#!/bin/bash
# install/pi/03-pacstrap.sh — Omarchy ARM64 package installation.
#
# Runs ON the Pi (firstboot), not on the build host. The base rootfs already
# contains linux-rpi + firmware from the image build; this stage installs the
# full Omarchy desktop package set from build/packages/*.packages.
#
# Idempotent: pacman -S --needed is a no-op for already-installed packages.

set -uo pipefail

OMARCHY_ARM_ROOT="${OMARCHY_ARM_ROOT:-/opt/omarchy}"
# shellcheck source=../lib/common.sh
source "$OMARCHY_ARM_ROOT/install/lib/common.sh"

require_root

omarchy_arm_log "Refreshing pacman databases (ALARM mirrors)"
pacman -Sy --noconfirm

omarchy_arm_log "Installing Omarchy ARM64 base package set"
pacman_install_list "$OMARCHY_ARM_PACKAGES/omarchy-pi5-base.packages" || \
  omarchy_arm_die "Base package installation failed"

omarchy_arm_log "Installing Omarchy ARM64 'other' package set"
pacman_install_list "$OMARCHY_ARM_PACKAGES/omarchy-pi5-other.packages" || \
  omarchy_arm_die "'Other' package installation failed"

# Note: Omarchy-specific packages (herdr, tensaku, cliamp, …) are AUR
# packages — installed by 05-pi-specific.sh via yay (see build/packages/aur.txt).

omarchy_arm_log "Package installation complete"
exit 0
