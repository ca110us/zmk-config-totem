if(CONFIG_TOTEM_BATTERY_LIPO_DIVIDER)
  zephyr_library()
  zephyr_library_sources(drivers/battery/battery_lipo_divider.c)
endif()
