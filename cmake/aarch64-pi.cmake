# SPDX-License-Identifier: Apache-2.0
#
# CMake toolchain file targeting the Raspberry Pi 4B (aarch64, Cortex-A72,
# Linux glibc) using the abhiTronix cross-toolchain fetched by
# device/scripts/bootstrap_rpi_toolchain.sh.
#
# Usage:
#   cmake -DCMAKE_TOOLCHAIN_FILE=$NN_ROOT/cmake/aarch64-pi.cmake \
#         -B build-aarch64 -S host/gw_linux

set(CMAKE_SYSTEM_NAME      Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Resolve toolchain prefix.  Allow override via NN_RPI_TOOLCHAIN env,
# otherwise look in the standard checkout path the bootstrap script
# installs to.
if(DEFINED ENV{NN_RPI_TOOLCHAIN})
    set(NN_RPI_TOOLCHAIN_PREFIX "$ENV{NN_RPI_TOOLCHAIN}")
else()
    # Walk up from this file: <root>/cmake/aarch64-pi.cmake
    # → <root>/third_party/rpi_toolchain/cross-pi-gcc-<ver>-64
    get_filename_component(_nn_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
    file(GLOB _gcc_dirs "${_nn_root}/third_party/rpi_toolchain/cross-pi-gcc-*-64")
    list(SORT _gcc_dirs)
    list(REVERSE _gcc_dirs)
    list(GET _gcc_dirs 0 NN_RPI_TOOLCHAIN_PREFIX)
endif()

if(NOT EXISTS "${NN_RPI_TOOLCHAIN_PREFIX}/bin/aarch64-linux-gnu-gcc")
    message(FATAL_ERROR
        "Cross-toolchain not found at ${NN_RPI_TOOLCHAIN_PREFIX}.\n"
        "Run device/scripts/bootstrap_rpi_toolchain.sh to fetch it, or "
        "set NN_RPI_TOOLCHAIN to a different aarch64 gcc prefix.")
endif()

set(CMAKE_C_COMPILER   ${NN_RPI_TOOLCHAIN_PREFIX}/bin/aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER ${NN_RPI_TOOLCHAIN_PREFIX}/bin/aarch64-linux-gnu-g++)
set(CMAKE_AR           ${NN_RPI_TOOLCHAIN_PREFIX}/bin/aarch64-linux-gnu-ar)
set(CMAKE_STRIP        ${NN_RPI_TOOLCHAIN_PREFIX}/bin/aarch64-linux-gnu-strip)

set(CMAKE_SYSROOT ${NN_RPI_TOOLCHAIN_PREFIX}/aarch64-linux-gnu/libc)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Cortex-A72 specific.
add_compile_options(-mcpu=cortex-a72 -mtune=cortex-a72)
