# BLE + OpenThread Provisioning App

**App:** `apps/ble_ot_esp32c6/`
**Board:** `esp32c6_devkitc/esp32c6/hpcore`
**Library:** `modules/libs/node_mgr/` (see `library_node_mgr.md`)

## Purpose

Three ESP32-C6 boards share a Thread network. Because Thread requires an
"active dataset" (network credentials), a BLE-based provisioning protocol
distributes that dataset to nodes that don't have it yet.

## Three-node architecture

```
Node 1 (Leader)          Node 3 (Broker)          Node 2 (Joiner)
────────────────         ────────────────         ────────────────
Thread leader            BLE only                 Thread joiner
BLE peripheral           BLE central              BLE peripheral
  (exposes dataset)        (fetch + push)           (receives dataset)

Shell: ble_ot start_leader   ble_ot start_broker   ble_ot start_joiner
```

## Shell commands

All nodes run the same firmware. Role is selected at runtime.

```
ble_ot start_leader   Create Thread network; expose dataset via BLE
ble_ot start_joiner   Join Thread (BLE provisioning if no stored dataset)
ble_ot start_broker   Fetch dataset from leader; push to all joiners
ble_ot status         Show Thread role, provisioned flag, NM ready
ble_ot reset          Clear provisioned flag; stop Thread
```

## End-to-end provisioning sequence

```
Node 1                        Node 3 (or host PC)           Node 2
──────                        ──────────────────            ──────
ble_ot start_leader
  nm_thread_create_network()
  → Thread starts, role=leader
  nm_thread_get_dataset()     ble_ot start_broker           ble_ot start_joiner
  prov_set_leader_dataset()     prov_central_fetch()          nm_ble_acquire_rf()
  prov_peripheral_start()         scan → find OT-Node           prov_peripheral_start()
  [advertising]                   connect to leader             [advertising]
  [GATT read: dataset char]←──────READ dataset char
  [110 bytes returned]──────────→ store tlvs[]
                                  prov_central_push()
                                    scan → find OT-Node
                                    (leader excluded)
                                    connect to joiner
                                    subscribe STATUS notify
                                    WRITE dataset char ──────→ [write callback]
                                                                 k_work_submit()
                                                                 apply_dataset_work:
                                                                   NOTIFY APPLYING
                                                                   nm_thread_apply_dataset()
                                                                   NOTIFY SUCCESS ←── emit
                                    recv STATUS=SUCCESS
                                                                 nm_thread_wait_for_role(CHILD)
                                                                 → Thread joined (~50 s)
```

## Host PC as broker (`provision_host.py`)

Replaces Node 3 entirely. Requires a Bluetooth adapter on the host PC.

```bash
cd apps/ble_ot_esp32c6
python3 provision_host.py \
    --leader /dev/ttyACM0 \
    --joiners /dev/ttyACM2 /dev/ttyACM4
```

The script:
1. Reboots all nodes via serial (`kernel reboot cold`).
2. Clears stale NVS flags (`ble_ot reset`).
3. Starts Node 1 as leader, all others as joiners.
4. Waits for Node 1 to advertise (trigger: `"advertising dataset"`).
5. BLE-scans for `PROV_SVC_UUID`; probes each device to find the leader.
6. Provisions every joiner found.
7. Waits for joiners to confirm Thread role via serial.

**Key args:**
- `--ble-only` — skip serial phase (nodes already running)
- `--scan-time 12` — BLE scan duration per pass (seconds)
- `--prov-timeout 30` — seconds to wait for STATUS_SUCCESS per joiner

**bleak version:** `0.12.1`. RSSI is on `BLEDevice`, not `AdvertisementData`.
Pattern: `getattr(adv, "rssi", None) or getattr(device, "rssi", "?")`.

## OpenThread concepts

| Term | Meaning |
|---|---|
| Active Dataset | Network credentials: PAN ID, channel, master key, network name, extended PAN ID |
| TLV format | Dataset encoded as type-length-value blob (≤254 bytes) |
| Leader | The node that manages the network topology database |
| Router | Forwards packets; can become leader |
| Child (End Device) | Attached to a router; does not route |
| FTD | Full Thread Device — can become router or leader |
| MTD | Minimal Thread Device — stays as child |

This project uses **FTD** (`CONFIG_OPENTHREAD_FTD=y`) so any node can become
leader or router.

## Thread role progression after joining

A freshly provisioned joiner follows this sequence:
1. `DETACHED` — searching for the network
2. `CHILD` — attached to a parent router (~50 s after dataset applied)
3. `ROUTER` or `LEADER` — promoted automatically within a few minutes

`nm_thread_wait_for_role(OT_DEVICE_ROLE_CHILD, 60000)` checks for CHILD.
The post-timeout check also accepts ROUTER/LEADER as success.

## Kconfig highlights (`prj.conf`)

```kconfig
CONFIG_OPENTHREAD_MANUAL_START=y  # Critical — see hardware_esp32c6.md
CONFIG_ESP32_SW_COEXIST_ENABLE=n  # Manual RF management instead
CONFIG_BT_PERIPHERAL=y            # GATT server (dataset expose/receive)
CONFIG_BT_CENTRAL=y               # GATT client (broker fetch/push)
CONFIG_BT_GATT_CLIENT=y
CONFIG_BT_MAX_CONN=2
CONFIG_BT_L2CAP_TX_MTU=260        # Enough for 254-byte dataset in one write
CONFIG_BT_BUF_ACL_RX_SIZE=264
CONFIG_BT_ATT_PREPARE_COUNT=4     # For PREPARE_WRITE fragmented writes
CONFIG_SETTINGS_NVS=y             # Persist dataset + provisioning flag
```

## Testing

```bash
# Automated 3-node test (nodes as dedicated roles)
python3 apps/ble_ot_esp32c6/test_3node.py

# Host BLE provisioner (2 joiners, host as broker)
python3 apps/ble_ot_esp32c6/provision_host.py \
    --leader /dev/ttyACM0 --joiners /dev/ttyACM2 /dev/ttyACM4
```

Expected output (provision_host.py success):
```
[host] === ALL NODES PROVISIONED SUCCESSFULLY ===
[host] All joiners confirmed Thread role ✓
Thread role       : leader     ← N1
Thread role       : leader     ← N2 (promoted)
Thread role       : leader     ← N3 (promoted)
BLE provisioned   : yes        ← N2, N3
NM ready          : yes        ← all
```
