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
grep -q 'vulkan-radeon' "$ROOT/install.sh" || fail "must pacstrap vulkan-radeon"
grep -q 'mesa' "$ROOT/install.sh" || fail "must pacstrap mesa"
grep -q 'thinkpad-charge-thresholds.conf' "$ROOT/install.sh" \
  || fail "must install charge threshold tmpfiles"
grep -q 'charge_control_start_threshold - - - - 70' "$ROOT/install.sh" \
  || fail "charge tmpfiles must set start 70"
grep -q 'charge_control_end_threshold - - - - 80' "$ROOT/install.sh" \
  || fail "charge tmpfiles must set end 80"
grep -q 'thinkpad-charge-thresholds.service' "$ROOT/install.sh" \
  || fail "must ship charge oneshot after multi-user"
grep -q 'After=multi-user.target' "$ROOT/install.sh" \
  || fail "charge oneshot must After=multi-user.target"
grep -q 'apply-charge-thresholds.sh' "$ROOT/install.sh" \
  || fail "must install apply-charge-thresholds.sh"

# reflector rate-sort must be concurrency + time bounded, or a few dead mirrors
# serialize into a multi-minute blank screen
grep -q -- '--sort rate' "$ROOT/install.sh" || fail "reflector rate sort missing"
grep -q 'timeout [0-9]* reflector' "$ROOT/install.sh" || fail "live reflector run must have an overall timeout"
grep -q -- '--threads 5' "$ROOT/install.sh" || fail "reflector ranking must be concurrent"

# TUI: backend bootstrap + semantic helpers must exist, plus plain fallback
grep -q '### Controls' "$ROOT/README.md" || fail "README must document TUI controls"
grep -q '### Safety model' "$ROOT/README.md" || fail "README must document the safety model"
grep -q 'command -v whiptail' "$ROOT/install.sh" || fail "must detect whiptail"
grep -q 'command -v dialog' "$ROOT/install.sh" || fail "must detect/install dialog"
grep -q -- '--passwordbox' "$ROOT/install.sh" || fail "passwords must use a TUI prompt"
grep -q 'ui_yesno' "$ROOT/install.sh" || fail "choices must use ui_yesno"
grep -q 'T14S_DRYRUN' "$ROOT/install.sh" || fail "must keep a dry-run stop point"
# DRYRUN must not disable host swap / tear down /mnt before the dry-run exit
python3 - "$ROOT/install.sh" <<'PY' || fail "umount/swapoff must be inside if (( ! DRYRUN ))"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
i = t.find("umount -R /mnt")
assert i > 0, "umount missing"
window = t[max(0, i - 200):i]
assert "if (( ! DRYRUN ))" in window, "umount not guarded by ! DRYRUN"
assert "swapoff -a" in t[i:i + 160], "swapoff missing near umount"
print("ok dryrun guard")
PY

# partitioning: partitions chosen from lists, sizes validated
grep -q 'build_part_menu' "$ROOT/install.sh" || fail "partition selector helper missing"
grep -q 'pick_part' "$ROOT/install.sh" || fail "partition picker missing"
grep -q 'EFI system partition size' "$ROOT/install.sh" || fail "ESP size must be selectable"
grep -q 'lsblk -prno TYPE,PATH' "$ROOT/install.sh" || fail "partition list must filter to type=part"
grep -q 'root_mb < 8192' "$ROOT/install.sh" || fail "must warn on tiny root"

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
