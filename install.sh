#!/usr/bin/env bash
# install.sh — interactive hardened Arch Stage A for ThinkPad T14s Gen 3 AMD
#               (21CQ/21CR) and ThinkPad P15 Gen 1 (20SU, Optimus NVIDIA).
#
# Modular layout: helpers live under lib/*.sh (see README). This file is the
# curl-able orchestrator; it sources local lib/ or fetches from GitHub.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
#   T14S_LIB_DIR=./lib bash install.sh   # local/dev without network fetches
#
# Stack: LUKS2(argon2id) + Btrfs + linux-lts/hardened UKIs + systemd-boot +
#        sbctl Secure Boot + minimal GNOME + firewalld (nftables, default drop).
#        T14s: amd-ucode, amd_iommu/amd_pstate. P15: intel-ucode, nvidia modeset.
#
# BIOS (F1): Secure Boot off for install; Sleep State = "Windows and Linux"
# (s2idle); enable AMD SVM + IOMMU. Re-enable Secure Boot after sbctl enroll.
#
# RUN FROM THE ARCH ISO (live environment), as root, UEFI mode, with internet.
# THIS ERASES DATA on the partitions you select.
#
# UI: full-screen whiptail/dialog TUI on /dev/tty. dialog is installed from the
# live repos if no backend exists; plain line prompts are the fallback.
set -euo pipefail

# ── library loader ──────────────────────────────────────────
T14S_BASE_URL="${T14S_BASE_URL:-https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main}"
T14S_LIB_DIR="${T14S_LIB_DIR:-}"
if [[ -z $T14S_LIB_DIR ]]; then
  _t14s_self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [[ -n $_t14s_self && -d $_t14s_self/lib ]]; then
    T14S_LIB_DIR="$_t14s_self/lib"
  fi
  unset -v _t14s_self
fi

# Defaults needed before any sourced lib runs say()/die under set -u
LOGGING=0
c0=$'\e[0m'; cR=$'\e[1;31m'; cG=$'\e[1;32m'; cY=$'\e[1;33m'; cB=$'\e[1;34m'
cC=$'\e[1;36m'
UI=${T14S_UI:-plain}
NONINTERACTIVE=0
LOG="$(mktemp /tmp/t14s-install.XXXXXX.log)"

_load_lib() {
  local f=$1
  if [[ -n ${T14S_LIB_DIR:-} && -f $T14S_LIB_DIR/$f ]]; then
    # shellcheck source=/dev/null
    source "$T14S_LIB_DIR/$f"
    return 0
  fi
  # curl one-liner path: fetch each module into a temp dir once
  if [[ -z ${T14S_LIB_FETCH_DIR:-} ]]; then
    T14S_LIB_FETCH_DIR="$(mktemp -d /tmp/t14s-lib.XXXXXX)"
  fi
  if [[ ! -f $T14S_LIB_FETCH_DIR/$f ]]; then
    curl -fsSL "$T14S_BASE_URL/lib/$f" -o "$T14S_LIB_FETCH_DIR/$f" \
      || { printf 'ERR: failed to fetch lib/%s from %s\n' "$f" "$T14S_BASE_URL" >&2; exit 1; }
  fi
  # shellcheck source=/dev/null
  source "$T14S_LIB_FETCH_DIR/$f"
}

for _lib in 00-common.sh 10-ui.sh 20-answers.sh 30-hardware.sh 40-disk.sh \
            50-packages.sh 60-boot.sh 70-firewall.sh; do
  _load_lib "$_lib"
done
unset -v _lib

# ── globals / session ───────────────────────────────────────
# Parse before any (( DRYRUN )): raw env text in arithmetic can run $(…), and an
# unrecognized value must never fall through to a real install.
_dr=${T14S_DRYRUN:-0}
case ${_dr,,} in
  0 | n | no | off | false) DRYRUN=0 ;;
  1 | y | yes | on | true) DRYRUN=1 ;;
  *) printf 'T14S_DRYRUN=%q not recognized (use 1 or 0)\n' "$_dr" >&2; exit 2 ;;
esac
unset -v _dr
UI=${T14S_UI:-plain}
# Accept 1/y/yes/on (case-insensitive) for env toggles — same spirit as yn_on.
_env_on() { local v=${1,,}; [[ $v == 1 || $v == y || $v == yes || $v == on ]]; }
if _env_on "${T14S_NONINTERACTIVE:-0}"; then NONINTERACTIVE=1; else NONINTERACTIVE=0; fi
ANSWERS_IN=${T14S_ANSWERS:-}
PASS_FILE=${T14S_PASS_FILE:-}
if _env_on "${T14S_I_WILL_ERASE:-0}"; then WILL_ERASE=1; else WILL_ERASE=0; fi
unset -f _env_on
# Never accept LUKS/user/root passwords from ambient environment (/proc leak).
# Unattended secrets come only from T14S_PASS_FILE; interactive uses ui_password.
unset -v LUKS_PASS USER_PASS ROOT_PASS
SECRETS_FROM_FILE=0
APP_TITLE="T14s Arch Installer"
PRESET=gnome
POST_HOOK_URL=""
EXTRA_PKGS=()
EXTRA_PKGS_LIST=""
LOG="$(mktemp /tmp/t14s-install.XXXXXX.log)"
LOGGING=0
DIALOG_RC=""
DIALOG_RC_DIR=""
DIALOG_RC_INFO="" DIALOG_RC_WARN="" DIALOG_RC_ERROR="" DIALOG_RC_CRITICAL="" DIALOG_RC_OK=""
TUI_TITLE=""
TUI_NEWT=""
TUI_DIALOGRC=""
TUI_KEEP_STDIN=0

# Wizard progress (Heads / modern installer pattern: step in backtitle).
TUI_STEPS=11
TUI_STEP=0
TUI_STEP_NAME=""
# Shared key hints (one question per screen; never color-only).
TUI_HINT_MENU='[log] view install log · [help] tips · Esc/Abort quits'
TUI_HINT_RADIO='Arrows+Space select · Enter=Next · Esc=Abort · [log]/[help]'
TUI_HINT_CHECK='Space=toggle · Enter=Next · Esc=Abort · [log]/[help]'


trap 'die "failed at line $LINENO (exit $?): $BASH_COMMAND" $?' ERR
trap 'cleanup_ui' EXIT

# ── 0. preflight ────────────────────────────────────────────
if (( ! DRYRUN )); then
  [[ $EUID -eq 0 ]] || die "run as root (from the Arch ISO)"
  [[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode — enable UEFI and reboot the ISO"
  # The installer assumes a disposable live environment (/mnt, cryptroot mapper).
  [[ -d /run/archiso || ${T14S_ALLOW_NON_ISO:-0} == 1 ]] \
    || die "not running from the Arch ISO (/run/archiso missing); set T14S_ALLOW_NON_ISO=1 to override"
  { ping -c1 -W3 archlinux.org || curl -fsS --max-time 6 https://archlinux.org; } >/dev/null 2>&1 \
    || die "no internet — connect first (iwctl / dhcp), then re-run"
  timedatectl set-ntp true || true
fi
bootstrap_ui
say "preflight ok (UEFI + network + ntp)"

if (( NONINTERACTIVE )); then
  warn "NONINTERACTIVE: skipping welcome TUI (answers + T14S_I_WILL_ERASE gate wipe)"
else
  ui_step 1 Welcome
  ui_warn "THINKPAD STAGE A INSTALLER — DESTROYS DATA ON DISK

Machines: T14s Gen 3 AMD (21CQ/21CR) or P15 Gen 1 (20SU Optimus)
Stack:    LUKS2 + Btrfs(+@tmp) + linux-lts/hardened + UKI + systemd-boot
          + minimal GNOME + zram + AppArmor + firewalld + Snapper + Secure Boot

One question per screen. Backtitle shows Step N/11.
All answers from /dev/tty. Nothing written until the final Erase confirm.
Destructive confirms default No. Wipe = Erase/Abort; hard gates = Continue/Abort."
fi

# Soft DMI check — T14s Gen 3 AMD (21CQ/21CR) or P15 Gen 1 (20SU).
ui_step 2 Hardware
_dmi="$(cat /sys/class/dmi/id/product_family /sys/class/dmi/id/product_version \
          /sys/class/dmi/id/product_name /sys/class/dmi/id/product_sku 2>/dev/null \
        | tr '\n' ' ')"
HW_PROFILE="${HW_PROFILE:-}"
if [[ -z $HW_PROFILE ]]; then
  if echo "$_dmi" | grep -qiE '(^|[[:space:]_/])21C[QR]([[:alnum:]_-]|$)'; then
    HW_PROFILE=t14s
  elif echo "$_dmi" | grep -qiE '(^|[[:space:]_/])20SU([[:alnum:]_-]|$)'; then
    HW_PROFILE=p15
  fi
fi
case ${HW_PROFILE,,} in
  t14s|thinkpad-t14s) HW_PROFILE=t14s ;;
  p15|thinkpad-p15) HW_PROFILE=p15 ;;
  *)
    if (( NONINTERACTIVE )); then
      HW_PROFILE=${HW_PROFILE:-t14s}
      warn "NONINTERACTIVE: DMI not 21CQ/21CR or 20SU (${_dmi:-unknown}) — HW_PROFILE=$HW_PROFILE"
    else
      HW_PROFILE="$(ui_radio "Hardware profile (DMI: ${_dmi:-unknown})" \
        t14s "ThinkPad T14s Gen 3 AMD (21CQ/21CR)" on \
        p15 "ThinkPad P15 Gen 1 Optimus (20SU)" off)" || die "aborted"
    fi
    ;;
esac
if [[ $HW_PROFILE == t14s ]]; then
  ok "target profile: T14s Gen 3 AMD (21CQ/21CR)"
  if ! grep -q AuthenticAMD /proc/cpuinfo; then
    if (( NONINTERACTIVE )); then
      warn "NONINTERACTIVE: CPU not AuthenticAMD — continuing (amd-ucode/cmdline still set)"
    else
      ui_yesno "CPU is not AuthenticAMD.
T14s profile sets amd-ucode + amd_iommu/amd_pstate.

Continue without an AMD CPU (VM rehearsal)?" no warn \
        || die "aborted — need AuthenticAMD or explicit YES"
    fi
  fi
else
  ok "target profile: P15 Gen 1 (20SU Optimus)"
  if ! grep -q GenuineIntel /proc/cpuinfo; then
    if (( NONINTERACTIVE )); then
      warn "NONINTERACTIVE: CPU not GenuineIntel — continuing (intel-ucode/cmdline still set)"
    else
      ui_yesno "CPU is not GenuineIntel.
P15 profile sets intel-ucode + nvidia_drm modeset.

Continue without an Intel CPU (VM rehearsal)?" no warn \
        || die "aborted — need GenuineIntel or explicit YES"
    fi
  fi
fi

# ── answers helpers (T14S_ANSWERS=file; export at end) ───────
# Known keys only — never eval the answers file.
ANSWERS_KEYS=(
  PRESET DESKTOP INSTALL_NERD_FONTS ENROLL_SB ENABLE_SSHD INSTALL_CUPS
  SKIP_REFLECTOR INSTALL_TLP INSTALL_CLI INSTALL_PODMAN INSTALL_DOCKER
  INSTALL_VIRT INSTALL_AVAHI INSTALL_WIREGUARD INSTALL_TAILSCALE
  INSTALL_STARSHIP INSTALL_CHROME_HINT INSTALL_FAIL2BAN INSTALL_THINKFAN
  INSTALL_SNAPPER_HOME INSTALL_LINUX_STABLE INSTALL_PLYMOUTH INSTALL_SELFTEST
  INSTALL_MULTILIB INSTALL_YAY INSTALL_TUNED INSTALL_DEVTOOLS INSTALL_BTRFS_ASSISTANT
  CLEAN_ESP_ARCH HW_PROFILE INSTALL_OLLAMA
  FW_SYNCTHING FW_KDECONNECT UFW_SYNCTHING UFW_KDECONNECT POST_HOOK_URL
  PACMAN_PARALLEL LUKS_WIPE HOSTNAME TIMEZONE LOCALE KEYMAP USERNAME
  MODE ESP_MB FORMAT_EFI DISK EFI_PART ROOT_PART
  BTRFS_COMPRESS ZRAM_SIZE REFLECTOR_COUNTRY SKIP_THINKPAD_HW
  EXTRA_PKGS_LIST
)


# Atomic: mktemp (always 0600) in the target dir, then rename over $f. A crash
# never leaves a partial file, and a symlink at $f is replaced, not followed.

# Secrets file (LUKS/USER/ROOT only). Never written by answers_save.
# Format: KEY=value lines. Must be mode 0600 (u=rw only). Fail closed if mode unknown.



if [[ -n $ANSWERS_IN ]]; then
  if answers_load "$ANSWERS_IN"; then
    ok "loaded answers from $ANSWERS_IN"
  else
    die "T14S_ANSWERS not readable: $ANSWERS_IN"
  fi
fi
if [[ -n $PASS_FILE ]]; then
  if secrets_load "$PASS_FILE"; then
    SECRETS_FROM_FILE=1
    ok "loaded secrets from $PASS_FILE (passwords not saved to answers)"
  else
    die "T14S_PASS_FILE not readable: $PASS_FILE"
  fi
fi
if (( NONINTERACTIVE )); then
  [[ -n $PASS_FILE && $SECRETS_FROM_FILE == 1 ]] \
    || die "NONINTERACTIVE requires T14S_PASS_FILE (mode 0600; no env passwords)"
  [[ -n ${LUKS_PASS:-} && -n ${USER_PASS:-} && -n ${ROOT_PASS:-} ]] \
    || die "T14S_PASS_FILE must set LUKS_PASS, USER_PASS, and ROOT_PASS"
fi

# ── profile preset (feeds checklist defaults) ───────────────
: "${PRESET:=gnome}"
ui_step 3 Profile
if (( ! NONINTERACTIVE )); then
  _pg=off; _pd=off; _pm=off
  case $PRESET in
    dev) _pd=on ;;
    minimal) _pm=on ;;
    *) _pg=on; PRESET=gnome ;;
  esac
  PRESET="$(ui_radio "Install profile (sets checklist defaults; you can still change)" \
    gnome "GNOME laptop — desktop + Nerd Fonts + mDNS" "$_pg" \
    dev "Dev laptop — GNOME + CLI tools + Podman + Starship" "$_pd" \
    minimal "Minimal — no desktop, small tool set" "$_pm")" || die "aborted"
  unset -v _pg _pd _pm
fi
case $PRESET in
  minimal)
    DESKTOP=${DESKTOP:-N}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-N}
    INSTALL_CLI=${INSTALL_CLI:-N}; INSTALL_PODMAN=${INSTALL_PODMAN:-N}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-N}; INSTALL_AVAHI=${INSTALL_AVAHI:-N}
    INSTALL_TLP=${INSTALL_TLP:-Y}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-N}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-N}; INSTALL_YAY=${INSTALL_YAY:-N}
    INSTALL_TUNED=${INSTALL_TUNED:-N}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-N}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-N}
    ;;
  dev)
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-Y}; INSTALL_PODMAN=${INSTALL_PODMAN:-Y}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-Y}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_CHROME_HINT=${INSTALL_CHROME_HINT:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-Y}; INSTALL_YAY=${INSTALL_YAY:-Y}
    INSTALL_TUNED=${INSTALL_TUNED:-Y}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-Y}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-Y}
    INSTALL_SNAPPER_HOME=${INSTALL_SNAPPER_HOME:-Y}
    ;;
  *)
    PRESET=gnome
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-N}; INSTALL_PODMAN=${INSTALL_PODMAN:-N}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-N}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-Y}; INSTALL_YAY=${INSTALL_YAY:-Y}
    INSTALL_TUNED=${INSTALL_TUNED:-Y}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-N}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-Y}
    ;;
esac
# Fill remaining flags with N if unset
: "${ENROLL_SB:=N}" "${ENABLE_SSHD:=N}" "${INSTALL_CUPS:=N}" "${SKIP_REFLECTOR:=N}"
: "${INSTALL_DOCKER:=N}" "${INSTALL_VIRT:=N}" "${INSTALL_WIREGUARD:=N}"
: "${INSTALL_TAILSCALE:=N}" "${INSTALL_CHROME_HINT:=N}" "${INSTALL_FAIL2BAN:=N}"
: "${INSTALL_THINKFAN:=N}" "${FW_SYNCTHING:=${UFW_SYNCTHING:-N}}" "${FW_KDECONNECT:=${UFW_KDECONNECT:-N}}"
: "${UFW_SYNCTHING:=N}" "${UFW_KDECONNECT:=N}" "${INSTALL_OLLAMA:=N}"
: "${INSTALL_SNAPPER_HOME:=N}" "${INSTALL_LINUX_STABLE:=N}" "${INSTALL_PLYMOUTH:=N}"
: "${INSTALL_SELFTEST:=N}" "${CLEAN_ESP_ARCH:=Y}"
: "${INSTALL_MULTILIB:=N}" "${INSTALL_YAY:=N}" "${INSTALL_TUNED:=N}"
: "${INSTALL_DEVTOOLS:=N}" "${INSTALL_BTRFS_ASSISTANT:=N}"
: "${PACMAN_PARALLEL:=10}" "${LUKS_WIPE:=none}"
: "${BTRFS_COMPRESS:=zstd3}" "${ZRAM_SIZE:=half}" "${REFLECTOR_COUNTRY:=}"
: "${FORMAT_EFI:=1}"

# clean_esp_arch_files: lib/30-hardware.sh (kernels/ucode always; Arch UKIs when CLEAN_ESP_ARCH=Y).
apply_extra_pkgs_list
detect_vm_thinkpad_skip

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
      menu_args+=("$d" "$(lsblk -dnro SIZE,MODEL "$d" 2>/dev/null | sed 's/  */ /g')")
    done
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

# ── 2. partition strategy ───────────────────────────────────
ui_step 5 Partition
if (( NONINTERACTIVE )); then
  [[ ${MODE:-} == auto || ${MODE:-} == manual ]] \
    || die "NONINTERACTIVE needs MODE=auto|manual in answers"
else
  _mode_auto=on; _mode_man=off
  [[ ${MODE:-auto} == manual ]] && { _mode_auto=off; _mode_man=on; }
  MODE="$(ui_radio "How should $DISK be partitioned?" \
    auto "wipe ALL of $DISK: EFI + LUKS root" "$_mode_auto" \
    manual "select existing partitions (EFI format or reuse)" "$_mode_man")" \
    || die "aborted"
  unset -v _mode_auto _mode_man
fi

require_ni_erase() {
  (( WILL_ERASE == 1 )) \
    || die "NONINTERACTIVE destructive install needs T14S_I_WILL_ERASE=1 (or y/yes/on)"
}

if [[ $MODE == auto ]]; then
  FORMAT_EFI=1
  while :; do
    if (( NONINTERACTIVE )); then
      [[ ${ESP_MB:-} =~ ^(1024|2048|4096)$ ]] \
        || die "NONINTERACTIVE AUTO needs ESP_MB=1024|2048|4096 in answers"
    else
      _e2=off; _e1=off; _e4=off
      case ${ESP_MB:-2048} in
        1024) _e1=on ;;
        4096) _e4=on ;;
        *) _e2=on; ESP_MB=2048 ;;
      esac
      ESP_MB="$(ui_radio "EFI system partition size on $DISK" \
        2048 "2G — recommended for dual UKIs" "$_e2" \
        1024 "1G — minimum comfortable" "$_e1" \
        4096 "4G — extra multiboot headroom" "$_e4")" || die "aborted"
      unset -v _e2 _e1 _e4
    fi
    disk_mb="$(size_mb "$DISK")"
    (( disk_mb > ESP_MB + 8192 )) && break
    if (( NONINTERACTIVE )); then
      die "Disk is only ${disk_mb}MB — ESP_MB=${ESP_MB} will not fit with 8GB root"
    fi
    ui_error "Disk is only ${disk_mb}MB — ${ESP_MB}MB ESP plus an 8GB root will not fit.
Pick a smaller ESP."
    ESP_MB=""
  done

  if (( NONINTERACTIVE )); then
    require_ni_erase
    warn "NONINTERACTIVE AUTO: will erase entire $DISK (ESP ${ESP_MB}MB + LUKS root)"
  else
    ui_critical "AUTO mode ERASES the ENTIRE disk:

$DISK

Plan: GPT · ${ESP_MB}MB ESP (FAT32) · remainder LUKS2 + Btrfs

That includes any Windows / other-OS partitions on it.

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null)"
    CONF="$(ui_input "Type the disk path to confirm total wipe" "")" || die "aborted"
    [[ $CONF == "$DISK" ]] || die "disk confirmation mismatch — aborting"
    ui_yesno "ERASE $DISK now?" no erase || die "aborted"
  fi
  # names only; the destructive writes run in the execute phase
  EFI_PART="$(part_of "$DISK" 1)"
  ROOT_PART="$(part_of "$DISK" 2)"
else
  # MANUAL: honor EFI_PART/ROOT_PART/FORMAT_EFI from answers under NONINTERACTIVE.
  if (( NONINTERACTIVE )); then
    [[ -n ${EFI_PART:-} && -n ${ROOT_PART:-} && -b ${EFI_PART:-/dev/null} && -b ${ROOT_PART:-/dev/null} ]] \
      || die "NONINTERACTIVE MANUAL needs EFI_PART and ROOT_PART block devices in answers"
    require_ni_erase
    [[ $EFI_PART != "$ROOT_PART" ]] || die "EFI_PART and ROOT_PART must differ"
    part_on_disk "$EFI_PART" "$DISK" \
      || die "EFI_PART $EFI_PART is not on DISK $DISK"
    part_on_disk "$ROOT_PART" "$DISK" \
      || die "ROOT_PART $ROOT_PART is not on DISK $DISK"
    [[ ${FORMAT_EFI:-1} =~ ^[01]$ ]] || FORMAT_EFI=1
    efifs="$(part_fs "$EFI_PART")"
    if (( FORMAT_EFI == 0 )) && [[ $efifs != vfat ]]; then
      die "FORMAT_EFI=0 but $EFI_PART is '${efifs:-empty}', not FAT32"
    fi
    efi_mb="$(size_mb "$EFI_PART")"
    root_mb="$(size_mb "$ROOT_PART")"
    if (( efi_mb < 512 )); then
      die "ESP $EFI_PART is only ${efi_mb}MB (need ≥512; enlarge or pick another)"
    fi
    if (( root_mb < 8192 )); then
      die "ROOT $ROOT_PART is only ${root_mb}MB (need ≥8192)"
    fi
    ok "MANUAL partitions from answers: EFI=$EFI_PART ROOT=$ROOT_PART format_efi=$FORMAT_EFI"
  else
    ui_info "Manual partitioning on $DISK.

Current layout (select from lists; sizes and existing filesystems shown):

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null)"

    ROOT_PART="$(pick_part "Select ROOT — ERASED, becomes LUKS2 + Btrfs" "$DISK")" \
      || die "aborted"
    while :; do
      _ef_reuse=on; _ef_fmt=off
      [[ ${FORMAT_EFI:-1} == 0 ]] || { _ef_reuse=off; _ef_fmt=on; }
      EFIMODE="$(ui_radio "EFI handling for $ROOT_PART" \
        reuse "keep an existing FAT32 ESP (multiboot-safe)" "$_ef_reuse" \
        format "format a partition as ESP (destroys its contents)" "$_ef_fmt")" || die "aborted"
      unset -v _ef_reuse _ef_fmt
      if [[ $EFIMODE == reuse ]]; then FORMAT_EFI=0; else FORMAT_EFI=1; fi

      if (( FORMAT_EFI == 0 )) && ! lsblk -prno FSTYPE "$DISK" 2>/dev/null | grep -qx vfat; then
        ui_warn "No FAT32 ESP exists on $DISK. Pick format mode instead (or cancel to abort)."
        continue
      fi

      if (( FORMAT_EFI == 0 )); then
        EFI_PART="$(pick_part "Select the existing ESP (must be FAT32)" "$DISK" any "$ROOT_PART")" \
          || die "aborted"
      else
        EFI_PART="$(pick_part "Select the partition to FORMAT as ESP" "$DISK" any "$ROOT_PART")" \
          || die "aborted"
      fi
      [[ $EFI_PART != "$ROOT_PART" ]] || { ui_error "EFI and ROOT cannot be the same partition."; continue; }

      efifs="$(part_fs "$EFI_PART")"
      if (( FORMAT_EFI == 0 )) && [[ $efifs != vfat ]]; then
        ui_error "$EFI_PART is '${efifs:-empty}', not FAT32 — reuse needs an existing ESP.
Pick format mode or another partition."
        continue
      fi
      efi_mb="$(size_mb "$EFI_PART")"
      if (( efi_mb < 512 )); then
        ui_yesno "ESP $EFI_PART is only ${efi_mb}MB. Dual UKIs will not fit.
Use it anyway?" no warn || continue
      elif (( efi_mb < 1024 )); then
        ui_warn "Note: ESP is ${efi_mb}MB — 1G+ is recommended for dual UKIs."
      fi
      break
    done

    root_mb="$(size_mb "$ROOT_PART")"
    if (( root_mb < 8192 )); then
      ui_yesno "ROOT $ROOT_PART is only ${root_mb}MB — 8G+ is recommended.
Use it anyway?" no warn || die "aborted"
    fi

    if (( FORMAT_EFI == 0 )); then
      _m="$(mktemp -d)"
      _esp_entries=""
      if mount -o ro "$EFI_PART" "$_m" 2>/dev/null; then
        _esp_entries="$(find "$_m/EFI" -maxdepth 1 -mindepth 1 2>/dev/null | sed 's,.*/,   ,' || true)"
        umount "$_m" || true
      fi
      rmdir "$_m" 2>/dev/null || true
      ui_info "Reusing ESP $EFI_PART (FAT, kept).

Existing /EFI entries (other OSes stay bootable):
${_esp_entries:-   (none)}

Changed on this ESP: systemd-boot is installed, /EFI/BOOT/BOOTX64.EFI (the
firmware fallback loader) is replaced, and /loader/loader.conf is rewritten.
Originals are kept as *.pre-arch.bak next to them."
    elif [[ $efifs == vfat ]]; then
      ui_critical "DANGER: $EFI_PART is ALREADY FAT — likely a shared ESP.
Formatting ERASES other OSes' bootloaders."
    fi

    # Precompute sizes/labels so the prompt has no nested quotes (smoke parses it).
    _proc_root_mb="$(size_mb "$ROOT_PART")"
    _proc_efi_lbl=$([[ $FORMAT_EFI == 1 ]] && echo FORMATTED || echo REUSED)
    ui_yesno "Proceed with these partitions?

  ROOT  $ROOT_PART  ${_proc_root_mb}MB  ERASED → LUKS2
  EFI   $EFI_PART  ${efi_mb}MB  ${_proc_efi_lbl}" no erase \
      || die "aborted"
    unset -v _proc_root_mb _proc_efi_lbl
  fi
fi
ok "EFI=$EFI_PART  ROOT=$ROOT_PART  (format_efi=$FORMAT_EFI)"

# ── 3. luks passphrase + optional mapper wipe (archfi-style) ─
ui_step 6 LUKS
if (( SECRETS_FROM_FILE )); then
  ok "LUKS passphrase from T14S_PASS_FILE"
else
  while :; do
    LUKS_PASS="$(ui_password 'LUKS passphrase')" || die "aborted"
    LUKS_PASS2="$(ui_password 'Repeat LUKS passphrase')" || die "aborted"
    [[ -n $LUKS_PASS && $LUKS_PASS == "$LUKS_PASS2" ]] && break
    ui_warn "Empty or mismatched LUKS passphrase — retry."
  done
fi
if (( NONINTERACTIVE )); then
  [[ ${LUKS_WIPE:-none} =~ ^(none|fast|normal)$ ]] \
    || die "NONINTERACTIVE needs LUKS_WIPE=none|fast|normal in answers"
  LUKS_WIPE=${LUKS_WIPE:-none}
else
  _wn=off; _wf=off; _wo=off
  case ${LUKS_WIPE:-none} in
    fast) _wf=on ;;
    normal) _wo=on ;;
    *) _wn=on; LUKS_WIPE=none ;;
  esac
  LUKS_WIPE="$(ui_radio "Wipe LUKS mapper before mkfs? (paranoia; slow on large disks)" \
    none "skip — mkfs.btrfs only (default)" "$_wn" \
    fast "dd zeros bs=64M until full" "$_wf" \
    normal "dd zeros (slow, thorough)" "$_wo")" || die "aborted"
  unset -v _wn _wf _wo
fi

# ── 4. identity (validated before wipe / LUKS at step 11) ───
ui_step 7 Identity
if (( NONINTERACTIVE )); then
  [[ -n ${HOSTNAME:-} ]] || die "NONINTERACTIVE needs HOSTNAME in answers"
  valid_hostname "$HOSTNAME" || die "invalid hostname (DNS labels only): ${HOSTNAME}"
else
  while :; do
    _hn_default=thinkpad-t14s
    [[ ${HW_PROFILE:-t14s} == p15 ]] && _hn_default=p15
    HOSTNAME="$(ui_input "Hostname" "${HOSTNAME:-$_hn_default}")" || die "aborted"
    unset -v _hn_default
    [[ -n $HOSTNAME ]] || { ui_warn "hostname cannot be empty"; continue; }
    valid_hostname "$HOSTNAME" && break
    ui_error "invalid hostname (DNS labels only; no leading/trailing hyphen)"
  done
fi

if (( NONINTERACTIVE )); then
  [[ -n ${TIMEZONE:-} ]] || die "NONINTERACTIVE needs TIMEZONE in answers"
  valid_timezone "$TIMEZONE" || die "NONINTERACTIVE needs valid TIMEZONE in answers"
  ok "timezone from answers: $TIMEZONE"
else
  while :; do
    TIMEZONE="$(pick_timezone)" || die "aborted"
    valid_timezone "$TIMEZONE" && break
    ui_error "Timezone not a TZif zone file: ${TIMEZONE:-<empty>} — pick again."
  done
fi

if (( NONINTERACTIVE )); then
  [[ -n ${LOCALE:-} ]] || die "NONINTERACTIVE needs LOCALE in answers"
  valid_locale "$LOCALE" || die "NONINTERACTIVE needs valid LOCALE in answers"
  ok "locale from answers: $LOCALE"
else
  while :; do
    _loc_prev=${LOCALE:-en_US.UTF-8}
    _lu=off; _lg=off; _ld=off; _lf=off; _ls=off; _lo=off
    case $_loc_prev in
      en_GB.UTF-8) _lg=on ;;
      de_DE.UTF-8) _ld=on ;;
      fr_FR.UTF-8) _lf=on ;;
      es_ES.UTF-8) _ls=on ;;
      en_US.UTF-8) _lu=on ;;
      *) _lo=on ;;
    esac
    LOCALE="$(ui_radio "System locale" \
      en_US.UTF-8 "English (US)" "$_lu" \
      en_GB.UTF-8 "English (UK)" "$_lg" \
      de_DE.UTF-8 "German" "$_ld" \
      fr_FR.UTF-8 "French" "$_lf" \
      es_ES.UTF-8 "Spanish" "$_ls" \
      other "type a locale (e.g. pt_BR.UTF-8)" "$_lo")" || die "aborted"
    unset -v _lu _lg _ld _lf _ls _lo
    if [[ $LOCALE == other ]]; then
      LOCALE="$(ui_input "Locale" "$_loc_prev")" || die "aborted"
    fi
    unset -v _loc_prev
    valid_locale "$LOCALE" && break
    ui_error "locale not in SUPPORTED/locale.gen: ${LOCALE:-<empty>}"
  done
fi

if (( NONINTERACTIVE )); then
  [[ -n ${KEYMAP:-} ]] || die "NONINTERACTIVE needs KEYMAP in answers"
  valid_keymap "$KEYMAP" || die "NONINTERACTIVE needs valid KEYMAP in answers"
  ok "keymap from answers: $KEYMAP"
else
  while :; do
    KEYMAP="$(pick_keymap)" || die "aborted"
    valid_keymap "$KEYMAP" && break
    ui_error "keymap not available: ${KEYMAP:-<empty>} — pick again."
  done
fi
if (( ! DRYRUN )) && command -v loadkeys >/dev/null 2>&1; then
  loadkeys "$KEYMAP" 2>/dev/null || warn "loadkeys $KEYMAP failed on live ISO (vconsole still set in target)"
fi

if (( NONINTERACTIVE )); then
  [[ -n ${USERNAME:-} ]] || die "NONINTERACTIVE needs USERNAME in answers"
  valid_username "$USERNAME" || die "NONINTERACTIVE needs valid USERNAME in answers"
  ok "username from answers: $USERNAME"
else
  while :; do
    USERNAME="$(ui_input "Username (lowercase POSIX)" "${USERNAME:-}")" || die "aborted"
    if [[ -z $USERNAME ]]; then
      ui_warn "username cannot be empty"
    elif [[ $USERNAME == root ]]; then
      ui_warn "username cannot be 'root'"
    elif ! valid_username "$USERNAME"; then
      ui_error "invalid username (^[a-z_][a-z0-9_-]*\$, ≤32, not an existing user/group)"
    else
      break
    fi
  done
fi
if (( SECRETS_FROM_FILE )); then
  ok "user/root passwords from T14S_PASS_FILE"
else
  while :; do
    USER_PASS="$(ui_password "Password for $USERNAME")" || die "aborted"
    USER_PASS2="$(ui_password "Repeat password for $USERNAME")" || die "aborted"
    [[ -n $USER_PASS && $USER_PASS == "$USER_PASS2" ]] && break
    ui_warn "Empty or mismatched password — retry."
  done
  while :; do
    ROOT_PASS="$(ui_password 'Root password')" || die "aborted"
    ROOT_PASS2="$(ui_password 'Repeat root password')" || die "aborted"
    [[ -n $ROOT_PASS && $ROOT_PASS == "$ROOT_PASS2" ]] && break
    ui_warn "Empty or mismatched password — retry."
  done
fi
unset -v LUKS_PASS2 USER_PASS2 ROOT_PASS2

ui_step 8 Downloads
if (( NONINTERACTIVE )); then
  [[ $PACMAN_PARALLEL =~ ^(5|10|15)$ ]] \
    || die "NONINTERACTIVE needs PACMAN_PARALLEL=5|10|15"
  [[ $BTRFS_COMPRESS =~ ^(zstd1|zstd3|zstd15|none)$ ]] \
    || die "NONINTERACTIVE needs BTRFS_COMPRESS=zstd1|zstd3|zstd15|none"
  [[ $ZRAM_SIZE =~ ^(half|quarter|8192)$ ]] \
    || die "NONINTERACTIVE needs ZRAM_SIZE=half|quarter|8192"
else
  _p5=off; _p10=on; _p15=off
  case $PACMAN_PARALLEL in 5) _p5=on; _p10=off ;; 15) _p15=on; _p10=off ;; esac
  PACMAN_PARALLEL="$(ui_radio "pacman ParallelDownloads (live + target)" \
    5 "conservative (slow / flaky links)" "$_p5" \
    10 "balanced (default)" "$_p10" \
    15 "aggressive (fast links)" "$_p15")" || die "aborted"
  unset -v _p5 _p10 _p15

  _bc3=on; _bc1=off; _bc15=off; _bc0=off
  case $BTRFS_COMPRESS in
    zstd1) _bc1=on; _bc3=off ;;
    zstd15) _bc15=on; _bc3=off ;;
    none) _bc0=on; _bc3=off ;;
    *) BTRFS_COMPRESS=zstd3 ;;
  esac
  BTRFS_COMPRESS="$(ui_radio "Btrfs compression (mount options)" \
    zstd3 "zstd:3 — default balance" "$_bc3" \
    zstd1 "zstd:1 — faster, larger" "$_bc1" \
    zstd15 "zstd:15 — smaller, slower" "$_bc15" \
    none "no compression" "$_bc0")" || die "aborted"
  unset -v _bc3 _bc1 _bc15 _bc0

  _zh=on; _zq=off; _z8=off
  case $ZRAM_SIZE in
    quarter) _zq=on; _zh=off ;;
    8192) _z8=on; _zh=off ;;
    *) ZRAM_SIZE=half ;;
  esac
  ZRAM_SIZE="$(ui_radio "zram size" \
    half "min(RAM/2, 16G) — default" "$_zh" \
    quarter "min(RAM/4, 8G)" "$_zq" \
    8192 "fixed 8G" "$_z8")" || die "aborted"
  unset -v _zh _zq _z8
fi
[[ $PACMAN_PARALLEL =~ ^(5|10|15)$ ]] || PACMAN_PARALLEL=10
[[ $BTRFS_COMPRESS =~ ^(zstd1|zstd3|zstd15|none)$ ]] || BTRFS_COMPRESS=zstd3
[[ $ZRAM_SIZE =~ ^(half|quarter|8192)$ ]] || ZRAM_SIZE=half

# Split checklists (Core / Tools / Network). Defaults from preset + answers.
flag_from_opts() {
  local opts=$1 tag=$2
  printf '%s\n' "$opts" | grep -qx "$tag"
}

ui_step 9 Extras
if (( NONINTERACTIVE )); then
  # Keep EXTRA_PKGS already filled from EXTRA_PKGS_LIST (answers replay).
  :
else
  OPTS_CORE="$(ui_checklist "Core extras — Space toggles, Enter = Next" \
    gnome "Minimal GNOME desktop + Flatpak browsers/VPN" "$(def_onoff "$DESKTOP")" \
    nerd_fonts "Nerd Fonts + Inter/Noto" "$(def_onoff "$INSTALL_NERD_FONTS")" \
    sbctl "Enroll Secure Boot keys now (Setup Mode)" "$(def_onoff "$ENROLL_SB")" \
    sshd "Enable SSH server (sshd) after install" "$(def_onoff "$ENABLE_SSHD")" \
    cups "CUPS printing (cups + cups-pdf + ghostscript)" "$(def_onoff "$INSTALL_CUPS")" \
    skip_reflector "Skip live reflector; keep ISO mirrorlist" "$(def_onoff "$SKIP_REFLECTOR")" \
    tlp "TLP power mgmt (console-only; skipped if GNOME)" "$(def_onoff "$INSTALL_TLP")" \
    thinkfan "Write thinkfan AUR note (not in official repos)" "$(def_onoff "$INSTALL_THINKFAN")" \
    snapper_home "Snapper config for @home" "$(def_onoff "$INSTALL_SNAPPER_HOME")" \
    btrfs_assistant "btrfs-assistant (snapshot GUI; needs GNOME)" "$(def_onoff "$INSTALL_BTRFS_ASSISTANT")" \
    tuned "tuned + tuned-ppd + tuned-gui (replaces power-profiles-daemon)" "$(def_onoff "$INSTALL_TUNED")" \
    multilib "Enable [multilib] (32-bit: Steam, Wine)" "$(def_onoff "$INSTALL_MULTILIB")" \
    yay "yay AUR helper (yay-bin, built as your user)" "$(def_onoff "$INSTALL_YAY")" \
    linux_stable "Also install linux (stable) UKI" "$(def_onoff "$INSTALL_LINUX_STABLE")" \
    plymouth "Plymouth splash (optional)" "$(def_onoff "$INSTALL_PLYMOUTH")" \
    selftest "Write post-boot BT/audio self-test script" "$(def_onoff "$INSTALL_SELFTEST")" \
    clean_esp "Clean old Arch files from ESP (UKIs/entries/EFI/arch)" "$(def_onoff "$CLEAN_ESP_ARCH")" \
    chrome_hint "Write post-boot Chrome Flatpak helper script" "$(def_onoff "$INSTALL_CHROME_HINT")")" \
    || die "aborted"

  OPTS_TOOLS="$(ui_checklist "Dev / CLI tools" \
    devtools "Dev toolchains: gcc/clang/gdb, python, node, go, rustup, gh, nvim, code" "$(def_onoff "$INSTALL_DEVTOOLS")" \
    cli "ripgrep fd fzf bat eza jq git-delta" "$(def_onoff "$INSTALL_CLI")" \
    starship "starship prompt (+ wire into user zsh)" "$(def_onoff "$INSTALL_STARSHIP")" \
    podman "podman + buildah (rootless)" "$(def_onoff "$INSTALL_PODMAN")" \
    docker "docker + docker-compose (heavier)" "$(def_onoff "$INSTALL_DOCKER")" \
    virt "libvirt + qemu-desktop + virt-manager" "$(def_onoff "$INSTALL_VIRT")" \
    ollama "ollama-cuda (P15 only; localhost:11434)" "$([[ ${HW_PROFILE:-} == p15 ]] && def_onoff "${INSTALL_OLLAMA:-N}" || echo off)" \
    tmux "tmux" off \
    rsync "rsync" off \
    bash_completion "bash-completion" off \
    wget "wget" off \
    usbutils "usbutils" off \
    lsof "lsof" off \
    dmidecode "dmidecode" off \
    powertop "powertop" off \
    mc "mc (midnight commander)" off \
    traceroute "traceroute" off \
    bind "bind (dig/nslookup)" off \
    smartmontools "smartmontools (smartctl)" off)" || die "aborted"

  OPTS_NET="$(ui_checklist "Network / security extras" \
    avahi "avahi + nss-mdns (.local discovery)" "$(def_onoff "$INSTALL_AVAHI")" \
    wireguard "wireguard-tools" "$(def_onoff "$INSTALL_WIREGUARD")" \
    tailscale "tailscale" "$(def_onoff "$INSTALL_TAILSCALE")" \
    fail2ban "fail2ban (useful with sshd)" "$(def_onoff "$INSTALL_FAIL2BAN")" \
    fw_syncthing "firewalld allow Syncthing 22000/tcp+udp" "$(def_onoff "${FW_SYNCTHING:-$UFW_SYNCTHING}")" \
    fw_kdeconnect "firewalld allow KDE Connect 1714:1764/tcp+udp" "$(def_onoff "${FW_KDECONNECT:-$UFW_KDECONNECT}")")" \
    || die "aborted"

  DESKTOP=N; INSTALL_NERD_FONTS=N; ENROLL_SB=N; ENABLE_SSHD=N
  INSTALL_CUPS=N; SKIP_REFLECTOR=N; INSTALL_TLP=N; INSTALL_THINKFAN=N
  INSTALL_SNAPPER_HOME=N; INSTALL_LINUX_STABLE=N; INSTALL_PLYMOUTH=N
  INSTALL_SELFTEST=N; CLEAN_ESP_ARCH=N; INSTALL_CHROME_HINT=N
  INSTALL_MULTILIB=N; INSTALL_YAY=N; INSTALL_TUNED=N; INSTALL_DEVTOOLS=N
  INSTALL_BTRFS_ASSISTANT=N
  INSTALL_CLI=N; INSTALL_STARSHIP=N
  INSTALL_PODMAN=N; INSTALL_DOCKER=N; INSTALL_VIRT=N
  INSTALL_AVAHI=N; INSTALL_WIREGUARD=N; INSTALL_TAILSCALE=N
  INSTALL_FAIL2BAN=N; FW_SYNCTHING=N; FW_KDECONNECT=N; INSTALL_OLLAMA=N
  # Preserve packages already loaded from EXTRA_PKGS_LIST (answers replay).
  _extras_keep=("${EXTRA_PKGS[@]}")
  EXTRA_PKGS=()

  flag_from_opts "$OPTS_CORE" gnome && DESKTOP=Y || true
  flag_from_opts "$OPTS_CORE" nerd_fonts && INSTALL_NERD_FONTS=Y || true
  flag_from_opts "$OPTS_CORE" sbctl && ENROLL_SB=Y || true
  flag_from_opts "$OPTS_CORE" sshd && ENABLE_SSHD=Y || true
  flag_from_opts "$OPTS_CORE" cups && INSTALL_CUPS=Y || true
  flag_from_opts "$OPTS_CORE" skip_reflector && SKIP_REFLECTOR=Y || true
  flag_from_opts "$OPTS_CORE" tlp && INSTALL_TLP=Y || true
  flag_from_opts "$OPTS_CORE" thinkfan && INSTALL_THINKFAN=Y || true
  flag_from_opts "$OPTS_CORE" snapper_home && INSTALL_SNAPPER_HOME=Y || true
  flag_from_opts "$OPTS_CORE" linux_stable && INSTALL_LINUX_STABLE=Y || true
  flag_from_opts "$OPTS_CORE" plymouth && INSTALL_PLYMOUTH=Y || true
  flag_from_opts "$OPTS_CORE" selftest && INSTALL_SELFTEST=Y || true
  flag_from_opts "$OPTS_CORE" clean_esp && CLEAN_ESP_ARCH=Y || true
  flag_from_opts "$OPTS_CORE" chrome_hint && INSTALL_CHROME_HINT=Y || true
  flag_from_opts "$OPTS_CORE" btrfs_assistant && INSTALL_BTRFS_ASSISTANT=Y || true
  flag_from_opts "$OPTS_CORE" tuned && INSTALL_TUNED=Y || true
  flag_from_opts "$OPTS_CORE" multilib && INSTALL_MULTILIB=Y || true
  flag_from_opts "$OPTS_CORE" yay && INSTALL_YAY=Y || true

  flag_from_opts "$OPTS_TOOLS" devtools && INSTALL_DEVTOOLS=Y || true
  flag_from_opts "$OPTS_TOOLS" cli && INSTALL_CLI=Y || true
  flag_from_opts "$OPTS_TOOLS" starship && INSTALL_STARSHIP=Y || true
  flag_from_opts "$OPTS_TOOLS" podman && INSTALL_PODMAN=Y || true
  flag_from_opts "$OPTS_TOOLS" docker && INSTALL_DOCKER=Y || true
  flag_from_opts "$OPTS_TOOLS" virt && INSTALL_VIRT=Y || true
  flag_from_opts "$OPTS_TOOLS" ollama && INSTALL_OLLAMA=Y || true
  [[ ${HW_PROFILE:-} == p15 ]] || INSTALL_OLLAMA=N
  # htop/btop/fastfetch ship in BASE_PKGS (always installed with firewalld).
  flag_from_opts "$OPTS_TOOLS" tmux && EXTRA_PKGS+=(tmux) || true
  flag_from_opts "$OPTS_TOOLS" rsync && EXTRA_PKGS+=(rsync) || true
  flag_from_opts "$OPTS_TOOLS" bash_completion && EXTRA_PKGS+=(bash-completion) || true
  flag_from_opts "$OPTS_TOOLS" wget && EXTRA_PKGS+=(wget) || true
  flag_from_opts "$OPTS_TOOLS" usbutils && EXTRA_PKGS+=(usbutils) || true
  flag_from_opts "$OPTS_TOOLS" lsof && EXTRA_PKGS+=(lsof) || true
  flag_from_opts "$OPTS_TOOLS" dmidecode && EXTRA_PKGS+=(dmidecode) || true
  flag_from_opts "$OPTS_TOOLS" powertop && EXTRA_PKGS+=(powertop) || true
  flag_from_opts "$OPTS_TOOLS" mc && EXTRA_PKGS+=(mc) || true
  flag_from_opts "$OPTS_TOOLS" traceroute && EXTRA_PKGS+=(traceroute) || true
  flag_from_opts "$OPTS_TOOLS" bind && EXTRA_PKGS+=(bind) || true
  flag_from_opts "$OPTS_TOOLS" smartmontools && EXTRA_PKGS+=(smartmontools) || true

  flag_from_opts "$OPTS_NET" avahi && INSTALL_AVAHI=Y || true
  flag_from_opts "$OPTS_NET" wireguard && INSTALL_WIREGUARD=Y || true
  flag_from_opts "$OPTS_NET" tailscale && INSTALL_TAILSCALE=Y || true
  flag_from_opts "$OPTS_NET" fail2ban && INSTALL_FAIL2BAN=Y || true
  flag_from_opts "$OPTS_NET" fw_syncthing && FW_SYNCTHING=Y || true
  flag_from_opts "$OPTS_NET" fw_kdeconnect && FW_KDECONNECT=Y || true

  # Re-apply answers extras after checklist rebuild (dedupe later at pacstrap).
  if ((${#_extras_keep[@]})); then
    EXTRA_PKGS+=("${_extras_keep[@]}")
  fi
  unset -v _extras_keep

  if [[ $SKIP_REFLECTOR != Y ]]; then
    REFLECTOR_COUNTRY="$(ui_input "Reflector --country (ISO codes, comma-ok; empty=worldwide)" \
      "${REFLECTOR_COUNTRY:-}")" || die "aborted"
  else
    REFLECTOR_COUNTRY=
  fi

  # Hook preset: none / env default (T14S_DEFAULT_HOOK_URL) / custom URL.
  # Never hardcode a private repo URL (smoke forbids linking private trees).
  _hp_none=on; _hp_env=off; _hp_custom=off
  if [[ -n ${POST_HOOK_URL:-} ]]; then
    _hp_none=off; _hp_custom=on
  elif [[ -n ${T14S_DEFAULT_HOOK_URL:-} ]]; then
    _hp_none=off; _hp_env=on
  fi
  _hook_menu=(none "skip post-install hook" "$_hp_none")
  if [[ -n ${T14S_DEFAULT_HOOK_URL:-} ]]; then
    _hook_menu+=(env "use T14S_DEFAULT_HOOK_URL" "$_hp_env")
  fi
  _hook_menu+=(custom "type a HTTPS hook URL" "$_hp_custom")
  HOOK_PRESET="$(ui_radio "Post-install hook (curl|bash as root in new system)" \
    "${_hook_menu[@]}")" || die "aborted"
  unset -v _hp_none _hp_env _hp_custom _hook_menu
  case $HOOK_PRESET in
    env)
      POST_HOOK_URL=${T14S_DEFAULT_HOOK_URL:-}
      [[ -n $POST_HOOK_URL ]] || die "T14S_DEFAULT_HOOK_URL empty"
      ;;
    custom)
      POST_HOOK_URL="$(ui_input "Post-install hook URL (HTTPS; empty=skip)" \
        "${POST_HOOK_URL:-}")" || die "aborted"
      ;;
    *) POST_HOOK_URL= ;;
  esac
  unset -v HOOK_PRESET
fi

# TLP conflicts with GNOME power-profiles-daemon and with tuned — force off.
if yn_on "$DESKTOP" && yn_on "$INSTALL_TLP"; then
  warn "TLP skipped — GNOME uses power-profiles-daemon / tuned-ppd"
  INSTALL_TLP=N
fi
if yn_on "$INSTALL_TUNED" && yn_on "$INSTALL_TLP"; then
  warn "TLP skipped — tuned selected (tlp conflicts with tuned)"
  INSTALL_TLP=N
fi
# btrfs-assistant is a GUI (Qt) — only with the desktop.
if yn_on "$INSTALL_BTRFS_ASSISTANT" && ! yn_on "$DESKTOP"; then
  warn "btrfs-assistant skipped — no desktop (use snapper CLI)"
  INSTALL_BTRFS_ASSISTANT=N
fi
# Re-apply VM/ThinkPad skip after checklist (thinkfan may have been re-enabled).
if yn_on "$SKIP_THINKPAD_HW"; then
  INSTALL_THINKFAN=N
fi
# Fresh-format ESP already empty; CLEAN_ESP_ARCH is ignored (forced Y in answers).
if [[ ${FORMAT_EFI:-1} == 1 ]]; then
  CLEAN_ESP_ARCH=Y
elif ! yn_on "${CLEAN_ESP_ARCH:-Y}"; then
  warn "CLEAN_ESP_ARCH=N — keeping prior Arch UKIs/arch*.conf; kernels/ucode still removed (pacstrap). Boot menu may show dead entries until you delete them."
fi
# Reflector country sanitize (letters/comma/space only).
if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
  _rc_re='^[A-Za-z][A-Za-z ,]*$'
  if ! [[ $REFLECTOR_COUNTRY =~ $_rc_re ]]; then
    warn "ignoring invalid REFLECTOR_COUNTRY=$REFLECTOR_COUNTRY"
    REFLECTOR_COUNTRY=
  fi
  unset -v _rc_re
fi

# Optional free-form extras (archfi -cpl spirit). Env T14S_EXTRA_PKGS appends.
if (( ! NONINTERACTIVE )); then
  _extra_in="$(ui_input "More pacstrap packages (space-separated, empty=none)" \
    "${T14S_EXTRA_PKGS:-}")" || die "aborted"
else
  _extra_in=${T14S_EXTRA_PKGS:-}
fi
if [[ -n ${_extra_in// /} ]]; then
  read -r -a _pkgs <<<"$_extra_in"
  for _p in "${_pkgs[@]}"; do
    if [[ $_p =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]; then
      EXTRA_PKGS+=("$_p")
    else
      ui_warn "Skipping invalid package name: $_p"
    fi
  done
fi
unset -v _extra_in _p _pkgs
# Persist extras for answers replay (space-separated).
EXTRA_PKGS_LIST="${EXTRA_PKGS[*]:-}"

# Canonicalize boolean flags (answers may use on/1; chroot + saves want Y/N).
for _flag in DESKTOP INSTALL_NERD_FONTS ENROLL_SB ENABLE_SSHD INSTALL_CUPS \
  SKIP_REFLECTOR INSTALL_TLP INSTALL_CLI INSTALL_PODMAN INSTALL_DOCKER \
  INSTALL_VIRT INSTALL_AVAHI INSTALL_WIREGUARD INSTALL_TAILSCALE \
  INSTALL_STARSHIP INSTALL_CHROME_HINT INSTALL_FAIL2BAN INSTALL_THINKFAN \
  INSTALL_SNAPPER_HOME INSTALL_LINUX_STABLE INSTALL_PLYMOUTH INSTALL_SELFTEST \
  CLEAN_ESP_ARCH INSTALL_MULTILIB INSTALL_YAY INSTALL_TUNED INSTALL_DEVTOOLS INSTALL_BTRFS_ASSISTANT \
  INSTALL_OLLAMA FW_SYNCTHING FW_KDECONNECT \
  UFW_SYNCTHING UFW_KDECONNECT SKIP_THINKPAD_HW
do
  [[ -v $_flag ]] || printf -v "$_flag" '%s' N
  yn_canon "$_flag"
done
unset -v _flag
# Prefer FW_*; keep UFW_* mirrors for old answers / tooling.
UFW_SYNCTHING=$FW_SYNCTHING
UFW_KDECONNECT=$FW_KDECONNECT

# ── final summary ───────────────────────────────────────────
ui_step 10 Review
_REVIEW="REVIEW — nothing has been written yet.

  Disk          $DISK $(size_mb "$DISK")MB ($([[ $MODE == auto ]] && echo "AUTO wipe, ${ESP_MB}MB ESP" || echo manual))
  EFI           $EFI_PART $(size_mb "$EFI_PART")MB ($([[ $FORMAT_EFI == 1 ]] && echo format || echo reuse))
  Clean ESP     $CLEAN_ESP_ARCH (old Arch UKIs/entries/EFI/arch)
  ROOT          $ROOT_PART $(size_mb "$ROOT_PART")MB (LUKS2, wipe=${LUKS_WIPE})
  Hostname      $HOSTNAME
  Timezone      $TIMEZONE
  Locale        $LOCALE
  Keymap        $KEYMAP
  User          $USERNAME
  Profile       $PRESET
  Parallel DL   $PACMAN_PARALLEL
  Btrfs/zram    compress=$BTRFS_COMPRESS zram=$ZRAM_SIZE
  Reflector     $([[ $SKIP_REFLECTOR == Y ]] && echo skip || echo "refresh${REFLECTOR_COUNTRY:+ ($REFLECTOR_COUNTRY)}")
  ThinkPad HW   $([[ $SKIP_THINKPAD_HW == Y ]] && echo skip || echo apply)
  Extra pkgs    $( ((${#EXTRA_PKGS[@]})) && printf '%s ' "${EXTRA_PKGS[@]}" || echo none)
  Desktop       $([[ $DESKTOP == Y ]] && echo 'minimal GNOME' || echo none)
  Nerd Fonts    $([[ $INSTALL_NERD_FONTS == Y ]] && echo curated set || echo no)
  Snapper       home=$INSTALL_SNAPPER_HOME gui=$INSTALL_BTRFS_ASSISTANT
  pacman/AUR    multilib=$INSTALL_MULTILIB yay=$INSTALL_YAY
  Power         $([[ $INSTALL_TUNED == Y ]] && echo 'tuned + tuned-ppd' || echo power-profiles-daemon)
  Dev tools     $INSTALL_DEVTOOLS
  linux/plymouth linux=$INSTALL_LINUX_STABLE plymouth=$INSTALL_PLYMOUTH
  CLI/Podman    cli=$INSTALL_CLI podman=$INSTALL_PODMAN docker=$INSTALL_DOCKER virt=$INSTALL_VIRT
  Net           avahi=$INSTALL_AVAHI wg=$INSTALL_WIREGUARD tailscale=$INSTALL_TAILSCALE
  CUPS/TLP/SB   cups=$INSTALL_CUPS tlp=$INSTALL_TLP sb=$ENROLL_SB
  SSH/f2b       sshd=$ENABLE_SSHD fail2ban=$INSTALL_FAIL2BAN
  Hook URL      ${POST_HOOK_URL:-none}
  Pass file     ${PASS_FILE:-none}

Typed passwords are not redisplayed."
if (( NONINTERACTIVE )); then
  ok "NONINTERACTIVE: skipping REVIEW/confirm UI"
  printf '%s\n' "$_REVIEW" | while IFS= read -r _l; do say "$_l"; done
else
  ui_info "$_REVIEW"
  ui_yesno "Start the installation? The partitions above will be ERASED." no erase \
    || die "aborted by user"
fi
unset -v _REVIEW _l

# Validate optional post-hook URL before wipe / DRYRUN exit.
if [[ -n ${POST_HOOK_URL:-} ]]; then
  [[ $POST_HOOK_URL =~ ^https://[^[:space:]@]+$ ]] \
    || die "POST_HOOK_URL must be https://… with no userinfo or spaces (got: $POST_HOOK_URL)"
fi

ANSWERS_OUT="${T14S_ANSWERS_OUT:-/tmp/t14s-answers.env}"
answers_save "$ANSWERS_OUT" || warn "could not write answers to $ANSWERS_OUT"
ok "answers saved: $ANSWERS_OUT (reload: T14S_ANSWERS=$ANSWERS_OUT)"

if (( DRYRUN )); then
  printf 'DRYRUN: preset=%s EFI=%s ROOT=%s host=%s user=%s locale=%s tz=%s keymap=%s wipe=%s parallel=%s desktop=%s nerd=%s cli=%s podman=%s docker=%s virt=%s avahi=%s sshd=%s extra=%s\n' \
    "$PRESET" "$EFI_PART" "$ROOT_PART" "$HOSTNAME" "$USERNAME" \
    "$LOCALE" "$TIMEZONE" "$KEYMAP" "$LUKS_WIPE" "$PACMAN_PARALLEL" \
    "$DESKTOP" "$INSTALL_NERD_FONTS" "$INSTALL_CLI" "$INSTALL_PODMAN" \
    "$INSTALL_DOCKER" "$INSTALL_VIRT" "$INSTALL_AVAHI" "$ENABLE_SSHD" \
    "${EXTRA_PKGS[*]:-}"
  exit 0
fi

start_log
ui_step 11 Install

# Release leftover state from a previous interrupted run on the CONFIRMED target
# (an open cryptroot / mounted /mnt keeps the disk busy → sgdisk/mkfs fail).
release_target_devices

# ── 4b. write the partition table (AUTO only) ───────────────
if [[ $MODE == auto ]]; then
  step "partitioning $DISK (GPT: 2G ESP + LUKS)"
  sgdisk --zap-all "$DISK" >/dev/null
  sgdisk -n1:0:+"${ESP_MB}"M -t1:ef00 -c1:EFI "$DISK" >/dev/null
  sgdisk -n2:0:0     -t2:8309 -c2:cryptroot "$DISK" >/dev/null
  partprobe "$DISK"; udevadm settle 2>/dev/null || sleep 2
fi

# ── 5. encrypt + filesystems ────────────────────────────────
step "LUKS2 format (argon2id) on $ROOT_PART"
wipefs -a "$ROOT_PART" >/dev/null 2>&1 || true   # clear stale signatures (dirty/reused disk)
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode "$ROOT_PART" -
printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
unset -v LUKS_PASS
LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"   # LUKS header UUID (for rd.luks.name)
[[ -n $LUKS_UUID ]] || die "could not read LUKS UUID from $ROOT_PART"
ok "LUKS open as /dev/mapper/cryptroot (LUKS UUID=$LUKS_UUID)"

# Optional full-volume wipe before mkfs; then btrfs subvols + ESP mount.
apply_luks_wipe
do_btrfs_and_mount

# ── 6. base install ─────────────────────────────────────────
case ${HW_PROFILE:-t14s} in
  p15) UCODE=intel-ucode ;;
  *)   UCODE=amd-ucode ;;
esac

# Reflector rates every candidate mirror by downloading its repo DB. Without
# --threads that loop is serial, so a handful of dead mirrors stall the install
# for minutes behind a blank screen. Bound it: few candidates, concurrent rating,
# short timeouts, hard overall deadline. Write to a temp file first so a killed or
# empty run never clobbers a usable mirrorlist.
ML_TMP="$(mktemp)"
_reflector_args=(--latest 10 --protocol https --sort rate
  --threads 5 --connection-timeout 3 --download-timeout 5 --save "$ML_TMP")
if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
  _reflector_args+=(--country "$REFLECTOR_COUNTRY")
fi
if [[ $SKIP_REFLECTOR == Y ]]; then
  ok "reflector skipped by operator — using ISO mirrorlist"
elif run_progress "refreshing live mirrors (best-effort, ≤45s)" \
     timeout 45 reflector "${_reflector_args[@]}" \
   && (( $(grep -c '^Server' "$ML_TMP") >= 3 )); then
  cat "$ML_TMP" > /etc/pacman.d/mirrorlist   # keep existing inode/perms (0644)
  ok "mirrorlist refreshed ($(grep -c '^Server' "$ML_TMP") mirrors)"
else
  warn "reflector skipped, timed out, or returned too few mirrors — keeping current mirrorlist"
fi
rm -f "$ML_TMP"
unset -v _reflector_args

# Live ISO pacman (pacstrap uses this file). Built-in downloader only:
# XferCommand makes pacman fetch one file at a time and ignore ParallelDownloads
# (old runs of this script added a curl XferCommand — drop it on re-runs).
# DisableDownloadTimeout keeps slow mirrors from aborting ("Operation too slow").
# Single pacstrap — no retry loop, which would re-run on a partially-populated
# root and hit 'conflicting files'.
pacman_tune /etc/pacman.conf "$PACMAN_PARALLEL"

t14s_base_packages
# Deduplicate extras already in the fixed base set.
if ((${#EXTRA_PKGS[@]})); then
  _seen=' '
  for _p in "${BASE_PKGS[@]}"; do _seen+="$_p "; done
  _extra_clean=()
  for _p in "${EXTRA_PKGS[@]}"; do
    [[ $_seen == *" $_p "* ]] && continue
    _extra_clean+=("$_p")
    _seen+="$_p "
  done
  EXTRA_PKGS=("${_extra_clean[@]}")
  unset -v _seen _extra_clean _p
fi
run_gauge "pacstrap base system ($UCODE) — downloading/installing packages" 0 100 \
  pacstrap -K /mnt "${BASE_PKGS[@]}" ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"}

step "genfstab"
genfstab -U /mnt >> /mnt/etc/fstab
# add nofail to the /tmp line (failure must not block boot)
sed -i -E '/[[:space:]]\/tmp[[:space:]]+btrfs/ s/(subvol=\/?@tmp)/\1,nofail/' /mnt/etc/fstab || true
# ESP root-only: systemd-boot refuses a world-readable random-seed
# ("Mount point '/boot' … is world accessible, which is a security hole").
sed -i -E '/[[:space:]]\/boot[[:space:]]+vfat/ s/fmask=[0-7]+/fmask=0077/; /[[:space:]]\/boot[[:space:]]+vfat/ s/dmask=[0-7]+/dmask=0077/' /mnt/etc/fstab || true
ok "base installed"


# ── 7. chroot configuration ─────────────────────────────────
say "deploying chroot setup + firewall module"
mkdir -p /mnt/root/t14s-lib
_deploy_lib() {
  local f=$1
  if [[ -n ${T14S_LIB_DIR:-} && -f $T14S_LIB_DIR/$f ]]; then
    cp -a "$T14S_LIB_DIR/$f" "/mnt/root/t14s-lib/$f"
  elif [[ -n ${T14S_LIB_FETCH_DIR:-} && -f $T14S_LIB_FETCH_DIR/$f ]]; then
    cp -a "$T14S_LIB_FETCH_DIR/$f" "/mnt/root/t14s-lib/$f"
  else
    curl -fsSL "$T14S_BASE_URL/lib/$f" -o "/mnt/root/t14s-lib/$f" \
      || die "failed to fetch lib/$f from $T14S_BASE_URL"
  fi
  [[ -s /mnt/root/t14s-lib/$f ]] || die "deployed lib/$f is missing or empty"
}
_deploy_lib 70-firewall.sh
_deploy_lib 80-chroot-setup.sh
install -m 755 /mnt/root/t14s-lib/80-chroot-setup.sh /mnt/root/chroot-setup.sh
unset -f _deploy_lib


# Passwords via 0600 file (not arch-chroot env — visible in /proc/*/environ).
# umask 077 only in this subshell: a script-wide umask leaks into arch-chroot
# and leaves /etc/locale.conf, sysctl.d, dconf … at 0600 (LANG unset for users).
(
  umask 077
  {
    printf 'USERNAME=%q\n' "$USERNAME"
    printf 'USER_PASS=%q\n' "$USER_PASS"
    printf 'ROOT_PASS=%q\n' "$ROOT_PASS"
  } > /mnt/root/.install-secrets
)
chmod 600 /mnt/root/.install-secrets
unset -v USER_PASS ROOT_PASS

chmod +x /mnt/root/chroot-setup.sh
# Host helpers the chroot reuses (single source: no duplicated function bodies).
declare -f pacman_tune >/mnt/root/t14s-lib.sh
rm -f /mnt/root/t14s-warnings.txt
cleanup_chroot_secrets() {
  shred -u /mnt/root/chroot-setup.sh /mnt/root/.install-secrets 2>/dev/null \
    || rm -f /mnt/root/chroot-setup.sh /mnt/root/.install-secrets
  rm -f /mnt/root/t14s-lib.sh
  rm -rf /mnt/root/t14s-lib
}
# Always drop secrets file even if chroot fails (set -e would otherwise skip shred).
# SNAP_PAC_SKIP=y: snap-pac hooks can't run snapper in the chroot ("fatal
# library error, lookup self"); snapshots start on the booted system.
if ! run_gauge "chroot config (UKIs, users, optional GNOME)" 0 100 \
  arch-chroot /mnt env \
    TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" KEYMAP="$KEYMAP" HOSTNAME="$HOSTNAME" \
    USERNAME="$USERNAME" \
    LUKS_UUID="$LUKS_UUID" DESKTOP="$DESKTOP" ENROLL_SB="$ENROLL_SB" \
    ENABLE_SSHD="$ENABLE_SSHD" FORMAT_EFI="$FORMAT_EFI" \
    PACMAN_PARALLEL="$PACMAN_PARALLEL" INSTALL_CUPS="$INSTALL_CUPS" \
    INSTALL_NERD_FONTS="$INSTALL_NERD_FONTS" \
    INSTALL_CLI="$INSTALL_CLI" INSTALL_STARSHIP="$INSTALL_STARSHIP" \
    INSTALL_PODMAN="$INSTALL_PODMAN" INSTALL_DOCKER="$INSTALL_DOCKER" \
    INSTALL_VIRT="$INSTALL_VIRT" INSTALL_TLP="$INSTALL_TLP" \
    INSTALL_THINKFAN="$INSTALL_THINKFAN" INSTALL_AVAHI="$INSTALL_AVAHI" \
    INSTALL_WIREGUARD="$INSTALL_WIREGUARD" INSTALL_TAILSCALE="$INSTALL_TAILSCALE" \
    INSTALL_FAIL2BAN="$INSTALL_FAIL2BAN" INSTALL_CHROME_HINT="$INSTALL_CHROME_HINT" \
    INSTALL_SNAPPER_HOME="$INSTALL_SNAPPER_HOME" \
    INSTALL_MULTILIB="$INSTALL_MULTILIB" INSTALL_YAY="$INSTALL_YAY" \
    INSTALL_TUNED="$INSTALL_TUNED" INSTALL_DEVTOOLS="$INSTALL_DEVTOOLS" \
    INSTALL_BTRFS_ASSISTANT="$INSTALL_BTRFS_ASSISTANT" \
    INSTALL_LINUX_STABLE="$INSTALL_LINUX_STABLE" INSTALL_PLYMOUTH="$INSTALL_PLYMOUTH" \
    INSTALL_SELFTEST="$INSTALL_SELFTEST" CLEAN_ESP_ARCH="$CLEAN_ESP_ARCH" \
    ZRAM_SIZE="$ZRAM_SIZE" REFLECTOR_COUNTRY="$REFLECTOR_COUNTRY" \
    SKIP_THINKPAD_HW="$SKIP_THINKPAD_HW" \
    HW_PROFILE="$HW_PROFILE" INSTALL_OLLAMA="$INSTALL_OLLAMA" \
    FW_SYNCTHING="$FW_SYNCTHING" FW_KDECONNECT="$FW_KDECONNECT" \
    UFW_SYNCTHING="$UFW_SYNCTHING" UFW_KDECONNECT="$UFW_KDECONNECT" \
    SNAP_PAC_SKIP=y \
    bash /root/chroot-setup.sh
then
  cleanup_chroot_secrets
  die "chroot setup failed"
fi
cleanup_chroot_secrets
ok "chroot config complete"

# Backstop for the umask regression: these must be world-readable or users get
# LANG unset / "dconf … Unable to open /etc/dconf/profile/user: Permission denied".
for _f in etc/locale.conf etc/vconsole.conf etc/hostname etc/hosts etc/kernel/cmdline \
          etc/pacman.conf etc/makepkg.conf.d/t14s.conf etc/dconf/profile/user \
          etc/dconf/db/local etc/dconf/db/local.d/00-t14s etc/gdm/custom.conf \
          etc/dconf/profile/gdm etc/dconf/db/gdm etc/dconf/db/gdm.d/00-login-screen \
          etc/sysctl.d/99-security.conf etc/systemd/zram-generator.conf \
          etc/tmpfiles.d/thinkpad-charge-thresholds.conf \
          etc/systemd/sleep.conf.d/s2idle.conf etc/systemd/logind.conf.d/thinkpad-lid.conf \
          etc/udev/rules.d/61-thinkpad-charge-limit.rules \
          etc/udev/rules.d/71-thinkpad-t14s-touchpad-wakeup.rules \
          etc/udev/rules.d/61-gdm-wayland.rules \
          etc/environment.d/99-wayland.conf etc/systemd/system/gdm.service.d/override.conf; do
  [[ -e /mnt/$_f ]] || continue
  if [[ $(( 8#$(stat -c '%a' "/mnt/$_f") & 8#004 )) -eq 0 ]]; then
    chmod a+r "/mnt/$_f"
    warn "fixed permissions on /$_f (was not world-readable)"
    printf 'fixed permissions on /%s (was not world-readable)\n' "$_f" >>/mnt/root/t14s-warnings.txt
  fi
done
unset -v _f

# Collected chroot warnings → finish screen + /root/t14s-post-install.txt.
INSTALL_WARNINGS=""
if [[ -s /mnt/root/t14s-warnings.txt ]]; then
  INSTALL_WARNINGS=$(sort -u /mnt/root/t14s-warnings.txt)
fi

# Persist answers + optional post-install hook (dotfiles bootstrap URL).
answers_save /mnt/root/t14s-answers.env || true
if [[ -n ${POST_HOOK_URL:-} ]]; then
  # Remote script runs as root in the new system — require explicit consent.
  # Fail closed on scheme before consent / download (curl --proto is a backstop).
  [[ $POST_HOOK_URL =~ ^https://[^[:space:]@]+$ ]] \
    || die "POST_HOOK_URL must be https://… with no userinfo or spaces (got: $POST_HOOK_URL)"
  _hook_ok=0
  if (( NONINTERACTIVE )); then
    if [[ ${T14S_POST_HOOK_I_UNDERSTAND:-0} == 1 ]]; then
      _hook_ok=1
    else
      warn "post-hook skipped in NONINTERACTIVE without T14S_POST_HOOK_I_UNDERSTAND=1"
    fi
  else
    if ui_yesno "Run post-install hook as root in the new system?

URL: $POST_HOOK_URL

This downloads and executes remote code. Continue only if you trust the URL." no critical; then
      _hook_ok=1
    else
      warn "post-install hook skipped by operator"
    fi
  fi
  if (( _hook_ok )); then
    step "post-install hook: $POST_HOOK_URL"
    # Download to a temp file (optional SHA-256), then feed arch-chroot — never
    # pipe curl straight into bash when a pin is set or verification is wanted.
    if run_progress "post-install hook" \
         env POST_HOOK_URL="$POST_HOOK_URL" T14S_POST_HOOK_SHA256="${T14S_POST_HOOK_SHA256:-}" \
         bash -c 'set -euo pipefail
           tmp=$(mktemp)
           trap "rm -f -- \"$tmp\"" EXIT
           curl -fsSL --proto "=https" --tlsv1.2 --max-time 120 -o "$tmp" "$POST_HOOK_URL"
           if [[ -n ${T14S_POST_HOOK_SHA256:-} ]]; then
             got=$(sha256sum "$tmp" | awk "{print \$1}")
             [[ $got == "$T14S_POST_HOOK_SHA256" ]] \
               || { echo "post-hook SHA-256 mismatch (got $got want $T14S_POST_HOOK_SHA256)" >&2; exit 1; }
           fi
           arch-chroot /mnt bash -s <"$tmp"'
    then
      ok "post-install hook finished"
    else
      warn "post-install hook failed — re-run manually after boot"
    fi
  fi
  unset -v _hook_ok
fi

# ── 8. finish ───────────────────────────────────────────────
ui_step 0 Done
if yn_on "$DESKTOP"; then
  LOGIN_HINT="First login via GDM (Wayland).
  Flatpak browsers/VPN install in the background on first boot once online
  (connect Wi-Fi; retries every 5 min): journalctl -u t14s-flatpak-apps -f"
  FLATPAK_HINT="Optional post-boot: flatpak install --user -y flathub com.google.Chrome"
else
  LOGIN_HINT="Desktop skipped — log in on a virtual console (getty) as ${USERNAME}."
  FLATPAK_HINT="Optional later: pacman -S gnome-shell gdm flatpak && systemctl enable gdm"
fi
yn_on "$INSTALL_CHROME_HINT" \
  && FLATPAK_HINT="Chrome helper: ~${USERNAME}/install-chrome-flatpak.sh (flatpak install --user -y flathub com.google.Chrome)"

if yn_on "$INSTALL_SNAPPER_HOME"; then
  SNAPPER_HINT="root + home configs enabled"
else
  SNAPPER_HINT="root config enabled; add home later: snapper -c home create-config /home"
fi
if yn_on "$INSTALL_SELFTEST"; then
  SELFTEST_HINT="Self-test: /usr/local/bin/t14s-selftest (BT/audio/wifi/apparmor/firewalld/s2idle/amd_pstate/BAT0/touchpad)"
else
  SELFTEST_HINT="Self-test script not installed"
fi

# Optional hint lines (plain if/else: a failing $(…) inside POST_TXT="…"
# would make the assignment return 1 under set -e).
EXTRA_HINTS=""
if yn_on "$INSTALL_YAY"; then
  EXTRA_HINTS+="  AUR: yay -S <pkg>   (makepkg uses all cores; no -debug pkgs)
"
fi
if yn_on "$INSTALL_DEVTOOLS"; then
  EXTRA_HINTS+="  Rust: rustup default stable   (per-user toolchain)
"
fi

POST_TXT="T14s install — next steps

  Reboot and remove the ISO:   reboot
  Boot menu: Arch Linux (LTS) default, Hardened as fallback.
  Answers file: /root/t14s-answers.env (T14S_ANSWERS=... to reuse)
  Passwords: use T14S_PASS_FILE for unattended (never stored in answers)
  Verify after boot: lscpu | grep -i ryzen
                     cat /sys/power/mem_sleep   (expect s2idle bracketed)
  Secure Boot (to enable):
    1) BIOS -> clear Secure Boot keys -> Setup Mode
    2) booted OS: sudo sbctl enroll-keys -m
    3) BIOS -> Secure Boot -> Enabled   (pacman hook auto-resigns on updates)
    multiboot: '-m' keeps Microsoft keys so Windows still boots; other
    unsigned Linux loaders won't boot under SB until you 'sbctl sign' them.
    If enroll fails: keep SB off, or boot LTS UKI then enroll.
  Recovery (from Arch ISO):
    cryptsetup open /dev/<root> cryptroot
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    mount /dev/<esp> /mnt/boot
    arch-chroot /mnt
  Snapper: ${SNAPPER_HINT}
  ${SELFTEST_HINT}
  linux-hardened + Flatpak: userns sysctl already set (99-userns.conf).
  Fingerprint (fprintd on GNOME): fprintd-enroll
  Hostname: ${HOSTNAME}
  ${LOGIN_HINT}
  Post-boot check: grep -E 'amd_iommu|amd_pstate' /proc/cmdline
  Charge thresholds (ThinkPad BAT* only; skip/absent on VM):
    cat /sys/class/power_supply/BAT0/charge_control_*_threshold
    (expect 70 / 80; oneshot thinkpad-charge-thresholds.service + tmpfiles)
${EXTRA_HINTS}  Full install log: /var/log/t14s-install.log (root only)
  ${FLATPAK_HINT}"
if [[ -n $INSTALL_WARNINGS ]]; then
  POST_TXT+="

  Warnings during install (details in /var/log/t14s-install.log):
$(printf '%s\n' "$INSTALL_WARNINGS" | sed 's/^/    - /')"
fi

printf '%s\n' "$POST_TXT" > /mnt/root/t14s-post-install.txt
rm -f /mnt/root/t14s-warnings.txt   # already merged into t14s-post-install.txt

step "unmounting"
# Keep the full log on the installed system (live /tmp is gone after reboot).
# Passwords never reach it (secrets go via a 0600 file, not command output).
install -m 600 "$LOG" /mnt/var/log/t14s-install.log 2>/dev/null \
  || warn "could not copy install log to /var/log/t14s-install.log"
umount -R /mnt
cryptsetup close cryptroot
stop_log

if [[ -n $INSTALL_WARNINGS ]]; then
  ui_warn "INSTALL COMPLETE with warnings — reboot and remove the ISO.

$(printf '%s' "$POST_TXT")"
else
  ui_ok "INSTALL COMPLETE — reboot and remove the ISO.

$(printf '%s' "$POST_TXT")"
fi
ok "done — reboot when ready"
