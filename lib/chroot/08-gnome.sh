# 08-gnome.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 34-72 %: minimal GNOME desktop, apps, Flatpak first-boot service.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

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
