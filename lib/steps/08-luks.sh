# 08-luks.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Wizard step 6/11: LUKS passphrase and optional mapper wipe.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 3. luks passphrase + optional mapper wipe (archfi-style) ─
ui_step 6 LUKS
if (( SECRETS_FROM_FILE )); then
  ok "LUKS passphrase from T14S_PASS_FILE"
else
  while :; do
    LUKS_PASS="$(ui_password 'LUKS passphrase')" || die "aborted"
    LUKS_PASS2="$(ui_password 'Repeat LUKS passphrase')" || die "aborted"
    [[ -n $LUKS_PASS && $LUKS_PASS == "$LUKS_PASS2" ]] && break
    ui_warn "Empty or mismatched LUKS passphrase — retry."
  done
fi
if (( NONINTERACTIVE )); then
  [[ ${LUKS_WIPE:-none} =~ ^(none|fast|normal)$ ]] \
    || die "NONINTERACTIVE needs LUKS_WIPE=none|fast|normal in answers"
  LUKS_WIPE=${LUKS_WIPE:-none}
else
  _wn=off; _wf=off; _wo=off
  case ${LUKS_WIPE:-none} in
    fast) _wf=on ;;
    normal) _wo=on ;;
    *) _wn=on; LUKS_WIPE=none ;;
  esac
  LUKS_WIPE="$(ui_radio "Wipe LUKS mapper before mkfs? (paranoia; slow on large disks)" \
    none "skip — mkfs.btrfs only (default)" "$_wn" \
    fast "dd zeros bs=64M until full" "$_wf" \
    normal "dd zeros (slow, thorough)" "$_wo")" || die "aborted"
  unset -v _wn _wf _wo
fi
