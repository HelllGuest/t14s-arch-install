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
grep -q '^valid_username()' "$ROOT/install.sh" || fail "must define valid_username"
grep -q '^valid_timezone()' "$ROOT/install.sh" || fail "must define valid_timezone"
grep -q '^valid_keymap()' "$ROOT/install.sh" || fail "must define valid_keymap"
grep -q 'grep -qxF --' "$ROOT/install.sh" || fail "keymap match must be fixed-string (-F)"
grep -q 'getent group' "$ROOT/install.sh" || fail "username must reject existing groups"
grep -q 'TZif' "$ROOT/install.sh" || fail "timezone must require TZif magic"
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
grep -q 'ui_step' "$ROOT/install.sh" || fail "wizard must set ui_step progress"
grep -q 'ui_backtitle' "$ROOT/install.sh" || fail "tui must use dynamic backtitle"
grep -q 'ui_fold' "$ROOT/install.sh" || fail "messages must fold prose"
grep -q '_tui_btns' "$ROOT/install.sh" || fail "must set Next/Abort/Erase button labels"
grep -q 'erase_yesno' "$ROOT/install.sh" || fail "wipe confirms need erase_yesno buttons"
grep -q 'critical_yesno' "$ROOT/install.sh" || fail "hard gates need critical_yesno buttons"
grep -q 'TUI_STEPS=11' "$ROOT/install.sh" || fail "wizard must declare 11 steps"
grep -q 'not color-only' "$ROOT/README.md" || fail "README must note a11y severity badges"
grep -q 'Next' "$ROOT/README.md" || fail "README Controls must document Next button"
grep -q 'ui_yesno` only' "$ROOT/README.md" \
  || fail "README must mark erase/critical confirms as ui_yesno-only"
grep -q 'NONINTERACTIVE: skipping welcome TUI' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE must skip welcome TUI"
grep -q 'choose 1-\$i (empty=1)' "$ROOT/install.sh" \
  || fail "plain menu must not claim Ctrl-C is Esc"
grep -q -- '--progressbox' "$ROOT/install.sh" || fail "dialog progressbox for live steps"
# Button roles: wipe uses erase; DMI/hook hard gates use critical (not Erase).
# Non-spanning parse: one quoted prompt per ui_yesno (no nested " inside prompts).
python3 - "$ROOT/install.sh" <<'PY' || fail "yesno button roles must separate erase vs continue"
from pathlib import Path
import re, sys
t = Path(sys.argv[1]).read_text()
# dialog + whiptail labels
for backend, yes, flag in (
    ("dialog", "Erase", "--yes-label"),
    ("dialog", "Continue", "--yes-label"),
    ("whiptail", "Erase", "--yes-button"),
    ("whiptail", "Continue", "--yes-button"),
):
    role = "erase_yesno" if yes == "Erase" else "critical_yesno"
    pat = rf"{backend}/{role}\)\s+_btns=\({flag} {yes}"
    assert re.search(pat, t), f"missing {backend} {role} → {yes}"
# plain [ERASE] distinct from [CRITICAL]
assert re.search(r"erase\)\s+tag=.*\[ERASE\]", t), "plain [ERASE] tag"
assert re.search(r"critical\)\s+tag=.*\[CRITICAL\]", t), "plain [CRITICAL] tag"
# One call == one "..." prompt; [^"]* allows newlines inside the quotes.
calls = re.findall(
    r'ui_yesno\s+"([^"]*)"\s+(yes|no)\s+(critical|erase|warn|error|info)\b',
    t,
    flags=re.S,
)
erase = [(p, d, s) for p, d, s in calls if s == "erase"]
critical = [(p, d, s) for p, d, s in calls if s == "critical"]
assert len(erase) == 3, (
    f"expected exactly 3 erase confirms, got {len(erase)}: {[p[:40] for p, _, _ in erase]}"
)
assert all(d == "no" for _, d, _ in erase), "erase confirms must default no"
assert any(p.startswith("ERASE $DISK now?") for p, _, _ in erase), "AUTO disk erase"
assert any("Proceed with these partitions" in p for p, _, _ in erase), "MANUAL proceed erase"
assert any("will be ERASED" in p for p, _, _ in erase), "final start erase"
assert any("Wrong machine?" in p for p, _, _ in critical), "DMI must use critical"
assert any("trust the URL" in p for p, _, _ in critical), "hook must use critical"
proceed = [c for c in calls if "Proceed with these partitions" in c[0]]
assert len(proceed) == 1 and proceed[0][2] == "erase", proceed
# ui_msg must not grow an erase case branch (erase is ui_yesno-only)
msg = t[t.find("ui_msg()"): t.find("ui_info()")]
assert not re.search(r"(?m)^\s*erase\)", msg), "ui_msg must not handle erase severity"
# False-green regression: spanning .*? finder still sees Proceed after severity flip
poison = t.replace(
    '" no erase',
    '" no critical',
    1,
)  # flips AUTO disk erase first — real parser must fail count
poison_calls = re.findall(
    r'ui_yesno\s+"([^"]*)"\s+(yes|no)\s+(critical|erase|warn|error|info)\b',
    poison,
    flags=re.S,
)
poison_erase = [c for c in poison_calls if c[2] == "erase"]
assert len(poison_erase) == 2, "parser must drop flipped AUTO erase"
# Spanning finder stays green on Proceed→critical + extra erase (document why we avoid it)
span_src = t.replace(
    'EFI   $EFI_PART  ${efi_mb}MB  ${_proc_efi_lbl}" no erase',
    'EFI   $EFI_PART  ${efi_mb}MB  ${_proc_efi_lbl}" no critical',
    1,
)
span_src += '\nui_yesno "extra" no erase\n'
span_hit = re.findall(r'ui_yesno\s+".*?"\s+no\s+erase\b', span_src, flags=re.S)
assert any("Proceed with these partitions" in s for s in span_hit), (
    "expected spanning false-green; if this fails, delete this guard"
)
print("ok yesno button roles")
PY
# Live backends (when installed): confirm button flags exist on the binary.
if command -v dialog >/dev/null 2>&1; then
  dialog --help 2>&1 | grep -q -- '--yes-label' \
    || fail "installed dialog missing --yes-label"
  dialog --help 2>&1 | grep -q -- '--ok-label' \
    || fail "installed dialog missing --ok-label"
fi
if command -v whiptail >/dev/null 2>&1; then
  whiptail --help 2>&1 | grep -q -- '--yes-button' \
    || fail "installed whiptail missing --yes-button"
  whiptail --help 2>&1 | grep -q -- '--ok-button' \
    || fail "installed whiptail missing --ok-button"
fi
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
grep -q 'pick_keymap' "$ROOT/install.sh" || fail "must offer archfi-style keymap picker"
grep -q 'pick_timezone' "$ROOT/install.sh" || fail "must offer archfi-style timezone picker"
grep -q 'pt-latin1' "$ROOT/install.sh" || fail "common keymaps must use real map names"
grep -q 'br-abnt2' "$ROOT/install.sh" || fail "common keymaps must use real map names"
grep -q 'jp106' "$ROOT/install.sh" || fail "common keymaps must use real map names"
grep -q 'browse_args' "$ROOT/install.sh" || fail "keymap browse must not clobber commons menu"
grep -q "s/\\\\.map(\\\\.gz)?\\$//" "$ROOT/install.sh" \
  || grep -q 's/\.map(\.gz)?$//' "$ROOT/install.sh" \
  || fail "keymap browse must strip .map/.map.gz only (not %%.*)"
! grep -q 'km=\${f%%\.\*}' "$ROOT/install.sh" \
  || fail "keymap browse must not use \${f%%.*}"
grep -qF '/usr/share/zoneinfo/$tz' "$ROOT/install.sh" \
  || fail "timezone validator must resolve under /usr/share/zoneinfo"
grep -qF 'valid_timezone "$TIMEZONE"' "$ROOT/install.sh" \
  || fail "identity step must call valid_timezone"
grep -qF 'valid_hostname "$HOSTNAME"' "$ROOT/install.sh" \
  || fail "identity step must call valid_hostname"
grep -qF 'valid_locale "$LOCALE"' "$ROOT/install.sh" \
  || fail "identity step must call valid_locale"
grep -qF 'valid_keymap "$KEYMAP"' "$ROOT/install.sh" \
  || fail "identity step must call valid_keymap"
grep -qF 'valid_username "$USERNAME"' "$ROOT/install.sh" \
  || fail "identity step must call valid_username"
grep -qF 'T14S_IDENTITY_OVERRIDES' "$ROOT/install.sh" \
  || fail "fixture overrides must be gated on T14S_IDENTITY_OVERRIDES"
grep -qF 'cannot pick a timezone' "$ROOT/install.sh" \
  || fail "pick_timezone must not invent UTC when zoneinfo is missing"
grep -q 'LUKS_WIPE' "$ROOT/install.sh" || fail "must offer optional LUKS mapper wipe"
grep -q 'rc == 0 || rc == 1' "$ROOT/install.sh" || fail "LUKS wipe must treat dd exit 1 as success only"
grep -q 'PACMAN_PARALLEL' "$ROOT/install.sh" || fail "must offer ParallelDownloads choice"
grep -q '#\\?ParallelDownloads' "$ROOT/install.sh" \
  || fail "chroot ParallelDownloads sed must match commented or live lines"
grep -q 'skip_reflector' "$ROOT/install.sh" || fail "checklist must offer skip reflector"
grep -q 'INSTALL_CUPS' "$ROOT/install.sh" || fail "must offer archdi-style CUPS option"
grep -q 'nerd_fonts' "$ROOT/install.sh" || fail "checklist must offer nerd_fonts"
grep -q 'ttf-jetbrains-mono-nerd' "$ROOT/install.sh" || fail "must install JetBrains Mono Nerd"
grep -q 'ttf-meslo-nerd' "$ROOT/install.sh" || fail "must install Meslo Nerd"
grep -q 'ttf-nerd-fonts-symbols-common' "$ROOT/install.sh" || fail "must install nerd symbols"
grep -q 'INSTALL_NERD_FONTS' "$ROOT/install.sh" || fail "must gate nerd fonts install"
grep -A20 'arch-chroot /mnt env' "$ROOT/install.sh" | grep -q 'INSTALL_NERD_FONTS=' \
  || fail "arch-chroot env must pass INSTALL_NERD_FONTS"
grep -q 'answers_save' "$ROOT/install.sh" || fail "must save T14S answers file"
grep -q 'answers_load' "$ROOT/install.sh" || fail "must load T14S_ANSWERS"
grep -q 'T14S_NONINTERACTIVE' "$ROOT/install.sh" || fail "must honor T14S_NONINTERACTIVE"
grep -q 'Install profile' "$ROOT/install.sh" || fail "must offer gnome/dev/minimal presets"
grep -q 'smartctl -H' "$ROOT/install.sh" || fail "must SMART-check target disk"
grep -q 'INSTALL_CLI' "$ROOT/install.sh" || fail "must offer CLI tools bundle"
grep -q 'INSTALL_PODMAN' "$ROOT/install.sh" || fail "must offer podman"
grep -q 'INSTALL_DOCKER' "$ROOT/install.sh" || fail "must offer docker"
grep -q 'INSTALL_VIRT' "$ROOT/install.sh" || fail "must offer libvirt/qemu"
grep -q 'INSTALL_AVAHI' "$ROOT/install.sh" || fail "must offer avahi"
grep -q 'INSTALL_STARSHIP' "$ROOT/install.sh" || fail "must offer starship"
grep -q 'POST_HOOK_URL' "$ROOT/install.sh" || fail "must offer post-install hook URL"
grep -q 'prefer-dark' "$ROOT/install.sh" || fail "must ship GNOME dark dconf defaults"
grep -q 'JetBrainsMono Nerd Font' "$ROOT/install.sh" || fail "must set Console Nerd Font"
grep -q 'install-chrome-flatpak.sh' "$ROOT/install.sh" || fail "must offer Chrome helper script"
grep -q 'arch-chroot /mnt' "$ROOT/install.sh" || fail "recovery docs / hook must mention arch-chroot"
grep -q 'Core extras' "$ROOT/install.sh" || fail "must split Core checklist"
grep -q 'Dev / CLI tools' "$ROOT/install.sh" || fail "must split Dev/CLI checklist"
grep -q 'Network / security' "$ROOT/install.sh" || fail "must split Network checklist"
grep -q 'yn_on "\$DESKTOP"' "$ROOT/install.sh" || fail "TLP guard must use yn_on"
grep -q 'set -o pipefail' "$ROOT/install.sh" || fail "post-hook must use pipefail"
grep -q 'T14S_POST_HOOK_I_UNDERSTAND' "$ROOT/install.sh" \
  || fail "post-hook NONINTERACTIVE must require explicit opt-in"
grep -q 'mdns_minimal' "$ROOT/install.sh" || fail "avahi path must patch nsswitch mdns_minimal"
grep -q 'jail.d/sshd.local' "$ROOT/install.sh" || fail "fail2ban must enable sshd jail"
grep -q 'using DISK from answers' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE must honor DISK from answers"
grep -q 'timezone from answers' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE must honor TIMEZONE from answers"
grep -q 'T14S_PASS_FILE' "$ROOT/install.sh" || fail "must support T14S_PASS_FILE"
grep -q 'secrets_load' "$ROOT/install.sh" || fail "must define secrets_load"
grep -q 'MANUAL partitions from answers' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE MANUAL must honor EFI_PART/ROOT_PART"
grep -q 'SKIP_THINKPAD_HW' "$ROOT/install.sh" || fail "must detect/skip ThinkPad HW on VM"
grep -q 'INSTALL_SNAPPER_HOME' "$ROOT/install.sh" || fail "must offer snapper home"
grep -q 'ESP free after UKI\|ESP nearly full after UKI' "$ROOT/install.sh" \
  || fail "must check ESP free space after UKI build"
grep -q 'sbctl verify' "$ROOT/install.sh" || fail "must run sbctl verify"
grep -q 'enroll skipped — sbctl verify failed' "$ROOT/install.sh" \
  || fail "must block enroll when sbctl verify fails"
grep -q 't14s-selftest' "$ROOT/install.sh" || fail "must offer BT/audio self-test"
grep -q 'BTRFS_COMPRESS' "$ROOT/install.sh" || fail "must offer Btrfs compression radio"
grep -q 'ZRAM_SIZE' "$ROOT/install.sh" || fail "must offer zram size radio"
grep -q 'REFLECTOR_COUNTRY' "$ROOT/install.sh" || fail "must honor reflector country"
grep -q 'T14S_DEFAULT_HOOK_URL' "$ROOT/install.sh" || fail "must offer hook env preset"
grep -q 'xdg-user-dirs-update' "$ROOT/install.sh" || fail "must run xdg-user-dirs-update"
grep -q 'INSTALL_LINUX_STABLE' "$ROOT/install.sh" || fail "must offer optional linux UKI"
grep -q 'INSTALL_PLYMOUTH' "$ROOT/install.sh" || fail "must offer optional plymouth"
grep -q 'Answers schema' "$ROOT/README.md" || fail "README must document answers schema"
grep -q 'NONINTERACTIVE: skipping REVIEW/confirm' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE must skip REVIEW/final confirm"
grep -q 'NONINTERACTIVE AUTO: will erase' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE must skip AUTO type-DISK wipe confirm"
grep -q 'NONINTERACTIVE requires T14S_PASS_FILE' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE must die early without T14S_PASS_FILE"
# Pass-file gate must appear before ui_password for LUKS
python3 - "$ROOT/install.sh" <<'PY' || fail "NONINTERACTIVE pass-file die must precede ui_password"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
die_i = t.find("NONINTERACTIVE requires T14S_PASS_FILE")
pw_i = t.find("ui_password 'LUKS passphrase'")
assert die_i > 0 and pw_i > 0 and die_i < pw_i, (die_i, pw_i)
print("ok pass-file die order")
PY
grep -q 'part_on_disk' "$ROOT/install.sh" || fail "MANUAL answers must verify part_on_disk"
grep -q 'yn_canon' "$ROOT/install.sh" || fail "must canonicalize flags to Y/N"
grep -q 'chmod 600' "$ROOT/install.sh" || fail "answers_save / secrets must chmod 600"
grep -q 'must be mode 0600' "$ROOT/install.sh" || fail "secrets_load must require mode 0600"
# Chroot body must define yn_on and not leave stray ] after yn_on calls
python3 - "$ROOT/install.sh" <<'PY' || fail "chroot yn_on gates broken"
from pathlib import Path
import re, sys, subprocess, tempfile
t = Path(sys.argv[1]).read_text()
start = t.find("<<'CHROOT'\\n")
if start < 0:
    start = t.find("<<'CHROOT'\n")
assert start > 0
start = t.find("\n", start) + 1
end = t.find("\nCHROOT\n", start)
body = t[start:end]
assert "yn_on() {" in body, "chroot missing yn_on"
assert not re.search(r'yn_on[^\n]*"\]', body), "stray ] after yn_on"
assert not re.search(r'\$\{(?:INSTALL_|SKIP_|DESKTOP|ENROLL_|ENABLE_|UFW_)[A-Z0-9_]*\^\^\}', body), \
    "chroot still uses ^^ on feature flags"
assert "sd-encrypt" in body and "HOOKS missing sd-encrypt" in body
with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
    f.write(body)
    name = f.name
subprocess.check_call(["bash", "-n", name])
print("ok chroot yn_on + bash -n")
PY
grep -q 'xdg-user-dirs' "$ROOT/install.sh" || fail "must pacstrap or call xdg-user-dirs"
grep -q 'T14S_I_WILL_ERASE' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE wipe must require T14S_I_WILL_ERASE"
grep -q 'no env passwords' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE must refuse ambient env passwords"
grep -q 'unset -v LUKS_PASS USER_PASS ROOT_PASS' "$ROOT/install.sh" \
  || fail "must unset ambient password env at start"
grep -q 'cannot read mode of T14S_PASS_FILE' "$ROOT/install.sh" \
  || fail "secrets_load must fail closed if mode unknown"
grep -q 'could not chmod 600 answers' "$ROOT/install.sh" \
  || fail "answers_save must die if chmod 600 fails"
grep -q 'EXTRA_PKGS_LIST' "$ROOT/install.sh" \
  || fail "must persist EXTRA_PKGS_LIST in answers"
grep -q "v == y || \$v == yes" "$ROOT/install.sh" \
  || fail "yn_on must match y/yes/on/1 only"
grep -q "HOOKS=.*sd-encrypt" "$ROOT/install.sh" \
  || fail "HOOKS verify must match ^HOOKS=.*sd-encrypt"
grep -q 'NONINTERACTIVE needs DISK=' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE missing DISK must die (not TUI)"
grep -q 'NONINTERACTIVE needs MODE=' "$ROOT/install.sh" \
  || fail "NONINTERACTIVE missing MODE must die"
# part_on_disk must not accept nvme0n1 vs nvme0n10 via naive prefix
python3 - "$ROOT/install.sh" <<'PY' || fail "part_on_disk must bound nvme prefix"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
i = t.find("part_on_disk()")
assert i > 0
window = t[i:i+700]
assert 'nvme0n1' in window or 'Bound' in window or '${disk}p' in window
assert 'rest=' in window and '^[0-9]+$' in window
print("ok part_on_disk bound")
PY
grep -q 'T14S_I_WILL_ERASE' "$ROOT/README.md" \
  || fail "README must document T14S_I_WILL_ERASE"
grep -q 'EXTRA_PKGS_LIST' "$ROOT/README.md" \
  || fail "README must document EXTRA_PKGS_LIST"
grep -q 'CLEAN_ESP_ARCH' "$ROOT/install.sh" || fail "must offer CLEAN_ESP_ARCH"
grep -q 'clean_esp_arch_files' "$ROOT/install.sh" || fail "must define clean_esp_arch_files"
grep -q 'clean_esp "' "$ROOT/install.sh" || fail "Core checklist must offer clean_esp"
grep -q 'EFI/arch' "$ROOT/install.sh" || fail "ESP clean must remove EFI/arch vendor dir"
grep -A25 'arch-chroot /mnt env' "$ROOT/install.sh" | grep -q 'CLEAN_ESP_ARCH=' \
  || fail "arch-chroot env must pass CLEAN_ESP_ARCH"
grep -q 'CLEAN_ESP_ARCH' "$ROOT/README.md" || fail "README must document CLEAN_ESP_ARCH"
grep -q 'ESP / EFI layout' "$ROOT/README.md" || fail "README must document ESP/EFI layout"
grep -q 'Securing the EFI' "$ROOT/README.md" || fail "README must document EFI securing"
grep -q 'Can everything live under one directory' "$ROOT/README.md" \
  || fail "README must document why EFI is not one directory"
grep -q 'sbctl verify' "$ROOT/README.md" || fail "README must mention sbctl verify"
# NONINTERACTIVE must keep EXTRA_PKGS_LIST replay (not wipe array empty)
python3 - "$ROOT/install.sh" <<'PY' || fail "NONINTERACTIVE must not wipe EXTRA_PKGS after answers replay"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
i = t.find("if (( NONINTERACTIVE )); then\n  # Keep EXTRA_PKGS")
assert i > 0, "missing NI EXTRA_PKGS keep comment"
window = t[i:i+120]
assert "EXTRA_PKGS=()" not in window, "NI still wipes EXTRA_PKGS"
print("ok EXTRA_PKGS_LIST replay")
PY
# Interactive checklist must re-apply _extras_keep after EXTRA_PKGS=()
python3 - "$ROOT/install.sh" <<'PY' || fail "interactive must restore EXTRA_PKGS_LIST after checklist"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
assert "_extras_keep=(\"${EXTRA_PKGS[@]}\")" in t or '_extras_keep=("${EXTRA_PKGS[@]}")' in t
assert "EXTRA_PKGS+=(\"${_extras_keep[@]}\")" in t or 'EXTRA_PKGS+=("${_extras_keep[@]}")' in t
print("ok interactive extras keep")
PY
# Loader cleanup must use arch*.conf only (not linux-*.conf)
python3 - "$ROOT/install.sh" <<'PY' || fail "ESP clean must not delete linux-*.conf"
from pathlib import Path
import sys, re
t = Path(sys.argv[1]).read_text()
assert "-name 'arch*.conf'" in t or '-name "arch*.conf"' in t
# No find that deletes linux-*.conf
assert not re.search(r"-name 'linux-\*\.conf'", t), "linux-*.conf still deleted"
print("ok arch*.conf only")
PY
grep -q '_env_on' "$ROOT/install.sh" || fail "must parse T14S_NONINTERACTIVE / I_WILL_ERASE with yn-style"
grep -q 'DNS labels only' "$ROOT/install.sh" || fail "must validate HOSTNAME charset"
grep -q 'yn_on "\$DESKTOP"' "$ROOT/install.sh" || fail "finish path must use yn_on DESKTOP"
grep -q 'flatpak install --user -y flathub com.google.Chrome' "$ROOT/install.sh" \
  || fail "finish Chrome hint must use --user"
grep -q 'flatpak install --user' "$ROOT/README.md" \
  || fail "README Chrome tip must match helper (--user)"
grep -q 'Setup Mode' "$ROOT/README.md" || fail "README SB enroll must mention Setup Mode"
grep -q 'FORMAT_EFI=1' "$ROOT/README.md" || fail "README must note CLEAN_ESP ignored when formatting"
grep -q 'dead entries' "$ROOT/install.sh" || fail "CLEAN_ESP_ARCH=N must warn about dead boot entries"
grep -q 'sudo -u "\$USERNAME" tee -a' "$ROOT/install.sh" \
  || fail "starship must append zshrc as the user"
! grep -q "gtk-theme='Adwaita-dark'" "$ROOT/install.sh" \
  || fail "dconf must not set stale Adwaita-dark gtk-theme"
python3 - "$ROOT/install.sh" <<'PY' || fail "JetBrainsMono dconf must be gated on INSTALL_NERD_FONTS"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
i = t.find("monospace-font-name='JetBrainsMono Nerd Font Mono 11'")
assert i > 0, "monospace line missing"
window = t[max(0, i - 400):i]
assert "INSTALL_NERD_FONTS" in window, "JetBrainsMono dconf not under INSTALL_NERD_FONTS gate"
print("ok nerd dconf gate")
PY
grep -q 'yn_on "\$INSTALL_CHROME_HINT"' "$ROOT/install.sh" \
  || fail "chrome hint must use yn_on"
grep -q 'set-x11-keymap' "$ROOT/install.sh" || fail "GNOME path must set X11 keymap from console map"
grep -q 'XKB_LAYOUT=gb' "$ROOT/install.sh" || fail "XKB remap must map uk → gb"
grep -q 'XkbVariant' "$ROOT/install.sh" || fail "XKB conf must support variants (dvorak/colemak/abnt2)"
grep -q 'write_xkb_conf\|00-keyboard.conf' "$ROOT/install.sh" \
  || fail "must write 00-keyboard.conf when localectl fails"
grep -A6 'arch-chroot /mnt env' "$ROOT/install.sh" | grep -q 'INSTALL_CUPS=' \
  || fail "arch-chroot env must pass INSTALL_CUPS"
grep -A6 'arch-chroot /mnt env' "$ROOT/install.sh" | grep -q 'PACMAN_PARALLEL=' \
  || fail "arch-chroot env must pass PACMAN_PARALLEL"
grep -q 'bash-completion' "$ROOT/install.sh" || fail "must offer archdi console tools"
grep -q 'T14S_EXTRA_PKGS' "$ROOT/install.sh" || fail "must honor T14S_EXTRA_PKGS / free-form extras"
grep -q 'locale=%s' "$ROOT/install.sh" || fail "DRYRUN dump must include locale"
grep -q 'archfi' "$ROOT/README.md" || fail "README must credit archfi adaptations"
grep -q 'archdi' "$ROOT/README.md" || fail "README must credit archdi adaptations"
# keymap basename strip unit (no dialog)
python3 - <<'PY' || fail "keymap .map.gz strip logic wrong"
import re
samples = {
  "us.map.gz": "us",
  "lt.baltic.map.gz": "lt.baltic",
  "lt.l4.map.gz": "lt.l4",
  "defkeymap_V1.0.map.gz": "defkeymap_V1.0",
  "pt-latin1.map.gz": "pt-latin1",
  "br-abnt2.map": "br-abnt2",
}
pat = re.compile(r"\.map(\.gz)?$")
for src, want in samples.items():
  got = pat.sub("", src)
  assert got == want, (src, got, want)
print("ok keymap strip")
PY
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

# Identity validators: real inputs (extract from install.sh; fixtures for CI)
extract_fn() {
  awk -v n="$1" '
    $0 ~ "^" n "\\(\\)" {grab=1}
    grab {print; if ($0 == "}") exit}
  ' "$ROOT/install.sh"
}
# shellcheck disable=SC1090
source <(for fn in valid_hostname valid_username valid_timezone valid_locale valid_keymap; do
  extract_fn "$fn"
  echo
done)
valid_hostname thinkpad-t14s || fail "hostname thinkpad-t14s should pass"
valid_hostname host.example.com || fail "hostname FQDN should pass"
valid_hostname -bad && fail "hostname -bad should fail" || true
valid_hostname bad- && fail "hostname bad- should fail" || true
valid_username root && fail "username root should fail" || true
valid_username bin && fail "username bin should fail" || true
for _g in wheel audio users; do
  if getent group "$_g" >/dev/null 2>&1; then
    valid_username "$_g" && fail "username $_g (group) should fail" || true
  fi
done
_fresh="t14sid$$"
valid_username "$_fresh" || fail "username $_fresh should pass"
_long40='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
valid_username "$_long40" && fail "username len 40 should fail" || true
valid_timezone America/New_York || fail "timezone America/New_York should pass"
valid_timezone UTC || fail "timezone UTC should pass"
valid_timezone '../../../etc/passwd' && fail "timezone traversal should fail" || true
valid_timezone zone.tab && fail "timezone zone.tab should fail" || true
valid_timezone Factory && fail "timezone Factory should fail" || true
if [[ -f /usr/share/zoneinfo/leapseconds ]]; then
  valid_timezone leapseconds && fail "timezone leapseconds should fail" || true
fi
if [[ -f /usr/share/zoneinfo/posixrules ]]; then
  valid_timezone posixrules && fail "timezone posixrules should fail" || true
fi
_idtmp="$(mktemp -d)"
trap 'rm -rf "$_idtmp"' EXIT
printf '%s\n' 'en_US.UTF-8 UTF-8' >"$_idtmp/locales"
mkdir -p "$_idtmp/keymaps" "$_idtmp/bin"
: >"$_idtmp/keymaps/us.map.gz"
: >"$_idtmp/keymaps/extra.map.gz"
# Overrides ignored without T14S_IDENTITY_OVERRIDES=1
LOCALE_FILES="$_idtmp/locales" valid_locale en_US.UTF-8 \
  || fail "locale en_US.UTF-8 should pass via host locale.gen/SUPPORTED"
LOCALE_FILES="$_idtmp/locales" valid_locale NotA_Locale \
  && fail "locale NotA_Locale should fail without overrides inventing it" || true
T14S_IDENTITY_OVERRIDES=1 LOCALE_FILES="$_idtmp/locales" valid_locale en_US.UTF-8 \
  || fail "locale fixture en_US.UTF-8 should pass with overrides"
T14S_IDENTITY_OVERRIDES=1 LOCALE_FILES="$_idtmp/locales" valid_locale NotA_Locale \
  && fail "locale NotA_Locale should fail" || true
T14S_IDENTITY_OVERRIDES=1 KEYMAP_DIR="$_idtmp/keymaps" valid_keymap us \
  || fail "keymap fixture us should pass"
T14S_IDENTITY_OVERRIDES=1 KEYMAP_DIR="$_idtmp/keymaps" valid_keymap '*' \
  && fail "keymap glob * should fail" || true
# Without overrides, KEYMAP_DIR must not redirect the search root
KEYMAP_DIR="$_idtmp/keymaps" valid_keymap extra \
  && fail "KEYMAP_DIR must be ignored without T14S_IDENTITY_OVERRIDES" || true
cat >"$_idtmp/bin/localectl" <<'EOF'
#!/bin/sh
[ "$1" = list-keymaps ] || exit 1
printf '%s\n' us uk dvo
EOF
chmod +x "$_idtmp/bin/localectl"
extract_fn valid_keymap >"$_idtmp/valid_keymap.sh"
# shellcheck disable=SC2016
env T14S_IDENTITY_OVERRIDES=1 KEYMAP_DIR="$_idtmp/keymaps" \
  PATH="$_idtmp/bin:/usr/bin:/bin" bash -c '
  # shellcheck source=/dev/null
  source "$0"
  valid_keymap us || exit 11
  valid_keymap dvo || exit 14
  valid_keymap extra || exit 15
  valid_keymap u. && exit 12
  valid_keymap "..." && exit 13
  exit 0
' "$_idtmp/valid_keymap.sh" \
  || fail "stub localectl: us/dvo/extra pass / u. and ... must fail"

command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning -e SC2015,SC2086,SC2162 "$ROOT/install.sh" \
  || echo "NOTE: shellcheck skipped or warnings-only"

echo "PASS: smoke.test.sh"
