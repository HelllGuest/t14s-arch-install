#!/usr/bin/env bash
# 00-common.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

# ── ui helpers ──────────────────────────────────────────────
c0=$'\e[0m'; cR=$'\e[1;31m'; cG=$'\e[1;32m'; cY=$'\e[1;33m'; cB=$'\e[1;34m'
cC=$'\e[1;36m'
# Mirror status to /dev/tty when stdout is redirected into $LOG (destructive phase).
_tty() { [[ -w /dev/tty ]] && printf '%s\n' "$*" >/dev/tty || true; }

say()  {
  local m; m=$(printf '%s>>%s %s' "$cB" "$c0" "$*")
  printf '%s\n' "$m"
  if (( LOGGING )); then _tty "$m"; fi
  return 0
}
ok()   {
  local m; m=$(printf '%s ok%s %s' "$cG" "$c0" "$*")
  printf '%s\n' "$m"
  if (( LOGGING )); then _tty "$m"; fi
  return 0
}
warn() {
  local m; m=$(printf '%s !!%s %s' "$cY" "$c0" "$*")
  printf '%s\n' "$m" >&2
  if (( LOGGING )); then _tty "$m"; fi
  return 0
}

# True for y / yes / on / 1 only (case-insensitive). Rejects "yellow", "Y*".
yn_on() {
  local v=${1,,}
  [[ $v == y || $v == yes || $v == on || $v == 1 ]]
}
def_onoff() { if yn_on "$1"; then printf on; else printf off; fi; }
# Canonicalize flag to Y or N (keeps chroot gates + answers consistent).
yn_canon() {
  local -n _yc=$1
  if yn_on "${_yc:-}"; then _yc=Y; else _yc=N; fi
}

part_of() { # $1 disk, $2 num -> partition path (nvme/mmc need 'p')
  local d="$1" n="$2"
  [[ $d == *nvme* || $d == *mmcblk* || $d == *loop* ]] && printf '%sp%s' "$d" "$n" || printf '%s%s' "$d" "$n"
}

# Identity validators (before wipe).
# Test fixtures only when T14S_IDENTITY_OVERRIDES=1: LOCALE_FILES, KEYMAP_DIR.
valid_hostname() {
  local h="$1"
  # Single label or dotted FQDN; no leading/trailing hyphen or dot per label.
  [[ $h =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

valid_username() {
  local u="$1"
  [[ $u =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  (( ${#u} <= 32 )) || return 1
  # Reject names already in passwd or group (root/bin/nobody/wheel on the ISO).
  id "$u" &>/dev/null && return 1
  getent group "$u" >/dev/null 2>&1 && return 1
  return 0
}

valid_timezone() {
  local tz="$1" f magic
  [[ $tz != *..* ]] || return 1
  [[ $tz =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  # TZif junk / non-zone files that sit under zoneinfo.
  case $tz in
    Factory|leapseconds|posixrules|localtime|iso3166.tab|zone.tab|zonenow.tab|tzdata.zi) return 1 ;;
  esac
  f="/usr/share/zoneinfo/$tz"
  [[ -f $f ]] || return 1
  magic="$(head -c4 "$f" 2>/dev/null || true)"
  [[ $magic == TZif ]]
}

valid_locale() {
  local loc="$1" f line name
  local -a files=()
  [[ -n $loc ]] || return 1
  if [[ ${T14S_IDENTITY_OVERRIDES:-0} == 1 && -n ${LOCALE_FILES:-} ]]; then
    # shellcheck disable=SC2206
    files=(${LOCALE_FILES})
  else
    files=(/usr/share/i18n/SUPPORTED /etc/locale.gen)
  fi
  for f in "${files[@]}"; do
    [[ -r $f ]] || continue
    while read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*#?([A-Za-z0-9_.@-]+)[[:space:]] ]] || continue
      name="${BASH_REMATCH[1]}"
      [[ $name == "$loc" ]] && return 0
    done <"$f"
  done
  return 1
}

valid_keymap() {
  local km="$1" root=/usr/share/kbd/keymaps
  # Literal name only — never pass glob/regex metacharacters to find/grep.
  [[ $km =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
  if [[ ${T14S_IDENTITY_OVERRIDES:-0} == 1 && -n ${KEYMAP_DIR:-} ]]; then
    root="$KEYMAP_DIR"
  fi
  if command -v localectl >/dev/null 2>&1; then
    localectl list-keymaps 2>/dev/null | grep -qxF -- "$km" && return 0
    # Not listed: still accept an exact on-disk map (browse path). Charset is safe.
  fi
  # Directory check only for find fallback (Ubuntu CI often has no kbd keymaps tree).
  [[ -d $root ]] || return 1
  find "$root" -type f \
    \( -name "${km}.map" -o -name "${km}.map.gz" \
       -o -name "${km}.kmap" -o -name "${km}.kmap.gz" \) \
    2>/dev/null | grep -q .
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
    if [[ ! -b $ans ]]; then ui_error "Not a block device: $ans"; continue; fi
    if [[ $(disk_type "$ans") != part ]]; then
      ui_error "$ans is a whole disk, not a partition."; continue
    fi
    # Manual entry can name any disk; match the noninteractive part_on_disk check.
    if ! part_on_disk "$ans" "$disk"; then
      ui_error "$ans is not a partition on $disk."; continue
    fi
    printf '%s' "$ans"; return 0
  done
}

# archfi-inspired pickers: keymap from ISO maps, timezone Region/City menus.
# Commons must be real map basenames under /usr/share/kbd/keymaps.
pick_keymap() {
  local choice km args=() browse_args=()
  local commons=(us uk de fr es it pt-latin1 br-abnt2 ru jp106 dvorak colemak)
  for km in "${commons[@]}"; do
    args+=("$km" "common")
  done
  args+=(other "type a keymap name" browse "browse all keymaps on the ISO")
  while :; do
    choice="$(ui_menu "Console keymap (applied live with loadkeys)" "${args[@]}")" \
      || return 1
    case $choice in
      other)
        km="$(ui_input "Keymap name" us)" || return 1
        [[ -n $km ]] || continue
        printf '%s' "$km"
        return 0
        ;;
      browse)
        # Strip only .map.gz / .map — ${f%%.*} collapses lt.baltic → lt.
        browse_args=()
        while read -r km; do
          [[ -n $km ]] || continue
          browse_args+=("$km" "")
        done < <(find /usr/share/kbd/keymaps -type f \
          \( -name '*.map' -o -name '*.map.gz' \) -printf '%f\n' 2>/dev/null \
          | sed -E 's/\.map(\.gz)?$//' | sort -u)
        (( ${#browse_args[@]} >= 2 )) \
          || { ui_error "No keymaps under /usr/share/kbd/keymaps"; continue; }
        choice="$(ui_menu "All keymaps" "${browse_args[@]}")" || continue
        printf '%s' "$choice"
        return 0
        ;;
      *)
        printf '%s' "$choice"
        return 0
        ;;
    esac
  done
}

# Emit only a resolvable zone file path (or UTC). Never a directory.
pick_timezone() {
  local zroot=/usr/share/zoneinfo region city sub args=() d path
  # Do not invent UTC when zoneinfo is missing — valid_timezone needs a TZif file.
  [[ -d $zroot ]] || { ui_error "Missing $zroot — cannot pick a timezone"; return 1; }
  while read -r d; do
    args+=("$d" "")
  done < <(find "$zroot" -mindepth 1 -maxdepth 1 -type d \
    ! -name right ! -name posix -printf '%f\n' 2>/dev/null | sort)
  args+=(UTC "Coordinated Universal Time" other "type Region/City")
  region="$(ui_menu "Timezone region" "${args[@]}")" || return 1
  if [[ $region == other ]]; then
    city="$(ui_input "Timezone (Region/City)" America/New_York)" || return 1
    [[ -n $city ]] || return 1
    printf '%s' "$city"
    return 0
  fi
  if [[ $region == UTC ]]; then
    printf 'UTC'
    return 0
  fi
  args=()
  while read -r d; do
    args+=("$d" "")
  done < <(find "$zroot/$region" -mindepth 1 -maxdepth 1 \
    \( -type f -o -type d \) -printf '%f\n' 2>/dev/null | sort)
  (( ${#args[@]} >= 2 )) || { ui_error "No zones under $region"; return 1; }
  city="$(ui_menu "Timezone city ($region)" "${args[@]}")" || return 1
  path="$region/$city"
  # One nested level (e.g. America/Argentina/Buenos_Aires).
  if [[ -d $zroot/$path ]]; then
    args=()
    while read -r d; do
      args+=("$d" "")
    done < <(find "$zroot/$path" -mindepth 1 -maxdepth 1 \
      \( -type f -o -type d \) -printf '%f\n' 2>/dev/null | sort)
    if (( ${#args[@]} < 2 )); then
      ui_error "No zone files under $path"
      return 1
    fi
    sub="$(ui_menu "Timezone ($path)" "${args[@]}")" || return 1
    path="$path/$sub"
  fi
  if [[ ! -f $zroot/$path ]]; then
    ui_error "Not a timezone file: $path"
    return 1
  fi
  printf '%s' "$path"
}
