# syntax=docker/dockerfile:1
# Omarchy ARM64 image builder container.
#
# The container runs the actual image assembly (partitioning, pacstrap,
# firstboot wiring) under `--platform linux/arm64`: emulated via QEMU binfmt
# on x86_64 hosts, native on aarch64 hosts (ARM CI runners, Pi 5).
#
# Base image note: there is NO official Arch Linux arm64 container image —
# verified 2026-09-06 against both registries:
#   ghcr.io/archlinux/archlinux        -> amd64-only single-arch manifest
#   docker.io/library/archlinux        -> amd64 (+ attestation) index only
# So the builder base is bootstrapped from the Arch Linux ARM rootfs tarball:
# a multi-arch debian helper stage downloads + md5-verifies + extracts it,
# and the builder stage is FROM scratch with that rootfs COPYied in.
#
# Build context: repository root.

# --- Stage 1: fetch + extract the ALARM aarch64 rootfs (any host arch) --------
FROM debian:stable-slim AS alarm-rootfs
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl ca-certificates gzip tar findutils coreutils \
 && rm -rf /var/lib/apt/lists/*
# ADD cannot extract remote tarballs, so download first, then extract.
# Keep ALARM's canonical filename: the .md5 references it by name, so
# `md5sum -c` fails if we save the download under a different name.
RUN curl -fsSL --retry 5 -o /tmp/ArchLinuxARM-aarch64-latest.tar.gz \
      http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz \
 && curl -fsSL --retry 5 -o /tmp/ArchLinuxARM-aarch64-latest.tar.gz.md5 \
      http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz.md5 \
 && cd /tmp \
 && md5sum -c ArchLinuxARM-aarch64-latest.tar.gz.md5 \
 && mkdir -p /alarm-root \
 && tar -xzf /tmp/ArchLinuxARM-aarch64-latest.tar.gz -C /alarm-root --numeric-owner \
 && rm -f /tmp/ArchLinuxARM-aarch64-latest.tar.gz /tmp/ArchLinuxARM-aarch64-latest.tar.gz.md5

# --- Stage 2: the builder = the ALARM aarch64 rootfs ---------------------------
FROM scratch
COPY --from=alarm-rootfs /alarm-root/ /

ENV LANG=C.UTF-8

# Retry-friendly pacman setup for container bootstrap (ALARM repos).
# DisableSandbox: pacman 6.1+ sandboxes DB syncs with Landlock + the 'alpm'
# user, which BuildKit's seccomp profile blocks ("Landlock ruleset could not
# be applied") — we run as root in a throwaway build container, so the
# sandbox buys nothing. No `|| true`: a failed pacman must fail the build.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
 && pacman-key --init \
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
 && pacman -Scc --noconfirm

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
