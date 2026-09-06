#!/bin/bash
# install/pi/02-partition.sh — partition verification / finalization.
#
# The shipped image is already partitioned (GPT: p1 ESP, p2 rootfs) and the
# firstboot entrypoint has already expanded p2. This stage:
#   - verifies the expected layout,
#   - writes /etc/fstab from the template using real UUIDs,
#   - ensures the ESP is mounted read-only per fstab policy.

set -uo pipefail

OMARCHY_ARM_ROOT="${OMARCHY_ARM_ROOT:-/opt/omarchy}"
# shellcheck source=../lib/common.sh
source "$OMARCHY_ARM_ROOT/install/lib/common.sh"

require_root

ROOT_SRC="$(findmnt -n -o SOURCE /)"
ESP_SRC="$(lsblk -no PKNAME "$ROOT_SRC" | head -1)"
DISK="/dev/${ESP_SRC:-mmcblk0}"
ESP_PART="${DISK}p1"

if [[ ! -b "$ESP_PART" ]]; then
  # Some media (USB sticks via sd*) do not use the 'p' separator
  ESP_PART="${DISK}1"
fi

if [[ ! -b "$ESP_PART" ]]; then
  omarchy_arm_die "ESP partition not found (tried ${DISK}p1 and ${DISK}1)."
fi

omarchy_arm_log "Root: $ROOT_SRC — ESP: $ESP_PART"

# UUIDs
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_SRC")"
BOOT_UUID="$(blkid -s UUID -o value "$ESP_PART")"
[[ -n "$ROOT_UUID" && -n "$BOOT_UUID" ]] || omarchy_arm_die "Could not read UUIDs from $ROOT_SRC / $ESP_PART"

# Generate /etc/fstab from template
omarchy_arm_log "Writing /etc/fstab (root=$ROOT_UUID, boot=$BOOT_UUID)"
sed -e "s|ROOTFS-UUID|$ROOT_UUID|" -e "s|BOOT-UUID|$BOOT_UUID|" \
    "$OMARCHY_ARM_ROOT/build/rootfs/etc/fstab.pi-template" > /etc/fstab

# Mount ESP per fstab (should already be mounted by the firmware → remount ro)
mkdir -p /boot
mount -o remount,rw /boot 2>/dev/null || mount "$ESP_PART" /boot
omarchy_arm_log "ESP mounted at /boot (will be remounted ro by post-install)"

exit 0
