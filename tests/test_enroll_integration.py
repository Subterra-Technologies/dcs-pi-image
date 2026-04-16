"""Pi enroll script unit test in DRY_RUN mode.

Does not require headscale running — we stub the expected inputs and verify
the script reads the enroll config, computes routes, and would call
`tailscale up` with the correct flags.
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
ENROLL_SCRIPT = REPO_ROOT / "rootfs" / "usr" / "local" / "sbin" / "subterra-enroll"


def main() -> int:
    sandbox = Path(tempfile.mkdtemp(prefix="subterra-pi-"))
    pi_state = sandbox / "pi-state"
    pi_boot = sandbox / "pi-boot"
    pi_state.mkdir()
    pi_boot.mkdir()

    enroll_cfg = {
        "authkey": "tskey-auth-test-00000000000000000000",
        "coordinator": "https://hub.subterra.test",
        "district": "oakridge",
        "advertise_routes": ["192.168.10.0/24"],
    }
    (pi_boot / "subterra-enroll.json").write_text(json.dumps(enroll_cfg))

    pi_env = {
        **os.environ,
        "SUBTERRA_STATE_DIR": str(pi_state),
        "SUBTERRA_ENROLL_CONFIG": str(pi_boot / "subterra-enroll.json"),
        "SUBTERRA_DRY_RUN": "1",
        "SUBTERRA_SERIAL": "ABCDEF12",
    }

    try:
        result = subprocess.run(
            ["bash", str(ENROLL_SCRIPT)],
            env=pi_env, capture_output=True, text=True,
        )
        if result.returncode != 0:
            print("stderr:\n", result.stderr, file=sys.stderr)
            raise SystemExit(f"enroll exited {result.returncode}")

        err = result.stderr
        # Verify the dry-run log shows the tailscale command that would run.
        assert "DRY: tailscale up" in err, err
        assert "--login-server https://hub.subterra.test" in err, err
        assert "--authkey tskey-auth-test-00000000000000000000" in err, err
        assert "--ssh" in err, err
        assert "--advertise-routes" in err, err
        assert "192.168.10.0/24" in err, err
        # Hostname should include district + short serial.
        assert "oakridge-pi-ABCDEF12" in err, err

        meta = json.loads((pi_state / "enrollment.json").read_text())
        assert meta["district"] == "oakridge", meta
        assert meta["coordinator"] == "https://hub.subterra.test", meta
        assert meta["hostname"] == "oakridge-pi-ABCDEF12", meta
        assert "192.168.10.0/24" in meta["advertise_routes"], meta

        assert (pi_state / "enrolled").exists()
        assert not (pi_boot / "subterra-enroll.json").exists()

        # Re-run must short-circuit.
        (pi_boot / "subterra-enroll.json").write_text(json.dumps(enroll_cfg))
        rerun = subprocess.run(
            ["bash", str(ENROLL_SCRIPT)],
            env=pi_env, capture_output=True, text=True,
        )
        assert rerun.returncode == 0
        assert "already enrolled" in rerun.stderr, rerun.stderr

        print("OK: Pi tailscale enrollment dry-run green")
        return 0
    finally:
        shutil.rmtree(sandbox, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
