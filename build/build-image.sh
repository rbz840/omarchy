#!/bin/bash
# build/build-image.sh — actual image assembly (runs INSIDE the aarch64 builder
# container or, with --native, directly as root on an aarch64 host).
#
# Steps:
#   1. Create sparse image file (BUILD_SIZE, default 16G)
#   2. Partition GPT: p1 ESP (512 MiB, FAT32), p2 ext4 rootfs
#   3. Pacstrap ALARM aarch64 base system into p2
#   4. Overlay Omarchy files: bin/, config/, default/, applications/, install/,
#      themes/, shell/ — plus the Pi-specific overlay (build/rootfs/)
#    enable firstboot service
#   5. Assemble ESP: firmware, kernel_2712.img, initramfs, config.txt, cmdline.txt
#   6. (Optional) build the experimental archiso aarch64 netboot ISO
#
# Environment (set by build/build.sh):
#   BUILD_SIZE (default 16G), BUILD_NAME (default omarchy-arm64-rpi5-YYYYMMDD),
#   BUILD_ISO (1/0), BUILD_IMG (1/0). Output goes to /output.
#
# Pi 5 boot note: the GPU firmware stage (start.elf on Pi 0-4) is embedded in
# the EEPROM on Pi 5 — the boot FS carries config.txt, DTBs, overlays and
# kernel_2712.img only.

set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
SIZE="${BUILD_SIZE:-16G}"
NAME="${BUILD_NAME:-omarchy-arm64-rpi5-$(date +%Y%m%d)}"
BUILD_ISO="${BUILD_ISO:-1}"
BUILD_IMG="${BUILD_IMG:-1}"
REPO="/omarchy-arm"                 # repo mounted read-only in container
ROOTFS_DIR="/rootfs"                # staging rootfs (pacstrap target)
IMG="$OUTPUT_DIR/$NAME.img"
ROOT="/mnt/omarchy-root"
BOOT_CONFIG="$REPO/build/boot"

LOOPDEV=""

log()  { printf '\033[1;34m[image]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[image]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[image] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Idempotent cleanup on failure
cleanup() {
  local rc=$?
  set +e
  umount "$ROOT/boot" "$ROOT" 2>/dev/null
  losetup -d "$LOOPDEV" 2>/dev/null
  rm -rf "$ROOT"
  exit $rc
}
trap cleanup EXIT

# Make p1/p2 visible for $LOOPDEV. losetup --partscan fails to create the
# partition block devices when the host loaded the loop module with
# max_part=0 (observed on hosted CI runners). Strategy: retry a few seconds
# (slow udev), then re-read the table (partprobe), then add the partitions
# via BLKPG ioctls (partx -a) which works independently of max_part.
ensure_loop_partitions() {
  local dev="$1" i
  for i in 1 2 3 4 5; do
    [[ -e "${dev}p1" && -e "${dev}p2" ]] && return 0
    sleep 1
  done
  partprobe "$dev" 2>/dev/null || true
  [[ -e "${dev}p1" && -e "${dev}p2" ]] && return 0
  partx -a "$dev" 2>/dev/null || true
  [[ -e "${dev}p1" && -e "${dev}p2" ]]
}

mkdir -p "$OUTPUT_DIR"

# 1. Create image -------------------------------------------------------------
(( BUILD_IMG )) || true
if (( BUILD_IMG )); then
  log "Creating sparse image $IMG ($SIZE)"
  rm -f "$IMG"
  truncate -s "$SIZE" "$IMG"

  # 2. Partition GPT ----------------------------------------------------------
  log "Partitioning GPT (p1 ESP 512 MiB FAT32, p2 ext4 rootfs)"
  parted --script "$IMG" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart rootfs ext4 513MiB 100%

  # Attach a loop device with partition scanning
  LOOPDEV=$(losetup --find --show --partscan "$IMG")
  log "Loop device: $LOOPDEV"
  ensure_loop_partitions "$LOOPDEV" \
    || die "Partition nodes not visible after losetup --partscan, partprobe and partx -a"

  # 3. Filesystems ------------------------------------------------------------
  log "Creating filesystems"
  mkfs.vfat -F 32 -n OMARCHY_BOOT "${LOOPDEV}p1"
  mkfs.ext4 -q -L omarchy-root "${LOOPDEV}p2"

  # 4. Rootfs assembly --------------------------------------------------------
  mkdir -p "$ROOT"
  mount "${LOOPDEV}p2" "$ROOT"
  mkdir -p "$ROOT/boot"
  mount "${LOOPDEV}p1" "$ROOT/boot"

  # 4.1 Pacstrap ALARM aarch64 base + kernel + firmware
  log "Pacstrapping ALARM aarch64 base (linux-rpi, firmware, bootloader)"
  pacstrap -C "$REPO/build/pacman-arm.conf" \
            -K "$ROOT" \
            base base-devel \
            linux-rpi linux-rpi-headers \
            raspberrypi-bootloader \
            raspberrypi-overlays \
            raspberrypi-utils \
            rpi5-eeprom \
            firmware-raspberrypi \
            linux-firmware \
            wireless-regdb \
            networkmanager wpa_supplicant bluez bluez-utils \
            sudo openssh git curl jq rsync parted e2fsprogs dosfstools \
            btrfs-progs snapper zram-generator kernel-modules-hook \
            mkinitcpio \
            neovim vim \
            bash-completion \
            man-db man-pages \
            tzdata

  # 4.2 Omarchy overlay: desktop stack, agents, configs, shell.
  # NOTE: build/ and tests/ are intentionally KEPT on the target — the install
  # stages read build/packages/*.packages at runtime and the validation script
  # lives in tests/.
  log "Overlaying Omarchy tree into rootfs"
  mkdir -p "$ROOT/opt"
  rsync -a --delete \
    --exclude 'out/' \
    --exclude '.git/' \
    --exclude '.github/' \
    "$REPO/" "$ROOT/opt/omarchy/"

  # 4.3 Pi-specific rootfs overlay (fstab, services, sysctl, modprobe, udev)
  log "Applying Pi rootfs overlay (build/rootfs/)"
  rsync -a "$REPO/build/rootfs/" "$ROOT/"

  # 4.4 Enable firstboot service (expands rootfs, runs Omarchy install flow)
  log "Enabling omarchy-firstboot-pi.service"
  systemctl --root="$ROOT" enable omarchy-firstboot-pi.service
  # Trigger marker: the unit is conditioned on this file's existence
  mkdir -p "$ROOT/var/lib/omarchy-firstboot-pi"
  touch "$ROOT/var/lib/omarchy-firstboot-pi/firstboot-pending"
  # fstab is generated at firstboot (UUIDs known only on target hardware);
  # a template is shipped in build/rootfs/etc/fstab.pi-template.

  # 4.5 Regenerate the initramfs INSIDE the rootfs so the omarchy-pi-esp hook
  # and forced modules (virtio/ext4/nvme/mmc_block) are actually embedded —
  # pacstrap's initramfs predates the 4.3 overlay and would ship without them.
  log "Regenerating initramfs (omarchy-pi-esp hook + forced modules)"
  arch-chroot "$ROOT" mkinitcpio -P \
    || die "mkinitcpio -P failed in rootfs — initramfs would lack the ESP hook"

  # 5. Boot configuration -----------------------------------------------------
  # $ROOT/boot IS the ESP (partition p1): pacstrap already wrote firmware,
  # kernel_2712.img, initramfs, DTBs and overlays there via raspberrypi-bootloader
  # + linux-rpi. Only our Omarchy boot config remains to be applied.
  log "Applying Omarchy boot config (config.txt, cmdline.txt) to the ESP"
  cp "$BOOT_CONFIG/config.txt" "$ROOT/boot/config.txt"
  # Inject the ACTUAL root PARTUUID into cmdline.txt: the template cannot know
  # it, and a hardcoded /dev/mmcblk0p2 would kernel-panic on a pristine NVMe
  # (or USB) boot before the ESP hook ever runs. The hook still repairs later
  # corruption, rewriting root= to whatever medium it booted from.
  P2_PARTUUID=$(blkid -s PARTUUID -o value "${LOOPDEV}p2")
  [[ -n "$P2_PARTUUID" ]] || die "cannot read PARTUUID of the root partition"
  sed "s|root=[^ ]*|root=PARTUUID=${P2_PARTUUID}|" "$BOOT_CONFIG/cmdline.txt" > "$ROOT/boot/cmdline.txt"
  log "cmdline.txt root=PARTUUID=$P2_PARTUUID"
  sync

  # 6. Optional archiso build -------------------------------------------------
  if (( BUILD_ISO )); then
    if ! command -v mkarchiso >/dev/null 2>&1; then
      warn "mkarchiso not available (archiso is not packaged in ALARM repos) — ISO build skipped; the .img is the primary deliverable"
    elif [[ -d "$REPO/build/archiso" ]]; then
      log "Building experimental archiso aarch64 ISO (build/archiso/)"
      mkarchiso -v -w /tmp/archiso-work -o "$OUTPUT_DIR" "$REPO/build/archiso/releng-omarchy-aarch64" \
        || warn "archiso build failed (non-fatal; the .img is the primary deliverable)"
    else
      warn "archiso profile not found at build/archiso/releng-omarchy-aarch64"
    fi
  fi

  # Detach loop, unmount
  umount "$ROOT/boot"
  umount "$ROOT"
  losetup -d "$LOOPDEV"
  log "Image ready: $IMG"
fi
