#!/usr/bin/env bash
# 30-hardware.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# DMI / ThinkPad helpers (orchestration still does soft DMI gate).

clean_esp_arch_files() {
  local root=${1%/}
  [[ -d $root ]] || return 0
  rm -f "$root"/intel-ucode.img "$root"/amd-ucode.img \
        "$root"/vmlinuz-linux* "$root"/initramfs-linux* 2>/dev/null || true
  if yn_on "${CLEAN_ESP_ARCH:-Y}"; then
    rm -f "$root"/EFI/Linux/arch-linux*.efi \
          "$root"/EFI/Linux/arch*.efi 2>/dev/null || true
    if [[ -d $root/loader/entries ]]; then
      find "$root/loader/entries" -maxdepth 1 -type f \
        -name 'arch*.conf' -delete 2>/dev/null || true
    fi
    # Legacy GRUB/refind-style Arch vendor dirs (case variants).
    rm -rf "$root"/EFI/arch "$root"/EFI/Arch "$root"/EFI/ARCH 2>/dev/null || true
  fi
}

# Replay checklist extras from answers (space-separated package names).
apply_extra_pkgs_list() {
  [[ -n ${EXTRA_PKGS_LIST:-} ]] || return 0
  # read -a splits on whitespace without pathname expansion (a "*" stays literal).
  local -a _pkgs=()
  local _p
  read -r -a _pkgs <<<"$EXTRA_PKGS_LIST"
  for _p in "${_pkgs[@]}"; do
    if [[ $_p =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]; then
      EXTRA_PKGS+=("$_p")
    else
      warn "Ignoring invalid EXTRA_PKGS_LIST entry: $_p"
    fi
  done
}

# VM / non-ThinkPad rehearsal: skip BAT thresholds, fprintd, thinkfan notes.
detect_vm_thinkpad_skip() {
  IS_VM=0
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null; then
    IS_VM=1
  elif grep -qiE 'qemu|kvm|vmware|virtualbox|xen|bochs|microsoft corporation|hyper-v' \
    /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then
    IS_VM=1
  fi
  if [[ -z ${SKIP_THINKPAD_HW:-} ]]; then
    if (( IS_VM )); then SKIP_THINKPAD_HW=Y; else SKIP_THINKPAD_HW=N; fi
  fi
  if yn_on "$SKIP_THINKPAD_HW"; then
    warn "SKIP_THINKPAD_HW=Y (VM=${IS_VM}) — skip charge thresholds / fprintd / thinkfan"
    INSTALL_THINKFAN=N
  fi
}
