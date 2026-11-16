#!/usr/bin/env bash
# 70-firewall.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

# firewalld (nftables). Default zone: drop (deny inbound). Not "public".
# Called from chroot after base services; optional ports from answers.
# Prefer firewall-offline-cmd: firewalld is not running inside arch-chroot.

# Chroot only defines say/stage/yn_on — keep logging self-contained.
_fw_say() { if declare -F say >/dev/null 2>&1; then say "$@"; else printf '>> %s\n' "$*"; fi; }
_fw_warn() { _fw_say "WARN: $*"; }
_fw_ok() { _fw_say "ok $*"; }

# Run a permanent firewalld mutation (offline in chroot, live if daemon up).
_fw_perm() {
  if [[ -x /usr/bin/firewall-offline-cmd ]] || command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd "$@"
    return
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent "$@"
    return
  fi
  _fw_warn "firewall-offline-cmd missing and firewalld inactive — cannot apply: $*"
  return 1
}

configure_firewalld() {
  # FIREWALLD_CONF: override for tests only (never touch the host /etc).
  local conf=${FIREWALLD_CONF:-/etc/firewalld/firewalld.conf}
  _fw_say "firewalld: default zone drop + optional ports"

  mkdir -p "$(dirname "$conf")"
  if [[ ! -f $conf ]]; then
    printf '%s\n' '# seeded by Stage A' 'DefaultZone=drop' 'FirewallBackend=nftables' \
      > "$conf"
  else
    sed -i 's/^FirewallBackend=.*/FirewallBackend=nftables/' "$conf" || true
    grep -q '^FirewallBackend=' "$conf" \
      || echo 'FirewallBackend=nftables' >> "$conf"
    if grep -q '^DefaultZone=' "$conf"; then
      sed -i 's/^DefaultZone=.*/DefaultZone=drop/' "$conf"
    else
      echo 'DefaultZone=drop' >> "$conf"
    fi
  fi

  # Never let ufw fight firewalld on nftables — mask unit and drop package.
  systemctl disable --now ufw 2>/dev/null || true
  systemctl mask ufw 2>/dev/null || true
  if command -v pacman >/dev/null 2>&1 && pacman -Q ufw >/dev/null 2>&1; then
    pacman -Rns --noconfirm ufw 2>/dev/null \
      || _fw_warn "firewalld: could not remove ufw package"
  fi

  if yn_on "${ENABLE_SSHD:-N}"; then
    _fw_perm --add-service=ssh \
      || _fw_warn "firewalld: could not add ssh service"
  fi

  # Avahi/nss-mdns: replies to .local queries come from other hosts, so conntrack
  # never matches them and the drop zone discards them without this service.
  if yn_on "${INSTALL_AVAHI:-N}"; then
    _fw_perm --add-service=mdns \
      || _fw_warn "firewalld: could not allow mdns"
  fi

  # Syncthing: transfer 22000/tcp (+ optional quic 22000/udp), discovery 21027/udp
  if yn_on "${FW_SYNCTHING:-N}"; then
    _fw_perm --add-port=22000/tcp \
      || _fw_warn "firewalld: could not allow Syncthing 22000/tcp"
    _fw_perm --add-port=22000/udp \
      || _fw_warn "firewalld: could not allow Syncthing 22000/udp"
    _fw_perm --add-port=21027/udp \
      || _fw_warn "firewalld: could not allow Syncthing 21027/udp"
  fi

  if yn_on "${FW_KDECONNECT:-N}"; then
    _fw_perm --add-port=1714-1764/tcp \
      || _fw_warn "firewalld: could not allow KDE Connect tcp"
    _fw_perm --add-port=1714-1764/udp \
      || _fw_warn "firewalld: could not allow KDE Connect udp"
  fi

  # Live reload only when a daemon is actually answering. In arch-chroot
  # `systemctl is-active` can still report success, so skip chroots explicitly
  # and ask firewalld itself (--state) instead of systemd.
  if ! systemd-detect-virt --chroot >/dev/null 2>&1 \
    && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --reload || _fw_warn "firewalld: reload failed"
  fi
  _fw_ok "firewalld configured (zone drop)"
}
