#!/usr/bin/env bash
# Smoke checks for the public T14s installer (no root / no disk).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$ROOT/install.sh" ]] || fail "missing install.sh"
[[ -x "$ROOT/install.sh" ]] || fail "install.sh not executable"
bash -n "$ROOT/install.sh" || fail "bash -n failed"

grep -q 'amd_iommu=on' "$ROOT/install.sh" || fail "missing amd_iommu=on"
grep -q 'amd_pstate=active' "$ROOT/install.sh" || fail "missing amd_pstate=active"
grep -q 'UCODE=amd-ucode' "$ROOT/install.sh" || fail "must default amd-ucode"
grep -qE 'intel_iommu=on' "$ROOT/install.sh" && fail "must not set intel_iommu=on" || true

grep -q 'username cannot be empty' "$ROOT/install.sh" || fail "must reject empty username"
grep -q "username cannot be 'root'" "$ROOT/install.sh" || fail "must reject username root"
grep -q '.t14s-install-secrets' "$ROOT/install.sh" || fail "must use secrets file (not env passwords)"
grep -q 'USER_PASS=' "$ROOT/install.sh" && grep -q 'arch-chroot /mnt env' "$ROOT/install.sh" \
  && grep 'arch-chroot /mnt env' -A3 "$ROOT/install.sh" | grep -q 'USER_PASS=' \
  && fail "must not pass USER_PASS via arch-chroot env" || true

grep -q 'com.google.Chrome' "$ROOT/install.sh" \
  && grep -A2 'for app in' "$ROOT/install.sh" | grep -q 'com.google.Chrome' \
  && fail "Chrome must not be in chroot flatpak loop" || true

grep -q 'LOGIN_HINT' "$ROOT/install.sh" || fail "finish banner must gate on DESKTOP"
grep -q 'AuthenticAMD' "$ROOT/install.sh" || fail "must gate on AuthenticAMD"
grep -qF '21C[QR]' "$ROOT/install.sh" || fail "DMI check must use anchored 21C[QR]"

grep -q 'HelllGuest/t14s-arch-install/main/install.sh' "$ROOT/install.sh" \
  || fail "curl URL must point at this repo"
! grep -q 'github.com/HelllGuest/dotfiles' "$ROOT/install.sh" \
  || fail "install.sh must not link private dotfiles"
! grep -q 'github.com/HelllGuest/dotfiles' "$ROOT/README.md" \
  || fail "README must not link private dotfiles"
grep -E 'Flatpak/Podman|Podman userns' "$ROOT/install.sh" \
  && fail "banner must not claim Podman" || true

command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning -e SC2015,SC2086,SC2162 "$ROOT/install.sh" \
  || echo "NOTE: shellcheck skipped or warnings-only"

echo "PASS: smoke.test.sh"
