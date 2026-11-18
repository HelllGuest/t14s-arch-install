# 04-ukis.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 8-24 %: unified kernel images on the ESP.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

stage 8 24 "building unified kernel images"
# UKI presets: linux-lts (primary) + linux-hardened (fallback)
# Re-clean Arch EFI artifacts before rebuild (host already cleaned /mnt/boot).
# Do NOT touch /boot/vmlinuz-* or *-ucode.img here: pacstrap just installed
# them and mkinitcpio -P below reads ALL_kver from vmlinuz. Stale copies were
# already removed on the host before pacstrap (clean_esp_arch_files).
# Full UKI / loader-entry clean only when CLEAN_ESP_ARCH=Y.
# (Function inlined — chroot has no host helpers.)
if yn_on "${CLEAN_ESP_ARCH}"; then
  say "CLEAN_ESP_ARCH — removing old Arch UKIs / loader entries / EFI/arch"
  rm -f /boot/EFI/Linux/arch*.efi 2>/dev/null || true
  if [[ -d /boot/loader/entries ]]; then
    find /boot/loader/entries -maxdepth 1 -type f \
      -name 'arch*.conf' -delete 2>/dev/null || true
  fi
  rm -rf /boot/EFI/arch /boot/EFI/Arch /boot/EFI/ARCH 2>/dev/null || true
fi
mkdir -p /boot/EFI/Linux
cat > /etc/mkinitcpio.d/linux-lts.preset <<EOF
# ALL_kver is REQUIRED — mkinitcpio reads the kernel version from this vmlinuz.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-lts.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-lts-fallback.efi"
fallback_options="-S autodetect"
EOF
cat > /etc/mkinitcpio.d/linux-hardened.preset <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-hardened"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-hardened.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-hardened-fallback.efi"
fallback_options="-S autodetect"
EOF
if yn_on "${INSTALL_LINUX_STABLE}"; then
  cat > /etc/mkinitcpio.d/linux.preset <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF
fi
say "building UKIs"
mkinitcpio -P
# drop redundant non-UKI initramfs left by the pacstrap install hook — UKI-only
# presets won't regenerate them, so this frees ESP space permanently.
rm -f /boot/initramfs-linux-lts.img /boot/initramfs-linux-lts-fallback.img \
      /boot/initramfs-linux-hardened.img /boot/initramfs-linux-hardened-fallback.img \
      /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
# ESP free-space gate after UKI build (dual UKIs need headroom for updates).
_esp_free_mb="$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')"
if [[ ${_esp_free_mb:-} =~ ^[0-9]+$ ]]; then
  if (( _esp_free_mb < 64 )); then
    echo "ERROR: ESP nearly full after UKI build (${_esp_free_mb}MB free). Enlarge ESP or drop linux-stable." >&2
    exit 1
  elif (( _esp_free_mb < 200 )); then
    say "WARN: ESP low after UKI build (${_esp_free_mb}MB free) — leave room for kernel updates"
  else
    say "ESP free after UKI build: ${_esp_free_mb}MB"
  fi
fi
unset -v _esp_free_mb
