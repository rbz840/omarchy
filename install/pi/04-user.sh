#!/bin/bash
# install/pi/04-user.sh — user provisioning (Omarchy upstream flow, adapted).
#
# Creates the 'omarchy' user, installs Omarchy dotfiles/configs from the
# overlay at /opt/omarchy, and wires up the agents (bar, launcher, notifications,
# CLI agents). Everything below mirrors upstream install/user/* — adapted only
# for the absence of a GUI installer on firstboot.

set -uo pipefail

OMARCHY_ARM_ROOT="${OMARCHY_ARM_ROOT:-/opt/omarchy}"
# shellcheck source=../lib/common.sh
source "$OMARCHY_ARM_ROOT/install/lib/common.sh"

require_root

OMARCHY_USER="${OMARCHY_USER:-omarchy}"

# --- 1. User creation (idempotent) -------------------------------------------
if ! id "$OMARCHY_USER" &>/dev/null; then
  omarchy_arm_log "Creating user: $OMARCHY_USER"
  useradd -m -G wheel,audio,video,input,uucp -s /bin/bash "$OMARCHY_USER"
  # Lock the account: the user unlocks it by choosing a password in SDDM /
  # at first console login (or via `sudo passwd omarchy` from another seat).
  passwd -l "$OMARCHY_USER" >/dev/null 2>&1 || true
else
  omarchy_arm_log "User $OMARCHY_USER already exists — skipping creation"
fi

# --- 2. Wheel sudo -------------------------------------------------------------
if [[ -f /etc/sudoers.d/10-installer ]]; then
  omarchy_arm_log "Sudoers already configured"
else
  omarchy_arm_log "Enabling wheel sudo"
  echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-installer
  chmod 440 /etc/sudoers.d/10-installer
fi

# --- 2b. Temporary passwordless sudo for AUR builds -----------------------------
# Stage 05 (AUR builds via yay) runs right after this stage while the account
# is still locked; grant temporary NOPASSWD to the build user and drop it in
# stage 06 (see install/pi/06-post-install.sh). No NOPASSWD persists in the
# final image.
rm -f /etc/sudoers.d/20-omarchy-build
cat > /etc/sudoers.d/20-omarchy-build <<EOF
$OMARCHY_USER ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/20-omarchy-build

# --- 3. Omarchy dotfiles / configs --------------------------------------------
omarchy_arm_log "Installing Omarchy configs to /home/$OMARCHY_USER"
omarchy_home="/home/$OMARCHY_USER"
mkdir -p "$omarchy_home/.config"

# Copy default configs from the overlay (same tree upstream uses)
if [[ -d "$OMARCHY_ARM_ROOT/config" ]]; then
  cp -r "$OMARCHY_ARM_ROOT/config/." "$omarchy_home/.config/"
  chown -R "$OMARCHY_USER:$OMARCHY_USER" "$omarchy_home/.config"
fi

# --- 4. Enable the Omarchy runtime environment --------------------------------
omarchy_arm_log "Exporting OMARCHY_PATH for the session"
if ! grep -q OMARCHY_PATH "$omarchy_home/.profile" 2>/dev/null; then
  cat >> "$omarchy_home/.profile" <<EOF
export OMARCHY_PATH="$OMARCHY_ARM_ROOT"
EOF
fi
if [[ -d "$OMARCHY_ARM_ROOT/bin" ]]; then
  chmod +x "$OMARCHY_ARM_ROOT"/bin/* 2>/dev/null || true
fi

# --- 4b. Prepare yay cache dirs (build user) ------------------------------------
install -d -o "$OMARCHY_USER" -g "$OMARCHY_USER" \
  "$omarchy_home/.cache/yay" "$omarchy_home/.config/yay"

# --- 5. Enable services (upstream parity) --------------------------------------
omarchy_arm_log "Enabling system services (NetworkManager, bluetooth, sddm)"
systemctl enable NetworkManager.service bluetooth.service sddm.service

omarchy_arm_log "User provisioning complete"
exit 0
