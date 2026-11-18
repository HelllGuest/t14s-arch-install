# 30-finish.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Finish: final summary (with any install warnings), unmount.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 8. finish ───────────────────────────────────────────────
ui_step 0 Done
if yn_on "$DESKTOP"; then
  LOGIN_HINT="First login via GDM (Wayland).
  Flatpak browsers/VPN install in the background on first boot once online
  (connect Wi-Fi; retries every 5 min): journalctl -u t14s-flatpak-apps -f"
  FLATPAK_HINT="Optional post-boot: flatpak install --user -y flathub com.google.Chrome"
else
  LOGIN_HINT="Desktop skipped — log in on a virtual console (getty) as ${USERNAME}."
  FLATPAK_HINT="Optional later: pacman -S gnome-shell gdm flatpak && systemctl enable gdm"
fi
yn_on "$INSTALL_CHROME_HINT" \
  && FLATPAK_HINT="Chrome helper: ~${USERNAME}/install-chrome-flatpak.sh (flatpak install --user -y flathub com.google.Chrome)"

if yn_on "$INSTALL_SNAPPER_HOME"; then
  SNAPPER_HINT="root + home configs enabled"
else
  SNAPPER_HINT="root config enabled; add home later: snapper -c home create-config /home"
fi
if yn_on "$INSTALL_SELFTEST"; then
  SELFTEST_HINT="Self-test: /usr/local/bin/t14s-selftest (BT/audio/wifi/apparmor/firewalld/s2idle/cpufreq driver/BAT0/touchpad)"
else
  SELFTEST_HINT="Self-test script not installed"
fi

# Optional hint lines (plain if/else: a failing $(…) inside POST_TXT="…"
# would make the assignment return 1 under set -e).
EXTRA_HINTS=""
if yn_on "$INSTALL_YAY"; then
  EXTRA_HINTS+="  AUR: yay -S <pkg>   (makepkg uses all cores; no -debug pkgs)
"
fi
if yn_on "$INSTALL_DEVTOOLS"; then
  EXTRA_HINTS+="  Rust: rustup default stable   (per-user toolchain)
"
fi

# Profile-specific post-boot checks (P15 is Intel + NVIDIA, not Rembrandt).
if [[ $HW_PROFILE == p15 ]]; then
  CPU_HINT="lscpu | grep -i 'model name'   (expect Intel Core/Xeon)"
  CMDLINE_HINT="grep -E 'intel_iommu|nvidia_drm' /proc/cmdline"
else
  CPU_HINT="lscpu | grep -i ryzen"
  CMDLINE_HINT="grep -E 'amd_iommu|amd_pstate' /proc/cmdline"
fi

POST_TXT="T14s install — next steps

  Reboot and remove the ISO:   reboot
  Boot menu: Arch Linux (LTS) default, Hardened as fallback.
  Answers file: /root/t14s-answers.env (T14S_ANSWERS=... to reuse)
  Passwords: use T14S_PASS_FILE for unattended (never stored in answers)
  Verify after boot: ${CPU_HINT}
                     cat /sys/power/mem_sleep   (expect s2idle bracketed)
  Secure Boot (to enable):
    1) BIOS -> clear Secure Boot keys -> Setup Mode
    2) booted OS: sudo sbctl enroll-keys -m
    3) BIOS -> Secure Boot -> Enabled   (pacman hook auto-resigns on updates)
    multiboot: '-m' keeps Microsoft keys so Windows still boots; other
    unsigned Linux loaders won't boot under SB until you 'sbctl sign' them.
    If enroll fails: keep SB off, or boot LTS UKI then enroll.
  Recovery (from Arch ISO):
    cryptsetup open /dev/<root> cryptroot
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    mount /dev/<esp> /mnt/boot
    arch-chroot /mnt
  Snapper: ${SNAPPER_HINT}
  ${SELFTEST_HINT}
  linux-hardened + Flatpak: userns sysctl already set (99-userns.conf).
  Fingerprint (fprintd on GNOME): fprintd-enroll
  Hostname: ${HOSTNAME}
  ${LOGIN_HINT}
  Post-boot check: ${CMDLINE_HINT}
  TRIM through LUKS: lsblk -D /dev/mapper/cryptroot   (DISC-GRAN non-zero)
  Charge thresholds (ThinkPad BAT* only; skip/absent on VM):
    cat /sys/class/power_supply/BAT0/charge_control_*_threshold
    (expect 70 / 80; oneshot thinkpad-charge-thresholds.service + tmpfiles)
${EXTRA_HINTS}  Full install log: /var/log/t14s-install.log (root only)
  ${FLATPAK_HINT}"
if [[ -n $INSTALL_WARNINGS ]]; then
  POST_TXT+="

  Warnings during install (details in /var/log/t14s-install.log):
$(printf '%s\n' "$INSTALL_WARNINGS" | sed 's/^/    - /')"
fi

printf '%s\n' "$POST_TXT" > /mnt/root/t14s-post-install.txt
rm -f /mnt/root/t14s-warnings.txt   # already merged into t14s-post-install.txt

step "unmounting"
# Keep the full log on the installed system (live /tmp is gone after reboot).
# Passwords never reach it (secrets go via a 0600 file, not command output).
install -m 600 "$LOG" /mnt/var/log/t14s-install.log 2>/dev/null \
  || warn "could not copy install log to /var/log/t14s-install.log"
umount -R /mnt
cryptsetup close cryptroot
stop_log

if [[ -n $INSTALL_WARNINGS ]]; then
  ui_warn "INSTALL COMPLETE with warnings — reboot and remove the ISO.

$(printf '%s' "$POST_TXT")"
else
  ui_ok "INSTALL COMPLETE — reboot and remove the ISO.

$(printf '%s' "$POST_TXT")"
fi
ok "done — reboot when ready"
