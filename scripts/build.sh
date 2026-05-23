#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

APP_DIR="${ROOT_DIR}/apps/hello_cpp"
BOARD="nrf52840dk/nrf52840"
BUILD_DIR=""
USE_SYSBUILD="auto"
SHIELD=""
SNIPPET=""
ESPRESSIF_TOOLCHAIN_PATH=""
APP_VERSION=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version)
			APP_VERSION="$2"
			shift 2
			;;

		--app)
			APP_DIR="${ROOT_DIR}/$2"
			shift 2
			;;
		--board)
			BOARD="$2"
			shift 2
			;;
		--build-dir)
			BUILD_DIR="${ROOT_DIR}/$2"
			shift 2
			;;
		--shield)
			SHIELD="$2"
			shift 2
			;;
		--snippet)
			SNIPPET="$2"
			shift 2
			;;
		--espressif-toolchain)
			ESPRESSIF_TOOLCHAIN_PATH="$2"
			shift 2
			;;
		--sysbuild)
			USE_SYSBUILD="yes"
			shift
			;;
		--no-sysbuild)
			USE_SYSBUILD="no"
			shift
			;;
		*)
			echo "Unknown argument: $1" >&2
			exit 1
			;;
	esac
done

# Derive BUILD_DIR from app name + board if not set explicitly.
if [[ -z "${BUILD_DIR}" ]]; then
	APP_NAME=$(basename "${APP_DIR}")
	BOARD_SLUG="${BOARD//\//_}"
	BUILD_DIR="${ROOT_DIR}/out/${APP_NAME}/${BOARD_SLUG}"
fi

export ZEPHYR_BASE="${ROOT_DIR}/third_party/zephyr"

if [[ ! -d "${ZEPHYR_BASE}" ]]; then
	echo "Missing ${ZEPHYR_BASE}. Run ./scripts/bootstrap_third_party.sh first." >&2
	exit 1
fi

if [[ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ]]; then
	for candidate in \
		"${HOME}/zephyr-sdk-0.17.0" \
		"${HOME}/zephyr-sdk" \
		"/opt/zephyr-sdk"
	do
		if [[ -d "${candidate}" ]]; then
			export ZEPHYR_SDK_INSTALL_DIR="${candidate}"
			break
		fi
	done
fi

if [[ -z "${ZEPHYR_SDK_INSTALL_DIR:-}" ]]; then
	echo "ZEPHYR_SDK_INSTALL_DIR is not set and no SDK was auto-detected." >&2
	exit 1
fi

find_python_with_elftools() {
	local candidate

	for candidate in \
		"${PYTHON_EXECUTABLE:-}" \
		"/media/chalos/mx500/oss/zephyr/venv/bin/python" \
		"${HOME}/.virtualenvs/zephyr/bin/python" \
		"$(command -v python3)"
	do
		[[ -n "${candidate}" ]] || continue
		[[ -x "${candidate}" ]] || continue

		if "${candidate}" -c 'import elftools' >/dev/null 2>&1; then
			echo "${candidate}"
			return 0
		fi
	done

	return 1
}

PYTHON_BIN="$(find_python_with_elftools || true)"
if [[ -z "${PYTHON_BIN}" ]]; then
	echo "Could not find a Python interpreter with pyelftools installed." >&2
	exit 1
fi

export CCACHE_DISABLE=1

declare -a modules=()

append_module_if_present() {
	local path="$1"

	if [[ -f "${path}/zephyr/module.yml" ]]; then
		modules+=("${path}")
	fi
}

for path in "${ROOT_DIR}"/third_party/*; do
	# Accept both real directories and symlinks-to-directories
	[[ -d "${path}" ]] || [[ -L "${path}" && -d "${path}" ]] || continue
	[[ "${path}" == "${ZEPHYR_BASE}" ]] && continue
	append_module_if_present "${path}"
done

for path in "${ROOT_DIR}"/modules/*/*; do
	[[ -d "${path}" ]] || continue
	append_module_if_present "${path}"
done

if [[ ${#modules[@]} -gt 0 ]]; then
	IFS=';'
	export ZEPHYR_MODULES="${modules[*]}"
	unset IFS
else
	unset ZEPHYR_MODULES
fi

if [[ "${USE_SYSBUILD}" == "auto" ]]; then
	if [[ -f "${APP_DIR}/sysbuild.conf" ]]; then
		USE_SYSBUILD="yes"
	else
		USE_SYSBUILD="no"
	fi
fi

declare -a extra_cmake_args=()
if [[ -n "${SHIELD}" ]]; then
	extra_cmake_args+=("-DSHIELD=${SHIELD}")
fi
if [[ -n "${SNIPPET}" ]]; then
	extra_cmake_args+=("-DSNIPPET=${SNIPPET}")
fi
# ESPRESSIF_TOOLCHAIN_PATH is needed for OpenOCD discovery in board.cmake.
# Auto-detect if not set explicitly.
if [[ -z "${ESPRESSIF_TOOLCHAIN_PATH}" ]]; then
	for candidate in \
		"${HOME}/esp" \
		"/home/chalos/ext/mx500/oss/esp32" \
		"/opt/esp"
	do
		if [[ -f "${candidate}/openocd-esp32/bin/openocd" ]]; then
			ESPRESSIF_TOOLCHAIN_PATH="${candidate}"
			break
		fi
	done
fi
if [[ -n "${ESPRESSIF_TOOLCHAIN_PATH}" ]]; then
	extra_cmake_args+=("-DESPRESSIF_TOOLCHAIN_PATH=${ESPRESSIF_TOOLCHAIN_PATH}")
fi
if [[ -n "${APP_VERSION}" ]]; then
	export NN_APP_VERSION="${APP_VERSION}"
fi

if [[ "${USE_SYSBUILD}" == "yes" ]]; then
	cmake -S "${ZEPHYR_BASE}/share/sysbuild" -B "${BUILD_DIR}" -GNinja \
		-DAPP_DIR="${APP_DIR}" \
		-DBOARD="${BOARD}" \
		-DBOARD_ROOT="${ROOT_DIR}" \
		-DPython3_EXECUTABLE="${PYTHON_BIN}" \
		-DZEPHYR_MODULES="${ZEPHYR_MODULES:-}" \
		"${extra_cmake_args[@]}"
else
	cmake -S "${APP_DIR}" -B "${BUILD_DIR}" -GNinja \
		-DBOARD="${BOARD}" \
		-DBOARD_ROOT="${ROOT_DIR}" \
		-DPython3_EXECUTABLE="${PYTHON_BIN}" \
		-DZEPHYR_MODULES="${ZEPHYR_MODULES:-}" \
		"${extra_cmake_args[@]}"
fi

cmake --build "${BUILD_DIR}"
