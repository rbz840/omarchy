#!/bin/bash
# build/build.sh — Omarchy ARM64 (Raspberry Pi 5) build orchestrator (host side).
#
# Wraps Docker/Podman to run build/build-image.sh inside an aarch64 container:
#   - On x86_64 hosts: enables QEMU binfmt for arm64 and runs the builder
#     container with --platform linux/arm64 (full emulation, no native toolchain).
#   - On native aarch64 hosts: runs the same container without emulation.
#
# Usage:
#   ./build/build.sh [options]
#
# Options:
#   --output DIR        Directory for the resulting .img (default: ./out)
#   --size SIZE         Image size before firstboot expansion (default: 16G)
#   --name NAME         Image basename (default: omarchy-arm64-rpi5-YYYYMMDD)
#   --no-iso            Skip the experimental archiso build
#   --iso-only          Only build the experimental ISO, skip the .img
#   --native            Build natively on the current machine (requires aarch64
#                       host + root; skips container entirely)
#   --keep-container    Do not remove the builder container after run
#   -h | --help         Show this help
#
# Requirements (x86_64 host):
#   docker (or podman) with binfmt support:
#     docker run --privileged --rm tonistiigi/binfmt --install arm64
#   ~25 GB free disk space, network access to mirror.archlinuxarm.org.
#
# The image produced is a GPT raw image: p1 = ESP (FAT32, Pi firmware +
# kernel_2712.img + initramfs + config.txt/cmdline.txt), p2 = ext4 rootfs.
# Flash with dd / Raspberry Pi Imager / balenaEtcher to SD, USB3 or NVMe.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/out"
SIZE="16G"
NAME="omarchy-arm64-rpi5-$(date +%Y%m%d)"
BUILD_ISO=1
BUILD_IMG=1
NATIVE=0
KEEP_CONTAINER=0
CONTAINER_ENGINE=""
[[ -n "${CONTAINER_ENGINE_ENV:-}" ]] && CONTAINER_ENGINE="$CONTAINER_ENGINE_ENV"

log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '/^# Usage:/,/^# Requirements/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)         OUTPUT_DIR="$2"; shift 2 ;;
    --size)           SIZE="$2"; shift 2 ;;
    --name)           NAME="$2"; shift 2 ;;
    --no-iso)         BUILD_ISO=0; shift ;;
    --iso-only)       BUILD_IMG=0; shift ;;
    --native)         NATIVE=1; shift ;;
    --keep-container) KEEP_CONTAINER=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

HOST_ARCH="$(uname -m)"

if (( NATIVE )); then
  [[ "$HOST_ARCH" == "aarch64" ]] || die "--native requires an aarch64 host (got $HOST_ARCH)"
  [[ $(id -u) -eq 0 ]] || die "--native must run as root (pacstrap/chroot need it)"
  log "Native build on aarch64 host — invoking build-image.sh directly"
  export OUTPUT_DIR="$OUTPUT_DIR" BUILD_SIZE="$SIZE" BUILD_NAME="$NAME" \
         BUILD_ISO="$BUILD_ISO" BUILD_IMG="$BUILD_IMG"
  exec "$REPO_ROOT/build/build-image.sh"
fi

# --- Container-based build ---------------------------------------------------

detect_engine() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
  elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
  else
    die "No working container engine found. Install Docker (or Podman), or use --native on an aarch64 host."
  fi
}
detect_engine

# Enable aarch64 emulation when building on x86_64.
if [[ "$HOST_ARCH" != "aarch64" ]]; then
  log "Host arch $HOST_ARCH — ensuring QEMU binfmt for arm64 is registered"
  if (( ! KEEP_CONTAINER )); then
    case "$CONTAINER_ENGINE" in
      docker) docker run --privileged --rm tonistiigi/binfmt --install arm64 || warn "binfmt install failed — aarch64 emulation may be unavailable" ;;
      podman) warn "Podman: register binfmt manually (see docs/05-contributing.md) if the build fails on foreign-arch binaries" ;;
    esac
  fi
fi

IMAGE_TAG="omarchy-arm-builder:latest"
log "Building builder container ($IMAGE_TAG)"
case "$CONTAINER_ENGINE" in
  docker) docker build --platform "linux/arm64" -t "$IMAGE_TAG" -f "$REPO_ROOT/build/Dockerfile" "$REPO_ROOT" ;;
  podman) podman build --platform "linux/arm64" -t "$IMAGE_TAG" -f "$REPO_ROOT/build/Dockerfile" "$REPO_ROOT" ;;
esac

mkdir -p "$OUTPUT_DIR"

# Loop device + mount privileges are required for partitioning/mkfs.
RUN_ARGS=(
  --rm --privileged
  --platform "linux/arm64"
  -e BUILD_SIZE="$SIZE"
  -e BUILD_NAME="$NAME"
  -e BUILD_ISO="$BUILD_ISO"
  -e BUILD_IMG="$BUILD_IMG"
  -v "$OUTPUT_DIR:/output"
  -v "$REPO_ROOT:/omarchy-arm:ro"
  "$IMAGE_TAG"
)

log "Running image assembly in aarch64 container"
case "$CONTAINER_ENGINE" in
  docker)
    if (( KEEP_CONTAINER )); then RUN_ARGS=( "${RUN_ARGS[@]/--rm/}" ); fi
    docker run "${RUN_ARGS[@]}"
    ;;
  podman)
    podman run "${RUN_ARGS[@]}"
    ;;
esac

log "Done. Artifacts in: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR" || true
