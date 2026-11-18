# 01-preflight.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Preflight checks (root, UEFI, ISO, network, NTP) and TUI backend.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 0. preflight ────────────────────────────────────────────
if (( ! DRYRUN )); then
  [[ $EUID -eq 0 ]] || die "run as root (from the Arch ISO)"
  [[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode — enable UEFI and reboot the ISO"
  # The installer assumes a disposable live environment (/mnt, cryptroot mapper).
  [[ -d /run/archiso ]] || (( ALLOW_NON_ISO )) \
    || die "not running from the Arch ISO (/run/archiso missing); set T14S_ALLOW_NON_ISO=1 to override"
  { ping -c1 -W3 archlinux.org || curl -fsS --max-time 6 https://archlinux.org; } >/dev/null 2>&1 \
    || die "no internet — connect first (iwctl / dhcp), then re-run"
  timedatectl set-ntp true || true
fi
bootstrap_ui
# newt (whiptail, the Arch ISO backend) ignores Esc on the console: Abort is a
# button there, so the hints must not promise Esc.
if [[ $UI == whiptail ]]; then
  TUI_HINT_MENU='[log] view install log · [help] tips · Tab to Abort quits'
  TUI_HINT_RADIO='Arrows+Space select · Enter=Next · Tab to Abort · [log]/[help]'
  TUI_HINT_CHECK='Space=toggle · Enter=Next · Tab to Abort · [log]/[help]'
fi
say "preflight ok (UEFI + network + ntp)"
