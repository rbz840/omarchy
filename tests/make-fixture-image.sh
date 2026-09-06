#!/bin/bash
# tests/make-fixture-image.sh — build a tiny synthetic Pi 5 image for testing
# tests/verify-image.sh (the CI release gate) without a full image build.
#
# The fixture reproduces exactly the layout the gate inspects: a GPT disk with
# p1 = FAT32 ESP (Pi-firmware boot files) and p2 = ext4 rootfs. cmdline.txt,
# config.txt and the initramfs hook are COPIED FROM THE REPO (build/boot/*,
# build/rootfs/usr/lib/initcpio/hooks/*); the initramfs is a real newc cpio
# archive (bash+gzip only) with the repo's actual member paths — so the gate's
# initramfs inspection runs against genuine member names. kernel_2712.img and
# the DTBs are synthetic stubs (the repo does not ship binaries; the gate only
# checks their presence/size).
#
# Negative knobs (for proving the gate FAILS, not just passes):
#   --omit-cmdline   drop cmdline.txt from the ESP
#   --omit-hook      build the initramfs WITHOUT the omarchy-pi-esp runtime
#   --omit-dtb       drop bcm2712*.dtb from the ESP
#
# Output: <out-dir>/fixture.img (default out/fixture.img), 64 MiB, sparse.
#
# Requirements: root (losetup/mkfs/mount); sgdisk, mkfs.vfat, mkfs.ext4.
# Usage:
#   sudo ./tests/make-fixture-image.sh [options] [out-dir]

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR=""
OMIT_CMDLINE=0 OMIT_HOOK=0 OMIT_DTB=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --omit-cmdline) OMIT_CMDLINE=1; shift ;;
    --omit-hook)    OMIT_HOOK=1;    shift ;;
    --omit-dtb)     OMIT_DTB=1;     shift ;;
    -h|--help) grep '^# \|^#$' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) OUT_DIR="$1"; shift ;;   # positional: output directory
  esac
done
: "${OUT_DIR:=$REPO_ROOT/out}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
FIXTURE="$OUT_DIR/fixture.img"

log() { printf '\033[1;34m[fixture]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[fixture] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

(( EUID == 0 )) || die "run as root (losetup/mkfs/mount required)"
for tool in sgdisk mkfs.vfat mkfs.ext4 losetup mountpoint; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
for f in build/boot/config.txt build/boot/cmdline.txt \
         build/rootfs/usr/lib/initcpio/hooks/omarchy-pi-esp; do
  [[ -s "$REPO_ROOT/$f" ]] || die "missing repo artifact: $f"
done

log "Creating sparse 64 MiB fixture at $FIXTURE"
rm -f "$FIXTURE"
truncate -s 64M "$FIXTURE"

# GPT: p1 ESP 32 MiB (EF00), p2 rootfs (8304) — same layout as the real build
sgdisk -n 1:2048:+32M -t 1:EF00 -n 2:0:0 -t 2:8304 "$FIXTURE" >/dev/null || die "sgdisk failed"

LOOP=$(losetup --find --show --partscan "$FIXTURE") || die "losetup failed"
MNT="$(mktemp -d)"
cleanup() {
  set +e
  mountpoint -q "$MNT" && umount "$MNT"
  [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkfs.vfat -F 32 -n OMARCHY "${LOOP}p1" >/dev/null || die "mkfs.vfat failed"
mount "${LOOP}p1" "$MNT" || die "mount ESP failed"

# --- ESP: boot files ----------------------------------------------------------------
# cmdline.txt/config.txt: the repo's real templates (gate greps config.txt for
# 'kernel=kernel_2712.img'). kernel/DTBs/overlay: synthetic stubs — the repo
# ships no binaries and the gate only verifies presence + non-zero size.
cp "$REPO_ROOT/build/boot/config.txt"               "$MNT/"
cp "$REPO_ROOT/build/boot/cmdline.txt"              "$MNT/"
head -c 1M /dev/urandom > "$MNT/kernel_2712.img"
# Minimal but realistic bcm2712 DTB stubs (gate checks name/presence/size)
printf 'dts-v1/;\n/ { compatible = "brcm,bcm2712"; };\n' > "$MNT/bcm2712-rpi-5-b.dtb"
mkdir -p "$MNT/overlays"
printf 'name_override = "vc4-kms-v3d-pi5"\n' > "$MNT/overlays/vc4-kms-v3d-pi5.dtbo"
(( OMIT_CMDLINE )) && rm -f "$MNT/cmdline.txt"
(( OMIT_DTB ))     && rm -f "$MNT"/bcm2712-*.dtb

# --- Initramfs fixture: real newc cpio with the repo's hook + templates ----------
log "Building initramfs fixture (newc cpio -> gzip)"
CPIO_DIR="$(mktemp -d)"
install -Dm644 "$REPO_ROOT/build/boot/cmdline.txt" "$CPIO_DIR/etc/omarchy-pi-boot/cmdline.txt"
install -Dm644 "$REPO_ROOT/build/boot/config.txt"  "$CPIO_DIR/etc/omarchy-pi-boot/config.txt"
mkdir -p "$CPIO_DIR/usr/lib/initcpio/hooks"
cp "$REPO_ROOT/build/rootfs/usr/lib/initcpio/hooks/omarchy-pi-esp" \
   "$CPIO_DIR/usr/lib/initcpio/hooks/omarchy-pi-esp"
(( OMIT_HOOK )) && rm -f "$CPIO_DIR/usr/lib/initcpio/hooks/omarchy-pi-esp"

# newc cpio in pure bash: 110-byte ASCII header + name + data, 4-byte alignment
CPIO="$CPIO_DIR/initramfs.cpio"
: > "$CPIO"
while IFS= read -r -d '' f; do
  name="${f#"$CPIO_DIR"/}"
  filesize=$(wc -c < "$f")
  namesize=$(( ${#name} + 1 ))
  { printf '070701'
    for v in 0 0 0 0 1 0 "$filesize" 0 0 0 0 "$namesize" 0; do
      printf '%08X' "$v"
    done
    printf '%s\0' "$name"
  } >> "$CPIO"
  pad=$(( (4 - (110 + namesize) % 4) % 4 ))
  (( pad )) && printf '%0.s\0' $(seq 1 "$pad") >> "$CPIO"
  cat "$f" >> "$CPIO"
  pad=$(( (4 - filesize % 4) % 4 ))
  (( pad )) && printf '%0.s\0' $(seq 1 "$pad") >> "$CPIO"
done < <(find "$CPIO_DIR" -type f ! -name "$(basename "$CPIO")" -print0)
# trailer (name "TRAILER!!!" = 10 chars + NUL -> namesize 11)
{ printf '070701'
  for v in 0 0 0 0 1 0 0 0 0 0 0 11 0; do printf '%08X' "$v"; done
  printf 'TRAILER!!!\0'
} >> "$CPIO"
pad=$(( (4 - (110 + 11) % 4) % 4 ))
(( pad )) && printf '%0.s\0' $(seq 1 "$pad") >> "$CPIO"
pad=$(( (512 - $(wc -c < "$CPIO") % 512) % 512 ))
(( pad )) && printf '%0.s\0' $(seq 1 "$pad") >> "$CPIO"

gzip -c "$CPIO" > "$MNT/initramfs-linux-rpi.img"
sync
umount "$MNT"

# --- p2: rootfs (presence only — the gate does not inspect it) --------------------
mkfs.ext4 -q -L omarchy-root "${LOOP}p2" || die "mkfs.ext4 failed"

log "Fixture written: $FIXTURE"
[[ $OMIT_CMDLINE -eq 1 ]] && log "  (negative fixture: cmdline.txt omitted)"
[[ $OMIT_HOOK    -eq 1 ]] && log "  (negative fixture: omarchy-pi-esp hook omitted)"
[[ $OMIT_DTB     -eq 1 ]] && log "  (negative fixture: bcm2712 DTBs omitted)"
