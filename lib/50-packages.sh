#!/usr/bin/env bash
# 50-packages.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

# Package list assembly. pacstrap orchestration stays in install.sh.
# pacman_tune() is provided by 10-ui.sh / 00-common.

t14s_base_packages() {
  # Populates BASE_PKGS; call after UCODE and INSTALL_LINUX_STABLE / PLYMOUTH are set.
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
    wireless-regdb
    xdg-user-dirs
  )
  if yn_on "${INSTALL_LINUX_STABLE:-N}"; then
    BASE_PKGS+=(linux linux-headers)
  fi
  if yn_on "${INSTALL_PLYMOUTH:-N}"; then
    BASE_PKGS+=(plymouth)
  fi
}
