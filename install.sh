#!/usr/bin/env bash
# install.sh — interactive hardened Arch install for ThinkPad T14s Gen 3 AMD
#               (machine type 21CQ / 21CR; example MTM 21CRS1PU00)
#
# Target: Rembrandt-U (Ryzen 5/7 PRO 6650U/6850U), soldered LPDDR5, amdgpu,
#         Wi-Fi 6E, 57Wh, s2idle.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
#
# Stack: LUKS2(argon2id) + Btrfs + linux-lts/hardened UKIs + systemd-boot +
#        sbctl Secure Boot + minimal GNOME. AMD defaults: amd-ucode,
#        amd_iommu=on, amd_pstate=active. Hostname default: thinkpad-t14s.
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

# ── ui helpers ──────────────────────────────────────────────
c0=$'\e[0m'; cR=$'\e[1;31m'; cG=$'\e[1;32m'; cY=$'\e[1;33m'; cB=$'\e[1;34m'
say()  { printf '%s>>%s %s\n' "$cB" "$c0" "$*"; }
ok()   { printf '%s ok%s %s\n' "$cG" "$c0" "$*"; }
warn() { printf '%s !!%s %s\n' "$cY" "$c0" "$*" >&2; }

DRYRUN=${T14S_DRYRUN:-0}
UI=${T14S_UI:-plain}
APP_TITLE="T14s Arch Installer"
LOG="$(mktemp /tmp/t14s-install.XXXXXX.log)"
LOGGING=0

# Screen geometry, clamped so tiny/huge terminals stay usable.
ROWS=$(tput lines 2>/dev/null) || ROWS=24
COLS=$(tput cols 2>/dev/null) || COLS=80
[[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24
[[ $COLS =~ ^[0-9]+$ ]] || COLS=80
H=$(( ROWS > 28 ? 22 : ROWS - 6 )); (( H < 12 )) && H=12
W=$(( COLS > 92 ? 84 : COLS - 8 )); (( W < 56 )) && W=56
LH=$(( H - 8 )); (( LH < 4 )) && LH=4

# dialog/whiptail draw on stdout and return the result on stderr. fd3 carries
# the caller's stdout (the capture channel), so UI is pinned to /dev/tty and keys
# come from /dev/tty even when the script itself arrives on a pipe.
tui() { "$UI" --title "$APP_TITLE" "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty; }

die() { # message [exit-code]
  local msg=${1:-failed} rc=${2:-1}
  trap - ERR
  printf '%sERR%s %s\n' "$cR" "$c0" "$msg" >&2
  if (( LOGGING )) && [[ $UI != plain ]]; then
    { printf 'FAILED: %s\n\n--- last output ---\n' "$msg"
      tail -n "$H" "$LOG" 2>/dev/null; } > "$LOG.fail"
    tui --textbox "$LOG.fail" "$H" "$W" || true
  fi
  printf 'full log: %s\n' "$LOG" >&2
  exit "$rc"
}
trap 'die "failed at line $LINENO" $?' ERR

# ── tty prompt primitives (plain fallback) ──────────────────
ask()       { local p="$1" d="${2:-}" v; read -r  -p "$p" v </dev/tty || true; printf '%s' "${v:-$d}"; }
ask_secret(){ local p="$1" v; read -rs -p "$p" v </dev/tty || true; printf '\n' >&2; printf '%s' "$v"; }
plain_pause(){ read -rsn1 -p ' [enter] ' </dev/tty || true; printf '\n' >&2; }

# ── semantic UI: every screen uses these ────────────────────
ui_msgbox() { # text
  if [[ $UI == plain ]]; then printf '\n%s\n' "$1" >&2; plain_pause; return 0; fi
  tui --msgbox "$1" "$H" "$W"
}

ui_yesno() { # text [default]  (default = yes|no; destructive callers pass no)
  local text=$1 def=${2:-yes}
  if [[ $UI == plain ]]; then
    local suf=' [Y/n]: ' v
    [[ $def == no ]] && suf=' [y/N]: '
    read -r -p "$text$suf" v </dev/tty || true
    v=${v:-$def}
    [[ ${v,,} == y* ]]
    return
  fi
  local extra=(); [[ $def == no ]] && extra=(--defaultno)
  tui "${extra[@]}" --yesno "$text" "$H" "$W"
}

ui_input() { # prompt [default]
  if [[ $UI == plain ]]; then ask "$1: " "${2:-}"; return; fi
  tui --inputbox "$1" "$H" "$W" "${2:-}"
}

ui_password() { # prompt
  if [[ $UI == plain ]]; then ask_secret "$1: "; return; fi
  tui --passwordbox "$1" "$H" "$W"
}

# ui_menu prompt tag description [tag description ...]  -> tag on stdout
ui_menu() {
  local prompt=$1; shift
  if [[ $UI != plain ]]; then tui --menu "$prompt" "$H" "$W" "$LH" "$@"; return; fi
  local tags=() descs=() t d i=0
  printf '\n%s\n' "$prompt" >&2
  while (( $# >= 2 )); do
    t=$1 d=$2; shift 2; tags+=("$t") descs+=("$d"); i=$((i + 1))
    printf '  %d) %s [%s]\n' "$i" "$d" "$t" >&2
  done
  local pick
  read -r -p "choose 1-$i: " pick </dev/tty || true
  [[ -z $pick ]] && pick=1
  if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )); then
    printf '%s' "${tags[pick - 1]}"
  else
    printf '%s' "$pick"
  fi
}

# ui_radio prompt tag description on|off [tag description on|off ...] -> tag
ui_radio() {
  local prompt=$1; shift
  if [[ $UI != plain ]]; then tui --radiolist "$prompt" "$H" "$W" "$LH" "$@"; return; fi
  local tags=() descs=() def='' t d s i=0
  printf '\n%s\n' "$prompt" >&2
  while (( $# >= 3 )); do
    t=$1 d=$2 s=$3; shift 3; tags+=("$t") descs+=("$d"); i=$((i + 1))
    [[ $s == on ]] && def=$t
    printf '  %d) %s [%s]\n' "$i" "$d" "$t" >&2
  done
  local pick
  read -r -p "choose 1-$i (default $def): " pick </dev/tty || true
  if [[ -z $pick ]]; then printf '%s' "$def"; return 0; fi
  if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )); then
    printf '%s' "${tags[pick - 1]}"
  else
    printf '%s' "$def"
  fi
}

ui_infobox() { [[ $UI == plain ]] && return 0; tui --infobox "$1" "$H" "$W"; }
step() { say "$*"; ui_infobox "$*"; }

# ── logging around the destructive phase ────────────────────
start_log() { LOGGING=1; exec 8>&1 9>&2; exec >>"$LOG" 2>&1; }
stop_log()  { exec >&8 2>&9; LOGGING=0; }

bootstrap_ui() {
  if [[ -n ${T14S_UI:-} ]]; then          # explicit override
    UI=$T14S_UI
    if [[ $UI != plain ]] && ! command -v "$UI" >/dev/null 2>&1; then
      (( DRYRUN )) || pacman -Sy --needed --noconfirm "$UI" >/dev/null 2>&1 || true
      command -v "$UI" >/dev/null 2>&1 || UI=plain
    fi
    return 0
  fi
  [[ -n ${TERM:-} && -r /dev/tty ]] || return 0
  if command -v whiptail >/dev/null 2>&1; then UI=whiptail
  elif command -v dialog >/dev/null 2>&1; then UI=dialog
  elif (( DRYRUN )); then :
  elif command -v pacman >/dev/null 2>&1 \
    && pacman -Sy --needed --noconfirm dialog >/dev/null 2>&1 \
    && command -v dialog >/dev/null 2>&1; then UI=dialog
  fi
  [[ $UI == plain ]] && warn "no TUI backend (whiptail/dialog) — plain prompts"
  return 0
}

part_of() { # $1 disk, $2 num -> partition path (nvme/mmc need 'p')
  local d="$1" n="$2"
  [[ $d == *nvme* || $d == *mmcblk* || $d == *loop* ]] && printf '%sp%s' "$d" "$n" || printf '%s%s' "$d" "$n"
}

disk_type() { lsblk -dno TYPE "$1" 2>/dev/null; }
size_mb()   { local b; b="$(lsblk -bdnro SIZE "$1" 2>/dev/null)"; printf '%s' "$(( ${b:-0} / 1048576 ))"; }
part_fs()   { lsblk -no FSTYPE "$1" 2>/dev/null | head -1; }

# build_part_menu ARRAY DISK [filter] [exclude]
#   filter = any | vfat; fills ARRAY with tag/description pairs for ui_menu.
build_part_menu() {
  local -n _out=$1
  local _disk=$2 _filter=${3:-any} _excl=${4:-} typ p sz fs tt
  _out=()
  while read -r typ p sz fs tt; do
    [[ $typ == part ]] || continue
    [[ -n $_excl && $p == "$_excl" ]] && continue
    [[ $_filter == vfat && $fs != vfat ]] && continue
    _out+=("$p" "${sz}  ${fs:-empty}  ${tt:-}")
  done < <(lsblk -prno TYPE,PATH,SIZE,FSTYPE,PARTTYPENAME "$_disk" 2>/dev/null)
  _out+=(manual "type a partition path")
}

# pick_part PROMPT DISK [filter] [exclude] -> partition path on stdout
pick_part() {
  local prompt=$1 disk=$2 filter=${3:-any} excl=${4:-}
  local arr=() ans
  while :; do
    build_part_menu arr "$disk" "$filter" "$excl"
    ans="$(ui_menu "$prompt" "${arr[@]}")" || return 1
    if [[ $ans == manual ]]; then
      ans="$(ui_input "Partition path (e.g. /dev/nvme0n1p2)" "")" || return 1
    fi
    if [[ -z $ans ]]; then continue; fi
    if [[ ! -b $ans ]]; then ui_msgbox "Not a block device: $ans"; continue; fi
    if [[ $(disk_type "$ans") != part ]]; then
      ui_msgbox "$ans is a whole disk, not a partition."; continue
    fi
    printf '%s' "$ans"; return 0
  done
}

# ── 0. preflight ────────────────────────────────────────────
if (( ! DRYRUN )); then
  [[ $EUID -eq 0 ]] || die "run as root (from the Arch ISO)"
  [[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode — enable UEFI and reboot the ISO"
  { ping -c1 -W3 archlinux.org || curl -fsS --max-time 6 https://archlinux.org; } >/dev/null 2>&1 \
    || die "no internet — connect first (iwctl / dhcp), then re-run"
  timedatectl set-ntp true || true
fi
bootstrap_ui
say "preflight ok (UEFI + network + ntp)"

# clean leftover state from a previous interrupted run so re-runs start fresh
# (otherwise an open cryptroot / mounted /mnt keeps the disk busy → sgdisk/mkfs
#  can't reformat → stale files survive → pacstrap 'conflicting files').
# Never touch mounts/swap during T14S_DRYRUN (safe on a normal host).
if (( ! DRYRUN )); then
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
fi

ui_msgbox "T14s Gen 3 AMD ARCH INSTALLER — DESTROYS DATA ON DISK

Machine: ThinkPad T14s Gen 3 AMD (Type 21CQ/21CR) — Rembrandt + amdgpu
Stack:   LUKS2 + Btrfs(+@tmp) + linux-lts/hardened + UKI + systemd-boot
         + minimal GNOME + zram + AppArmor + UFW + Snapper + Secure Boot

All answers are read from /dev/tty. Nothing changes until the final confirm."

# Soft DMI check — Gen 3 AMD types only (21CQ/21CR). Anchored to avoid substring noise.
_dmi="$(cat /sys/class/dmi/id/product_family /sys/class/dmi/id/product_version \
          /sys/class/dmi/id/product_name /sys/class/dmi/id/product_sku 2>/dev/null \
        | tr '\n' ' ')"
if ! echo "$_dmi" | grep -qiE '(^|[[:space:]_/])21C[QR]([[:alnum:]_-]|$)'; then
  ui_yesno "DMI is NOT T14s Gen 3 AMD type 21CQ/21CR:
${_dmi:-unknown}

Continue only if intentional (VM rehearsal / forced). Wrong machine? Abort." no \
    || die "aborted — this installer is for type 21CQ/21CR only"
fi
if ! grep -q AuthenticAMD /proc/cpuinfo; then
  ui_yesno "CPU is not AuthenticAMD.
This installer sets amd-ucode + amd_iommu/amd_pstate.

Continue without an AMD CPU (VM rehearsal)?" no \
    || die "aborted — need AuthenticAMD or explicit YES"
fi
ok "target profile: T14s Gen 3 AMD (21CQ/21CR)"

# ── 1. choose disk ──────────────────────────────────────────
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
    DISK="$(ui_input "Target disk (e.g. /dev/nvme0n1)" "")" || die "no disk selected"
  fi
  [[ -b $DISK ]] || { ui_msgbox "Not a block device: ${DISK:-<empty>}"; continue; }
  [[ $(disk_type "$DISK") == disk ]] || { ui_msgbox "$DISK is not a whole disk."; continue; }
  break
done

# ── 2. partition strategy ───────────────────────────────────
MODE="$(ui_radio "How should $DISK be partitioned?" \
  auto "wipe ALL of $DISK: EFI + LUKS root" on \
  manual "select existing partitions (EFI format or reuse)" off)" || die "aborted"

FORMAT_EFI=1
if [[ $MODE == auto ]]; then
  while :; do
    ESP_MB="$(ui_radio "EFI system partition size on $DISK" \
      2048 "2G — recommended for dual UKIs" on \
      1024 "1G — minimum comfortable" off \
      4096 "4G — extra multiboot headroom" off)" || die "aborted"
    disk_mb="$(size_mb "$DISK")"
    (( disk_mb > ESP_MB + 8192 )) && break
    ui_msgbox "Disk is only ${disk_mb}MB — ${ESP_MB}MB ESP plus an 8GB root will not fit.
Pick a smaller ESP."
  done

  ui_msgbox "AUTO mode ERASES the ENTIRE disk:

$DISK

Plan: GPT · ${ESP_MB}MB ESP (FAT32) · remainder LUKS2 + Btrfs

That includes any Windows / other-OS partitions on it.

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null)"
  CONF="$(ui_input "Type the disk path to confirm total wipe" "")" || die "aborted"
  [[ $CONF == "$DISK" ]] || die "disk confirmation mismatch — aborting"
  ui_yesno "ERASE $DISK now?" no || die "aborted"
  # names only; the destructive writes run in the execute phase
  EFI_PART="$(part_of "$DISK" 1)"
  ROOT_PART="$(part_of "$DISK" 2)"
else
  ui_msgbox "Manual partitioning on $DISK.

Current layout (select from lists; sizes and existing filesystems shown):

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null)"

  ROOT_PART="$(pick_part "Select ROOT — ERASED, becomes LUKS2 + Btrfs" "$DISK")" \
    || die "aborted"
  while :; do
    EFIMODE="$(ui_radio "EFI handling for $ROOT_PART" \
      reuse "keep an existing FAT32 ESP (multiboot-safe)" on \
      format "format a partition as ESP (destroys its contents)" off)" || die "aborted"
    if [[ $EFIMODE == reuse ]]; then FORMAT_EFI=0; else FORMAT_EFI=1; fi

    if (( FORMAT_EFI == 0 )) && ! lsblk -prno FSTYPE "$DISK" 2>/dev/null | grep -qx vfat; then
      ui_msgbox "No FAT32 ESP exists on $DISK. Pick format mode instead (or cancel to abort)."
      continue
    fi

    if (( FORMAT_EFI == 0 )); then
      EFI_PART="$(pick_part "Select the existing ESP (must be FAT32)" "$DISK" any "$ROOT_PART")" \
        || die "aborted"
    else
      EFI_PART="$(pick_part "Select the partition to FORMAT as ESP" "$DISK" any "$ROOT_PART")" \
        || die "aborted"
    fi
    [[ $EFI_PART != "$ROOT_PART" ]] || { ui_msgbox "EFI and ROOT cannot be the same partition."; continue; }

    efifs="$(part_fs "$EFI_PART")"
    if (( FORMAT_EFI == 0 )) && [[ $efifs != vfat ]]; then
      ui_msgbox "$EFI_PART is '${efifs:-empty}', not FAT32 — reuse needs an existing ESP.
Pick format mode or another partition."
      continue
    fi
    efi_mb="$(size_mb "$EFI_PART")"
    if (( efi_mb < 512 )); then
      ui_yesno "ESP $EFI_PART is only ${efi_mb}MB. Dual UKIs will not fit.
Use it anyway?" no || continue
    elif (( efi_mb < 1024 )); then
      ui_msgbox "Note: ESP is ${efi_mb}MB — 1G+ is recommended for dual UKIs."
    fi
    break
  done

  root_mb="$(size_mb "$ROOT_PART")"
  if (( root_mb < 8192 )); then
    ui_yesno "ROOT $ROOT_PART is only ${root_mb}MB — 8G+ is recommended.
Use it anyway?" no || die "aborted"
  fi

  if (( FORMAT_EFI == 0 )); then
    _m="$(mktemp -d)"
    _esp_entries=""
    if mount -o ro "$EFI_PART" "$_m" 2>/dev/null; then
      _esp_entries="$(find "$_m/EFI" -maxdepth 1 -mindepth 1 2>/dev/null | sed 's,.*/,   ,' || true)"
      umount "$_m" || true
    fi
    rmdir "$_m" 2>/dev/null || true
    ui_msgbox "Reusing ESP $EFI_PART (FAT, kept).

Existing /EFI entries (other OSes stay bootable):
${_esp_entries:-   (none)}"
  elif [[ $efifs == vfat ]]; then
    ui_msgbox "DANGER: $EFI_PART is ALREADY FAT — likely a shared ESP.
Formatting ERASES other OSes' bootloaders."
  fi

  ui_yesno "Proceed with these partitions?

  ROOT  $ROOT_PART  $(size_mb "$ROOT_PART")MB  ERASED → LUKS2
  EFI   $EFI_PART  ${efi_mb}MB  $([[ $FORMAT_EFI == 1 ]] && echo FORMATTED || echo REUSED)" no \
    || die "aborted"
fi
ok "EFI=$EFI_PART  ROOT=$ROOT_PART  (format_efi=$FORMAT_EFI)"

# ── 3. luks passphrase ──────────────────────────────────────
while :; do
  LUKS_PASS="$(ui_password 'LUKS passphrase')" || die "aborted"
  LUKS_PASS2="$(ui_password 'Repeat LUKS passphrase')" || die "aborted"
  [[ -n $LUKS_PASS && $LUKS_PASS == "$LUKS_PASS2" ]] && break
  ui_msgbox "Empty or mismatched LUKS passphrase — retry."
done

# ── 4. identity ─────────────────────────────────────────────
HOSTNAME="$(ui_input "Hostname" thinkpad-t14s)" || die "aborted"
[[ -n $HOSTNAME ]] || die "hostname cannot be empty"
TIMEZONE="$(ui_input "Timezone (Region/City)" America/New_York)" || die "aborted"
LOCALE="$(ui_input "Locale" en_US.UTF-8)" || die "aborted"
KEYMAP="$(ui_input "Console keymap" us)" || die "aborted"
while :; do
  USERNAME="$(ui_input "Username (lowercase POSIX)" "")" || die "aborted"
  if [[ -z $USERNAME ]]; then
    ui_msgbox "username cannot be empty"
  elif [[ $USERNAME == root ]]; then
    ui_msgbox "username cannot be 'root'"
  elif ! [[ $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    ui_msgbox "username must match ^[a-z_][a-z0-9_-]*$ (lowercase POSIX)"
  else
    break
  fi
done
while :; do
  USER_PASS="$(ui_password "Password for $USERNAME")" || die "aborted"
  USER_PASS2="$(ui_password "Repeat password for $USERNAME")" || die "aborted"
  [[ -n $USER_PASS && $USER_PASS == "$USER_PASS2" ]] && break
  ui_msgbox "Empty or mismatched password — retry."
done
while :; do
  ROOT_PASS="$(ui_password 'Root password')" || die "aborted"
  ROOT_PASS2="$(ui_password 'Repeat root password')" || die "aborted"
  [[ -n $ROOT_PASS && $ROOT_PASS == "$ROOT_PASS2" ]] && break
  ui_msgbox "Empty or mismatched password — retry."
done
unset -v LUKS_PASS2 USER_PASS2 ROOT_PASS2

ui_yesno "Install the minimal GNOME desktop, browsers, VPN and software center?" yes \
  && DESKTOP=Y || DESKTOP=N
ui_yesno "Enroll Secure Boot keys now if the firmware is in Setup Mode?" no \
  && ENROLL_SB=Y || ENROLL_SB=N

# ── final summary ───────────────────────────────────────────
ui_msgbox "REVIEW — nothing has been written yet.

  Disk          $DISK $(size_mb "$DISK")MB ($([[ $MODE == auto ]] && echo "AUTO wipe, ${ESP_MB}MB ESP" || echo manual))
  EFI           $EFI_PART $(size_mb "$EFI_PART")MB ($([[ $FORMAT_EFI == 1 ]] && echo format || echo reuse))
  ROOT          $ROOT_PART $(size_mb "$ROOT_PART")MB (LUKS2, will be erased)
  Hostname      $HOSTNAME
  Timezone      $TIMEZONE
  Locale        $LOCALE
  Keymap        $KEYMAP
  User          $USERNAME
  Desktop       $([[ $DESKTOP == Y ]] && echo 'minimal GNOME' || echo none)
  Secure Boot   $([[ $ENROLL_SB == Y ]] && echo 'enroll keys now' || echo 'enroll later')

Typed passwords are not redisplayed."

ui_yesno "Start the installation? The partitions above will be ERASED." no \
  || die "aborted by user"

if (( DRYRUN )); then
  printf 'DRYRUN: EFI=%s ROOT=%s format_efi=%s esp_mb=%s host=%s user=%s desktop=%s sb=%s\n' \
    "$EFI_PART" "$ROOT_PART" "$FORMAT_EFI" "${ESP_MB:-}" "$HOSTNAME" "$USERNAME" "$DESKTOP" "$ENROLL_SB"
  exit 0
fi

start_log

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

step "btrfs + subvolumes"
mkfs.btrfs -f -L archroot /dev/mapper/cryptroot >/dev/null
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @snapshots @var_log @var_cache @tmp; do btrfs subvolume create "/mnt/$sv" >/dev/null; done
chattr +C /mnt/@tmp 2>/dev/null || true   # nodatacow inheritance
umount /mnt

CO="noatime,compress=zstd:3,ssd,space_cache=v2"
mount -o "$CO,subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/log,var/cache,tmp,boot}
mount -o "$CO,subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "$CO,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "$CO,subvol=@var_log"   /dev/mapper/cryptroot /mnt/var/log
mount -o "$CO,subvol=@var_cache" /dev/mapper/cryptroot /mnt/var/cache
mount -o "noatime,nodatacow,nosuid,nodev,subvol=@tmp" /dev/mapper/cryptroot /mnt/tmp
chmod 1777 /mnt/tmp

if [[ $FORMAT_EFI == 1 ]]; then
  step "format ESP $EFI_PART"
  wipefs -a "$EFI_PART" >/dev/null 2>&1 || true   # clear stale fs signatures that confuse blkid/mount
  mkfs.fat -F32 -n EFI "$EFI_PART"                 # show output — surface real errors
  sync
fi
udevadm settle 2>/dev/null || true
mount -t vfat "$EFI_PART" /mnt/boot                # explicit type: don't rely on auto-detect
esp_mb=$(df -Pm /mnt/boot | awk 'NR==2{print $2}'); esp_mb=${esp_mb:-0}
(( esp_mb >= 1024 )) || warn "ESP is ${esp_mb}MB — dual-kernel UKIs want >=1024MB; install may fill it"
# defensive: drop leftover Arch boot files from a prior install so pacstrap won't hit
# 'conflicting files'. Clears both ucode names for multiboot ESP hygiene (this
# installer only pacstraps amd-ucode; intel-ucode.img removal is intentional).
step "cleaning prior Arch boot artifacts on ESP"
rm -f /mnt/boot/intel-ucode.img /mnt/boot/amd-ucode.img \
      /mnt/boot/vmlinuz-linux* /mnt/boot/initramfs-linux* \
      /mnt/boot/EFI/Linux/arch-linux*.efi 2>/dev/null || true
if [[ -d /mnt/boot/loader/entries ]]; then
  find /mnt/boot/loader/entries -maxdepth 1 -type f \
    \( -name 'arch*.conf' -o -name 'linux-*.conf' \) -delete 2>/dev/null || true
fi
ok "filesystems mounted (ESP ${esp_mb}MB)"

# ── 6. base install ─────────────────────────────────────────
# Rembrandt target — always amd-ucode (non-AMD already confirmed at preflight).
UCODE=amd-ucode

# Reflector rates every candidate mirror by downloading its repo DB. Without
# --threads that loop is serial, so a handful of dead mirrors stall the install
# for minutes behind a blank screen. Bound it: few candidates, concurrent rating,
# short timeouts, hard overall deadline. Write to a temp file first so a killed or
# empty run never clobbers a usable mirrorlist.
step "refreshing live mirrors (best-effort, time-bounded)"
ML_TMP="$(mktemp)"
if timeout 45 reflector --latest 10 --protocol https --sort rate \
     --threads 5 --connection-timeout 3 --download-timeout 5 \
     --save "$ML_TMP" 2>/dev/null \
   && (( $(grep -c '^Server' "$ML_TMP") >= 3 )); then
  cat "$ML_TMP" > /etc/pacman.d/mirrorlist   # keep existing inode/perms (0644)
  ok "mirrorlist refreshed ($(grep -c '^Server' "$ML_TMP") mirrors)"
else
  warn "reflector skipped, timed out, or returned too few mirrors — keeping current mirrorlist"
fi
rm -f "$ML_TMP"

# Robust downloads: route pacman through curl with retries + resume and NO
# low-speed abort, so a slow mirror stalls but doesn't kill the transaction
# (the default libcurl path aborts with "Operation too slow"). Failover across
# the reflector mirrorlist still applies. Single pacstrap — no retry loop, which
# would re-run on a partially-populated root and hit 'conflicting files'.
if ! grep -q '^XferCommand' /etc/pacman.conf; then
  sed -i '/^\[options\]/a XferCommand = /usr/bin/curl -fL -C - -o %o %u --retry 5 --retry-connrefused --connect-timeout 15' /etc/pacman.conf
fi

BASE_PKGS=(
  base base-devel
  linux-lts linux-lts-headers linux-hardened linux-hardened-headers
  linux-firmware "$UCODE"
  btrfs-progs cryptsetup
  bluez bluez-utils
  networkmanager sudo zsh git vim nano
  reflector pacman-contrib
  mkinitcpio snapper snap-pac zram-generator
  apparmor ufw sbctl efibootmgr
)
step "pacstrap base system ($UCODE)"
pacstrap -K /mnt "${BASE_PKGS[@]}"

step "genfstab"
genfstab -U /mnt >> /mnt/etc/fstab
# add nofail to the /tmp line (failure must not block boot)
sed -i -E '/[[:space:]]\/tmp[[:space:]]+btrfs/ s/(subvol=\/?@tmp)/\1,nofail/' /mnt/etc/fstab || true
ok "base installed"

# ── 7. chroot configuration ─────────────────────────────────
step "writing chroot config"
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
say(){ printf '\e[1;34m>>\e[0m %s\n' "$*"; }

# time / locale / keymap
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE} \)/\1/" /etc/locale.gen
grep -q "^${LOCALE} " /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname / hosts
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# users — secrets from /root/.t14s-install-secrets (0600; shredded after chroot)
# shellcheck disable=SC1091
source /root/.t14s-install-secrets
echo "root:${ROOT_PASS}" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
unset -v USER_PASS ROOT_PASS
rm -f /root/.t14s-install-secrets

# initramfs (systemd + sd-encrypt for LUKS)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# kernel cmdline (shared by both UKIs)
mkdir -p /etc/kernel
# AMD Rembrandt: amd_iommu + amd_pstate (no intel_iommu / i915). BIOS Sleep =
# "Windows and Linux" pairs with mem_sleep_default=s2idle.
echo "rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3 mem_sleep_default=s2idle apparmor=1 security=apparmor amd_iommu=on amd_pstate=active" > /etc/kernel/cmdline

# Charge window 70–80. tmpfiles can race before thinkpad_acpi exposes BAT*;
# oneshot After=multi-user.target waits/retries. No-op on VM without BAT.
mkdir -p /etc/tmpfiles.d /usr/local/lib/t14s
cat > /etc/tmpfiles.d/thinkpad-charge-thresholds.conf <<'EOF'
# ThinkPad charge thresholds 70–80 (PPD host; no TLP).
# Best-effort at boot; see thinkpad-charge-thresholds.service if BAT* appears late.
w /sys/class/power_supply/BAT0/charge_control_start_threshold - - - - 70
w /sys/class/power_supply/BAT0/charge_control_end_threshold - - - - 80
EOF
cat > /usr/local/lib/t14s/apply-charge-thresholds.sh <<'EOF'
#!/usr/bin/env bash
# Wait for thinkpad_acpi BAT* charge_control_*, then apply 70–80. Exit 0 if absent (VM).
set -euo pipefail
START=70 END=80
for _ in $(seq 1 60); do
  shopt -s nullglob
  found=(/sys/class/power_supply/BAT*/charge_control_end_threshold)
  shopt -u nullglob
  ((${#found[@]} > 0)) && break
  sleep 1
done
shopt -s nullglob
for bat in /sys/class/power_supply/BAT*; do
  [[ -d $bat ]] || continue
  if [[ -e $bat/charge_control_start_threshold ]]; then
    printf '%s\n' "$START" >"$bat/charge_control_start_threshold" || true
  fi
  if [[ -e $bat/charge_control_end_threshold ]]; then
    printf '%s\n' "$END" >"$bat/charge_control_end_threshold" || true
  fi
done
shopt -u nullglob
exit 0
EOF
chmod 755 /usr/local/lib/t14s/apply-charge-thresholds.sh
cat > /etc/systemd/system/thinkpad-charge-thresholds.service <<'EOF'
[Unit]
Description=ThinkPad battery charge thresholds (70-80)
Documentation=file:///usr/local/lib/t14s/apply-charge-thresholds.sh
After=multi-user.target
# Do not use ConditionPathExists*: BAT* may appear after early boot.

[Service]
Type=oneshot
ExecStart=/usr/local/lib/t14s/apply-charge-thresholds.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable thinkpad-charge-thresholds.service

# UKI presets: linux-lts (primary) + linux-hardened (fallback)
# reuse ESP: clear stale UKIs + loader entries before rebuild (multiboot-safe names)
if [[ ${FORMAT_EFI:-1} == 0 ]]; then
  say "reuse ESP — removing old Arch UKIs and loader entries"
  rm -f /boot/EFI/Linux/arch-linux*.efi 2>/dev/null || true
  if [[ -d /boot/loader/entries ]]; then
    find /boot/loader/entries -maxdepth 1 -type f \
      \( -name 'arch*.conf' -o -name 'linux-*.conf' \) -delete 2>/dev/null || true
  fi
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
say "building UKIs"
mkinitcpio -P
# drop redundant non-UKI initramfs left by the pacstrap install hook — UKI-only
# presets won't regenerate them, so this frees ESP space permanently.
rm -f /boot/initramfs-linux-lts.img /boot/initramfs-linux-lts-fallback.img \
      /boot/initramfs-linux-hardened.img /boot/initramfs-linux-hardened-fallback.img

# bootloader — when reusing a shared/multiboot ESP, back up another OS's fallback
# loader first. On a freshly-formatted ESP there's nothing to preserve (no clutter).
say "systemd-boot"
if [[ ${FORMAT_EFI:-1} == 0 && -f /boot/EFI/BOOT/BOOTX64.EFI ]]; then
  cp -n /boot/EFI/BOOT/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI.pre-arch.bak 2>/dev/null || true
  say "backed up existing /EFI/BOOT/BOOTX64.EFI -> .pre-arch.bak"
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

# zram (RAM/2 cap 16G — T14s often ships 16–32G soldered LPDDR5)
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 16384)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# sysctl hardening
cat > /etc/sysctl.d/99-security.conf <<EOF
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
net.core.bpf_jit_harden = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
vm.swappiness = 100
EOF
# userns: needed for Flatpak under linux-hardened; '-' = ignore on LTS (key absent)
echo '-kernel.unprivileged_userns_clone = 1' > /etc/sysctl.d/99-userns.conf

# firewall — set ENABLED=yes so it's active on first boot (rule-apply may warn in chroot)
ufw default deny incoming
ufw default allow outgoing
ufw --force enable >/dev/null 2>&1 || true
grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null || sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf 2>/dev/null || true

# reflector mirrors (weekly timer; rate-rating must not serialize on dead mirrors)
cat > /etc/xdg/reflector/reflector.conf <<EOF
--latest 10
--protocol https
--sort rate
--threads 5
--connection-timeout 3
--download-timeout 5
--save /etc/pacman.d/mirrorlist
EOF

# pacman niceties
sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf

# services
systemctl enable NetworkManager apparmor ufw bluetooth fstrim.timer reflector.timer \
                 systemd-tmpfiles-clean.timer

# snapper config for / (handle pre-existing @snapshots mount) — non-fatal
umount /.snapshots 2>/dev/null || true
rmdir  /.snapshots 2>/dev/null || true
if snapper --no-dbus -c root create-config /; then
  btrfs subvolume delete /.snapshots 2>/dev/null || true
  mkdir -p /.snapshots; mount -a || true; chmod 750 /.snapshots
  systemctl enable snapper-timeline.timer snapper-cleanup.timer
else
  say "WARN: snapper create-config failed — skipping snapshots (configure post-boot)"
  mkdir -p /.snapshots; mount -a || true
fi

# minimal GNOME (optional)
if [[ ${DESKTOP^^} != N* ]]; then
  say "installing minimal GNOME + browsers + VPN + software center"
  # sof-firmware+alsa-ucm-conf: Rembrandt audio.
  # mesa+vulkan-radeon+fprintd: Radeon 680M (libva via mesa Provides). No Yoga / iio.
  # FP (D-Bus-activated — do NOT systemctl enable).
  # browsers + proton-vpn: Flatpak. gnome-software: Flatpak software center.
  # Non-fatal: a network hiccup here must not abort an otherwise-bootable base system.
  if pacman -S --noconfirm --needed --disable-download-timeout \
    gnome-shell gnome-session gdm gnome-control-center gnome-keyring \
    gnome-backgrounds nautilus gnome-console gnome-text-editor \
    gnome-system-monitor gnome-calculator loupe evince gnome-disk-utility \
    xdg-user-dirs-gtk xdg-desktop-portal xdg-desktop-portal-gnome polkit \
    flatpak fwupd bolt pipewire pipewire-pulse wireplumber earlyoom \
    power-profiles-daemon \
    sof-firmware alsa-ucm-conf fprintd \
    mesa vulkan-radeon \
    gnome-software
  then
    systemctl enable gdm bolt.service earlyoom.service power-profiles-daemon
    mkdir -p /etc/gdm
    printf '[daemon]\nWaylandEnable=true\n' > /etc/gdm/custom.conf
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    # Skip extra-data apps (Chrome) in chroot — bwrap userns refused; install post-boot:
    #   flatpak install --system -y flathub com.google.Chrome
    failed_fp=()
    for app in com.brave.Browser app.zen_browser.zen \
               io.gitlab.librewolf-community com.protonvpn.www; do
      if ! flatpak install --system -y --noninteractive flathub "$app"; then
        failed_fp+=("$app")
        flatpak uninstall --system -y --noninteractive "$app" >/dev/null 2>&1 || true
        flatpak info --system "$app" >/dev/null 2>&1 || rm -rf "/var/lib/flatpak/app/$app"
      fi
    done
    if (( ${#failed_fp[@]} )); then
      say "WARN: flatpak install failed: ${failed_fp[*]}"
      say "      retry after first boot: flatpak install --system -y flathub <app>"
    fi
  else
    say "WARN: GNOME install incomplete (network?) — base system is fine. Finish post-boot:"
    say "      pacman -S gnome-shell gdm && systemctl enable gdm"
  fi
fi

# Secure Boot: create + sign now; enroll post-reboot (needs firmware Setup Mode)
say "sbctl: create keys + sign"
sbctl create-keys
for f in /boot/EFI/Linux/arch-linux-lts.efi /boot/EFI/Linux/arch-linux-lts-fallback.efi \
         /boot/EFI/Linux/arch-linux-hardened.efi /boot/EFI/Linux/arch-linux-hardened-fallback.efi \
         /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI; do
  [[ -f $f ]] && sbctl sign -s "$f" || true
done
if [[ ${ENROLL_SB^^} == Y* ]] && sbctl status 2>/dev/null | grep -qi 'setup mode.*enabled'; then
  say "enrolling Secure Boot keys (-m)"; sbctl enroll-keys -m || echo "enroll failed — do it post-reboot"
fi
sbctl verify || true
CHROOT

# Passwords via 0600 file (not arch-chroot env — visible in /proc/*/environ).
umask 077
{
  printf 'USERNAME=%q\n' "$USERNAME"
  printf 'USER_PASS=%q\n' "$USER_PASS"
  printf 'ROOT_PASS=%q\n' "$ROOT_PASS"
} > /mnt/root/.t14s-install-secrets
chmod 600 /mnt/root/.t14s-install-secrets
unset -v USER_PASS ROOT_PASS

chmod +x /mnt/root/chroot-setup.sh
cleanup_chroot_secrets() {
  shred -u /mnt/root/chroot-setup.sh /mnt/root/.t14s-install-secrets 2>/dev/null \
    || rm -f /mnt/root/chroot-setup.sh /mnt/root/.t14s-install-secrets
}
# Always drop secrets file even if chroot fails (set -e would otherwise skip shred).
step "running chroot config"
if ! arch-chroot /mnt env \
  TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" KEYMAP="$KEYMAP" HOSTNAME="$HOSTNAME" \
  USERNAME="$USERNAME" \
  LUKS_UUID="$LUKS_UUID" DESKTOP="$DESKTOP" ENROLL_SB="$ENROLL_SB" FORMAT_EFI="$FORMAT_EFI" \
  bash /root/chroot-setup.sh
then
  cleanup_chroot_secrets
  die "chroot setup failed"
fi
cleanup_chroot_secrets
ok "chroot config complete"

# ── 8. finish ───────────────────────────────────────────────
if [[ ${DESKTOP^^} != N* ]]; then
  LOGIN_HINT="First login via GDM (Wayland)."
  FLATPAK_HINT="Optional post-boot: flatpak install --system -y flathub com.google.Chrome"
else
  LOGIN_HINT="Desktop skipped — log in on a virtual console (getty) as ${USERNAME}."
  FLATPAK_HINT="Optional later: pacman -S gnome-shell gdm flatpak && systemctl enable gdm"
fi

POST_TXT="T14s install — next steps

  Reboot and remove the ISO:   reboot
  Boot menu: Arch Linux (LTS) default, Hardened as fallback.
  Verify after boot: lscpu | grep -i ryzen
                     cat /sys/power/mem_sleep   (expect s2idle bracketed)
  Secure Boot (to enable):
    1) BIOS -> clear Secure Boot keys -> Setup Mode
    2) booted OS: sudo sbctl enroll-keys -m
    3) BIOS -> Secure Boot -> Enabled   (pacman hook auto-resigns on updates)
    multiboot: '-m' keeps Microsoft keys so Windows still boots; other
    unsigned Linux loaders won't boot under SB until you 'sbctl sign' them.
  linux-hardened + Flatpak: userns sysctl already set (99-userns.conf).
  Hostname: ${HOSTNAME}
  ${LOGIN_HINT}
  Post-boot check: grep -E 'amd_iommu|amd_pstate' /proc/cmdline
  Charge thresholds (ThinkPad BAT* only; skip/absent on VM):
    cat /sys/class/power_supply/BAT0/charge_control_*_threshold
    (expect 70 / 80; oneshot thinkpad-charge-thresholds.service + tmpfiles)
  ${FLATPAK_HINT}"

printf '%s\n' "$POST_TXT" > /mnt/root/t14s-post-install.txt

step "unmounting"
umount -R /mnt
cryptsetup close cryptroot
stop_log

ui_msgbox "INSTALL COMPLETE — reboot and remove the ISO.

$(printf '%s' "$POST_TXT")"
ok "done — reboot when ready"
