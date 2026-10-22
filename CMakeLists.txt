if(CONFIG_TOTEM_BATTERY_LIPO_DIVIDER)
  zephyr_library()
  zephyr_library_sources(drivers/battery/battery_lipo_divider.c)
endif()

target_sources_ifdef(CONFIG_TOTEM_BEHAVIOR_ADV_BURST app PRIVATE drivers/behaviors/behavior_adv_burst.c)
target_sources_ifdef(CONFIG_TOTEM_IDLE_POWER_SAVING app PRIVATE src/idle_power_saving.c)
