# 09-fonts-gnome-defaults.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 72-78 %: fonts and GNOME/GDM dconf defaults.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

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
