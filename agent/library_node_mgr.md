# node_mgr Library

**Location:** `modules/libs/node_mgr/`

Reusable library for BLE-based OpenThread provisioning, ECIES v2 hub crypto,
and OTA firmware updates on ESP32-C6.

## Directory layout

```
modules/libs/node_mgr/
├── CMakeLists.txt
├── Kconfig                     ← NODE_MGR + NODE_MGR_HUB_CRYPTO_DEPS (PSA selects)
├── include/node_mgr/
│   ├── init_manager.h
│   ├── network_manager.h
│   ├── provision_manager.h
│   ├── hub_crypto.h            ← ECIES v2 encrypt/decrypt (X25519 + HKDF + AES-GCM)
│   └── ota_client.h            ← OTA check, download (Block2), apply
└── src/
    ├── init_manager.c
    ├── network_manager.c       ← BLE init + OpenThread + RF coex
    ├── provision_peripheral.c  ← BLE GATT server (dataset, hub_config, dev_pubkeys)
    ├── provision_central.c     ← BLE GATT client (scan, fetch, push)
    ├── hub_crypto.c            ← PSA-based ECIES v2 (X25519 ECDH + HKDF-SHA256 + AES-256-GCM)
    └── ota_client.c            ← Device-initiated OTA over plain CoAP Block2
```

## How to include in an app

In the app's `CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(my_app)

add_subdirectory(../../modules/libs/node_mgr node_mgr_build)

target_sources(app PRIVATE src/main.c)
```

**Important:** The library's `CMakeLists.txt` uses `target_sources(app PRIVATE ...)`
(not `zephyr_library()`). This is intentional — `zephyr_library()` from an
app-level `add_subdirectory()` compiles the code but does not register the
library in the Zephyr linker command, causing `undefined reference` at link time.

## API reference

### `network_manager.h`

Handles BLE stack init, RF coexistence, and all OpenThread operations.

```c
int          nm_init(void);
// Call once from main(). Calls bt_enable() + coex setup. Blocks until ready.

bool         nm_is_ready(void);
// True after nm_init() succeeds.

void         nm_ble_acquire_rf(void);
// Disable 802.15.4 to free the shared RF for BLE.
// MUST be called before any BLE scan or advertising.

int          nm_thread_create_network(void);
// Create a new Thread network (random dataset) and start the stack.
// Device will become Leader after ~10 s.

int          nm_thread_start(void);
// Start Thread from a dataset already stored in NVS (rejoin after reboot).

int          nm_thread_apply_dataset(const uint8_t *tlvs, uint8_t len);
// Apply a TLV dataset received over BLE, persist it, and start Thread.
// Called internally by provision_peripheral's k_work handler.

int          nm_thread_get_dataset(uint8_t *out_tlvs, uint8_t *out_len);
// Copy the active dataset as a TLV blob (up to 254 bytes).

otDeviceRole nm_thread_get_role(void);
// Current Thread role: DISABLED, DETACHED, CHILD, ROUTER, LEADER.

int          nm_thread_wait_for_role(otDeviceRole target, uint32_t timeout_ms);
// Block until role reached. Returns 0 or -ETIMEDOUT.

void         nm_thread_stop(void);
// Stop Thread and bring the IPv6 interface down.
```

### `provision_manager.h`

BLE GATT peripheral (dataset server) and central (dataset client).

```c
/* --- Peripheral (Nodes 1 and 2) --- */

void prov_set_leader_dataset(const uint8_t *tlvs, uint8_t len);
// Node 1 only: expose this dataset via the readable GATT characteristic.

int  prov_peripheral_start(void);
// Start advertising "OT-Node" with the OT Provisioning Service UUID.

void prov_peripheral_stop(void);
// Stop advertising.

int  prov_peripheral_wait(uint32_t timeout_ms);
// Block until a dataset has been written and applied. Returns 0 or -ETIMEDOUT.

bool prov_is_provisioned(void);
// True if a dataset was previously received and persisted to flash.

void prov_clear_flag(void);
// Clear the persisted provisioning flag (without stopping Thread).

/* --- Central (Node 3 broker or host PC replacement) --- */

int  prov_central_fetch(uint8_t *out_tlvs, uint8_t *out_len, uint32_t timeout_ms);
// Scan → connect → READ dataset from the leader.
// Automatically excludes joiners that return READ_NOT_PERMITTED.
// After success: carries leader's address to exclude it from the push scan.

int  prov_central_push(const uint8_t *tlvs, uint8_t len, uint32_t timeout_ms);
// Scan → connect → WRITE dataset to a joiner → wait for STATUS_SUCCESS notify.
// g_n_excluded carries the leader's address from fetch — do NOT reset between calls.
```

### `init_manager.h`

Startup policy.

```c
bool im_needs_provisioning(void);
// Returns true  → go through BLE provisioning flow.
// Returns false → call nm_thread_start() to rejoin directly.

void im_clear_provisioning(void);
// Stop Thread + clear persisted provisioning flag.
// After this, im_needs_provisioning() returns true.
```

## GATT service layout

**Service UUID:** `e7f00001-6b3e-4f6b-9232-3e26d0d5a2f0`

| Attr index | Type | UUID suffix | Properties | Purpose |
|---|---|---|---|---|
| attrs[0] | Primary service declaration | `...0001` | — | Service |
| attrs[1-2] | Dataset characteristic | `...0002` | READ \| WRITE | OT dataset TLV blob |
| attrs[3-5] | Status characteristic + CCC | `...0003` | READ \| NOTIFY | Provisioning status |
| attrs[6-7] | Hub Config characteristic | `...0004` | WRITE | `[1B name_len][name][32B hub X25519 pub]` |
| attrs[8-9] | Device Pubkeys characteristic | `...0005` | READ | 32 bytes: device X25519 public key |

Notify uses `bt_gatt_notify(conn, &ot_prov_svc.attrs[4], ...)`.

### Hub Config wire format (WRITE to `...0004`)
```
[1 byte]  name_len
[N bytes] device name (UTF-8, max 32)
[32 bytes] hub X25519 public key
```

### Device Pubkeys wire format (READ from `...0005`)
```
[32 bytes] device X25519 public key
```

## Status values (peripheral → central notify)

| Value | Meaning |
|---|---|
| `0x00` | IDLE |
| `0x01` | APPLYING (dataset write received, Thread start in progress) |
| `0x02` | SUCCESS |
| `0x03` | ERROR |

### `hub_crypto.h`

ECIES v2 envelope encrypt/decrypt using PSA Crypto.

```c
int  hub_crypto_init(void);
// Load/generate device X25519 key pair from NVS. Call after settings_load().

void hub_crypto_get_device_x25519_pub(uint8_t out[32]);
// Copy device X25519 public key into out.

int  hub_crypto_set_hub_pubkey(const uint8_t hub_x25519_pub[32]);
// Store hub X25519 public key in NVS (received via BLE HUB_CONFIG_CHAR).

int  hub_crypto_decrypt(char *json_in, uint8_t *plain_out, size_t *plain_len);
// Decrypt ECIES v2 JSON envelope from hub (h2d direction).

int  hub_crypto_encrypt(const uint8_t *plain, size_t plain_len,
                        char *json_out, size_t json_cap);
// Encrypt plaintext into ECIES v2 JSON envelope for hub (d2h direction).
```

**Protocol v2 key derivation:**
```
shared_e = ECDH(ephem_priv, peer_static_pub)
shared_s = ECDH(own_static_priv, peer_static_pub)
aes_key  = HKDF-SHA256(shared_e || shared_s, salt=epk, info=direction_tag)
  h2d: info = "nn-hub-v2-h2d"
  d2h: info = "nn-hub-v2-d2h"
```

**Envelope JSON:** `{"v":2,"epk":"<b64>","nonce":"<b64>","ct":"<b64>"}`

### `ota_client.h`

Device-initiated OTA over plain CoAP (no ECIES).

```c
int  ota_client_init(void);
// Load hub addr and auto-apply from NVS.

int  ota_client_set_hub_addr(const char *addr);
// Set hub CoAP IPv6 address (persisted to NVS).

int  ota_client_check(void);
// POST /ota/check to hub. Returns 1=update available, 0=up-to-date, <0=error.

int  ota_client_download(void);
// GET /ota/image via CoAP Block2 → flash_img_buffered_write(slot1).

int  ota_client_apply(void);
// boot_request_upgrade(PERMANENT) + sys_reboot(). Does not return.

void ota_client_set_auto_apply(bool enable);
bool ota_client_get_auto_apply(void);
// Auto-apply policy (persisted in NVS). When on: download → reboot automatically.
```

**OTA flow:** check → download (~4 KB/s over Thread) → apply → MCUboot overwrites slot0.

## NVS settings keys

| Key | Size | Description |
|---|---|---|
| `ble_prov/done` | 1 B | Provisioning flag (0 or 1) |
| `hub_prov/name` | ≤33 B | Hub-provisioned device name |
| `mesh_app/name` | ≤33 B | Application device name (mDNS hostname) |
| `hub_crypto/dev_x25519_priv` | 32 B | Device X25519 private key |
| `hub_crypto/hub_x25519_pub` | 32 B | Hub X25519 public key |
| `ota/hub_addr` | ≤46 B | Hub CoAP IPv6 address for OTA |
| `ota/auto_apply` | 1 B | Auto-apply policy (bool) |

OT dataset is persisted automatically by `otDatasetSetActiveTlvs()` via the
OT NVS back-end.

## Threading model

- **GATT write callback** runs in the BT RX thread. It must not call
  `nm_thread_apply_dataset()` directly (acquires OT mutex + starts Thread
  while BLE TX is pending → crash).
- **Fix:** `apply_work` (`struct k_work`) is submitted from the write callback.
  `apply_dataset_work_handler()` runs in the system work queue thread.

## Advertising restart on disconnect

Zephyr stops advertising when a connection is accepted. If the broker
disconnects before delivering the dataset (e.g. during a fetch-retry probe),
the node must restart advertising. The `disconnected()` callback in
`provision_peripheral.c` does this:

```c
if (g_adv_started && !g_provisioned) {
    bt_le_adv_start(&g_adv_param, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
}
```
