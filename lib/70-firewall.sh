#!/usr/bin/env bash
# 70-firewall.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

# firewalld (nftables). Default zone: drop (deny inbound). Not "public".
# Called from chroot after base services; optional ports from answers.
# Prefer firewall-offline-cmd: firewalld is not running inside arch-chroot.

# Run a permanent firewalld mutation (offline in chroot, live if daemon up).
_fw_perm() {
  if command -v firewall-offline-cmd >/dev/null 2>&1; then
    firewall-offline-cmd "$@"
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent "$@"
  else
    firewall-cmd --permanent "$@"
  fi
}

configure_firewalld() {
  say "firewalld: default zone drop + optional ports"

  mkdir -p /etc/firewalld
  if [[ ! -f /etc/firewalld/firewalld.conf ]]; then
    printf '%s\n' '# seeded by Stage A' 'DefaultZone=drop' 'FirewallBackend=nftables' \
      > /etc/firewalld/firewalld.conf
  else
    sed -i 's/^FirewallBackend=.*/FirewallBackend=nftables/' /etc/firewalld/firewalld.conf || true
    grep -q '^FirewallBackend=' /etc/firewalld/firewalld.conf \
      || echo 'FirewallBackend=nftables' >> /etc/firewalld/firewalld.conf
    if grep -q '^DefaultZone=' /etc/firewalld/firewalld.conf; then
      sed -i 's/^DefaultZone=.*/DefaultZone=drop/' /etc/firewalld/firewalld.conf
    else
      echo 'DefaultZone=drop' >> /etc/firewalld/firewalld.conf
    fi
  fi

  # Never let ufw fight firewalld on nftables.
  systemctl disable --now ufw 2>/dev/null || true
  systemctl mask ufw 2>/dev/null || true

  if yn_on "${ENABLE_SSHD:-N}"; then
    _fw_perm --add-service=ssh \
      || warn "firewalld: could not add ssh service"
  fi

  # Syncthing: transfer 22000/tcp (+ optional quic 22000/udp), discovery 21027/udp
  if yn_on "${FW_SYNCTHING:-${UFW_SYNCTHING:-N}}"; then
    _fw_perm --add-port=22000/tcp \
      || warn "firewalld: could not allow Syncthing 22000/tcp"
    _fw_perm --add-port=22000/udp \
      || warn "firewalld: could not allow Syncthing 22000/udp"
    _fw_perm --add-port=21027/udp \
      || warn "firewalld: could not allow Syncthing 21027/udp"
  fi

  if yn_on "${FW_KDECONNECT:-${UFW_KDECONNECT:-N}}"; then
    _fw_perm --add-port=1714-1764/tcp \
      || warn "firewalld: could not allow KDE Connect tcp"
    _fw_perm --add-port=1714-1764/udp \
      || warn "firewalld: could not allow KDE Connect udp"
  fi

  # Live reload only when the daemon is up (skip in chroot / offline path).
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --reload || warn "firewalld: reload failed"
  fi
  ok "firewalld configured (zone drop)"
}

check_firewalld() {
  systemctl is-active --quiet firewalld 2>/dev/null \
    || systemctl is-enabled --quiet firewalld 2>/dev/null
}
