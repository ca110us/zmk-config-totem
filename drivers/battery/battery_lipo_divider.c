/*
 * Voltage divider battery driver for LiPo cells, based on ZMK's
 * zmk,battery-voltage-divider. Instead of ZMK's straight line between
 * 3.45V and 4.2V, the state of charge comes from a LiPo discharge curve,
 * and each board's readings can be scaled to correct its measurement error.
 *
 * SPDX-License-Identifier: MIT
 */

#define DT_DRV_COMPAT totem_battery_lipo_divider

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/logging/log.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

struct curve_point {
    uint16_t mv;
    uint8_t pct;
};

// Typical 3.7V LiPo resting voltage curve, highest voltage first.
static const struct curve_point lipo_curve[] = {
    {4200, 100}, {4150, 95}, {4110, 90}, {4080, 85}, {4020, 80}, {3980, 75}, {3950, 70},
    {3910, 65},  {3870, 60}, {3850, 55}, {3840, 50}, {3820, 45}, {3800, 40}, {3790, 35},
    {3770, 30},  {3750, 25}, {3730, 20}, {3710, 15}, {3690, 10}, {3610, 5},  {3270, 0},
};

static uint8_t lipo_mv_to_pct(uint16_t mv) {
    if (mv >= lipo_curve[0].mv) {
        return 100;
    }

    for (size_t i = 1; i < ARRAY_SIZE(lipo_curve); i++) {
        const struct curve_point *hi = &lipo_curve[i - 1];
        const struct curve_point *lo = &lipo_curve[i];

        if (mv >= lo->mv) {
            // Linear interpolation between the two neighbouring points
            return lo->pct + (mv - lo->mv) * (hi->pct - lo->pct) / (hi->mv - lo->mv);
        }
    }

    return 0;
}

struct io_channel_config {
    uint8_t channel;
};

struct bld_config {
    struct io_channel_config io_channel;
    struct gpio_dt_spec power;
    uint32_t output_ohm;
    uint32_t full_ohm;
    uint16_t voltage_scale_permille;
};

struct bld_data {
    const struct device *adc;
    struct adc_channel_cfg acc;
    struct adc_sequence as;
    uint16_t adc_raw;
    uint16_t millivolts;
    uint8_t state_of_charge;
};

static int bld_sample_fetch(const struct device *dev, enum sensor_channel chan) {
    struct bld_data *drv_data = dev->data;
    const struct bld_config *drv_cfg = dev->config;
    struct adc_sequence *as = &drv_data->as;

    // Make sure selected channel is supported
    if (chan != SENSOR_CHAN_GAUGE_VOLTAGE && chan != SENSOR_CHAN_GAUGE_STATE_OF_CHARGE &&
        chan != SENSOR_CHAN_ALL) {
        LOG_DBG("Selected channel is not supported: %d.", chan);
        return -ENOTSUP;
    }

    int rc = 0;

#if DT_INST_NODE_HAS_PROP(0, power_gpios)
    // Enable power before sampling
    rc = gpio_pin_set_dt(&drv_cfg->power, 1);

    if (rc != 0) {
        LOG_DBG("Failed to enable ADC power GPIO: %d", rc);
        return rc;
    }

    // wait for any capacitance to charge up
    k_sleep(K_MSEC(10));
#endif // DT_INST_NODE_HAS_PROP(0, power_gpios)

    // Read ADC
    rc = adc_read(drv_data->adc, as);
    as->calibrate = false;

    if (rc == 0) {
        int32_t val = drv_data->adc_raw;

        adc_raw_to_millivolts(adc_ref_internal(drv_data->adc), drv_data->acc.gain, as->resolution,
                              &val);

        uint16_t millivolts = val * (uint64_t)drv_cfg->full_ohm / drv_cfg->output_ohm;
        uint16_t calibrated_mv = millivolts * drv_cfg->voltage_scale_permille / 1000;
        uint8_t percent = lipo_mv_to_pct(calibrated_mv);
        LOG_DBG("ADC raw %d ~ %d mV => %d mV (calibrated %d mV) => %d%%", drv_data->adc_raw, val,
                millivolts, calibrated_mv, percent);

        drv_data->millivolts = millivolts;
        drv_data->state_of_charge = percent;
    } else {
        LOG_DBG("Failed to read ADC: %d", rc);
    }

#if DT_INST_NODE_HAS_PROP(0, power_gpios)
    // Disable power GPIO if present
    int rc2 = gpio_pin_set_dt(&drv_cfg->power, 0);

    if (rc2 != 0) {
        LOG_DBG("Failed to disable ADC power GPIO: %d", rc2);
        return rc2;
    }
#endif // DT_INST_NODE_HAS_PROP(0, power_gpios)

    return rc;
}

static int bld_channel_get(const struct device *dev, enum sensor_channel chan,
                           struct sensor_value *val) {
    struct bld_data *drv_data = dev->data;

    switch (chan) {
    case SENSOR_CHAN_GAUGE_VOLTAGE:
        val->val1 = drv_data->millivolts / 1000;
        val->val2 = (drv_data->millivolts % 1000) * 1000U;
        break;

    case SENSOR_CHAN_GAUGE_STATE_OF_CHARGE:
        val->val1 = drv_data->state_of_charge;
        val->val2 = 0;
        break;

    default:
        return -ENOTSUP;
    }

    return 0;
}

static const struct sensor_driver_api bld_api = {
    .sample_fetch = bld_sample_fetch,
    .channel_get = bld_channel_get,
};

static int bld_init(const struct device *dev) {
    struct bld_data *drv_data = dev->data;
    const struct bld_config *drv_cfg = dev->config;

    if (drv_data->adc == NULL) {
        LOG_ERR("ADC failed to retrieve ADC driver");
        return -ENODEV;
    }

    int rc = 0;

#if DT_INST_NODE_HAS_PROP(0, power_gpios)
    if (!device_is_ready(drv_cfg->power.port)) {
        LOG_ERR("GPIO port for power control is not ready");
        return -ENODEV;
    }
    rc = gpio_pin_configure_dt(&drv_cfg->power, GPIO_OUTPUT_INACTIVE);
    if (rc != 0) {
        LOG_ERR("Failed to control feed %u: %d", drv_cfg->power.pin, rc);
        return rc;
    }
#endif // DT_INST_NODE_HAS_PROP(0, power_gpios)

    drv_data->as = (struct adc_sequence){
        .channels = BIT(0),
        .buffer = &drv_data->adc_raw,
        .buffer_size = sizeof(drv_data->adc_raw),
        .oversampling = 4,
        .calibrate = true,
    };

#ifdef CONFIG_ADC_NRFX_SAADC
    drv_data->acc = (struct adc_channel_cfg){
        .gain = ADC_GAIN_1_6,
        .reference = ADC_REF_INTERNAL,
        .acquisition_time = ADC_ACQ_TIME(ADC_ACQ_TIME_MICROSECONDS, 40),
        .input_positive = SAADC_CH_PSELP_PSELP_AnalogInput0 + drv_cfg->io_channel.channel,
    };

    drv_data->as.resolution = 12;
#else
#error Unsupported ADC
#endif

    rc = adc_channel_setup(drv_data->adc, &drv_data->acc);
    LOG_DBG("AIN%u setup returned %d", drv_cfg->io_channel.channel, rc);

    return rc;
}

static struct bld_data bld_data = {.adc = DEVICE_DT_GET(DT_IO_CHANNELS_CTLR(DT_DRV_INST(0)))};

static const struct bld_config bld_cfg = {
    .io_channel =
        {
            DT_IO_CHANNELS_INPUT(DT_DRV_INST(0)),
        },
#if DT_INST_NODE_HAS_PROP(0, power_gpios)
    .power = GPIO_DT_SPEC_INST_GET(0, power_gpios),
#endif
    .output_ohm = DT_INST_PROP(0, output_ohms),
    .full_ohm = DT_INST_PROP(0, full_ohms),
    .voltage_scale_permille = DT_INST_PROP(0, voltage_scale_permille),
};

DEVICE_DT_INST_DEFINE(0, &bld_init, NULL, &bld_data, &bld_cfg, POST_KERNEL,
                      CONFIG_SENSOR_INIT_PRIORITY, &bld_api);
