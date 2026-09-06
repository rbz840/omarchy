#!/bin/bash
# tests/qemu-esp-restore-test.sh — end-to-end test of the omarchy-pi-esp
# initramfs hook under QEMU (aarch64).
#
# What it does, on a COPY of the image (the original is never modified):
#
#   Boot 1  image kernel + initramfs, ESP intact
#           -> expect "omarchy-pi-esp: ESP verified, no repair needed"
#   Host    delete cmdline.txt from the ESP (partition 1)
#   Boot 2  same boot, ESP missing cmdline.txt
#           -> expect "omarchy-pi-esp: RESTORED missing cmdline.txt (root=/dev/sda2)"
#   Host    verify cmdline.txt exists again on the ESP, carrying root=/dev/sda2
#
# Why -kernel/-initrd instead of UEFI: the image's ESP carries Pi-firmware
# boot files (config.txt + kernel_2712.img), not an EFI bootloader, so QEMU's
# UEFI cannot boot it. Passing the image's REAL kernel + initramfs directly
# still exercises the exact artifacts that ship (kernel_2712.img,
# initramfs-linux-rpi.img, the omarchy-pi-esp hook, busybox early userspace).
# The kernel cmdline comes from -append (QEMU), not the ESP — exactly like
# the Pi, where firmware hands the kernel its cmdline — so a deleted ESP
# cmdline.txt does not block booting; it only removes the file the hook must
# restore. The disk is attached as a USB mass-storage device (qemu-xhci +
# usb-storage): linux-rpi has NO virtio drivers (Pi hardware has none, and
# force-adding virtio modules fails mkinitcpio — CI run 34048432400), while
# USB is the Pi's real USB-boot path and IS in the initramfs. root=/dev/sda2
# additionally proves the hook rewrites root= to the ACTUAL boot medium
# rather than parroting the SD-card template.
#
# Requirements: qemu-system-aarch64; root (losetup/mount). Runs in CI on
# ubuntu-24.04-arm (tcg software emulation; the hook under test runs in early
# userspace, so the test never needs a full desktop boot to pass).
#
# Usage:
#   sudo ./tests/qemu-esp-restore-test.sh out/omarchy-arm64-rpi5-YYYYMMDD.img
# Options (env):
#   QEMU_TIMEOUT_S   per-boot timeout         (default 300)
#   KEEP_TEST_IMG=1  keep the working copy + logs for debugging

set -uo pipefail

IMG="${1:-}"
[[ -n "$IMG" && -f "$IMG" ]] || { echo "usage: $0 <image.img>" >&2; exit 2; }
IMG="$(readlink -f "$IMG")"

QEMU_TIMEOUT_S="${QEMU_TIMEOUT_S:-300}"
QEMU_BIN="${QEMU_BIN:-qemu-system-aarch64}"

log()  { printf '\033[1;34m[qemu-test]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[qemu-test] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

command -v "$QEMU_BIN" >/dev/null 2>&1 || die "$QEMU_BIN not found (apt install qemu-system-arm)"
(( EUID == 0 )) || die "run as root (losetup/mount required)"
command -v timeout >/dev/null 2>&1 || die "coreutils 'timeout' required"

# Acceleration: KVM on native arm64 hosts with /dev/kvm, else tcg emulation.
if [[ "$(uname -m)" == "aarch64" && -w /dev/kvm ]]; then
  QEMU_ACCEL=( -accel kvm -cpu host )
  log "Acceleration: KVM (native)"
else
  QEMU_ACCEL=( -accel tcg,thread=multi -cpu max )
  log "Acceleration: tcg (software emulation)"
fi

WORK="$(mktemp -d /tmp/omarchy-qemu-esp-XXXXXX)"
LOOP=""
MNT_ESP="$WORK/esp"
LOGDIR="$PWD/qemu-test-logs"
mkdir -p "$MNT_ESP"

cleanup() {
  local rc=$?
  set +e
  mountpoint -q "$MNT_ESP" && umount "$MNT_ESP"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
  if [[ "${KEEP_TEST_IMG:-0}" == "1" ]]; then
    log "KEEP_TEST_IMG=1 — working copy and logs kept at $WORK"
  else
    rm -rf "$WORK"
  fi
  exit $rc
}
trap cleanup EXIT

# Copy boot console logs next to the CWD so CI can upload them as artifacts.
save_logs() {
  mkdir -p "$LOGDIR"
  cp -f "$WORK"/boot*.log "$WORK"/qemu*.out "$LOGDIR"/ 2>/dev/null || true
}

attach_loop() {
  LOOP=$(losetup --find --show --partscan "$WORK/test.img") || die "losetup failed"
  # Hosted runners may load the loop module with max_part=0: partscan creates
  # no partition nodes. Kernel-side partitions appear under /sys either way —
  # materialize the /dev nodes from major:minor when missing.
  if [[ ! -e "${LOOP}p1" || ! -e "${LOOP}p2" ]]; then
    partprobe "$LOOP" 2>/dev/null; partx -a "$LOOP" 2>/dev/null || true
  fi
  local base="${LOOP##*/}" sp maj
  for sp in "/sys/block/$base/$base"p1 "/sys/block/$base/$base"p2; do
    [[ -e "${LOOP}${sp##*/$base}" ]] && continue
    [[ -r "$sp/dev" ]] || die "partition node missing and no sysfs entry: $sp"
    maj="$(cat "$sp/dev")"
    mknod "${LOOP}${sp##*/$base}" b "${maj%%:*}" "${maj##*:}" || die "mknod ${LOOP}${sp##*/$base} failed"
    chmod 660 "${LOOP}${sp##*/$base}"
  done
  [[ -e "${LOOP}p1" && -e "${LOOP}p2" ]] || die "expected ${LOOP}p1/p2 partitions"
}
detach_loop() {
  umount "$MNT_ESP" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null
  LOOP=""
}

run_boot() {  # $1 = boot number, $2 = expected console marker
  local n="$1" marker="$2"
  log "Boot $n: starting QEMU (timeout ${QEMU_TIMEOUT_S}s)"
  # -kernel/-initrd/-append: direct boot of the image's real kernel+initramfs
  # (rationale in the header). panic=-1 + -no-reboot: any panic exits QEMU
  # instead of hanging. systemd.unit=multi-user.target: skip the desktop.
  # Disk on a USB bus (qemu-xhci + usb-storage): linux-rpi ships no virtio
  # drivers; usb-storage + xhci_pci are force-included in the initramfs and
  # mirror the Pi's real USB-boot path.
  timeout --foreground "$QEMU_TIMEOUT_S" "$QEMU_BIN" \
      -machine virt -m 1024 -smp 2 \
      "${QEMU_ACCEL[@]}" \
      -kernel "$WORK/kernel.img" \
      -initrd "$WORK/initrd.img" \
      -append "root=/dev/sda2 rw rootwait console=ttyAMA0 panic=-1 systemd.unit=multi-user.target" \
      -drive "id=usbdrv,file=$WORK/test.img,format=raw,if=none" \
      -device qemu-xhci -device usb-storage,drive=usbdrv \
      -display none -serial "file:$WORK/boot$n.log" -no-reboot \
      >"$WORK/qemu$n.out" 2>&1
  # We deliberately do NOT require a clean shutdown: the behavior under test
  # happens in early userspace; a late-boot hang/timeout must not mask a hook
  # success already recorded in the console log.
  grep -q "$marker" "$WORK/boot$n.log" 2>/dev/null
}

show_hook_lines() {  # $1 = boot log — print hook output for diagnosis
  if grep -q "omarchy-pi-esp" "$1" 2>/dev/null; then
    grep "omarchy-pi-esp" "$1" | tail -10 | sed 's/^/       /' >&2
  else
    echo "       (no omarchy-pi-esp output at all — hook never ran?)" >&2
    tail -20 "$1" 2>/dev/null | sed 's/^/       /' >&2
  fi
}

# --- 0. Working copy ----------------------------------------------------------
log "Preparing working copy (original image untouched)"
cp --sparse=always "$IMG" "$WORK/test.img" || die "copy failed"

# --- 1. Extract kernel + initramfs from the image ------------------------------
log "Extracting kernel_2712.img + initramfs-linux-rpi.img from the image"
attach_loop
mount -o ro "${LOOP}p1" "$MNT_ESP" || die "cannot mount ESP read-only"
[[ -s "$MNT_ESP/kernel_2712.img" ]]         || { umount "$MNT_ESP"; detach_loop; die "kernel_2712.img missing from ESP"; }
[[ -s "$MNT_ESP/initramfs-linux-rpi.img" ]] || { umount "$MNT_ESP"; detach_loop; die "initramfs-linux-rpi.img missing from ESP"; }
cp "$MNT_ESP/kernel_2712.img"         "$WORK/kernel.img"
cp "$MNT_ESP/initramfs-linux-rpi.img" "$WORK/initrd.img"
umount "$MNT_ESP"
detach_loop
# The loop MUST be detached before QEMU runs: a concurrent losetup mapping of
# the same file makes the guest see a frozen/stale disk.
ok "kernel + initramfs extracted"

# --- 2. Boot 1: intact ESP -------------------------------------------------------
log "Boot 1: ESP intact — expect 'ESP verified, no repair needed'"
if run_boot 1 "omarchy-pi-esp: ESP verified, no repair needed"; then
  ok "Boot 1: hook verified the intact ESP (no repair)"
else
  bad "Boot 1: expected no-op marker in console log:"
  show_hook_lines "$WORK/boot1.log"
  save_logs
  die "Boot 1 failed (logs copied to $LOGDIR)"
fi

# --- 3. Sabotage: delete cmdline.txt from the ESP --------------------------------
log "Deleting cmdline.txt from the ESP (partition 1)"
attach_loop
mount -o rw "${LOOP}p1" "$MNT_ESP" || { detach_loop; die "cannot mount ESP rw"; }
rm -f "$MNT_ESP/cmdline.txt"
sync
umount "$MNT_ESP"
# Confirm it is really gone (read-only re-check on the still-attached loop)
mount -o ro "${LOOP}p1" "$MNT_ESP" || { detach_loop; die "ESP re-check mount failed"; }
if [[ -s "$MNT_ESP/cmdline.txt" ]]; then
  umount "$MNT_ESP"; detach_loop
  die "cmdline.txt still present after deletion?!"
fi
umount "$MNT_ESP"
detach_loop
ok "cmdline.txt deleted"

# --- 4. Boot 2: broken ESP --------------------------------------------------------
log "Boot 2: ESP missing cmdline.txt — expect RESTORED marker with root=/dev/sda2"
if run_boot 2 "omarchy-pi-esp: RESTORED missing cmdline.txt (root=/dev/sda2)"; then
  ok "Boot 2: hook restored cmdline.txt, rewriting root= to the real boot medium"
else
  bad "Boot 2: expected RESTORED marker (root=/dev/sda2) in console log:"
  show_hook_lines "$WORK/boot2.log"
  save_logs
  die "Boot 2 failed (logs copied to $LOGDIR)"
fi

# --- 5. Post-boot verification of the repaired ESP --------------------------------
log "Verifying restored cmdline.txt on the ESP"
attach_loop
mount -o ro "${LOOP}p1" "$MNT_ESP" || { detach_loop; die "cannot mount ESP after boot 2"; }
verify_failed=0
if [[ -s "$MNT_ESP/cmdline.txt" ]]; then
  ok "cmdline.txt present again ($(wc -c < "$MNT_ESP/cmdline.txt") bytes)"
  if grep -q "root=/dev/sda2" "$MNT_ESP/cmdline.txt"; then
    ok "restored cmdline.txt carries the ACTUAL boot medium (root=/dev/sda2)"
  else
    bad "restored cmdline.txt lacks root=/dev/sda2:"
    sed 's/^/       /' "$MNT_ESP/cmdline.txt" >&2
    verify_failed=1
  fi
  grep -q "rootwait" "$MNT_ESP/cmdline.txt" || \
    bad "WARNING: restored cmdline.txt lost rootwait (non-fatal)"
else
  bad "cmdline.txt still missing after restore boot:"
  ls -la "$MNT_ESP" | sed 's/^/       /' >&2
  verify_failed=1
fi
umount "$MNT_ESP"
detach_loop
(( verify_failed == 0 )) || { save_logs; die "post-boot verification failed (logs in $LOGDIR)"; }

echo
log "ALL CHECKS PASSED — omarchy-pi-esp ESP self-repair works end-to-end under QEMU."
