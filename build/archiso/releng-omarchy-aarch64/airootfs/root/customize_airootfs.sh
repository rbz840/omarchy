#!/bin/bash
# archiso airootfs customization for the Omarchy aarch64 live ISO.
# Runs inside the airootfs chroot at build time.

set -e

# Enable networking in the live session
systemctl enable NetworkManager.service
systemctl enable systemd-resolved.service

# Prompt to set root password on first login of the live session
if [[ ! -e /root/.pw-prompt-shown ]]; then
  cat >> /root/.bashrc <<'EOF'
# Omarchy live ISO: quick start hint
cat <<'HINT'
==================================================================
 Omarchy ARM64 (experimental live ISO) — Pi 5 netboot installer.

 Install Omarchy to your target disk with:
   $ omarchy-pi-install

 (This ISO is experimental. The primary deliverable is the raw
  .img — see https://github.com/rbz840/omarchy)
==================================================================
HINT
EOF
  touch /root/.pw-prompt-shown
fi
