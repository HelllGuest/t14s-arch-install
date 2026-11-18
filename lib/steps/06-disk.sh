# 06-disk.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Wizard step 4/11: target disk.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 1. choose disk ──────────────────────────────────────────
ui_step 4 Disk
if (( NONINTERACTIVE )); then
  [[ -n ${DISK:-} && -b ${DISK:-} && $(disk_type "$DISK") == disk ]] \
    || die "NONINTERACTIVE needs DISK=<whole-disk block device> in answers"
  ok "using DISK from answers: $DISK"
else
  while :; do
    mapfile -t DISKS < <(lsblk -dno PATH,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }')
    menu_args=()
    for d in "${DISKS[@]}"; do
      [[ -b $d ]] || continue
      IFS=$'\x1f' read -r _sz _model < <(lsblk_rows "$d" SIZE MODEL) || true
      menu_args+=("$d" "$(printf '%-7s %s' "${_sz:-?}" "${_model:-}")")
    done
    unset -v _sz _model
    menu_args+=("manual" "type a device path")

    DISK="$(ui_menu "Select the target disk. AUTO wipes it entirely." "${menu_args[@]}")" \
      || die "no disk selected"
    if [[ $DISK == manual ]]; then
      DISK="$(ui_input "Target disk (e.g. /dev/nvme0n1)" "${DISK:-}")" || die "no disk selected"
    fi
    [[ -b $DISK ]] || { ui_error "Not a block device: ${DISK:-<empty>}"; continue; }
    [[ $(disk_type "$DISK") == disk ]] || { ui_error "$DISK is not a whole disk."; continue; }
    break
  done
fi

# SMART health hint before any wipe (non-fatal if smartmontools/smartctl absent).
if command -v smartctl >/dev/null 2>&1; then
  _smart="$(smartctl -H "$DISK" 2>/dev/null | grep -i 'result' | head -1 || true)"
  if [[ -n $_smart ]]; then
    ui_info "SMART health for $DISK:
$_smart

Full report later: smartctl -a $DISK"
  fi
  unset -v _smart
else
  warn "smartctl not on ISO — pacstrap will not include it unless you add smartmontools"
fi
