#!/bin/bash
# install/pi/firstboot-entrypoint.sh — first-boot orchestrator for Omarchy ARM64.
#
# Invoked by omarchy-firstboot-pi.service (enabled in the shipped image).
# On the first boot it:
#   1. expands the root filesystem to fill the boot medium,
#   2. runs the install stages (01-detect → 06-post-install),
#   3. reboots into the finished Omarchy desktop.
#
# Every stage is idempotent and leaves a marker in
# /var/lib/omarchy-firstboot-pi/stages/ — a failed boot does not replay
# already-completed work (see install/lib/common.sh).

set -euo pipefail

OMARCHY_ARM_ROOT="${OMARCHY_ARM_ROOT:-/opt/omarchy}"
# shellcheck source=../lib/common.sh
source "$OMARCHY_ARM_ROOT/install/lib/common.sh"

require_root

STAGES=(
  01-detect.sh
  02-partition.sh
  03-pacstrap.sh
  04-user.sh
  05-pi-specific.sh
  06-post-install.sh
)

# --- 1. Expand root filesystem ----------------------------------------------
expand_rootfs() {
  local root_dev root_part part_num disk
  root_dev="$(findmnt -n -o SOURCE /)"
  root_part="$root_dev"

  # e.g. /dev/mmcblk0p2 -> /dev/mmcblk0 + 2 ; /dev/nvme0n1p2 -> /dev/nvme0n1 + 2
  if [[ "$root_part" =~ ^(.*?)(p?)([0-9]+)$ ]]; then
    disk="${BASH_REMATCH[1]}"
    part_num="${BASH_REMATCH[3]}"
  else
    omarchy_arm_die "Cannot parse root device: $root_part"
  fi

  # Skip if already expanded (marker written after successful resize)
  if [[ -f "$OMARCHY_ARM_STATE/rootfs-expanded" ]]; then
    omarchy_arm_log "Root filesystem already expanded — skipping"
    return 0
  fi

  omarchy_arm_log "Expanding $part_num on $disk to fill the medium"
  if command -v growpart >/dev/null 2>&1; then
    growpart "$disk" "$part_num" || omarchy_arm_warn "growpart failed (partition may already fill the disk)"
  else
    # growpart is in cloud-guest-utils; fall back to parted
    parted --script "$disk" resizepart "$part_num" 100% || omarchy_arm_warn "parted resizepart failed"
  fi
  partprobe "$disk" || true
  resize2fs "$root_part" || omarchy_arm_die "resize2fs failed on $root_part"
  touch "$OMARCHY_ARM_STATE/rootfs-expanded"
  omarchy_arm_log "Root filesystem expanded"
}

# --- 2. Install stages -------------------------------------------------------
for stage in "${STAGES[@]}"; do
  run_stage "$stage"
done

# --- 3. Reboot into the desktop ---------------------------------------------
omarchy_arm_log "First boot setup complete — rebooting into Omarchy"
systemctl disable omarchy-firstboot-pi.service || true
rm -f /var/lib/omarchy-firstboot-pi/firstboot-pending
sleep 2
systemctl reboot
