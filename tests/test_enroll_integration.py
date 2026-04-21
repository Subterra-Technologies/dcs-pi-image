"""Pi enroll script unit test in DRY_RUN mode.

Does not require Tailscale/Headscale running — we stub the expected inputs
and verify the script reads the enroll config, computes routes, and would
call `tailscale up` with the correct flags.

Covers both:
  - Tailscale SaaS mode (no login_server; default)
  - Self-hosted Headscale mode (explicit login_server)
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ENROLL_SCRIPT = REPO_ROOT / "rootfs" / "usr" / "local" / "sbin" / "detel-enroll"


def run_enroll(cfg: dict, serial: str = "ABCDEF12") -> subprocess.CompletedProcess:
    sandbox = Path(tempfile.mkdtemp(prefix="detel-pi-"))
    try:
        pi_state = sandbox / "pi-state"
        pi_boot = sandbox / "pi-boot"
        pi_state.mkdir()
        pi_boot.mkdir()
        (pi_boot / "detel-enroll.json").write_text(json.dumps(cfg))
        env = {
            **os.environ,
            "DETEL_STATE_DIR": str(pi_state),
            "DETEL_ENROLL_CONFIG": str(pi_boot / "detel-enroll.json"),
            "DETEL_DRY_RUN": "1",
            "DETEL_SERIAL": serial,
        }
        r = subprocess.run(
            ["bash", str(ENROLL_SCRIPT)],
            env=env, capture_output=True, text=True,
        )
        r.sandbox = sandbox   # type: ignore[attr-defined]
        return r
    except Exception:
        shutil.rmtree(sandbox, ignore_errors=True)
        raise


def case_saas() -> None:
    """Default path: no login_server → defaults to Tailscale SaaS."""
    cfg = {
        "authkey": "tskey-auth-test-00000000000000000000",
        "district": "oakridge",
        "advertise_routes": ["192.168.10.0/24"],
    }
    r = run_enroll(cfg)
    try:
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            raise SystemExit("SaaS case: exit nonzero")
        err = r.stderr
        assert "DRY: tailscale up" in err, err
        assert "--authkey tskey-auth-test-00000000000000000000" in err, err
        assert "--ssh" in err, err
        assert "--advertise-routes" in err, err
        assert "192.168.10.0/24" in err, err
        assert "oakridge-pi-ABCDEF12" in err, err
        # Critical: SaaS mode MUST NOT pass --login-server.
        assert "--login-server" not in err, err
        assert "joining tailnet (Tailscale SaaS)" in err, err

        meta = json.loads((r.sandbox / "pi-state" / "enrollment.json").read_text())
        assert meta["district"] == "oakridge", meta
        assert meta["login_server"] == "tailscale-saas", meta
        assert meta["hostname"] == "oakridge-pi-ABCDEF12", meta
        print("OK: SaaS default path")
    finally:
        shutil.rmtree(r.sandbox, ignore_errors=True)


def case_headscale() -> None:
    """Explicit login_server → backward-compatible Headscale path."""
    cfg = {
        "authkey": "tskey-auth-test-00000000000000000000",
        "login_server": "https://hub.example.test",
        "district": "lincoln",
        "advertise_routes": ["10.5.0.0/24"],
    }
    r = run_enroll(cfg, serial="11111111")
    try:
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            raise SystemExit("Headscale case: exit nonzero")
        err = r.stderr
        assert "DRY: tailscale up" in err, err
        assert "--login-server https://hub.example.test" in err, err
        assert "lincoln-pi-11111111" in err, err

        meta = json.loads((r.sandbox / "pi-state" / "enrollment.json").read_text())
        assert meta["login_server"] == "https://hub.example.test", meta
        print("OK: Headscale explicit login_server path")
    finally:
        shutil.rmtree(r.sandbox, ignore_errors=True)


def main() -> int:
    case_saas()
    case_headscale()
    print("\nOK: Pi tailscale enrollment dry-run green (SaaS + Headscale paths)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
