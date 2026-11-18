# 02-welcome.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Wizard step 1/11: welcome screen.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

if (( NONINTERACTIVE )); then
  warn "NONINTERACTIVE: skipping welcome TUI (answers + T14S_I_WILL_ERASE gate wipe)"
else
  ui_step 1 Welcome
  ui_warn "T14s Arch Installer  $(ui_bar $(( 1 * 100 / TUI_STEPS )) 20)  1/${TUI_STEPS}

THINKPAD STAGE A INSTALLER — DESTROYS DATA ON DISK

Machines: T14s Gen 3 AMD (21CQ/21CR) or P15 Gen 1 (20SU Optimus)
Stack:    LUKS2 + Btrfs(+@tmp) + linux-lts/hardened + UKI + systemd-boot
          + minimal GNOME + zram + AppArmor + firewalld + Snapper + Secure Boot

One question per screen. Backtitle shows Step N/11 with a progress bar.
All answers from /dev/tty. Nothing written until the final Erase confirm.
Destructive confirms default No. Wipe = Erase/Abort; hard gates = Continue/Abort."
fi
