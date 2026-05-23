#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# flash_esp32c6.sh — flash an ESP32-C6 DevKitC + reset the host TTY.
#
# Background: after esptool writes at --baud 460800 the Linux kernel
# leaves the CH343 USB-CDC port at 460800.  The chip then boots at
# 115200, so the host drops bytes until you replug.  This wrapper
# runs esptool write-flash, then issues `stty 115200` on the
# matching CH343 port to clear the stale baud without a physical
# replug.
#
# Usage:
#   flash_esp32c6.sh --jtag /dev/ttyACMx                 \
#                    --mcuboot path/to/mcuboot.bin       \
#                    --app     path/to/app.signed.bin    \
#                    [--ch343  /dev/ttyACMx]              # optional, auto-detected
#
# If --ch343 is omitted, the script finds it by USB topology: the
# CH343 (1a86:55d3) sibling that shares the same USB sub-hub as the
# given JTAG (303a:1001) port.

set -euo pipefail

JTAG=""
CH343=""
MCUBOOT=""
APP=""
BAUD=460800
CHIP=esp32c6

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jtag)    JTAG="$2"; shift 2;;
        --ch343)   CH343="$2"; shift 2;;
        --mcuboot) MCUBOOT="$2"; shift 2;;
        --app)     APP="$2"; shift 2;;
        --baud)    BAUD="$2"; shift 2;;
        --chip)    CHIP="$2"; shift 2;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's|^# \?||'
            exit 0;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
    esac
done

[[ -n "${JTAG}"     ]] || { echo "--jtag required" >&2; exit 1; }
[[ -n "${MCUBOOT}"  ]] || { echo "--mcuboot required" >&2; exit 1; }
[[ -n "${APP}"      ]] || { echo "--app required"     >&2; exit 1; }
[[ -e "${JTAG}"     ]] || { echo "JTAG port ${JTAG} does not exist" >&2; exit 1; }
[[ -f "${MCUBOOT}"  ]] || { echo "mcuboot ${MCUBOOT} not found"     >&2; exit 1; }
[[ -f "${APP}"      ]] || { echo "app     ${APP} not found"         >&2; exit 1; }

# ── Auto-detect the CH343 sibling of the JTAG port ────────────────────────
# Both USB devices on a DevKitC enumerate as siblings under the same
# on-board internal hub.  Their DEVPATHs share the parent-hub path and
# differ only in the trailing per-port dir + tty name.  Walking up four
# levels with dirname collapses to the shared parent.
#
#   /devices/.../1-11.3/1-11.3.4/1-11.3.4:1.0/tty/ttyACM8     (JTAG)
#                ^^^^^^                                       ← match
#   /devices/.../1-11.3/1-11.3.2/1-11.3.2:1.0/tty/ttyACM5     (CH343)
detect_ch343() {
    local jtag="$1"
    local jtag_dev jtag_parent
    jtag_dev="$(udevadm info -q property "${jtag}" 2>/dev/null \
                | sed -n 's|^DEVPATH=||p')"
    [[ -n "${jtag_dev}" ]] || return 1

    jtag_parent="$(dirname "$(dirname "$(dirname "$(dirname "${jtag_dev}")")")")"
    [[ -n "${jtag_parent}" && "${jtag_parent}" != "/" ]] || return 1

    local cand vid pid devpath
    for cand in /dev/ttyACM*; do
        [[ -e "${cand}" ]] || continue
        vid="$(udevadm info -q property "${cand}" 2>/dev/null \
               | sed -n 's|^ID_VENDOR_ID=||p')"
        pid="$(udevadm info -q property "${cand}" 2>/dev/null \
               | sed -n 's|^ID_MODEL_ID=||p')"
        devpath="$(udevadm info -q property "${cand}" 2>/dev/null \
                   | sed -n 's|^DEVPATH=||p')"
        [[ "${vid}" == "1a86" && "${pid}" == "55d3" ]] || continue

        local cand_parent
        cand_parent="$(dirname "$(dirname "$(dirname "$(dirname "${devpath}")")")")"
        if [[ "${cand_parent}" == "${jtag_parent}" ]]; then
            echo "${cand}"
            return 0
        fi
    done
    return 1
}

if [[ -z "${CH343}" ]]; then
    if CH343="$(detect_ch343 "${JTAG}")"; then
        echo "[flash] detected CH343 sibling: ${CH343}"
    else
        echo "[flash] no CH343 sibling found for ${JTAG} — skipping post-flash stty reset" >&2
    fi
fi

# ── Flash via JTAG (uses GPIO9 strap, doesn't set LP_AON) ─────────────────
echo "[flash] esptool write-flash → ${JTAG} @ ${BAUD}"
esptool --chip "${CHIP}" --port "${JTAG}" --baud "${BAUD}" \
    --before usb-reset --after hard-reset \
    write-flash --flash-mode dio --flash-freq 80m --flash-size 8MB \
    0x0     "${MCUBOOT}" \
    0x20000 "${APP}"

# ── Reset the CH343 host TTY back to 115200 ───────────────────────────────
if [[ -n "${CH343}" && -e "${CH343}" ]]; then
    echo "[flash] stty ${CH343} 115200 (clear stale baud from esptool session)"
    # stty needs a brief moment after the chip reboots before the host
    # driver will accept a re-config.  ~250 ms is plenty.
    sleep 0.3
    stty -F "${CH343}" 115200 raw -echo cs8 -cstopb -parenb \
        2>/dev/null || true
fi

echo "[flash] done"
