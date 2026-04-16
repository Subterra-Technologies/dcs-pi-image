#!/usr/bin/env bash
set -euo pipefail

# subterra-pi-image: build a Raspberry Pi OS Lite 64-bit Bookworm image
# with Subterra's rootfs overlay baked in, flashable to NVMe.
#
# Strategy: wrap pi-gen. We provide a stage (stage-subterra) that copies
# rootfs/ into the target, runs apt install for packages.list, enables
# first-boot.service, and locks down ssh/ufw.
#
# This stub documents the flow. Implementation lands in task #7.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
WORK="${REPO_ROOT}/work"
PI_GEN_REF="${PI_GEN_REF:-arm64}"

echo "subterra-pi-image build stub — not yet implemented"
echo "Repo root: ${REPO_ROOT}"
echo "Work dir : ${WORK}"
echo "pi-gen   : ${PI_GEN_REF}"
exit 1
