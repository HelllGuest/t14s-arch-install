#!/usr/bin/env bash
# Behavior tests for tests/host-check.sh parsers (stub commands, fake trees; no host state).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# Run a parser function from host-check.sh with $T/bin stubs first on PATH.
hc() {
  PATH="$T/bin:$PATH" HOST_CHECK_LIB=1 bash -c '
    source "$1"; shift
    "$@"
  ' _ "$ROOT/tests/host-check.sh" "$@"
}

# sysctl_check: "-key" prefix, spaced values, comments, mismatch, absent key.
cat >"$T/bin/sysctl" <<'EOF'
#!/bin/sh
case $2 in
  a.b) echo 1 ;; c.d) printf '2\t2\n' ;; e.f) echo 6 ;; *) exit 255 ;;
esac
EOF
chmod +x "$T/bin/sysctl"
printf '%s\n' '# comment' '; other comment' '-a.b = 1' 'c.d = 2 2' 'g.h = 1' >"$T/ok.conf"
out=$(hc sysctl_check "$T/ok.conf")
[[ $out == *"PASS ok.conf: 2 live sysctl values match (1 absent"* ]] || fail "sysctl_check pass case: $out"
printf '%s\n' 'a.b = 1' 'e.f = 5' >"$T/bad.conf"
out=$(hc sysctl_check "$T/bad.conf")
[[ $out == *"FAIL sysctl e.f = 6 (want 5, bad.conf)"* && $out != *PASS* ]] || fail "sysctl_check mismatch case: $out"
out=$(hc sysctl_check "$T/missing.conf")
[[ $out == *"FAIL $T/missing.conf missing"* ]] || fail "sysctl_check missing file: $out"

# makepkg_flags: glob order — a drop-in after pacman's rust.conf keeps target-cpu.
printf '%s\n' 'CFLAGS="-march=x86-64 -mtune=generic -O2"' 'OPTIONS=(strip !debug lto)' >"$T/makepkg.conf"
mkdir -p "$T/mk.d"
printf 'RUSTFLAGS="-C force-frame-pointers=yes"\n' >"$T/mk.d/rust.conf"
awk '/^cat > \/etc\/makepkg\.conf\.d\/t14s\.conf <<.EOF.$/{f=1;next} f&&/^EOF$/{exit} f' \
  "$ROOT/lib/80-chroot-setup.sh" >"$T/mk.d/t14s.conf"
[[ -s $T/mk.d/t14s.conf ]] || fail "could not extract installer t14s.conf"
out=$(hc makepkg_flags "$T/makepkg.conf" "$T/mk.d")
grep -qx 'RUSTFLAGS=-C force-frame-pointers=yes -C target-cpu=x86-64-v3' <<<"$out" || fail "makepkg_flags RUSTFLAGS: $out"
grep -q '^CFLAGS=-march=x86-64-v3' <<<"$out" || fail "makepkg_flags CFLAGS: $out"
grep -q '^OPTIONS=.*!debug' <<<"$out" || fail "makepkg_flags OPTIONS: $out"
mv "$T/mk.d/t14s.conf" "$T/mk.d/00-t14s.conf"   # sorts before rust.conf -> loses
out=$(hc makepkg_flags "$T/makepkg.conf" "$T/mk.d")
grep -qx 'RUSTFLAGS=-C force-frame-pointers=yes' <<<"$out" || fail "makepkg_flags must follow glob order: $out"

# conf_value: the last setting across drop-ins wins.
cat >"$T/bin/systemd-analyze" <<'EOF'
#!/bin/sh
printf '%s\n' '# /etc/systemd/logind.conf' '[Login]' '#HandleLidSwitch=lock' 'HandleLidSwitch=lock' \
  '# /etc/systemd/logind.conf.d/thinkpad-lid.conf' '[Login]' 'HandleLidSwitch=suspend'
EOF
chmod +x "$T/bin/systemd-analyze"
[[ $(hc conf_value logind.conf HandleLidSwitch) == suspend ]] || fail "conf_value must take the last drop-in"
[[ -z $(hc conf_value logind.conf HandleLidSwitchExternalPower) ]] || fail "conf_value unset key must be empty"

# dconf_stale: keyfile newer than compiled db.
mkdir -p "$T/gdm.d"
touch -d '2026-01-02' "$T/gdm.d/00-login-screen"
touch -d '2026-01-01' "$T/db"
hc dconf_stale "$T/db" "$T/gdm.d" || fail "dconf_stale must detect a newer keyfile"
touch -d '2026-01-03' "$T/db"
! hc dconf_stale "$T/db" "$T/gdm.d" || fail "dconf_stale must accept an up-to-date db"

# touchpad_wakeups: both T14s Gen 3 pad SKUs, nothing else.
for d in i2c-SYNA8018:00 i2c-ELAN0678:00 i2c-OTHER0001:00; do
  mkdir -p "$T/i2c/$d/power"; echo enabled >"$T/i2c/$d/power/wakeup"
done
out=$(hc touchpad_wakeups "$T/i2c")
[[ $(wc -l <<<"$out") == 2 && $out == *ELAN0678* && $out == *SYNA8018* && $out != *OTHER* ]] \
  || fail "touchpad_wakeups: $out"
[[ -z $(hc touchpad_wakeups "$T/none") ]] || fail "touchpad_wakeups with no pads must be empty"

# snapper_has_config: CSV parsing, exact name match.
printf '#!/bin/sh\nprintf "config,subvolume\\nhome,/home\\nroot2,/x\\n"\n' >"$T/bin/snapper"
chmod +x "$T/bin/snapper"
! hc snapper_has_config root || fail "snapper_has_config must not match root2"
hc snapper_has_config home || fail "snapper_has_config must find home"

echo "PASS: host-check.test.sh"
