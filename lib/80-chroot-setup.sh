#!/usr/bin/env bash
# 80-chroot-setup.sh — part of HelllGuest/t14s-arch-install
# Runs inside arch-chroot. Expects env from Stage A.
# shellcheck shell=bash
set -euo pipefail
# Files written here must be world-readable (locale.conf, dconf, sysctl.d…).
umask 022
# "WARN: …" lines are also collected for the host finish screen.
WARN_FILE=/root/t14s-warnings.txt
say(){
  printf '\e[1;34m>>\e[0m %s\n' "$*"
  if [[ $* == WARN:* ]]; then printf '%s\n' "${*#WARN: }" >>"$WARN_FILE"; fi
  return 0
}
warn(){ say "WARN: $*"; }
ok(){ say "ok $*"; }
# Progress marker for the host gauge (progress_filter): stage <lo%> <hi%> <text>
stage(){ printf '@@STAGE %s %s %s\n' "$1" "$2" "$3"; }
yn_on() { local v=${1,,}; [[ $v == y || $v == yes || $v == on || $v == 1 ]]; }
# Optional package set: install or record pacman's own error (not just "failed").
# Usage: pkg_try "label" pkg…   → 0 on success, 1 after a WARN with the reason.
pkg_try() {
  local label=$1 out rc=0; shift
  out=$(mktemp)
  pacman -S --noconfirm --needed "$@" 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}
  # New packager keys can postdate the pacstrap keyring: refresh once, retry.
  # Match pacman's error lines only — normal output always says "checking keys
  # in keyring". Keyring sync is followed by -Su (never a bare -Sy install).
  if (( rc != 0 )) && grep -qiE '^error:.*(signature|PGP|keyring|key "[^"]+")' "$out"; then
    say "$label: pacman key/signature error — refreshing archlinux-keyring, retrying once"
    rc=0
    { pacman -Sy --noconfirm --needed archlinux-keyring \
        && pacman -Su --noconfirm \
        && pacman -S --noconfirm --needed "$@"; } 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}
  fi
  if (( rc != 0 )); then
    say "WARN: $label install failed (pacman exit $rc): $(grep -m1 -E '^error:' "$out" || tail -n1 "$out")"
  fi
  rm -f "$out"
  return "$rc"
}
# Shared host helpers (pacman_tune) — written by the installer before arch-chroot.
# shellcheck disable=SC1091
source /root/t14s-lib.sh

# ── stages ──────────────────────────────────────────────────
# lib/chroot/*.sh, deployed to /root/t14s-lib/chroot/ by lib/steps/23-install-chroot.sh.
# Sourced here at top level in order, so helpers, globals and umask are shared.
for _t14s_cstage in /root/t14s-lib/chroot/[0-9]*.sh; do
  # shellcheck source=/dev/null
  source "$_t14s_cstage"
done
unset -v _t14s_cstage
