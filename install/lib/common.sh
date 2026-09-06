# install/lib/common.sh — shared helpers for the Omarchy ARM64 (Pi 5) installer.
# Sourced by install/pi/*.sh — no shebang by upstream convention.

# Directories (overridable for tests)
: "${OMARCHY_ARM_ROOT:=/opt/omarchy}"
: "${OMARCHY_ARM_STATE:=/var/lib/omarchy-firstboot-pi}"
OMARCHY_ARM_LOG_DIR="$OMARCHY_ARM_STATE/logs"
OMARCHY_ARM_STAGES_DIR="$OMARCHY_ARM_STATE/stages"
OMARCHY_ARM_PACKAGES="$OMARCHY_ARM_ROOT/build/packages"

mkdir -p "$OMARCHY_ARM_LOG_DIR" "$OMARCHY_ARM_STAGES_DIR" 2>/dev/null || true

omarchy_arm_log()  { printf '\033[1;34m[omarchy-arm]\033[0m %s\n' "$*" | tee -a "$OMARCHY_ARM_LOG_DIR/install.log"; }
omarchy_arm_warn() { printf '\033[1;33m[omarchy-arm] WARN:\033[0m %s\n' "$*" | tee -a "$OMARCHY_ARM_LOG_DIR/install.log" >&2; }
omarchy_arm_die()  { printf '\033[1;31m[omarchy-arm] ERROR:\033[0m %s\n' "$*" | tee -a "$OMARCHY_ARM_LOG_DIR/install.log" >&2; exit 1; }

require_root() {
  if (( EUID != 0 )); then
    omarchy_arm_die "This script must run as root (systemd firstboot service context)."
  fi
}

is_aarch64() { [[ "$(uname -m)" == "aarch64" ]]; }

is_rpi5() {
  [[ -r /proc/device-tree/model ]] && \
    grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null
}

# Marker-based stage tracking: each stage runs at most once per boot medium
# unless FORCE_STAGE=1 is set in the environment.
stage_done() {
  local stage="$1"
  [[ -f "$OMARCHY_ARM_STAGES_DIR/$stage.done" ]]
}

mark_stage_done() {
  local stage="$1"
  touch "$OMARCHY_ARM_STAGES_DIR/$stage.done"
}

run_stage() {
  local stage="$1"
  local script="$OMARCHY_ARM_INSTALL/pi/$stage"
  if stage_done "$stage" && [[ "${FORCE_STAGE:-0}" != "1" ]]; then
    omarchy_arm_log "Stage $stage already completed — skipping (FORCE_STAGE=1 to rerun)"
    return 0
  fi
  if [[ ! -x "$script" ]]; then
    omarchy_arm_warn "Stage script $stage missing or not executable — skipping"
    return 0
  fi
  omarchy_arm_log ">>> Running stage: $stage"
  if "$script" >>"$OMARCHY_ARM_LOG_DIR/install.log" 2>&1; then
    mark_stage_done "$stage"
    omarchy_arm_log "Stage $stage completed"
  else
    omarchy_arm_die "Stage $stage failed — see $OMARCHY_ARM_LOG_DIR/install.log"
  fi
}

# Install a package list file (one name per line, # comments) via pacman --needed
pacman_install_list() {
  local list_file="$1"
  local pkgs=()
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && pkgs+=("$line")
  done < "$list_file"
  if (( ${#pkgs[@]} == 0 )); then
    omarchy_arm_warn "Empty package list: $list_file"
    return 0
  fi
  pacman -S --needed --noconfirm -- "${pkgs[@]}"
}
