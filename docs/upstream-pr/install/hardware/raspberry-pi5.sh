if omarchy-hw-raspberrypi5; then
  # Raspberry Pi 5 firmware/boot packages — Arch Linux ARM repository names.
  # The detector is aarch64-gated, so this never resolves on x86_64 installs.
  omarchy-pkg-add firmware-raspberrypi raspberrypi-utils rpi5-eeprom
fi
