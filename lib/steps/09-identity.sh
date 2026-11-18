# 09-identity.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Wizard step 7/11: hostname, user, passwords, locale, timezone, keymap.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 4. identity (validated before wipe / LUKS at step 11) ───
ui_step 7 Identity
if (( NONINTERACTIVE )); then
  [[ -n ${HOSTNAME:-} ]] || die "NONINTERACTIVE needs HOSTNAME in answers"
  valid_hostname "$HOSTNAME" || die "invalid hostname (DNS labels only): ${HOSTNAME}"
else
  while :; do
    _hn_default=thinkpad-t14s
    [[ ${HW_PROFILE:-t14s} == p15 ]] && _hn_default=p15
    HOSTNAME="$(ui_input "Hostname" "${HOSTNAME:-$_hn_default}")" || die "aborted"
    unset -v _hn_default
    [[ -n $HOSTNAME ]] || { ui_warn "hostname cannot be empty"; continue; }
    valid_hostname "$HOSTNAME" && break
    ui_error "invalid hostname (DNS labels only; no leading/trailing hyphen)"
  done
fi

if (( NONINTERACTIVE )); then
  [[ -n ${TIMEZONE:-} ]] || die "NONINTERACTIVE needs TIMEZONE in answers"
  valid_timezone "$TIMEZONE" || die "NONINTERACTIVE needs valid TIMEZONE in answers"
  ok "timezone from answers: $TIMEZONE"
else
  while :; do
    TIMEZONE="$(pick_timezone)" || die "aborted"
    valid_timezone "$TIMEZONE" && break
    ui_error "Timezone not a TZif zone file: ${TIMEZONE:-<empty>} — pick again."
  done
fi

if (( NONINTERACTIVE )); then
  [[ -n ${LOCALE:-} ]] || die "NONINTERACTIVE needs LOCALE in answers"
  valid_locale "$LOCALE" || die "NONINTERACTIVE needs valid LOCALE in answers"
  ok "locale from answers: $LOCALE"
else
  while :; do
    _loc_prev=${LOCALE:-en_US.UTF-8}
    _lu=off; _lg=off; _ld=off; _lf=off; _ls=off; _lo=off
    case $_loc_prev in
      en_GB.UTF-8) _lg=on ;;
      de_DE.UTF-8) _ld=on ;;
      fr_FR.UTF-8) _lf=on ;;
      es_ES.UTF-8) _ls=on ;;
      en_US.UTF-8) _lu=on ;;
      *) _lo=on ;;
    esac
    LOCALE="$(ui_radio "System locale" \
      en_US.UTF-8 "English (US)" "$_lu" \
      en_GB.UTF-8 "English (UK)" "$_lg" \
      de_DE.UTF-8 "German" "$_ld" \
      fr_FR.UTF-8 "French" "$_lf" \
      es_ES.UTF-8 "Spanish" "$_ls" \
      other "type a locale (e.g. pt_BR.UTF-8)" "$_lo")" || die "aborted"
    unset -v _lu _lg _ld _lf _ls _lo
    if [[ $LOCALE == other ]]; then
      LOCALE="$(ui_input "Locale" "$_loc_prev")" || die "aborted"
    fi
    unset -v _loc_prev
    valid_locale "$LOCALE" && break
    ui_error "locale not in SUPPORTED/locale.gen: ${LOCALE:-<empty>}"
  done
fi

if (( NONINTERACTIVE )); then
  [[ -n ${KEYMAP:-} ]] || die "NONINTERACTIVE needs KEYMAP in answers"
  valid_keymap "$KEYMAP" || die "NONINTERACTIVE needs valid KEYMAP in answers"
  ok "keymap from answers: $KEYMAP"
else
  while :; do
    KEYMAP="$(pick_keymap)" || die "aborted"
    valid_keymap "$KEYMAP" && break
    ui_error "keymap not available: ${KEYMAP:-<empty>} — pick again."
  done
fi
if (( ! DRYRUN )) && command -v loadkeys >/dev/null 2>&1; then
  loadkeys "$KEYMAP" 2>/dev/null || warn "loadkeys $KEYMAP failed on live ISO (vconsole still set in target)"
fi

if (( NONINTERACTIVE )); then
  [[ -n ${USERNAME:-} ]] || die "NONINTERACTIVE needs USERNAME in answers"
  valid_username "$USERNAME" || die "NONINTERACTIVE needs valid USERNAME in answers"
  ok "username from answers: $USERNAME"
else
  while :; do
    USERNAME="$(ui_input "Username (lowercase POSIX)" "${USERNAME:-}")" || die "aborted"
    if [[ -z $USERNAME ]]; then
      ui_warn "username cannot be empty"
    elif [[ $USERNAME == root ]]; then
      ui_warn "username cannot be 'root'"
    elif ! valid_username "$USERNAME"; then
      ui_error "invalid username (^[a-z_][a-z0-9_-]*\$, ≤32, not an existing user/group)"
    else
      break
    fi
  done
fi
if (( SECRETS_FROM_FILE )); then
  ok "user/root passwords from T14S_PASS_FILE"
else
  while :; do
    USER_PASS="$(ui_password "Password for $USERNAME")" || die "aborted"
    USER_PASS2="$(ui_password "Repeat password for $USERNAME")" || die "aborted"
    [[ -n $USER_PASS && $USER_PASS == "$USER_PASS2" ]] && break
    ui_warn "Empty or mismatched password — retry."
  done
  while :; do
    ROOT_PASS="$(ui_password 'Root password')" || die "aborted"
    ROOT_PASS2="$(ui_password 'Repeat root password')" || die "aborted"
    [[ -n $ROOT_PASS && $ROOT_PASS == "$ROOT_PASS2" ]] && break
    ui_warn "Empty or mismatched password — retry."
  done
fi
unset -v LUKS_PASS2 USER_PASS2 ROOT_PASS2
