# Project Structure

## Repository layout

```
nn_project_nowest/
├── agent/              ← AI agent knowledge base (this folder)
├── apps/               ← Product applications (one app per subdirectory)
│   ├── mdns_ot_esp32c6/← Thread mesh + mDNS + ECIES CoAP + OTA (primary app)
│   ├── ble_ot_esp32c6/ ← BLE + OpenThread provisioning demo (ESP32-C6)
│   ├── gateway/        ← ESP32-S3 Thread Border Router (ESP-IDF, not Zephyr)
│   ├── hello_cpp/      ← C++ hello-world template (nRF52840)
│   ├── ot_shell_esp32c6/
│   ├── wifi_shell/     ← WiFi shell (nRF52840 + nRF7002EK)
│   └── wifi_shell_esp32c6/
├── boards/             ← Custom board definitions (shared across apps)
├── cmake/              ← Shared CMake helpers
├── modules/
│   ├── cmake/
│   │   └── nn_version.cmake  ← Auto-version from git commit count
│   ├── drivers/        ← Internal Zephyr drivers (empty)
│   ├── hal_vendor/     ← Vendor HAL patches (empty)
│   └── libs/
│       └── node_mgr/   ← BLE+Thread provisioning, ECIES v2, OTA client
├── out/                ← Build outputs (gitignored)
├── scripts/
│   ├── build.sh        ← Primary build entry point
│   ├── bootstrap_third_party.sh
│   ├── flash_nrfjprog.sh
│   └── pins.sh
└── third_party/        ← Pinned upstream Zephyr ecosystem repos
    ├── zephyr/         ← Zephyr RTOS (v4.3.0-4357-g4d0852b0051c)
    ├── hal_espressif/  ← ESP32 HAL
    ├── hal_nordic/
    ├── mbedtls/
    ├── mcuboot/
    └── ...
```

## Key design rules

- **No west workspace.** The project uses direct CMake/Ninja invocation.
  `west` is NOT available for `west build` or `west flash`.
- **Pinned third-party.** All upstream repos under `third_party/` are at fixed
  commits. Do not update them without explicit instruction.
- **One app, one directory.** Each `apps/<name>/` is a self-contained Zephyr
  application with its own `CMakeLists.txt`, `prj.conf`, and optionally
  `sysbuild.conf`.
- **Reusable code lives in `modules/libs/`.** Business logic shared between
  apps goes here, not in `apps/`.
- **Build outputs go to `out/`.** Never commit the `out/` tree.

## Adding a new app

1. Create `apps/<name>/CMakeLists.txt`, `prj.conf`.
2. Add `sysbuild.conf` if MCUboot is needed.
3. Build with `scripts/build.sh --app apps/<name> --board <board>`.
4. If reusing node_mgr: `add_subdirectory(../../modules/libs/node_mgr node_mgr_build)`
   in the app's CMakeLists.txt.

## Two build paths (symlink)

`out/` and `/home/chalos/ext/mx500/nn_project_nowest/out/` are the same
directory — the project root is symlinked. Always use the full path
`/home/chalos/ext/mx500/nn_project_nowest/out/...` when passing to CMake;
do not mix the two path forms in one command.
