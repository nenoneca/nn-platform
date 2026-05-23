# Zephyr Patterns Used in This Project

## Build system — no west

This project does **not** use `west build` or `west flash`. Everything goes
through direct CMake/Ninja invocation via `scripts/build.sh`.

Do not suggest `west build`, `west flash`, or `west update` — they will fail
with "unknown command" because there is no west workspace manifest.

## Sysbuild (MCUboot + app)

When `apps/<name>/sysbuild.conf` exists, the build enters sysbuild mode.
Sysbuild builds MCUboot and the application as separate images, then signs
the app image with `imgtool`.

```
sysbuild.conf:
  SB_CONFIG_BOOTLOADER_MCUBOOT=y
  SB_CONFIG_MCUBOOT_MODE_OVERWRITE_ONLY=y
```

The signed binary lands at `out/<app>/<board>/ble_ot_esp32c6/zephyr/zephyr.signed.bin`.

## zephyr_library() gotcha

`zephyr_library()` called inside an `add_subdirectory()` from the **app's**
`CMakeLists.txt` does **not** automatically appear in the final linker command.
The library archive is compiled but the symbols are never linked → `undefined reference`.

**Correct pattern for in-project libraries:**

```cmake
# modules/libs/my_lib/CMakeLists.txt
target_sources(app PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foo.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/bar.c
)
target_include_directories(app PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)
```

```cmake
# apps/my_app/CMakeLists.txt
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(my_app)

add_subdirectory(../../modules/libs/my_lib my_lib_build)
target_sources(app PRIVATE src/main.c)
```

## SYS_INIT — startup hooks

```c
static int my_init(void) { ... return 0; }
SYS_INIT(my_init, POST_KERNEL, 75);
// Levels: PRE_KERNEL_1, PRE_KERNEL_2, POST_KERNEL, APPLICATION
// Priority: lower number = earlier execution within the same level
```

Used in `network_manager.c` to call `esp_phy_enable(PHY_MODEM_BT)` at
POST_KERNEL priority 75, before the 802.15.4 driver at priority 80.

## k_work — async work items

```c
static struct k_work my_work;

static void my_work_handler(struct k_work *work) { /* runs in system workqueue */ }

// Init once (e.g. in start function):
k_work_init(&my_work, my_work_handler);

// Submit from any context (ISR, BT RX thread, etc.):
k_work_submit(&my_work);
```

Used to decouple the GATT write callback (BT RX thread) from `nm_thread_apply_dataset()`
which acquires the OT mutex. Doing both in the same thread deadlocks.

## Semaphores for callback synchronisation

```c
static K_SEM_DEFINE(my_sem, 0, 1);

// In callback:
k_sem_give(&my_sem);

// In caller thread:
if (k_sem_take(&my_sem, K_MSEC(timeout_ms)) != 0) {
    // timed out
}

// Reset before reuse:
k_sem_reset(&my_sem);
```

Pattern used throughout `provision_central.c` to synchronise:
`connected_sem`, `mtu_sem`, `discovery_sem`, `write_sem`, `read_sem`, `prov_result_sem`.

## BT_CONN_CB_DEFINE — connection callbacks

```c
BT_CONN_CB_DEFINE(my_conn_cb) = {
    .connected    = my_connected_cb,
    .disconnected = my_disconnected_cb,
};
```

Each translation unit can define one set of connection callbacks.
Names must be unique across the whole build — use descriptive prefixes
(`periph_conn_cb`, `central_conn_cb`).

## SETTINGS_STATIC_HANDLER_DEFINE — persist data to NVS

```c
static int my_settings_set(const char *name, size_t len,
                            settings_read_cb read_cb, void *cb_arg)
{
    if (!strcmp(name, "key")) {
        uint8_t val;
        read_cb(cb_arg, &val, sizeof(val));
        // use val
    }
    return 0;
}
SETTINGS_STATIC_HANDLER_DEFINE(my_module, "my_module", NULL,
                                my_settings_set, NULL, NULL);

// Save:
settings_save_one("my_module/key", &val, sizeof(val));
```

Requires `CONFIG_SETTINGS=y` and `CONFIG_SETTINGS_NVS=y`.

## openthread_mutex_lock / unlock

All OpenThread API calls must be protected by the OT mutex:

```c
openthread_mutex_lock();
otError err = otThreadSetEnabled(get_inst(), true);
openthread_mutex_unlock();
```

`openthread_get_default_instance()` returns the singleton OT instance.
Never call OT APIs from an ISR.

## GATT service definition

```c
BT_GATT_SERVICE_DEFINE(my_svc,
    BT_GATT_PRIMARY_SERVICE(&uuid_svc),
    BT_GATT_CHARACTERISTIC(&uuid_char.uuid,
                           BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                           BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
                           read_cb, write_cb, NULL),
    BT_GATT_CCC(ccc_changed_cb, BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);
```

Attribute array layout: `attrs[0]`=service, `attrs[1]`=char decl, `attrs[2]`=char value,
`attrs[3]`=next char decl, `attrs[4]`=next char value, `attrs[5]`=CCC.
Use `attrs[4]` when notifying the status characteristic.

## Logging

```c
LOG_MODULE_REGISTER(my_module, LOG_LEVEL_INF);

LOG_INF("message: %d", value);
LOG_WRN("warning: %s", str);
LOG_ERR("error: %d", err);
```

Log level for subsystems is set in `prj.conf`:
```kconfig
CONFIG_BT_LOG_LEVEL_INF=y
CONFIG_OPENTHREAD_L2_LOG_LEVEL_WRN=y
```

## Common errno values used in this codebase

| errno | Meaning in context |
|---|---|
| `-ETIMEDOUT` | Scan, connection, or wait timed out |
| `-ENODATA` | ATT READ_NOT_PERMITTED — joiner has no dataset (readback_len == 0) |
| `-ENODEV` | No device found after scan |
| `-ECONNREFUSED` | Connection established then immediately dropped |
| `-EIO` | OT API returned a non-NONE error |
| `-EINVAL` | Null pointer or bad length passed to an API |
