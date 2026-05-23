# Build and Flash

## Build

```bash
./scripts/build.sh \
  --app apps/<name> \
  --board <board-target> \
  --build-dir out/<name>/<board-slug>
```

### ESP32-C6 example (most common board in this project)

```bash
./scripts/build.sh \
  --app apps/ble_ot_esp32c6 \
  --board esp32c6_devkitc/esp32c6/hpcore \
  --build-dir out/ble_ot_esp32c6/esp32c6_devkitc_esp32c6_hpcore
```

### nRF52840 example

```bash
./scripts/build.sh \
  --app apps/wifi_shell \
  --board nrf52840dk/nrf52840 \
  --build-dir out/wifi_shell/nrf52840dk_nrf52840
```

### Internals

`build.sh` calls CMake directly — no `west build`. It sets:
- `ZEPHYR_BASE` pointing to `third_party/zephyr`
- `ZEPHYR_MODULES` listing all entries under `third_party/` plus `modules/`
- `ZEPHYR_SDK_INSTALL_DIR` auto-detected at `~/zephyr-sdk-0.17.0`

If `sysbuild.conf` exists in the app directory, the script automatically enters
sysbuild mode (MCUboot + signed app built together).

### After a CMakeLists change — always clean

If you change `CMakeLists.txt` (app or library), delete the build directory
before rebuilding. The CMake cache is not invalidated by source-only changes:

```bash
rm -rf out/<name>/<board-slug>
./scripts/build.sh ...
```

## Flash — ESP32-C6

`west flash` is not available. Use `esptool` directly.

### Binaries

| Binary | Path | Flash address |
|---|---|---|
| MCUboot bootloader | `out/<app>/<board>/mcuboot/zephyr/zephyr.bin` | `0x0` |
| Signed application | `out/<app>/<board>/ble_ot_esp32c6/zephyr/zephyr.signed.bin` | `0x20000` |

### Flash command (single board)

```bash
esptool --chip esp32c6 --port /dev/ttyACM0 --baud 921600 \
    --before default_reset --after hard_reset write_flash \
    --flash_mode dio --flash_freq 80m --flash_size 8MB \
    0x0   out/<app>/<board>/mcuboot/zephyr/zephyr.bin \
    0x20000 out/<app>/<board>/ble_ot_esp32c6/zephyr/zephyr.signed.bin
```

### Flash 3 boards in parallel

```bash
flash_board() {
    esptool --chip esp32c6 --port $1 --baud 921600 \
        --before default_reset --after hard_reset write_flash \
        --flash_mode dio --flash_freq 80m --flash_size 8MB \
        0x0 <mcuboot.bin> 0x20000 <app.signed.bin> 2>&1 | tail -4
}
flash_board /dev/ttyACM0 &
flash_board /dev/ttyACM2 &
flash_board /dev/ttyACM4 &
wait
```

Serial ports follow `ttyACM0`, `ttyACM1`, ... for each connected ESP32-C6.
Each board uses two consecutive ports (JTAG + UART); the even port
(`ttyACM0`, `ttyACM2`, `ttyACM4`) is the UART console.

## Flash — nRF52840

```bash
./scripts/flash_nrfjprog.sh --build-dir out/<app>/<board>
```

Uses `nrfjprog` under the hood. Prefers a merged hex when sysbuild produced one.

## Serial console

```bash
picocom -b 115200 /dev/ttyACM0
# or
screen /dev/ttyACM0 115200
```

Shell prompt: `ble_ot:~$`

## Verify build succeeded

A successful ESP32-C6 sysbuild ends with:
```
Successfully created ESP32-C6 image.
[3/6] Completed 'ble_ot_esp32c6'
[6/6] Completed 'mcuboot'
```

Any `undefined reference` at link time means either:
1. A source file was not added to `target_sources(app PRIVATE ...)`.
2. A library's CMakeLists uses `zephyr_library()` but is not linked — switch to
   `target_sources(app PRIVATE ...)` (see `modules/libs/node_mgr/CMakeLists.txt`).
