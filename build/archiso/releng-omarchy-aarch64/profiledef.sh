#!/bin/bash
# build/archiso/releng-omarchy-aarch64/profiledef.sh
# Experimental archiso profile for an aarch64 netboot ISO.
#
# Purpose: not a graphical installer. This ISO boots on Pi 5 only via a
# U-Boot chain (booti + DT) and provides a live environment to pacstrap
# Omarchy ARM onto a target disk. The primary deliverable remains the raw
# .img (build/build.sh), which needs no U-Boot and is far simpler.
#
# Build (native aarch64 host with archiso installed, or inside the builder
# container):
#   mkarchiso -v -w /tmp/archiso-work -o ./out \
#       build/archiso/releng-omarchy-aarch64

export arch="aarch64"
export iso_name="omarchy-arm64-rpi5"
export iso_label="OMARCHY_AARCH64"
export iso_publisher="Omarchy ARM64 <https://github.com/rbz840/omarchy>"
export iso_application="Omarchy ARM64 Live/Netboot (experimental)"
export iso_version="$(date +%Y.%m.%d)"
export install_dir="omarchy"

# systemd-boot ESP bootmode only (BIOS/syslinux and hybrid modes are x86-only).
export bootmodes=('uefi-arm64.systemd-boot.esp')

export archiso_initramfs_options=(COMPRESSION zstd)

# Packages available in the live environment; the Omarchy payload itself is
# installed into the target system via pacstrap (see docs/03-tests-validation.md).
declare -a packages=(
  "arch-install-scripts"
  "btrfs-progs"
  "dosfstools"
  "e2fsprogs"
  "git"
  "iwd"
  "linux-rpi"
  "linux-firmware"
  "mkinitcpio"
  "networkmanager"
  "neovim"
  "openssh"
  "parted"
  "raspberrypi-bootloader"
  "firmware-raspberrypi"
  "rsync"
  "sudo"
  "vim"
)

declare -a airootfs_tool_directories=("/usr/local/bin")
