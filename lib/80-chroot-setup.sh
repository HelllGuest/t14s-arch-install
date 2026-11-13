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

stage 0 4 "locale, time, hostname, pacman"
# time / locale / keymap
if [[ $TIMEZONE == UTC ]]; then
  ln -sf /usr/share/zoneinfo/UTC /etc/localtime
else
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
fi
hwclock --systohc
# Escape BRE metacharacters so en_US.UTF-8 dots are literal in sed.
_loc_esc=$(printf '%s\n' "$LOCALE" | sed 's/[.[\\*^$]/\\&/g')
sed -i "s/^#${_loc_esc} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
grep -qxF "${LOCALE} UTF-8" /etc/locale.gen \
  || echo "${LOCALE} UTF-8" >> /etc/locale.gen
unset -v _loc_esc
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname / hosts: FQDN first, then short label (Debian/Ubuntu convention).
echo "$HOSTNAME" > /etc/hostname
_host_short=${HOSTNAME%%.*}
if [[ $_host_short == "$HOSTNAME" ]]; then
  cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
else
  cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME} ${_host_short}
EOF
fi
unset -v _host_short

# pacman before the UKI stage: a multilib -Syu that upgrades a kernel then
# runs its mkinitcpio hook before our presets exist (no double UKI build).
# pacman: parallel built-in downloader, no download timeout abort, Color/
# ILoveCandy/VerbosePkgLists, optional [multilib] (same helper as the live ISO).
PACMAN_PARALLEL="${PACMAN_PARALLEL:-10}"
pacman_tune /etc/pacman.conf "$PACMAN_PARALLEL" "$(yn_on "${INSTALL_MULTILIB:-N}" && echo Y || echo N)"
if yn_on "${INSTALL_MULTILIB:-N}"; then
  # -Syu, never bare -Sy (partial upgrades); target is fresh so this is cheap.
  pacman -Syu --noconfirm || say "WARN: could not sync [multilib] database"
fi
# makepkg (yay / AUR builds): all cores, Zen 3+ x86-64-v3, no -debug split packages
# (Arch default OPTIONS with debug → !debug; zstd is already -T0 upstream).
mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/t14s.conf <<'EOF'
# Local/AUR builds: Zen 3+ Rembrandt (T14s Gen 3) is x86-64-v3 (AVX2/BMI2/FMA).
MAKEFLAGS="-j$(nproc)"
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
if [[ ${CFLAGS-} == *"-march=x86-64"* && ${CFLAGS-} != *"-march=x86-64-v"* ]]; then
  CFLAGS="${CFLAGS/-march=x86-64/-march=x86-64-v3}"
  CFLAGS="${CFLAGS/-mtune=generic /}"
fi
if [[ ${CXXFLAGS-} == *"-march=x86-64"* && ${CXXFLAGS-} != *"-march=x86-64-v"* ]]; then
  CXXFLAGS="${CXXFLAGS/-march=x86-64/-march=x86-64-v3}"
  CXXFLAGS="${CXXFLAGS/-mtune=generic /}"
fi
case "${RUSTFLAGS-} " in
  *" -C target-cpu="* | *" target-cpu="*) ;;
  *) RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C target-cpu=x86-64-v3" ;;
esac
GOAMD64="${GOAMD64:-v3}"
EOF
# Weekly cache trim (keeps 3 versions; pacman-contrib is in the base set).
systemctl enable paccache.timer

stage 4 6 "users and passwords"
# users — secrets from /root/.install-secrets (0600; shredded after chroot)
# shellcheck disable=SC1091
source /root/.install-secrets
echo "root:${ROOT_PASS}" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
unset -v USER_PASS ROOT_PASS
rm -f /root/.install-secrets
stage 6 8 "initramfs and kernel cmdline"
# initramfs (systemd + sd-encrypt for LUKS; optional plymouth)
_HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)'
if yn_on "${INSTALL_PLYMOUTH}"; then
  _HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt plymouth filesystems fsck)'
fi
sed -i "s/^HOOKS=.*/${_HOOKS}/" /etc/mkinitcpio.conf
unset -v _HOOKS
grep -Eq '^HOOKS=.*sd-encrypt' /etc/mkinitcpio.conf \
  || { echo "ERROR: mkinitcpio HOOKS missing sd-encrypt after sed" >&2; exit 1; }

# kernel cmdline (shared by UKIs)
mkdir -p /etc/kernel
# BIOS Sleep = "Windows and Linux" pairs with mem_sleep_default=s2idle.
_cmdline="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3 mem_sleep_default=s2idle apparmor=1 security=apparmor"
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

stage 8 24 "building unified kernel images"
# UKI presets: linux-lts (primary) + linux-hardened (fallback)
# Re-clean Arch EFI artifacts before rebuild (host already cleaned /mnt/boot).
if yn_on "${CLEAN_ESP_ARCH}"; then
  say "CLEAN_ESP_ARCH — removing old Arch UKIs / loader entries / EFI/arch"
fi
# Do NOT touch /boot/vmlinuz-* or *-ucode.img here: pacstrap just installed
# them and mkinitcpio -P below reads ALL_kver from vmlinuz. Stale copies were
# already removed on the host before pacstrap (clean_esp_arch_files).
# Full UKI / loader-entry clean only when CLEAN_ESP_ARCH=Y.
# (Function inlined — chroot has no host helpers.)
if yn_on "${CLEAN_ESP_ARCH}"; then
  rm -f /boot/EFI/Linux/arch-linux*.efi /boot/EFI/Linux/arch*.efi 2>/dev/null || true
  if [[ -d /boot/loader/entries ]]; then
    find /boot/loader/entries -maxdepth 1 -type f \
      -name 'arch*.conf' -delete 2>/dev/null || true
  fi
  rm -rf /boot/EFI/arch /boot/EFI/Arch /boot/EFI/ARCH 2>/dev/null || true
fi
mkdir -p /boot/EFI/Linux
cat > /etc/mkinitcpio.d/linux-lts.preset <<EOF
# ALL_kver is REQUIRED — mkinitcpio reads the kernel version from this vmlinuz.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-lts.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-lts-fallback.efi"
fallback_options="-S autodetect"
EOF
cat > /etc/mkinitcpio.d/linux-hardened.preset <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-hardened"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-hardened.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-hardened-fallback.efi"
fallback_options="-S autodetect"
EOF
if yn_on "${INSTALL_LINUX_STABLE}"; then
  cat > /etc/mkinitcpio.d/linux.preset <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF
fi
say "building UKIs"
mkinitcpio -P
# drop redundant non-UKI initramfs left by the pacstrap install hook — UKI-only
# presets won't regenerate them, so this frees ESP space permanently.
rm -f /boot/initramfs-linux-lts.img /boot/initramfs-linux-lts-fallback.img \
      /boot/initramfs-linux-hardened.img /boot/initramfs-linux-hardened-fallback.img \
      /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
# ESP free-space gate after UKI build (dual UKIs need headroom for updates).
_esp_free_mb="$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')"
if [[ ${_esp_free_mb:-} =~ ^[0-9]+$ ]]; then
  if (( _esp_free_mb < 64 )); then
    echo "ERROR: ESP nearly full after UKI build (${_esp_free_mb}MB free). Enlarge ESP or drop linux-stable." >&2
    exit 1
  elif (( _esp_free_mb < 200 )); then
    say "WARN: ESP low after UKI build (${_esp_free_mb}MB free) — leave room for kernel updates"
  else
    say "ESP free after UKI build: ${_esp_free_mb}MB"
  fi
fi
unset -v _esp_free_mb

stage 24 27 "systemd-boot"
# bootloader — when reusing a shared/multiboot ESP, back up another OS's fallback
# loader first. On a freshly-formatted ESP there's nothing to preserve (no clutter).
say "systemd-boot"
# cp -n keeps the first (pre-Arch) backup across installer re-runs.
if [[ ${FORMAT_EFI:-1} == 0 ]]; then
  for _bk in /boot/EFI/BOOT/BOOTX64.EFI /boot/loader/loader.conf; do
    [[ -f $_bk ]] || continue
    if cp -n "$_bk" "$_bk.pre-arch.bak"; then
      say "backed up existing ${_bk#/boot} -> .pre-arch.bak"
    else
      say "WARN: could not back up ${_bk#/boot} before replacing it"
    fi
  done
  unset -v _bk
fi
bootctl install
# inform: coexisting loaders systemd-boot will auto-detect (Windows, other Linux)
find /boot/EFI -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's,^,   loader dir: ,' || true
cat > /boot/loader/loader.conf <<EOF
default arch-linux-lts.efi
timeout 3
editor no
console-mode max
EOF

stage 27 30 "zram, sysctl, firewall, mirrors"
# zram size from wizard (half / quarter / fixed 8G)
case ${ZRAM_SIZE:-half} in
  quarter) _zram_expr='min(ram / 4, 8192)' ;;
  8192) _zram_expr='8192' ;;
  *) _zram_expr='min(ram / 2, 16384)' ;;
esac
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${_zram_expr}
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
unset -v _zram_expr

# sysctl hardening
cat > /etc/sysctl.d/99-security.conf <<EOF
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
net.core.bpf_jit_harden = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
vm.swappiness = 100
EOF
# userns: needed for Flatpak under linux-hardened; '-' = ignore on LTS (key absent)
echo '-kernel.unprivileged_userns_clone = 1' > /etc/sysctl.d/99-userns.conf

# firewalld zone drop seeded later via configure_firewalld (lib/70-firewall.sh)

# reflector mirrors (weekly timer; rate-rating must not serialize on dead mirrors)
{
  printf '%s\n' '--latest 10' '--protocol https' '--sort rate' '--threads 5'
  printf '%s\n' '--connection-timeout 3' '--download-timeout 5'
  printf '%s\n' '--save /etc/pacman.d/mirrorlist'
  if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
    printf -- '--country %s\n' "$REFLECTOR_COUNTRY"
  fi
} > /etc/xdg/reflector/reflector.conf


stage 30 34 "services and snapshots"
# services (firewalld; ufw masked inside configure_firewalld before first boot)
systemctl enable NetworkManager apparmor firewalld bluetooth fstrim.timer reflector.timer \
                 systemd-tmpfiles-clean.timer


# snapper config for / (handle pre-existing @snapshots mount) — non-fatal
umount /.snapshots 2>/dev/null || true
rmdir  /.snapshots 2>/dev/null || true
if snapper --no-dbus -c root create-config /; then
  btrfs subvolume delete /.snapshots 2>/dev/null || true
  mkdir -p /.snapshots; mount -a || true; chmod 750 /.snapshots
  # Bounded retention (defaults keep 10 hourly + 10 daily + 10 monthly + 10
  # yearly); wheel may browse snapshots (btrfs-assistant, snapper list).
  snapper --no-dbus -c root set-config \
    TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=0 \
    TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=10 \
    ALLOW_GROUPS=wheel SYNC_ACL=yes \
    || say "WARN: snapper root set-config failed — default retention kept"
  systemctl enable snapper-timeline.timer snapper-cleanup.timer
else
  say "WARN: snapper create-config failed — skipping snapshots (configure post-boot)"
  mkdir -p /.snapshots; mount -a || true
fi
if yn_on "${INSTALL_SNAPPER_HOME}"; then
  say "snapper config for /home"
  if snapper --no-dbus -c home create-config /home; then
    snapper --no-dbus -c home set-config \
      TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=0 \
      TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=10 \
      ALLOW_GROUPS=wheel SYNC_ACL=yes \
      || say "WARN: snapper home set-config failed — default retention kept"
    say "snapper home config created"
  else
    say "WARN: snapper home create-config failed — configure post-boot"
  fi
fi

stage 34 72 "GNOME desktop, apps and Flatpaks"
# minimal GNOME (optional)
if yn_on "$DESKTOP"; then
  say "installing minimal GNOME + browsers + VPN + software center"
  # sof-firmware+alsa-ucm-conf: Rembrandt audio.
  # mesa+vulkan-radeon+fprintd: Radeon 680M (libva via mesa Provides). No Yoga / iio.
  # FP (D-Bus-activated — do NOT systemctl enable). Skip fprintd on VM.
  # browsers + proton-vpn: Flatpak. gnome-software: Flatpak software center.
  # Non-fatal: a network hiccup here must not abort an otherwise-bootable base system.
  _gnome_pkgs=(
    gnome-shell gnome-session gdm gnome-control-center gnome-keyring
    gnome-backgrounds nautilus gnome-console gnome-text-editor
    gnome-system-monitor gnome-calculator loupe evince gnome-disk-utility
    xdg-user-dirs-gtk xdg-desktop-portal xdg-desktop-portal-gnome polkit
    flatpak fwupd bolt pipewire pipewire-pulse wireplumber earlyoom
    rtkit evolution-data-server
    sof-firmware alsa-ucm-conf
    gnome-software
  )
  case ${HW_PROFILE:-t14s} in
    p15)
      _gnome_pkgs+=(mesa vulkan-intel intel-media-driver libva-utils
        nvidia-open-dkms nvidia-utils nvidia-prime egl-wayland)
      ;;
    *)
      _gnome_pkgs+=(mesa vulkan-radeon libva-utils)
      ;;
  esac
  # rtkit: realtime for PipeWire + gnome-shell KMS thread.
  # evolution-data-server: gnome-shell CalendarServer (top-bar calendar).
  # Power profiles: tuned + tuned-ppd (provides/conflicts power-profiles-daemon;
  # GNOME's power menu talks to tuned-ppd; tuned ships tuned-gui) or plain PPD.
  if yn_on "${INSTALL_TUNED}"; then
    _gnome_pkgs+=(tuned tuned-ppd)
    _power_units=(tuned.service tuned-ppd.service)
  else
    _gnome_pkgs+=(power-profiles-daemon)
    _power_units=(power-profiles-daemon.service)
  fi
  if yn_on "${INSTALL_BTRFS_ASSISTANT}"; then
    _gnome_pkgs+=(btrfs-assistant)
  fi
  if ! yn_on "${SKIP_THINKPAD_HW}"; then
    _gnome_pkgs+=(fprintd)
  fi
  if pkg_try "GNOME desktop" "${_gnome_pkgs[@]}"
  then
    unset -v _gnome_pkgs
    systemctl enable gdm bolt.service earlyoom.service "${_power_units[@]}"
    mkdir -p /etc/gdm /etc/environment.d /etc/udev/rules.d /etc/systemd/system/gdm.service.d \
      /etc/dconf/db/gdm.d /etc/dconf/profile
    cat > /etc/gdm/custom.conf <<'EOF'
[daemon]
WaylandEnable=true
AutomaticLoginEnable=false
TimedLoginEnable=false

[security]
DisallowTCP=true

[xdmcp]
Enable=false
EOF
    printf '%s\n' 'user-db:user' 'system-db:gdm' 'file-db:/usr/share/gdm/greeter-dconf-defaults' \
      > /etc/dconf/profile/gdm
    # GDM greeter (not user session); compiled by the dconf update below.
    cat > /etc/dconf/db/gdm.d/00-login-screen <<'EOF'
[org/gnome/login-screen]
disable-user-list=true
banner-message-enable=false
enable-fingerprint-authentication=true
enable-smartcard-authentication=false

[org/gnome/desktop/session]
idle-delay=uint32 60

[org/gnome/desktop/interface]
clock-show-seconds=false
clock-show-date=true
clock-format='24h'
color-scheme='prefer-dark'
cursor-theme='Adwaita'
cursor-size=24
icon-theme='Adwaita'

[org/gnome/desktop/background]
picture-uri=''
picture-uri-dark=''
primary-color='#2b2e30'
secondary-color='#2b2e30'
color-shading-type='solid'
picture-options='none'

[org/gnome/desktop/screensaver]
picture-uri=''
primary-color='#2b2e30'
color-shading-type='solid'
picture-options='none'

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='blank'
sleep-inactive-battery-timeout=180

[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=false
screen-magnifier-enabled=false

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']
EOF
    # No fprintd on VM / SKIP_THINKPAD_HW: don't offer fingerprint at the greeter.
    if yn_on "${SKIP_THINKPAD_HW}"; then
      sed -i 's/^enable-fingerprint-authentication=true$/enable-fingerprint-authentication=false/' \
        /etc/dconf/db/gdm.d/00-login-screen
    fi
    _libva=radeonsi
    [[ ${HW_PROFILE:-t14s} == p15 ]] && _libva=iHD
    cat > /etc/environment.d/99-wayland.conf <<EOF
# Wayland + VA-API defaults for GNOME Shell (${_libva})
OZONE_PLATFORM=wayland
MOZ_ENABLE_WAYLAND=1
MOZ_DBUS_REMOTE=1
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
SDL_VIDEODRIVER=wayland
CLUTTER_BACKEND=wayland
LIBVA_DRIVER_NAME=${_libva}
EOF
    if [[ ${HW_PROFILE:-t14s} == p15 ]]; then
      cat > /etc/udev/rules.d/61-gdm-wayland.rules <<'EOF'
# Intel + NVIDIA Optimus — keep GDM on Wayland
SUBSYSTEM=="drm", KERNEL=="card*", \
  ATTRS{vendor}=="0x8086", \
  TAG+="seat", TAG+="uaccess", \
  ENV{GDM_DISABLE_WAYLAND}=""

SUBSYSTEM=="drm", KERNEL=="card*", \
  ATTRS{vendor}=="0x10de", \
  ENV{GDM_DISABLE_WAYLAND}=""
EOF
    else
      cat > /etc/udev/rules.d/61-gdm-wayland.rules <<'EOF'
# AMD Radeon 680M Rembrandt (1002:1681) — keep GDM on Wayland
SUBSYSTEM=="drm", KERNEL=="card*", \
  ATTRS{vendor}=="0x1002", ATTRS{device}=="0x1681", \
  TAG+="seat", TAG+="uaccess", \
  ENV{GDM_DISABLE_WAYLAND}=""

SUBSYSTEM=="drm", KERNEL=="card*", \
  ATTRS{vendor}=="0x1002", \
  ENV{GDM_DISABLE_WAYLAND}=""
EOF
    fi
    cat > /etc/systemd/system/gdm.service.d/override.conf <<EOF
# /etc/systemd/system/gdm.service.d/override.conf

[Service]
Environment=GDK_BACKEND=wayland
Environment=CLUTTER_BACKEND=wayland
Environment=QT_QPA_PLATFORM=wayland
Environment=LIBVA_DRIVER_NAME=${_libva}
OOMScoreAdjust=-500
Restart=always
RestartSec=1s
EOF
    unset -v _libva
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    # Flatpak apps install on FIRST BOOT, not here: their runtimes (two
    # freedesktop versions + GL/codecs/locale + GNOME) are pure download and
    # took ~11 min of the last install. A oneshot after network-online does
    # one transaction; on failure it retries every 5 min (stamp only on success).
    # Chrome (extra-data) still needs the user helper (bwrap userns).
    stage 58 72 "Flatpak first-boot service"
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/t14s-flatpak-apps <<'FP'
#!/usr/bin/env bash
# First-boot Flatpak apps (written by t14s-arch-install). Log: journalctl -u t14s-flatpak-apps
set -uo pipefail
apps=(com.brave.Browser app.zen_browser.zen io.gitlab.librewolf-community com.protonvpn.www)
flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak install --system -y --noninteractive flathub "${apps[@]}"; then
  for a in "${apps[@]}"; do
    flatpak info --system "$a" >/dev/null 2>&1 \
      || flatpak install --system -y --noninteractive flathub "$a" || echo "failed: $a"
  done
fi
for a in "${apps[@]}"; do
  flatpak info --system "$a" >/dev/null 2>&1 || { echo "missing $a — will retry next boot"; exit 1; }
done
mkdir -p /var/lib/t14s && touch /var/lib/t14s/flatpak-apps.done
FP
    chmod 755 /usr/local/sbin/t14s-flatpak-apps
    cat > /etc/systemd/system/t14s-flatpak-apps.service <<'FP'
[Unit]
Description=Install Flatpak apps (first boot, t14s-arch-install)
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/t14s/flatpak-apps.done
# First boot often has no saved Wi-Fi yet: keep retrying every 5 min
# (oneshot + Restart= needs systemd >= 244) until the user connects.
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/t14s-flatpak-apps
Restart=on-failure
RestartSec=5min
TimeoutStartSec=30min
Nice=10
FP
    # Started by a timer, not WantedBy=multi-user.target: targets order After=
    # the units they want, so a oneshot retrying until Wi-Fi exists would hold
    # multi-user/graphical.target "starting" for the whole first boot.
    cat > /etc/systemd/system/t14s-flatpak-apps.timer <<'FP'
[Unit]
Description=Start first-boot Flatpak app install (t14s-arch-install)
ConditionPathExists=!/var/lib/t14s/flatpak-apps.done

[Timer]
OnBootSec=1min

[Install]
WantedBy=timers.target
FP
    # Explicit (NetworkManager's Also= enables it too) so network-online
    # really waits for NM on boot.
    systemctl enable NetworkManager-wait-online.service t14s-flatpak-apps.timer
    # archdi-style X11/Wayland keymap from console KEYMAP.
    # Console map names ≠ XKB layout/variant; remap commons, else best-effort.
    XKB_LAYOUT='' XKB_VARIANT=''
    case $KEYMAP in
      us|de|fr|es|it|ru) XKB_LAYOUT=$KEYMAP ;;
      uk) XKB_LAYOUT=gb ;;
      jp106) XKB_LAYOUT=jp ;;
      pt-latin1) XKB_LAYOUT=pt ;;
      br-abnt2) XKB_LAYOUT=br; XKB_VARIANT=abnt2 ;;
      dvorak) XKB_LAYOUT=us; XKB_VARIANT=dvorak ;;
      colemak) XKB_LAYOUT=us; XKB_VARIANT=colemak ;;
      *)
        XKB_LAYOUT=${KEYMAP%%-*}
        [[ $KEYMAP == *-* ]] && XKB_VARIANT=${KEYMAP#*-}
        ;;
    esac
    [[ -n $XKB_LAYOUT ]] || XKB_LAYOUT=us
    write_xkb_conf() {
      mkdir -p /etc/X11/xorg.conf.d
      {
        printf '%s\n' 'Section "InputClass"'
        printf '%s\n' '        Identifier "system-keyboard"'
        printf '%s\n' '        MatchIsKeyboard "on"'
        printf '        Option "XkbLayout" "%s"\n' "$XKB_LAYOUT"
        [[ -n $XKB_VARIANT ]] \
          && printf '        Option "XkbVariant" "%s"\n' "$XKB_VARIANT"
        printf '%s\n' 'EndSection'
      } > /etc/X11/xorg.conf.d/00-keyboard.conf
    }
    if command -v localectl >/dev/null 2>&1 \
      && localectl set-x11-keymap "$XKB_LAYOUT" "" "$XKB_VARIANT" "" 2>/dev/null; then
      :
    else
      write_xkb_conf
      say "WARN: localectl set-x11-keymap failed or missing — wrote 00-keyboard.conf ($XKB_LAYOUT${XKB_VARIANT:+|$XKB_VARIANT})"
    fi
    unset -f write_xkb_conf
  else
    unset -v _gnome_pkgs
    say "WARN: GNOME install incomplete (network?) — base system is fine. Finish post-boot:"
    say "      pacman -S gnome-shell gdm && systemctl enable gdm"
  fi
fi

stage 72 78 "fonts and GNOME defaults"
# Curated Nerd Fonts + UI fonts (matches HelllGuest install-fonts.sh; not full group).
if yn_on "${INSTALL_NERD_FONTS}"; then
  say "installing Nerd Fonts + Inter/Noto"
  if pkg_try "Nerd Fonts" \
    ttf-jetbrains-mono-nerd ttf-meslo-nerd ttf-firacode-nerd \
    ttf-cascadia-mono-nerd ttf-cascadia-code-nerd ttf-hack-nerd \
    ttf-iosevka-nerd ttf-iosevkaterm-nerd ttf-victor-mono-nerd \
    ttf-ibmplex-mono-nerd ttf-sourcecodepro-nerd ttf-dejavu-nerd \
    otf-geist-mono-nerd otf-commit-mono-nerd \
    ttf-nerd-fonts-symbols-common \
    inter-font noto-fonts noto-fonts-emoji
  then
    fc-cache -f >/dev/null 2>&1 || true
  fi
fi

# GNOME dconf defaults (color-scheme; fonts only when Nerd Fonts installed).
if yn_on "$DESKTOP"; then
  say "applying GNOME dconf defaults for $USERNAME"
  sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.config/dconf"
  mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
  printf '%s\n' 'user-db:user' 'system-db:local' > /etc/dconf/profile/user
  cat > /etc/dconf/db/local.d/00-t14s <<'DCONF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/desktop/peripherals/touchpad]
tap-to-click=true
natural-scroll=true

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']
DCONF
  if yn_on "${INSTALL_NERD_FONTS}"; then
    cat >> /etc/dconf/db/local.d/00-t14s <<'DCONF'

[org/gnome/desktop/interface]
font-name='Inter 11'
document-font-name='Inter 11'
monospace-font-name='JetBrainsMono Nerd Font Mono 11'

[org/gnome/Console]
font='JetBrainsMono Nerd Font Mono 12'
DCONF
  fi
  dconf update || say "WARN: dconf update failed; GNOME/GDM dconf defaults not applied"
fi

stage 78 92 "optional packages"
# archdi print stack (optional)
if yn_on "${INSTALL_CUPS}"; then
  say "installing CUPS printing stack"
  if pkg_try "CUPS" cups cups-pdf ghostscript; then
    systemctl enable cups.service
  fi
fi

# CLI tools
if yn_on "${INSTALL_CLI}"; then
  say "installing CLI tools (ripgrep fd fzf bat eza jq git-delta)"
  pkg_try "CLI tools" ripgrep fd fzf bat eza jq git-delta || true
fi

# Starship
if yn_on "${INSTALL_STARSHIP}"; then
  say "installing starship"
  if pkg_try "starship" starship; then
    sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.config"
    sudo -u "$USERNAME" tee "/home/$USERNAME/.config/starship.toml" >/dev/null <<'S'
# t14s default — customize after first boot
add_newline = false
S
    if ! grep -q 'starship init zsh' "/home/$USERNAME/.zshrc" 2>/dev/null; then
      printf '%s\n' 'eval "$(starship init zsh)"' \
        | sudo -u "$USERNAME" tee -a "/home/$USERNAME/.zshrc" >/dev/null
    fi
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config" "/home/$USERNAME/.zshrc"
  fi
fi

# Podman
if yn_on "${INSTALL_PODMAN}"; then
  say "installing podman + buildah"
  pkg_try "podman" podman buildah || true
fi

# Docker
if yn_on "${INSTALL_DOCKER}"; then
  say "installing docker"
  if pkg_try "docker" docker docker-compose; then
    systemctl enable docker.service
    usermod -aG docker "$USERNAME" || true
  fi
fi

# libvirt / qemu
if yn_on "${INSTALL_VIRT}"; then
  say "installing libvirt + qemu + virt-manager"
  if pkg_try "libvirt/qemu" libvirt qemu-desktop virt-manager edk2-ovmf dnsmasq; then
    systemctl enable libvirtd.service
    usermod -aG libvirt "$USERNAME" || true
  fi
fi

# tuned without GNOME (GNOME path installs tuned + tuned-ppd above).
if yn_on "${INSTALL_TUNED}" && ! yn_on "$DESKTOP"; then
  if pkg_try "tuned" tuned; then
    systemctl enable tuned.service
  fi
fi

# TLP (console-only — desktop path already cleared INSTALL_TLP)
if yn_on "${INSTALL_TLP}"; then
  say "installing TLP"
  if pkg_try "TLP" tlp tlp-rdw; then
    systemctl enable tlp.service
  fi
fi

# thinkfan is AUR-only — leave a post-boot note instead of a failing pacman -S.
if yn_on "${INSTALL_THINKFAN}"; then
  cat > /root/t14s-thinkfan.txt <<'TF'
thinkfan is not in official Arch repos (AUR). After first boot with an AUR helper:
  yay -S thinkfan
  # then configure /etc/thinkfan.conf for your T14s and:
  sudo systemctl enable --now thinkfan
TF
  say "wrote /root/t14s-thinkfan.txt (AUR install notes)"
fi

# Avahi / mDNS
if yn_on "${INSTALL_AVAHI}"; then
  say "installing avahi + nss-mdns"
  if pkg_try "avahi" avahi nss-mdns; then
    systemctl enable avahi-daemon.service
    # Ensure .local resolution (nss-mdns package may not patch hosts line alone).
    if [[ -f /etc/nsswitch.conf ]] \
      && ! grep -q 'mdns_minimal' /etc/nsswitch.conf; then
      sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
        /etc/nsswitch.conf \
        || say "WARN: could not patch nsswitch.conf for mdns_minimal"
    fi
  fi
fi

# WireGuard / Tailscale
if yn_on "${INSTALL_WIREGUARD}"; then
  pkg_try "wireguard-tools" wireguard-tools || true
fi
if yn_on "${INSTALL_TAILSCALE}"; then
  if pkg_try "tailscale" tailscale; then
    systemctl enable tailscaled.service
  fi
fi

# Developer tools (toolchains, debuggers, editors). rustup: run
# `rustup default stable` after first login (per-user toolchain).
if yn_on "${INSTALL_DEVTOOLS}"; then
  say "installing developer tools"
  _dev_pkgs=(
    git-lfs github-cli lazygit neovim
    python python-pip python-pipx nodejs npm go rustup
    cmake ninja meson clang lldb gdb valgrind perf strace ltrace
    shellcheck shfmt httpie man-db man-pages tealdeer
  )
  yn_on "$DESKTOP" && _dev_pkgs+=(code)
  pkg_try "developer tools" "${_dev_pkgs[@]}" || true
  unset -v _dev_pkgs
fi

# yay (AUR helper): build yay-bin as the new user, install with pacman -U as
# root — makepkg refuses root, and no sudoers NOPASSWD change is needed.
if yn_on "${INSTALL_YAY}"; then
  say "building yay (AUR yay-bin)"
  _yay_dir="/home/$USERNAME/.cache/t14s-yay"
  rm -rf "$_yay_dir"
  if pkg_try "yay build deps" git base-devel \
    && runuser -u "$USERNAME" -- mkdir -p "/home/$USERNAME/.cache" \
    && runuser -u "$USERNAME" -- git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$_yay_dir" \
    && runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" \
         bash -c 'cd "$1" && makepkg --noconfirm --nocheck' _ "$_yay_dir"; then
    _yay_pkg=$(find "$_yay_dir" -maxdepth 1 -name 'yay-bin-[0-9]*.pkg.tar.*' ! -name '*.sig' | head -n1)
    if [[ -n $_yay_pkg ]] && pacman -U --noconfirm --needed "$_yay_pkg"; then
      say "yay installed ($(pacman -Q yay-bin 2>/dev/null || echo yay-bin))"
    else
      say "WARN: yay package build produced nothing installable — install post-boot from AUR yay-bin"
    fi
  else
    say "WARN: yay build failed — after first boot: git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si"
  fi
  rm -rf "$_yay_dir"
  unset -v _yay_dir _yay_pkg
fi


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
# Quick Rembrandt laptop sanity after first boot.
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
# firewalld status (user-callable; no root required for is-enabled).
check_firewalld() {
  systemctl is-enabled --quiet firewalld 2>/dev/null || systemctl is-active --quiet firewalld
}
check bluetooth systemctl is-active --quiet bluetooth
check pipewire check_pipewire
check wifi check_wifi
check apparmor systemctl is-active --quiet apparmor
check firewalld check_firewalld
check mem_sleep grep -q '\[s2idle\]' /sys/power/mem_sleep
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]]; then
  check amd_pstate grep -q '^amd-pstate' /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
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

stage 95 100 "Secure Boot keys and signing"
# Secure Boot: create + sign now; enroll only if verify clean + Setup Mode.
say "sbctl: create keys + sign"
sbctl create-keys
for f in /boot/EFI/Linux/arch-linux-lts.efi /boot/EFI/Linux/arch-linux-lts-fallback.efi \
         /boot/EFI/Linux/arch-linux-hardened.efi /boot/EFI/Linux/arch-linux-hardened-fallback.efi \
         /boot/EFI/Linux/arch-linux.efi /boot/EFI/Linux/arch-linux-fallback.efi \
         /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI; do
  [[ -f $f ]] && sbctl sign -s "$f" || true
done
_sb_ok=0
if sbctl verify; then
  _sb_ok=1
  say "sbctl verify OK"
else
  say "WARN: sbctl verify failed — enroll blocked until signatures are fixed"
fi
if yn_on "${ENROLL_SB}"; then
  if (( _sb_ok )) && sbctl status 2>/dev/null | grep -qi 'setup mode.*enabled'; then
    say "enrolling Secure Boot keys (-m)"; sbctl enroll-keys -m || echo "enroll failed — do it post-reboot"
  elif (( ! _sb_ok )); then
    say "enroll skipped — sbctl verify failed"
  else
    say "enroll skipped — Setup Mode not enabled (enroll post-reboot)"
  fi
fi
unset -v _sb_ok

if yn_on "${ENABLE_SSHD}"; then
  say "enabling OpenSSH (sshd; firewalld allows ssh via configure_firewalld)"
  if pkg_try "openssh" openssh; then
    systemctl enable sshd
  fi
fi

# Optional local LLM (P15 Quadro T1000 4GB) — bind localhost only.
if yn_on "${INSTALL_OLLAMA:-N}" && [[ ${HW_PROFILE:-} == p15 ]]; then
  if pkg_try "ollama-cuda" ollama-cuda || pkg_try "ollama" ollama; then
    mkdir -p /etc/systemd/system/ollama.service.d
    cat > /etc/systemd/system/ollama.service.d/override.conf <<'OLL'
[Service]
Environment=OLLAMA_HOST=127.0.0.1:11434
Environment=OLLAMA_FLASH_ATTENTION=1
Environment=OLLAMA_KV_CACHE_TYPE=q8_0
Environment=OLLAMA_KEEP_ALIVE=5m
OLL
    systemctl enable ollama.service || true
    say "ollama enabled on 127.0.0.1:11434 — pull qwen2.5-coder:3b and qwen3.5:4b after first boot"
  fi
fi
if yn_on "${INSTALL_FAIL2BAN}"; then
  yn_on "${ENABLE_SSHD}" || say "fail2ban requested without sshd — installing anyway"
  if pkg_try "fail2ban" fail2ban; then
    mkdir -p /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/sshd.local <<'FB'
[sshd]
enabled = true
FB
    systemctl enable fail2ban.service
  fi
fi

# firewalld zone + optional ports + ssh service (lib/70-firewall.sh)
# shellcheck source=/dev/null
source /root/t14s-lib/70-firewall.sh
configure_firewalld
