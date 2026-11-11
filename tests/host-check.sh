#!/usr/bin/env bash
# host-check.sh — read-only verification of an installed T14s Gen 3 AMD system.
#
# Checks the effective state t14s-arch-install sets up (live sysfs/sysctl values,
# merged logind/makepkg config, running services), not just that files exist.
# Never writes anything. Root-only checks are SKIPPED unless run with sudo.
#
#   bash tests/host-check.sh            # as your user (desktop session checks)
#   sudo bash tests/host-check.sh       # adds /boot, LUKS, sbctl, snapper checks
#
# Exit: 0 = no FAIL, 1 = at least one FAIL.  WARN = worth a look, not fatal.
set -uo pipefail

pass=0 fail=0 warn=0 skip=0
if [[ -t 1 ]]; then G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' D=$'\e[2m' B=$'\e[1m' N=$'\e[0m'; else G='' R='' Y='' D='' B='' N=''; fi
PASS() { printf '%sPASS%s %s\n' "$G" "$N" "$*"; pass=$((pass + 1)); }
FAIL() { printf '%sFAIL%s %s\n' "$R" "$N" "$*"; fail=$((fail + 1)); }
WARN() { printf '%sWARN%s %s\n' "$Y" "$N" "$*"; warn=$((warn + 1)); }
SKIP() { printf '%sSKIP%s %s\n' "$D" "$N" "$*"; skip=$((skip + 1)); }
section() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }
# check NAME CMD... -> PASS/FAIL on the command's exit status
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then PASS "$n"; else FAIL "$n"; fi; }
is_root() { [[ $EUID -eq 0 ]]; }
has() { command -v "$1" >/dev/null 2>&1; }
read1() { [[ -r $1 ]] && head -c 4096 "$1" 2>/dev/null; }
unit_on() { systemctl is-enabled --quiet "$1" 2>/dev/null && systemctl is-active --quiet "$1" 2>/dev/null; }

# ── parsers (unit-tested by tests/host-check.test.sh with HOST_CHECK_LIB=1) ──
# sysctl_check FILE: compare each sysctl.d key=value with the live value.
sysctl_check() {
  local f=$1 k v live ok=0 bad=0 unread=0 note=""
  [[ -r $f ]] || { FAIL "$f missing"; return; }
  while IFS='=' read -r k v; do
    k=${k//[[:space:]]/} v=${v//[[:space:]]/}
    [[ -z $k || $k == \#* || $k == \;* ]] && continue
    k=${k#-}  # sysctl.d "-key" = ignore if the key does not exist on this kernel
    live=$(sysctl -n "$k" 2>/dev/null | tr -d '[:space:]') || { unread=$((unread + 1)); continue; }
    [[ -z $live ]] && { unread=$((unread + 1)); continue; }
    if [[ $live == "$v" ]]; then ok=$((ok + 1)); else bad=$((bad + 1)); FAIL "sysctl $k = $live (want $v, ${f##*/})"; fi
  done <"$f"
  (( unread )) && note=" ($unread absent on this kernel or unreadable as this user)"
  (( bad == 0 )) && PASS "${f##*/}: $ok live sysctl values match$note"
  return 0
}
# makepkg_flags CONF DIR: effective flags after makepkg.conf + conf.d in glob order.
makepkg_flags() {
  bash -c 'source "$1" 2>/dev/null; for f in "$2"/*.conf; do [[ -r $f ]] && source "$f"; done
    printf "%s\n" "CFLAGS=${CFLAGS:-}" "RUSTFLAGS=${RUSTFLAGS:-}" "GOAMD64=${GOAMD64:-}" "MAKEFLAGS=${MAKEFLAGS:-}" "OPTIONS=${OPTIONS[*]:-}"' \
    _ "$1" "$2" 2>/dev/null
}
# conf_value CONF KEY: last value of KEY across systemd/CONF and its drop-ins.
conf_value() {
  systemd-analyze cat-config "systemd/$1" 2>/dev/null | awk -F= -v k="$2" '$1 == k {v = $2} END {print v}'
}
# dconf_stale DB KEYDIR: true when a keyfile is newer than the compiled db.
dconf_stale() {
  local newest
  newest=$(find -L "$2" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
  [[ -n $newest ]] && (( ${newest%.*} > $(stat -c %Y "$1") ))
}
# touchpad_wakeups I2C_DIR: power/wakeup files of the T14s Gen 3 ELAN / Synaptics pads.
touchpad_wakeups() {
  local w
  for w in "$1"/i2c-ELAN0678:*/power/wakeup "$1"/i2c-SYNA8018:*/power/wakeup; do
    [[ -r $w ]] && printf '%s\n' "$w"
  done
  return 0
}
# snapper_has_config NAME: CSV output, independent of snapper's table glyphs.
snapper_has_config() {
  snapper --csvout list-configs 2>/dev/null | awk -F, -v n="$1" 'NR > 1 && $1 == n {f = 1} END {exit !f}'
}

if [[ ${HOST_CHECK_LIB:-0} == 1 ]]; then return 0 2>/dev/null || exit 0; fi

# ── platform ────────────────────────────────────────────────
section "Platform"
model="$(read1 /sys/class/dmi/id/product_name) $(read1 /sys/class/dmi/id/product_version)"
if [[ $model =~ 21C[QR] ]]; then PASS "DMI is T14s Gen 3 AMD (${model//$'\n'/ })"
else WARN "DMI is not 21CQ/21CR (${model//$'\n'/ }) — hardware checks may not apply"; fi
check "booted in UEFI mode" test -d /sys/firmware/efi
cmdline=$(read1 /proc/cmdline)
for flag in amd_iommu=on amd_pstate=active mem_sleep_default=s2idle apparmor=1 security=apparmor; do
  if [[ " $cmdline " == *" $flag "* ]]; then PASS "kernel cmdline has $flag"; else FAIL "kernel cmdline missing $flag"; fi
done
drv=$(read1 /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
if [[ $drv == amd-pstate* ]]; then PASS "cpufreq driver $drv"; else FAIL "cpufreq driver is '${drv:-none}', expected amd-pstate*"; fi
if compgen -G '/sys/class/iommu/*' >/dev/null; then PASS "IOMMU active"; else FAIL "no IOMMU in /sys/class/iommu"; fi
if grep -q '\[s2idle\]' /sys/power/mem_sleep 2>/dev/null; then PASS "suspend mode s2idle"
else FAIL "mem_sleep is '$(read1 /sys/power/mem_sleep)', expected [s2idle]"; fi
check "amd-ucode installed" pacman -Q amd-ucode
case $(uname -r) in
  *-lts | *-hardened) PASS "running kernel $(uname -r)" ;;
  *) WARN "running kernel $(uname -r) (installer default is linux-lts)" ;;
esac

# ── boot ────────────────────────────────────────────────────
section "Boot"
for k in linux-lts linux-hardened; do check "kernel package $k installed" pacman -Q "$k"; done
sbvar=$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -1)
if [[ -n $sbvar ]] && [[ $(od -An -tu1 -j4 -N1 "$sbvar" 2>/dev/null | tr -d ' ') == 1 ]]; then PASS "Secure Boot enabled"
else WARN "Secure Boot off (enable after: sudo sbctl enroll-keys -m)"; fi
if is_root; then
  check "systemd-boot installed on ESP" bootctl is-installed
  if compgen -G '/boot/EFI/Linux/arch-linux-lts*.efi' >/dev/null; then PASS "linux-lts UKI on ESP"; else FAIL "no arch-linux-lts UKI in /boot/EFI/Linux"; fi
  if compgen -G '/boot/EFI/Linux/arch-linux-hardened*.efi' >/dev/null; then PASS "linux-hardened UKI on ESP"; else FAIL "no arch-linux-hardened UKI"; fi
  check "loader.conf has editor no" grep -qx 'editor no' /boot/loader/loader.conf
  if has sbctl; then
    unsigned=$(sbctl verify 2>/dev/null | grep -c 'is not signed' || true)
    if (( unsigned == 0 )); then PASS "sbctl: all tracked EFI files signed"; else WARN "sbctl: $unsigned EFI file(s) not signed"; fi
  else SKIP "sbctl not installed"; fi
else
  SKIP "ESP / UKI / sbctl checks need root (/boot is 0700)"
fi

# ── storage ─────────────────────────────────────────────────
section "Storage"
rootsrc=$(findmnt -nvo SOURCE /)
if [[ $rootsrc == /dev/mapper/* ]] && lsblk -nso TYPE "$rootsrc" 2>/dev/null | grep -qx crypt; then
  luksdev=$(lsblk -nslpo NAME,FSTYPE "$rootsrc" | awk '$2 == "crypto_LUKS" {print $1; exit}')
  ver=$(lsblk -dno FSVER "${luksdev:-/nonexistent}" 2>/dev/null)
  if [[ $ver == 2 ]]; then PASS "root on LUKS2 ($luksdev)"; else FAIL "root LUKS version '${ver:-?}', expected 2"; fi
  if is_root && has cryptsetup; then
    pbkdf=$(cryptsetup luksDump "$luksdev" 2>/dev/null | awk '/PBKDF:/ {print $2; exit}')
    if [[ $pbkdf == argon2id ]]; then PASS "LUKS PBKDF argon2id"; else FAIL "LUKS PBKDF '${pbkdf:-?}', expected argon2id"; fi
  else SKIP "LUKS PBKDF check needs root"; fi
else
  FAIL "root ($rootsrc) is not on a dm-crypt device"
fi
check "root filesystem is btrfs" test "$(findmnt -no FSTYPE /)" = btrfs
for mp in /:@ /home:@home /.snapshots:@snapshots /var/log:@var_log /var/cache:@var_cache /tmp:@tmp; do
  m=${mp%%:*} sv=${mp#*:}
  opts=$(findmnt -no OPTIONS "$m" 2>/dev/null)
  if [[ ,$opts, == *",subvol=/$sv,"* ]]; then PASS "$m on subvolume $sv"; else FAIL "$m not mounted from subvolume $sv"; fi
done
ropts=$(findmnt -no OPTIONS /)
[[ $ropts == *compress=zstd* ]] && PASS "root mounted with zstd compression" || FAIL "root not mounted with compress=zstd"
[[ $ropts == *noatime* ]] && PASS "root mounted noatime" || WARN "root not mounted noatime"
if swapon --show=NAME --noheadings 2>/dev/null | grep -q zram; then PASS "zram swap active"; else FAIL "no zram swap"; fi
if grep -q '\[zstd\]' /sys/block/zram0/comp_algorithm 2>/dev/null; then PASS "zram uses zstd"; else WARN "zram compressor not zstd"; fi
check "fstrim.timer enabled" systemctl is-enabled --quiet fstrim.timer
for t in snapper-timeline.timer snapper-cleanup.timer; do check "$t enabled" systemctl is-enabled --quiet "$t"; done
if ! has snapper; then FAIL "snapper not installed"
elif ! snapper --csvout list-configs >/dev/null 2>&1; then SKIP "snapper configs not readable as this user"
elif snapper_has_config root; then PASS "snapper config 'root' exists"
else FAIL "snapper config 'root' missing"; fi

# ── security ────────────────────────────────────────────────
section "Security"
if grep -q apparmor /sys/kernel/security/lsm 2>/dev/null; then PASS "AppArmor is an active LSM"; else FAIL "AppArmor not in /sys/kernel/security/lsm"; fi
check "apparmor.service active" unit_on apparmor.service
check "ufw.service active" unit_on ufw.service
check "ufw enabled in ufw.conf" grep -qx 'ENABLED=yes' /etc/ufw/ufw.conf
if is_root; then
  ufw status 2>/dev/null | grep -qi 'Status: active' && PASS "ufw firewall active (ufw status)" || FAIL "ufw status not active"
  ufw status verbose 2>/dev/null | grep -qi 'deny (incoming)' && PASS "ufw default deny incoming" || FAIL "ufw default is not deny incoming"
fi
for f in /etc/sysctl.d/99-security.conf /etc/sysctl.d/99-userns.conf; do sysctl_check "$f"; done

# ── ThinkPad hardware ──────────────────────────────────────
section "ThinkPad hardware"
bat=/sys/class/power_supply/BAT0
if [[ -r $bat/charge_control_start_threshold ]]; then
  s=$(read1 "$bat/charge_control_start_threshold") e=$(read1 "$bat/charge_control_end_threshold")
  [[ $s == 70 ]] && PASS "charge start threshold 70" || FAIL "charge start threshold is $s, expected 70 (UPower reset? see 61-thinkpad-charge-limit.rules)"
  [[ $e == 80 ]] && PASS "charge end threshold 80" || FAIL "charge end threshold is $e, expected 80"
else SKIP "no BAT0 charge_control thresholds"; fi
check "thinkpad-charge-thresholds.service enabled" systemctl is-enabled --quiet thinkpad-charge-thresholds.service
check "charge apply script present" test -x /usr/local/lib/thinkpad/apply-charge-thresholds.sh
check "tmpfiles charge thresholds present" test -f /etc/tmpfiles.d/thinkpad-charge-thresholds.conf
if [[ -r /etc/udev/rules.d/61-thinkpad-charge-limit.rules ]] \
  && grep -q 'ENV{CHARGE_LIMIT}="70,80"' /etc/udev/rules.d/61-thinkpad-charge-limit.rules; then
  PASS "udev CHARGE_LIMIT=70,80 for UPower"
else FAIL "61-thinkpad-charge-limit.rules missing (UPower can reset start threshold to 0)"; fi
tp_found=0
while IFS= read -r w; do
  tp_found=1
  [[ $(read1 "$w") == disabled ]] && PASS "touchpad s2idle wakeup disabled (${w%/power/wakeup})" \
    || FAIL "touchpad wakeup is '$(read1 "$w")' (${w#/sys/bus/i2c/devices/}); want disabled — 71-thinkpad-t14s-touchpad-wakeup.rules"
done < <(touchpad_wakeups /sys/bus/i2c/devices)
(( tp_found )) || SKIP "no ELAN0678/SYNA8018 I2C touchpad found"
if has systemd-analyze; then
  lid=$(conf_value logind.conf HandleLidSwitch)
  lidac=$(conf_value logind.conf HandleLidSwitchExternalPower)
  [[ $lid == suspend ]] && PASS "lid on battery: suspend" || FAIL "effective HandleLidSwitch='${lid:-default}', expected suspend"
  [[ $lidac == ignore ]] && PASS "lid on AC: ignore" || FAIL "effective HandleLidSwitchExternalPower='${lidac:-default}', expected ignore"
  sleepst=$(conf_value sleep.conf MemorySleepMode)
  [[ $sleepst == s2idle ]] && PASS "systemd sleep MemorySleepMode=s2idle" || FAIL "effective MemorySleepMode='${sleepst:-default}', expected s2idle"
fi
if pacman -Q fprintd >/dev/null 2>&1; then PASS "fprintd installed"; else WARN "fprintd not installed"; fi

# ── graphics / desktop ─────────────────────────────────────
section "Graphics & desktop"
check "amdgpu driver loaded" test -d /sys/module/amdgpu
for p in mesa vulkan-radeon libva-utils sof-firmware alsa-ucm-conf wireless-regdb; do check "package $p" pacman -Q "$p"; done
if [[ -n ${XDG_RUNTIME_DIR:-} ]] && systemctl --user show-environment >/dev/null 2>&1; then
  if systemctl --user show-environment | grep -qx 'LIBVA_DRIVER_NAME=radeonsi'; then PASS "session LIBVA_DRIVER_NAME=radeonsi"
  else FAIL "session LIBVA_DRIVER_NAME is not radeonsi"; fi
  [[ ${XDG_SESSION_TYPE:-} == wayland ]] && PASS "Wayland session" || WARN "XDG_SESSION_TYPE='${XDG_SESSION_TYPE:-}', expected wayland"
  if has vainfo; then
    vainfo 2>/dev/null | grep -q 'VAProfileH264' && PASS "VA-API H.264 decode available (radeonsi)" || FAIL "vainfo shows no H.264 profile"
  fi
else SKIP "no user session (run as your desktop user for session checks)"; fi
check "gdm.service active" unit_on gdm.service
check "61-gdm-wayland.rules present" test -f /etc/udev/rules.d/61-gdm-wayland.rules
for kv in WaylandEnable=true DisallowTCP=true AutomaticLoginEnable=false TimedLoginEnable=false; do
  grep -qx "$kv" /etc/gdm/custom.conf 2>/dev/null && PASS "gdm custom.conf $kv" || FAIL "gdm custom.conf missing $kv"
done
awk '/^\[xdmcp\]/ {s=1; next} /^\[/ {s=0} s && /^Enable=false$/ {f=1} END {exit !f}' /etc/gdm/custom.conf 2>/dev/null \
  && PASS "gdm XDMCP disabled" || FAIL "gdm [xdmcp] Enable=false missing"
greeter=/etc/dconf/db/gdm.d/00-login-screen
if [[ -r $greeter ]]; then
  grep -qx 'disable-user-list=true' "$greeter" && PASS "greeter hides user list" || FAIL "greeter disable-user-list not true"
  awk '/^\[/ {s=$0} /^idle-delay=/ {print s}' "$greeter" | grep -qx '\[org/gnome/desktop/session\]' \
    && PASS "greeter idle-delay in [org/gnome/desktop/session]" || FAIL "greeter idle-delay not under [org/gnome/desktop/session] (ignored)"
  if [[ -s /etc/dconf/db/gdm ]]; then
    if dconf_stale /etc/dconf/db/gdm /etc/dconf/db/gdm.d; then
      FAIL "/etc/dconf/db/gdm older than gdm.d keyfiles — run: sudo dconf update"
    else PASS "compiled GDM dconf db up to date"; fi
  else FAIL "/etc/dconf/db/gdm not compiled — run: sudo dconf update"; fi
else FAIL "$greeter missing"; fi

# ── build flags ─────────────────────────────────────────────
section "makepkg"
mk=$(makepkg_flags /etc/makepkg.conf /etc/makepkg.conf.d)
grep -q '^CFLAGS=.*-march=x86-64-v3' <<<"$mk" && PASS "effective CFLAGS -march=x86-64-v3" || FAIL "effective CFLAGS lack -march=x86-64-v3"
grep -q '^RUSTFLAGS=.*target-cpu=x86-64-v3' <<<"$mk" && PASS "effective RUSTFLAGS target-cpu=x86-64-v3" || FAIL "RUSTFLAGS lack target-cpu=x86-64-v3"
grep -qx 'GOAMD64=v3' <<<"$mk" && PASS "GOAMD64=v3" || FAIL "GOAMD64 not v3"
grep -q '^MAKEFLAGS=-j' <<<"$mk" && PASS "MAKEFLAGS parallel ($(grep '^MAKEFLAGS=' <<<"$mk" | cut -d= -f2-))" || WARN "MAKEFLAGS has no -j"
grep -q '^OPTIONS=.*!debug' <<<"$mk" && PASS "makepkg OPTIONS !debug" || WARN "makepkg builds -debug packages"

# ── services ────────────────────────────────────────────────
section "Services"
for u in NetworkManager.service bluetooth.service earlyoom.service reflector.timer; do check "$u enabled" systemctl is-enabled --quiet "$u"; done
if pacman -Q tuned-ppd >/dev/null 2>&1; then check "tuned-ppd active" unit_on tuned-ppd.service
elif pacman -Q power-profiles-daemon >/dev/null 2>&1; then check "power-profiles-daemon active" unit_on power-profiles-daemon.service
else WARN "no power profile daemon (tuned-ppd / power-profiles-daemon)"; fi
if [[ -e /var/lib/t14s/flatpak-apps.done ]]; then PASS "first-boot Flatpak apps done"
elif systemctl is-enabled --quiet t14s-flatpak-apps.timer 2>/dev/null; then WARN "first-boot Flatpak apps still pending (timer enabled)"
elif systemctl is-enabled --quiet t14s-flatpak-apps.service 2>/dev/null; then WARN "Flatpak first-boot uses the old WantedBy=multi-user oneshot (pre-876f083 install)"
else SKIP "no t14s first-boot Flatpak unit"; fi
nfailed=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
(( nfailed == 0 )) && PASS "no failed system units" || FAIL "$nfailed failed unit(s): $(systemctl --failed --no-legend | awk '{print $2}' | tr '\n' ' ')"
state=$(systemctl is-system-running 2>/dev/null)
[[ $state == running ]] && PASS "system state running" || WARN "system state '$state'"
if [[ -x /usr/local/bin/t14s-selftest ]] && ! is_root; then
  if out=$(/usr/local/bin/t14s-selftest 2>&1); then PASS "t14s-selftest: ${out##*$'\n'}"
  elif fails=$(grep '^FAIL' <<<"$out" | tr '\n' ' ') && [[ -n $fails ]]; then FAIL "t14s-selftest: $fails"
  else FAIL "t14s-selftest aborted after: ${out##*$'\n'} (old selftest? reinstall from current installer)"; fi
fi

# ── summary ─────────────────────────────────────────────────
printf '\n%s%d pass, %d fail, %d warn, %d skip%s\n' "$B" "$pass" "$fail" "$warn" "$skip" "$N"
is_root || (( skip == 0 )) || printf '%sre-run with sudo for the skipped root-only checks%s\n' "$D" "$N"
(( fail == 0 ))
