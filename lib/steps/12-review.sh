# 12-review.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Wizard step 10/11: review, answers save, DRYRUN exit. Nothing written before this.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── final summary ───────────────────────────────────────────
ui_step 10 Review
_REVIEW="REVIEW — nothing has been written yet.

  Disk          $DISK $(size_mb "$DISK")MB ($([[ $MODE == auto ]] && echo "AUTO wipe, ${ESP_MB}MB ESP" || echo manual))
  EFI           $EFI_PART $(size_mb "$EFI_PART")MB ($([[ $FORMAT_EFI == 1 ]] && echo format || echo reuse))
  Clean ESP     $CLEAN_ESP_ARCH (old Arch UKIs/entries/EFI/arch)
  ROOT          $ROOT_PART $(size_mb "$ROOT_PART")MB (LUKS2, wipe=${LUKS_WIPE})
  Hostname      $HOSTNAME
  Timezone      $TIMEZONE
  Locale        $LOCALE
  Keymap        $KEYMAP
  User          $USERNAME
  Profile       $PRESET
  Parallel DL   $PACMAN_PARALLEL
  Btrfs/zram    compress=$BTRFS_COMPRESS zram=$ZRAM_SIZE
  Reflector     $([[ $SKIP_REFLECTOR == Y ]] && echo "skip (ISO mirrorlist until the weekly reflector run)" || echo "refresh${REFLECTOR_COUNTRY:+ ($REFLECTOR_COUNTRY)}")
  ThinkPad HW   $([[ $SKIP_THINKPAD_HW == Y ]] && echo skip || echo apply)
  Extra pkgs    $( ((${#EXTRA_PKGS[@]})) && printf '%s ' "${EXTRA_PKGS[@]}" || echo none)
  Desktop       $([[ $DESKTOP == Y ]] && echo 'minimal GNOME' || echo none)
  Nerd Fonts    $([[ $INSTALL_NERD_FONTS == Y ]] && echo curated set || echo no)
  Snapper       home=$INSTALL_SNAPPER_HOME gui=$INSTALL_BTRFS_ASSISTANT
  pacman/AUR    multilib=$INSTALL_MULTILIB yay=$INSTALL_YAY
  Power         $([[ $INSTALL_TUNED == Y ]] && echo 'tuned + tuned-ppd' || echo power-profiles-daemon)
  Dev tools     $INSTALL_DEVTOOLS
  linux/plymouth linux=$INSTALL_LINUX_STABLE plymouth=$INSTALL_PLYMOUTH
  CLI/Podman    cli=$INSTALL_CLI podman=$INSTALL_PODMAN docker=$INSTALL_DOCKER virt=$INSTALL_VIRT
  Net           avahi=$INSTALL_AVAHI wg=$INSTALL_WIREGUARD tailscale=$INSTALL_TAILSCALE
  CUPS/TLP/SB   cups=$INSTALL_CUPS tlp=$INSTALL_TLP sb=$ENROLL_SB
  SSH/f2b       sshd=$ENABLE_SSHD fail2ban=$INSTALL_FAIL2BAN
  Hook URL      ${POST_HOOK_URL:-none}
  Pass file     ${PASS_FILE:-none}

Typed passwords are not redisplayed."
if (( NONINTERACTIVE )); then
  ok "NONINTERACTIVE: skipping REVIEW/confirm UI"
  printf '%s\n' "$_REVIEW" | while IFS= read -r _l; do say "$_l"; done
else
  ui_info "$_REVIEW"
  ui_yesno "Start the installation? The partitions above will be ERASED." no erase \
    || die "aborted by user"
fi
unset -v _REVIEW _l

# Validate optional post-hook URL before wipe / DRYRUN exit.
if [[ -n ${POST_HOOK_URL:-} ]]; then
  [[ $POST_HOOK_URL =~ ^https://[^[:space:]@]+$ ]] \
    || die "POST_HOOK_URL must be https://… with no userinfo or spaces (got: $POST_HOOK_URL)"
fi

ANSWERS_OUT="${T14S_ANSWERS_OUT:-/tmp/t14s-answers.env}"
answers_save "$ANSWERS_OUT" || warn "could not write answers to $ANSWERS_OUT"
ok "answers saved: $ANSWERS_OUT (reload: T14S_ANSWERS=$ANSWERS_OUT)"

if (( DRYRUN )); then
  printf 'DRYRUN: preset=%s EFI=%s ROOT=%s host=%s user=%s locale=%s tz=%s keymap=%s wipe=%s parallel=%s desktop=%s nerd=%s cli=%s podman=%s docker=%s virt=%s avahi=%s sshd=%s extra=%s\n' \
    "$PRESET" "$EFI_PART" "$ROOT_PART" "$HOSTNAME" "$USERNAME" \
    "$LOCALE" "$TIMEZONE" "$KEYMAP" "$LUKS_WIPE" "$PACMAN_PARALLEL" \
    "$DESKTOP" "$INSTALL_NERD_FONTS" "$INSTALL_CLI" "$INSTALL_PODMAN" \
    "$INSTALL_DOCKER" "$INSTALL_VIRT" "$INSTALL_AVAHI" "$ENABLE_SSHD" \
    "${EXTRA_PKGS[*]:-}"
  exit 0
fi
