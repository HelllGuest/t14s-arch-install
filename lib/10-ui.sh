#!/usr/bin/env bash
# 10-ui.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash

ui_geometry() {
  ROWS=$(tput lines 2>/dev/null) || ROWS=24
  COLS=$(tput cols 2>/dev/null) || COLS=80
  [[ $ROWS =~ ^[0-9]+$ ]] || ROWS=24
  [[ $COLS =~ ^[0-9]+$ ]] || COLS=80
  H=$(( ROWS > 28 ? 22 : ROWS - 6 )); (( H < 12 )) && H=12
  W=$(( COLS > 92 ? 84 : COLS - 8 )); (( W < 56 )) && W=56
  LH=$(( H - 8 )); (( LH < 4 )) && LH=4
  # Compact height for short severity message boxes (still readable).
  MH=$(( H > 16 ? 14 : H )); (( MH < 10 )) && MH=10
  # Fold width for prose (~76 col modern CLI / Primer guideline).
  FW=$(( W - 4 )); (( FW > 76 )) && FW=76; (( FW < 40 )) && FW=40
  return 0
}
ui_geometry

ui_backtitle() {
  if (( ${TUI_STEP:-0} > 0 )); then
    printf '%s · %d/%d · %s' "$APP_TITLE" "$TUI_STEP" "$TUI_STEPS" "$TUI_STEP_NAME"
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

# Button labels by backend + role.
# critical_yesno = Continue/Abort (hard gate, no wipe).
# erase_yesno = Erase/Abort (disk/partition wipe only).
# dialog uses --*-label; whiptail uses --*-button.
_tui_btns() {
  _btns=()
  case ${UI:-plain}/$1 in
    dialog/nav) _btns=(--ok-label Next --cancel-label Abort) ;;
    whiptail/nav) _btns=(--ok-button Next --cancel-button Abort) ;;
    dialog/msg) _btns=(--ok-label Continue) ;;
    whiptail/msg) _btns=(--ok-button Continue) ;;
    dialog/yesno) _btns=(--yes-label Yes --no-label No) ;;
    whiptail/yesno) _btns=(--yes-button Yes --no-button No) ;;
    dialog/critical_yesno) _btns=(--yes-label Continue --no-label Abort) ;;
    whiptail/critical_yesno) _btns=(--yes-button Continue --no-button Abort) ;;
    dialog/erase_yesno) _btns=(--yes-label Erase --no-label Abort) ;;
    whiptail/erase_yesno) _btns=(--yes-button Erase --no-button Abort) ;;
  esac
}

# Base palettes: dialogrc (ncurses) + NEWT_COLORS (whiptail).
# The ISO's Linux console has 8 background colours and treats bold/"bright" as
# the intensity bit: bold BLACK text renders dark grey, and bright backgrounds
# fall back to their dim pair (yellow → brown, white → lightgray). Rules:
#   * never BLACK foreground with highlight ON (dialog) — unreadable grey;
#   * backgrounds only from the 8 normal colours (newt: no bright*/yellow/white bg);
#   * one focus colour everywhere: bright WHITE on BLUE;
#   * newt uses S-Lang names (yellow = bright, brown = dim; no "brightyellow").
# Severity overlays are appended to NEWT_COLORS_BASE in tui() (later keys win)
# and only touch border/title — never root/window — so screens don't flash.
NEWT_COLORS_BASE='
root=white,blue
roottext=brightcyan,blue
border=brightcyan,black
window=lightgray,black
shadow=black,black
title=yellow,black
button=black,lightgray
actbutton=white,blue
compactbutton=lightgray,black
checkbox=lightgray,black
actcheckbox=white,blue
entry=white,black
label=brightcyan,black
listbox=lightgray,black
actlistbox=white,blue
sellistbox=yellow,black
actsellistbox=white,blue
textbox=lightgray,black
acttextbox=white,blue
helpline=black,cyan
emptyscale=,black
fullscale=,cyan
disentry=gray,black
'

NEWT_COLORS_INFO='
border=brightcyan,black
title=brightcyan,black
'
NEWT_COLORS_WARN='
border=yellow,black
title=yellow,black
'
NEWT_COLORS_ERROR='
border=brightred,black
title=white,red
'
NEWT_COLORS_CRITICAL='
border=yellow,red
title=yellow,red
'
NEWT_COLORS_OK='
border=brightgreen,black
title=brightgreen,black
'

# Write one dialogrc: $1 path, $2 title colour, $3 border colour. The backdrop
# (screen_color) is the same for every severity so moving between screens never
# flashes the whole terminal; severity only recolours the frame + title. Focus
# is always bright WHITE on BLUE and BLACK text is never bold (rules above).
_write_one_dialogrc() {
  local path=$1 title=$2 border=$3
  local screen='(CYAN,BLUE,ON)'
  local focus='(WHITE,BLUE,ON)'
  cat >"$path" <<EOF
# T14s installer theme
use_shadow = ON
use_colors = ON
screen_color = $screen
shadow_color = (BLACK,BLACK,OFF)
dialog_color = (WHITE,BLACK,OFF)
title_color = $title
border_color = $border
border2_color = (BLUE,BLACK,ON)
button_active_color = $focus
button_inactive_color = (WHITE,BLACK,OFF)
button_key_active_color = (YELLOW,BLUE,ON)
button_key_inactive_color = (YELLOW,BLACK,ON)
button_label_active_color = $focus
button_label_inactive_color = (WHITE,BLACK,OFF)
inputbox_color = (WHITE,BLACK,OFF)
inputbox_border_color = $border
inputbox_border2_color = (BLUE,BLACK,ON)
searchbox_color = (WHITE,BLACK,OFF)
searchbox_title_color = $title
searchbox_border_color = $border
searchbox_border2_color = (BLUE,BLACK,ON)
menubox_color = (WHITE,BLACK,OFF)
menubox_border_color = $border
menubox_border2_color = (BLUE,BLACK,ON)
item_color = (WHITE,BLACK,OFF)
item_selected_color = $focus
tag_color = $title
tag_selected_color = $focus
tag_key_color = (YELLOW,BLACK,ON)
tag_key_selected_color = (YELLOW,BLUE,ON)
check_color = (WHITE,BLACK,OFF)
check_selected_color = $focus
uarrow_color = (GREEN,BLACK,ON)
darrow_color = (GREEN,BLACK,ON)
itemhelp_color = (BLACK,CYAN,OFF)
form_active_text_color = $focus
form_text_color = (WHITE,BLACK,OFF)
form_item_readonly_color = (CYAN,BLACK,ON)
gauge_color = (CYAN,BLACK,ON)
position_indicator_color = (CYAN,BLACK,ON)
EOF
}

write_dialogrc() {
  local base
  base="$(mktemp -d /tmp/t14s-dialogrc.XXXXXX)"
  DIALOG_RC_DIR=$base
  DIALOG_RC="$base/base"
  DIALOG_RC_INFO="$base/info"
  DIALOG_RC_WARN="$base/warn"
  DIALOG_RC_ERROR="$base/error"
  DIALOG_RC_CRITICAL="$base/critical"
  DIALOG_RC_OK="$base/ok"
  _write_one_dialogrc "$DIALOG_RC" \
    '(YELLOW,BLACK,ON)' '(CYAN,BLACK,ON)'
  _write_one_dialogrc "$DIALOG_RC_INFO" \
    '(CYAN,BLACK,ON)' '(CYAN,BLACK,ON)'
  _write_one_dialogrc "$DIALOG_RC_WARN" \
    '(YELLOW,BLACK,ON)' '(YELLOW,BLACK,ON)'
  _write_one_dialogrc "$DIALOG_RC_ERROR" \
    '(WHITE,RED,ON)' '(RED,BLACK,ON)'
  _write_one_dialogrc "$DIALOG_RC_CRITICAL" \
    '(YELLOW,RED,ON)' '(YELLOW,RED,ON)'
  _write_one_dialogrc "$DIALOG_RC_OK" \
    '(GREEN,BLACK,ON)' '(GREEN,BLACK,ON)'
  export DIALOGRC="$DIALOG_RC"
  export NEWT_COLORS="$NEWT_COLORS_BASE"
}

cleanup_ui() {
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

# Height for a message body: MH floor, H ceiling, scales with line count.
msg_height() {
  local text=$1 lines need
  lines=$(printf '%s' "$text" | wc -l)
  need=$(( lines + 6 ))
  (( need < MH )) && need=$MH
  (( need > H )) && need=$H
  printf '%s' "$need"
}

die() { # message [exit-code]
  local msg=${1:-failed} rc=${2:-1} was_logging=$LOGGING
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
# ERR/EXIT traps are installed by install.sh after globals (not here).

# ── tty prompt primitives (plain fallback) ──────────────────
ask()       { local p="$1" d="${2:-}" v; read -r  -p "$p" v </dev/tty || true; printf '%s' "${v:-$d}"; }
ask_secret(){ local p="$1" v; read -rs -p "$p" v </dev/tty || true; printf '\n' >&2; printf '%s' "$v"; }
plain_pause(){ read -rsn1 -p ' [enter] ' </dev/tty || true; printf '\n' >&2; }

# ── semantic UI: every screen uses these ────────────────────
# dialog preferred: --progressbox / --textbox / --checklist.
# whiptail: checklist + textbox; no progressbox (falls back to live TTY tee).
# Severity boxes: ui_info / ui_warn / ui_error / ui_critical / ui_ok (colored chrome).
# Every menu/radio/checklist can open log or console help via extra tags.

# ui_msg SEVERITY TEXT — colored message box (info|warn|error|critical|ok).
# Severity is also a text badge (not color-only; a11y / Primer CLI).
# Wipe / hard-gate button labels live on ui_yesno only — not on ui_msg.
ui_msg() {
  local sev=$1; shift
  local text folded title badge plain_c body newt drc h show
  text=$*
  folded=$(ui_fold "$text"; printf x); folded=${folded%x}
  # dialog --colors needs literal \Z sequences (single-quoted; $'..' strips \Z).
  case $sev in
    info)
      title="Info — $APP_TITLE"
      badge="INFO"
      plain_c=$cC
      body='\Zb\Z6[ INFO ]\Zn'$'\n\n'"$folded"
      newt=$NEWT_COLORS_INFO
      drc=${DIALOG_RC_INFO:-$DIALOG_RC}
      ;;
    warn)
      title="Warning — $APP_TITLE"
      badge="WARN"
      plain_c=$cY
      body='\Zb\Z3[ WARNING ]\Zn'$'\n\n'"$folded"
      newt=$NEWT_COLORS_WARN
      drc=${DIALOG_RC_WARN:-$DIALOG_RC}
      ;;
    error)
      title="Error — $APP_TITLE"
      badge="ERROR"
      plain_c=$cR
      body='\Zb\Z1[ ERROR ]\Zn'$'\n\n'"$folded"
      newt=$NEWT_COLORS_ERROR
      drc=${DIALOG_RC_ERROR:-$DIALOG_RC}
      ;;
    critical)
      title="CRITICAL — $APP_TITLE"
      badge="CRITICAL"
      plain_c=$cR
      body='\Zb\Z1\Zr[ CRITICAL ]\Zn'$'\n\n'"$folded"
      newt=$NEWT_COLORS_CRITICAL
      drc=${DIALOG_RC_CRITICAL:-$DIALOG_RC}
      ;;
    ok)
      title="Success — $APP_TITLE"
      badge="OK"
      plain_c=$cG
      body='\Zb\Z2[ OK ]\Zn'$'\n\n'"$folded"
      newt=$NEWT_COLORS_OK
      drc=${DIALOG_RC_OK:-$DIALOG_RC}
      ;;
    *)
      title="$APP_TITLE"
      badge="NOTE"
      plain_c=$cB
      body=$folded
      newt=
      drc=$DIALOG_RC
      ;;
  esac

  # NONINTERACTIVE: print and continue — no keypress or msgbox nobody answers.
  if [[ $UI == plain ]] || (( NONINTERACTIVE )); then
    printf '\n%s[%s]%s\n%s\n' "$plain_c" "$badge" "$c0" "$folded" >&2
    (( NONINTERACTIVE )) || plain_pause
    return 0
  fi

  # whiptail has no --colors / \Z; strip dialog markup for body.
  show=$body
  if [[ $UI == whiptail ]]; then
    show=$(printf '[ %s ]\n\n%s' "$badge" "$folded")
  fi
  h=$(msg_height "$show")

  TUI_TITLE=$title
  TUI_NEWT=$newt
  TUI_DIALOGRC=$drc
  _tui_btns msg
  tui "${_btns[@]}" --msgbox "$show" "$h" "$W" || true
  TUI_TITLE=""
  TUI_NEWT=""
  TUI_DIALOGRC=""
}

ui_info()     { ui_msg info "$@"; }
ui_warn()     { ui_msg warn "$@"; }
ui_error()    { ui_msg error "$@"; }
ui_critical() { ui_msg critical "$@"; }
ui_ok()       { ui_msg ok "$@"; }


ui_view_log() {
  touch "$LOG" 2>/dev/null || true
  if [[ ! -s $LOG ]]; then
    ui_info "Install log is empty so far.

Path: $LOG"
    return 0
  fi
  if [[ $UI == plain ]]; then
    printf '\n── log: %s (q to quit less) ──\n' "$LOG" >/dev/tty
    less -R "$LOG" </dev/tty >/dev/tty 2>/dev/null \
      || { tail -n 80 "$LOG" >/dev/tty; plain_pause; }
    return 0
  fi
  # Both dialog and whiptail support --textbox (scrollable file viewer).
  TUI_TITLE="Install log — $APP_TITLE"
  tui --textbox "$LOG" "$H" "$W" || true
  TUI_TITLE=""
}

ui_console_help() {
  ui_info "Console / log tips

• Backtitle shows Step N/M · phase name
• Full log:  $LOG
• Other TTY: Ctrl+Alt+F2 → root →  tail -f $LOG
• Menus: Next advances, Abort/Esc quits; [log] / [help] always available
• Checklist: Space toggles, Enter = Next
• Radio/menu: arrows (+ Space on radio), Enter = Next
• Severity badge + chrome (not color alone): INFO / WARN / ERROR / CRITICAL / OK
• Destructive confirms default No
• Hard gates (DMI/hook): Continue / Abort · wipe confirms: Erase / Abort
• Live steps (pacstrap/chroot): dialog progress box; whiptail/plain stream to TTY"
}

# Handle special nav tags; return 0 if consumed (caller should re-prompt).
ui_nav_special() {
  case "$1" in
    log) ui_view_log; return 0 ;;
    help) ui_console_help; return 0 ;;
    *) return 1 ;;
  esac
}

ui_yesno() { # text [default] [severity]
  # default = yes|no (destructive callers pass no).
  # severity = info|warn|error|critical|erase
  #   critical → CRITICAL chrome + Continue/Abort (hard gate, not wipe)
  #   erase    → CRITICAL chrome + Erase/Abort (disk/partition wipe only)
  local text=$1 def=${2:-yes} sev=${3:-}
  local folded old_title old_newt old_drc btn_role
  folded=$(ui_fold "$text"; printf x); folded=${folded%x}
  old_title=$TUI_TITLE old_newt=$TUI_NEWT old_drc=$TUI_DIALOGRC
  btn_role=yesno
  case $sev in
    warn)
      TUI_TITLE="Confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_WARN
      TUI_DIALOGRC=${DIALOG_RC_WARN:-$DIALOG_RC}
      ;;
    error)
      TUI_TITLE="Confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_ERROR
      TUI_DIALOGRC=${DIALOG_RC_ERROR:-$DIALOG_RC}
      ;;
    critical)
      TUI_TITLE="CRITICAL confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_CRITICAL
      TUI_DIALOGRC=${DIALOG_RC_CRITICAL:-$DIALOG_RC}
      btn_role=critical_yesno
      ;;
    erase)
      TUI_TITLE="ERASE confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_CRITICAL
      TUI_DIALOGRC=${DIALOG_RC_CRITICAL:-$DIALOG_RC}
      btn_role=erase_yesno
      ;;
    info)
      TUI_TITLE="Confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_INFO
      TUI_DIALOGRC=${DIALOG_RC_INFO:-$DIALOG_RC}
      ;;
  esac
  if [[ $UI == plain ]]; then
    local suf=' [Y/n]: ' v tag=
    [[ $def == no ]] && suf=' [y/N]: '
    case $sev in
      warn) tag="${cY}[WARN]${c0} " ;;
      error) tag="${cR}[ERROR]${c0} " ;;
      critical) tag="${cR}[CRITICAL]${c0} " ;;
      erase) tag="${cR}[ERASE]${c0} " ;;
    esac
    printf '%s%s\n' "$tag" "$folded" >&2
    read -r -p "$suf" v </dev/tty || true
    v=${v:-$def}
    TUI_TITLE=$old_title; TUI_NEWT=$old_newt; TUI_DIALOGRC=$old_drc
    [[ ${v,,} == y* ]]
    return
  fi
  local extra=(); [[ $def == no ]] && extra=(--defaultno)
  _tui_btns "$btn_role"
  local rc=0
  tui "${extra[@]}" "${_btns[@]}" --yesno "$folded" "$(msg_height "$folded")" "$W" || rc=$?
  TUI_TITLE=$old_title; TUI_NEWT=$old_newt; TUI_DIALOGRC=$old_drc
  return "$rc"
}

ui_input() { # prompt [default]
  if [[ $UI == plain ]]; then ask "$1: " "${2:-}"; return; fi
  _tui_btns nav
  tui "${_btns[@]}" --inputbox "$1" 10 "$W" "${2:-}"
}

ui_password() { # prompt
  if [[ $UI == plain ]]; then ask_secret "$1: "; return; fi
  _tui_btns nav
  tui "${_btns[@]}" --passwordbox "$1" 10 "$W"
}

# ui_menu prompt tag description [tag description ...]  -> tag on stdout
# Always offers log / help as extra entries. Next advances; Abort/Esc quits.
ui_menu() {
  local prompt=$1; shift
  local args=("$@") choice
  while true; do
    set -- "${args[@]}"
    if [[ $UI != plain ]]; then
      _tui_btns nav
      choice=$(tui "${_btns[@]}" --menu "${prompt}

$TUI_HINT_MENU" \
        "$H" "$W" "$LH" "$@" \
        log "View install log" \
        help "Console / log tips") || return 1
    else
      local tags=() descs=() t d i=0
      printf '\n%s\n' "$prompt" >&2
      while (( $# >= 2 )); do
        t=$1 d=$2; shift 2; tags+=("$t") descs+=("$d"); i=$((i + 1))
        printf '  %d) %s [%s]\n' "$i" "$d" "$t" >&2
      done
      tags+=(log help); descs+=("View install log" "Console / log tips")
      i=$((i + 2))
      printf '  %d) View install log [log]\n' "$((i - 1))" >&2
      printf '  %d) Console / log tips [help]\n' "$i" >&2
      local pick
      read -r -p "choose 1-$i (empty=1): " pick </dev/tty || true
      [[ -z $pick ]] && pick=1
      if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )); then
        choice="${tags[pick - 1]}"
      else
        choice=$pick
      fi
    fi
    ui_nav_special "$choice" && continue
    printf '%s' "$choice"
    return 0
  done
}

# ui_radio prompt tag description on|off [...] -> tag
ui_radio() {
  local prompt=$1; shift
  local args=("$@") choice
  while true; do
    set -- "${args[@]}"
    if [[ $UI != plain ]]; then
      _tui_btns nav
      choice=$(tui "${_btns[@]}" --radiolist "${prompt}

$TUI_HINT_RADIO" \
        "$H" "$W" "$LH" "$@" \
        log "View install log" off \
        help "Console / log tips" off) || return 1
    else
      local tags=() descs=() def='' t d s i=0
      printf '\n%s\n' "$prompt" >&2
      while (( $# >= 3 )); do
        t=$1 d=$2 s=$3; shift 3; tags+=("$t") descs+=("$d"); i=$((i + 1))
        [[ $s == on ]] && def=$t
        printf '  %d) %s [%s]\n' "$i" "$d" "$t" >&2
      done
      printf '  L) View install log\n  H) Console / log tips\n' >&2
      local pick
      read -r -p "choose 1-$i / L / H (default $def): " pick </dev/tty || true
      case "${pick,,}" in
        l) choice=log ;;
        h) choice=help ;;
        '') choice=$def ;;
        *)
          if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )); then
            choice="${tags[pick - 1]}"
          else
            choice=$def
          fi
          ;;
      esac
    fi
    ui_nav_special "$choice" && continue
    printf '%s' "$choice"
    return 0
  done
}

# ui_checklist prompt tag item on|off [...] -> selected tags, one per line
# Space toggles (dialog/whiptail). Plain: number toggles + empty line confirms.
# Always offers log / help; selecting either re-opens the checklist.
ui_checklist() {
  local prompt=$1; shift
  local args=("$@") out raw
  while true; do
    set -- "${args[@]}"
    if [[ $UI == dialog ]]; then
      _tui_btns nav
      raw=$(tui "${_btns[@]}" --separate-output --checklist "${prompt}

$TUI_HINT_CHECK" \
        "$H" "$W" "$LH" "$@" \
        log "View install log" off \
        help "Console / log tips" off) || return 1
      out=$raw
    elif [[ $UI == whiptail ]]; then
      _tui_btns nav
      raw=$(tui "${_btns[@]}" --checklist "${prompt}

$TUI_HINT_CHECK" \
        "$H" "$W" "$LH" "$@" \
        log "View install log" off \
        help "Console / log tips" off) || return 1
      out=$(printf '%s\n' "$raw" | sed 's/"/\n/g' | awk 'NF && $0 !~ /^[[:space:]]*$/')
    else
      local tags=() descs=() states=() t d s i=0
      printf '\n%s\n' "$prompt" >&2
      printf '(numbers toggle; empty line=Next; L=log H=help)\n' >&2
      while (( $# >= 3 )); do
        t=$1 d=$2 s=$3; shift 3
        tags+=("$t"); descs+=("$d"); states+=("$s"); i=$((i + 1))
      done
      while true; do
        local j
        for (( j=0; j<i; j++ )); do
          printf '  %d) [%s] %s\n' "$((j + 1))" \
            "$([[ ${states[j]} == on ]] && echo x || echo ' ')" "${descs[j]}" >&2
        done
        local pick
        read -r -p "toggle # / Enter=Next / L=log / H=help: " pick </dev/tty || true
        case "${pick,,}" in
          '') break ;;
          l) ui_view_log; continue ;;
          h) ui_console_help; continue ;;
          *)
            if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= i )); then
              if [[ ${states[pick - 1]} == on ]]; then
                states[pick - 1]=off
              else
                states[pick - 1]=on
              fi
            fi
            ;;
        esac
      done
      out=""
      for (( j=0; j<i; j++ )); do
        [[ ${states[j]} == on ]] && out+="${tags[j]}"$'\n'
      done
    fi
    # log/help alone → open viewer and re-prompt. Mixed with real tags → strip nav.
    local real
    real=$(printf '%s\n' "$out" | grep -Ev '^(log|help)$' || true)
    if [[ -z $real ]]; then
      if printf '%s\n' "$out" | grep -qx log; then
        ui_view_log
        continue
      fi
      if printf '%s\n' "$out" | grep -qx help; then
        ui_console_help
        continue
      fi
    fi
    printf '%s' "$real"
    return 0
  done
}

ui_infobox() { [[ $UI == plain ]] && return 0; tui --infobox "$1" "$H" "$W"; }
step() { say "$*"; ui_infobox "$*"; }

# ── logging around the destructive phase ────────────────────
# stdout/stderr go to $LOG so the TUI stays clean — but long jobs (pacstrap)
# must still show live progress (dialog --progressbox or TTY tee).
start_log() { LOGGING=1; exec 8>&1 9>&2; exec >>"$LOG" 2>&1; }
stop_log()  { exec >&8 2>&9; LOGGING=0; }

# Plain-console header for a long step (label + where to follow the log).
progress_banner() {
  {
    printf '\n'
    printf '────────────────────────────────────────────────────────\n'
    printf ' %s\n' "$1"
    printf ' log: %s\n' "$LOG"
    printf ' (live output — can take several minutes)\n'
    printf ' tip: other TTY → tail -f %s\n' "$LOG"
    printf '────────────────────────────────────────────────────────\n\n'
  } >/dev/tty
  return 0
}

# Run a long command with live TUI/console output AND append to $LOG.
# Usage: run_progress "label" cmd [args…]
run_progress() {
  local desc=$1; shift
  local rc=0
  say "$desc"
  if [[ $UI == dialog && -w /dev/tty ]]; then
    # dialog --progressbox: piped output, exits when the command ends (no OK).
    # Pipe captures cmd stdout (overrides exec→LOG), so tee -a back into $LOG.
    # Must keep stdin as the pipe — tui's default </dev/tty would starve progressbox.
    set +e
    TUI_KEEP_STDIN=1
    "$@" 2>&1 | tee -a "$LOG" | tui --progressbox "${desc}

log: $LOG" "$H" "$W"
    rc=${PIPESTATUS[0]}
    TUI_KEEP_STDIN=0
    set -e
    return "$rc"
  fi
  if [[ -w /dev/tty ]]; then
    progress_banner "$desc"
    set +e
    # Pipe steals stdout from exec→LOG; tee -a keeps the file in sync.
    "$@" 2>&1 | tee -a "$LOG" >/dev/tty
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
  fi
  "$@"
}

# Turn command output (stdin) into a progress estimate. Raw lines always go to
# $LOG. Signals understood:
#   "@@STAGE lo hi text"   chroot stage marker: new band lo–hi %, caption text
#   "Packages (N) …"       pacman transaction size ("Package (N)" with VerbosePkgLists)
#   " <file> downloading..."   pacman (no TTY): one file download started
#   "( k/N) verb …"        pacman counters (keys/integrity/install/hooks)
#   ">> text"              installer say() line → detail caption
# pacman phases inside the current band: download 0–40 %, verify 40–50 %,
# install 50–95 %, hooks 95–100 %. Percent only moves forward inside a band
# (a new @@STAGE sets it to the band start); capped at 99 until the command exits.
# $3 = gauge: emit dialog/whiptail --gauge protocol on stdout
#      text:  echo raw lines (markers become ">> [nn%] text") for plain consoles
# $4 = step label repeated at the top of every gauge caption
# $5 = footer line on every caption (log path / tail -f hint)
progress_filter() {
  local lo=${1:-0} hi=${2:-100} mode=${3:-gauge} desc=${4:-} hint=${5:-}
  local line clean pct=$lo new stage="" detail="" total=0 dl=0
  local cur tot what blo bhi esc=$'\e'
  shopt -s extglob
  while IFS= read -r line || [[ -n $line ]]; do
    printf '%s\n' "$line" >>"$LOG"
    clean=${line##*$'\r'}
    clean=${clean//$esc\[*([0-9;])[a-zA-Z]/}
    new=-1
    if [[ $clean =~ ^@@STAGE\ ([0-9]+)\ ([0-9]+)\ (.*)$ ]]; then
      lo=${BASH_REMATCH[1]} hi=${BASH_REMATCH[2]} stage=${BASH_REMATCH[3]}
      detail="" total=0 dl=0 pct=$lo   # stages are sequential: jump to band start
      if [[ $mode == text ]]; then printf '>> [%s%%] %s\n' "$lo" "$stage"; continue; fi
    elif [[ $clean =~ ^Packages?\ \(([0-9]+)\) ]]; then
      total=${BASH_REMATCH[1]} dl=0
      detail="resolving ${total} packages"
    elif [[ $clean == *" downloading..." ]]; then
      dl=$(( dl + 1 ))
      if (( total > 0 )); then
        (( dl > total )) && dl=$total
        new=$(( lo + (hi - lo) * 40 * dl / (100 * total) ))
        detail="downloading packages (${dl}/${total})"
      else
        detail="downloading packages (${dl})"
      fi
    elif [[ $clean =~ ^\(\ *([0-9]+)/([0-9]+)\)\ (.+)$ ]]; then
      cur=${BASH_REMATCH[1]} tot=${BASH_REMATCH[2]} what=${BASH_REMATCH[3]}
      (( tot > 0 )) || tot=1
      case $what in
        installing\ *|upgrading\ *|reinstalling\ *) blo=50 bhi=95 ;;
        checking\ *|loading\ *) blo=40 bhi=50 ;;
        *) blo=95 bhi=100 ;;
      esac
      new=$(( lo + (hi - lo) * (blo + (bhi - blo) * cur / tot) / 100 ))
      detail="${what%%...*} (${cur}/${tot})"
    elif [[ $clean =~ ^\>\>\ (.+)$ ]]; then
      detail=${BASH_REMATCH[1]}
    fi
    if [[ $mode == text ]]; then printf '%s\n' "$line"; continue; fi
    if (( new > pct )); then pct=$new; fi
    if (( pct > 99 )); then pct=99; fi
    printf 'XXX\n%s\n%s\n\n%s\n%s\n\n%s\nXXX\n' "$pct" "$desc" "${stage:-working…}" \
      "${detail:0:$(( W - 8 ))}" "$hint"
  done
  return 0
}

# Long step with a percentage gauge (dialog/whiptail), fed by progress_filter.
# Usage: run_gauge "label" lo hi cmd [args…]   (lo/hi = initial % band)
# Plain console: live raw output (stage markers shown as ">> [nn%] …").
run_gauge() {
  local desc=$1 lo=$2 hi=$3; shift 3
  local rc=0 hint="log: $LOG · other TTY: tail -f $LOG"
  say "$desc"
  set +e
  if [[ ( $UI == dialog || $UI == whiptail ) && -w /dev/tty ]]; then
    TUI_KEEP_STDIN=1
    "$@" 2>&1 | progress_filter "$lo" "$hi" gauge "$desc" "$hint" \
      | tui --gauge "${desc}

${hint}" 14 "$W" "$lo"
    rc=${PIPESTATUS[0]}
    TUI_KEEP_STDIN=0
  elif [[ -w /dev/tty ]]; then
    progress_banner "$desc"
    "$@" 2>&1 | progress_filter "$lo" "$hi" text >/dev/tty
    rc=${PIPESTATUS[0]}
  else
    "$@" 2>&1 | progress_filter "$lo" "$hi" text >/dev/null
    rc=${PIPESTATUS[0]}
  fi
  set -e
  return "$rc"
}

# Tune a pacman.conf in place (live ISO and target; shipped into the chroot via
# declare -f). $1 conf, $2 ParallelDownloads, $3 Y = enable [multilib].
#   * no XferCommand (it serializes downloads and ignores ParallelDownloads)
#   * DisableDownloadTimeout (slow mirrors stall instead of aborting)
#   * Color + ILoveCandy, VerbosePkgLists, CheckSpace
pacman_tune() {
  local conf=$1 par=${2:-10} multilib=${3:-N}
  [[ -f $conf ]] || return 1
  sed -i '/^XferCommand[[:space:]]*=/d' "$conf"
  if grep -qE '^#?ParallelDownloads' "$conf"; then
    sed -i -E "s/^#?ParallelDownloads.*/ParallelDownloads = ${par}/" "$conf"
  else
    sed -i "/^\\[options\\]/a ParallelDownloads = ${par}" "$conf"
  fi
  sed -i -E 's/^#(Color|VerbosePkgLists|CheckSpace)[[:space:]]*$/\1/' "$conf"
  grep -q '^Color' "$conf" || sed -i '/^\[options\]/a Color' "$conf"
  grep -q '^ILoveCandy' "$conf" || sed -i '/^Color/a ILoveCandy' "$conf"
  grep -q '^DisableDownloadTimeout' "$conf" \
    || sed -i '/^\[options\]/a DisableDownloadTimeout' "$conf"
  if [[ $multilib == Y ]]; then
    # Only [multilib] and its Include line — never [multilib-testing].
    sed -i '/^#\[multilib\]$/{s/^#//;n;s/^#Include/Include/}' "$conf"
  fi
  return 0
}

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
  fi
  ui_geometry
  return 0
}
