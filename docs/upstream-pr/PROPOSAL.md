# Upstream PR proposal — Raspberry Pi 5 hardware support layer

> Candidate PR for [`omacom/omarchy`](https://github.com/omacom/omarchy) (branch `quattro`).
> The PR description below is ready to paste into GitHub; the candidate files are
> in this folder: `install/hardware/raspberry-pi5.sh` and
> `bin/omarchy-hw-raspberrypi5`.
> Prepared 2026-09-06 · Reference discussion: [#7960 — FR: Support aarch64](https://github.com/omacom/omarchy/discussions/7960)

---

## Title

```
Add Raspberry Pi 5 hardware support (detector + firmware/boot packages)
```

## Summary

Adds first-class hardware support for the Raspberry Pi 5 (BCM2712, aarch64) to
Omarchy's hardware layer — the same treatment every other platform already
gets (ASUS, Framework, T2 Macs, Surface, Dell, Lenovo) — without touching the
ISO, the installer flow, or any existing script. Users on Arch Linux ARM (or
any Arch-based aarch64 base) can run Omarchy's own `omarchy-apply-hardware`
and get the Pi-specific pieces installed.

Two files, both strictly additive:

- **`bin/omarchy-hw-raspberrypi5`** — a new `omarchy-hw-*` detector following
  the existing one-liner convention (`omarchy:summary=` marker, exit-code
  contract). aarch64-gated, so it is false on every x86_64 machine.
- **`install/hardware/raspberry-pi5.sh`** — a hardware leaf guarded by that
  detector. Installs the Pi firmware/boot packages (Arch Linux ARM repo names)
  when running on a Pi 5. No-op everywhere else.

An accompanying `all.sh` one-liner wires the leaf into the standard orchestration
(see "Changes" — the only line touching an existing file).

## Why

- aarch64 is the most requested platform gap (discussion #7960, plus multiple
  "Omarchy on ARM" threads); the Pi 5 is the highest-volume aarch64 desktop
  board and already runs Hyprland well on its V3D GPU (Mesa `v3d`, Vulkan
  `vulkan-broadcom`).
- Omarchy's hardware layer is the natural integration point: it is designed
  for exactly this pattern — a detector + guarded leaf — and currently has no
  ARM representation at all. Adding it costs nothing on existing installs and
  makes "Omarchy on Pi" a supported configuration instead of a workaround.
- The packages installed here are repo packages (Arch Linux ARM `core`/`alarm`
  repos: `firmware-raspberrypi`, `raspberrypi-utils`, `rpi5-eeprom`), verified
  against the live ALARM databases on 2026-09-06 — no AUR, no new repo, no
  x86 regression surface.

## What it does / does not do

**Does (on a Pi 5, aarch64):**
- installs `firmware-raspberrypi` (WiFi CYW43455 + Bluetooth firmware),
  `raspberrypi-utils` (vcgencmd etc.), `rpi5-eeprom` (EEPROM update tooling
  for USB/NVMe boot);
- leaves every other Omarchy component untouched — the desktop itself is
  already architecture-neutral.

**Does not:**
- change the ISO, the installer orchestration, `mkinitcpio`, kernel selection,
  or anything x86-specific (`nvidia.sh`, `vulkan.sh`, `intel/*` are untouched —
  their `lspci`/DMI guards simply do not match on Pi hardware);
- add repositories, force a kernel, or install anything on non-aarch64
  machines (detector exits 1 before any package operation).

## Changes

```diff
 # new file: bin/omarchy-hw-raspberrypi5
+#!/bin/bash
+# omarchy:summary=Detect whether the machine is a Raspberry Pi 5 (BCM2712, aarch64).
+[[ $(uname -m) == "aarch64" ]] &&
+{
+  grep -q "bcm2712" /proc/device-tree/compatible 2>/dev/null ||
+  grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null
+}
+
 # new file: install/hardware/raspberry-pi5.sh
+if omarchy-hw-raspberrypi5; then
+  # Raspberry Pi 5 firmware/boot packages — Arch Linux ARM repository names.
+  # The detector is aarch64-gated, so this never resolves on x86_64 installs.
+  omarchy-pkg-add firmware-raspberrypi raspberrypi-utils rpi5-eeprom
+fi
+
 # install/hardware/all.sh — one line, appended to the platform section:
+run_logged "$OMARCHY_INSTALL/hardware/raspberry-pi5.sh"
```

## Conventions followed

- Detector: `#!/bin/bash`, `# omarchy:summary=…` marker, single boolean
  expression, exit-code contract (same shape as `omarchy-hw-asus-rog`,
  `omarchy-hw-intel`).
- Leaf: no shebang, sourced via `run_logged`, no `exit`, guards everything on
  the detector, uses `omarchy-pkg-add` (per `agents/skills/install-scripts.md`).
- Style: 2-space indent, `[[ ]]` conditionals, no hard-wrapped docs
  (`.editorconfig`, `AGENTS.md`).

## Testing

- Detector logic exercised against `/proc/device-tree/compatible` (`bcm2712`)
  and `/proc/device-tree/model` (`Raspberry Pi 5`) — see the full port at
  [`rbz840/omarchy`](https://github.com/rbz840/omarchy), which uses this exact
  detector; on-Pi validation lives in
  `tests/validate-pi-hardware.sh` there.
- `tests/check-pkg-availability.sh` in the same fork verifies every package
  name in the leaf exists in the live ALARM repos (currently 191/191 repo
  packages pass, including the three installed here).
- On x86_64 the leaf is a provable no-op: the detector gates on
  `uname -m == aarch64` before any action.

## Notes / known platform limits (context for reviewers)

Out of scope for this leaf but documented in the fork: no Secure Boot/TPM
(firmware limitation), boot via native device-tree (the EDK2 rpi5-uefi port is
archived upstream), HEVC decode via the VideoCore VI V4L2-request path (stock
ALARM ffmpeg/mpv lack the v4l2request hwdec — verified by binary inspection —
so mpv software-decodes with GPU compositing; an ffmpeg built with
`--enable-v4l2-request`, mainlined in FFmpeg 8.0, restores full hw decode),
Vulkan 1.3 via `vulkan-broadcom`. Full technical report:
[`REPORT.md` in rbz840/omarchy](https://github.com/rbz840/omarchy/blob/quattro/REPORT.md).

---

### Checklist (repo conventions)

- [x] Atomic change: one detector + one guarded leaf + one `all.sh` line
- [x] No shebangs on sourced leaves; no `exit` in them
- [x] `$OMARCHY_INSTALL`-relative orchestration, no hard-coded paths
- [x] Packages verified against target-arch repos; documented in commit body
- [x] Docs updated in the fork (install guide, limitations, contributing)
