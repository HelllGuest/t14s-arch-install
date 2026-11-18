# 23-install-chroot.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Deploy and run the chroot setup (UKIs, users, services, desktop), write the
# firmware boot entry, collect install warnings, run the optional post-install hook.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 7. chroot configuration ─────────────────────────────────
say "deploying chroot setup + firewall module"
mkdir -p /mnt/root/t14s-lib
_deploy_lib() {
  local f=$1
  mkdir -p "$(dirname "/mnt/root/t14s-lib/$f")"
  if [[ -n ${T14S_LIB_DIR:-} && -f $T14S_LIB_DIR/$f ]]; then
    cp -a "$T14S_LIB_DIR/$f" "/mnt/root/t14s-lib/$f"
  elif [[ -n ${T14S_LIB_FETCH_DIR:-} && -f $T14S_LIB_FETCH_DIR/$f ]]; then
    cp -a "$T14S_LIB_FETCH_DIR/$f" "/mnt/root/t14s-lib/$f"
  else
    curl -fsSL "$T14S_BASE_URL/lib/$f" -o "/mnt/root/t14s-lib/$f" \
      || die "failed to fetch lib/$f from $T14S_BASE_URL"
  fi
  [[ -s /mnt/root/t14s-lib/$f ]] || die "deployed lib/$f is missing or empty"
}
_deploy_lib 70-firewall.sh
_deploy_lib 80-chroot-setup.sh
# Chroot stages, run in this order by 80-chroot-setup.sh (lib/chroot/).
for _cs in \
    01-base-config.sh 02-users.sh 03-initramfs-cmdline.sh 04-ukis.sh \
    05-systemd-boot.sh 06-zram-sysctl-mirrors.sh 07-services-snapshots.sh \
    08-gnome.sh 09-fonts-gnome-defaults.sh 10-optional-packages.sh \
    11-helpers-selftest.sh 12-secureboot-ssh-firewall.sh; do
  _deploy_lib "chroot/$_cs"
done
unset -v _cs
install -m 755 /mnt/root/t14s-lib/80-chroot-setup.sh /mnt/root/chroot-setup.sh
unset -f _deploy_lib


# Passwords via 0600 file (not arch-chroot env — visible in /proc/*/environ).
# umask 077 only in this subshell: a script-wide umask leaks into arch-chroot
# and leaves /etc/locale.conf, sysctl.d, dconf … at 0600 (LANG unset for users).
(
  umask 077
  {
    printf 'USERNAME=%q\n' "$USERNAME"
    printf 'USER_PASS=%q\n' "$USER_PASS"
    printf 'ROOT_PASS=%q\n' "$ROOT_PASS"
  } > /mnt/root/.install-secrets
)
chmod 600 /mnt/root/.install-secrets
unset -v USER_PASS ROOT_PASS

chmod +x /mnt/root/chroot-setup.sh
# Host helpers the chroot reuses (single source: no duplicated function bodies).
declare -f pacman_tune >/mnt/root/t14s-lib.sh
rm -f /mnt/root/t14s-warnings.txt
cleanup_chroot_secrets() {
  shred -u /mnt/root/chroot-setup.sh /mnt/root/.install-secrets 2>/dev/null \
    || rm -f /mnt/root/chroot-setup.sh /mnt/root/.install-secrets
  rm -f /mnt/root/t14s-lib.sh
  rm -rf /mnt/root/t14s-lib
}
# Always drop secrets file even if chroot fails (set -e would otherwise skip shred).
# SNAP_PAC_SKIP=y: snap-pac hooks can't run snapper in the chroot ("fatal
# library error, lookup self"); snapshots start on the booted system.
if ! run_gauge "chroot config (UKIs, users, optional GNOME)" 0 100 \
  arch-chroot /mnt env \
    TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" KEYMAP="$KEYMAP" HOSTNAME="$HOSTNAME" \
    USERNAME="$USERNAME" \
    LUKS_UUID="$LUKS_UUID" DESKTOP="$DESKTOP" ENROLL_SB="$ENROLL_SB" \
    ENABLE_SSHD="$ENABLE_SSHD" FORMAT_EFI="$FORMAT_EFI" \
    PACMAN_PARALLEL="$PACMAN_PARALLEL" INSTALL_CUPS="$INSTALL_CUPS" \
    INSTALL_NERD_FONTS="$INSTALL_NERD_FONTS" \
    INSTALL_CLI="$INSTALL_CLI" INSTALL_STARSHIP="$INSTALL_STARSHIP" \
    INSTALL_PODMAN="$INSTALL_PODMAN" INSTALL_DOCKER="$INSTALL_DOCKER" \
    INSTALL_VIRT="$INSTALL_VIRT" INSTALL_TLP="$INSTALL_TLP" \
    INSTALL_THINKFAN="$INSTALL_THINKFAN" INSTALL_AVAHI="$INSTALL_AVAHI" \
    INSTALL_WIREGUARD="$INSTALL_WIREGUARD" INSTALL_TAILSCALE="$INSTALL_TAILSCALE" \
    INSTALL_FAIL2BAN="$INSTALL_FAIL2BAN" INSTALL_CHROME_HINT="$INSTALL_CHROME_HINT" \
    INSTALL_SNAPPER_HOME="$INSTALL_SNAPPER_HOME" \
    INSTALL_MULTILIB="$INSTALL_MULTILIB" INSTALL_YAY="$INSTALL_YAY" \
    INSTALL_TUNED="$INSTALL_TUNED" INSTALL_DEVTOOLS="$INSTALL_DEVTOOLS" \
    INSTALL_BTRFS_ASSISTANT="$INSTALL_BTRFS_ASSISTANT" \
    INSTALL_LINUX_STABLE="$INSTALL_LINUX_STABLE" INSTALL_PLYMOUTH="$INSTALL_PLYMOUTH" \
    INSTALL_SELFTEST="$INSTALL_SELFTEST" CLEAN_ESP_ARCH="$CLEAN_ESP_ARCH" \
    ZRAM_SIZE="$ZRAM_SIZE" REFLECTOR_COUNTRY="$REFLECTOR_COUNTRY" \
    SKIP_THINKPAD_HW="$SKIP_THINKPAD_HW" \
    HW_PROFILE="$HW_PROFILE" INSTALL_OLLAMA="$INSTALL_OLLAMA" \
    FW_SYNCTHING="$FW_SYNCTHING" FW_KDECONNECT="$FW_KDECONNECT" \
    SNAP_PAC_SKIP=y \
    bash /root/chroot-setup.sh
then
  cleanup_chroot_secrets
  die "chroot setup failed"
fi
cleanup_chroot_secrets
ok "chroot config complete"

# Backstop for the umask regression: these must be world-readable or users get
# LANG unset / "dconf … Unable to open /etc/dconf/profile/user: Permission denied".
for _f in etc/locale.conf etc/vconsole.conf etc/hostname etc/hosts etc/kernel/cmdline \
          etc/pacman.conf etc/makepkg.conf.d/t14s.conf etc/dconf/profile/user \
          etc/dconf/db/local etc/dconf/db/local.d/00-t14s etc/gdm/custom.conf \
          etc/dconf/profile/gdm etc/dconf/db/gdm etc/dconf/db/gdm.d/00-login-screen \
          etc/sysctl.d/99-security.conf etc/systemd/zram-generator.conf \
          etc/tmpfiles.d/thinkpad-charge-thresholds.conf \
          etc/systemd/sleep.conf.d/s2idle.conf etc/systemd/logind.conf.d/thinkpad-lid.conf \
          etc/udev/rules.d/61-thinkpad-charge-limit.rules \
          etc/udev/rules.d/71-thinkpad-t14s-touchpad-wakeup.rules \
          etc/udev/rules.d/61-gdm-wayland.rules \
          etc/environment.d/99-wayland.conf etc/systemd/system/gdm.service.d/override.conf; do
  [[ -e /mnt/$_f ]] || continue
  if [[ $(( 8#$(stat -c '%a' "/mnt/$_f") & 8#004 )) -eq 0 ]]; then
    chmod a+r "/mnt/$_f"
    warn "fixed permissions on /$_f (was not world-readable)"
    printf 'fixed permissions on /%s (was not world-readable)\n' "$_f" >>/mnt/root/t14s-warnings.txt
  fi
done
unset -v _f

# Firmware boot entry (bootctl in the chroot cannot write EFI variables).
if ! ensure_boot_entry "$EFI_PART"; then
  printf '%s\n' "no firmware boot entry: Arch boots only via the \\EFI\\BOOT fallback (Windows may take over) — after first boot: sudo efibootmgr --create --disk $DISK --part ${EFI_PART##*[!0-9]} --label 'Linux Boot Manager' --loader '\\EFI\\systemd\\systemd-bootx64.efi'" \
    >>/mnt/root/t14s-warnings.txt
fi

# Collected chroot warnings → finish screen + /root/t14s-post-install.txt.
INSTALL_WARNINGS=""
if [[ -s /mnt/root/t14s-warnings.txt ]]; then
  INSTALL_WARNINGS=$(sort -u /mnt/root/t14s-warnings.txt)
fi

# Persist answers + optional post-install hook (dotfiles bootstrap URL).
answers_save /mnt/root/t14s-answers.env || true
if [[ -n ${POST_HOOK_URL:-} ]]; then
  # Remote script runs as root in the new system — require explicit consent.
  # Fail closed on scheme before consent / download (curl --proto is a backstop).
  [[ $POST_HOOK_URL =~ ^https://[^[:space:]@]+$ ]] \
    || die "POST_HOOK_URL must be https://… with no userinfo or spaces (got: $POST_HOOK_URL)"
  _hook_ok=0
  if (( NONINTERACTIVE )); then
    if (( POST_HOOK_CONSENT )); then
      _hook_ok=1
    else
      warn "post-hook skipped in NONINTERACTIVE without T14S_POST_HOOK_I_UNDERSTAND=1"
    fi
  else
    if ui_yesno "Run post-install hook as root in the new system?

URL: $POST_HOOK_URL

This downloads and executes remote code. Continue only if you trust the URL." no critical; then
      _hook_ok=1
    else
      warn "post-install hook skipped by operator"
    fi
  fi
  if (( _hook_ok )); then
    step "post-install hook: $POST_HOOK_URL"
    # Download to a temp file (optional SHA-256), then feed arch-chroot — never
    # pipe curl straight into bash when a pin is set or verification is wanted.
    if run_progress "post-install hook" \
         env POST_HOOK_URL="$POST_HOOK_URL" T14S_POST_HOOK_SHA256="${T14S_POST_HOOK_SHA256:-}" \
         bash -c 'set -euo pipefail
           tmp=$(mktemp)
           trap "rm -f -- \"$tmp\"" EXIT
           curl -fsSL --proto "=https" --tlsv1.2 --max-time 120 -o "$tmp" "$POST_HOOK_URL"
           if [[ -n ${T14S_POST_HOOK_SHA256:-} ]]; then
             got=$(sha256sum "$tmp" | awk "{print \$1}")
             [[ $got == "$T14S_POST_HOOK_SHA256" ]] \
               || { echo "post-hook SHA-256 mismatch (got $got want $T14S_POST_HOOK_SHA256)" >&2; exit 1; }
           fi
           arch-chroot /mnt bash -s <"$tmp"'
    then
      ok "post-install hook finished"
    else
      warn "post-install hook failed — re-run manually after boot"
    fi
  fi
  unset -v _hook_ok
fi
