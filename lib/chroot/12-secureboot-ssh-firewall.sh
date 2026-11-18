# 12-secureboot-ssh-firewall.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Chroot stage 95-100 %: Secure Boot keys and signing, sshd, fail2ban, firewalld.
# Sourced by 80-chroot-setup.sh inside arch-chroot, at top level and in
# order: shares its helpers, globals, set -e and umask as if inline.

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
    # Arch's default banaction is iptables-multiport (legacy iptables), outside
    # the nftables ruleset firewalld manages; ban through firewalld instead.
    cat > /etc/fail2ban/jail.d/00-firewalld.local <<'FB'
[DEFAULT]
banaction = firewallcmd-rich-rules
banaction_allports = firewallcmd-allports
FB
    systemctl enable fail2ban.service
  fi
fi

# firewalld zone + optional ports + ssh service (lib/70-firewall.sh)
# shellcheck source=/dev/null
source /root/t14s-lib/70-firewall.sh
configure_firewalld
