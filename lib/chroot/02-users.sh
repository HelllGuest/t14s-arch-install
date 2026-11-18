# 02-users.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 4-6 %: users, passwords, sudo (secrets file removed here).
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

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
