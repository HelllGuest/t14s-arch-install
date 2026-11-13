#!/usr/bin/env bash
# 70-firewall.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

# firewalld (nftables). Default zone: drop (deny inbound). Not "public".
# Called from chroot after base services; optional ports from answers.

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
    firewall-cmd --permanent --add-service=ssh || true
  fi

  # Syncthing: transfer 22000/tcp (+ optional quic 22000/udp), discovery 21027/udp
  if yn_on "${FW_SYNCTHING:-${UFW_SYNCTHING:-N}}"; then
    firewall-cmd --permanent --add-port=22000/tcp || true
    firewall-cmd --permanent --add-port=22000/udp || true
    firewall-cmd --permanent --add-port=21027/udp || true
  fi

  if yn_on "${FW_KDECONNECT:-${UFW_KDECONNECT:-N}}"; then
    firewall-cmd --permanent --add-port=1714-1764/tcp || true
    firewall-cmd --permanent --add-port=1714-1764/udp || true
  fi

  firewall-cmd --reload 2>/dev/null || true
  ok "firewalld configured (zone drop)"
}

check_firewalld() {
  systemctl is-active --quiet firewalld 2>/dev/null \
    || systemctl is-enabled --quiet firewalld 2>/dev/null
}
