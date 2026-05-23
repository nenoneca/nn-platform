#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

BUILD_DIR="${ROOT_DIR}/out/hello_cpp/nrf52840dk_nrf52840"
HEX_PATH=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--build-dir)
			BUILD_DIR="${ROOT_DIR}/$2"
			shift 2
			;;
		--hex)
			HEX_PATH="$2"
			shift 2
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
	esac
done

if [[ -z "${HEX_PATH}" ]]; then
	shopt -s nullglob
	merged_hexes=("${BUILD_DIR}"/merged_*.hex)
	shopt -u nullglob

	if [[ ${#merged_hexes[@]} -eq 1 ]]; then
		HEX_PATH="${merged_hexes[0]}"
	else
		HEX_PATH="${BUILD_DIR}/zephyr/zephyr.hex"
	fi
fi

if [[ ! -f "${HEX_PATH}" ]]; then
	echo "Missing hex file: ${HEX_PATH}" >&2
	exit 1
fi

nrfjprog --family NRF52 --program "${HEX_PATH}" --sectorerase --verify --reset
