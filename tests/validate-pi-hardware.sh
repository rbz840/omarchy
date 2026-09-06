#!/bin/bash
# tests/validate-pi-hardware.sh — post-install hardware validation on the Pi 5.
#
# Run ON the Raspberry Pi 5 after Omarchy ARM64 is installed:
#   sudo ./tests/validate-pi-hardware.sh
#
# Exit 0 = all critical checks passed. Warnings don't fail the run.
# Output is also appended to /var/log/omarchy-pi-validation.log.

set -uo pipefail

LOG=/var/log/omarchy-pi-validation.log
pass=0; warn=0; fail=0

section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*" | tee -a "$LOG"; }
ok()      { printf '\033[1;32m  PASS\033[0m %s\n' "$*" | tee -a "$LOG"; pass=$((pass+1)); }
warnw()   { printf '\033[1;33m  WARN\033[0m %s\n' "$*" | tee -a "$LOG"; warn=$((warn+1)); }
bad()     { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" | tee -a "$LOG"; fail=$((fail+1)); }

section "1. Boot & platform"
if grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null; then
  ok "Model: $(tr -d '\0' < /proc/device-tree/model)"
else
  bad "Not a Raspberry Pi 5 (model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo '?'))"
fi
[[ "$(uname -m)" == "aarch64" ]] && ok "aarch64 kernel" || bad "Not aarch64: $(uname -m)"
if [[ "$(uname -r)" == *"-rpi"* || -e /boot/kernel_2712.img ]]; then
  ok "Kernel: $(uname -r)"
else
  warnw "Kernel $(uname -r) does not look like linux-rpi"
fi
# EEPROM version (info only)
if command -v rpi-eeprom-update >/dev/null 2>&1; then
  rpi-eeprom-update 2>/dev/null | head -2 | tee -a "$LOG"
else
  warnw "rpi-eeprom-update not found (EEPROM version unknown)"
fi

section "1b. Boot resilience (omarchy-pi-esp initramfs hook)"
if [[ -f /usr/lib/initcpio/hooks/omarchy-pi-esp ]]; then
  ok "omarchy-pi-esp runtime hook installed"
else
  bad "omarchy-pi-esp runtime hook missing (ESP self-repair disabled)"
fi
if grep -qs "omarchy-pi-esp" /etc/mkinitcpio.conf.d/omarchy-pi.conf 2>/dev/null; then
  ok "hook enabled in mkinitcpio.conf.d drop-in"
else
  warnw "hook not present in /etc/mkinitcpio.conf.d/omarchy-pi.conf"
fi
if [[ -f /boot/cmdline.txt && -s /boot/cmdline.txt && -f /boot/config.txt && -s /boot/config.txt ]]; then
  ok "ESP boot files present (cmdline.txt, config.txt)"
else
  warnw "ESP boot files missing/empty — they will be restored by the initramfs hook on next boot"
fi
if lsinitcpio /boot/initramfs-linux-rpi.img 2>/dev/null | grep -q "etc/omarchy-pi-boot/cmdline.txt"; then
  ok "pristine boot templates embedded in initramfs"
else
  warnw "pristine boot templates not found in initramfs (regenerate with mkinitcpio -P)"
fi

section "2. GPU (V3D / VideoCore VI)"
if ls /dev/dri/renderD* >/dev/null 2>&1; then
  ok "DRI render nodes present: $(ls /dev/dri/renderD* | tr '\n' ' ')"
else
  bad "No DRI render node — vc4/v3d not bound"
fi
if grep -qs "^v3d" /proc/modules || grep -qs "v3d" /lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null; then
  ok "v3d module loaded/builtin"
else
  warnw "v3d module not detected"
fi
if command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary 2>/dev/null | grep -qi "broadcom"; then
  ok "Vulkan (v3dv) reports Broadcom device"
else
  warnw "Vulkan Broadcom device not reported (vulkan-tools not installed, or v3dv failed)"
fi
if command -v glxinfo >/dev/null 2>&1; then
  if glxinfo -B 2>/dev/null | grep -qi "opengl es\|v3d"; then
    ok "OpenGL/GLES reports V3D renderer"
  else
    warnw "glxinfo present but V3D renderer not confirmed (Wayland-only systems may need eglinfo)"
  fi
fi

section "3. Video decode (HEVC / V4L2 request)"
if grep -qs "^rpivid" /proc/modules; then
  ok "rpivid (HEVC decoder) module loaded"
else
  warnw "rpivid module not loaded — HEVC hw decode may be missing"
fi
if [[ -e /dev/media0 || -e /dev/video19 ]]; then
  ok "V4L2/media devices present"
else
  warnw "No V4L2/media device nodes (codecs not exposed)"
fi
# mpv decoder capability: report what hwdecs the linked ffmpeg/mpv actually
# ship. The v4l2request hwdec requires an ffmpeg built with the V4L2
# request-API hwaccels (mainlined in FFmpeg 8.0); stock ALARM ffmpeg/mpv do
# NOT ship it (verified 2026-09-06 by binary inspection) — software decode via
# hwdec=auto-safe is the expected path, so its absence is a WARN, not a FAIL.
if command -v mpv >/dev/null 2>&1; then
  if mpv --hwdec=help 2>&1 | grep -q "v4l2request"; then
    ok "mpv: v4l2request hwdec available (full HEVC hw decode)"
  else
    warnw "mpv: no v4l2request hwdec — HEVC/H264 use software decode (hwdec=auto-safe, GPU compositing)"
  fi
  if mpv --hwdec=help 2>&1 | grep -Eq "vaapi|drm"; then
    ok "mpv: generic hwdec wrappers present (vaapi/drm)"
  else
    warnw "mpv: no vaapi/drm hwdec wrappers found"
  fi
else
  warnw "mpv not installed"
fi

section "4. Network (Ethernet + WiFi)"
if ip link show eth0 >/dev/null 2>&1; then
  ok "Ethernet interface eth0 present (bcmgenet)"
else
  warnw "eth0 not present (no cable, or driver issue)"
fi
if ip link show wlan0 >/dev/null 2>&1; then
  ok "WiFi interface wlan0 present (brcmfmac CYW43455)"
else
  bad "wlan0 missing — brcmfmac or firmware problem"
fi
if nmcli radio wifi 2>/dev/null | grep -q enabled; then
  ok "WiFi radio enabled"
else
  warnw "WiFi radio disabled (nmcli radio wifi on to enable)"
fi
if [[ -e /lib/firmware/brcm/brcmfmac43455-sdio.bin ]]; then
  ok "CYW43455 firmware files present"
else
  bad "brcmfmac43455-sdio.bin missing (firmware-raspberrypi)"
fi

section "5. Bluetooth"
if systemctl is-active --quiet bluetooth; then
  ok "bluetooth.service active"
else
  warnw "bluetooth.service not active"
fi
if [[ -e /lib/firmware/brcm/BCM4345C0.hcd ]]; then
  ok "BT firmware BCM4345C0.hcd present"
else
  warnw "BCM4345C0.hcd missing — BT firmware incomplete"
fi

section "6. Storage (PCIe / NVMe / USB3)"
if lspci 2>/dev/null | grep -qi "BCM2712\|RP1"; then
  ok "PCIe: RP1 detected"
else
  warnw "lspci did not list RP1 (pciutils missing, or PCIe disabled)"
fi
nvme_devs=$(ls /dev/nvme0n1 2>/dev/null | wc -l)
if (( nvme_devs > 0 )); then
  ok "NVMe device(s): $(ls /dev/nvme*n1 | tr '\n' ' ')"
else
  warnw "No NVMe device found (attach an NVMe HAT or ignore)"
fi
if lsusb 2>/dev/null | grep -q "xHCI"; then
  ok "USB3 xHCI controller visible"
else
  warnw "lsusb did not show xHCI (usbutils missing?)"
fi

section "7. Audio (ALSA/PipeWire)"
if command -v aplay >/dev/null 2>&1; then
  sinks=$(aplay -l 2>/dev/null | grep -c "^card")
  if (( sinks > 0 )); then
    ok "ALSA playback devices: $sinks"
  else
    bad "No ALSA playback device (snd_bcm2835 problem)"
  fi
else
  warnw "alsa-utils not installed (aplay missing)"
fi
if systemctl is-active --quiet pipewire 2>/dev/null; then
  ok "pipewire active (user session)"
else
  warnw "pipewire not active in this session (normal from TTY; check inside desktop session)"
fi

section "8. Thermal & cooling"
if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
  temp=$(cat /sys/class/thermal/thermal_zone0/temp)
  ok "SoC temperature: $((temp / 1000)) °C"
else
  warnw "No thermal zone readable"
fi

section "9. Omarchy runtime agents"
if [[ -n "${OMARCHY_PATH:-}" && -d "$OMARCHY_PATH/bin" ]]; then
  ok "OMARCHY_PATH=$OMARCHY_PATH with $(ls "$OMARCHY_PATH/bin" | wc -l) commands"
else
  warnw "OMARCHY_PATH not set in this shell — source /etc/profile.d/omarchy-pi.sh"
fi
for cmd in omarchy-bar omarchy-launch-walker omarchy-notification-send; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd present"
  else
    warnw "$cmd missing (agents not fully installed)"
  fi
done

section "Summary"
printf 'PASS: %d  WARN: %d  FAIL: %d\n' "$pass" "$warn" "$fail" | tee -a "$LOG"
(( fail == 0 )) && exit 0 || exit 1
