<picture>
  <source media="(prefers-color-scheme: dark)" srcset="/docs/images/TOTEM_logo_dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="/docs/images/TOTEM_logo_bright.svg">
  <img alt="TOTEM logo font" src="/docs/images/TOTEM_logo_bright.svg">
</picture>

# ZMK CONFIG FOR THE TOTEM SPLIT KEYBOARD

[Here](https://github.com/GEIGEIGEIST/totem) you can find the hardware files and build guide.\
[Here](https://github.com/GEIGEIGEIST/qmk-config-totem) you can find the QMK config for the TOTEM.

TOTEM is a 38 key column-staggered split keyboard running [ZMK](https://zmk.dev/) or [QMK](https://docs.qmk.fm/). It's meant to be used with a SEEED XIAO BLE or RP2040.


![TOTEM layout](/docs/images/TOTEM_layout.svg)

The image above shows the upstream default layout. This fork uses its own QWERTY layout, described below.


## WHAT'S DIFFERENT IN THIS FORK

### Keymap

- QWERTY base layer with home-row mods: `A`/`;` Cmd, `S`/`L` Option, `D`/`K` Ctrl, `F`/`J` Shift.
- Hold `Tab` (left middle thumb) for the NAV layer: arrows, Home/End, Page Up/Down and a numpad.
- Hold `Esc` (right middle thumb) for the SYM layer.
- Hold `Tab` + `Enter` (left middle and right inner thumb) for the ADJ layer: Bluetooth profiles, output toggle, F-keys, reset and bootloader.
- `Q` + `W` together send `Esc`.
- ZMK is pinned to `v0.3` in `config/west.yml`, and a `settings_reset` firmware is built alongside the two halves.

### Battery reporting for both halves

- The left half (central) forwards the right half's battery level to the computer, so both levels are available over Bluetooth (`config/totem.conf`).
- macOS' own Bluetooth menu only shows the left half. Use the status page or the menu bar app below to see both.

### More accurate battery percentage

ZMK's default estimate is a straight line between 3.45 V and 4.2 V, and only reports 100% at 4.2 V, which a resting battery rarely reaches. This fork adds its own driver (`drivers/battery/battery_lipo_divider.c`) that:

- maps the voltage to a typical LiPo discharge curve, and
- corrects each half's readings for its own XIAO board's measurement error.

The divider resistors' tolerance and the ADC's gain error make every XIAO read the same battery a few percent differently, so each half has its own `voltage-scale-permille` in `config/boards/shields/totem/totem_left.overlay` and `totem_right.overlay` (currently `1037` and `1012`, where `1000` means no correction). Raise a half's value if a full battery stops short of 100%; lower it if the level stays at 100% for too long after charging. The value belongs to the board: recalibrate after swapping a XIAO, but not after replacing a battery.

### Advertise key for the status page

Chrome's Web Bluetooth device picker on macOS only lists devices that are advertising, and ZMK stops advertising once it is connected. Press `Tab` + `Enter` + `B` (ADJ layer) to make the left half advertise for 10 seconds (`drivers/behaviors/behavior_adv_burst.c`).

The advertising is non-connectable, so it cannot open a new connection or drop the existing one. If the host connects, disconnects or the profile changes during those 10 seconds, the burst stops and ZMK's normal advertising takes over again.

### Battery status page

`web/index.html` is a single-file page that reads both halves' battery levels over Web Bluetooth and keeps them updated. It is also hosted at [ca110.us/keyboard](https://ca110.us/keyboard/).

1. Open the page in Chrome or Edge (Safari and Firefox do not support Web Bluetooth).
2. Click **Connect keyboard**, then press `Tab` + `Enter` + `B` on the keyboard.
3. Pick **TOTEM** in the dialog.

Add `?demo` to the URL to preview the page with sample data.

### macOS menu bar app

`macos/TotemBattery` is a small AppKit menu bar app. It reads both halves' battery levels from the already-connected keyboard, so no advertise key is needed.

- The menu bar shows the TOTEM icon with a dot for the lower of the two halves: green at 50% and above, yellow from 20%, red below 20%.
- The menu lists each half's level, a refresh item and an **Open at Login** toggle.
- Notifications warn when a half drops below 20% and again below 10%, and when the keyboard or its right half stays disconnected for 30 seconds. Drops while the Mac goes to sleep are ignored. Each kind can be switched off in the menu (**Low Battery Alerts**, **Disconnect Alerts**).
- It subscribes to battery notifications instead of polling, and uses about 14 MB of memory.

Build it with `macos/TotemBattery/build.sh`, or create an installable disk image with `macos/TotemBattery/package.sh` (written to `macos/TotemBattery/build/TotemBattery.dmg`). It requires macOS 13 or later and asks for Bluetooth access on first launch. The app is ad-hoc signed, so it is meant for the Mac it was built on.

### Repository layout

| Path | Contents |
| --- | --- |
| `config/` | Keymap, shield definition and ZMK settings |
| `drivers/`, `dts/`, `Kconfig`, `CMakeLists.txt`, `zephyr/module.yml` | The battery driver and advertise behavior, loaded by the build as a Zephyr module |
| `web/` | Battery status page |
| `macos/TotemBattery/` | Menu bar app |


## HOW TO USE

- fork this repo
- `git clone` your repo, to create a local copy on your PC (you can use the [command line](https://www.atlassian.com/git/tutorials) or [github desktop](https://desktop.github.com/))
- adjust the `config/totem.keymap` file (find all the keycodes on [the zmk docs pages](https://zmk.dev/docs/codes/))
- `git push` your repo to your fork
- on the GitHub page of your fork navigate to "Actions"
- scroll down and unzip the `firmware.zip` archive that contains the latest firmware
- connect the left half of the TOTEM to your PC, press reset twice
- the keyboard should now appear as a mass storage device
- drag'n'drop the `totem_left-seeeduino_xiao_ble-zmk.uf2` file from the archive onto the storage device
- repeat this process with the right half and the `totem_right-seeeduino_xiao_ble-zmk.uf2` file.

### Flashing tips

- With the GitHub CLI you can download the firmware of a build directly:
  ```
  gh run download <run-id> -R <owner>/zmk-config-totem -n firmware -D ~/Downloads/totem-firmware
  ```
- The left half can also enter the bootloader from the ADJ layer (`Tab` + `Enter` + `A`). The right half needs the double reset.
- On a XIAO BLE the storage device is called `XIAO-SENSE`. If Finder fails to copy the file, use `cp -X <file>.uf2 /Volumes/XIAO-SENSE/`.
- Bluetooth pairings are kept when flashing. Only if the halves stop pairing with each other, flash `settings_reset-seeeduino_xiao_ble-zmk.uf2` to both halves, then flash the normal firmware again.
