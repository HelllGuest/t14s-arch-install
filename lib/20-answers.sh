#!/usr/bin/env bash
# 20-answers.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

answers_load() {
  local f=$1 line key val
  [[ -f $f ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    val=${val%$'\r'}  # CRLF files leave CR at the end
    # Strip one matching pair of surrounding quotes (hand-edited answers).
    if [[ $val == \"*\" ]]; then
      val=${val#\"}; val=${val%\"}
    elif [[ $val == \'*\' ]]; then
      val=${val#\'}; val=${val%\'}
    fi
    case " ${ANSWERS_KEYS[*]} " in
      *" $key "*) printf -v "$key" '%s' "$val" ;;
    esac
  done <"$f"
  return 0
}

# Atomic: mktemp (always 0600) in the target dir, then rename over $f. A crash
# never leaves a partial file, and a symlink at $f is replaced, not followed.
answers_save() {
  local f=$1 k val tmp mode
  tmp=$(mktemp "$(dirname -- "$f")/.t14s-answers.XXXXXX") || return 1
  mode=$(stat -c '%a' "$tmp" 2>/dev/null || echo '')
  if [[ $mode != 600 ]]; then
    rm -f -- "$tmp"
    die "answers temp file not mode 0600 (got ${mode:-unknown}): $tmp"
  fi
  if ! {
    printf '# t14s-arch-install answers — reload with T14S_ANSWERS=%s\n' "$f"
    printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf '# Passwords NEVER stored here — use T14S_PASS_FILE for unattended secrets.\n'
    for k in "${ANSWERS_KEYS[@]}"; do
      if [[ -v $k ]]; then val=${!k}; else val=; fi
      printf '%s=%s\n' "$k" "$val"
    done
  } >"$tmp" || ! mv -f -- "$tmp" "$f"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Secrets file (LUKS/USER/ROOT only). Never written by answers_save.
# Format: KEY=value lines. Must be mode 0600 (u=rw only). Fail closed if mode unknown.
secrets_load() {
  local f=$1 line key val mode
  [[ -f $f ]] || return 1
  mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%OLp' "$f" 2>/dev/null || true)
  if [[ -z $mode ]]; then
    die "cannot read mode of T14S_PASS_FILE (need 0600): $f"
  fi
  if [[ $mode != 600 && $mode != 0600 ]]; then
    die "T14S_PASS_FILE must be mode 0600 (got $mode): $f"
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    val=${val%$'\r'}  # CRLF files leave CR at the end
    # Strip one matching pair of surrounding quotes (raw values preferred).
    if [[ $val == \"*\" ]]; then
      val=${val#\"}; val=${val%\"}
    elif [[ $val == \'*\' ]]; then
      val=${val#\'}; val=${val%\'}
    fi
    case $key in
      LUKS_PASS|USER_PASS|ROOT_PASS) printf -v "$key" '%s' "$val" ;;
    esac
  done <"$f"
  return 0
}

# True if partition $1 is a child of disk $2 (PKNAME preferred; bounded path fallback).
part_on_disk() {
  local part=$1 disk=$2 pk base rest
  [[ -b $part && -b $disk ]] || return 1
  pk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
  base=${disk##*/}
  [[ -n $pk && $pk == "$base" ]] && return 0
  # Bound fallback so /dev/nvme0n1 does not match /dev/nvme0n10p1.
  if [[ $disk == *nvme* || $disk == *mmcblk* || $disk == *loop* ]]; then
    [[ $part == "${disk}p"* ]] || return 1
    rest=${part#"${disk}p"}
  else
    [[ $part == "$disk"* && $part != "$disk" ]] || return 1
    rest=${part#"$disk"}
  fi
  [[ $rest =~ ^[0-9]+$ ]]
}
