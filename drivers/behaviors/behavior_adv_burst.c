/*
 * Advertise for a short time while the active profile stays connected, so tools
 * that only list advertising devices (like Chrome's Web Bluetooth chooser) can
 * find the keyboard.
 *
 * The advertising is non-connectable, so nothing can open a new connection
 * through it and the existing host connection is never touched. ZMK normally
 * owns the single legacy advertising set and only uses it while disconnected;
 * whenever ZMK may need it again (a host connects or disconnects, or the
 * active profile changes), the burst stops and ZMK's advertising is refreshed.
 *
 * SPDX-License-Identifier: MIT
 */

#define DT_DRV_COMPAT totem_behavior_adv_burst

#include <string.h>

#include <zephyr/device.h>
#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/logging/log.h>

#include <drivers/behavior.h>

#include <zmk/behavior.h>
#include <zmk/ble.h>
#include <zmk/event_manager.h>
#include <zmk/events/ble_active_profile_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

#if DT_HAS_COMPAT_STATUS_OKAY(DT_DRV_COMPAT)

// Defined in ZMK's app/src/ble.c; re-evaluates whether ZMK itself should advertise.
int update_advertising(void);

#define BURST_ADV_PARAM                                                                            \
    BT_LE_ADV_PARAM(BT_LE_ADV_OPT_USE_IDENTITY, BT_GAP_ADV_FAST_INT_MIN_2,                        \
                    BT_GAP_ADV_FAST_INT_MAX_2, NULL)

struct behavior_adv_burst_config {
    uint32_t duration_ms;
};

static const struct behavior_adv_burst_config burst_config = {
    .duration_ms = DT_INST_PROP(0, duration_ms),
};

// Only touched from the system work queue, so no locking is needed.
static bool bursting;

static void start_burst(struct k_work *work);
static void stop_burst(struct k_work *work);

static K_WORK_DEFINE(start_work, start_burst);
static K_WORK_DELAYABLE_DEFINE(stop_work, stop_burst);

static void start_burst(struct k_work *work) {
    if (bursting) {
        // Pressing again during a burst restarts the countdown
        k_work_reschedule(&stop_work, K_MSEC(burst_config.duration_ms));
        return;
    }

    if (!zmk_ble_active_profile_is_connected()) {
        // ZMK is already advertising so the host can reconnect; leave it alone
        LOG_DBG("Active profile not connected, skipping advertising burst");
        return;
    }

    // The advertised address must match the existing connection's identity address,
    // so the host recognises this as the device it is already connected to.
    const char *name = bt_get_name();
    const struct bt_data ad[] = {
        BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
        BT_DATA_BYTES(BT_DATA_GAP_APPEARANCE, 0xC1, 0x03),
        BT_DATA_BYTES(BT_DATA_UUID16_SOME, 0x12, 0x18 /* HID */, 0x0f, 0x18 /* Battery */),
        BT_DATA(BT_DATA_NAME_COMPLETE, name, strlen(name)),
    };

    int err = bt_le_adv_start(BURST_ADV_PARAM, ad, ARRAY_SIZE(ad), NULL, 0);
    if (err) {
        LOG_WRN("Failed to start advertising burst (err %d)", err);
        return;
    }

    bursting = true;
    k_work_reschedule(&stop_work, K_MSEC(burst_config.duration_ms));
    LOG_DBG("Advertising burst started for %u ms", burst_config.duration_ms);
}

static void stop_burst(struct k_work *work) {
    if (!bursting) {
        return;
    }

    int err = bt_le_adv_stop();
    if (err) {
        LOG_WRN("Failed to stop advertising burst (err %d)", err);
    }
    bursting = false;
    LOG_DBG("Advertising burst stopped");

    // If ZMK tried to start its own advertising while the burst held the advertising
    // set, that attempt failed; give it another go now that the set is free.
    update_advertising();
}

static void request_stop(void) { k_work_reschedule(&stop_work, K_NO_WAIT); }

static void on_conn_changed(struct bt_conn *conn) {
    struct bt_conn_info info;

    // Only host connections matter; the split link to the right half uses the central role
    if (bt_conn_get_info(conn, &info) == 0 && info.role == BT_CONN_ROLE_PERIPHERAL) {
        request_stop();
    }
}

static void on_connected(struct bt_conn *conn, uint8_t err) { on_conn_changed(conn); }

static void on_disconnected(struct bt_conn *conn, uint8_t reason) { on_conn_changed(conn); }

BT_CONN_CB_DEFINE(adv_burst_conn_callbacks) = {
    .connected = on_connected,
    .disconnected = on_disconnected,
};

static int adv_burst_listener(const zmk_event_t *eh) {
    if (as_zmk_ble_active_profile_changed(eh)) {
        request_stop();
    }
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(behavior_adv_burst, adv_burst_listener);
ZMK_SUBSCRIPTION(behavior_adv_burst, zmk_ble_active_profile_changed);

static int on_keymap_binding_pressed(struct zmk_behavior_binding *binding,
                                     struct zmk_behavior_binding_event event) {
    k_work_submit(&start_work);
    return ZMK_BEHAVIOR_OPAQUE;
}

static int on_keymap_binding_released(struct zmk_behavior_binding *binding,
                                      struct zmk_behavior_binding_event event) {
    return ZMK_BEHAVIOR_OPAQUE;
}

static const struct behavior_driver_api behavior_adv_burst_driver_api = {
    .binding_pressed = on_keymap_binding_pressed,
    .binding_released = on_keymap_binding_released,
    .locality = BEHAVIOR_LOCALITY_CENTRAL,
#if IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
    .get_parameter_metadata = zmk_behavior_get_empty_param_metadata,
#endif // IS_ENABLED(CONFIG_ZMK_BEHAVIOR_METADATA)
};

BEHAVIOR_DT_INST_DEFINE(0, NULL, NULL, NULL, &burst_config, POST_KERNEL,
                        CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, &behavior_adv_burst_driver_api);

#endif /* DT_HAS_COMPAT_STATUS_OKAY(DT_DRV_COMPAT) */
