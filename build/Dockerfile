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

# Import + locally sign the ALARM signing keys BEFORE the first pacman -Syu.
# The rootfs tarball ships /usr/share/pacman/keyrings/archlinuxarm.gpg and its
# archlinuxarm-trusted list; --populate imports the keyring and gives the
# trusted keys ownertrust. Without this, every package fails with
# "signature from \"Arch Linux ARM Build System\" ... is unknown trust"
# (observed 2026-09-06, run 34045511921): the key being present in the
# keyring is NOT enough — pacman requires local trust/ownertrust.
# --populate is the official ALARM bootstrap step (archlinuxarm wiki).
RUN pacman-key --init \
 && pacman-key --populate archlinuxarm

# Retry-friendly pacman setup for container bootstrap (ALARM repos).
# DisableSandbox: pacman 6.1+ sandboxes DB syncs with Landlock + the 'alpm'
# user, which BuildKit's seccomp profile blocks ("Landlock ruleset could not
# be applied") — we run as root in a throwaway build container, so the
# sandbox buys nothing. No `|| true`: a failed pacman must fail the build.
#
# Package cache: the builder may run with a host directory bind-mounted at
# /var/cache/pacman/pkg (build/build.sh --pkg-cache) to reuse packages across
# runs. Cleanup is therefore `pacman -Sc` (removes only packages no longer
# installed) and NEVER `-Scc`, which would wipe the mounted cache and defeat
# cross-run reuse.
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf \
 && printf '\n# pacman -Sc/-Scc must never wipe a host-mounted cache dir\n# (see build/build.sh --pkg-cache)\n' >> /etc/pacman.conf \
 && pacman -Syu --noconfirm --needed \
      arch-install-scripts \
      dosfstools \
      e2fsprogs \
      parted \
      gptfdisk \
      rsync \
      squashfs-tools \
      git \
      curl \
      jq \
 && pacman -Sc --noconfirm

# NOTE: no `archiso` here — ALARM does not package it (verified 2026-09-06,
# "target not found: archiso"); the optional ISO build (build-image.sh step 6)
# detects that and skips with a warning. The .img is the primary deliverable.

COPY . /omarchy-arm
WORKDIR /omarchy-arm

# build/build-image.sh performs the actual image assembly
ENTRYPOINT ["/bin/bash", "/omarchy-arm/build/build-image.sh"]
