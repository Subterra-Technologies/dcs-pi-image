#!/bin/bash -e
# Copy the Detel rootfs overlay into the image.

OVERLAY="${STAGE_DIR}/rootfs"
if [ ! -d "${OVERLAY}" ]; then
    echo "rootfs overlay not found at ${OVERLAY}" >&2
    exit 1
fi

rsync -a \
    --exclude='boot/firmware/config.txt.append' \
    --exclude='boot/firmware/cmdline.txt.append' \
    "${OVERLAY}/" "${ROOTFS_DIR}/"

# Fix perms on executables and sensitive paths.
chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/detel-enroll"
chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/detel-heartbeat"
chmod 0755 "${ROOTFS_DIR}/usr/local/sbin/detel-setup"
install -d -m 0700 "${ROOTFS_DIR}/etc/wireguard"
install -d -m 0755 "${ROOTFS_DIR}/var/lib/detel"

# Merge our additions into the pi-gen-produced boot config files.
if [ -f "${OVERLAY}/boot/firmware/config.txt.append" ]; then
    cat "${OVERLAY}/boot/firmware/config.txt.append" \
        >> "${ROOTFS_DIR}/boot/firmware/config.txt"
fi
if [ -f "${OVERLAY}/boot/firmware/cmdline.txt.append" ]; then
    cmdline_extra=$(tr -d '\n' < "${OVERLAY}/boot/firmware/cmdline.txt.append")
    sed -i "1 s|\$|${cmdline_extra}|" "${ROOTFS_DIR}/boot/firmware/cmdline.txt"
fi
