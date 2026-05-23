# ESP32-C6 Hardware Knowledge

## Chip overview

| Property | Value |
|---|---|
| Architecture | RISC-V single-core (HP core, 160 MHz) |
| Radio | Single RF front-end shared by **BLE 5.3** and **IEEE 802.15.4** (Thread/Zigbee) |
| Flash | 8 MB (external SPI, DIO mode, 80 MHz) |
| RAM | ~512 KB total; ~320 KB usable after Zephyr + OT stack |
| Board target | `esp32c6_devkitc/esp32c6/hpcore` |
| Serial ports | Two CDC-ACM ports per board (`ttyACM0/1`, `ttyACM2/3`, `ttyACM4/5`) |
| Bootloader | MCUboot (sysbuild), image slot at `0x20000` |

## Critical constraint: shared RF front-end

**BLE and 802.15.4 cannot transmit or receive simultaneously without coexistence arbitration.**

The ESP32-C6 has one antenna and one RF transceiver. When 802.15.4 holds the
radio (e.g. in continuous RX mode), BLE scans receive zero advertising reports
and BLE connections fail silently.

### What happens at boot (without the fix)

1. Zephyr's `net_if_post_init()` auto-starts all network interfaces.
2. For the 802.15.4 interface: `esp32_start()` → `esp_ieee802154_receive()`.
3. 802.15.4 MAC enters continuous RX — it holds the RF hardware.
4. Any BLE scan started afterwards gets zero results.

### The fix used in this project

```
nm_ble_acquire_rf()
  └── esp_ieee802154_disable()   ← fully releases PHY, not just sleep
       g_radio_disabled = true

Thread start path (nm_thread_create_network / nm_thread_start / nm_thread_apply_dataset)
  └── maybe_wake_radio()
        └── esp_ieee802154_enable()   ← re-initialises MAC + ISR
             g_radio_disabled = false
```

**Rule:** Call `nm_ble_acquire_rf()` before every BLE scan or advertising start.
The Thread start functions in `network_manager` call `maybe_wake_radio()` internally —
the app does not need to do this manually.

### `esp_ieee802154_sleep()` is NOT sufficient

`IEEE802154_RF_DISABLE()` is a no-op macro in Zephyr unless
`SOC_PM_MODEM_RETENTION_BY_REGDMA + FREERTOS_USE_TICKLESS_IDLE` are both enabled.
**Always use `esp_ieee802154_disable()` / `esp_ieee802154_enable()`.**

## PHY calibration order

`esp_phy_load_cal_and_init()` runs only for the first caller (modem_flag == 0).
The second caller gets only `phy_wakeup_init` — a partial initialisation.

To ensure BLE gets full calibration, `network_manager.c` installs a
`SYS_INIT` hook at `POST_KERNEL` priority **75** that calls
`esp_phy_enable(PHY_MODEM_BT)` before the 802.15.4 driver initialises
at priority **80**.

```c
SYS_INIT(phy_ble_first_caller_init, POST_KERNEL, 75);
// priority 75 < IEEE802154_ESP32_INIT_PRIO (80)
```

## Software coexistence (`CONFIG_ESP32_SW_COEXIST_ENABLE`)

This project sets `CONFIG_ESP32_SW_COEXIST_ENABLE=n` deliberately.

SW coex enables a hardware arbiter that multiplexes BLE and 802.15.4 on the
shared RF. It requires careful PTI (packet traffic indication) management and
adds latency. The simpler approach used here is to **never run both radios at the
same time**: disable 802.15.4 for BLE operations, re-enable before Thread.

If SW coex is ever re-enabled, the `coex_set_idle()` function in
`network_manager.c` sets `IEEE802154_IDLE` PTI after `bt_enable()` so the
arbiter grants the radio to BLE while Thread is inactive.

## `CONFIG_OPENTHREAD_MANUAL_START=y`

Without this, OT reads stored state (otThread/otIp6 enabled flags) from NVS at
boot and tries to start the Thread stack before `esp_ieee802154_enable()` has
been called. This causes TX timeout floods on the disabled radio.

Always keep `OPENTHREAD_MANUAL_START=y` in `prj.conf` for this board.

## ISR slot management

`esp_ieee802154_dev.c` originally called `esp_intr_disable()` in
`ieee802154_mac_deinit()`. This marks the interrupt disabled but does **not**
free the slot. On the second call to `esp_ieee802154_enable()` the slot
allocation fails and the radio never initialises.

**Fix (already applied in the local hal_espressif):** `ieee802154_mac_deinit()`
calls `esp_intr_free()` with a NULL guard. If you pull a new hal_espressif,
verify this fix is present.

## Memory layout (sysbuild / MCUboot)

| Region | Address | Notes |
|---|---|---|
| MCUboot bootloader | `0x000000` | ~40 KB |
| Application slot 0 | `0x020000` | Primary slot (running image) |
| Application slot 1 | `0x0A0000` | Update slot (OTA target) |
| NVS / settings | end of flash | OT dataset, BLE prov flag |

Flash parameters: `--flash_mode dio --flash_freq 80m --flash_size 8MB`

## Zephyr SDK version

`zephyr-sdk-0.17.0` at `~/zephyr-sdk-0.17.0`.
RISC-V toolchain: `riscv64-zephyr-elf`.
