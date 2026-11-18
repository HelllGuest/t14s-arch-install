# 03-initramfs-cmdline.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 6-8 %: mkinitcpio hooks, kernel cmdline, ThinkPad charge thresholds.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

stage 6 8 "initramfs and kernel cmdline"
# initramfs (systemd + sd-encrypt for LUKS; optional plymouth)
_HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)'
if yn_on "${INSTALL_PLYMOUTH}"; then
  # plymouth before sd-encrypt so the LUKS prompt shows on the splash (ArchWiki).
  _HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)'
fi
sed -i "s/^HOOKS=.*/${_HOOKS}/" /etc/mkinitcpio.conf
unset -v _HOOKS
grep -Eq '^HOOKS=.*sd-encrypt' /etc/mkinitcpio.conf \
  || { echo "ERROR: mkinitcpio HOOKS missing sd-encrypt after sed" >&2; exit 1; }

# kernel cmdline (shared by UKIs)
mkdir -p /etc/kernel
# BIOS Sleep = "Windows and Linux" pairs with mem_sleep_default=s2idle.
# rd.luks.options=discard: pass TRIM through dm-crypt (fstrim.timer is enabled;
# without it the SSD never sees discards). Trade-off: free-block layout is visible
# to someone holding the disk; contents stay encrypted.
# lsm= replaces the deprecated security=apparmor (ArchWiki AppArmor order).
_cmdline="rd.luks.name=${LUKS_UUID}=cryptroot rd.luks.options=discard root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3 mem_sleep_default=s2idle lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
case ${HW_PROFILE:-t14s} in
  p15)
    _cmdline+=" intel_iommu=on nvidia_drm.modeset=1 rd.driver.blacklist=nouveau"
    ;;
  *)
    _cmdline+=" amd_iommu=on amd_pstate=active"
    ;;
esac
if yn_on "${INSTALL_PLYMOUTH}"; then
  _cmdline+=" splash"
fi
printf '%s\n' "$_cmdline" > /etc/kernel/cmdline
unset -v _cmdline

# systemd sleep: enforce s2idle (matches mem_sleep_default=s2idle on Rembrandt).
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/s2idle.conf <<'EOF'
[Sleep]
SuspendState=mem
MemorySleepMode=s2idle
HibernateMode=shutdown
EOF

# Charge window 70–80, touchpad s2idle wakeup disable, lid policy — skipped on VM / SKIP_THINKPAD_HW.
mkdir -p /etc/tmpfiles.d /usr/local/lib/thinkpad /etc/udev/rules.d /etc/systemd/logind.conf.d
if ! yn_on "${SKIP_THINKPAD_HW}"; then
cat > /etc/tmpfiles.d/thinkpad-charge-thresholds.conf <<'EOF'
# ThinkPad charge thresholds 70–80 (PPD host; no TLP).
# Best-effort at boot; see thinkpad-charge-thresholds.service if BAT* appears late.
w /sys/class/power_supply/BAT0/charge_control_start_threshold - - - - 70
w /sys/class/power_supply/BAT0/charge_control_end_threshold - - - - 80
EOF
cat > /etc/udev/rules.d/61-thinkpad-charge-limit.rules <<'EOF'
# UPower 1.90+ / GNOME Preserve Battery Health:
# 60-upower-battery.rules only imports CHARGE_LIMIT from hwdb if
# charge_control_start_threshold already exists when BAT0 is added (races
# thinkpad_acpi) and defaults to 75,80. Explicitly export CHARGE_LIMIT=70,80
# on BAT* so upowerd writes 70-80 instead of clobbering start_threshold to 0.
ACTION!="remove", SUBSYSTEM=="power_supply", KERNEL=="BAT*", ENV{CHARGE_LIMIT}="70,80"
EOF
cat > /etc/udev/rules.d/71-thinkpad-t14s-touchpad-wakeup.rules <<'EOF'
# ThinkPad T14s Gen 3 AMD (21CQ/21CR): disable I2C touchpad wakeup from s2idle.
# Prevents spurious wakeups when the lid flexes in transit (ArchWiki T14s Gen 3 AMD).
# Matches both Elan (i2c-ELAN0678:00) and Synaptics (i2c-SYNA8018:00) SKUs.
ACTION=="add|change", SUBSYSTEM=="i2c", KERNEL=="i2c-ELAN0678:*|i2c-SYNA8018:*", ATTR{power/wakeup}="disabled"
EOF
cat > /etc/systemd/logind.conf.d/thinkpad-lid.conf <<'EOF'
[Login]
# Battery / unknown: suspend on lid. On charger: stay awake (GNOME mirrors this).
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
cat > /usr/local/lib/thinkpad/apply-charge-thresholds.sh <<'EOF'
#!/usr/bin/env bash
# Wait for thinkpad_acpi BAT* charge_control_*, then apply 70–80. Exit 0 if absent (VM).
set -euo pipefail
START=70 END=80
for _ in $(seq 1 60); do
  shopt -s nullglob
  found=(/sys/class/power_supply/BAT*/charge_control_end_threshold)
  shopt -u nullglob
  ((${#found[@]} > 0)) && break
  sleep 1
done
shopt -s nullglob
for bat in /sys/class/power_supply/BAT*; do
  [[ -d $bat ]] || continue
  if [[ -e $bat/charge_control_start_threshold ]]; then
    printf '%s\n' "$START" >"$bat/charge_control_start_threshold" || true
  fi
  if [[ -e $bat/charge_control_end_threshold ]]; then
    printf '%s\n' "$END" >"$bat/charge_control_end_threshold" || true
  fi
done
shopt -u nullglob
exit 0
EOF
chmod 755 /usr/local/lib/thinkpad/apply-charge-thresholds.sh
cat > /etc/systemd/system/thinkpad-charge-thresholds.service <<'EOF'
[Unit]
Description=ThinkPad battery charge thresholds (70-80)
Documentation=file:///usr/local/lib/thinkpad/apply-charge-thresholds.sh
After=multi-user.target
# Do not use ConditionPathExists*: BAT* may appear after early boot.

[Service]
Type=oneshot
ExecStart=/usr/local/lib/thinkpad/apply-charge-thresholds.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable thinkpad-charge-thresholds.service
else
  say "SKIP_THINKPAD_HW — charge thresholds not installed"
fi
