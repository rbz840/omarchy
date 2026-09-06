#!/bin/bash
# install/pi/01-detect.sh — hardware detection & preflight for Omarchy ARM64.
# Exits non-zero (and logs why) if this machine cannot run the port.

set -uo pipefail

OMARCHY_ARM_ROOT="${OMARCHY_ARM_ROOT:-/opt/omarchy}"
# shellcheck source=../lib/common.sh
source "$OMARCHY_ARM_ROOT/install/lib/common.sh"

require_root

# 1. Architecture
if ! is_aarch64; then
  omarchy_arm_die "Unsupported architecture: $(uname -m). This port targets aarch64 only."
fi

# 2. Raspberry Pi 5 detection
if is_rpi5; then
  omarchy_arm_log "Detected: $(tr -d '\0' < /proc/device-tree/model)"
else
  omarchy_arm_warn "Model is not 'Raspberry Pi 5' — continuing, but Pi 5-specific firmware may not apply."
fi

# 3. BCM2712 SoC sanity (compatible /proc/cpuinfo part)
if ! grep -qi "BCM2712\|Raspberry Pi 5" /proc/cpuinfo /proc/device-tree/compatible 2>/dev/null; then
  omarchy_arm_warn "BCM2712 signature not found in /proc/cpuinfo or device-tree compatible."
fi

# 4. Kernel must be linux-rpi (Pi downstream) — check for Pi-specific module
if [[ ! -d /lib/modules/$(uname -r) ]]; then
  omarchy_arm_die "Kernel modules for $(uname -r) missing — kernel/initramfs mismatch?"
fi
if ! grep -q "vc4\|v3d" /lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null; then
  omarchy_arm_warn "vc4/v3d not found in modules.builtin — Pi GPU may not initialize."
fi

# 5. Minimum RAM check (Omarchy desktop needs ~2 GB; 8 GB recommended)
if [[ -r /proc/meminfo ]]; then
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  if (( mem_kb < 1500000 )); then
    omarchy_arm_die "Not enough RAM: ${mem_kb} kB (Omarchy desktop needs at least 1.5 GB)."
  fi
  if (( mem_kb < 3500000 )); then
    omarchy_arm_warn "Only ~4 GB RAM detected — desktop usable but agents may swap under load."
  fi
fi

# 6. Boot medium: log it (SD, USB, or NVMe)
root_src="$(findmnt -n -o SOURCE /)"
omarchy_arm_log "Root device: $root_src"

omarchy_arm_log "Preflight OK — hardware is compatible with Omarchy ARM64."
exit 0
