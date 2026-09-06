# syntax=docker/dockerfile:1
# Omarchy ARM64 image builder container.
#
# Build context: repository root. The container runs the actual image
# assembly (partitioning, pacstrap, firstboot wiring). When invoked with
# `--platform linux/arm64` (the default path in build/build.sh on x86_64
# hosts), the whole build runs under QEMU user emulation via Docker
# binfmt — no cross-compile toolchain needed on the host.
#
# On native aarch64 hosts (Pi 5, ARM CI runners) the same Dockerfile is
# used without emulation.

FROM archlinux:base-devel

# Retry-friendly pacman setup for container bootstrap
RUN pacman-key --init \
 && pacman -Syu --noconfirm --needed \
      arch-install-scripts \
      archiso \
      dosfstools \
      e2fsprogs \
      parted \
      gptfdisk \
      rsync \
      squashfs-tools \
      git \
      curl \
      jq \
 && pacman -Scc --noconfirm || true

# Import the Arch Linux ARM build-system signing key into the container
# keyring. pacstrap copies this keyring into the target rootfs, which lets
# ALARM-signed packages verify from the very first install.
# Key: 68B3537F39A313B3E574D06777193F152BDBE6A6 (Arch Linux ARM Build System)
RUN pacman-key --init \
 && (pacman-key -r 68B3537F39A313B3E574D06777193F152BDBE6A6 \
        --keyserver hkps://keyserver.ubuntu.com \
     || pacman-key -r 68B3537F39A313B3E574D06777193F152BDBE6A6 \
        --keyserver hkps://keys.openpgp.org) \
 && pacman-key --lsign-key 68B3537F39A313B3E574D06777193F152BDBE6A6

COPY . /omarchy-arm
WORKDIR /omarchy-arm

# build/build-image.sh performs the actual image assembly
ENTRYPOINT ["/bin/bash", "/omarchy-arm/build/build-image.sh"]
