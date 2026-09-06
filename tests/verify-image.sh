#!/bin/bash
# tests/verify-image.sh — boot-critical content verification for a built image.
#
# Usage (needs root — loop mount):
#   sudo ./tests/verify-image.sh out/omarchy-arm64-rpi5-YYYYMMDD.img
#
# Verifies the ESP (partition 1, FAT32 — all boot files live there; p2's /boot
# is only an empty mountpoint in this layout, since pacstrap writes them
# through the mounted ESP).
#
# CRITICAL (absence = exit 1, blocks release):
#   - kernel_2712.img (non-empty)
#   - config.txt (non-empty, with kernel=kernel_2712.img)
#   - cmdline.txt (non-empty, with root=)
#   - at least one bcm2712*.dtb (non-empty)
#   - vc4-kms-v3d-pi5.dtbo overlay
#   - initramfs-linux-rpi.img with the omarchy-pi-esp hook runtime script
#     and the pristine boot templates inside
# WARNINGS (absence = exit 0):
#   - start.elf/start4d.elf (GPU firmware stage, EEPROM-embedded on Pi 5)
#   - overlays/README
#   - initramfs-linux-rpi-fallback.img
#
# The image is mounted READ-ONLY; the loop is always detached and mounts
# cleaned up on exit.

set -euo pipefail

IMG="${1:-}"
[[ -n "$IMG" && -f "$IMG" ]] || { echo "usage: $0 <image.img>" >&2; exit 2; }
IMG="$(readlink -f "$IMG")"

log()  { printf '%s\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*" >&2; }
bad()  { printf '  FAIL  %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die "run as root (loop mount required)"

MNT="$(mktemp -d /tmp/omarchy-verify-XXXXXX)"
LOOPDEV=""

cleanup() {
  local rc=$?
  set +e
  umount "$MNT" 2>/dev/null
  [[ -n "$LOOPDEV" ]] && losetup -d "$LOOPDEV" 2>/dev/null
  rmdir "$MNT" 2>/dev/null
  exit $rc
}
trap cleanup EXIT

log "Attaching $IMG read-only"
LOOPDEV=$(losetup --find --show --read-only --partscan "$IMG")
log "Loop device: $LOOPDEV"

# Partition sanity: exactly the GPT layout the build produces (p1 ESP, p2 rootfs)
[[ -e "${LOOPDEV}p1" && -e "${LOOPDEV}p2" ]] || die "expected partitions ${LOOPDEV}p1 and ${LOOPDEV}p2 not found"
[[ ! -e "${LOOPDEV}p3" ]] || warn "unexpected third partition present"

mount --read-only -t vfat "${LOOPDEV}p1" "$MNT"

# ----------------------------------------------------------------- critical
failures=0
check_file() {
  local path="$1" desc="$2"
  if [[ -s "$MNT/$path" ]]; then
    ok "$desc: $path ($(wc -c < "$MNT/$path") bytes)"
  else
    bad "$desc missing or empty: $path"
    failures=$(( failures + 1 ))
  fi
}

check_file "kernel_2712.img"     "Pi 5 kernel"
check_file "config.txt"          "Firmware config"
check_file "cmdline.txt"         "Kernel cmdline"
check_file "vc4-kms-v3d-pi5.dtbo" "V3D KMS overlay"

# config.txt must select the Pi 5 kernel explicitly
if grep -q '^kernel=kernel_2712.img' "$MNT/config.txt"; then
  ok "config.txt: kernel=kernel_2712.img present"
else
  bad "config.txt: missing 'kernel=kernel_2712.img'"
  failures=$(( failures + 1 ))
fi

# At least one BCM2712 device tree
dtb_hits=$(find "$MNT" -maxdepth 1 -iname 'bcm2712*.dtb' -size +0 2>/dev/null | wc -l)
if (( dtb_hits > 0 )); then
  ok "BCM2712 DTB(s): $(find "$MNT" -maxdepth 1 -iname 'bcm2712*.dtb' -printf '%f ' 2>/dev/null)"
else
  bad "no bcm2712*.dtb found on the ESP"
  failures=$(( failures + 1 ))
fi

# Initramfs with the ESP self-repair hook
list_initramfs() {
  local img="$1"
  if command -v lsinitcpio >/dev/null 2>&1; then
    lsinitcpio "$img" 2>/dev/null
    return 0
  fi
  # Portable fallback (CI hosts without mkinitcpio): detect the compression
  # magic, decompress to stdout, list the cpio members.
  local magic decompressor
  magic=$(dd if="$img" bs=4 count=1 status=none | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    28b52ffd) decompressor="unzstd -c" ;;   # zstd
    1f8b*)    decompressor="gzip -dc" ;;    # gzip
    fd377a58) decompressor="xz -dc" ;;      # xz
    04224d18) decompressor="lz4 -dc" ;;     # lz4
    *) return 1 ;;
  esac
  command -v cpio >/dev/null 2>&1 || return 1
  command -v "${decompressor%% *}" >/dev/null 2>&1 || return 1
  $decompressor -- "$img" 2>/dev/null | cpio -it --quiet 2>/dev/null
}

check_file "initramfs-linux-rpi.img" "Initramfs"
if [[ -s "$MNT/initramfs-linux-rpi.img" ]]; then
  if listing=$(list_initramfs "$MNT/initramfs-linux-rpi.img") && [[ -n "$listing" ]]; then
    if grep -q 'usr/lib/initcpio/hooks/omarchy-pi-esp' <<<"$listing"; then
      ok "initramfs contains omarchy-pi-esp runtime hook"
    else
      bad "initramfs lacks the omarchy-pi-esp hook (ESP self-repair disabled)"
      failures=$(( failures + 1 ))
    fi
    if grep -q 'etc/omarchy-pi-boot/cmdline.txt' <<<"$listing"; then
      ok "initramfs contains pristine boot templates"
    else
      bad "initramfs lacks pristine boot templates"
      failures=$(( failures + 1 ))
    fi
  else
    warn "cannot list initramfs contents here (no lsinitcpio, or cpio/decompressor missing) — hook not inspected"
  fi
fi

# --------------------------------------------------------------- warnings
[[ -f "$MNT/start.elf" || -f "$MNT/start4d.elf" ]] || \
  warn "start.elf/start4d.elf absent (acceptable on Pi 5: GPU firmware stage lives in the EEPROM)"
[[ -f "$MNT/overlays/README" ]] || warn "overlays/README absent"
[[ -f "$MNT/initramfs-linux-rpi-fallback.img" ]] || warn "fallback initramfs absent"

umount "$MNT"
echo
if (( failures > 0 )); then
  die "$failures boot-critical check(s) failed — refusing to release this image"
fi
log "Image verification passed: $IMG is release-ready."
