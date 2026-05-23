#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

source "${SCRIPT_DIR}/pins.sh"

SOURCE_WORKSPACE=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--source-workspace)
			SOURCE_WORKSPACE="$2"
			shift 2
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
	esac
done

clone_repo() {
	local dest_name="$1"
	local remote_url="$2"
	local revision="$3"
	local source_relpath="$4"
	local dest_path="${ROOT_DIR}/third_party/${dest_name}"

	if [[ -e "${dest_path}" ]]; then
		echo "Skipping ${dest_name}: ${dest_path} already exists"
		return
	fi

	if [[ -n "${SOURCE_WORKSPACE}" && -d "${SOURCE_WORKSPACE}/${source_relpath}/.git" ]]; then
		echo "Cloning ${dest_name} from local workspace"
		git clone "${SOURCE_WORKSPACE}/${source_relpath}" "${dest_path}"
	else
		echo "Cloning ${dest_name} from ${remote_url}"
		git clone "${remote_url}" "${dest_path}"
	fi

	git -C "${dest_path}" checkout "${revision}"
}

clone_repo "zephyr" "${ZEPHYR_URL}" "${ZEPHYR_REV}" "${ZEPHYR_SRC_PATH}"
clone_repo "cmsis" "${CMSIS_URL}" "${CMSIS_REV}" "${CMSIS_SRC_PATH}"
clone_repo "cmsis_6" "${CMSIS_6_URL}" "${CMSIS_6_REV}" "${CMSIS_6_SRC_PATH}"
clone_repo "hal_nordic" "${HAL_NORDIC_URL}" "${HAL_NORDIC_REV}" "${HAL_NORDIC_SRC_PATH}"
clone_repo "mbedtls" "${MBEDTLS_URL}" "${MBEDTLS_REV}" "${MBEDTLS_SRC_PATH}"
clone_repo "mcuboot" "${MCUBOOT_URL}" "${MCUBOOT_REV}" "${MCUBOOT_SRC_PATH}"
