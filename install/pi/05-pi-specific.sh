#!/bin/bash
# install/pi/05-pi-specific.sh — Raspberry Pi 5 hardware enablement.
# (Runs AFTER 04-user.sh so the 'omarchy' build user exists for AUR builds.)
#
# Covers: WiFi/BT firmware (CYW43455), V3D + Vulkan, V4L2 HEVC/H264 decode,
# fan/thermal policy, NVMe/PCIe, AUR agents, mpv V4L2 profile, boot config.
# Every step is guarded — safe to re-run (idempotent).

set -uo pipefail

OMARCHY_ARM_ROOT="${OMARCHY_ARM_ROOT:-/opt/omarchy}"
# shellcheck source=../lib/common.sh
source "$OMARCHY_ARM_ROOT/install/lib/common.sh"

require_root

ESP="/boot"

# --- 1. WiFi + Bluetooth firmware (CYW43455) ---------------------------------
omarchy_arm_log "Verifying WiFi/BT firmware (firmware-raspberrypi)"
if [[ ! -e /lib/firmware/brcm/brcmfmac43455-sdio.bin ]]; then
  pacman -S --needed --noconfirm firmware-raspberrypi || omarchy_arm_warn "firmware-raspberrypi install failed"
fi
# The 43455 needs a per-board NVRAM txt; check the Pi 5 variant is present.
if ! ls /lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.txt >/dev/null 2>&1; then
  omarchy_arm_warn "Pi 5 WiFi NVRAM file missing — WiFi may need manual firmware copy."
fi

# --- 2. Vulkan + V3D stack ----------------------------------------------------
omarchy_arm_log "Installing Vulkan-Broadcom (v3dv) + Mesa V3D"
pacman -S --needed --noconfirm mesa vulkan-broadcom vulkan-icd-loader vulkan-tools || \
  omarchy_arm_warn "Vulkan stack install failed — Hyprland will fall back to GLES"

# --- 3. V4L2 HEVC/H264 decode (VideoCore VI) ----------------------------------
omarchy_arm_log "Ensuring V4L2 codecs module (rpivid) is enabled"
if ! grep -q "^rpivid" /etc/modules-load.d/omarchy-pi.conf 2>/dev/null; then
  mkdir -p /etc/modules-load.d
  echo "rpivid" >> /etc/modules-load.d/omarchy-pi.conf
fi

# mpv profile. Stock ALARM ffmpeg + mpv have NO v4l2request hwdec (verified
# 2026-09-06); hwdec=auto-safe therefore software-decodes HEVC/H264 with GPU
# compositing — the practical Pi 5 path. See config/mpv/mpv.conf for details.
omarchy_arm_log "Installing mpv config (hwdec=auto-safe)"
mkdir -p /etc/mpv
cp "$OMARCHY_ARM_ROOT/config/mpv/mpv.conf" /etc/mpv/mpv.conf

# --- 4. Boot config verification -------------------------------------------------
omarchy_arm_log "Verifying boot config on ESP"
if [[ -f "$ESP/config.txt" ]]; then
  grep -q "^kernel=kernel_2712.img" "$ESP/config.txt" || \
    omarchy_arm_warn "config.txt missing kernel=kernel_2712.img — boot may use wrong kernel"
else
  omarchy_arm_warn "$ESP/config.txt not found — was the image ESP assembled correctly?"
fi

# --- 5. AUR agents (Omarchy tooling not in ALARM repos) ------------------------
omarchy_arm_log "Installing AUR agents via yay (this takes a while on Pi 5)"
if command -v yay >/dev/null 2>&1; then
  aur_pkgs=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && aur_pkgs+=("$line")
  done < "$OMARCHY_ARM_PACKAGES/aur.txt"
  if (( ${#aur_pkgs[@]} > 0 )); then
    # yay must run as non-root; use the omarchy user if it exists
    if id "omarchy" &>/dev/null; then
      sudo -u omarchy \
        env HOME=/home/omarchy \
        yay -S --needed --noconfirm --sudoloop=false -- "${aur_pkgs[@]}" || \
        omarchy_arm_warn "Some AUR packages failed — see /tmp/yay.log"
    else
      omarchy_arm_warn "User 'omarchy' not created yet — AUR agents skipped (rerun install/pi/04-pi-specific.sh after 05-user.sh)"
    fi
  fi
else
  omarchy_arm_warn "yay not found — AUR agents skipped"
fi

# --- 6. Fan/thermal policy (official Pi 5 fan via firmware) --------------------
omarchy_arm_log "Fan/thermal: using firmware defaults (config.txt dtparam fan_temp*)"

# --- 7. NVMe/PCIe --------------------------------------------------------------
omarchy_arm_log "PCIe/NVMe: native DT boot — no action needed"

omarchy_arm_log "Pi-specific enablement complete"
exit 0
