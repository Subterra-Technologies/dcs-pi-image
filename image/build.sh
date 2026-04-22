#!/usr/bin/env bash
# Build a dcs-pi Raspberry Pi OS Lite 64-bit image.
#
# Wraps pi-gen. First run clones pi-gen into ./work/pi-gen; subsequent runs
# reuse it. Produces a flashable .img.xz under ./deploy/.
#
# Requires: Docker (for build-docker.sh) or the host packages pi-gen wants.
# Recommended: use Docker — it sidesteps a lot of host-compatibility pain.
#
# Usage: ./image/build.sh [--clean]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
WORK="${REPO_ROOT}/work"
PI_GEN_DIR="${WORK}/pi-gen"
PI_GEN_REPO="${PI_GEN_REPO:-https://github.com/RPi-Distro/pi-gen.git}"
PI_GEN_REF="${PI_GEN_REF:-arm64}"
DEPLOY_DIR="${REPO_ROOT}/deploy"

if [[ "${1:-}" = "--clean" ]]; then
    echo "cleaning ${WORK} and ${DEPLOY_DIR}"
    rm -rf "${WORK}" "${DEPLOY_DIR}"
    shift || true
fi

mkdir -p "${WORK}" "${DEPLOY_DIR}"

if [[ ! -d "${PI_GEN_DIR}" ]]; then
    echo "cloning pi-gen (${PI_GEN_REF})"
    git clone --depth 1 --branch "${PI_GEN_REF}" "${PI_GEN_REPO}" "${PI_GEN_DIR}"
fi

echo "installing stage-dcs into pi-gen"
rsync -a --delete "${HERE}/stage-dcs/" "${PI_GEN_DIR}/stage-dcs/"
find "${PI_GEN_DIR}/stage-dcs" -type f \( -name '*.sh' -o -name 'prerun.sh' \) \
    -exec chmod +x {} +

for stage in stage3 stage4 stage5; do
    touch "${PI_GEN_DIR}/${stage}/SKIP" "${PI_GEN_DIR}/${stage}/SKIP_IMAGES"
done
# stage2 still produces an intermediate image; we suppress its export.
touch "${PI_GEN_DIR}/stage2/SKIP_IMAGES"

# Make the overlay reachable to stage-dcs hooks via ${STAGE_DIR}/rootfs.
ln -snf "${REPO_ROOT}/rootfs" "${PI_GEN_DIR}/stage-dcs/rootfs"

cp "${HERE}/config" "${PI_GEN_DIR}/config"

cd "${PI_GEN_DIR}"
if command -v docker >/dev/null 2>&1; then
    echo "running pi-gen via build-docker.sh"
    ./build-docker.sh
else
    echo "Docker not found. Install Docker or run build.sh manually:"
    echo "  cd ${PI_GEN_DIR} && sudo ./build.sh"
    exit 3
fi

echo "collecting output to ${DEPLOY_DIR}"
find "${PI_GEN_DIR}/deploy" -maxdepth 2 -name '*.img*' -exec cp -v {} "${DEPLOY_DIR}/" \;

echo "done. Images in ${DEPLOY_DIR}/"
