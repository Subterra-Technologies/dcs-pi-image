"""Pi enroll script against a real coordinator. Sandbox paths via env vars;
iptables/systemctl/reboot suppressed via SUBTERRA_DRY_RUN=1.

Covers the per-district model: district has two Zabbix VMs (redundancy),
Pi enrolls and receives both as peers, writes a multi-[Peer] wg0.conf,
installs MASQUERADE (no NETMAP), and records peers in enrollment.json.
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


def _gen_pub() -> str:
    priv = subprocess.run(
        ["wg", "genkey"], capture_output=True, text=True, check=True
    ).stdout.strip()
    return subprocess.run(
        ["wg", "pubkey"], input=priv, capture_output=True, text=True, check=True
    ).stdout.strip()


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="subterra-int-"))
    hub_state = sandbox / "hub-state"
    pi_state = sandbox / "pi-state"
    pi_wg = sandbox / "pi-wg"
    pi_iptables = sandbox / "pi-iptables"
    pi_boot = sandbox / "pi-boot"
    for d in (hub_state, pi_state, pi_wg, pi_iptables, pi_boot):
        d.mkdir(parents=True)

    port = free_port()
    hub_env = {
        **os.environ,
        "SUBTERRA_DB": str(hub_state / "state.db"),
        "SUBTERRA_HOST": "127.0.0.1",
        "SUBTERRA_PORT": str(port),
    }

    hub_proc: subprocess.Popen | None = None
    try:
        def hub_cli(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(
                [str(HUB_VENV_PY), "-m", "enrollment.admin_cli", *args],
                env=hub_env, cwd=HUB_ROOT, check=True, capture_output=True, text=True,
            )

        hub_cli("init")
        hub_cli("add-district", "springfield", "Springfield Unified")
        za_pub = _gen_pub()
        zb_pub = _gen_pub()
        hub_cli(
            "register-zabbix", "springfield", "zabbix-springfield-a", za_pub,
            "zabbix-a.hub.test:51821", "--listen-port", "51821",
        )
        hub_cli(
            "register-zabbix", "springfield", "zabbix-springfield-b", zb_pub,
            "zabbix-b.hub.test:51822", "--listen-port", "51822",
        )
        token = hub_cli("issue-token", "springfield").stdout.strip().splitlines()[-1]

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
            "candidate_subnets": ["192.168.1.0/24", "10.50.0.0/24"],
        }
        (pi_boot / "subterra-enroll.json").write_text(json.dumps(enroll_cfg))

        pi_env = {
            **os.environ,
            "SUBTERRA_STATE_DIR": str(pi_state),
            "SUBTERRA_WG_DIR": str(pi_wg),
            "SUBTERRA_ENROLL_CONFIG": str(pi_boot / "subterra-enroll.json"),
            "SUBTERRA_IPTABLES_DIR": str(pi_iptables),
            "SUBTERRA_DRY_RUN": "1",
            "SUBTERRA_SERIAL": "PI-INT-0001",
        }
        result = subprocess.run(
            ["bash", str(ENROLL_SCRIPT)],
            env=pi_env, capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("enroll stdout:\n", result.stdout, file=sys.stderr)
            print("enroll stderr:\n", result.stderr, file=sys.stderr)
            raise SystemExit(f"enroll script exited {result.returncode}")

        wg_conf = (pi_wg / "wg0.conf").read_text()
        assert "[Interface]" in wg_conf
        assert "Address = 10.200.0.1/29" in wg_conf, wg_conf
        assert wg_conf.count("[Peer]") == 2, wg_conf
        assert za_pub in wg_conf, wg_conf
        assert zb_pub in wg_conf, wg_conf
        assert "Endpoint = zabbix-a.hub.test:51821" in wg_conf, wg_conf
        assert "Endpoint = zabbix-b.hub.test:51822" in wg_conf, wg_conf
        assert "AllowedIPs = 10.200.0.2/32" in wg_conf, wg_conf
        assert "AllowedIPs = 10.200.0.3/32" in wg_conf, wg_conf
        assert "PersistentKeepalive = 25" in wg_conf, wg_conf

        # No NETMAP rules in the new model.
        assert "NETMAP" not in result.stderr, result.stderr

        meta = json.loads((pi_state / "enrollment.json").read_text())
        assert meta["hostname"] == "springfield-pi01", meta
        assert meta["tunnel_ip"] == "10.200.0.1/29", meta
        assert meta["district_subnet"] == "10.200.0.0/29", meta
        assert "192.168.1.0/24" in meta["real_subnets"]
        assert "10.50.0.0/24" in meta["real_subnets"]
        assert len(meta["peers"]) == 2, meta
        peer_pubs = {p["pubkey"] for p in meta["peers"]}
        assert peer_pubs == {za_pub, zb_pub}

        stderr_out = result.stderr
        assert "DRY: iptables -t nat -A POSTROUTING" in stderr_out, stderr_out
        assert "DRY: systemctl enable" in stderr_out, stderr_out
        assert "2 peer(s)" in stderr_out, stderr_out

        assert (pi_state / "enrolled").exists()
        assert not (pi_boot / "subterra-enroll.json").exists()

        # Idempotency.
        (pi_boot / "subterra-enroll.json").write_text(json.dumps(enroll_cfg))
        rerun = subprocess.run(
            ["bash", str(ENROLL_SCRIPT)],
            env=pi_env, capture_output=True, text=True,
        )
        assert rerun.returncode == 0, rerun.stderr
        assert "already enrolled" in rerun.stderr, rerun.stderr

        print("OK: per-district Pi enrollment integration green")
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
