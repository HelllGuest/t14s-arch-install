#!/usr/bin/env bash
# 10-ui.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# TUI core: screen geometry, dialog/whiptail wrapper, console log level, die/on_exit,
# backend selection. Theme: 11-ui-theme.sh; screens: 12-ui-screens.sh; progress: 13-ui-progress.sh.

ui_geometry() {
  local sz=""
  # Ask the terminal itself: tput falls back to 24x80 once stdin, stdout and
  # stderr are all redirected (curl | bash after start_log sends output to $LOG).
  sz=$(stty size 2>/dev/null </dev/tty) || sz=""
  ROWS=${sz% *} COLS=${sz#* }
  if ! [[ $ROWS =~ ^[1-9][0-9]*$ && $COLS =~ ^[1-9][0-9]*$ ]]; then
    ROWS=$(tput lines 2>/dev/null) || ROWS=24
    COLS=$(tput cols 2>/dev/null) || COLS=80
  fi
  [[ $ROWS =~ ^[1-9][0-9]*$ ]] || ROWS=24
  [[ $COLS =~ ^[1-9][0-9]*$ ]] || COLS=80
  # Lists, logs and progress scale with the console: small terminals use almost
  # all of it; big fbcon consoles (T14s 2.8K ~180x56, WUXGA ~240x75) get ~2/3,
  # capped so boxes stay readable instead of a fixed 84x22 island.
  if (( ROWS > 28 )); then
    H=$(( ROWS * 2 / 3 )); (( H < 22 )) && H=22; (( H > 44 )) && H=44
  else
    H=$(( ROWS - 6 ))
  fi
  (( H < 12 )) && H=12
  if (( COLS > 92 )); then
    W=$(( COLS * 2 / 3 )); (( W < 84 )) && W=84; (( W > 120 )) && W=120
  else
    W=$(( COLS - 8 ))
  fi
  (( W < 56 )) && W=56
  # Never larger than the screen (minimums above can exceed a tiny console).
  (( H > ROWS - 2 )) && H=$(( ROWS - 2 ))
  (( W > COLS - 2 )) && W=$(( COLS - 2 ))
  (( H < 1 )) && H=1
  (( W < 1 )) && W=1
  LH=$(( H - 8 )); (( LH < 4 )) && LH=4
  # Compact height for short severity message boxes (still readable).
  MH=$(( H > 16 ? 14 : H )); (( MH < 10 && H >= 10 )) && MH=10
  # Fold width for prose (~76 col modern CLI / Primer guideline).
  FW=$(( W - 4 )); (( FW > 76 )) && FW=76; (( FW < 40 )) && FW=40
  # Message boxes may use the whole screen bar backtitle + shadow (H keeps
  # menus compact; a msgbox capped at H hid the manual layout's last rows).
  XH=$(( ROWS - 4 )); (( XH < H )) && XH=$H
  # Prose boxes (msg/yesno/input/info) hug the fold width, not the wide W.
  MW=$(( FW + 8 )); (( MW > W )) && MW=$W
  return 0
}
ui_geometry

# ui_bar PCT [WIDTH] — percent bar for backtitle / gauge / plain TTY.
# UTF-8: █/░ ; C locale or non-UTF-8: #/- .
ui_bar() {
  local pct=${1:-0} w=${2:-10} filled empty i n bar=
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  [[ $w =~ ^[1-9][0-9]*$ ]] || w=10
  (( pct > 100 )) && pct=100
  n=$(( pct * w / 100 ))
  if [[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *UTF-8* ]]; then
    filled='█' empty='░'
  else
    filled='#' empty='-'
  fi
  for (( i = 0; i < w; i++ )); do
    if (( i < n )); then bar+=$filled; else bar+=$empty; fi
  done
  printf '[%s]' "$bar"
}

ui_backtitle() {
  local bar pct=0
  if (( ${TUI_STEP:-0} > 0 && ${TUI_STEPS:-0} > 0 )); then
    pct=$(( TUI_STEP * 100 / TUI_STEPS ))
    bar=$(ui_bar "$pct" 10)
    printf '%s · %s %d/%d · %s' "$APP_TITLE" "$bar" "$TUI_STEP" "$TUI_STEPS" "$TUI_STEP_NAME"
  else
    printf '%s' "$APP_TITLE"
  fi
}

# ui_step N NAME — set wizard progress; refresh geometry.
ui_step() {
  TUI_STEP=${1:-0}
  TUI_STEP_NAME=${2:-}
  ui_geometry
}

# Fold prose for msg/confirm bodies. Wrap long lines.
# Callers that must keep trailing newlines: out=$(ui_fold "$t"; printf x); out=${out%x}
ui_fold() {
  local text=$1
  if command -v fold >/dev/null 2>&1; then
    printf '%s' "$text" | fold -s -w "${FW:-72}"
  else
    printf '%s' "$text"
  fi
}

# Kernel messages print straight onto the VT and tear dialog/whiptail screens
# (amdgpu/ACPI/Wi-Fi errors on real hardware). On a VT, as root: show only
# emergencies on the console while the TUI runs (dmesg/journal keep the rest);
# cleanup_ui restores the level on every exit path.
ui_mute_console() {
  local stat f nr lvl
  [[ -w /proc/sys/kernel/printk ]] || return 0
  # Controlling terminal from /proc (`tty </dev/tty` only says "/dev/tty"):
  # a VT is major 4, minor 1-63 (ttyS* are 64+; SSH is a pty, never muted).
  read -r stat </proc/$$/stat || return 0
  read -ra f <<<"${stat##*) }"
  nr=${f[4]:-0}
  [[ $nr =~ ^[0-9]+$ ]] || return 0
  (( (nr >> 8 & 0xfff) == 4 && (nr & 0xff | nr >> 12 & 0xfff00) >= 1 \
     && (nr & 0xff | nr >> 12 & 0xfff00) <= 63 )) || return 0
  read -r lvl _ </proc/sys/kernel/printk || return 0
  [[ $lvl =~ ^[0-9]+$ ]] && (( lvl > 1 )) || return 0
  printf '1\n' >/proc/sys/kernel/printk 2>/dev/null && UI_PRINTK_SAVED=$lvl
  return 0
}

# Idempotent; runs first in die/on_exit, before any write to a terminal that
# may already be gone (hangup), so the console level is never left muted.
ui_restore_console() {
  if [[ -n ${UI_PRINTK_SAVED:-} ]]; then
    printf '%s\n' "$UI_PRINTK_SAVED" >/proc/sys/kernel/printk 2>/dev/null || true
    UI_PRINTK_SAVED=""
  fi
  return 0
}

cleanup_ui() {
  ui_restore_console
  [[ -n ${DIALOG_RC_DIR:-} && -d $DIALOG_RC_DIR ]] && rm -rf -- "$DIALOG_RC_DIR"
  [[ -f ${LOG:-}.fail ]] && rm -f -- "$LOG.fail"
  # Drop empty dry-run / unused logs so /tmp does not accumulate zeros.
  if [[ -n ${LOG:-} && -f $LOG && ! -s $LOG ]]; then
    rm -f -- "$LOG"
  fi
  return 0
}

# dialog/whiptail draw on stdout and return the result on stderr. fd3 carries
# the caller's stdout (the capture channel), so UI is pinned to /dev/tty and keys
# come from /dev/tty even when the script itself arrives on a pipe.
# TUI_KEEP_STDIN=1: leave stdin alone (required for --progressbox pipe feed).
tui() {
  local title=${TUI_TITLE:-$APP_TITLE}
  local back
  back=$(ui_backtitle)
  local drc=${TUI_DIALOGRC:-${DIALOG_RC:-${DIALOGRC:-}}}
  case $UI in
    dialog)
      if [[ ${TUI_KEEP_STDIN:-0} == 1 ]]; then
        DIALOGRC="$drc" \
          dialog --colors --backtitle "$back" --title "$title" \
          "$@" 3>&1 1>/dev/tty 2>&3
      else
        DIALOGRC="$drc" \
          dialog --colors --backtitle "$back" --title "$title" \
          "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty
      fi
      ;;
    whiptail)
      if [[ ${TUI_KEEP_STDIN:-0} == 1 ]]; then
        NEWT_COLORS="${NEWT_COLORS_BASE}${TUI_NEWT:-}" \
          whiptail --backtitle "$back" --title "$title" \
          "$@" 3>&1 1>/dev/tty 2>&3
      else
        NEWT_COLORS="${NEWT_COLORS_BASE}${TUI_NEWT:-}" \
          whiptail --backtitle "$back" --title "$title" \
          "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

die() { # message [exit-code]
  local msg=${1:-failed} rc=${2:-1} was_logging=$LOGGING
  ui_restore_console
  T14S_DIED=1
  trap - ERR
  # After start_log, stderr is the log file: record the error there, then
  # restore the console so the operator actually sees why it stopped.
  if (( LOGGING )); then
    printf 'ERR %s\n' "$msg" >>"$LOG"
    stop_log
  fi
  printf '%sERR%s %s\n' "$cR" "$c0" "$msg" >&2
  # Unattended runs must exit, not wait on a dialog nobody will answer.
  if [[ $UI != plain ]] && (( ! NONINTERACTIVE )); then
    ui_critical "$msg

Full log: $LOG" || true
    if (( was_logging )); then
      { printf 'FAILED: %s\n\n--- last output ---\n' "$msg"
        tail -n "$H" "$LOG" 2>/dev/null; } >"$LOG.fail"
      TUI_TITLE="Failure log — $APP_TITLE"
      TUI_NEWT="$NEWT_COLORS_ERROR"
      TUI_DIALOGRC="${DIALOG_RC_ERROR:-$DIALOG_RC}"
      tui --textbox "$LOG.fail" "$H" "$W" || true
      TUI_TITLE=""; TUI_NEWT=""; TUI_DIALOGRC=""
    fi
  fi
  printf 'full log: %s\n' "$LOG" >&2
  cleanup_ui
  exit "$rc"
}

# EXIT backstop. The ERR trap is not inherited by functions (no set -E: that
# would also fire inside every $(…)), so a set -e exit from a failing command
# inside a helper (mkfs/mount in do_btrfs_and_mount, …) never reaches die().
# Report it like die() instead of closing the TUI with the reason only in $LOG.
on_exit() {
  local rc=$1
  ui_restore_console
  if (( rc != 0 && ! ${T14S_DIED:-0} )); then
    # Operator interrupt (INT/TERM): report and exit, no dialog to dismiss.
    if (( rc == 130 || rc == 143 )); then
      NONINTERACTIVE=1 die "interrupted (signal $(( rc - 128 )))" "$rc"
    fi
    die "stopped unexpectedly (exit $rc): a command inside a helper failed — see the log" "$rc"
  fi
  cleanup_ui
}
# ERR/EXIT traps are installed by install.sh after globals (not here).

bootstrap_ui() {
  if [[ -n ${T14S_UI:-} ]]; then          # explicit override
    case $T14S_UI in
      plain | dialog | whiptail) UI=$T14S_UI ;;
      *) warn "T14S_UI=$T14S_UI unsupported (plain|dialog|whiptail); using plain"; UI=plain ;;
    esac
    if [[ $UI != plain ]] && ! command -v "$UI" >/dev/null 2>&1; then
      (( DRYRUN )) || pacman -Sy --needed --noconfirm "$UI" >/dev/null 2>&1 || true
      command -v "$UI" >/dev/null 2>&1 || UI=plain
    fi
  else
    [[ -n ${TERM:-} && -r /dev/tty ]] || return 0
    # Prefer dialog: --progressbox / --separate-output checklist / richer textbox.
    if command -v dialog >/dev/null 2>&1; then UI=dialog
    elif command -v whiptail >/dev/null 2>&1; then UI=whiptail
    elif (( DRYRUN )); then :
    elif command -v pacman >/dev/null 2>&1 \
      && pacman -Sy --needed --noconfirm dialog >/dev/null 2>&1 \
      && command -v dialog >/dev/null 2>&1; then UI=dialog
    fi
    [[ $UI == plain ]] && warn "no TUI backend (dialog/whiptail) — plain prompts"
    [[ $UI == whiptail ]] && warn "whiptail: no progressbox — long steps stream to the console"
  fi
  if [[ $UI == dialog || $UI == whiptail ]]; then
    write_dialogrc
    ui_mute_console
  fi
  ui_geometry
  return 0
}
