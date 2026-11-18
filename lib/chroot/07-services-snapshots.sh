# 07-services-snapshots.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 30-34 %: base services, timesyncd, snapper.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

stage 30 34 "services and snapshots"
# services (firewalld; ufw masked inside configure_firewalld before first boot)
# systemd-timesyncd: the preflight's `timedatectl set-ntp true` only affects the
# ISO; without this the installed system never synchronizes its clock.
systemctl enable NetworkManager apparmor firewalld bluetooth fstrim.timer reflector.timer \
                 systemd-tmpfiles-clean.timer systemd-timesyncd.service


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
