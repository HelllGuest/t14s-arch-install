# 06-zram-sysctl-mirrors.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 27-30 %: zram, sysctl hardening, reflector config.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

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
    # reflector shlex-splits each line: quote so "United States" stays one arg
    # (valid_reflector_country limits the value to letters, commas and spaces — no quotes).
    printf -- "--country '%s'\n" "$REFLECTOR_COUNTRY"
  fi
} > /etc/xdg/reflector/reflector.conf
