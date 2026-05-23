#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fetch + extract the abhiTronix aarch64 cross-toolchain for RPi 4B
# (Bookworm/Trixie host).  The toolchain binaries are not in the fork
# repo (third_party/rpi_cross_compiler) — they live on SourceForge and
# are downloaded on demand.
#
# Layout after running:
#   third_party/rpi_toolchain/
#     cross-pi-gcc-14.2.0-64/        ← extracted toolchain
#       bin/aarch64-linux-gnu-gcc
#       ...
#
# The path is intentionally outside third_party/rpi_cross_compiler/ so
# we don't pollute the fork checkout (which is just scripts + docs).
# It's added to .gitignore at the repo root.

set -euo pipefail

GCC_VER="${RPI_GCC_VER:-14.2.0}"
DEBIAN_FLAVOR="${RPI_DEBIAN:-Bookworm}"  # Bookworm / Bullseye / Buster
TARBALL="cross-gcc-${GCC_VER}-pi_64.tar.gz"
SF_PROJECT="raspberry-pi-cross-compilers"
SF_FOLDER="Bonus%20Raspberry%20Pi%20GCC%2064-Bit%20Toolchains/Raspberry%20Pi%20GCC%2064-Bit%20Cross-Compiler%20Toolchains"
URL="https://sourceforge.net/projects/${SF_PROJECT}/files/${SF_FOLDER}/${DEBIAN_FLAVOR}/GCC%20${GCC_VER}/${TARBALL}/download"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
INSTALL_DIR="${ROOT_DIR}/third_party/rpi_toolchain"

mkdir -p "${INSTALL_DIR}"

# Quick exit if the toolchain bin is already present
TOOLCHAIN_BIN="${INSTALL_DIR}/cross-pi-gcc-${GCC_VER}-64/bin/aarch64-linux-gnu-gcc"
if [[ -x "${TOOLCHAIN_BIN}" ]]; then
    echo "[rpi-toolchain] already present: ${TOOLCHAIN_BIN}"
    "${TOOLCHAIN_BIN}" --version | head -1
    exit 0
fi

cd "${INSTALL_DIR}"

if [[ ! -f "${TARBALL}" ]]; then
    echo "[rpi-toolchain] downloading ${TARBALL} (~320 MB) from SourceForge..."
    # SF redirects through several CDN hops; -L follows them.  --retry rides
    # over the occasional 503 from mirror selection.
    curl -L --fail --retry 5 --retry-delay 2 -o "${TARBALL}" "${URL}"
fi

echo "[rpi-toolchain] extracting ${TARBALL}..."
tar -xf "${TARBALL}"

if [[ -x "${TOOLCHAIN_BIN}" ]]; then
    echo "[rpi-toolchain] installed:"
    "${TOOLCHAIN_BIN}" --version | head -1
    echo "[rpi-toolchain] toolchain prefix: $(dirname "${TOOLCHAIN_BIN}")"
else
    echo "[rpi-toolchain] ERROR: expected binary not found at ${TOOLCHAIN_BIN}" >&2
    echo "Tarball contents:" >&2
    tar -tf "${TARBALL}" | head -10 >&2
    exit 1
fi
