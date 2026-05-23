# Known Issues and Root Causes

Hard-won debugging knowledge. Read before investigating any new failure.

---

## 1. BLE scan returns zero results

**Symptom:** `bt_le_scan_start()` succeeds but `scan_cb()` is never called,
or is called only for non-matching devices.

**Root cause:** 802.15.4 radio is holding the shared RF front-end.
`net_if_post_init()` puts the 802.15.4 MAC into continuous RX at boot.

**Fix:** Call `nm_ble_acquire_rf()` before every scan or advertising start.
Internally: `esp_ieee802154_disable()`. This truly releases the PHY.

**Wrong fix:** `esp_ieee802154_sleep()` — does NOT release the RF on this chip.
`IEEE802154_RF_DISABLE()` is a no-op macro without `SOC_PM_MODEM_RETENTION_BY_REGDMA`.

---

## 2. Second `esp_ieee802154_enable()` fails silently

**Symptom:** After one disable/enable cycle, Thread works. After the second
disable/enable (e.g. BLE provisioning → Thread join → BLE provisioning again),
the radio never initialises. No error is returned; Thread just never attaches.

**Root cause:** `ieee802154_mac_deinit()` in `esp_ieee802154_dev.c` called
`esp_intr_disable()` instead of `esp_intr_free()`. The ISR slot remained
allocated. The next call to `esp_ieee802154_enable()` tried to allocate the
same slot and failed.

**Fix:** Changed to `esp_intr_free(handle); handle = NULL;` with a NULL guard.
Applied to the local `third_party/hal_espressif`. If you pull a new
hal_espressif, re-apply this patch.

---

## 3. Crash in bt_tx_processor when applying dataset

**Symptom:** Fault or hang shortly after a joiner receives the dataset over BLE.

**Root cause:** The GATT write callback (`write_dataset_cb`) called
`nm_thread_apply_dataset()` directly. That function acquires the OT mutex and
starts Thread while the BT TX thread is pending, causing a deadlock or
stack overflow.

**Fix:** `write_dataset_cb` submits a `k_work` item. The actual apply runs
in the system workqueue thread, after the BLE write completes.

---

## 4. Broker connects to joiner instead of leader

**Symptom:** `prov_central_fetch()` returns `-ENODATA` (ATT error 0x02,
`BT_ATT_ERR_READ_NOT_PERMITTED`). The dataset is never obtained.

**Root cause:** Both Node 1 (leader) and Node 2 (joiner) advertise the same
service UUID. The broker scanned and happened to find Node 2 first.
Node 2's `read_dataset_cb` returns `BT_GATT_ERR(BT_ATT_ERR_READ_NOT_PERMITTED)`
because `readback_len == 0` (joiner has no dataset to expose).

**Fix:** `prov_central_fetch()` retry loop — on `-ENODATA`, add the device
address to `g_excluded[]` and scan again. After success, the leader's address
replaces the exclusion list so the push scan skips it.

---

## 5. Joiner stops advertising after broker probe

**Symptom:** After the broker's fetch-retry probe connects to and disconnects
from Node 2, Node 2 is no longer visible in subsequent scans.

**Root cause:** Zephyr's BLE stack automatically stops advertising when an
incoming connection is accepted. On disconnect, advertising is not restarted.

**Fix:** `disconnected()` callback in `provision_peripheral.c` calls
`bt_le_adv_start()` when `g_adv_started && !g_provisioned`.

---

## 6. Thread join timeout — node never reaches CHILD role

**Symptom:** `nm_thread_wait_for_role(OT_DEVICE_ROLE_CHILD, timeout)` returns
`-ETIMEDOUT`. Node is actually joining but slower than expected.

**Root cause:** Thread join on ESP32-C6 takes up to ~50 seconds in practice
depending on network conditions. Earlier code used 20 s timeout.

**Fix:** Timeout is 60 000 ms. Post-timeout check: if role is ROUTER or LEADER,
treat as success (nodes with FTD firmware can be promoted before CHILD is stable).

---

## 7. TX timeout floods on Node 1 after Thread start

**Symptom:** Serial console floods with TX timeout messages on Node 1 after
Thread is running.

**Root cause:** Not fully investigated. Likely related to OT trying to transmit
on the 802.15.4 radio before it has stabilised, or a coexistence timing issue.

**Status:** Known / not yet resolved. Does not prevent Thread network operation.

---

## 8. `CONFIG_OPENTHREAD_MANUAL_START` must be set

**Symptom:** TX timeout floods immediately at boot, before any shell command.

**Root cause:** Without `CONFIG_OPENTHREAD_MANUAL_START=y`, Zephyr's OT
integration restores the `otThread` and `otIp6` enabled state from NVS at boot.
If the 802.15.4 radio is not yet enabled (disabled for BLE first-caller PHY
init), every TX attempt times out.

**Fix:** `CONFIG_OPENTHREAD_MANUAL_START=y` in `prj.conf`. Never remove it.

---

## 9. zephyr_library() not linked from app add_subdirectory

**Symptom:** Build succeeds, all `.c` files compiled, `.a` archive created
in build dir — but linker reports `undefined reference` for all library symbols.

**Root cause:** `zephyr_library()` appends to the `ZEPHYR_LIBS` CMake global
property. When called from an `add_subdirectory()` within the app's
`CMakeLists.txt` (not from the Zephyr module tree), this append does not reach
the Zephyr linker command generator at the right time.

**Fix:** Use `target_sources(app PRIVATE ...)` + `target_include_directories(app PRIVATE ...)`
in the library's `CMakeLists.txt`. Sources compile directly into `app/libapp.a`.
See `modules/libs/node_mgr/CMakeLists.txt`.

---

## 10. bleak 0.12.1 — RSSI on BLEDevice, not AdvertisementData

**Symptom:** `AttributeError: 'AdvertisementData' object has no attribute 'rssi'`
in `provision_host.py`.

**Root cause:** bleak moved `rssi` from `BLEDevice` to `AdvertisementData` in
version 0.14. The host has bleak 0.12.1.

**Fix:**
```python
rssi = getattr(adv, "rssi", None) or getattr(device, "rssi", "?")
```

---

## Debugging checklist for new failures

1. **BLE scan issues** → Is `nm_ble_acquire_rf()` called before the scan?
2. **Thread not starting** → Is `nm_thread_wait_for_role()` timeout ≥ 60 s?
   Check for ROUTER/LEADER as alternative success states.
3. **Second provisioning cycle fails** → Is `esp_intr_free()` fix in hal_espressif?
4. **Undefined symbols at link** → Is the library using `target_sources(app ...)`?
5. **Crash after BLE write** → Is the dataset apply deferred via `k_work`?
6. **TX timeouts at boot** → Is `CONFIG_OPENTHREAD_MANUAL_START=y`?
