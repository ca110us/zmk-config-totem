/*
 * Slows the link to the right half while the keyboard is idle.
 *
 * The left half is the BLE central of the split link, so it has to wake for every
 * connection event even when the right half has nothing to send. That is most of the
 * extra drain on the left half. While ZMK reports the keyboard as idle (no key
 * pressed for CONFIG_ZMK_IDLE_TIMEOUT), the link runs at a longer interval; the
 * first key press switches it straight back to ZMK's normal interval.
 *
 * The host can turn this on or off through a small GATT service, and the choice is
 * kept in the settings storage.
 *
 * SPDX-License-Identifier: MIT
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/settings/settings.h>
#include <zephyr/logging/log.h>

#include <zmk/activity.h>
#include <zmk/event_manager.h>
#include <zmk/events/activity_state_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

// The supervision timeout must outlast (1 + latency) connection intervals, twice over
BUILD_ASSERT(CONFIG_ZMK_SPLIT_BLE_PREF_TIMEOUT * 10 >
                 (1 + CONFIG_ZMK_SPLIT_BLE_PREF_LATENCY) * CONFIG_TOTEM_IDLE_POWER_SAVING_INTERVAL *
                     5 / 4 * 2,
             "CONFIG_TOTEM_IDLE_POWER_SAVING_INTERVAL is too long for the split link timeout");

#define POWER_SAVING_SERVICE_UUID                                                                  \
    BT_UUID_128_ENCODE(0x8fc697bd, 0x5c61, 0x4712, 0x86dd, 0x75b98ef03b7a)
#define POWER_SAVING_ENABLED_UUID                                                                  \
    BT_UUID_128_ENCODE(0x8fc697be, 0x5c61, 0x4712, 0x86dd, 0x75b98ef03b7a)

#define SETTINGS_SUBTREE "totem"
#define SETTINGS_NAME "idle_power_saving"

// Wait for ZMK to finish setting up a new split link before slowing it down
#define NEW_LINK_DELAY K_SECONDS(10)

static bool enabled = true;

static void apply_interval(struct k_work *work);
static void save_enabled(struct k_work *work);

static K_WORK_DELAYABLE_DEFINE(apply_work, apply_interval);
static K_WORK_DEFINE(save_work, save_enabled);

static void update_split_conn(struct bt_conn *conn, void *data) {
    const struct bt_le_conn_param *param = data;
    struct bt_conn_info info;

    // The left half is the central only on the split link; host links use the peripheral role
    if (bt_conn_get_info(conn, &info) != 0 || info.role != BT_CONN_ROLE_CENTRAL ||
        info.le.interval == param->interval_min) {
        return;
    }

    int err = bt_conn_le_param_update(conn, param);
    if (err) {
        LOG_WRN("Failed to update split link interval (err %d)", err);
    } else {
        LOG_DBG("Split link interval %d -> %d", info.le.interval, param->interval_min);
    }
}

static void apply_interval(struct k_work *work) {
    bool slow = enabled && zmk_activity_get_state() != ZMK_ACTIVITY_ACTIVE;
    uint16_t interval =
        slow ? CONFIG_TOTEM_IDLE_POWER_SAVING_INTERVAL : CONFIG_ZMK_SPLIT_BLE_PREF_INT;
    struct bt_le_conn_param param =
        BT_LE_CONN_PARAM_INIT(interval, interval, CONFIG_ZMK_SPLIT_BLE_PREF_LATENCY,
                              CONFIG_ZMK_SPLIT_BLE_PREF_TIMEOUT);

    bt_conn_foreach(BT_CONN_TYPE_LE, update_split_conn, &param);
}

static void save_enabled(struct k_work *work) {
    uint8_t value = enabled;
    int err = settings_save_one(SETTINGS_SUBTREE "/" SETTINGS_NAME, &value, sizeof(value));
    if (err) {
        LOG_WRN("Failed to save idle power saving setting (err %d)", err);
    }
}

static int activity_listener(const zmk_event_t *eh) {
    k_work_reschedule(&apply_work, K_NO_WAIT);
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(totem_idle_power_saving, activity_listener);
ZMK_SUBSCRIPTION(totem_idle_power_saving, zmk_activity_state_changed);

static void on_connected(struct bt_conn *conn, uint8_t err) {
    struct bt_conn_info info;

    // A split link that comes up while the keyboard is idle starts at the normal interval
    if (!err && bt_conn_get_info(conn, &info) == 0 && info.role == BT_CONN_ROLE_CENTRAL) {
        k_work_reschedule(&apply_work, NEW_LINK_DELAY);
    }
}

BT_CONN_CB_DEFINE(idle_power_saving_conn_callbacks) = {
    .connected = on_connected,
};

static ssize_t read_enabled(struct bt_conn *conn, const struct bt_gatt_attr *attr, void *buf,
                            uint16_t len, uint16_t offset) {
    uint8_t value = enabled;
    return bt_gatt_attr_read(conn, attr, buf, len, offset, &value, sizeof(value));
}

static ssize_t write_enabled(struct bt_conn *conn, const struct bt_gatt_attr *attr,
                             const void *buf, uint16_t len, uint16_t offset, uint8_t flags) {
    if (offset != 0) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_OFFSET);
    }
    if (len != 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t value = *(const uint8_t *)buf;
    if (value > 1) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }

    enabled = value;
    LOG_DBG("Idle power saving %s", enabled ? "enabled" : "disabled");
    k_work_submit(&save_work);
    k_work_reschedule(&apply_work, K_NO_WAIT);
    return len;
}

// Encrypted access only, so just a bonded host can read or change it
BT_GATT_SERVICE_DEFINE(totem_power_saving_svc,
                       BT_GATT_PRIMARY_SERVICE(BT_UUID_DECLARE_128(POWER_SAVING_SERVICE_UUID)),
                       BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(POWER_SAVING_ENABLED_UUID),
                                              BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
                                              BT_GATT_PERM_READ_ENCRYPT |
                                                  BT_GATT_PERM_WRITE_ENCRYPT,
                                              read_enabled, write_enabled, NULL),
                       BT_GATT_CUD("Power saving when idle", BT_GATT_PERM_READ));

static int settings_set(const char *name, size_t len, settings_read_cb read_cb, void *cb_arg) {
    const char *next;

    if (!settings_name_steq(name, SETTINGS_NAME, &next) || next) {
        return -ENOENT;
    }
    if (len != sizeof(uint8_t)) {
        return -EINVAL;
    }

    uint8_t value;
    int rc = read_cb(cb_arg, &value, sizeof(value));
    if (rc < 0) {
        return rc;
    }

    enabled = value != 0;
    return 0;
}

SETTINGS_STATIC_HANDLER_DEFINE(totem_idle_power_saving, SETTINGS_SUBTREE, NULL, settings_set,
                               NULL, NULL);
