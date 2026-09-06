#!/bin/bash
# install/pi/06-post-install.sh — final boot wiring after package installation.
#
# Regenerates the initramfs for linux-rpi, syncs kernel+initramfs+DTB to the
# ESP (FAT32, read by the Pi firmware), enables services, and remounts the
# ESP read-only for safety.

set -uo pipefail

OMARCHY_ARM_ROOT="${OMARCHY_ARM_ROOT:-/opt/omarchy}"
# shellcheck source=../lib/common.sh
source "$OMARCHY_ARM_ROOT/install/lib/common.sh"

require_root

ESP="/boot"

# --- 1. Initramfs ---------------------------------------------------------------
omarchy_arm_log "Regenerating initramfs for linux-rpi (with omarchy-pi-esp hook)"
# The omarchy-pi-esp hook is pulled in by the HOOKS+=(omarchy-pi-esp) drop-in
# (build/rootfs/etc/mkinitcpio.conf.d/omarchy-pi.conf): it waits for the boot
# medium on NVMe/USB and self-repairs cmdline.txt/config.txt on the ESP.
mkinitcpio -P || omarchy_arm_die "mkinitcpio failed — kernel image may be stale"
if [[ -f /usr/lib/initcpio/hooks/omarchy-pi-esp ]] && grep -q "omarchy-pi-esp" /etc/mkinitcpio.conf.d/omarchy-pi.conf; then
  omarchy_arm_log "omarchy-pi-esp hook: present and enabled"
else
  omarchy_arm_warn "omarchy-pi-esp hook missing — boot-medium wait + ESP self-repair disabled"
fi

# --- 2. Sync boot files to the ESP ------------------------------------------------
omarchy_arm_log "Syncing kernel, initramfs and DTB to the ESP"
if mountpoint -q "$ESP"; then
  mount -o remount,rw "$ESP"
  # linux-rpi deploys kernel_2712.img + initramfs-linux-rpi.img in /boot of the
  # rootfs; raspberrypi-bootloader places DTBs and overlays in /boot too.
  # On this layout /boot IS the ESP (single mount), so files are already in
  # place — just ensure cmdline.txt matches the template.
  if [[ -f "$OMARCHY_ARM_ROOT/build/boot/cmdline.txt" && ! -f "$ESP/cmdline.txt" ]]; then
    cp "$OMARCHY_ARM_ROOT/build/boot/cmdline.txt" "$ESP/cmdline.txt"
  fi
  if [[ -f "$OMARCHY_ARM_ROOT/build/boot/config.txt" && ! -f "$ESP/config.txt" ]]; then
    cp "$OMARCHY_ARM_ROOT/build/boot/config.txt" "$ESP/config.txt"
  fi
  sync
  mount -o remount,ro "$ESP" || true
else
  omarchy_arm_warn "$ESP is not a mountpoint — boot files not synced"
fi

# --- 3. Services (upstream Omarchy parity) ------------------------------------------
omarchy_arm_log "Enabling Omarchy desktop services"
systemctl enable NetworkManager.service bluetooth.service sddm.service \
                 systemd-resolved.service avahi-daemon.service ufw.service

# --- 4. Locale / timezone (interactive deferred to first login) ----------------------
omarchy_arm_log "Locale/timezone: defaults applied; adjust after first login (omarchy-channel-set, timedatectl)"

# --- 4b. Drop the temporary AUR-build sudo grant (installed by 04-user.sh) -----------
rm -f /etc/sudoers.d/20-omarchy-build

# --- 5. Mark installation complete ----------------------------------------------------
omarchy_arm_log "Omarchy ARM64 installation complete."
omarchy_arm_log "Reboot will bring up the Omarchy desktop (SDDM → Hyprland/Quickshell)."

exit 0
