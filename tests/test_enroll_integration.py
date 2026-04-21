"""Pi enroll script unit test in DRY_RUN mode.

Does not require Tailscale running — we stub the expected inputs
and verify the script reads the enroll config, computes routes, and would
call `tailscale up` with the correct flags.
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
        assert "--login-server" not in err, err
        assert "joining tailnet (Tailscale SaaS)" in err, err

        meta = json.loads((r.sandbox / "pi-state" / "enrollment.json").read_text())
        assert meta["district"] == "oakridge", meta
        assert meta["hostname"] == "oakridge-pi-ABCDEF12", meta
        assert "login_server" not in meta, meta
        print("OK: SaaS enrollment path")
    finally:
        shutil.rmtree(r.sandbox, ignore_errors=True)


def main() -> int:
    case_saas()
    print("\nOK: Pi tailscale enrollment dry-run green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
