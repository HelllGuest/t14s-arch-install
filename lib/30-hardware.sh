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
    rm -f "$root"/EFI/Linux/arch*.efi 2>/dev/null || true
    if [[ -d $root/loader/entries ]]; then
      find "$root/loader/entries" -maxdepth 1 -type f \
        -name 'arch*.conf' -delete 2>/dev/null || true
    fi
    # Legacy GRUB/refind-style Arch vendor dirs (case variants).
    rm -rf "$root"/EFI/arch "$root"/EFI/Arch "$root"/EFI/ARCH 2>/dev/null || true
  fi
}

# ── firmware boot entry ────────────────────────────────────
# bootctl runs in the chroot, where it skips EFI variables ("running in a
# container"), so without this Arch boots only through the \EFI\BOOT fallback:
# a Windows Boot Manager entry, or a Windows update rewriting BOOTX64.EFI, wins.
SDBOOT_LOADER='\EFI\systemd\systemd-bootx64.efi'

# sdboot_plan ESP_PARTUUID < efibootmgr output
#   "delete NNNN" per (Fallback) Linux Boot Manager entry on another ESP (old
#   installs, deleted partitions), then "keep NNNN" for an entry already loading
#   systemd-boot from this ESP, else "create". Other OS entries are never listed.
sdboot_plan() {
  local uuid=${1,,} line low id keep=""
  while IFS= read -r line; do
    [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+(Fallback\ )?Linux\ Boot\ Manager([[:space:]]|$) ]] || continue
    id=${BASH_REMATCH[1]} low=${line,,}
    if [[ $low != *",gpt,$uuid,"* ]]; then
      echo "delete $id"
    elif [[ -z ${BASH_REMATCH[2]} && -z $keep && $low == *'\efi\systemd\systemd-bootx64.efi'* ]]; then
      keep=$id
    fi
  done
  if [[ -n $keep ]]; then echo "keep $keep"; else echo create; fi
}

# boot_order_front ID < efibootmgr output → BootOrder value with ID first.
boot_order_front() {
  local id=$1 order o rest=""
  order=$(sed -n 's/^BootOrder: *//p')
  for o in ${order//,/ }; do [[ ${o^^} == "${id^^}" ]] || rest+=",$o"; done
  printf '%s%s\n' "$id" "$rest"
}

# ensure_boot_entry ESP_PART: "Linux Boot Manager" for this ESP, first in BootOrder.
# Returns 1 (after a warning) when it could not; Arch then still boots via the fallback.
ensure_boot_entry() {
  local esp=$1 uuid disk partn act id
  if [[ ! -d /sys/firmware/efi/efivars ]] || ! command -v efibootmgr >/dev/null 2>&1; then
    warn "no EFI variables or efibootmgr: firmware boot entry not written"
    return 1
  fi
  uuid=$(lsblk -dno PARTUUID "$esp" 2>/dev/null)
  disk=$(lsblk -dno PKNAME "$esp" 2>/dev/null)
  partn=$(cat "/sys/class/block/${esp##*/}/partition" 2>/dev/null)
  if [[ -z $uuid || -z $disk || -z $partn ]]; then
    warn "cannot resolve $esp (PARTUUID/disk/partition number): firmware boot entry not written"
    return 1
  fi
  while read -r act id; do
    case $act in
      delete)
        if efibootmgr -q -b "$id" -B; then say "removed stale firmware entry Boot$id (Linux Boot Manager on another ESP)"
        else warn "could not remove stale firmware entry Boot$id"; fi ;;
      keep)
        efibootmgr -q -o "$(efibootmgr | boot_order_front "$id")" \
          || { warn "could not put Boot$id first in BootOrder"; return 1; }
        ok "firmware entry Boot$id (Linux Boot Manager on $esp) is first in BootOrder" ;;
      create)
        # efibootmgr --create prepends the new entry to BootOrder.
        efibootmgr -q --create --disk "/dev/$disk" --part "$partn" \
          --label "Linux Boot Manager" --loader "$SDBOOT_LOADER" \
          || { warn "could not create the firmware boot entry"; return 1; }
        ok "created firmware entry Linux Boot Manager ($esp), first in BootOrder" ;;
    esac
  done < <(efibootmgr | sdboot_plan "$uuid")
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
