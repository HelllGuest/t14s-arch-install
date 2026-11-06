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
grep -q 'run_progress' "$ROOT/install.sh" || fail "must define run_progress for live pacstrap output"
grep -q 'run_progress "pacstrap' "$ROOT/install.sh" \
  || fail "pacstrap must use run_progress (visible on TTY)"
grep -q 'run_progress "running chroot' "$ROOT/install.sh" \
  || fail "chroot must use run_progress"
grep -q 'ui_view_log' "$ROOT/install.sh" || fail "must offer ui_view_log"
grep -q 'ui_checklist' "$ROOT/install.sh" || fail "must offer ui_checklist multi-select"
grep -q 'ui_info' "$ROOT/install.sh" || fail "must define ui_info"
grep -q 'ui_warn' "$ROOT/install.sh" || fail "must define ui_warn"
grep -q 'ui_error' "$ROOT/install.sh" || fail "must define ui_error"
grep -q 'ui_critical' "$ROOT/install.sh" || fail "must define ui_critical"
grep -q 'ui_ok' "$ROOT/install.sh" || fail "must define ui_ok"
grep -q 'write_dialogrc' "$ROOT/install.sh" || fail "must ship dialogrc theme"
grep -q 'DIALOG_RC_CRITICAL' "$ROOT/install.sh" || fail "must ship per-severity dialogrc"
grep -q 'NEWT_COLORS_CRITICAL' "$ROOT/install.sh" || fail "must ship severity NEWT palettes"
grep -q 'NEWT_COLORS_OK' "$ROOT/install.sh" || fail "must ship green OK NEWT palette"
grep -q 'msg_height' "$ROOT/install.sh" || fail "must scale msgbox height with content"
grep -q 'TUI_KEEP_STDIN=1' "$ROOT/install.sh" || fail "progressbox must keep pipe stdin"
grep -q 'ui_critical' "$ROOT/install.sh" && grep -A20 '^die()' "$ROOT/install.sh" | grep -q 'ui_critical' \
  || fail "die must show ui_critical"
grep -q '\[severity\]' "$ROOT/install.sh" || fail "ui_yesno must document severity arg"
grep -q '\[ERROR\]' "$ROOT/install.sh" || fail "plain yesno must label error distinctly from critical"
grep -q 'log "View install log" off' "$ROOT/install.sh" || fail "checklist must offer log entry"
grep -q -- '--colors' "$ROOT/install.sh" || fail "dialog must enable --colors"
grep -q 'Message severity' "$ROOT/README.md" || fail "README must document message severity"
grep -q 'per-severity' "$ROOT/README.md" || fail "README must note per-severity dialogrc/NEWT"
grep -q -- '--progressbox' "$ROOT/install.sh" || fail "dialog progressbox for live steps"
# progressbox path must not force </dev/tty on the same invocation
python3 - "$ROOT/install.sh" <<'PY' || fail "progressbox must use TUI_KEEP_STDIN around tui"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
i = t.find('tui --progressbox')
assert i > 0, "progressbox call missing"
window = t[max(0, i - 250):i + 80]
assert "TUI_KEEP_STDIN=1" in window, "TUI_KEEP_STDIN=1 missing before progressbox"
assert "TUI_KEEP_STDIN=0" in t[i:i + 120], "TUI_KEEP_STDIN=0 missing after progressbox"
print("ok progressbox stdin")
PY
grep -q 'log "View install log"' "$ROOT/install.sh" \
  || fail "menus must expose log viewer entry"
grep -q 'sshd "Enable SSH' "$ROOT/install.sh" \
  || fail "checklist must offer sshd option"
# Prefer dialog over whiptail for progressbox
grep -q 'Prefer dialog' "$ROOT/install.sh" \
  || grep -A2 'command -v dialog' "$ROOT/install.sh" | grep -q 'UI=dialog' \
  || fail "bootstrap must prefer dialog when available"
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
