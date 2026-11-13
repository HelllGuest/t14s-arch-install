#!/usr/bin/env bash
# 50-packages.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

# Package list assembly and pacstrap live in install.sh orchestration for now.
# pacman_tune() is provided by 10-ui.sh.
t14s_base_packages() {
  # Populates BASE_PKGS array; called from install.sh before pacstrap.
  : "${UCODE:=amd-ucode}"
  BASE_PKGS=(
    base base-devel
    linux-lts linux-lts-headers linux-hardened linux-hardened-headers
    linux-firmware "$UCODE"
    btrfs-progs cryptsetup
    bluez bluez-utils
    networkmanager sudo zsh git vim nano
    reflector pacman-contrib
    mkinitcpio snapper snap-pac zram-generator
    apparmor firewalld sbctl efibootmgr
    xdg-user-dirs wireless-regdb
  )
  if yn_on "${INSTALL_LINUX_STABLE:-N}"; then
    BASE_PKGS+=(linux linux-headers)
  fi
}
