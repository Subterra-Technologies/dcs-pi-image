#!/bin/bash -e
# pi-gen prerun hook for stage-dcs. Copies the previous stage into ROOTFS_DIR.
if [ ! -d "${ROOTFS_DIR}" ]; then
    copy_previous
fi
