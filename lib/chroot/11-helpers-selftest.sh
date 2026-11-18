# 11-helpers-selftest.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 92-95 %: helper scripts and t14s-selftest.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

stage 92 95 "helpers and self-test"
# Chrome Flatpak helper (post-boot — bwrap often fails in chroot)
if yn_on "${INSTALL_CHROME_HINT}"; then
  sudo -u "$USERNAME" tee "/home/$USERNAME/install-chrome-flatpak.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub com.google.Chrome
SH
  chmod 755 "/home/$USERNAME/install-chrome-flatpak.sh"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/install-chrome-flatpak.sh"
fi

# XDG user dirs after packages exist (GNOME pulls xdg-user-dirs; base may too).
if command -v xdg-user-dirs-update >/dev/null 2>&1; then
  sudo -u "$USERNAME" env HOME="/home/$USERNAME" xdg-user-dirs-update || true
fi

# Post-boot BT/audio self-test helper (optional).
if yn_on "${INSTALL_SELFTEST}"; then
  cat > /usr/local/bin/t14s-selftest <<'ST'
#!/usr/bin/env bash
# Quick laptop sanity after first boot (T14s Gen 3 AMD / P15 Gen 1).
set -euo pipefail
ok=0; bad=0
check() {
  local name=$1; shift
  if "$@"; then echo "OK  $name"; ok=$((ok+1)); else echo "FAIL $name"; bad=$((bad+1)); fi
}
check_pipewire() {
  systemctl --user is-active --quiet pipewire 2>/dev/null || pactl info >/dev/null 2>&1
}
check_wifi() {
  nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -q ':wifi:connected' \
    || nmcli networking connectivity 2>/dev/null | grep -qi full
}
# firewalld status (user-callable; enabled counts before the first start).
check_firewalld() {
  systemctl is-active --quiet firewalld 2>/dev/null \
    || systemctl is-enabled --quiet firewalld 2>/dev/null
}
check bluetooth systemctl is-active --quiet bluetooth
check pipewire check_pipewire
check wifi check_wifi
check apparmor systemctl is-active --quiet apparmor
check firewalld check_firewalld
check mem_sleep grep -q '\[s2idle\]' /sys/power/mem_sleep
# CPU vendor decides the expected cpufreq driver (T14s amd-pstate, P15 intel_pstate).
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]]; then
  if grep -q AuthenticAMD /proc/cpuinfo; then
    check amd_pstate grep -q '^amd-pstate' /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
  elif grep -q GenuineIntel /proc/cpuinfo; then
    check intel_pstate grep -q '^intel_pstate' /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
  fi
fi
if [[ -f /sys/class/power_supply/BAT0/charge_control_start_threshold ]]; then
  check bat_start grep -qx '70' /sys/class/power_supply/BAT0/charge_control_start_threshold
  check bat_end grep -qx '80' /sys/class/power_supply/BAT0/charge_control_end_threshold
fi
for _tp in /sys/bus/i2c/devices/i2c-ELAN0678:*/power/wakeup /sys/bus/i2c/devices/i2c-SYNA8018:*/power/wakeup; do
  if [[ -f $_tp ]]; then
    check touchpad_wakeup grep -qx 'disabled' "$_tp"
  fi
done
if [[ -d /etc/dconf/db/gdm.d ]]; then
  check gdm_dconf test -s /etc/dconf/db/gdm
fi
echo "t14s-selftest: $ok ok, $bad fail"
(( bad == 0 ))
ST
  chmod 755 /usr/local/bin/t14s-selftest
  say "wrote /usr/local/bin/t14s-selftest"
fi
