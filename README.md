# nn-device — Zephyr Firmware for Thread Mesh Nodes

West-free Zephyr layout for ESP32-C6 Thread mesh devices with:
- **BLE provisioning** — hub pushes OT dataset + X25519 keys via GATT
- **ECIES v2 encrypted CoAP** — hub ↔ device messaging (X25519 ECDH + HKDF + AES-256-GCM)
- **OTA firmware updates** — device pulls firmware from hub via CoAP Block2 through Thread Border Router
- **mDNS** — hostname discovery within the Thread mesh
- **Auto-versioning** — `nn_version.cmake` derives version from git commit count

Layout:
- `apps/mdns_ot_esp32c6/` — primary application (Thread mesh + mDNS + CoAP + OTA)
- `modules/libs/node_mgr/` — reusable library (BLE provisioning, hub_crypto, ota_client)
- `modules/cmake/nn_version.cmake` — auto-version from git commit count
- `third_party/` — pinned Zephyr ecosystem

## Initial pinned upstream repos

These revisions were taken from a local Zephyr workspace based on upstream Zephyr `v4.3.0-4357-g4d0852b0051`.

| Path | Upstream | Revision |
| --- | --- | --- |
| `third_party/zephyr` | `https://github.com/zephyrproject-rtos/zephyr` | `4d0852b0051c9b13b59f34bceb0c38148ad12eb1` |
| `third_party/cmsis` | `https://github.com/zephyrproject-rtos/cmsis` | `512cc7e895e8491696b61f7ba8066b4a182569b8` |
| `third_party/cmsis_6` | `https://github.com/zephyrproject-rtos/CMSIS_6` | `30a859f44ef8ab4dc8f84b03ed586fd16ccf9d74` |
| `third_party/hal_nordic` | `https://github.com/zephyrproject-rtos/hal_nordic` | `a83db66acbeca0bfef157a0c3482c07ddbb82555` |
| `third_party/mbedtls` | `https://github.com/zephyrproject-rtos/mbedtls` | `c5b06d89c9c498d8fc8659ce31f7e53137b6270f` |
| `third_party/mcuboot` | `https://github.com/zephyrproject-rtos/mcuboot` | `9ac72969f281491d677e669d053281fc2d538ed4` |

For this Zephyr revision and target, `cmsis`, `cmsis_6`, `hal_nordic`, `mbedtls`, and `mcuboot` are the pinned external repos currently used by the template.

## Bootstrap third-party sources

If you already have a local Zephyr workspace, bootstrap from it:

```bash
./scripts/bootstrap_third_party.sh --source-workspace /media/chalos/mx500/oss/zephyr
```

If you want to clone from GitHub instead:

```bash
./scripts/bootstrap_third_party.sh
```

## Build

The build wrapper avoids `west` commands entirely and computes `ZEPHYR_MODULES` from pinned repos under `third_party/` plus internal modules under `modules/`.

If an application contains `sysbuild.conf`, the wrapper enters Zephyr sysbuild automatically. The current `hello_cpp` app uses this to build MCUboot and the signed application image together.

```bash
./scripts/build.sh
```

Defaults:

- app: `apps/hello_cpp`
- board: `nrf52840dk/nrf52840`
- out dir: `out/hello_cpp/nrf52840dk_nrf52840`

The default `hello_cpp` build includes:

- MCUboot as the bootloader
- overwrite-only MCUboot mode
- a merged hex file containing bootloader plus signed application

You can override the board and build directory:

```bash
./scripts/build.sh --board nrf52840dk/nrf52840 --build-dir out/hello_cpp/custom
```

If `ZEPHYR_SDK_INSTALL_DIR` is not set, the script will try a few common locations under `$HOME`.

The build also needs a Python environment with Zephyr build dependencies such as `pyelftools`. The wrapper will prefer an interpreter that can import `elftools`, checking:

- `$PYTHON_EXECUTABLE`
- `/media/chalos/mx500/oss/zephyr/venv/bin/python`
- `$HOME/.virtualenvs/zephyr/bin/python`
- `python3`

## Flash with nrfjprog

`ninja flash` is not used here because that delegates to `west flash`. Flash the generated hex directly instead:

```bash
./scripts/flash_nrfjprog.sh
```

When a merged sysbuild hex exists, the flash wrapper prefers it. For the current app that means:

```bash
out/hello_cpp/nrf52840dk_nrf52840/merged_nrf52840dk_nrf52840.hex
```

and falls back to the plain application hex when sysbuild is not in use.

The programming command remains:

```bash
nrfjprog --family NRF52 --program <hex> --sectorerase --verify --reset
```

## Reference

- Zephyr docs: https://docs.zephyrproject.org/latest/develop/west/without-west.html
