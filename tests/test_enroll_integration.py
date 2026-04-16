"""Integration test: run hub service + Pi enroll script end-to-end.

Starts the hub (uvicorn) in /tmp sandbox, issues a token via admin CLI,
writes a fake enrollment config, invokes subterra-enroll with DRY_RUN=1 +
path overrides, and asserts the Pi produced a correct wg0.conf,
enrollment.json, and NETMAP plan.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
HUB_ROOT = REPO_ROOT.parent / "subterra-wg-hub"
HUB_VENV_PY = HUB_ROOT / ".venv" / "bin" / "python"
ENROLL_SCRIPT = REPO_ROOT / "rootfs" / "usr" / "local" / "sbin" / "subterra-enroll"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_for_http(url: str, timeout: float = 10.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as r:
                if r.status == 200:
                    return
        except Exception:
            time.sleep(0.1)
    raise RuntimeError(f"service at {url} did not become healthy in {timeout}s")


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="subterra-int-"))
    hub_state = sandbox / "hub-state"
    hub_wg = sandbox / "hub-wg"
    pi_state = sandbox / "pi-state"
    pi_wg = sandbox / "pi-wg"
    pi_iptables = sandbox / "pi-iptables"
    pi_boot = sandbox / "pi-boot"
    for d in (hub_state, hub_wg, pi_state, pi_wg, pi_iptables, pi_boot):
        d.mkdir(parents=True)

    port = free_port()
    hub_env = {
        **os.environ,
        "SUBTERRA_DB": str(hub_state / "state.db"),
        "SUBTERRA_WG_CONF": str(hub_wg / "wg0.conf"),
        "SUBTERRA_HUB_PRIVKEY": str(hub_wg / "hub.key"),
        "SUBTERRA_HUB_PUBKEY": str(hub_wg / "hub.pubkey"),
        "SUBTERRA_WG_ENDPOINT": "hub.test.internal:51820",
        "SUBTERRA_SKIP_WG_SYNC": "1",
        "SUBTERRA_HOST": "127.0.0.1",
        "SUBTERRA_PORT": str(port),
    }

    hub_proc: subprocess.Popen | None = None
    try:
        subprocess.run(
            [str(HUB_VENV_PY), "-m", "enrollment.admin_cli", "bootstrap"],
            env=hub_env,
            cwd=HUB_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

        subprocess.run(
            [str(HUB_VENV_PY), "-m", "enrollment.admin_cli",
             "add-school", "springfield", "Springfield Unified"],
            env=hub_env, cwd=HUB_ROOT, check=True, capture_output=True, text=True,
        )
        issued = subprocess.run(
            [str(HUB_VENV_PY), "-m", "enrollment.admin_cli",
             "issue-token", "springfield"],
            env=hub_env, cwd=HUB_ROOT, check=True, capture_output=True, text=True,
        )
        token = issued.stdout.strip().splitlines()[-1]

        hub_proc = subprocess.Popen(
            [str(HUB_VENV_PY), "-m", "uvicorn", "enrollment.main:app",
             "--host", "127.0.0.1", "--port", str(port), "--log-level", "warning"],
            env=hub_env, cwd=HUB_ROOT,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        wait_for_http(f"http://127.0.0.1:{port}/healthz")

        enroll_cfg = {
            "enroll_token": token,
            "enrollment_url": f"http://127.0.0.1:{port}",
            "candidate_subnets": ["192.168.50.0/24"],
        }
        (pi_boot / "subterra-enroll.json").write_text(json.dumps(enroll_cfg))

        pi_env = {
            **os.environ,
            "SUBTERRA_STATE_DIR": str(pi_state),
            "SUBTERRA_WG_DIR": str(pi_wg),
            "SUBTERRA_ENROLL_CONFIG": str(pi_boot / "subterra-enroll.json"),
            "SUBTERRA_IPTABLES_DIR": str(pi_iptables),
            "SUBTERRA_DRY_RUN": "1",
            "SUBTERRA_SERIAL": "PI-INTEGRATION-0001",
        }

        result = subprocess.run(
            ["bash", str(ENROLL_SCRIPT)],
            env=pi_env, capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("enroll script stdout:\n", result.stdout, file=sys.stderr)
            print("enroll script stderr:\n", result.stderr, file=sys.stderr)
            raise SystemExit(f"enroll script exited {result.returncode}")

        wg_conf = (pi_wg / "wg0.conf").read_text()
        assert "[Interface]" in wg_conf and "[Peer]" in wg_conf, wg_conf
        assert "Endpoint = hub.test.internal:51820" in wg_conf, wg_conf
        assert "PersistentKeepalive = 25" in wg_conf, wg_conf
        assert "AllowedIPs = 10.200.0.0/16" in wg_conf, wg_conf
        assert "Address = 10.200.0.2/32" in wg_conf, wg_conf

        meta = json.loads((pi_state / "enrollment.json").read_text())
        assert meta["hostname"] == "springfield-pi01", meta
        assert meta["tunnel_ip"] == "10.200.0.2/32", meta
        assert meta["virtual_subnet"] == "10.100.0.0/16", meta
        assert "192.168.50.0/24" in meta["real_subnets"], meta
        mapping_virts = {m["virtual"]: m["real"] for m in meta["subnet_mappings"]}
        assert "10.100.0.0/24" in mapping_virts, meta["subnet_mappings"]
        assert mapping_virts["10.100.0.0/24"] == "192.168.50.0/24", mapping_virts

        stderr_out = result.stderr
        if "NETMAP 10.100.0.0/24 -> 192.168.50.0/24" not in stderr_out:
            print("FULL STDERR:\n" + stderr_out, file=sys.stderr)
            raise AssertionError("NETMAP log missing")
        assert "DRY: iptables" in stderr_out, stderr_out
        assert "DRY: systemctl enable" in stderr_out, stderr_out

        assert (pi_state / "enrolled").exists(), "enrolled sentinel not created"
        assert not (pi_boot / "subterra-enroll.json").exists(), "enroll_config should be deleted"

        # Idempotency: re-run should short-circuit
        (pi_boot / "subterra-enroll.json").write_text(json.dumps(enroll_cfg))
        rerun = subprocess.run(
            ["bash", str(ENROLL_SCRIPT)],
            env=pi_env, capture_output=True, text=True,
        )
        assert rerun.returncode == 0, rerun.stderr
        assert "already enrolled" in rerun.stderr, rerun.stderr

        print("OK: Pi enrollment integration green")
        return 0
    finally:
        if hub_proc is not None:
            hub_proc.send_signal(signal.SIGTERM)
            try:
                hub_proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                hub_proc.kill()
        shutil.rmtree(sandbox, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
