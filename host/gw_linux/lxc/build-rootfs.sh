#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# build-rootfs.sh — create + bootstrap a minimal Debian LXC rootfs for
# the nn-gw gateway daemon.  Uses lxc-download (canonical on Debian
# Trixie / LXC 5+; the standalone lxc-debian template was removed).
# Idempotent: skips if the container already exists.

set -euo pipefail

NAME=${NAME:-nn-gw}
DIST=${DIST:-debian}
RELEASE=${RELEASE:-trixie}
ARCH=${ARCH:-arm64}
LXC_ROOT=${LXC_ROOT:-/var/lib/lxc}

if [[ $EUID -ne 0 ]]; then
    echo "build-rootfs.sh: must run as root" >&2
    exit 1
fi

if [[ -d "${LXC_ROOT}/${NAME}" ]]; then
    echo "container '${NAME}' already exists at ${LXC_ROOT}/${NAME}"
    echo "(remove with: sudo lxc-destroy -n ${NAME})"
    exit 0
fi

echo "==> creating LXC container '${NAME}' (${DIST} ${RELEASE}/${ARCH})"
lxc-create \
    -n "${NAME}" \
    -t download \
    -- \
    --dist    "${DIST}" \
    --release "${RELEASE}" \
    --arch    "${ARCH}"

ROOTFS="${LXC_ROOT}/${NAME}/rootfs"

echo "==> installing runtime deps inside rootfs"
mount --bind /proc "${ROOTFS}/proc"
mount --bind /sys  "${ROOTFS}/sys"
mount --bind /dev  "${ROOTFS}/dev"
trap 'umount "${ROOTFS}/dev" "${ROOTFS}/sys" "${ROOTFS}/proc" 2>/dev/null || true' EXIT

install -D -m 0644 /etc/resolv.conf "${ROOTFS}/etc/resolv.conf.host"
ln -sfn /etc/resolv.conf.host "${ROOTFS}/etc/resolv.conf"

chroot "${ROOTFS}" /bin/bash -eux <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# libmbedcrypto package name has churned across Debian releases:
#   Bullseye/Bookworm: libmbedcrypto7
#   Trixie:            libmbedcrypto16 (mbedtls 3.6+, what gw_linux needs)
# Pick whichever is provided.
if apt-cache show libmbedcrypto16 >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends \
        libmbedcrypto16 libsystemd0 avahi-utils ca-certificates
else
    apt-get install -y --no-install-recommends \
        libmbedcrypto7 libsystemd0 avahi-utils ca-certificates
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

echo "==> done; rootfs at ${ROOTFS}"
echo "    next: sudo ./install-gw_linux.sh"
