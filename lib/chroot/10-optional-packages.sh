# 10-optional-packages.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 78-92 %: optional packages (CLI, containers, virt, dev tools, AUR helper).
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

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
