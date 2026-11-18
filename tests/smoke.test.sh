#!/usr/bin/env bash
# Smoke checks for the public T14s installer (no root / no disk).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Concatenated INSTALL_SH lives under /tmp — force local modules for live runs.
export T14S_LIB_DIR="${T14S_LIB_DIR:-$ROOT/lib}"
fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "$ROOT/install.sh" ]] || fail "missing install.sh"
[[ -x "$ROOT/install.sh" ]] || fail "install.sh not executable"
bash -n "$ROOT/install.sh" || fail "bash -n failed"
[[ -d $ROOT/lib ]] || fail "missing lib/ (modular layout)"
shopt -s nullglob
for _lib in "$ROOT"/lib/*.sh "$ROOT"/lib/steps/*.sh "$ROOT"/lib/chroot/*.sh; do
  bash -n "$_lib" || fail "bash -n failed: $_lib"
done
unset -v _lib
# Greps search orchestrator + modules. Live runs use ORCH_SH (not the concat).
ORCH_SH="$ROOT/install.sh"
# Stages exactly as install.sh sources them; lib/steps/ must hold no more, no less.
mapfile -t STEPS < <(sed -n '/^for _t14s_step in/,/; do$/p' "$ORCH_SH" \
  | tr ' ' '\n' | sed 's/;$//' | grep -E '^[0-9]{2}-[a-z0-9-]+\.sh$')
(( ${#STEPS[@]} > 0 )) || fail "could not read the stage list from install.sh"
[[ "$(printf '%s\n' "${STEPS[@]}")" == "$(cd "$ROOT/lib/steps" && ls -1 [0-9]*.sh)" ]] \
  || fail "install.sh stage list and lib/steps/ differ (or are not in run order)"
# curl one-liner path: _lib_path fetches lib/steps/* (subdir) from the same
# base URL into the temp dir. file:// keeps this offline.
_fetch="$(bash -c 'eval "$(awk "/^_lib_path\\(\\) *\\{/{f=1} f{print} f&&/^}\$/{exit}" "$1")"
  T14S_LIB_DIR="" T14S_BASE_URL="file://$2"; _lib_path steps/01-preflight.sh
  cmp -s "$_LIB_PATH" "$2/lib/steps/01-preflight.sh" && echo same; rm -rf -- "$T14S_LIB_FETCH_DIR"' _ "$ORCH_SH" "$ROOT")"
[[ $_fetch == same ]] || fail "curl path must fetch lib/steps/* into the fetch dir (got: $_fetch)"
unset -v _fetch
# Libraries as install.sh loads them: every lib/NN-*.sh except the chroot entry.
mapfile -t LIBS < <(sed -n '/^for _lib in/,/; do$/p' "$ORCH_SH" | tr ' ' '\n' | sed 's/;$//' \
  | grep -E '^[0-9]{2}-[a-z0-9-]+\.sh$')
[[ "$(printf '%s\n' "${LIBS[@]}")" == "$(cd "$ROOT/lib" && ls -1 [0-9]*.sh | grep -vx 80-chroot-setup.sh)" ]] \
  || fail "install.sh library list and lib/*.sh differ (or are not in load order)"
UI_SH=$(mktemp)       # the TUI layer (10-13) in load order, for tests that source it
trap 'rm -f "$UI_SH"' EXIT
_ui=()
for _l in "${LIBS[@]}"; do [[ $_l == 1[0-9]-ui*.sh ]] && _ui+=("$ROOT/lib/$_l"); done
cat "${_ui[@]}" >"$UI_SH"
unset -v _ui _l
INSTALL_SH=$(mktemp)
WIZARD_SH=$(mktemp)   # install.sh + stages in run order: the code install.sh runs
trap 'rm -f "$INSTALL_SH" "$WIZARD_SH" "${CHROOT_SH:-}" "$UI_SH"' EXIT
cat "$ROOT/install.sh" "${STEPS[@]/#/$ROOT/lib/steps/}" >"$WIZARD_SH"
# Chroot stages as lib/steps/23-install-chroot.sh deploys them; 80-chroot-setup.sh
# sources /root/t14s-lib/chroot/[0-9]*.sh in glob order, so names must sort in run order.
mapfile -t CHROOT_STAGES < <(sed -n '/^for _cs in/,/; do$/p' "$ROOT/lib/steps/23-install-chroot.sh" \
  | tr ' ' '\n' | sed 's/;$//' | grep -E '^[0-9]{2}-[a-z0-9-]+\.sh$')
(( ${#CHROOT_STAGES[@]} > 0 )) || fail "could not read the chroot stage list"
[[ "$(printf '%s\n' "${CHROOT_STAGES[@]}")" == "$(cd "$ROOT/lib/chroot" && ls -1 [0-9]*.sh)" ]] \
  || fail "deployed chroot stage list and lib/chroot/ differ (or are not in run order)"
grep -q 'for _t14s_cstage in /root/t14s-lib/chroot/\[0-9\]\*.sh; do' "$ROOT/lib/80-chroot-setup.sh" \
  || fail "80-chroot-setup.sh must source the deployed chroot stages"
CHROOT_SH=$(mktemp)   # chroot entry + stages in run order: the code arch-chroot runs
cat "$ROOT/lib/80-chroot-setup.sh" "${CHROOT_STAGES[@]/#/$ROOT/lib/chroot/}" >"$CHROOT_SH"
cat "$WIZARD_SH" "$ROOT"/lib/*.sh "${CHROOT_STAGES[@]/#/$ROOT/lib/chroot/}" >"$INSTALL_SH"

[[ -x "$ROOT/tests/host-check.sh" ]] && bash -n "$ROOT/tests/host-check.sh" \
  || fail "tests/host-check.sh missing, not executable, or bash -n failed"
! grep -qE '(^|[;&|[:space:]])(rm|mv|dd|mkfs|sgdisk|wipefs|tee|chmod|chown|sed -i|systemctl (start|stop|enable|disable|restart)) ' \
  "$ROOT/tests/host-check.sh" || fail "host-check.sh must stay read-only"

grep -q 'amd_iommu=on' "$INSTALL_SH" || fail "missing amd_iommu=on"
grep -q 'amd_pstate=active' "$INSTALL_SH" || fail "missing amd_pstate=active"
grep -q 'UCODE=amd-ucode' "$INSTALL_SH" || fail "must support amd-ucode for t14s"
grep -q 'UCODE=intel-ucode' "$INSTALL_SH" || fail "must support intel-ucode for p15"
grep -q 'HW_PROFILE' "$INSTALL_SH" || fail "must define HW_PROFILE"
grep -q 'intel_iommu=on' "$INSTALL_SH" || fail "p15 path must set intel_iommu=on"
grep -q 'firewalld' "$INSTALL_SH" || fail "must install/enable firewalld"

grep -q 'configure_firewalld' "$INSTALL_SH" || fail "must define configure_firewalld"
grep -q 'DefaultZone=drop' "$INSTALL_SH" || fail "must set firewalld DefaultZone=drop"
grep -q 'htop btop fastfetch' "$ROOT/lib/50-packages.sh" \
  || fail "base packages must always include htop btop fastfetch"
grep -q 'github-cli glab' "$ROOT/lib/50-packages.sh" \
  || fail "base packages must always include github-cli glab"
grep -q 'pacman -Rns --noconfirm ufw' "$ROOT/lib/70-firewall.sh" \
  || fail "configure_firewalld must remove ufw package when present"
! grep -qE '(^|[[:space:]])ufw([[:space:]]|$)' "$ROOT/lib/50-packages.sh" \
  || fail "base packages must not include ufw"
! grep -qE '\bUFW_(SYNCTHING|KDECONNECT)\b' "$WIZARD_SH" "$ROOT/lib/70-firewall.sh" \
  || fail "UFW_* answer compat must be removed (FW_* only)"
! test -e "$ROOT/install.sh.monolithic" \
  || fail "install.sh.monolithic must be deleted (modular install.sh is canonical)"
grep -q 'firewall-offline-cmd' "$INSTALL_SH" \
  || fail "chroot firewall must prefer firewall-offline-cmd"
grep -q 'T14S_LIB_DIR' "$ROOT/install.sh" || fail "orchestrator must support T14S_LIB_DIR"
grep -q "application/vnd.github.sha" "$ROOT/install.sh" \
  || fail "curl path must resolve main→SHA (Accept: application/vnd.github.sha)"
grep -q 'T14S_LIB_DIR && -z ${T14S_BASE_URL' "$ROOT/install.sh" \
  || fail "SHA resolve must run only when local lib/ is absent"
grep -qE 'T14S_REF:=69d4483' "$ROOT/install.sh" \
  && fail "must not hardcode a stale T14S_REF commit pin" || true
# Offline: checkout with lib/ beside install.sh must not need GitHub API
if command -v unshare >/dev/null 2>&1 && unshare -rn true 2>/dev/null; then
  _off_tmp="$(mktemp -d /tmp/t14s-off.XXXXXX)"
  ln -s "$ROOT/lib" "$_off_tmp/lib"
  sed -n '/^# ── library loader/,/^export T14S_REF/p' "$ROOT/install.sh" \
    >"$_off_tmp/probe.sh"
  printf '%s\n' \
    '[[ -n ${T14S_LIB_DIR:-} ]] || { echo "ERR: T14S_LIB_DIR empty"; exit 1; }' \
    '[[ -f $T14S_LIB_DIR/00-common.sh ]] || { echo "ERR: missing 00-common"; exit 1; }' \
    'printf "ok offline local lib\n"' >>"$_off_tmp/probe.sh"
  _off_err="$(
    unshare -rn env -u T14S_LIB_DIR -u T14S_BASE_URL -u T14S_REF \
      PATH="$PATH" HOME=/tmp TMPDIR=/tmp \
      bash "$_off_tmp/probe.sh" 2>&1
  )" || {
    printf '%s\n' "$_off_err" >&2
    rm -rf -- "$_off_tmp"
    fail "offline checkout must resolve lib/ without GitHub API"
  }
  echo "$_off_err" | grep -q 'ok offline local lib' \
    || { rm -rf -- "$_off_tmp"; fail "offline local lib probe: $_off_err"; }
  rm -rf -- "$_off_tmp"
  unset -v _off_tmp _off_err
fi
grep -q 'is-active --quiet firewalld' "$CHROOT_SH" \
  || fail "selftest check_firewalld must prefer is-active"
grep -q '70-firewall.sh' "$WIZARD_SH" || fail "orchestrator must deploy 70-firewall.sh"
grep -q '80-chroot-setup.sh' "$WIZARD_SH" || fail "orchestrator must deploy 80-chroot-setup.sh"
grep -q 't14s_base_packages' "$INSTALL_SH" || fail "pacstrap must use t14s_base_packages"
grep -q 'rm -rf /mnt/root/t14s-lib' "$WIZARD_SH" \
  || fail "cleanup must remove /mnt/root/t14s-lib"
grep -q 'deployed lib/.*missing or empty' "$WIZARD_SH" \
  || fail "_deploy_lib must reject empty modules"
grep -q 'systemctl mask ufw' "$INSTALL_SH" \
  || fail "must mask ufw when enabling firewalld"
grep -qE '(^|[[:space:]])ufw([[:space:]]|$)' "$INSTALL_SH" \
  && grep -q 'systemctl enable.*\bufw\b' "$INSTALL_SH" \
  && fail "must not enable ufw" || true
grep -q 'ollama.service.d' "$INSTALL_SH" || fail "must ship ollama override for P15"
grep -q 'OLLAMA_HOST=127.0.0.1:11434' "$INSTALL_SH" || fail "ollama must bind localhost"

grep -q 'username cannot be empty' "$INSTALL_SH" || fail "must reject empty username"
grep -q "username cannot be 'root'" "$INSTALL_SH" || fail "must reject username root"
grep -q '^valid_username()' "$INSTALL_SH" || fail "must define valid_username"
grep -q '^valid_timezone()' "$INSTALL_SH" || fail "must define valid_timezone"
grep -q '^valid_keymap()' "$INSTALL_SH" || fail "must define valid_keymap"
grep -q 'grep -qxF --' "$INSTALL_SH" || fail "keymap match must be fixed-string (-F)"
grep -q 'getent group' "$INSTALL_SH" || fail "username must reject existing groups"
grep -q 'TZif' "$INSTALL_SH" || fail "timezone must require TZif magic"
grep -q '.install-secrets' "$INSTALL_SH" || fail "must use secrets file (not env passwords)"
grep -q 'USER_PASS=' "$INSTALL_SH" && grep -q 'arch-chroot /mnt env' "$INSTALL_SH" \
  && grep 'arch-chroot /mnt env' -A3 "$INSTALL_SH" | grep -q 'USER_PASS=' \
  && fail "must not pass USER_PASS via arch-chroot env" || true

grep -q 'com.google.Chrome' "$INSTALL_SH" \
  && grep -A2 'for app in' "$INSTALL_SH" | grep -q 'com.google.Chrome' \
  && fail "Chrome must not be in chroot flatpak loop" || true

grep -q 'LOGIN_HINT' "$INSTALL_SH" || fail "finish banner must gate on DESKTOP"
grep -q 'AuthenticAMD' "$INSTALL_SH" || fail "must gate T14s on AuthenticAMD"
grep -q 'GenuineIntel' "$INSTALL_SH" || fail "must gate P15 on GenuineIntel"
grep -qF '21C[QR]' "$INSTALL_SH" || fail "DMI check must use anchored 21C[QR]"
grep -qF '20SU' "$INSTALL_SH" || fail "DMI check must detect P15 20SU"
grep -q 'target profile: T14s Gen 3 AMD' "$INSTALL_SH" \
  || fail "must print T14s target profile"
grep -q 'target profile: P15 Gen 1' "$INSTALL_SH" \
  || fail "must print P15 target profile"
grep -q 'HW_PROFILE=t14s' "$INSTALL_SH" || fail "must set HW_PROFILE=t14s on 21CQ/21CR"
grep -q 'HW_PROFILE=p15' "$INSTALL_SH" || fail "must set HW_PROFILE=p15 on 20SU"
grep -q 'vulkan-radeon' "$INSTALL_SH" || fail "must pacstrap vulkan-radeon"
grep -q 'mesa' "$INSTALL_SH" || fail "must pacstrap mesa"
grep -q 'libva-utils' "$INSTALL_SH" || fail "must install libva-utils with GNOME"
grep -q '_libva=radeonsi' "$INSTALL_SH" \
  || fail "must default LIBVA to radeonsi for T14s"
grep -q '_libva=iHD' "$INSTALL_SH" \
  || fail "must set LIBVA iHD for P15"
grep -q 'LIBVA_DRIVER_NAME=${_libva}' "$INSTALL_SH" \
  || fail "must write LIBVA_DRIVER_NAME from HW_PROFILE"
grep -q '61-gdm-wayland.rules' "$INSTALL_SH" \
  || fail "must install 61-gdm-wayland.rules for AMD 0x1002/0x1681"
# GDM hardening: check the actual heredoc bodies, not just any line in install.sh.
_heredoc() { awk -v t="$1" 'index($0, "cat > " t " <<\x27EOF\x27"){f=1;next} f&&/^EOF$/{exit} f' "$INSTALL_SH"; }
_gdmconf="$(_heredoc /etc/gdm/custom.conf)"
grep -qx 'DisallowTCP=true' <<<"$_gdmconf" || fail "gdm custom.conf must set DisallowTCP=true"
grep -qx 'AutomaticLoginEnable=false' <<<"$_gdmconf" || fail "gdm custom.conf must disable autologin"
awk '/^\[xdmcp\]/{s=1;next} /^\[/{s=0} s&&/^Enable=false$/{f=1} END{exit !f}' <<<"$_gdmconf" \
  || fail "gdm custom.conf must disable XDMCP"
_greeter="$(_heredoc /etc/dconf/db/gdm.d/00-login-screen)"
grep -qx 'disable-user-list=true' <<<"$_greeter" || fail "GDM greeter dconf must hide the user list"
# idle-delay is an org.gnome.desktop.session key; under login-screen it is ignored.
awk '/^\[/{s=$0} /^idle-delay=/{print s}' <<<"$_greeter" | grep -qx '\[org/gnome/desktop/session\]' \
  || fail "greeter idle-delay must live under [org/gnome/desktop/session]"
grep -q 'enable-fingerprint-authentication=false' "$INSTALL_SH" \
  || fail "greeter fingerprint auth must be disabled on SKIP_THINKPAD_HW"
if command -v dconf >/dev/null; then
  _d="$(mktemp -d)"
  printf '%s\n' "$_greeter" >"$_d/00"
  dconf compile "$_d/db" "$_d" || fail "GDM greeter dconf keyfile must compile"
  rm -rf "$_d"
fi
grep -q 'check gdm_dconf' "$INSTALL_SH" || fail "t14s-selftest must check the compiled GDM dconf db"
# The GDM block must sit inside the DESKTOP guard (headless installs have no gdm).
awk '/^if yn_on "\$DESKTOP"; then$/{d=1} d&&/^fi$/{d=0} /cat > \/etc\/gdm\/custom\.conf/{print d+0; exit}' "$INSTALL_SH" \
  | grep -qx 1 || fail "GDM config must be written inside the DESKTOP guard"
grep -q 'gdm.service.d/override.conf' "$INSTALL_SH" \
  || fail "must install GDM systemd override.conf"
grep -q '99-wayland.conf' "$INSTALL_SH" \
  || fail "must install /etc/environment.d/99-wayland.conf"
grep -q 'x86-64-v3' "$INSTALL_SH" \
  || fail "makepkg t14s.conf must tune for Zen 3+ x86-64-v3"
grep -q 'GOAMD64="\${GOAMD64:-v3}"' "$INSTALL_SH" \
  || fail "makepkg t14s.conf must set GOAMD64=v3"
grep -q 's2idle.conf' "$INSTALL_SH" \
  || fail "must install /etc/systemd/sleep.conf.d/s2idle.conf"
grep -q 'thinkpad-lid.conf' "$INSTALL_SH" \
  || fail "must install /etc/systemd/logind.conf.d/thinkpad-lid.conf"
grep -q '61-thinkpad-charge-limit.rules' "$INSTALL_SH" \
  || fail "must install 61-thinkpad-charge-limit.rules (UPower CHARGE_LIMIT=70,80)"
grep -q 'ENV{CHARGE_LIMIT}="70,80"' "$INSTALL_SH" \
  || fail "61-thinkpad-charge-limit.rules must export CHARGE_LIMIT=70,80"
grep -q '71-thinkpad-t14s-touchpad-wakeup.rules' "$INSTALL_SH" \
  || fail "must install 71-thinkpad-t14s-touchpad-wakeup.rules"
grep -q 'i2c-ELAN0678:\*|i2c-SYNA8018:\*' "$INSTALL_SH" \
  || fail "touchpad wakeup rule must match ELAN0678 and SYNA8018"
# Functional check: extract /etc/makepkg.conf.d/t14s.conf and /usr/local/bin/t14s-selftest
_mkconf="$(awk '/^cat > \/etc\/makepkg\.conf\.d\/t14s\.conf <<\x27EOF\x27$/{f=1;next} f&&/^EOF$/{exit} f' "$INSTALL_SH")"
[[ -n $_mkconf ]] || fail "could not extract makepkg.conf.d/t14s.conf heredoc"
bash -c '
  set -euo pipefail
  CFLAGS="-march=x86-64 -mtune=generic -O2"
  CXXFLAGS="-march=x86-64 -mtune=generic -O2"
  RUSTFLAGS="-C opt-level=2"
  eval "$1"
  [[ $CFLAGS == "-march=x86-64-v3 -O2" ]] || exit 11
  [[ $CXXFLAGS == "-march=x86-64-v3 -O2" ]] || exit 12
  [[ $RUSTFLAGS == "-C opt-level=2 -C target-cpu=x86-64-v3" ]] || exit 13
  [[ $GOAMD64 == "v3" ]] || exit 14
' _ "$_mkconf" || fail "makepkg.conf.d/t14s.conf runtime flag rewrite failed"
unset -v _mkconf
_stbody="$(awk '/cat > \/usr\/local\/bin\/t14s-selftest <<\x27ST\x27$/{f=1;next} f&&/^ST$/{exit} f' "$INSTALL_SH")"
[[ -n $_stbody ]] || fail "could not extract t14s-selftest heredoc"
bash -n <<<"$_stbody" || fail "t14s-selftest bash -n failed"
grep -qE '^check .*\|' <<<"$_stbody" \
  && fail "t14s-selftest must not pipe check() into another command (subshell loses ok/bad counter)" || true
unset -v _stbody
grep -q 'thinkpad-charge-thresholds.conf' "$INSTALL_SH" \
  || fail "must install charge threshold tmpfiles"
grep -q 'charge_control_start_threshold - - - - 70' "$INSTALL_SH" \
  || fail "charge tmpfiles must set start 70"
grep -q 'charge_control_end_threshold - - - - 80' "$INSTALL_SH" \
  || fail "charge tmpfiles must set end 80"
grep -q 'thinkpad-charge-thresholds.service' "$INSTALL_SH" \
  || fail "must ship charge oneshot after multi-user"
grep -q 'After=multi-user.target' "$INSTALL_SH" \
  || fail "charge oneshot must After=multi-user.target"
grep -q 'apply-charge-thresholds.sh' "$INSTALL_SH" \
  || fail "must install apply-charge-thresholds.sh"
grep -qF '/usr/local/lib/thinkpad/apply-charge-thresholds.sh' "$INSTALL_SH" \
  || fail "charge apply path must be /usr/local/lib/thinkpad/ (dotfiles parity)"
grep -q '/usr/local/lib/t14s/' "$INSTALL_SH" \
  && fail "must not use legacy /usr/local/lib/t14s/" || true
# set -e / ERR: top-level functions must not end on a bare failing && list.
python3 - "$INSTALL_SH" <<'PY' || fail "top-level function ends with failing && (set -e hazard)"
from pathlib import Path
import re, sys
t = Path(sys.argv[1]).read_text().splitlines()
# Stop before chroot deploy (chroot helpers live in lib/80, different rules).
cut = next((i for i, ln in enumerate(t) if "80-chroot-setup.sh" in ln and "deploy" in ln.lower() or ln.strip().endswith("80-chroot-setup.sh")), len(t))
# Prefer explicit deploy marker if present.
for i, ln in enumerate(t):
    if "_deploy_lib 80-chroot-setup.sh" in ln or ln.startswith("cat > /mnt/root/chroot-setup.sh"):
        cut = i
        break
t = t[:cut]
bad = []
i = 0
while i < len(t):
    m = re.match(r'^([a-zA-Z_][a-zA-Z0-9_]*)\(\)\s*\{', t[i])
    if not m:
        i += 1
        continue
    name, depth, start = m.group(1), 0, i
    for j in range(i, len(t)):
        depth += t[j].count('{') - t[j].count('}')
        if j > i and depth <= 0:
            last = None
            for ln in reversed(t[start:j]):
                s = ln.strip()
                if not s or s.startswith('#'):
                    continue
                last = s
                break
            # Hazard: last stmt is &&-list without || / return (function status = 1).
            if (last and '&&' in last and '||' not in last
                    and not last.startswith('return')
                    and not re.search(r'&&\s*return\b', last)):
                bad.append(f'{name}:{start+1} last={last}')
            i = j + 1
            break
    else:
        i += 1
if bad:
    raise SystemExit('&&-tailed functions:\n  ' + '\n  '.join(bad))
print('ok no &&-tailed top-level functions')
PY
grep -qF '_host_short=${HOSTNAME%%.*}' "$INSTALL_SH" \
  || fail "FQDN hostname must derive short label"
grep -qF '127.0.1.1 ${HOSTNAME} ${_host_short}' "$INSTALL_SH" \
  || fail "FQDN hosts entry must list FQDN before short name"

# reflector rate-sort must be concurrency + time bounded, or a few dead mirrors
# serialize into a multi-minute blank screen
grep -q -- '--sort rate' "$INSTALL_SH" || fail "reflector rate sort missing"
grep -q 'timeout [0-9]* reflector' "$INSTALL_SH" || fail "live reflector run must have an overall timeout"
grep -q -- '--threads 5' "$INSTALL_SH" || fail "reflector ranking must be concurrent"

# TUI: backend bootstrap + semantic helpers must exist, plus plain fallback
grep -q '### Controls' "$ROOT/README.md" || fail "README must document TUI controls"
grep -q '### Safety model' "$ROOT/README.md" || fail "README must document the safety model"
grep -q 'command -v whiptail' "$INSTALL_SH" || fail "must detect whiptail"
grep -q 'command -v dialog' "$INSTALL_SH" || fail "must detect/install dialog"
grep -q -- '--passwordbox' "$INSTALL_SH" || fail "passwords must use a TUI prompt"
grep -q 'ui_yesno' "$INSTALL_SH" || fail "choices must use ui_yesno"
grep -q 'T14S_DRYRUN' "$INSTALL_SH" || fail "must keep a dry-run stop point"
grep -q 'run_progress' "$INSTALL_SH" || fail "must define run_progress for live pacstrap output"
grep -q 'run_gauge "pacstrap' "$INSTALL_SH" \
  || fail "pacstrap must use run_gauge (percent gauge, live on plain TTY)"
grep -q 'run_gauge "chroot config' "$INSTALL_SH" \
  || fail "chroot must use run_gauge"

# progress_filter: pacman/curl/stage lines → monotonic gauge percent per band
python3 - "$CHROOT_SH" <<'PY' || fail "chroot stage markers must be ascending, 0→100, contiguous"
import re, sys
t = open(sys.argv[1]).read()
st = [(int(a), int(b)) for a, b in re.findall(r'^stage (\d+) (\d+) "', t, re.M)]
assert len(st) >= 8, st
assert st[0][0] == 0 and st[-1][1] == 100, st
for (a, b), (c, d) in zip(st, st[1:]):
    assert a < b and b == c, (a, b, c, d)
print('ok chroot stage markers')
PY
_pf_out="$(bash -c '
  eval "$(sed -n "/^ui_bar()/,/^}/p" "$1")"
  eval "$(sed -n "/^progress_filter()/,/^}/p" "$1")"
  LOG=/dev/null W=72
  { printf "Packages (2) a-1 b-1\n"
    printf " a-1-x86_64.pkg.tar.zst downloading...\n"
    printf " a-1-x86_64.pkg.tar.zst downloading...\n"
    printf "(1/2) checking keys in keyring\n(2/2) installing b\n(1/1) Updating initcpios...\n"
    printf "@@STAGE 34 72 GNOME\n(100/100) installing gnome-shell\n"
  } | progress_filter 0 100 gauge step | awk "p==\"XXX\" && /^[0-9]+\$/{print} {p=\$0}"
' _ "$INSTALL_SH")"
[[ "$(printf '%s\n' "$_pf_out" | tr '\n' ' ')" == "0 20 40 45 95 99 34 70 " ]] \
  || fail "progress_filter percents wrong: $(printf '%s\n' "$_pf_out" | tr '\n' ' ')"
echo "ok progress_filter percents"

# progress_filter edge cases: VerbosePkgLists header, footer hint on every
# caption, plain text mode (raw passthrough + stage marker rewrite).
_pf_edge="$(bash -c '
  eval "$(sed -n "/^ui_bar()/,/^}/p" "$1")"
  eval "$(sed -n "/^progress_filter()/,/^}/p" "$1")"
  LOG=/dev/null W=72 LC_ALL=C
  printf "Package (2)  New Version\n b-1-any.pkg.tar.zst downloading...\n" \
    | progress_filter 0 100 gauge step "HINT-LINE" | tr "\n" "|"
  echo
  printf "@@STAGE 34 72 GNOME\nraw line\n" | progress_filter 0 100 text step
' _ "$INSTALL_SH")"
grep -Fq '|20|step|[####----------------]||working…|downloading packages (1/2)||HINT-LINE|XXX|' <<<"$_pf_edge" \
  || fail "progress_filter: VerbosePkgLists header or caption hint broken: $_pf_edge"
[[ $(grep -c 'HINT-LINE' <<<"$(tr '|' '\n' <<<"$_pf_edge")") == 2 ]] \
  || fail "progress_filter: hint must be on every gauge caption"
grep -qx '>> \[34%\] GNOME' <<<"$_pf_edge" || fail "text mode must rewrite @@STAGE markers"
grep -qx 'raw line' <<<"$_pf_edge" || fail "text mode must pass raw lines through"
echo "ok progress_filter edge cases"

# run_gauge end-to-end against a stub dialog in a pty: --gauge args, start %,
# caption stream, and the command's exit status passed back.
if command -v script >/dev/null 2>&1; then
  _rg="$(mktemp -d)"
  mkdir -p "$_rg/bin"
  cat >"$_rg/bin/dialog" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$RG_DIR/args"
cat >"$RG_DIR/stdin"
STUB
  chmod +x "$_rg/bin/dialog"
  cat >"$_rg/run.sh" <<'RUN'
set -euo pipefail
src=$1
# First top-level definition only (chroot heredoc redefines say() inline).
for fn in say _tty ui_bar ui_backtitle tui progress_banner progress_filter run_gauge; do
  eval "$(awk -v f="$fn" '
    !p && index($0, f "()") == 1 { p = 1; if ($0 ~ /\}[[:space:]]*$/) { print; exit } }
    p { print } p && /^\}/ { exit }' "$src")"
done
UI=dialog LOG="$RG_DIR/log" W=72 LOGGING=0 APP_TITLE=t c0= cB=
rc=0
run_gauge "step label" 34 72 bash -c 'printf "(1/2) installing a\n"; exit 7' || rc=$?
echo "rc=$rc" >"$RG_DIR/rc"
RUN
  RG_DIR="$_rg" PATH="$_rg/bin:$PATH" script -qec "bash $_rg/run.sh $INSTALL_SH" /dev/null \
    >/dev/null 2>&1 || true
  grep -qx 'rc=7' "$_rg/rc" 2>/dev/null || fail "run_gauge must return the command exit status"
  grep -qx -- '--gauge' "$_rg/args" || fail "run_gauge must call dialog --gauge"
  [[ $(tail -n 3 "$_rg/args" | tr '\n' ' ') == "16 72 34 " ]] \
    || fail "run_gauge geometry/start % wrong: $(tail -n 3 "$_rg/args" | tr '\n' ' ')"
  grep -qx 'installing a (1/2)' "$_rg/stdin" || fail "run_gauge must stream captions to dialog"
  grep -q 'tail -f' "$_rg/stdin" || fail "run_gauge captions must keep the tail -f hint"
  grep -qx '(1/2) installing a' "$_rg/log" || fail "run_gauge must append raw output to LOG"
  rm -rf "$_rg"
  echo "ok run_gauge stub dialog"
else
  echo "SKIP: run_gauge pty test (no script(1))"
fi

# Palette readability on the 8-colour Linux console (ISO):
#   dialogrc: no BLACK foreground with highlight ON (renders dark grey)
#   newt:     no bright/"yellow"/"white" background; only S-Lang colour names
python3 - "$INSTALL_SH" <<'PY' || fail "TUI palette breaks console readability rules"
import re, sys
t = open(sys.argv[1]).read()
bad = re.findall(r'\(BLACK,[A-Z]+,ON\)', t)
assert not bad, f'bold BLACK fg: {bad}'
names = {'black','red','green','brown','blue','magenta','cyan','lightgray','gray',
         'brightred','brightgreen','yellow','brightblue','brightmagenta','brightcyan','white',''}
dim_bg = {'black','red','green','brown','blue','magenta','cyan','lightgray',''}
for blk in re.findall(r"^NEWT_COLORS_[A-Z]+='\n(.*?)\n'", t, re.S | re.M):
    for ln in blk.splitlines():
        k, _, v = ln.partition('=')
        fg, _, bg = v.partition(',')
        assert fg in names and bg in names, f'unknown S-Lang colour: {ln}'
        if k not in ('emptyscale', 'fullscale'):
            assert bg in dim_bg, f'bright background (console cannot show): {ln}'
assert 'NEWT_COLORS="${NEWT_COLORS_BASE}${TUI_NEWT:-}"' in t, 'severity overlays must extend base'
print('ok TUI palette rules')
PY
grep -q 'ui_view_log' "$INSTALL_SH" || fail "must offer ui_view_log"
grep -q 'ui_checklist' "$INSTALL_SH" || fail "must offer ui_checklist multi-select"
grep -q 'ui_info' "$INSTALL_SH" || fail "must define ui_info"
grep -q 'ui_warn' "$INSTALL_SH" || fail "must define ui_warn"
grep -q 'ui_error' "$INSTALL_SH" || fail "must define ui_error"
grep -q 'ui_critical' "$INSTALL_SH" || fail "must define ui_critical"
grep -q 'ui_ok' "$INSTALL_SH" || fail "must define ui_ok"
grep -q 'write_dialogrc' "$INSTALL_SH" || fail "must ship dialogrc theme"
grep -q 'DIALOG_RC_CRITICAL' "$INSTALL_SH" || fail "must ship per-severity dialogrc"
grep -q 'NEWT_COLORS_CRITICAL' "$INSTALL_SH" || fail "must ship severity NEWT palettes"
grep -q 'NEWT_COLORS_OK' "$INSTALL_SH" || fail "must ship green OK NEWT palette"
grep -q 'msg_height' "$INSTALL_SH" || fail "must scale msgbox height with content"
grep -q 'TUI_KEEP_STDIN=1' "$INSTALL_SH" || fail "progressbox must keep pipe stdin"
grep -q 'ui_critical' "$INSTALL_SH" && grep -A20 '^die()' "$INSTALL_SH" | grep -q 'ui_critical' \
  || fail "die must show ui_critical"
grep -q '\[severity\]' "$INSTALL_SH" || fail "ui_yesno must document severity arg"
grep -q '\[ERROR\]' "$INSTALL_SH" || fail "plain yesno must label error distinctly from critical"
grep -q 'log "View install log" off' "$INSTALL_SH" || fail "checklist must offer log entry"
grep -q -- '--colors' "$INSTALL_SH" || fail "dialog must enable --colors"
grep -q 'Message severity' "$ROOT/README.md" || fail "README must document message severity"
grep -q 'per-severity' "$ROOT/README.md" || fail "README must note per-severity dialogrc/NEWT"
grep -q 'ui_step' "$INSTALL_SH" || fail "wizard must set ui_step progress"
grep -q 'ui_backtitle' "$INSTALL_SH" || fail "tui must use dynamic backtitle"
grep -q '^ui_bar()' "$INSTALL_SH" || fail "must define ui_bar for step/gauge strips"
grep -q 'ui_bar' "$INSTALL_SH" && awk '/^ui_backtitle\(\)/,/^}/' "$INSTALL_SH" | grep -q 'ui_bar' \
  || fail "ui_backtitle must show a step bar via ui_bar"
grep -q 'ui_bar' "$ROOT/lib/steps/02-welcome.sh" \
  || fail "welcome must show a step bar in the destroy warn"
# ui_bar shapes (UTF-8 + C locale)
_bar_c="$(bash -c 'eval "$(sed -n "/^ui_bar()/,/^}/p" "$1")"; LC_ALL=C ui_bar 40 10' _ "$INSTALL_SH")"
[[ $_bar_c == '[####------]' ]] || fail "ui_bar C 40%: got $_bar_c"
_bar_u="$(bash -c 'eval "$(sed -n "/^ui_bar()/,/^}/p" "$1")"; LC_ALL=en_US.UTF-8 ui_bar 50 10' _ "$INSTALL_SH")"
[[ $_bar_u == '[█████░░░░░]' ]] || fail "ui_bar UTF-8 50%: got $_bar_u"
unset -v _bar_c _bar_u
grep -q 'gauge_color = (CYAN,BLUE,ON)' "$INSTALL_SH" \
  || fail "dialog gauge fill must be CYAN on BLUE"
grep -q 'ui_fold' "$INSTALL_SH" || fail "messages must fold prose"
grep -q '_tui_btns' "$INSTALL_SH" || fail "must set Next/Abort/Erase button labels"
grep -q 'erase_yesno' "$INSTALL_SH" || fail "wipe confirms need erase_yesno buttons"
grep -q 'critical_yesno' "$INSTALL_SH" || fail "hard gates need critical_yesno buttons"
grep -q 'TUI_STEPS=11' "$INSTALL_SH" || fail "wizard must declare 11 steps"
grep -q 'not color-only' "$ROOT/README.md" || fail "README must note a11y severity badges"
grep -q 'Next' "$ROOT/README.md" || fail "README Controls must document Next button"
grep -q 'ui_yesno` only' "$ROOT/README.md" \
  || fail "README must mark erase/critical confirms as ui_yesno-only"
grep -q 'NONINTERACTIVE: skipping welcome TUI' "$INSTALL_SH" \
  || fail "NONINTERACTIVE must skip welcome TUI"
grep -q 'choose 1-\$i (empty=1)' "$INSTALL_SH" \
  || fail "plain menu must not claim Ctrl-C is Esc"
grep -q -- '--progressbox' "$INSTALL_SH" || fail "dialog progressbox for live steps"
# Button roles: wipe uses erase; DMI/hook hard gates use critical (not Erase).
# Non-spanning parse: one quoted prompt per ui_yesno (no nested " inside prompts).
python3 - "$INSTALL_SH" <<'PY' || fail "yesno button roles must separate erase vs continue"
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
assert "Hardware profile" in t and "ThinkPad P15 Gen 1" in t, "must offer HW_PROFILE radio"
warns = [(p, d, s) for p, d, s in calls if s == "warn"]
assert any("AuthenticAMD" in p for p, _, _ in warns), "T14s CPU mismatch must use warn"
assert any("GenuineIntel" in p for p, _, _ in warns), "P15 CPU mismatch must use warn"
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
python3 - "$INSTALL_SH" <<'PY' || fail "progressbox must use TUI_KEEP_STDIN around tui"
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
grep -q 'log "View install log"' "$INSTALL_SH" \
  || fail "menus must expose log viewer entry"
grep -q 'sshd "Enable SSH' "$INSTALL_SH" \
  || fail "checklist must offer sshd option"
grep -q 'pick_keymap' "$INSTALL_SH" || fail "must offer archfi-style keymap picker"
grep -q 'pick_timezone' "$INSTALL_SH" || fail "must offer archfi-style timezone picker"
grep -q 'pt-latin1' "$INSTALL_SH" || fail "common keymaps must use real map names"
grep -q 'br-abnt2' "$INSTALL_SH" || fail "common keymaps must use real map names"
grep -q 'jp106' "$INSTALL_SH" || fail "common keymaps must use real map names"
grep -q 'browse_args' "$INSTALL_SH" || fail "keymap browse must not clobber commons menu"
grep -q "s/\\\\.map(\\\\.gz)?\\$//" "$INSTALL_SH" \
  || grep -q 's/\.map(\.gz)?$//' "$INSTALL_SH" \
  || fail "keymap browse must strip .map/.map.gz only (not %%.*)"
! grep -q 'km=\${f%%\.\*}' "$INSTALL_SH" \
  || fail "keymap browse must not use \${f%%.*}"
grep -qF '/usr/share/zoneinfo/$tz' "$INSTALL_SH" \
  || fail "timezone validator must resolve under /usr/share/zoneinfo"
grep -qF 'valid_timezone "$TIMEZONE"' "$INSTALL_SH" \
  || fail "identity step must call valid_timezone"
grep -qF 'valid_hostname "$HOSTNAME"' "$INSTALL_SH" \
  || fail "identity step must call valid_hostname"
grep -qF 'valid_locale "$LOCALE"' "$INSTALL_SH" \
  || fail "identity step must call valid_locale"
grep -qF 'valid_keymap "$KEYMAP"' "$INSTALL_SH" \
  || fail "identity step must call valid_keymap"
grep -qF 'valid_username "$USERNAME"' "$INSTALL_SH" \
  || fail "identity step must call valid_username"
grep -qF 'T14S_IDENTITY_OVERRIDES' "$INSTALL_SH" \
  || fail "fixture overrides must be gated on T14S_IDENTITY_OVERRIDES"
grep -qF 'cannot pick a timezone' "$INSTALL_SH" \
  || fail "pick_timezone must not invent UTC when zoneinfo is missing"
grep -q 'LUKS_WIPE' "$INSTALL_SH" || fail "must offer optional LUKS mapper wipe"
grep -q 'PACMAN_PARALLEL' "$INSTALL_SH" || fail "must offer ParallelDownloads choice"
# pacman_tune: behaviour on a stock-style pacman.conf (live ISO + target).
_pt="$(mktemp)"
cat >"$_pt" <<'CONF'
[options]
XferCommand = /usr/bin/curl -fL -C - -o %o %u
#Color
#VerbosePkgLists
#ParallelDownloads = 5
[core]
Include = /etc/pacman.d/mirrorlist
#[multilib-testing]
#Include = /etc/pacman.d/mirrorlist
#[multilib]
#Include = /etc/pacman.d/mirrorlist
CONF
bash -c 'eval "$(sed -n "/^pacman_tune()/,/^}/p" "$1")"; pacman_tune "$2" 15 Y; pacman_tune "$2" 15 Y' \
  _ "$INSTALL_SH" "$_pt" || fail "pacman_tune failed"
grep -q '^XferCommand' "$_pt" && fail "pacman_tune must drop XferCommand (serializes downloads)" || true
grep -qx 'ParallelDownloads = 15' "$_pt" || fail "pacman_tune must set ParallelDownloads"
for _k in Color ILoveCandy VerbosePkgLists DisableDownloadTimeout '\[multilib\]'; do
  [[ $(grep -c "^${_k}\$" "$_pt") == 1 ]] || fail "pacman_tune: expected exactly one ${_k} (idempotent)"
done
grep -q '^#\[multilib-testing\]' "$_pt" || fail "pacman_tune must not enable [multilib-testing]"
[[ $(grep -c '^Include' "$_pt") == 2 ]] || fail "pacman_tune: only [multilib] Include uncommented"
rm -f "$_pt"; unset -v _pt _k
grep -qE '^[^#]*XferCommand = ' "$INSTALL_SH" \
  && fail "installer must not add an XferCommand" || true
grep -q 'declare -f pacman_tune >/mnt/root/t14s-lib.sh' "$INSTALL_SH" \
  || fail "chroot must reuse host pacman_tune (no duplicate body)"
echo "ok pacman_tune"

# Chroot pkg_try: failure records pacman's own error line; key errors refresh
# archlinux-keyring and retry once. Stub pacman on PATH.
_pk="$(mktemp -d)"
mkdir -p "$_pk/bin"
cat >"$_pk/bin/pacman" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PK_DIR/calls"
# Real pacman prints this on every install attempt (success or not).
echo "(1/1) checking keys in keyring"
case "$*" in
  *archlinux-keyring*) touch "$PK_DIR/refreshed"; exit 0 ;;
  *keyfail*) [[ -f $PK_DIR/refreshed ]] && exit 0
             echo "error: keyfail: signature from \"X\" is unknown trust"; exit 1 ;;
  *broken*) echo ":: downloading broken..."; echo "error: failed to commit transaction (conflicting files)"; exit 1 ;;
  *keychain*) echo "error: target not found: keychain"; exit 1 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$_pk/bin/pacman"
_chroot_body="$(cat "$CHROOT_SH")"
PK_DIR="$_pk" PATH="$_pk/bin:$PATH" bash -c '
  set -euo pipefail
  eval "$(printf "%s\n" "$1" | awk "/^WARN_FILE=/{f=1} f; /^source \\/root\\/t14s-lib.sh/{exit}" | grep -v "^source ")"
  WARN_FILE=$2/warn
  # Key case first: its refresh must be the ONLY keyring call; a later
  # non-key failure must not trigger another one.
  pkg_try "Key set" keyfail >/dev/null || exit 22
  pkg_try "Broken set" broken >/dev/null && exit 21
  pkg_try "Name with key" keychain >/dev/null && exit 24
  pkg_try "Fine set" fine >/dev/null || exit 23
' _ "$_chroot_body" "$_pk" || fail "pkg_try behaviour wrong (rc=$?)"
grep -qx 'Broken set install failed (pacman exit 1): error: failed to commit transaction (conflicting files)' "$_pk/warn" \
  || fail "pkg_try must record pacman's error line: $(cat "$_pk/warn" 2>/dev/null)"
grep -q 'archlinux-keyring' "$_pk/calls" || fail "pkg_try must refresh archlinux-keyring on key errors"
grep -q 'Key set' "$_pk/warn" && fail "key error fixed by refresh must not warn" || true
[[ $(grep -c 'archlinux-keyring' "$_pk/calls") == 1 ]] \
  || fail "only the key error may trigger a keyring refresh (not 'checking keys in keyring' noise)"
grep -qx -- '-Su --noconfirm' "$_pk/calls" || fail "keyring refresh must be followed by -Su (no partial upgrade)"
rm -rf "$_pk"; unset -v _pk _chroot_body
echo "ok pkg_try"

# New option flags are wired end to end (answers, canonicalize, chroot env).
for _fl in INSTALL_MULTILIB INSTALL_YAY INSTALL_TUNED INSTALL_DEVTOOLS INSTALL_BTRFS_ASSISTANT \
           INSTALL_OLLAMA FW_SYNCTHING FW_KDECONNECT; do
  python3 - "$INSTALL_SH" "$_fl" <<'PY' || fail "flag $_fl not wired everywhere"
import re, sys
t = open(sys.argv[1]).read(); f = sys.argv[2]
keys = t[t.index('ANSWERS_KEYS=('):t.index(')', t.index('ANSWERS_KEYS=('))]
assert f in keys.split(), 'ANSWERS_KEYS'
# Tokenize the yn_canon for-list (stop at newline+do), not substring 'do' in names.
start = t.index('for _flag in DESKTOP')
end = t.index('\ndo\n', start)
canon = t[start:end]
assert f in canon.split(), 'yn_canon loop'
env = t[t.index('arch-chroot /mnt env'):t.index('bash /root/chroot-setup.sh', t.index('arch-chroot /mnt env'))]
assert f'{f}="${f}"' in env, 'chroot env'
if f.startswith('FW_'):
  assert f'{f}:=' in t, 'default'
else:
  assert f'${{{f}:=N}}' in t, 'default'
PY
done
unset -v _fl
grep -q 'tuned tuned-ppd' "$INSTALL_SH" || fail "GNOME + tuned must install tuned-ppd (replaces PPD)"
grep -q 'tlp conflicts with tuned' "$INSTALL_SH" || fail "tuned must force TLP off"
grep -q 'runuser -u "$USERNAME" -- git clone --depth 1 https://aur.archlinux.org/yay-bin.git' "$INSTALL_SH" \
  || fail "yay must be built as the user (makepkg refuses root)"
grep -vE '^\s*#' "$INSTALL_SH" | grep -q 'NOPASSWD' \
  && fail "installer must not grant sudoers NOPASSWD" || true
grep -q 'rtkit evolution-data-server' "$INSTALL_SH" || fail "GNOME needs rtkit + evolution-data-server"
grep -qE '^[[:space:]]+wireless-regdb$' "$INSTALL_SH" || fail "base needs wireless-regdb (regulatory.db)"
grep -q 'install -m 600 "$LOG" /mnt/var/log/t14s-install.log' "$INSTALL_SH" \
  || fail "install log must be kept on the target"
grep -q 'INSTALL COMPLETE with warnings' "$INSTALL_SH" || fail "finish screen must surface warnings"
# Flatpak apps are deferred to a first-boot oneshot (not downloaded in chroot).
_chr="$(cat "$CHROOT_SH")"
grep -qE '^\s*flatpak install --system .*\$\{_fp_apps' <<<"$_chr" \
  && fail "chroot must not download Flatpak apps (first-boot service does)" || true
grep -q 'systemctl enable NetworkManager-wait-online.service t14s-flatpak-apps.timer' <<<"$_chr" \
  || fail "first-boot flatpak timer + wait-online must be enabled"
# The retrying oneshot must not be WantedBy a target: targets order After= their
# wants, so boot would stay "starting" until Flatpak downloads succeed (VM test).
_fpsvc="$(awk '/cat > \/etc\/systemd\/system\/t14s-flatpak-apps.service/{f=1;next} f&&/^FP$/{exit} f' <<<"$_chr")"
[[ -n $_fpsvc ]] || fail "could not extract t14s-flatpak-apps.service"
! grep -qE '^\[Install\]|^WantedBy=' <<<"$_fpsvc" \
  || fail "flatpak oneshot must not be WantedBy a target (start it from the timer)"
_fptmr="$(awk '/cat > \/etc\/systemd\/system\/t14s-flatpak-apps.timer/{f=1;next} f&&/^FP$/{exit} f' <<<"$_chr")"
grep -qx 'OnBootSec=1min' <<<"$_fptmr" && grep -qx 'WantedBy=timers.target' <<<"$_fptmr" \
  || fail "flatpak timer must fire OnBootSec and be WantedBy timers.target"
grep -q 'TimeoutStartSec=30min' <<<"$_chr" || fail "flatpak oneshot timeout must be 30min"
grep -q 'ConditionPathExists=!/var/lib/t14s/flatpak-apps.done' <<<"$_chr" || fail "flatpak service must be one-shot (stamp)"
grep -q 'Restart=on-failure' <<<"$_chr" || fail "flatpak service must retry until online"
grep -q 'SNAP_PAC_SKIP=y' "$INSTALL_SH" || fail "chroot run must set SNAP_PAC_SKIP=y"
[[ $(grep -c 'NUMBER_LIMIT=10' <<<"$_chr") == 2 ]] || fail "snapper root and home must both set NUMBER_LIMIT=10"
unset -v _chr
echo "ok option wiring"

# No full-screen colour flashes: one backdrop for every severity; newt
# overlays never recolour root/window.
python3 - "$INSTALL_SH" <<'PY' || fail "TUI backdrop must be constant across severities"
import re, sys
t = open(sys.argv[1]).read()
assert t.count('screen_color = $screen') == 1
assert "local screen='(CYAN,BLUE,ON)'" in t
for blk in re.findall(r"^NEWT_COLORS_(?!BASE)[A-Z]+='\n(.*?)\n'", t, re.S | re.M):
    for ln in blk.splitlines():
        assert ln.split('=')[0] in ('border', 'title'), ln
print('ok constant TUI backdrop')
PY
grep -q 'skip_reflector' "$INSTALL_SH" || fail "checklist must offer skip reflector"
grep -q 'INSTALL_CUPS' "$INSTALL_SH" || fail "must offer archdi-style CUPS option"
grep -q 'nerd_fonts' "$INSTALL_SH" || fail "checklist must offer nerd_fonts"
grep -q 'ttf-jetbrains-mono-nerd' "$INSTALL_SH" || fail "must install JetBrains Mono Nerd"
grep -q 'ttf-meslo-nerd' "$INSTALL_SH" || fail "must install Meslo Nerd"
grep -q 'ttf-nerd-fonts-symbols-common' "$INSTALL_SH" || fail "must install nerd symbols"
grep -q 'INSTALL_NERD_FONTS' "$INSTALL_SH" || fail "must gate nerd fonts install"
grep -A20 'arch-chroot /mnt env' "$INSTALL_SH" | grep -q 'INSTALL_NERD_FONTS=' \
  || fail "arch-chroot env must pass INSTALL_NERD_FONTS"
grep -q 'answers_save' "$INSTALL_SH" || fail "must save T14S answers file"
grep -q 'answers_load' "$INSTALL_SH" || fail "must load T14S_ANSWERS"
grep -q 'T14S_NONINTERACTIVE' "$INSTALL_SH" || fail "must honor T14S_NONINTERACTIVE"
grep -q 'Install profile' "$INSTALL_SH" || fail "must offer gnome/dev/minimal presets"
grep -q 'smartctl -H' "$INSTALL_SH" || fail "must SMART-check target disk"
grep -q 'INSTALL_CLI' "$INSTALL_SH" || fail "must offer CLI tools bundle"
grep -q 'INSTALL_PODMAN' "$INSTALL_SH" || fail "must offer podman"
grep -q 'INSTALL_DOCKER' "$INSTALL_SH" || fail "must offer docker"
grep -q 'INSTALL_VIRT' "$INSTALL_SH" || fail "must offer libvirt/qemu"
grep -q 'INSTALL_AVAHI' "$INSTALL_SH" || fail "must offer avahi"
grep -q 'INSTALL_STARSHIP' "$INSTALL_SH" || fail "must offer starship"
grep -q 'POST_HOOK_URL' "$INSTALL_SH" || fail "must offer post-install hook URL"
grep -q 'prefer-dark' "$INSTALL_SH" || fail "must ship GNOME dark dconf defaults"
grep -q 'JetBrainsMono Nerd Font' "$INSTALL_SH" || fail "must set Console Nerd Font"
grep -q 'install-chrome-flatpak.sh' "$INSTALL_SH" || fail "must offer Chrome helper script"
grep -q 'arch-chroot /mnt' "$INSTALL_SH" || fail "recovery docs / hook must mention arch-chroot"
grep -q 'Core extras' "$INSTALL_SH" || fail "must split Core checklist"
grep -q 'Dev / CLI tools' "$INSTALL_SH" || fail "must split Dev/CLI checklist"
grep -q 'Network / security' "$INSTALL_SH" || fail "must split Network checklist"
grep -q 'yn_on "\$DESKTOP"' "$INSTALL_SH" || fail "TLP guard must use yn_on"
grep -q 'pipefail' "$INSTALL_SH" || fail "post-hook must use pipefail"
grep -qE '\^https://' "$INSTALL_SH" \
  || fail "post-hook must require https:// URL (fail closed)"
grep -q 'T14S_POST_HOOK_SHA256' "$INSTALL_SH" \
  || fail "post-hook must support optional T14S_POST_HOOK_SHA256 pin"
grep -q 'T14S_POST_HOOK_I_UNDERSTAND' "$INSTALL_SH" \
  || fail "post-hook NONINTERACTIVE must require explicit opt-in"
grep -q 'mdns_minimal' "$INSTALL_SH" || fail "avahi path must patch nsswitch mdns_minimal"
grep -q 'jail.d/sshd.local' "$INSTALL_SH" || fail "fail2ban must enable sshd jail"
grep -q 'banaction = firewallcmd-rich-rules' "$INSTALL_SH" || fail "fail2ban must ban through firewalld"
grep -q 'systemd-tmpfiles-clean.timer systemd-timesyncd.service' "$INSTALL_SH" || fail "installed system must enable systemd-timesyncd"
grep -q 'using DISK from answers' "$INSTALL_SH" \
  || fail "NONINTERACTIVE must honor DISK from answers"
grep -q 'timezone from answers' "$INSTALL_SH" \
  || fail "NONINTERACTIVE must honor TIMEZONE from answers"
grep -q 'T14S_PASS_FILE' "$INSTALL_SH" || fail "must support T14S_PASS_FILE"
grep -q 'secrets_load' "$INSTALL_SH" || fail "must define secrets_load"
grep -q 'MANUAL partitions from answers' "$INSTALL_SH" \
  || fail "NONINTERACTIVE MANUAL must honor EFI_PART/ROOT_PART"
grep -q 'SKIP_THINKPAD_HW' "$INSTALL_SH" || fail "must detect/skip ThinkPad HW on VM"
grep -q 'INSTALL_SNAPPER_HOME' "$INSTALL_SH" || fail "must offer snapper home"
grep -q 'ESP free after UKI\|ESP nearly full after UKI' "$INSTALL_SH" \
  || fail "must check ESP free space after UKI build"
grep -q 'sbctl verify' "$INSTALL_SH" || fail "must run sbctl verify"
grep -q 'enroll skipped — sbctl verify failed' "$INSTALL_SH" \
  || fail "must block enroll when sbctl verify fails"
grep -q 't14s-selftest' "$INSTALL_SH" || fail "must offer BT/audio self-test"
grep -q 'BTRFS_COMPRESS' "$INSTALL_SH" || fail "must offer Btrfs compression radio"
grep -q 'ZRAM_SIZE' "$INSTALL_SH" || fail "must offer zram size radio"
grep -q 'REFLECTOR_COUNTRY' "$INSTALL_SH" || fail "must honor reflector country"
grep -q 'T14S_DEFAULT_HOOK_URL' "$INSTALL_SH" || fail "must offer hook env preset"
grep -q 'xdg-user-dirs-update' "$INSTALL_SH" || fail "must run xdg-user-dirs-update"
grep -q 'INSTALL_LINUX_STABLE' "$INSTALL_SH" || fail "must offer optional linux UKI"
grep -q 'INSTALL_PLYMOUTH' "$INSTALL_SH" || fail "must offer optional plymouth"
grep -q 'Answers schema' "$ROOT/README.md" || fail "README must document answers schema"
grep -q 'NONINTERACTIVE: skipping REVIEW/confirm' "$INSTALL_SH" \
  || fail "NONINTERACTIVE must skip REVIEW/final confirm"
grep -q 'NONINTERACTIVE AUTO: will erase' "$INSTALL_SH" \
  || fail "NONINTERACTIVE must skip AUTO type-DISK wipe confirm"
grep -q 'NONINTERACTIVE requires T14S_PASS_FILE' "$INSTALL_SH" \
  || fail "NONINTERACTIVE must die early without T14S_PASS_FILE"
# Pass-file gate must appear before ui_password for LUKS
python3 - "$INSTALL_SH" <<'PY' || fail "NONINTERACTIVE pass-file die must precede ui_password"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
die_i = t.find("NONINTERACTIVE requires T14S_PASS_FILE")
pw_i = t.find("ui_password 'LUKS passphrase'")
assert die_i > 0 and pw_i > 0 and die_i < pw_i, (die_i, pw_i)
print("ok pass-file die order")
PY
grep -q 'part_on_disk' "$INSTALL_SH" || fail "MANUAL answers must verify part_on_disk"
grep -q 'yn_canon' "$INSTALL_SH" || fail "must canonicalize flags to Y/N"
grep -q 'chmod 600' "$INSTALL_SH" || fail "answers_save / secrets must chmod 600"
grep -q 'must be mode 0600' "$INSTALL_SH" || fail "secrets_load must require mode 0600"
# Chroot body must define yn_on and not leave stray ] after yn_on calls
python3 - "$CHROOT_SH" <<'PY' || fail "chroot yn_on gates broken"
from pathlib import Path
import re, sys, subprocess, tempfile
body = Path(sys.argv[1]).read_text()
assert "yn_on() {" in body, "chroot missing yn_on"
assert not re.search(r'yn_on[^\n]*"\]', body), "stray ] after yn_on"
assert not re.search(r'\$\{(?:INSTALL_|SKIP_|DESKTOP|ENROLL_|ENABLE_|FW_)[A-Z0-9_]*\^\^\}', body), \
    "chroot still uses ^^ on feature flags"
assert "sd-encrypt" in body and "HOOKS missing sd-encrypt" in body
with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
    f.write(body)
    name = f.name
subprocess.check_call(["bash", "-n", name])
print("ok chroot yn_on + bash -n")
PY
grep -q 'xdg-user-dirs' "$INSTALL_SH" || fail "must pacstrap or call xdg-user-dirs"
grep -q 'T14S_I_WILL_ERASE' "$INSTALL_SH" \
  || fail "NONINTERACTIVE wipe must require T14S_I_WILL_ERASE"
grep -q 'no env passwords' "$INSTALL_SH" \
  || fail "NONINTERACTIVE must refuse ambient env passwords"
grep -q 'unset -v LUKS_PASS USER_PASS ROOT_PASS' "$INSTALL_SH" \
  || fail "must unset ambient password env at start"
grep -q 'cannot read mode of T14S_PASS_FILE' "$INSTALL_SH" \
  || fail "secrets_load must fail closed if mode unknown"
grep -q 'EXTRA_PKGS_LIST' "$INSTALL_SH" \
  || fail "must persist EXTRA_PKGS_LIST in answers"
grep -q "v == y || \$v == yes" "$INSTALL_SH" \
  || fail "yn_on must match y/yes/on/1 only"
grep -q "HOOKS=.*sd-encrypt" "$INSTALL_SH" \
  || fail "HOOKS verify must match ^HOOKS=.*sd-encrypt"
grep -q 'NONINTERACTIVE needs DISK=' "$INSTALL_SH" \
  || fail "NONINTERACTIVE missing DISK must die (not TUI)"
grep -q 'NONINTERACTIVE needs MODE=' "$INSTALL_SH" \
  || fail "NONINTERACTIVE missing MODE must die"
# part_on_disk must not accept nvme0n1 vs nvme0n10 via naive prefix
python3 - "$INSTALL_SH" <<'PY' || fail "part_on_disk must bound nvme prefix"
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
grep -q 'CLEAN_ESP_ARCH' "$INSTALL_SH" || fail "must offer CLEAN_ESP_ARCH"
grep -q 'clean_esp_arch_files' "$INSTALL_SH" || fail "must define clean_esp_arch_files"
grep -q 'clean_esp "' "$INSTALL_SH" || fail "Core checklist must offer clean_esp"
grep -q 'EFI/arch' "$INSTALL_SH" || fail "ESP clean must remove EFI/arch vendor dir"
grep -A25 'arch-chroot /mnt env' "$INSTALL_SH" | grep -q 'CLEAN_ESP_ARCH=' \
  || fail "arch-chroot env must pass CLEAN_ESP_ARCH"
grep -q 'CLEAN_ESP_ARCH' "$ROOT/README.md" || fail "README must document CLEAN_ESP_ARCH"
grep -q 'ESP / EFI layout' "$ROOT/README.md" || fail "README must document ESP/EFI layout"
grep -q 'Securing the EFI' "$ROOT/README.md" || fail "README must document EFI securing"
grep -q 'Can everything live under one directory' "$ROOT/README.md" \
  || fail "README must document why EFI is not one directory"
grep -q 'sbctl verify' "$ROOT/README.md" || fail "README must mention sbctl verify"
# NONINTERACTIVE must keep EXTRA_PKGS_LIST replay (not wipe array empty)
python3 - "$INSTALL_SH" <<'PY' || fail "NONINTERACTIVE must not wipe EXTRA_PKGS after answers replay"
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
python3 - "$INSTALL_SH" <<'PY' || fail "interactive must restore EXTRA_PKGS_LIST after checklist"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
assert "_extras_keep=(\"${EXTRA_PKGS[@]}\")" in t or '_extras_keep=("${EXTRA_PKGS[@]}")' in t
assert "EXTRA_PKGS+=(\"${_extras_keep[@]}\")" in t or 'EXTRA_PKGS+=("${_extras_keep[@]}")' in t
print("ok interactive extras keep")
PY
# Loader cleanup must use arch*.conf only (not linux-*.conf)
python3 - "$INSTALL_SH" <<'PY' || fail "ESP clean must not delete linux-*.conf"
from pathlib import Path
import sys, re
t = Path(sys.argv[1]).read_text()
assert "-name 'arch*.conf'" in t or '-name "arch*.conf"' in t
# No find that deletes linux-*.conf
assert not re.search(r"-name 'linux-\*\.conf'", t), "linux-*.conf still deleted"
print("ok arch*.conf only")
PY
grep -q '_env_on' "$INSTALL_SH" || fail "must parse T14S_NONINTERACTIVE / I_WILL_ERASE with yn-style"
grep -q 'DNS labels only' "$INSTALL_SH" || fail "must validate HOSTNAME charset"
grep -q 'yn_on "\$DESKTOP"' "$INSTALL_SH" || fail "finish path must use yn_on DESKTOP"
grep -q 'flatpak install --user -y flathub com.google.Chrome' "$INSTALL_SH" \
  || fail "finish Chrome hint must use --user"
grep -q 'flatpak install --user' "$ROOT/README.md" \
  || fail "README Chrome tip must match helper (--user)"
grep -q 'Setup Mode' "$ROOT/README.md" || fail "README SB enroll must mention Setup Mode"
grep -q 'FORMAT_EFI=1' "$ROOT/README.md" || fail "README must note CLEAN_ESP ignored when formatting"
grep -q 'dead entries' "$INSTALL_SH" || fail "CLEAN_ESP_ARCH=N must warn about dead boot entries"
# umask must not leak into arch-chroot (regression: /etc/locale.conf 0600 → LANG unset).
grep -vE '^\s*#' "$WIZARD_SH" | grep -qE '^umask ' \
  && fail "script-wide umask leaks into arch-chroot; scope it in a subshell" || true
grep -qx 'umask 022' "$CHROOT_SH" \
  || fail "chroot script must pin umask 022"
grep -q 'fmask=0077' "$INSTALL_SH" || fail "ESP fstab must use fmask/dmask=0077 (random-seed)"
# Chroot must not delete pacstrap's kernels/ucode before mkinitcpio -P
# (regression: "'/boot/vmlinuz-linux-lts' must be readable").
awk '/^mkinitcpio -P/{exit} {print}' "$CHROOT_SH" \
  | grep -vE '^\s*#' \
  | grep -qE 'rm .*(/boot/vmlinuz|/boot/(amd|intel)-ucode\.img)' \
  && fail "chroot removes /boot/vmlinuz* or *-ucode.img before mkinitcpio -P" || true
grep -q 'sudo -u "\$USERNAME" tee -a' "$INSTALL_SH" \
  || fail "starship must append zshrc as the user"
! grep -q "gtk-theme='Adwaita-dark'" "$INSTALL_SH" \
  || fail "dconf must not set stale Adwaita-dark gtk-theme"
python3 - "$INSTALL_SH" <<'PY' || fail "JetBrainsMono dconf must be gated on INSTALL_NERD_FONTS"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
i = t.find("monospace-font-name='JetBrainsMono Nerd Font Mono 11'")
assert i > 0, "monospace line missing"
window = t[max(0, i - 400):i]
assert "INSTALL_NERD_FONTS" in window, "JetBrainsMono dconf not under INSTALL_NERD_FONTS gate"
print("ok nerd dconf gate")
PY
grep -q 'yn_on "\$INSTALL_CHROME_HINT"' "$INSTALL_SH" \
  || fail "chrome hint must use yn_on"
grep -q 'set-x11-keymap' "$INSTALL_SH" || fail "GNOME path must set X11 keymap from console map"
grep -q 'XKB_LAYOUT=gb' "$INSTALL_SH" || fail "XKB remap must map uk → gb"
grep -q 'XkbVariant' "$INSTALL_SH" || fail "XKB conf must support variants (dvorak/colemak/abnt2)"
grep -q 'write_xkb_conf\|00-keyboard.conf' "$INSTALL_SH" \
  || fail "must write 00-keyboard.conf when localectl fails"
grep -A6 'arch-chroot /mnt env' "$INSTALL_SH" | grep -q 'INSTALL_CUPS=' \
  || fail "arch-chroot env must pass INSTALL_CUPS"
grep -A6 'arch-chroot /mnt env' "$INSTALL_SH" | grep -q 'PACMAN_PARALLEL=' \
  || fail "arch-chroot env must pass PACMAN_PARALLEL"
grep -q 'bash-completion' "$INSTALL_SH" || fail "must offer archdi console tools"
grep -q 'T14S_EXTRA_PKGS' "$INSTALL_SH" || fail "must honor T14S_EXTRA_PKGS / free-form extras"
grep -q 'locale=%s' "$INSTALL_SH" || fail "DRYRUN dump must include locale"
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
grep -q 'Prefer dialog' "$INSTALL_SH" \
  || grep -A2 'command -v dialog' "$INSTALL_SH" | grep -q 'UI=dialog' \
  || fail "bootstrap must prefer dialog when available"
# Leftover cleanup: only after the final confirm + DRYRUN exit, only on the target.
python3 - "$INSTALL_SH" <<'PY' || fail "leftover cleanup must run after confirmation and be target-scoped"
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
confirm = t.find('"Start the installation? The partitions above will be ERASED."')
dry_exit = t.find("exit 0", t.find("if (( DRYRUN )); then\n  printf 'DRYRUN:"))
release = t.find("release_target_devices", dry_exit)
part = t.find('sgdisk --zap-all "$DISK"')
assert 0 < confirm < dry_exit < release < part, (confirm, dry_exit, release, part)
assert "swapoff -a" not in t, "global swapoff -a must not be used"
# Body lives in lib/40-disk.sh (concatenated into INSTALL_SH for greps).
fn = t.find("release_target_devices() {")
assert fn > 0, "release_target_devices must be defined"
body = t[fn:t.find("\n}", fn) + 2]
assert '_on_target "$_src" || die' in body, "umount /mnt must be gated on the target"
assert 'if _on_target "$_sw"; then swapoff "$_sw"' in body, "swapoff must be per-device on the target"
assert "_on_target /dev/mapper/cryptroot" in body, "cryptroot close must be gated on the target"
print("ok scoped leftover cleanup")
PY

# partitioning: partitions chosen from lists, sizes validated
grep -q 'build_part_menu' "$INSTALL_SH" || fail "partition selector helper missing"
grep -q 'pick_part' "$INSTALL_SH" || fail "partition picker missing"
grep -q 'EFI system partition size' "$INSTALL_SH" || fail "ESP size must be selectable"
grep -q 'lsblk_rows "\$_disk" TYPE PATH' "$INSTALL_SH" || fail "partition list must filter to type=part"
grep -q 'root_mb < 8192' "$INSTALL_SH" || fail "must warn on tiny root"

grep -q 'HelllGuest/t14s-arch-install/main/install.sh' "$INSTALL_SH" \
  || fail "curl URL must point at this repo"
! grep -q 'github.com/HelllGuest/dotfiles' "$INSTALL_SH" \
  || fail "install.sh must not link private dotfiles"
! grep -q 'github.com/HelllGuest/dotfiles' "$ROOT/README.md" \
  || fail "README must not link private dotfiles"
grep -E 'Flatpak/Podman|Podman userns' "$INSTALL_SH" \
  && fail "banner must not claim Podman" || true

# Identity validators: real inputs (extract from install.sh; fixtures for CI)
extract_fn() {
  awk -v n="$1" '
    $0 ~ "^" n "\\(\\)" {grab=1}
    grab {print; if ($0 == "}") exit}
  ' "$INSTALL_SH"
}
# shellcheck disable=SC1090
source <(for fn in valid_hostname valid_username valid_timezone valid_locale valid_keymap valid_reflector_country; do
  extract_fn "$fn"
  echo
done)
# reflector --country is written single-quoted into reflector.conf (chroot).
for _c in DE DE,NL "United States" "Germany, France"; do
  valid_reflector_country "$_c" || fail "reflector country '$_c' should pass"
done
for _c in "DE;rm" "DE'x" '$(id)' "1DE" "DE-NL" ""; do
  valid_reflector_country "$_c" && fail "reflector country '$_c' should fail" || true
done
unset -v _c
# The prompt re-asks; an answers-file value gets a box (a bare warn line there
# was drawn over by the Review screen before logging even started).
grep -A6 'REFLECTOR_COUNTRY="$(ui_input' "$WIZARD_SH" | grep -q 'valid_reflector_country' \
  || fail "reflector country prompt must re-ask on invalid input"
grep -A3 '^# Reflector country sanitize' "$WIZARD_SH" | grep -q 'ui_warn' \
  || fail "invalid REFLECTOR_COUNTRY from answers must be shown (ui_warn)"
# Live refresh failure: reason + consequence in a box (a bare warn line was
# drawn over by the download gauge at once); never "skipped" on that path.
_rb="$(awk '/^ML_TMP="\$\(mktemp\)"$/{f=1} f{print} f&&/^unset -v _reflector_args$/{exit}' "$WIZARD_SH")"
grep -q '124) _rfl_why="timed out' <<<"$_rb" || fail "reflector failure must name a timeout"
grep -q '(( NONINTERACTIVE )) || ui_warn "Mirror refresh' <<<"$_rb" || fail "reflector failure must be shown interactively"
grep -q 'reflector skipped, timed out' <<<"$_rb" && fail "failure path must not say 'skipped'"
unset -v _rb
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

command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning -e SC2015,SC2086,SC2162,SC2034 "$INSTALL_SH" \
  || echo "NOTE: shellcheck skipped or warnings-only"

# Live NONINTERACTIVE dry-run: catches set -e helper return bugs (no disk writes).
_dry_disk=""
while read -r _name _typ; do
  [[ $_typ == disk ]] || continue
  case $_name in
    /dev/zram*|/dev/loop*|/dev/ram*|/dev/md*) continue ;;
  esac
  _dry_disk=$_name
  break
done < <(lsblk -dpno NAME,TYPE 2>/dev/null)
if [[ -z $_dry_disk ]]; then
  echo "SKIP: no whole-disk block device for NONINTERACTIVE dry-run"
else
  _drytmp="$(mktemp -d)"
  trap 'rm -rf "${_idtmp:-}" "$_drytmp"' EXIT
  _ans="$_drytmp/answers.env"
  _pass="$_drytmp/pass.env"
  _out="$_drytmp/answers.out"
  cat >"$_ans" <<EOF
DISK=$_dry_disk
MODE=auto
ESP_MB=2048
HOSTNAME=thinkpad-t14s
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
USERNAME=t14sdry
PRESET=minimal
DESKTOP=N
LUKS_WIPE=none
PACMAN_PARALLEL=5
BTRFS_COMPRESS=zstd3
ZRAM_SIZE=half
SKIP_THINKPAD_HW=Y
SKIP_REFLECTOR=Y
EOF
  cat >"$_pass" <<'EOF'
LUKS_PASS=dryrun-luks-pass
USER_PASS=dryrun-user-pass
ROOT_PASS=dryrun-root-pass
EOF
  chmod 600 "$_ans" "$_pass"
  # Ubuntu CI: localectl list-keymaps is empty and /usr/share/kbd/keymaps is
  # missing — use the gated fixture path (same as identity unit tests).
  mkdir -p "$_drytmp/keymaps"
  : >"$_drytmp/keymaps/us.map.gz"
  _dry_log="$_drytmp/dryrun.log"
  if ! T14S_DRYRUN=1 T14S_UI=plain T14S_NONINTERACTIVE=1 T14S_I_WILL_ERASE=1 \
      T14S_IDENTITY_OVERRIDES=1 KEYMAP_DIR="$_drytmp/keymaps" \
      T14S_ANSWERS="$_ans" T14S_PASS_FILE="$_pass" T14S_ANSWERS_OUT="$_out" \
      T14S_LIB_DIR="$ROOT/lib" \
      bash "$ORCH_SH" >"$_dry_log" 2>&1
  then
    tail -n 40 "$_dry_log" >&2 || true
    fail "NONINTERACTIVE dry-run exited non-zero (disk=$_dry_disk)"
  fi
  grep -q '^DRYRUN:' "$_dry_log" \
    || fail "dry-run must print DRYRUN summary line"
  # On non-T14s CI VMs: warn path must not claim ok target profile.
  if ! grep -qiE '21C[QR]' /sys/class/dmi/id/product_name \
        /sys/class/dmi/id/product_sku 2>/dev/null
  then
    grep -q 'DMI not 21CQ/21CR' "$_dry_log" \
      || fail "non-T14s dry-run must warn about DMI mismatch"
    grep -q 'ok target profile: T14s Gen 3 AMD' "$_dry_log" \
      && fail "ok target profile must not print after DMI mismatch" || true
  fi
  echo "ok NONINTERACTIVE dry-run on $_dry_disk"
fi
# Static: DRYRUN exit must precede every destructive write (log grep is useless:
# those commands are not echoed, and start_log runs only after the exit).
python3 - "$INSTALL_SH" <<'PY' || fail "DRYRUN exit must precede destructive commands"
from pathlib import Path
import re, sys
t = Path(sys.argv[1]).read_text().splitlines()
dry = None
for i, ln in enumerate(t):
    if "printf 'DRYRUN:" in ln or 'printf "DRYRUN:' in ln:
        for j in range(i, min(i + 15, len(t))):
            if re.match(r'\s*exit 0\s*$', t[j]):
                dry = j
                break
        break
assert dry is not None, 'DRYRUN summary + exit 0 not found'
# Match command starts, including after | ; & && || (piped cryptsetup etc.).
# Line-position only (not call order); live dry-run covers runtime.
cmd = (
    r'(?:^|[|;&]|&&|\|\|)\s*'
    r'(?:sgdisk --zap-all|cryptsetup (?:luksFormat|open)|wipefs -a|'
    r'mkfs\.fat|mkfs\.btrfs|dd if=/dev/)'
)
pat = re.compile(cmd)

def hits(lines):
    out = []
    for i, ln in enumerate(lines):
        s = ln.lstrip()
        if not s or s.startswith('#'):
            continue
        if pat.search(ln):
            out.append(f'{i+1}:{ln.strip()}')
    return out

before = hits(t[:dry])
if before:
    raise SystemExit('destructive cmds before DRYRUN exit:\n  ' + '\n  '.join(before))
after = hits(t[dry+1:])
assert after, 'no destructive cmds after DRYRUN exit'
# Piped cryptsetup must be visible to the scanner (regression for ^\s* anchor).
assert any('cryptsetup luksFormat' in x for x in after), \
    'piped cryptsetup luksFormat not detected after DRYRUN exit'
print('ok DRYRUN exit before destructive phase')
PY

# ── safety / robustness regressions ─────────────────────────
_pick="$(awk '/^pick_part\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$INSTALL_SH")"
grep -q 'part_on_disk "\$ans" "\$disk"' <<<"$_pick" \
  || fail "pick_part must reject manual partitions on another disk"
grep -qF '[[ -d /run/archiso ]] || (( ALLOW_NON_ISO ))' "$INSTALL_SH" \
  || fail "preflight must require /run/archiso unless T14S_ALLOW_NON_ISO=1"
grep -q 'iflag=count_bytes count="\$size"' "$INSTALL_SH" \
  || fail "LUKS wipe must bound dd to the device size"
grep -q '(( rc == 0 )) || die "LUKS wipe failed' "$INSTALL_SH" \
  || fail "LUKS wipe must only accept dd exit 0"
_tmp="$(mktemp -d)"
dd if=/dev/zero of="$_tmp/w" bs=64M iflag=count_bytes count=1000000 status=none \
  || fail "dd count_bytes wipe returned nonzero"
[[ $(stat -c %s "$_tmp/w") == 1000000 ]] || fail "dd count_bytes wrote wrong size"
# read -a must not glob: "*" stays literal even with files in cwd.
touch "$_tmp/install.sh"
( cd "$_tmp" && read -r -a _a <<<'htop * tmux' && [[ ${_a[*]} == 'htop * tmux' ]] ) \
  || fail "package tokenizing must not pathname-expand"
rm -rf "$_tmp"
! grep -qE 'for _p in \$\{?(EXTRA_PKGS_LIST|_extra_in)' "$INSTALL_SH" \
  || fail "package lists must not use unquoted for-in splitting"
[[ $(grep -cE 'read -r -a _pkgs <<<"\$(EXTRA_PKGS_LIST|_extra_in)"' "$INSTALL_SH") -eq 2 ]] \
  || fail "both package lists must tokenize with read -r -a"
! grep -qF "val=\${val#\$'\\r'}" "$INSTALL_SH" \
  || fail "answers/secrets parsers must strip trailing CR, not leading"
[[ $(grep -cF "val=\${val%\$'\\r'}" "$INSTALL_SH") -eq 2 ]] \
  || fail "both answers and secrets parsers must strip trailing CR"
grep -q 'plain | dialog | whiptail) UI=\$T14S_UI' "$INSTALL_SH" \
  || fail "T14S_UI must be limited to plain|dialog|whiptail"
grep -qF "trap '_on_err \"\$?\" \"\$LINENO\" \"\$BASH_COMMAND\"' ERR" "$ORCH_SH" \
  || fail "ERR trap must pass \$? first to _on_err (a \$(…) in the trap would reset it)"
# Code lives in lib/steps/: a failure must name the stage file; install.sh itself
# runs from a pipe on the curl path (/dev/fd/N) and must still say install.sh.
_oe="$(awk '/^_on_err\(\) *\{/{f=1} f{print} f&&/^}$/{exit}' "$ORCH_SH")"
[[ -n $_oe ]] || fail "could not extract _on_err"
_st="$(mktemp -d)"; printf ': first line\n(exit 3)\n' >"$_st/22-x.sh"
_pre='set -euo pipefail; die() { echo "$1 rc=$2"; exit 1; }'
_trap="trap '_on_err \"\$?\" \"\$LINENO\" \"\$BASH_COMMAND\"' ERR"
_msg="$(bash -c "$_pre"$'\n'"$_oe"$'\n'"$_trap"$'\n''source "$1"' _ "$_st/22-x.sh" 2>&1 || true)"
[[ $_msg == "failed at 22-x.sh:2 (exit 3): ( exit 3 ) rc=3" ]] \
  || fail "ERR inside a stage must name file:line and keep the exit code, got: $_msg"
_msg="$(bash <(printf '%s\n' "$_pre" "$_oe" "$_trap" '(exit 5)') 2>&1 || true)"
[[ $_msg == "failed at install.sh:"*" (exit 5): ( exit 5 ) rc=5" ]] \
  || fail "ERR in install.sh run from a pipe must say install.sh, got: $_msg"
rm -rf -- "$_st"; unset -v _st _msg _oe _pre _trap
grep -qF "trap 'on_exit \$?' EXIT" "$ORCH_SH" \
  || fail "EXIT trap must route through on_exit (backstop for failures inside helpers)"

# T14S_DRYRUN: unknown values abort (never a silent real install) and are
# never evaluated as arithmetic (no $(…) execution).
_tmp="$(mktemp -d)"
for _v in true 'maybe' "a[\$(touch $_tmp/pwned)]"; do
  _rc=0
  T14S_DRYRUN="$_v" T14S_NONINTERACTIVE=1 T14S_LIB_DIR="$ROOT/lib" \
    timeout 30 bash "$ORCH_SH" </dev/null >/dev/null 2>&1 || _rc=$?
  [[ -e $_tmp/pwned ]] && fail "T14S_DRYRUN value was executed: $_v"
  if [[ $_v == true ]]; then
    (( _rc != 2 )) || fail "T14S_DRYRUN=true must be accepted as dry run"
  else
    (( _rc == 2 )) || fail "T14S_DRYRUN=$_v must abort with exit 2 (got $_rc)"
  fi
done

# answers_save: atomic rename, mode 0600, replaces a symlink instead of following it.
printf 'victim\n' >"$_tmp/victim"
ln -s "$_tmp/victim" "$_tmp/answers.env"
_fn="$(awk '/^answers_save\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$INSTALL_SH")"
[[ -n $_fn ]] || fail "could not extract answers_save"
bash -c '
  set -euo pipefail
  die() { echo "die: $*" >&2; exit 9; }
  eval "$1"
  ANSWERS_KEYS=(MODE HOSTNAME); MODE=auto; HOSTNAME=t14s
  answers_save "$2"
' _ "$_fn" "$_tmp/answers.env" || fail "answers_save failed"
[[ ! -L $_tmp/answers.env ]] || fail "answers_save must replace a symlink, not follow it"
[[ $(cat "$_tmp/victim") == victim ]] || fail "answers_save wrote through a symlink"
[[ $(stat -c %a "$_tmp/answers.env") == 600 ]] || fail "answers file must be mode 0600"
grep -qx 'HOSTNAME=t14s' "$_tmp/answers.env" || fail "answers file content missing"
[[ -z $(find "$_tmp" -name '.t14s-answers.*') ]] || fail "answers_save left a temp file"
rm -rf "$_tmp"

# _on_target: only the confirmed target (or, in auto mode, partitions on DISK).
_fn="$(awk '/^_on_target\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$INSTALL_SH")"
[[ -n $_fn ]] || fail "could not extract _on_target"
bash -c '
  set -euo pipefail
  eval "$1"
  part_on_disk() { [[ $1 == /dev/nvme0n1p* && $2 == /dev/nvme0n1 ]]; }
  cryptsetup() { printf "  type:    LUKS2\n  device:  %s\n" "$CRYPT_DEV"; }
  ROOT_PART=/dev/nvme0n1p2 EFI_PART=/dev/nvme0n1p1 DISK=/dev/nvme0n1
  MODE=manual
  _on_target /dev/nvme0n1p2 || exit 11
  _on_target /dev/nvme0n1p1 || exit 12
  ! _on_target /dev/nvme0n1p3 || exit 13        # same disk, not chosen (manual)
  ! _on_target /dev/sda1 || exit 14
  ! _on_target /swapfile || exit 15
  CRYPT_DEV=/dev/nvme0n1p2; _on_target /dev/mapper/cryptroot || exit 16
  CRYPT_DEV=/dev/sda2; ! _on_target /dev/mapper/cryptroot || exit 17
  MODE=auto ROOT_PART= EFI_PART=
  _on_target /dev/nvme0n1p3 || exit 18          # auto: whole disk is the target
  ! _on_target /dev/sda1 || exit 19
' _ "$_fn" || fail "_on_target ownership check wrong (exit $?)"

# Reused ESP: back up loader.conf and the fallback loader, and say so up front.
grep -q 'for _bk in /boot/EFI/BOOT/BOOTX64.EFI /boot/loader/loader.conf; do' "$INSTALL_SH" \
  || fail "reused ESP must back up BOOTX64.EFI and loader.conf"
! grep -q 'BOOTX64.EFI.pre-arch.bak 2>/dev/null || true' "$INSTALL_SH" \
  || fail "ESP backup failure must be reported, not swallowed"
grep -q 'firmware fallback loader) is replaced' "$INSTALL_SH" \
  || fail "ESP reuse prompt must warn that BOOTX64.EFI and loader.conf change"

# NONINTERACTIVE must never block on a keypress or msgbox (VM test: the final
# "INSTALL COMPLETE" waited for [enter] forever with the target unmounted).
_fns=""
for _f in ui_fold ui_msg ui_restore_console die start_log stop_log on_exit; do
  _body="$(awk -v f="$_f" '$0 ~ "^"f"\\(\\) *\\{" {p=1} p{print} p&&/^}/{exit}' "$INSTALL_SH")"
  [[ -n $_body ]] || fail "could not extract $_f"
  _fns+="$_body"$'\n'
done
_ui() { # UI NONINTERACTIVE -> prints PAUSED / TUI if the message would block
  bash -c '
    eval "$1"
    plain_pause() { echo PAUSED; }; tui() { echo TUI; }
    UI=$2 NONINTERACTIVE=$3 W=70 APP_TITLE=t cR= cG= cY= cB= cC= c0=
    ui_msg ok "INSTALL COMPLETE" 2>/dev/null
  ' _ "$_fns" "$1" "$2"
}
[[ -z $(_ui plain 1) ]] || fail "NONINTERACTIVE plain message must not pause"
[[ -z $(_ui dialog 1) ]] || fail "NONINTERACTIVE dialog message must not open a msgbox"
[[ $(_ui plain 0) == PAUSED ]] || fail "interactive plain message must still pause"
# die after start_log: the error must reach the console AND the log.
_tmp="$(mktemp -d)"
_err="$(bash -c '
  eval "$1"
  cleanup_ui() { :; }; ui_critical() { echo CRIT; }; tui() { echo TUI; }
  UI=plain NONINTERACTIVE=1 LOGGING=0 LOG=$2 cR= c0= H=20 W=70
  start_log
  die "boom-on-console" 3
' _ "$_fns" "$_tmp/log" 2>&1 >/dev/null)" || true
grep -q 'ERR boom-on-console' <<<"$_err" || fail "die after start_log must print the error on the console"
grep -q 'ERR boom-on-console' "$_tmp/log" || fail "die after start_log must also record the error in the log"
rm -rf "$_tmp"
unset -f _ui

# t14s-selftest runs as the user (pipewire check): `ufw status` needs root.
_st="$(awk '/cat > \/usr\/local\/bin\/t14s-selftest <<.ST.$/{f=1;next} f&&/^ST$/{exit} f' "$INSTALL_SH")"
[[ -n $_st ]] || fail "could not extract t14s-selftest"
! grep -v '^[[:space:]]*#' <<<"$_st" | grep -q 'ufw status' \
  || fail "selftest must not call root-only 'ufw status'"
grep -q 'check_firewalld' <<<"$_st" \
  || fail "selftest must check firewalld"
grep -qE 'systemctl is-(enabled|active) --quiet firewalld' <<<"$_st" \
  || fail "selftest firewalld check must use systemctl"

# A set -e exit from inside a helper skips the (non-inherited) ERR trap; on_exit
# must still report it. die() must not be reported twice; rc 0 stays silent.
_tmp="$(mktemp -d)"
_run_exit() {
  bash -c '
    eval "$1"
    cleanup_ui() { :; }; ui_critical() { echo CRIT; }; tui() { echo TUI; }
    UI=plain NONINTERACTIVE=1 LOGGING=0 LOG=$2 cR= c0= H=20 W=70 T14S_DIED=0
    set -euo pipefail
    trap "die \"failed at line \$LINENO\" \$?" ERR
    trap "on_exit \$?" EXIT
    helper() { false; echo not-reached; }
    case $3 in
      helper) start_log; helper ;;
      die) die "explicit-die" 4 ;;
      ok) : ;;
    esac
  ' _ "$_fns" "$_tmp/log" "$1" 2>&1 >/dev/null
}
_err="$(_run_exit helper)" && fail "helper failure must exit non-zero"
grep -q 'ERR stopped unexpectedly (exit 1)' <<<"$_err" \
  || fail "on_exit must report a failure inside a helper on the console: $_err"
grep -q 'ERR stopped unexpectedly' "$_tmp/log" || fail "on_exit report must also reach the log"
_err="$(_run_exit die)" && fail "die must exit non-zero"
[[ $(grep -c '^ERR' <<<"$_err") -eq 1 ]] || fail "die must not be reported twice by on_exit: $_err"
[[ -z $(_run_exit ok) ]] || fail "clean exit must stay silent"
rm -rf "$_tmp"
unset -f _run_exit

# TRIM through LUKS, lsm= (not deprecated security=), plymouth before sd-encrypt.
grep -q 'rd.luks.options=discard' "$INSTALL_SH" || fail "cmdline must pass discards through LUKS (fstrim.timer)"
grep -q 'lsm=landlock,lockdown,yama,integrity,apparmor,bpf' "$INSTALL_SH" \
  || fail "cmdline must enable AppArmor via lsm="
! grep -v '^[[:space:]]*#' "$CHROOT_SH" | grep -q 'security=apparmor' || fail "security= is deprecated; use lsm="
while IFS= read -r _h; do
  if [[ $_h == *plymouth* ]]; then
    [[ ${_h%%plymouth*} != *sd-encrypt* ]] || fail "plymouth hook must precede sd-encrypt: $_h"
  fi
done < <(grep -o "HOOKS=([^)]*)" "$CHROOT_SH")
grep -q 'HOOKS=([^)]*plymouth sd-encrypt' "$CHROOT_SH" \
  || fail "missing plymouth HOOKS variant"

# Avahi needs the mdns service in the drop zone (replies are not conntracked).
_fw="$(awk '/^configure_firewalld\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$ROOT/lib/70-firewall.sh")"
grep -q 'INSTALL_AVAHI' <<<"$_fw" && grep -q -- '--add-service=mdns' <<<"$_fw" \
  || fail "configure_firewalld must allow mdns when INSTALL_AVAHI=Y"
_tmp="$(mktemp -d)"
mkdir -p "$_tmp/bin" "$_tmp/etc"
printf '#!/bin/sh\necho "$@" >>"%s/calls"\n' "$_tmp" >"$_tmp/bin/firewall-offline-cmd"
for _c in systemctl systemd-detect-virt firewall-cmd pacman; do printf '#!/bin/sh\nexit 1\n' >"$_tmp/bin/$_c"; done
chmod +x "$_tmp"/bin/*
_fwrun() {
  PATH="$_tmp/bin:$PATH" INSTALL_AVAHI=$1 FIREWALLD_CONF="$_tmp/etc/firewalld/firewalld.conf" bash -c '
    yn_on() { local v=${1,,}; [[ $v == y || $v == yes || $v == on || $v == 1 ]]; }
    source "$1"
    configure_firewalld >/dev/null' _ "$ROOT/lib/70-firewall.sh"
}
_fwrun Y; grep -qx -- '--add-service=mdns' "$_tmp/calls" || fail "INSTALL_AVAHI=Y must add mdns"
grep -qx 'DefaultZone=drop' "$_tmp/etc/firewalld/firewalld.conf" || fail "firewalld.conf must be seeded with DefaultZone=drop"
printf '%s\n' 'DefaultZone=public' 'FirewallBackend=iptables' >"$_tmp/etc/firewalld/firewalld.conf"
rm -f "$_tmp/calls"; _fwrun N
! grep -qs -- 'mdns' "$_tmp/calls" || fail "INSTALL_AVAHI=N must not open mdns"
[[ $(cat "$_tmp/etc/firewalld/firewalld.conf") == $'DefaultZone=drop\nFirewallBackend=nftables' ]] \
  || fail "existing firewalld.conf must be rewritten to drop + nftables"
rm -rf "$_tmp"
unset -f _fwrun

# P15 (Intel) must not get AMD-only post-boot checks.
_st="$(awk '/cat > \/usr\/local\/bin\/t14s-selftest <<.ST.$/{f=1;next} f&&/^ST$/{exit} f' "$INSTALL_SH")"
grep -q 'check intel_pstate' <<<"$_st" || fail "selftest must check intel_pstate on Intel (P15)"
grep -q 'GenuineIntel' <<<"$_st" || fail "selftest cpufreq check must branch on CPU vendor"
grep -q 'CMDLINE_HINT="grep -E .intel_iommu|nvidia_drm' "$WIZARD_SH" \
  || fail "P15 finish screen must check intel_iommu/nvidia_drm, not amd_*"
! grep -q 'Verify after boot: lscpu | grep -i ryzen' "$WIZARD_SH" \
  || fail "finish screen CPU hint must be profile-aware"

# Interrupt (INT/TERM) reports and exits without a dialog to dismiss.
_tmp="$(mktemp -d)"
_err="$(bash -c '
  eval "$1"
  cleanup_ui() { :; }; ui_critical() { echo CRIT >&2; }; tui() { echo TUI >&2; }
  UI=dialog NONINTERACTIVE=0 LOGGING=0 LOG=$2 cR= c0= H=20 W=70 T14S_DIED=0
  trap "on_exit \$?" EXIT
  exit 130
' _ "$_fns" "$_tmp/log" 2>&1 >/dev/null)" && fail "interrupt must exit non-zero"
grep -q 'ERR interrupted (signal 2)' <<<"$_err" || fail "interrupt must be reported: $_err"
! grep -q CRIT <<<"$_err" || fail "interrupt must not open a dialog"
rm -rf "$_tmp"

# reflector.conf: shlex-split per line, so a spaced country must stay one arg.
_rf="$(awk '/^# reflector mirrors/{f=1;next} f{print} f&&/^} > \/etc\/xdg\/reflector\/reflector.conf$/{exit}' "$CHROOT_SH")"
[[ -n $_rf ]] || fail "could not extract reflector.conf writer"
_rfout="$(REFLECTOR_COUNTRY='United States,DE' bash -c "${_rf%>*}")"
python3 -c 'import shlex,sys; a=[t for l in sys.stdin for t in shlex.split(l, comments=True)]; i=a.index("--country"); sys.exit(0 if a[i+1]=="United States,DE" else 1)' <<<"$_rfout" \
  || fail "reflector.conf --country must survive shlex splitting: $_rfout"

# Minor: one install log; ESP size in the step text; env toggles accept y/yes/on.
[[ $(grep -c '^LOG="\$(mktemp' "$ORCH_SH") -eq 1 ]] || fail "install.sh must create the log file once"
! grep -q '2G ESP + LUKS' "$WIZARD_SH" || fail "partition step text must use ESP_MB"
grep -q '_env_on "${T14S_ALLOW_NON_ISO:-0}"' "$WIZARD_SH" || fail "T14S_ALLOW_NON_ISO must accept y/yes/on"
grep -q '_env_on "${T14S_POST_HOOK_I_UNDERSTAND:-0}"' "$WIZARD_SH" \
  || fail "T14S_POST_HOOK_I_UNDERSTAND must accept y/yes/on"

# TUI geometry scales with the real console (pty via script(1)) and never
# exceeds it; size comes from /dev/tty even with every fd redirected.
if command -v script >/dev/null 2>&1; then
  _geo() { # rows cols [redirect] -> "H W LH MH MW"
    local cmd='source "$1"; ui_geometry; echo "GEO $H $W $LH $MH $MW"'
    [[ ${3:-} == redirect ]] && cmd='source "$1"; { ui_geometry; echo "GEO $H $W $LH $MH $MW" >&3; } 3>&1 </dev/null >/dev/null 2>&1'
    script -qec "stty rows $1 cols $2; bash -c '$cmd' _ '$UI_SH'" /dev/null 2>/dev/null \
      | tr -d '\r' | sed -n 's/^GEO //p'
  }
  [[ $(_geo 24 80) == "18 72 10 14 72" ]] || fail "80x24 geometry: $(_geo 24 80)"
  [[ $(_geo 37 120) == "24 84 16 14 84" ]] || fail "120x37 geometry: $(_geo 37 120)"
  [[ $(_geo 56 180) == "37 120 29 14 84" ]] || fail "T14s 2.8K 180x56 geometry: $(_geo 56 180)"
  [[ $(_geo 75 240) == "44 120 36 14 84" ]] || fail "WUXGA 240x75 geometry: $(_geo 75 240)"
  [[ $(_geo 56 180 redirect) == "37 120 29 14 84" ]] \
    || fail "geometry must read /dev/tty when all fds are redirected: $(_geo 56 180 redirect)"
  read -r _gh _gw _ <<<"$(_geo 10 40)"
  (( _gh <= 8 && _gw <= 38 )) || fail "tiny 40x10 console: box must fit the screen ($_gh x $_gw)"
  unset -f _geo; unset -v _gh _gw
else
  echo "skip TUI geometry pty checks (no script(1))"
fi
# whiptail cuts long msgbox/yesno text unless --scrolltext (REVIEW is 30+ lines),
# but --scrolltext moves focus into the text where Enter does nothing (every box
# looked frozen on the ISO console): scroll only bodies taller than the screen.
_um="$(awk '/^ui_msg\(\) *\{/{f=1} f{print} f&&/^}$/{exit}' "$UI_SH")"
grep -q 'msg_overflows "$show"' <<<"$_um" && grep -q 'scroll=(--scrolltext)' <<<"$_um" \
  || fail "whiptail msgbox must use --scrolltext only when the body overflows"
_uy="$(awk '/^ui_yesno\(\) *\{/{f=1} f{print} f&&/^}$/{exit}' "$UI_SH")"
grep -q 'msg_overflows "$folded"' <<<"$_uy" && grep -q 'extra+=(--scrolltext)' <<<"$_uy" \
  || fail "whiptail yesno must use --scrolltext only when the body overflows"
grep -qE '\[\[ \$UI == whiptail \]\] && (scroll=|extra\+=)\(--scrolltext\)' "$UI_SH" \
  && fail "unconditional whiptail --scrolltext is back (Enter ignored on every box)"
# msg_overflows: lines + 6 rows must fit XH.
_mo() { bash -c 'source "$1"; XH=$2; msg_overflows "$(seq 1 "$3")"' _ "$UI_SH" "$1" "$2"; }
_mo 20 14 && fail "14 lines fit a 20-row box (14+6)"
_mo 20 15 || fail "15 lines overflow a 20-row box"
unset -f _mo
# list_height: whiptail shows only H - list - 6 prompt rows (the key hint under
# every prompt was cut); dialog keeps LH and shrinks its list itself.
_lh() { bash -c 'source "$1"; UI=$2 H=37 W=$3 LH=29; list_height "$4"' _ "$UI_SH" "$@"; }
[[ $(_lh whiptail 120 $'prompt\n\nhint') == 28 ]] || fail "whiptail list must leave room for prompt+blank+hint"
[[ $(_lh dialog 120 $'prompt\n\nhint') == 29 ]] || fail "dialog list height must stay LH"
[[ $(_lh whiptail 60 "$(printf 'x%.0s' $(seq 1 200))") == 27 ]] || fail "wrapped prompt rows must be counted (200 cols / 54)"
unset -f _lh
for _f in ui_menu ui_radio ui_checklist; do
  awk "/^${_f}\\(\\) *\\{/{f=1} f{print} f&&/^}\$/{exit}" "$UI_SH" | grep -q 'list_height "' \
    || fail "$_f must size its list with list_height"
done
unset -v _f
# Kernel messages tear the TUI on a VT: muted while it runs, restored first on exit.
awk '/^bootstrap_ui\(\) *\{/{f=1} f{print} f&&/^}$/{exit}' "$UI_SH" | grep -q 'ui_mute_console' \
  || fail "bootstrap_ui must mute kernel console messages"
for _f in die on_exit cleanup_ui; do
  awk "/^${_f}\\(\\) *\\{/{f=1} f{print} f&&/^}\$/{exit}" "$UI_SH" | sed -n 2,4p | grep -q 'ui_restore_console' \
    || fail "$_f must restore the console log level first"
done
unset -v _f
# Off a VT (this test's terminal) the console level is never touched.
[[ -z $(bash -c 'source "$1"; ui_mute_console; printf %s "${UI_PRINTK_SAVED:-}"' _ "$UI_SH") ]] \
  || fail "ui_mute_console must only act on a Linux VT"
# whiptail (ISO default) ignores Esc: its hints must not promise it.
_wh="$(awk '/^if \[\[ \$UI == whiptail \]\]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$WIZARD_SH")"
grep -q 'TUI_HINT_RADIO=' <<<"$_wh" && ! grep -q 'Esc' <<<"$_wh" \
  || fail "whiptail hints must say Tab to Abort, not Esc"
# whiptail long steps: clear the last box before streaming live output.
awk '/^run_progress\(\) *\{/{f=1} f{print} f&&/^}$/{exit}' "$UI_SH" | grep -qF "\e[H\e[2J" \
  || fail "run_progress must clear the stale whiptail box"
unset -v _um _uy

# Partition/disk menus read lsblk -P: spaces stay readable (no "EFI\x20System")
# and an empty FSTYPE must not shift PARTTYPENAME into the fs column.
_tmp="$(mktemp -d)"
mkdir -p "$_tmp/bin"
cat >"$_tmp/bin/lsblk" <<'LSBLK'
#!/bin/sh
# Pairs output only for -P; anything else gets lsblk -r style (escaped spaces).
if [ "$1" != -pnP ]; then echo 'part /dev/nvme0n1p1 2.8G vfat EFI\x20System'; exit 0; fi
case "$*" in
  *TYPE,PATH,SIZE,FSTYPE,PARTTYPENAME*)
    echo 'TYPE="disk" PATH="/dev/nvme0n1" SIZE="953.9G" FSTYPE="" PARTTYPENAME=""'
    echo 'TYPE="part" PATH="/dev/nvme0n1p1" SIZE="2.8G" FSTYPE="vfat" PARTTYPENAME="EFI System"'
    echo 'TYPE="part" PATH="/dev/nvme0n1p2" SIZE="16M" FSTYPE="" PARTTYPENAME="Microsoft reserved"'
    echo 'TYPE="part" PATH="/dev/nvme0n1p5" SIZE="805.4G" FSTYPE="crypto_LUKS" PARTTYPENAME="Linux filesystem"'
    echo 'TYPE="crypt" PATH="/dev/mapper/cryptroot" SIZE="805.4G" FSTYPE="btrfs" PARTTYPENAME=""' ;;
  *SIZE,MODEL*) echo 'SIZE="953.9G" MODEL="SAMSUNG MZVL21T0HCLR-00BL7"' ;;
esac
LSBLK
chmod +x "$_tmp/bin/lsblk"
_menu="$(PATH="$_tmp/bin:$PATH" bash -c '
  source "$1"; arr=(); build_part_menu arr /dev/nvme0n1
  printf "%s\n" "${arr[@]}"' _ "$ROOT/lib/00-common.sh" | paste -d'|' - -)"
grep -qxF '/dev/nvme0n1p1|2.8G    vfat        EFI System' <<<"$_menu" || fail "partition menu row p1: $_menu"
grep -qxF '/dev/nvme0n1p2|16M     empty       Microsoft reserved' <<<"$_menu" \
  || fail "empty FSTYPE must stay empty, not take PARTTYPENAME: $_menu"
! grep -q 'x20\|cryptroot\|953.9G' <<<"$_menu" || fail "menu must list partitions only, unescaped: $_menu"
_model="$(PATH="$_tmp/bin:$PATH" bash -c 'source "$1"; IFS=$'"'"'\x1f'"'"' read -r s m < <(lsblk_rows /dev/nvme0n1 SIZE MODEL); echo "$s|$m"' _ "$ROOT/lib/00-common.sh")"
[[ $_model == '953.9G|SAMSUNG MZVL21T0HCLR-00BL7' ]] || fail "disk model must keep spaces: $_model"
! grep -q 'dnro SIZE,MODEL\|prno TYPE,PATH' "$WIZARD_SH" "$ROOT/lib/00-common.sh" || fail "menus must not use lsblk -r (escapes spaces)"
rm -rf "$_tmp"; unset -v _menu _model

# msg_height counts the last (unterminated) line: 2 lines + 6 rows overhead.
[[ $(bash -c 'source "$1"; MH=1 H=50 XH=50; msg_height "a
b"' _ "$UI_SH") == 8 ]] || fail "msg_height must count the final line"

# The erase / manual-layout screens must fit an 80x24 console (message box
# limit 20 rows = 14 text rows): badge 2 + intro + table (header, disk, parts).
for _scr in 'ui_critical "AUTO mode ERASES' 'ui_info "Manual partitioning on'; do
  _n="$(awk -v s="$_scr" 'index($0, s){f=1} f{n++} f&&/^\$\(lsblk -o NAME/{print n; exit}' "$WIZARD_SH")"
  [[ -n $_n ]] || fail "could not find screen: $_scr"
  (( _n - 1 <= 4 )) || fail "screen '$_scr' has $(( _n - 1 )) intro lines; keep ≤4 so a 5-partition table fits 80x24"
done
unset -v _scr _n

# prefetch_pkgs: downloads retried (mirror resets aborted pacstrap mid-install);
# pacstrap runs once, after a successful prefetch, from the target cache.
_pfx="$(mktemp -d)"; mkdir -p "$_pfx/bin"
cat >"$_pfx/bin/pacman" <<EOF
#!/bin/sh
echo "\$*" >>"$_pfx/calls"
n=\$(wc -l <"$_pfx/calls")
[ "\$n" -ge "\${PF_OK_AT:-3}" ]
EOF
chmod +x "$_pfx/bin/pacman"
_pfrun() { PATH="$_pfx/bin:$PATH" PREFETCH_BACKOFF=0 bash -c 'source "$1"; shift; prefetch_pkgs "$@"' _ \
  "$ROOT/lib/50-packages.sh" "$_pfx/cache" base linux 2>&1; }
_o="$(PF_OK_AT=3 _pfrun)" || fail "prefetch must succeed on the 3rd attempt: $_o"
[[ $(wc -l <"$_pfx/calls") -eq 3 ]] || fail "prefetch must retry until success"
grep -q -- "-Syw --noconfirm --dbpath .* --cachedir $_pfx/cache -- base linux" "$_pfx/calls" \
  || fail "prefetch must download only, into the target cache, with a private db: $(head -1 "$_pfx/calls")"
[[ $(grep -c retrying <<<"$_o") -eq 2 ]] || fail "each failed attempt must say it retries: $_o"
rm -f "$_pfx/calls"
_o="$(PF_OK_AT=99 PREFETCH_TRIES=3 _pfrun)" && fail "prefetch must fail after the last attempt" || true
[[ $(wc -l <"$_pfx/calls") -eq 3 ]] && grep -q 'giving up' <<<"$_o" || fail "must stop after PREFETCH_TRIES and say so: $_o"
_pf_line="$(grep -n 'prefetch_pkgs /mnt/var/cache/pacman/pkg' "$WIZARD_SH" | cut -d: -f1)"
_ps_line="$(grep -n 'pacstrap -K /mnt' "$WIZARD_SH" | head -1 | cut -d: -f1)"
[[ -n $_pf_line && -n $_ps_line ]] && (( _pf_line < _ps_line )) || fail "install.sh must prefetch before pacstrap"
grep -A2 'prefetch_pkgs /mnt/var/cache/pacman/pkg' "$WIZARD_SH" | grep -q '|| die' \
  || fail "a failed prefetch must stop before pacstrap touches the root"
grep -q 'chmod 0755 "$db"' "$ROOT/lib/50-packages.sh" \
  || fail "prefetch db dir must be traversable by pacman's download user (alpm sandbox)"
rm -rf "$_pfx"; unset -v _pfx _o _pf_line _ps_line; unset -f _pfrun

# Firmware boot entry: bootctl in the chroot writes no EFI variables, so the
# host creates "Linux Boot Manager" for the chosen ESP and drops stale ones.
_efi_fx='BootCurrent: 001C
BootOrder: 0003,0001,0002,001C
Boot0001* Linux Boot Manager	HD(1,GPT,0a1d6820-8fd4-47d9-be7c-79d7fdcf6c40,0x800,0x200000)/\EFI\systemd\systemd-bootx64.efi
Boot0002* Fallback Linux Boot Manager	HD(1,GPT,0a1d6820-8fd4-47d9-be7c-79d7fdcf6c40,0x800,0x200000)/\EFI\systemd\systemd-boot-fallbackx64.efi
Boot0003* Windows Boot Manager	HD(1,GPT,CC7AE317-8288-40F3-BFEE-A6983A51C9B5,0x800,0x578000)/\EFI\Microsoft\Boot\bootmgfw.efi
Boot001C* NVMe0	VenMsg(bc7838d2-0f82-4d60-8316-c068ee79d25b,001c)'
_hw() { bash -c 'warn(){ :; }; say(){ :; }; ok(){ :; }; source "$1"; shift; "$@"' _ "$ROOT/lib/30-hardware.sh" "$@"; }
_o="$(_hw sdboot_plan cc7ae317-8288-40f3-bfee-a6983a51c9b5 <<<"$_efi_fx")"
[[ $_o == $'delete 0001\ndelete 0002\ncreate' ]] || fail "stale Linux Boot Manager entries must go, Windows stays, new entry created: $_o"
_o="$(_hw sdboot_plan 0A1D6820-8FD4-47D9-BE7C-79D7FDCF6C40 <<<"$_efi_fx")"
[[ $_o == 'keep 0001' ]] || fail "an entry already on this ESP must be kept (fallback too), not recreated: $_o"
[[ $(_hw sdboot_plan 11111111-2222-3333-4444-555555555555 <<<'BootOrder: 0000') == create ]] || fail "empty NVRAM must create"
[[ $(_hw boot_order_front 0001 <<<"$_efi_fx") == 0001,0003,0002,001C ]] || fail "boot_order_front must move the entry first"
_ebe="$(grep -n 'ensure_boot_entry "$EFI_PART"' "$WIZARD_SH" | cut -d: -f1)"
_cc="$(grep -n 'ok "chroot config complete"' "$WIZARD_SH" | cut -d: -f1)"
_iw="$(grep -n '^INSTALL_WARNINGS=""' "$WIZARD_SH" | cut -d: -f1)"
[[ -n $_ebe && -n $_cc && -n $_iw ]] && (( _cc < _ebe && _ebe < _iw )) \
  || fail "install.sh must write the firmware entry after the chroot and before warnings are collected"
grep -A3 'ensure_boot_entry "$EFI_PART"' "$WIZARD_SH" | grep -q 't14s-warnings.txt' \
  || fail "a missing firmware entry must be listed as an install warning"
grep -B2 -A2 '_ef_reuse=on; _ef_fmt=off' "$WIZARD_SH" | grep -q 'grep -qx vfat' \
  || fail "MANUAL must default to reusing an existing FAT32 ESP (formatting kills Windows' loader)"
unset -v _efi_fx _o _ebe _cc _iw; unset -f _hw

echo "PASS: smoke.test.sh"
