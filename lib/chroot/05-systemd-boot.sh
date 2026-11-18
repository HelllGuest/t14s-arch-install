# 05-systemd-boot.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 24-27 %: systemd-boot and loader.conf.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

stage 24 27 "systemd-boot"
# bootloader — when reusing a shared/multiboot ESP, back up another OS's fallback
# loader first. On a freshly-formatted ESP there's nothing to preserve (no clutter).
say "systemd-boot"
# cp -n keeps the first (pre-Arch) backup across installer re-runs.
if [[ ${FORMAT_EFI:-1} == 0 ]]; then
  for _bk in /boot/EFI/BOOT/BOOTX64.EFI /boot/loader/loader.conf; do
    [[ -f $_bk ]] || continue
    if cp -n "$_bk" "$_bk.pre-arch.bak"; then
      say "backed up existing ${_bk#/boot} -> .pre-arch.bak"
    else
      say "WARN: could not back up ${_bk#/boot} before replacing it"
    fi
  done
  unset -v _bk
fi
bootctl install
# inform: coexisting loaders systemd-boot will auto-detect (Windows, other Linux)
find /boot/EFI -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's,^,   loader dir: ,' || true
cat > /boot/loader/loader.conf <<EOF
default arch-linux-lts.efi
timeout 3
editor no
console-mode max
EOF
