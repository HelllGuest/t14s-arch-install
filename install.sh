#!/usr/bin/env bash
# install.sh — interactive hardened Arch install for ThinkPad T14s Gen 3 AMD
#               (machine type 21CQ / 21CR; example MTM 21CRS1PU00)
#
# Target: Rembrandt-U (Ryzen 5/7 PRO 6650U/6850U), soldered LPDDR5, amdgpu,
#         Wi-Fi 6E, 57Wh, s2idle.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
#
# Stack: LUKS2(argon2id) + Btrfs + linux-lts/hardened UKIs + systemd-boot +
#        sbctl Secure Boot + minimal GNOME. AMD defaults: amd-ucode,
#        amd_iommu=on, amd_pstate=active. Hostname default: thinkpad-t14s.
#
# BIOS (F1): Secure Boot off for install; Sleep State = "Windows and Linux"
# (s2idle); enable AMD SVM + IOMMU. Re-enable Secure Boot after sbctl enroll.
#
# RUN FROM THE ARCH ISO (live environment), as root, UEFI mode, with internet.
# THIS ERASES DATA on the partitions you select.
#
# UI: full-screen whiptail/dialog TUI on /dev/tty. dialog is installed from the
# live repos if no backend exists; plain line prompts are the fallback.
set -euo pipefail

# ── ui helpers ──────────────────────────────────────────────
c0=$'\e[0m'; cR=$'\e[1;31m'; cG=$'\e[1;32m'; cY=$'\e[1;33m'; cB=$'\e[1;34m'
cC=$'\e[1;36m'
# Mirror status to /dev/tty when stdout is redirected into $LOG (destructive phase).
_tty() { [[ -w /dev/tty ]] && printf '%s\n' "$*" >/dev/tty || true; }

say()  {
  local m; m=$(printf '%s>>%s %s' "$cB" "$c0" "$*")
  printf '%s\n' "$m"
  if (( LOGGING )); then _tty "$m"; fi
  return 0
}
ok()   {
  local m; m=$(printf '%s ok%s %s' "$cG" "$c0" "$*")
  printf '%s\n' "$m"
  if (( LOGGING )); then _tty "$m"; fi
  return 0
}
warn() {
  local m; m=$(printf '%s !!%s %s' "$cY" "$c0" "$*")
  printf '%s\n' "$m" >&2
  if (( LOGGING )); then _tty "$m"; fi
  return 0
}

DRYRUN=${T14S_DRYRUN:-0}
UI=${T14S_UI:-plain}
# Accept 1/y/yes/on (case-insensitive) for env toggles — same spirit as yn_on.
_env_on() { local v=${1,,}; [[ $v == 1 || $v == y || $v == yes || $v == on ]]; }
if _env_on "${T14S_NONINTERACTIVE:-0}"; then NONINTERACTIVE=1; else NONINTERACTIVE=0; fi
ANSWERS_IN=${T14S_ANSWERS:-}
PASS_FILE=${T14S_PASS_FILE:-}
if _env_on "${T14S_I_WILL_ERASE:-0}"; then WILL_ERASE=1; else WILL_ERASE=0; fi
unset -f _env_on
# Never accept LUKS/user/root passwords from ambient environment (/proc leak).
# Unattended secrets come only from T14S_PASS_FILE; interactive uses ui_password.
unset -v LUKS_PASS USER_PASS ROOT_PASS
SECRETS_FROM_FILE=0
APP_TITLE="T14s Arch Installer"
PRESET=gnome
POST_HOOK_URL=""
EXTRA_PKGS=()
EXTRA_PKGS_LIST=""
LOG="$(mktemp /tmp/t14s-install.XXXXXX.log)"
LOGGING=0
DIALOG_RC=""
DIALOG_RC_DIR=""
DIALOG_RC_INFO="" DIALOG_RC_WARN="" DIALOG_RC_ERROR="" DIALOG_RC_CRITICAL="" DIALOG_RC_OK=""
TUI_TITLE=""
TUI_NEWT=""
TUI_DIALOGRC=""
TUI_KEEP_STDIN=0

# Wizard progress (Heads / modern installer pattern: step in backtitle).
TUI_STEPS=11
TUI_STEP=0
TUI_STEP_NAME=""
# Shared key hints (one question per screen; never color-only).
TUI_HINT_MENU='[log] view install log · [help] tips · Esc/Abort quits'
TUI_HINT_RADIO='Arrows+Space select · Enter=Next · Esc=Abort · [log]/[help]'
TUI_HINT_CHECK='Space=toggle · Enter=Next · Esc=Abort · [log]/[help]'

# Screen geometry, clamped so tiny/huge terminals stay usable.
# Refresh on each ui_step (step boundaries only; no SIGWINCH trap).
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
  local msg=${1:-failed} rc=${2:-1}
  trap - ERR
  printf '%sERR%s %s\n' "$cR" "$c0" "$msg" >&2
  if [[ $UI != plain ]]; then
    ui_critical "$msg

Full log: $LOG" || true
    if (( LOGGING )); then
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
# BASH_COMMAND is the unexpanded source text, so "$LUKS_PASS" stays a name, not a value.
trap 'die "failed at line $LINENO (exit $?): $BASH_COMMAND" $?' ERR
trap 'cleanup_ui' EXIT

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

  if [[ $UI == plain ]]; then
    printf '\n%s[%s]%s\n%s\n' "$plain_c" "$badge" "$c0" "$folded" >&2
    plain_pause
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

part_of() { # $1 disk, $2 num -> partition path (nvme/mmc need 'p')
  local d="$1" n="$2"
  [[ $d == *nvme* || $d == *mmcblk* || $d == *loop* ]] && printf '%sp%s' "$d" "$n" || printf '%s%s' "$d" "$n"
}

# Identity validators (before wipe).
# Test fixtures only when T14S_IDENTITY_OVERRIDES=1: LOCALE_FILES, KEYMAP_DIR.
valid_hostname() {
  local h="$1"
  # Single label or dotted FQDN; no leading/trailing hyphen or dot per label.
  [[ $h =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

valid_username() {
  local u="$1"
  [[ $u =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  (( ${#u} <= 32 )) || return 1
  # Reject names already in passwd or group (root/bin/nobody/wheel on the ISO).
  id "$u" &>/dev/null && return 1
  getent group "$u" >/dev/null 2>&1 && return 1
  return 0
}

valid_timezone() {
  local tz="$1" f magic
  [[ $tz != *..* ]] || return 1
  [[ $tz =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  # TZif junk / non-zone files that sit under zoneinfo.
  case $tz in
    Factory|leapseconds|posixrules|localtime|iso3166.tab|zone.tab|zonenow.tab|tzdata.zi) return 1 ;;
  esac
  f="/usr/share/zoneinfo/$tz"
  [[ -f $f ]] || return 1
  magic="$(head -c4 "$f" 2>/dev/null || true)"
  [[ $magic == TZif ]]
}

valid_locale() {
  local loc="$1" f line name
  local -a files=()
  [[ -n $loc ]] || return 1
  if [[ ${T14S_IDENTITY_OVERRIDES:-0} == 1 && -n ${LOCALE_FILES:-} ]]; then
    # shellcheck disable=SC2206
    files=(${LOCALE_FILES})
  else
    files=(/usr/share/i18n/SUPPORTED /etc/locale.gen)
  fi
  for f in "${files[@]}"; do
    [[ -r $f ]] || continue
    while read -r line || [[ -n $line ]]; do
      [[ $line =~ ^[[:space:]]*#?([A-Za-z0-9_.@-]+)[[:space:]] ]] || continue
      name="${BASH_REMATCH[1]}"
      [[ $name == "$loc" ]] && return 0
    done <"$f"
  done
  return 1
}

valid_keymap() {
  local km="$1" root=/usr/share/kbd/keymaps
  # Literal name only — never pass glob/regex metacharacters to find/grep.
  [[ $km =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
  if [[ ${T14S_IDENTITY_OVERRIDES:-0} == 1 && -n ${KEYMAP_DIR:-} ]]; then
    root="$KEYMAP_DIR"
  fi
  if command -v localectl >/dev/null 2>&1; then
    localectl list-keymaps 2>/dev/null | grep -qxF -- "$km" && return 0
    # Not listed: still accept an exact on-disk map (browse path). Charset is safe.
  fi
  # Directory check only for find fallback (Ubuntu CI often has no kbd keymaps tree).
  [[ -d $root ]] || return 1
  find "$root" -type f \
    \( -name "${km}.map" -o -name "${km}.map.gz" \
       -o -name "${km}.kmap" -o -name "${km}.kmap.gz" \) \
    2>/dev/null | grep -q .
}

disk_type() { lsblk -dno TYPE "$1" 2>/dev/null; }
size_mb()   { local b; b="$(lsblk -bdnro SIZE "$1" 2>/dev/null)"; printf '%s' "$(( ${b:-0} / 1048576 ))"; }
part_fs()   { lsblk -no FSTYPE "$1" 2>/dev/null | head -1; }

# build_part_menu ARRAY DISK [filter] [exclude]
#   filter = any | vfat; fills ARRAY with tag/description pairs for ui_menu.
build_part_menu() {
  local -n _out=$1
  local _disk=$2 _filter=${3:-any} _excl=${4:-} typ p sz fs tt
  _out=()
  while read -r typ p sz fs tt; do
    [[ $typ == part ]] || continue
    [[ -n $_excl && $p == "$_excl" ]] && continue
    [[ $_filter == vfat && $fs != vfat ]] && continue
    _out+=("$p" "${sz}  ${fs:-empty}  ${tt:-}")
  done < <(lsblk -prno TYPE,PATH,SIZE,FSTYPE,PARTTYPENAME "$_disk" 2>/dev/null)
  _out+=(manual "type a partition path")
}

# pick_part PROMPT DISK [filter] [exclude] -> partition path on stdout
pick_part() {
  local prompt=$1 disk=$2 filter=${3:-any} excl=${4:-}
  local arr=() ans
  while :; do
    build_part_menu arr "$disk" "$filter" "$excl"
    ans="$(ui_menu "$prompt" "${arr[@]}")" || return 1
    if [[ $ans == manual ]]; then
      ans="$(ui_input "Partition path (e.g. /dev/nvme0n1p2)" "")" || return 1
    fi
    if [[ -z $ans ]]; then continue; fi
    if [[ ! -b $ans ]]; then ui_error "Not a block device: $ans"; continue; fi
    if [[ $(disk_type "$ans") != part ]]; then
      ui_error "$ans is a whole disk, not a partition."; continue
    fi
    # Manual entry can name any disk; match the noninteractive part_on_disk check.
    if ! part_on_disk "$ans" "$disk"; then
      ui_error "$ans is not a partition on $disk."; continue
    fi
    printf '%s' "$ans"; return 0
  done
}

# archfi-inspired pickers: keymap from ISO maps, timezone Region/City menus.
# Commons must be real map basenames under /usr/share/kbd/keymaps.
pick_keymap() {
  local choice km args=() browse_args=()
  local commons=(us uk de fr es it pt-latin1 br-abnt2 ru jp106 dvorak colemak)
  for km in "${commons[@]}"; do
    args+=("$km" "common")
  done
  args+=(other "type a keymap name" browse "browse all keymaps on the ISO")
  while :; do
    choice="$(ui_menu "Console keymap (applied live with loadkeys)" "${args[@]}")" \
      || return 1
    case $choice in
      other)
        km="$(ui_input "Keymap name" us)" || return 1
        [[ -n $km ]] || continue
        printf '%s' "$km"
        return 0
        ;;
      browse)
        # Strip only .map.gz / .map — ${f%%.*} collapses lt.baltic → lt.
        browse_args=()
        while read -r km; do
          [[ -n $km ]] || continue
          browse_args+=("$km" "")
        done < <(find /usr/share/kbd/keymaps -type f \
          \( -name '*.map' -o -name '*.map.gz' \) -printf '%f\n' 2>/dev/null \
          | sed -E 's/\.map(\.gz)?$//' | sort -u)
        (( ${#browse_args[@]} >= 2 )) \
          || { ui_error "No keymaps under /usr/share/kbd/keymaps"; continue; }
        choice="$(ui_menu "All keymaps" "${browse_args[@]}")" || continue
        printf '%s' "$choice"
        return 0
        ;;
      *)
        printf '%s' "$choice"
        return 0
        ;;
    esac
  done
}

# Emit only a resolvable zone file path (or UTC). Never a directory.
pick_timezone() {
  local zroot=/usr/share/zoneinfo region city sub args=() d path
  # Do not invent UTC when zoneinfo is missing — valid_timezone needs a TZif file.
  [[ -d $zroot ]] || { ui_error "Missing $zroot — cannot pick a timezone"; return 1; }
  while read -r d; do
    args+=("$d" "")
  done < <(find "$zroot" -mindepth 1 -maxdepth 1 -type d \
    ! -name right ! -name posix -printf '%f\n' 2>/dev/null | sort)
  args+=(UTC "Coordinated Universal Time" other "type Region/City")
  region="$(ui_menu "Timezone region" "${args[@]}")" || return 1
  if [[ $region == other ]]; then
    city="$(ui_input "Timezone (Region/City)" America/New_York)" || return 1
    [[ -n $city ]] || return 1
    printf '%s' "$city"
    return 0
  fi
  if [[ $region == UTC ]]; then
    printf 'UTC'
    return 0
  fi
  args=()
  while read -r d; do
    args+=("$d" "")
  done < <(find "$zroot/$region" -mindepth 1 -maxdepth 1 \
    \( -type f -o -type d \) -printf '%f\n' 2>/dev/null | sort)
  (( ${#args[@]} >= 2 )) || { ui_error "No zones under $region"; return 1; }
  city="$(ui_menu "Timezone city ($region)" "${args[@]}")" || return 1
  path="$region/$city"
  # One nested level (e.g. America/Argentina/Buenos_Aires).
  if [[ -d $zroot/$path ]]; then
    args=()
    while read -r d; do
      args+=("$d" "")
    done < <(find "$zroot/$path" -mindepth 1 -maxdepth 1 \
      \( -type f -o -type d \) -printf '%f\n' 2>/dev/null | sort)
    if (( ${#args[@]} < 2 )); then
      ui_error "No zone files under $path"
      return 1
    fi
    sub="$(ui_menu "Timezone ($path)" "${args[@]}")" || return 1
    path="$path/$sub"
  fi
  if [[ ! -f $zroot/$path ]]; then
    ui_error "Not a timezone file: $path"
    return 1
  fi
  printf '%s' "$path"
}

# ── 0. preflight ────────────────────────────────────────────
if (( ! DRYRUN )); then
  [[ $EUID -eq 0 ]] || die "run as root (from the Arch ISO)"
  [[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode — enable UEFI and reboot the ISO"
  # Leftover-state cleanup below disables all swap and unmounts /mnt: live ISO only.
  [[ -d /run/archiso || ${T14S_ALLOW_NON_ISO:-0} == 1 ]] \
    || die "not running from the Arch ISO (/run/archiso missing); set T14S_ALLOW_NON_ISO=1 to override"
  { ping -c1 -W3 archlinux.org || curl -fsS --max-time 6 https://archlinux.org; } >/dev/null 2>&1 \
    || die "no internet — connect first (iwctl / dhcp), then re-run"
  timedatectl set-ntp true || true
fi
bootstrap_ui
say "preflight ok (UEFI + network + ntp)"

# clean leftover state from a previous interrupted run so re-runs start fresh
# (otherwise an open cryptroot / mounted /mnt keeps the disk busy → sgdisk/mkfs
#  can't reformat → stale files survive → pacstrap 'conflicting files').
# Never touch mounts/swap during T14S_DRYRUN (safe on a normal host).
if (( ! DRYRUN )); then
  umount -R /mnt 2>/dev/null || true
  swapoff -a 2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
fi

if (( NONINTERACTIVE )); then
  warn "NONINTERACTIVE: skipping welcome TUI (answers + T14S_I_WILL_ERASE gate wipe)"
else
  ui_step 1 Welcome
  ui_warn "T14s Gen 3 AMD ARCH INSTALLER — DESTROYS DATA ON DISK

Machine: ThinkPad T14s Gen 3 AMD (Type 21CQ/21CR) — Rembrandt + amdgpu
Stack:   LUKS2 + Btrfs(+@tmp) + linux-lts/hardened + UKI + systemd-boot
         + minimal GNOME + zram + AppArmor + UFW + Snapper + Secure Boot

One question per screen. Backtitle shows Step N/11.
All answers from /dev/tty. Nothing written until the final Erase confirm.
Destructive confirms default No. Wipe = Erase/Abort; hard gates = Continue/Abort."
fi

# Soft DMI check — Gen 3 AMD types only (21CQ/21CR). Anchored to avoid substring noise.
ui_step 2 Hardware
_dmi="$(cat /sys/class/dmi/id/product_family /sys/class/dmi/id/product_version \
          /sys/class/dmi/id/product_name /sys/class/dmi/id/product_sku 2>/dev/null \
        | tr '\n' ' ')"
if echo "$_dmi" | grep -qiE '(^|[[:space:]_/])21C[QR]([[:alnum:]_-]|$)'; then
  ok "target profile: T14s Gen 3 AMD (21CQ/21CR)"
else
  if (( NONINTERACTIVE )); then
    warn "NONINTERACTIVE: DMI not 21CQ/21CR (${_dmi:-unknown}) — continuing"
  else
    ui_yesno "DMI is NOT T14s Gen 3 AMD type 21CQ/21CR:
${_dmi:-unknown}

Continue only if intentional (VM rehearsal / forced). Wrong machine? Abort." no critical \
      || die "aborted — this installer is for type 21CQ/21CR only"
  fi
fi
if ! grep -q AuthenticAMD /proc/cpuinfo; then
  if (( NONINTERACTIVE )); then
    warn "NONINTERACTIVE: CPU not AuthenticAMD — continuing (amd-ucode/cmdline still set)"
  else
    ui_yesno "CPU is not AuthenticAMD.
This installer sets amd-ucode + amd_iommu/amd_pstate.

Continue without an AMD CPU (VM rehearsal)?" no warn \
      || die "aborted — need AuthenticAMD or explicit YES"
  fi
fi

# ── answers helpers (T14S_ANSWERS=file; export at end) ───────
# Known keys only — never eval the answers file.
ANSWERS_KEYS=(
  PRESET DESKTOP INSTALL_NERD_FONTS ENROLL_SB ENABLE_SSHD INSTALL_CUPS
  SKIP_REFLECTOR INSTALL_TLP INSTALL_CLI INSTALL_PODMAN INSTALL_DOCKER
  INSTALL_VIRT INSTALL_AVAHI INSTALL_WIREGUARD INSTALL_TAILSCALE
  INSTALL_STARSHIP INSTALL_CHROME_HINT INSTALL_FAIL2BAN INSTALL_THINKFAN
  INSTALL_SNAPPER_HOME INSTALL_LINUX_STABLE INSTALL_PLYMOUTH INSTALL_SELFTEST
  INSTALL_MULTILIB INSTALL_YAY INSTALL_TUNED INSTALL_DEVTOOLS INSTALL_BTRFS_ASSISTANT
  CLEAN_ESP_ARCH
  UFW_SYNCTHING UFW_KDECONNECT POST_HOOK_URL
  PACMAN_PARALLEL LUKS_WIPE HOSTNAME TIMEZONE LOCALE KEYMAP USERNAME
  MODE ESP_MB FORMAT_EFI DISK EFI_PART ROOT_PART
  BTRFS_COMPRESS ZRAM_SIZE REFLECTOR_COUNTRY SKIP_THINKPAD_HW
  EXTRA_PKGS_LIST
)

answers_load() {
  local f=$1 line key val
  [[ -f $f ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    val=${val%$'\r'}  # CRLF files leave CR at the end
    # Strip one matching pair of surrounding quotes (hand-edited answers).
    if [[ $val == \"*\" ]]; then
      val=${val#\"}; val=${val%\"}
    elif [[ $val == \'*\' ]]; then
      val=${val#\'}; val=${val%\'}
    fi
    case " ${ANSWERS_KEYS[*]} " in
      *" $key "*) printf -v "$key" '%s' "$val" ;;
    esac
  done <"$f"
  return 0
}

answers_save() {
  local f=$1 k val
  {
    printf '# t14s-arch-install answers — reload with T14S_ANSWERS=%s\n' "$f"
    printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf '# Passwords NEVER stored here — use T14S_PASS_FILE for unattended secrets.\n'
    for k in "${ANSWERS_KEYS[@]}"; do
      if [[ -v $k ]]; then val=${!k}; else val=; fi
      printf '%s=%s\n' "$k" "$val"
    done
  } >"$f"
  if ! chmod 600 "$f"; then
    die "could not chmod 600 answers file: $f"
  fi
  _amode=$(stat -c '%a' "$f" 2>/dev/null || echo '')
  if [[ $_amode != 600 && $_amode != 0600 ]]; then
    die "answers file not mode 0600 after chmod (got ${_amode:-unknown}): $f"
  fi
  unset -v _amode
}

# Secrets file (LUKS/USER/ROOT only). Never written by answers_save.
# Format: KEY=value lines. Must be mode 0600 (u=rw only). Fail closed if mode unknown.
secrets_load() {
  local f=$1 line key val mode
  [[ -f $f ]] || return 1
  mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%OLp' "$f" 2>/dev/null || true)
  if [[ -z $mode ]]; then
    die "cannot read mode of T14S_PASS_FILE (need 0600): $f"
  fi
  if [[ $mode != 600 && $mode != 0600 ]]; then
    die "T14S_PASS_FILE must be mode 0600 (got $mode): $f"
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line == *=* ]] || continue
    key=${line%%=*}
    val=${line#*=}
    key=${key#"${key%%[![:space:]]*}"}
    key=${key%"${key##*[![:space:]]}"}
    val=${val%$'\r'}  # CRLF files leave CR at the end
    # Strip one matching pair of surrounding quotes (raw values preferred).
    if [[ $val == \"*\" ]]; then
      val=${val#\"}; val=${val%\"}
    elif [[ $val == \'*\' ]]; then
      val=${val#\'}; val=${val%\'}
    fi
    case $key in
      LUKS_PASS|USER_PASS|ROOT_PASS) printf -v "$key" '%s' "$val" ;;
    esac
  done <"$f"
  return 0
}

# True for y / yes / on / 1 only (case-insensitive). Rejects "yellow", "Y*".
yn_on() {
  local v=${1,,}
  [[ $v == y || $v == yes || $v == on || $v == 1 ]]
}
def_onoff() { if yn_on "$1"; then printf on; else printf off; fi; }
# Canonicalize flag to Y or N (keeps chroot gates + answers consistent).
yn_canon() {
  local -n _yc=$1
  if yn_on "${_yc:-}"; then _yc=Y; else _yc=N; fi
}

# True if partition $1 is a child of disk $2 (PKNAME preferred; bounded path fallback).
part_on_disk() {
  local part=$1 disk=$2 pk base rest
  [[ -b $part && -b $disk ]] || return 1
  pk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
  base=${disk##*/}
  [[ -n $pk && $pk == "$base" ]] && return 0
  # Bound fallback so /dev/nvme0n1 does not match /dev/nvme0n10p1.
  if [[ $disk == *nvme* || $disk == *mmcblk* || $disk == *loop* ]]; then
    [[ $part == "${disk}p"* ]] || return 1
    rest=${part#"${disk}p"}
  else
    [[ $part == "$disk"* && $part != "$disk" ]] || return 1
    rest=${part#"$disk"}
  fi
  [[ $rest =~ ^[0-9]+$ ]]
}

if [[ -n $ANSWERS_IN ]]; then
  if answers_load "$ANSWERS_IN"; then
    ok "loaded answers from $ANSWERS_IN"
  else
    die "T14S_ANSWERS not readable: $ANSWERS_IN"
  fi
fi
if [[ -n $PASS_FILE ]]; then
  if secrets_load "$PASS_FILE"; then
    SECRETS_FROM_FILE=1
    ok "loaded secrets from $PASS_FILE (passwords not saved to answers)"
  else
    die "T14S_PASS_FILE not readable: $PASS_FILE"
  fi
fi
if (( NONINTERACTIVE )); then
  [[ -n $PASS_FILE && $SECRETS_FROM_FILE == 1 ]] \
    || die "NONINTERACTIVE requires T14S_PASS_FILE (mode 0600; no env passwords)"
  [[ -n ${LUKS_PASS:-} && -n ${USER_PASS:-} && -n ${ROOT_PASS:-} ]] \
    || die "T14S_PASS_FILE must set LUKS_PASS, USER_PASS, and ROOT_PASS"
fi

# ── profile preset (feeds checklist defaults) ───────────────
: "${PRESET:=gnome}"
ui_step 3 Profile
if (( ! NONINTERACTIVE )); then
  _pg=off; _pd=off; _pm=off
  case $PRESET in
    dev) _pd=on ;;
    minimal) _pm=on ;;
    *) _pg=on; PRESET=gnome ;;
  esac
  PRESET="$(ui_radio "Install profile (sets checklist defaults; you can still change)" \
    gnome "GNOME laptop — desktop + Nerd Fonts + mDNS" "$_pg" \
    dev "Dev laptop — GNOME + CLI tools + Podman + Starship" "$_pd" \
    minimal "Minimal — no desktop, small tool set" "$_pm")" || die "aborted"
  unset -v _pg _pd _pm
fi
case $PRESET in
  minimal)
    DESKTOP=${DESKTOP:-N}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-N}
    INSTALL_CLI=${INSTALL_CLI:-N}; INSTALL_PODMAN=${INSTALL_PODMAN:-N}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-N}; INSTALL_AVAHI=${INSTALL_AVAHI:-N}
    INSTALL_TLP=${INSTALL_TLP:-Y}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-N}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-N}; INSTALL_YAY=${INSTALL_YAY:-N}
    INSTALL_TUNED=${INSTALL_TUNED:-N}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-N}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-N}
    ;;
  dev)
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-Y}; INSTALL_PODMAN=${INSTALL_PODMAN:-Y}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-Y}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_CHROME_HINT=${INSTALL_CHROME_HINT:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-Y}; INSTALL_YAY=${INSTALL_YAY:-Y}
    INSTALL_TUNED=${INSTALL_TUNED:-Y}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-Y}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-Y}
    INSTALL_SNAPPER_HOME=${INSTALL_SNAPPER_HOME:-Y}
    ;;
  *)
    PRESET=gnome
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-N}; INSTALL_PODMAN=${INSTALL_PODMAN:-N}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-N}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-Y}; INSTALL_YAY=${INSTALL_YAY:-Y}
    INSTALL_TUNED=${INSTALL_TUNED:-Y}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-N}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-Y}
    ;;
esac
# Fill remaining flags with N if unset
: "${ENROLL_SB:=N}" "${ENABLE_SSHD:=N}" "${INSTALL_CUPS:=N}" "${SKIP_REFLECTOR:=N}"
: "${INSTALL_DOCKER:=N}" "${INSTALL_VIRT:=N}" "${INSTALL_WIREGUARD:=N}"
: "${INSTALL_TAILSCALE:=N}" "${INSTALL_CHROME_HINT:=N}" "${INSTALL_FAIL2BAN:=N}"
: "${INSTALL_THINKFAN:=N}" "${UFW_SYNCTHING:=N}" "${UFW_KDECONNECT:=N}"
: "${INSTALL_SNAPPER_HOME:=N}" "${INSTALL_LINUX_STABLE:=N}" "${INSTALL_PLYMOUTH:=N}"
: "${INSTALL_SELFTEST:=N}" "${CLEAN_ESP_ARCH:=Y}"
: "${INSTALL_MULTILIB:=N}" "${INSTALL_YAY:=N}" "${INSTALL_TUNED:=N}"
: "${INSTALL_DEVTOOLS:=N}" "${INSTALL_BTRFS_ASSISTANT:=N}"
: "${PACMAN_PARALLEL:=10}" "${LUKS_WIPE:=none}"
: "${BTRFS_COMPRESS:=zstd3}" "${ZRAM_SIZE:=half}" "${REFLECTOR_COUNTRY:=}"
: "${FORMAT_EFI:=1}"

# Remove prior Arch boot files under an ESP mount root ($1 = /mnt/boot or /boot).
# Always drops kernels/ucode that conflict with pacstrap. When CLEAN_ESP_ARCH=Y
# also removes Arch UKIs, Arch-named loader entries (arch*.conf only), and
# EFI/arch vendor dirs. Does not delete linux-*.conf (may belong to other
# distros on a shared ESP). Never removes EFI/Microsoft or other vendor dirs.
clean_esp_arch_files() {
  local root=${1%/}
  [[ -d $root ]] || return 0
  rm -f "$root"/intel-ucode.img "$root"/amd-ucode.img \
        "$root"/vmlinuz-linux* "$root"/initramfs-linux* 2>/dev/null || true
  if yn_on "${CLEAN_ESP_ARCH:-Y}"; then
    rm -f "$root"/EFI/Linux/arch-linux*.efi \
          "$root"/EFI/Linux/arch*.efi 2>/dev/null || true
    if [[ -d $root/loader/entries ]]; then
      find "$root/loader/entries" -maxdepth 1 -type f \
        -name 'arch*.conf' -delete 2>/dev/null || true
    fi
    # Legacy GRUB/refind-style Arch vendor dirs (case variants).
    rm -rf "$root"/EFI/arch "$root"/EFI/Arch "$root"/EFI/ARCH 2>/dev/null || true
  fi
}
# Replay checklist extras from answers (space-separated package names).
if [[ -n ${EXTRA_PKGS_LIST:-} ]]; then
  # read -a splits on whitespace without pathname expansion (a "*" stays literal).
  read -r -a _pkgs <<<"$EXTRA_PKGS_LIST"
  for _p in "${_pkgs[@]}"; do
    if [[ $_p =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]; then
      EXTRA_PKGS+=("$_p")
    else
      warn "Ignoring invalid EXTRA_PKGS_LIST entry: $_p"
    fi
  done
  unset -v _p _pkgs
fi

# VM / non-ThinkPad rehearsal: skip BAT thresholds, fprintd, thinkfan notes.
IS_VM=0
if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -q 2>/dev/null; then
  IS_VM=1
elif grep -qiE 'qemu|kvm|vmware|virtualbox|xen|bochs|microsoft corporation|hyper-v' \
  /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then
  IS_VM=1
fi
if [[ -z ${SKIP_THINKPAD_HW:-} ]]; then
  if (( IS_VM )); then SKIP_THINKPAD_HW=Y; else SKIP_THINKPAD_HW=N; fi
fi
if yn_on "$SKIP_THINKPAD_HW"; then
  warn "SKIP_THINKPAD_HW=Y (VM=${IS_VM}) — skip charge thresholds / fprintd / thinkfan"
  INSTALL_THINKFAN=N
fi

# ── 1. choose disk ──────────────────────────────────────────
ui_step 4 Disk
if (( NONINTERACTIVE )); then
  [[ -n ${DISK:-} && -b ${DISK:-} && $(disk_type "$DISK") == disk ]] \
    || die "NONINTERACTIVE needs DISK=<whole-disk block device> in answers"
  ok "using DISK from answers: $DISK"
else
  while :; do
    mapfile -t DISKS < <(lsblk -dno PATH,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }')
    menu_args=()
    for d in "${DISKS[@]}"; do
      [[ -b $d ]] || continue
      menu_args+=("$d" "$(lsblk -dnro SIZE,MODEL "$d" 2>/dev/null | sed 's/  */ /g')")
    done
    menu_args+=("manual" "type a device path")

    DISK="$(ui_menu "Select the target disk. AUTO wipes it entirely." "${menu_args[@]}")" \
      || die "no disk selected"
    if [[ $DISK == manual ]]; then
      DISK="$(ui_input "Target disk (e.g. /dev/nvme0n1)" "${DISK:-}")" || die "no disk selected"
    fi
    [[ -b $DISK ]] || { ui_error "Not a block device: ${DISK:-<empty>}"; continue; }
    [[ $(disk_type "$DISK") == disk ]] || { ui_error "$DISK is not a whole disk."; continue; }
    break
  done
fi

# SMART health hint before any wipe (non-fatal if smartmontools/smartctl absent).
if command -v smartctl >/dev/null 2>&1; then
  _smart="$(smartctl -H "$DISK" 2>/dev/null | grep -i 'result' | head -1 || true)"
  if [[ -n $_smart ]]; then
    ui_info "SMART health for $DISK:
$_smart

Full report later: smartctl -a $DISK"
  fi
  unset -v _smart
else
  warn "smartctl not on ISO — pacstrap will not include it unless you add smartmontools"
fi

# ── 2. partition strategy ───────────────────────────────────
ui_step 5 Partition
if (( NONINTERACTIVE )); then
  [[ ${MODE:-} == auto || ${MODE:-} == manual ]] \
    || die "NONINTERACTIVE needs MODE=auto|manual in answers"
else
  _mode_auto=on; _mode_man=off
  [[ ${MODE:-auto} == manual ]] && { _mode_auto=off; _mode_man=on; }
  MODE="$(ui_radio "How should $DISK be partitioned?" \
    auto "wipe ALL of $DISK: EFI + LUKS root" "$_mode_auto" \
    manual "select existing partitions (EFI format or reuse)" "$_mode_man")" \
    || die "aborted"
  unset -v _mode_auto _mode_man
fi

require_ni_erase() {
  (( WILL_ERASE == 1 )) \
    || die "NONINTERACTIVE destructive install needs T14S_I_WILL_ERASE=1 (or y/yes/on)"
}

if [[ $MODE == auto ]]; then
  FORMAT_EFI=1
  while :; do
    if (( NONINTERACTIVE )); then
      [[ ${ESP_MB:-} =~ ^(1024|2048|4096)$ ]] \
        || die "NONINTERACTIVE AUTO needs ESP_MB=1024|2048|4096 in answers"
    else
      _e2=off; _e1=off; _e4=off
      case ${ESP_MB:-2048} in
        1024) _e1=on ;;
        4096) _e4=on ;;
        *) _e2=on; ESP_MB=2048 ;;
      esac
      ESP_MB="$(ui_radio "EFI system partition size on $DISK" \
        2048 "2G — recommended for dual UKIs" "$_e2" \
        1024 "1G — minimum comfortable" "$_e1" \
        4096 "4G — extra multiboot headroom" "$_e4")" || die "aborted"
      unset -v _e2 _e1 _e4
    fi
    disk_mb="$(size_mb "$DISK")"
    (( disk_mb > ESP_MB + 8192 )) && break
    if (( NONINTERACTIVE )); then
      die "Disk is only ${disk_mb}MB — ESP_MB=${ESP_MB} will not fit with 8GB root"
    fi
    ui_error "Disk is only ${disk_mb}MB — ${ESP_MB}MB ESP plus an 8GB root will not fit.
Pick a smaller ESP."
    ESP_MB=""
  done

  if (( NONINTERACTIVE )); then
    require_ni_erase
    warn "NONINTERACTIVE AUTO: will erase entire $DISK (ESP ${ESP_MB}MB + LUKS root)"
  else
    ui_critical "AUTO mode ERASES the ENTIRE disk:

$DISK

Plan: GPT · ${ESP_MB}MB ESP (FAT32) · remainder LUKS2 + Btrfs

That includes any Windows / other-OS partitions on it.

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null)"
    CONF="$(ui_input "Type the disk path to confirm total wipe" "")" || die "aborted"
    [[ $CONF == "$DISK" ]] || die "disk confirmation mismatch — aborting"
    ui_yesno "ERASE $DISK now?" no erase || die "aborted"
  fi
  # names only; the destructive writes run in the execute phase
  EFI_PART="$(part_of "$DISK" 1)"
  ROOT_PART="$(part_of "$DISK" 2)"
else
  # MANUAL: honor EFI_PART/ROOT_PART/FORMAT_EFI from answers under NONINTERACTIVE.
  if (( NONINTERACTIVE )); then
    [[ -n ${EFI_PART:-} && -n ${ROOT_PART:-} && -b ${EFI_PART:-/dev/null} && -b ${ROOT_PART:-/dev/null} ]] \
      || die "NONINTERACTIVE MANUAL needs EFI_PART and ROOT_PART block devices in answers"
    require_ni_erase
    [[ $EFI_PART != "$ROOT_PART" ]] || die "EFI_PART and ROOT_PART must differ"
    part_on_disk "$EFI_PART" "$DISK" \
      || die "EFI_PART $EFI_PART is not on DISK $DISK"
    part_on_disk "$ROOT_PART" "$DISK" \
      || die "ROOT_PART $ROOT_PART is not on DISK $DISK"
    [[ ${FORMAT_EFI:-1} =~ ^[01]$ ]] || FORMAT_EFI=1
    efifs="$(part_fs "$EFI_PART")"
    if (( FORMAT_EFI == 0 )) && [[ $efifs != vfat ]]; then
      die "FORMAT_EFI=0 but $EFI_PART is '${efifs:-empty}', not FAT32"
    fi
    efi_mb="$(size_mb "$EFI_PART")"
    root_mb="$(size_mb "$ROOT_PART")"
    if (( efi_mb < 512 )); then
      die "ESP $EFI_PART is only ${efi_mb}MB (need ≥512; enlarge or pick another)"
    fi
    if (( root_mb < 8192 )); then
      die "ROOT $ROOT_PART is only ${root_mb}MB (need ≥8192)"
    fi
    ok "MANUAL partitions from answers: EFI=$EFI_PART ROOT=$ROOT_PART format_efi=$FORMAT_EFI"
  else
    ui_info "Manual partitioning on $DISK.

Current layout (select from lists; sizes and existing filesystems shown):

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null)"

    ROOT_PART="$(pick_part "Select ROOT — ERASED, becomes LUKS2 + Btrfs" "$DISK")" \
      || die "aborted"
    while :; do
      _ef_reuse=on; _ef_fmt=off
      [[ ${FORMAT_EFI:-1} == 0 ]] || { _ef_reuse=off; _ef_fmt=on; }
      EFIMODE="$(ui_radio "EFI handling for $ROOT_PART" \
        reuse "keep an existing FAT32 ESP (multiboot-safe)" "$_ef_reuse" \
        format "format a partition as ESP (destroys its contents)" "$_ef_fmt")" || die "aborted"
      unset -v _ef_reuse _ef_fmt
      if [[ $EFIMODE == reuse ]]; then FORMAT_EFI=0; else FORMAT_EFI=1; fi

      if (( FORMAT_EFI == 0 )) && ! lsblk -prno FSTYPE "$DISK" 2>/dev/null | grep -qx vfat; then
        ui_warn "No FAT32 ESP exists on $DISK. Pick format mode instead (or cancel to abort)."
        continue
      fi

      if (( FORMAT_EFI == 0 )); then
        EFI_PART="$(pick_part "Select the existing ESP (must be FAT32)" "$DISK" any "$ROOT_PART")" \
          || die "aborted"
      else
        EFI_PART="$(pick_part "Select the partition to FORMAT as ESP" "$DISK" any "$ROOT_PART")" \
          || die "aborted"
      fi
      [[ $EFI_PART != "$ROOT_PART" ]] || { ui_error "EFI and ROOT cannot be the same partition."; continue; }

      efifs="$(part_fs "$EFI_PART")"
      if (( FORMAT_EFI == 0 )) && [[ $efifs != vfat ]]; then
        ui_error "$EFI_PART is '${efifs:-empty}', not FAT32 — reuse needs an existing ESP.
Pick format mode or another partition."
        continue
      fi
      efi_mb="$(size_mb "$EFI_PART")"
      if (( efi_mb < 512 )); then
        ui_yesno "ESP $EFI_PART is only ${efi_mb}MB. Dual UKIs will not fit.
Use it anyway?" no warn || continue
      elif (( efi_mb < 1024 )); then
        ui_warn "Note: ESP is ${efi_mb}MB — 1G+ is recommended for dual UKIs."
      fi
      break
    done

    root_mb="$(size_mb "$ROOT_PART")"
    if (( root_mb < 8192 )); then
      ui_yesno "ROOT $ROOT_PART is only ${root_mb}MB — 8G+ is recommended.
Use it anyway?" no warn || die "aborted"
    fi

    if (( FORMAT_EFI == 0 )); then
      _m="$(mktemp -d)"
      _esp_entries=""
      if mount -o ro "$EFI_PART" "$_m" 2>/dev/null; then
        _esp_entries="$(find "$_m/EFI" -maxdepth 1 -mindepth 1 2>/dev/null | sed 's,.*/,   ,' || true)"
        umount "$_m" || true
      fi
      rmdir "$_m" 2>/dev/null || true
      ui_info "Reusing ESP $EFI_PART (FAT, kept).

Existing /EFI entries (other OSes stay bootable):
${_esp_entries:-   (none)}"
    elif [[ $efifs == vfat ]]; then
      ui_critical "DANGER: $EFI_PART is ALREADY FAT — likely a shared ESP.
Formatting ERASES other OSes' bootloaders."
    fi

    # Precompute sizes/labels so the prompt has no nested quotes (smoke parses it).
    _proc_root_mb="$(size_mb "$ROOT_PART")"
    _proc_efi_lbl=$([[ $FORMAT_EFI == 1 ]] && echo FORMATTED || echo REUSED)
    ui_yesno "Proceed with these partitions?

  ROOT  $ROOT_PART  ${_proc_root_mb}MB  ERASED → LUKS2
  EFI   $EFI_PART  ${efi_mb}MB  ${_proc_efi_lbl}" no erase \
      || die "aborted"
    unset -v _proc_root_mb _proc_efi_lbl
  fi
fi
ok "EFI=$EFI_PART  ROOT=$ROOT_PART  (format_efi=$FORMAT_EFI)"

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

# ── 4. identity (validated before wipe / LUKS at step 11) ───
ui_step 7 Identity
if (( NONINTERACTIVE )); then
  [[ -n ${HOSTNAME:-} ]] || die "NONINTERACTIVE needs HOSTNAME in answers"
  valid_hostname "$HOSTNAME" || die "invalid hostname (DNS labels only): ${HOSTNAME}"
else
  while :; do
    HOSTNAME="$(ui_input "Hostname" "${HOSTNAME:-thinkpad-t14s}")" || die "aborted"
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

ui_step 8 Downloads
if (( NONINTERACTIVE )); then
  [[ $PACMAN_PARALLEL =~ ^(5|10|15)$ ]] \
    || die "NONINTERACTIVE needs PACMAN_PARALLEL=5|10|15"
  [[ $BTRFS_COMPRESS =~ ^(zstd1|zstd3|zstd15|none)$ ]] \
    || die "NONINTERACTIVE needs BTRFS_COMPRESS=zstd1|zstd3|zstd15|none"
  [[ $ZRAM_SIZE =~ ^(half|quarter|8192)$ ]] \
    || die "NONINTERACTIVE needs ZRAM_SIZE=half|quarter|8192"
else
  _p5=off; _p10=on; _p15=off
  case $PACMAN_PARALLEL in 5) _p5=on; _p10=off ;; 15) _p15=on; _p10=off ;; esac
  PACMAN_PARALLEL="$(ui_radio "pacman ParallelDownloads (live + target)" \
    5 "conservative (slow / flaky links)" "$_p5" \
    10 "balanced (default)" "$_p10" \
    15 "aggressive (fast links)" "$_p15")" || die "aborted"
  unset -v _p5 _p10 _p15

  _bc3=on; _bc1=off; _bc15=off; _bc0=off
  case $BTRFS_COMPRESS in
    zstd1) _bc1=on; _bc3=off ;;
    zstd15) _bc15=on; _bc3=off ;;
    none) _bc0=on; _bc3=off ;;
    *) BTRFS_COMPRESS=zstd3 ;;
  esac
  BTRFS_COMPRESS="$(ui_radio "Btrfs compression (mount options)" \
    zstd3 "zstd:3 — default balance" "$_bc3" \
    zstd1 "zstd:1 — faster, larger" "$_bc1" \
    zstd15 "zstd:15 — smaller, slower" "$_bc15" \
    none "no compression" "$_bc0")" || die "aborted"
  unset -v _bc3 _bc1 _bc15 _bc0

  _zh=on; _zq=off; _z8=off
  case $ZRAM_SIZE in
    quarter) _zq=on; _zh=off ;;
    8192) _z8=on; _zh=off ;;
    *) ZRAM_SIZE=half ;;
  esac
  ZRAM_SIZE="$(ui_radio "zram size" \
    half "min(RAM/2, 16G) — default" "$_zh" \
    quarter "min(RAM/4, 8G)" "$_zq" \
    8192 "fixed 8G" "$_z8")" || die "aborted"
  unset -v _zh _zq _z8
fi
[[ $PACMAN_PARALLEL =~ ^(5|10|15)$ ]] || PACMAN_PARALLEL=10
[[ $BTRFS_COMPRESS =~ ^(zstd1|zstd3|zstd15|none)$ ]] || BTRFS_COMPRESS=zstd3
[[ $ZRAM_SIZE =~ ^(half|quarter|8192)$ ]] || ZRAM_SIZE=half

# Split checklists (Core / Tools / Network). Defaults from preset + answers.
flag_from_opts() {
  local opts=$1 tag=$2
  printf '%s\n' "$opts" | grep -qx "$tag"
}

ui_step 9 Extras
if (( NONINTERACTIVE )); then
  # Keep EXTRA_PKGS already filled from EXTRA_PKGS_LIST (answers replay).
  :
else
  OPTS_CORE="$(ui_checklist "Core extras — Space toggles, Enter = Next" \
    gnome "Minimal GNOME desktop + Flatpak browsers/VPN" "$(def_onoff "$DESKTOP")" \
    nerd_fonts "Nerd Fonts + Inter/Noto" "$(def_onoff "$INSTALL_NERD_FONTS")" \
    sbctl "Enroll Secure Boot keys now (Setup Mode)" "$(def_onoff "$ENROLL_SB")" \
    sshd "Enable SSH server (sshd) after install" "$(def_onoff "$ENABLE_SSHD")" \
    cups "CUPS printing (cups + cups-pdf + ghostscript)" "$(def_onoff "$INSTALL_CUPS")" \
    skip_reflector "Skip live reflector; keep ISO mirrorlist" "$(def_onoff "$SKIP_REFLECTOR")" \
    tlp "TLP power mgmt (console-only; skipped if GNOME)" "$(def_onoff "$INSTALL_TLP")" \
    thinkfan "Write thinkfan AUR note (not in official repos)" "$(def_onoff "$INSTALL_THINKFAN")" \
    snapper_home "Snapper config for @home" "$(def_onoff "$INSTALL_SNAPPER_HOME")" \
    btrfs_assistant "btrfs-assistant (snapshot GUI; needs GNOME)" "$(def_onoff "$INSTALL_BTRFS_ASSISTANT")" \
    tuned "tuned + tuned-ppd + tuned-gui (replaces power-profiles-daemon)" "$(def_onoff "$INSTALL_TUNED")" \
    multilib "Enable [multilib] (32-bit: Steam, Wine)" "$(def_onoff "$INSTALL_MULTILIB")" \
    yay "yay AUR helper (yay-bin, built as your user)" "$(def_onoff "$INSTALL_YAY")" \
    linux_stable "Also install linux (stable) UKI" "$(def_onoff "$INSTALL_LINUX_STABLE")" \
    plymouth "Plymouth splash (optional)" "$(def_onoff "$INSTALL_PLYMOUTH")" \
    selftest "Write post-boot BT/audio self-test script" "$(def_onoff "$INSTALL_SELFTEST")" \
    clean_esp "Clean old Arch files from ESP (UKIs/entries/EFI/arch)" "$(def_onoff "$CLEAN_ESP_ARCH")" \
    chrome_hint "Write post-boot Chrome Flatpak helper script" "$(def_onoff "$INSTALL_CHROME_HINT")")" \
    || die "aborted"

  OPTS_TOOLS="$(ui_checklist "Dev / CLI tools" \
    devtools "Dev toolchains: gcc/clang/gdb, python, node, go, rustup, gh, nvim, code" "$(def_onoff "$INSTALL_DEVTOOLS")" \
    cli "ripgrep fd fzf bat eza jq git-delta" "$(def_onoff "$INSTALL_CLI")" \
    starship "starship prompt (+ wire into user zsh)" "$(def_onoff "$INSTALL_STARSHIP")" \
    podman "podman + buildah (rootless)" "$(def_onoff "$INSTALL_PODMAN")" \
    docker "docker + docker-compose (heavier)" "$(def_onoff "$INSTALL_DOCKER")" \
    virt "libvirt + qemu-desktop + virt-manager" "$(def_onoff "$INSTALL_VIRT")" \
    htop "htop" off \
    tmux "tmux" off \
    rsync "rsync" off \
    bash_completion "bash-completion" off \
    wget "wget" off \
    usbutils "usbutils" off \
    lsof "lsof" off \
    dmidecode "dmidecode" off \
    powertop "powertop" off \
    mc "mc (midnight commander)" off \
    traceroute "traceroute" off \
    bind "bind (dig/nslookup)" off \
    smartmontools "smartmontools (smartctl)" off)" || die "aborted"

  OPTS_NET="$(ui_checklist "Network / security extras" \
    avahi "avahi + nss-mdns (.local discovery)" "$(def_onoff "$INSTALL_AVAHI")" \
    wireguard "wireguard-tools" "$(def_onoff "$INSTALL_WIREGUARD")" \
    tailscale "tailscale" "$(def_onoff "$INSTALL_TAILSCALE")" \
    fail2ban "fail2ban (useful with sshd)" "$(def_onoff "$INSTALL_FAIL2BAN")" \
    ufw_syncthing "UFW allow Syncthing 22000/tcp+udp" "$(def_onoff "$UFW_SYNCTHING")" \
    ufw_kdeconnect "UFW allow KDE Connect 1714:1764/tcp+udp" "$(def_onoff "$UFW_KDECONNECT")")" \
    || die "aborted"

  DESKTOP=N; INSTALL_NERD_FONTS=N; ENROLL_SB=N; ENABLE_SSHD=N
  INSTALL_CUPS=N; SKIP_REFLECTOR=N; INSTALL_TLP=N; INSTALL_THINKFAN=N
  INSTALL_SNAPPER_HOME=N; INSTALL_LINUX_STABLE=N; INSTALL_PLYMOUTH=N
  INSTALL_SELFTEST=N; CLEAN_ESP_ARCH=N; INSTALL_CHROME_HINT=N
  INSTALL_MULTILIB=N; INSTALL_YAY=N; INSTALL_TUNED=N; INSTALL_DEVTOOLS=N
  INSTALL_BTRFS_ASSISTANT=N
  INSTALL_CLI=N; INSTALL_STARSHIP=N
  INSTALL_PODMAN=N; INSTALL_DOCKER=N; INSTALL_VIRT=N
  INSTALL_AVAHI=N; INSTALL_WIREGUARD=N; INSTALL_TAILSCALE=N
  INSTALL_FAIL2BAN=N; UFW_SYNCTHING=N; UFW_KDECONNECT=N
  # Preserve packages already loaded from EXTRA_PKGS_LIST (answers replay).
  _extras_keep=("${EXTRA_PKGS[@]}")
  EXTRA_PKGS=()

  flag_from_opts "$OPTS_CORE" gnome && DESKTOP=Y || true
  flag_from_opts "$OPTS_CORE" nerd_fonts && INSTALL_NERD_FONTS=Y || true
  flag_from_opts "$OPTS_CORE" sbctl && ENROLL_SB=Y || true
  flag_from_opts "$OPTS_CORE" sshd && ENABLE_SSHD=Y || true
  flag_from_opts "$OPTS_CORE" cups && INSTALL_CUPS=Y || true
  flag_from_opts "$OPTS_CORE" skip_reflector && SKIP_REFLECTOR=Y || true
  flag_from_opts "$OPTS_CORE" tlp && INSTALL_TLP=Y || true
  flag_from_opts "$OPTS_CORE" thinkfan && INSTALL_THINKFAN=Y || true
  flag_from_opts "$OPTS_CORE" snapper_home && INSTALL_SNAPPER_HOME=Y || true
  flag_from_opts "$OPTS_CORE" linux_stable && INSTALL_LINUX_STABLE=Y || true
  flag_from_opts "$OPTS_CORE" plymouth && INSTALL_PLYMOUTH=Y || true
  flag_from_opts "$OPTS_CORE" selftest && INSTALL_SELFTEST=Y || true
  flag_from_opts "$OPTS_CORE" clean_esp && CLEAN_ESP_ARCH=Y || true
  flag_from_opts "$OPTS_CORE" chrome_hint && INSTALL_CHROME_HINT=Y || true
  flag_from_opts "$OPTS_CORE" btrfs_assistant && INSTALL_BTRFS_ASSISTANT=Y || true
  flag_from_opts "$OPTS_CORE" tuned && INSTALL_TUNED=Y || true
  flag_from_opts "$OPTS_CORE" multilib && INSTALL_MULTILIB=Y || true
  flag_from_opts "$OPTS_CORE" yay && INSTALL_YAY=Y || true

  flag_from_opts "$OPTS_TOOLS" devtools && INSTALL_DEVTOOLS=Y || true
  flag_from_opts "$OPTS_TOOLS" cli && INSTALL_CLI=Y || true
  flag_from_opts "$OPTS_TOOLS" starship && INSTALL_STARSHIP=Y || true
  flag_from_opts "$OPTS_TOOLS" podman && INSTALL_PODMAN=Y || true
  flag_from_opts "$OPTS_TOOLS" docker && INSTALL_DOCKER=Y || true
  flag_from_opts "$OPTS_TOOLS" virt && INSTALL_VIRT=Y || true
  flag_from_opts "$OPTS_TOOLS" htop && EXTRA_PKGS+=(htop) || true
  flag_from_opts "$OPTS_TOOLS" tmux && EXTRA_PKGS+=(tmux) || true
  flag_from_opts "$OPTS_TOOLS" rsync && EXTRA_PKGS+=(rsync) || true
  flag_from_opts "$OPTS_TOOLS" bash_completion && EXTRA_PKGS+=(bash-completion) || true
  flag_from_opts "$OPTS_TOOLS" wget && EXTRA_PKGS+=(wget) || true
  flag_from_opts "$OPTS_TOOLS" usbutils && EXTRA_PKGS+=(usbutils) || true
  flag_from_opts "$OPTS_TOOLS" lsof && EXTRA_PKGS+=(lsof) || true
  flag_from_opts "$OPTS_TOOLS" dmidecode && EXTRA_PKGS+=(dmidecode) || true
  flag_from_opts "$OPTS_TOOLS" powertop && EXTRA_PKGS+=(powertop) || true
  flag_from_opts "$OPTS_TOOLS" mc && EXTRA_PKGS+=(mc) || true
  flag_from_opts "$OPTS_TOOLS" traceroute && EXTRA_PKGS+=(traceroute) || true
  flag_from_opts "$OPTS_TOOLS" bind && EXTRA_PKGS+=(bind) || true
  flag_from_opts "$OPTS_TOOLS" smartmontools && EXTRA_PKGS+=(smartmontools) || true

  flag_from_opts "$OPTS_NET" avahi && INSTALL_AVAHI=Y || true
  flag_from_opts "$OPTS_NET" wireguard && INSTALL_WIREGUARD=Y || true
  flag_from_opts "$OPTS_NET" tailscale && INSTALL_TAILSCALE=Y || true
  flag_from_opts "$OPTS_NET" fail2ban && INSTALL_FAIL2BAN=Y || true
  flag_from_opts "$OPTS_NET" ufw_syncthing && UFW_SYNCTHING=Y || true
  flag_from_opts "$OPTS_NET" ufw_kdeconnect && UFW_KDECONNECT=Y || true

  # Re-apply answers extras after checklist rebuild (dedupe later at pacstrap).
  if ((${#_extras_keep[@]})); then
    EXTRA_PKGS+=("${_extras_keep[@]}")
  fi
  unset -v _extras_keep

  if [[ $SKIP_REFLECTOR != Y ]]; then
    REFLECTOR_COUNTRY="$(ui_input "Reflector --country (ISO codes, comma-ok; empty=worldwide)" \
      "${REFLECTOR_COUNTRY:-}")" || die "aborted"
  else
    REFLECTOR_COUNTRY=
  fi

  # Hook preset: none / env default (T14S_DEFAULT_HOOK_URL) / custom URL.
  # Never hardcode a private repo URL (smoke forbids linking private trees).
  _hp_none=on; _hp_env=off; _hp_custom=off
  if [[ -n ${POST_HOOK_URL:-} ]]; then
    _hp_none=off; _hp_custom=on
  elif [[ -n ${T14S_DEFAULT_HOOK_URL:-} ]]; then
    _hp_none=off; _hp_env=on
  fi
  _hook_menu=(none "skip post-install hook" "$_hp_none")
  if [[ -n ${T14S_DEFAULT_HOOK_URL:-} ]]; then
    _hook_menu+=(env "use T14S_DEFAULT_HOOK_URL" "$_hp_env")
  fi
  _hook_menu+=(custom "type a HTTPS hook URL" "$_hp_custom")
  HOOK_PRESET="$(ui_radio "Post-install hook (curl|bash as root in new system)" \
    "${_hook_menu[@]}")" || die "aborted"
  unset -v _hp_none _hp_env _hp_custom _hook_menu
  case $HOOK_PRESET in
    env)
      POST_HOOK_URL=${T14S_DEFAULT_HOOK_URL:-}
      [[ -n $POST_HOOK_URL ]] || die "T14S_DEFAULT_HOOK_URL empty"
      ;;
    custom)
      POST_HOOK_URL="$(ui_input "Post-install hook URL (HTTPS; empty=skip)" \
        "${POST_HOOK_URL:-}")" || die "aborted"
      ;;
    *) POST_HOOK_URL= ;;
  esac
  unset -v HOOK_PRESET
fi

# TLP conflicts with GNOME power-profiles-daemon and with tuned — force off.
if yn_on "$DESKTOP" && yn_on "$INSTALL_TLP"; then
  warn "TLP skipped — GNOME uses power-profiles-daemon / tuned-ppd"
  INSTALL_TLP=N
fi
if yn_on "$INSTALL_TUNED" && yn_on "$INSTALL_TLP"; then
  warn "TLP skipped — tuned selected (tlp conflicts with tuned)"
  INSTALL_TLP=N
fi
# btrfs-assistant is a GUI (Qt) — only with the desktop.
if yn_on "$INSTALL_BTRFS_ASSISTANT" && ! yn_on "$DESKTOP"; then
  warn "btrfs-assistant skipped — no desktop (use snapper CLI)"
  INSTALL_BTRFS_ASSISTANT=N
fi
# Re-apply VM/ThinkPad skip after checklist (thinkfan may have been re-enabled).
if yn_on "$SKIP_THINKPAD_HW"; then
  INSTALL_THINKFAN=N
fi
# Fresh-format ESP already empty; CLEAN_ESP_ARCH is ignored (forced Y in answers).
if [[ ${FORMAT_EFI:-1} == 1 ]]; then
  CLEAN_ESP_ARCH=Y
elif ! yn_on "${CLEAN_ESP_ARCH:-Y}"; then
  warn "CLEAN_ESP_ARCH=N — keeping prior Arch UKIs/arch*.conf; kernels/ucode still removed (pacstrap). Boot menu may show dead entries until you delete them."
fi
# Reflector country sanitize (letters/comma/space only).
if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
  _rc_re='^[A-Za-z][A-Za-z ,]*$'
  if ! [[ $REFLECTOR_COUNTRY =~ $_rc_re ]]; then
    warn "ignoring invalid REFLECTOR_COUNTRY=$REFLECTOR_COUNTRY"
    REFLECTOR_COUNTRY=
  fi
  unset -v _rc_re
fi

# Optional free-form extras (archfi -cpl spirit). Env T14S_EXTRA_PKGS appends.
if (( ! NONINTERACTIVE )); then
  _extra_in="$(ui_input "More pacstrap packages (space-separated, empty=none)" \
    "${T14S_EXTRA_PKGS:-}")" || die "aborted"
else
  _extra_in=${T14S_EXTRA_PKGS:-}
fi
if [[ -n ${_extra_in// /} ]]; then
  read -r -a _pkgs <<<"$_extra_in"
  for _p in "${_pkgs[@]}"; do
    if [[ $_p =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]; then
      EXTRA_PKGS+=("$_p")
    else
      ui_warn "Skipping invalid package name: $_p"
    fi
  done
fi
unset -v _extra_in _p _pkgs
# Persist extras for answers replay (space-separated).
EXTRA_PKGS_LIST="${EXTRA_PKGS[*]:-}"

# Canonicalize boolean flags (answers may use on/1; chroot + saves want Y/N).
for _flag in DESKTOP INSTALL_NERD_FONTS ENROLL_SB ENABLE_SSHD INSTALL_CUPS \
  SKIP_REFLECTOR INSTALL_TLP INSTALL_CLI INSTALL_PODMAN INSTALL_DOCKER \
  INSTALL_VIRT INSTALL_AVAHI INSTALL_WIREGUARD INSTALL_TAILSCALE \
  INSTALL_STARSHIP INSTALL_CHROME_HINT INSTALL_FAIL2BAN INSTALL_THINKFAN \
  INSTALL_SNAPPER_HOME INSTALL_LINUX_STABLE INSTALL_PLYMOUTH INSTALL_SELFTEST \
  CLEAN_ESP_ARCH INSTALL_MULTILIB INSTALL_YAY INSTALL_TUNED INSTALL_DEVTOOLS INSTALL_BTRFS_ASSISTANT \
  UFW_SYNCTHING UFW_KDECONNECT SKIP_THINKPAD_HW
do
  [[ -v $_flag ]] || printf -v "$_flag" '%s' N
  yn_canon "$_flag"
done
unset -v _flag

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
  Reflector     $([[ $SKIP_REFLECTOR == Y ]] && echo skip || echo "refresh${REFLECTOR_COUNTRY:+ ($REFLECTOR_COUNTRY)}")
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

start_log
ui_step 11 Install

# ── 4b. write the partition table (AUTO only) ───────────────
if [[ $MODE == auto ]]; then
  step "partitioning $DISK (GPT: 2G ESP + LUKS)"
  sgdisk --zap-all "$DISK" >/dev/null
  sgdisk -n1:0:+"${ESP_MB}"M -t1:ef00 -c1:EFI "$DISK" >/dev/null
  sgdisk -n2:0:0     -t2:8309 -c2:cryptroot "$DISK" >/dev/null
  partprobe "$DISK"; udevadm settle 2>/dev/null || sleep 2
fi

# ── 5. encrypt + filesystems ────────────────────────────────
step "LUKS2 format (argon2id) on $ROOT_PART"
wipefs -a "$ROOT_PART" >/dev/null 2>&1 || true   # clear stale signatures (dirty/reused disk)
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode "$ROOT_PART" -
printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
unset -v LUKS_PASS
LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"   # LUKS header UUID (for rd.luks.name)
[[ -n $LUKS_UUID ]] || die "could not read LUKS UUID from $ROOT_PART"
ok "LUKS open as /dev/mapper/cryptroot (LUKS UUID=$LUKS_UUID)"

# Optional full-volume wipe before mkfs (archfi normal/fast).
# count_bytes = exact device size, so dd exits 0 on a complete wipe and any
# nonzero exit (EIO, short write) is a real failure, not end-of-device ENOSPC.
_luks_wipe() {
  local desc=$1; shift
  local rc=0 size
  size=$(blockdev --getsize64 /dev/mapper/cryptroot) || die "LUKS wipe: cannot read cryptroot size"
  set +e
  run_progress "$desc" "$@" iflag=count_bytes count="$size"
  rc=$?
  set -e
  (( rc == 0 )) || die "LUKS wipe failed (dd exit $rc)"
}
case $LUKS_WIPE in
  fast)
    _luks_wipe "wiping cryptroot (fast dd bs=64M)" \
      dd if=/dev/zero of=/dev/mapper/cryptroot bs=64M status=progress
    ;;
  normal)
    _luks_wipe "wiping cryptroot (dd)" \
      dd if=/dev/zero of=/dev/mapper/cryptroot status=progress
    ;;
esac
unset -f _luks_wipe

step "btrfs + subvolumes"
mkfs.btrfs -f -L archroot /dev/mapper/cryptroot >/dev/null
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @snapshots @var_log @var_cache @tmp; do btrfs subvolume create "/mnt/$sv" >/dev/null; done
chattr +C /mnt/@tmp 2>/dev/null || true   # nodatacow inheritance
umount /mnt

case ${BTRFS_COMPRESS:-zstd3} in
  zstd1) CO="noatime,compress=zstd:1,ssd,space_cache=v2" ;;
  zstd15) CO="noatime,compress=zstd:15,ssd,space_cache=v2" ;;
  none) CO="noatime,ssd,space_cache=v2" ;;
  *) CO="noatime,compress=zstd:3,ssd,space_cache=v2" ;;
esac
mount -o "$CO,subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/log,var/cache,tmp,boot}
mount -o "$CO,subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "$CO,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "$CO,subvol=@var_log"   /dev/mapper/cryptroot /mnt/var/log
mount -o "$CO,subvol=@var_cache" /dev/mapper/cryptroot /mnt/var/cache
mount -o "noatime,nodatacow,nosuid,nodev,subvol=@tmp" /dev/mapper/cryptroot /mnt/tmp
chmod 1777 /mnt/tmp

if [[ $FORMAT_EFI == 1 ]]; then
  step "format ESP $EFI_PART"
  wipefs -a "$EFI_PART" >/dev/null 2>&1 || true   # clear stale fs signatures that confuse blkid/mount
  mkfs.fat -F32 -n EFI "$EFI_PART"                 # show output — surface real errors
  sync
fi
udevadm settle 2>/dev/null || true
mount -t vfat "$EFI_PART" /mnt/boot                # explicit type: don't rely on auto-detect
esp_mb=$(df -Pm /mnt/boot | awk 'NR==2{print $2}'); esp_mb=${esp_mb:-0}
(( esp_mb >= 1024 )) || warn "ESP is ${esp_mb}MB — dual-kernel UKIs want >=1024MB; install may fill it"
# Drop leftover Arch boot files from a prior install (see CLEAN_ESP_ARCH).
# Always clears kernels/ucode so pacstrap won't hit 'conflicting files'.
step "cleaning prior Arch boot artifacts on ESP (CLEAN_ESP_ARCH=$CLEAN_ESP_ARCH)"
clean_esp_arch_files /mnt/boot
ok "filesystems mounted (ESP ${esp_mb}MB)"

# ── 6. base install ─────────────────────────────────────────
# Rembrandt target — always amd-ucode (non-AMD already confirmed at preflight).
UCODE=amd-ucode

# Reflector rates every candidate mirror by downloading its repo DB. Without
# --threads that loop is serial, so a handful of dead mirrors stall the install
# for minutes behind a blank screen. Bound it: few candidates, concurrent rating,
# short timeouts, hard overall deadline. Write to a temp file first so a killed or
# empty run never clobbers a usable mirrorlist.
ML_TMP="$(mktemp)"
_reflector_args=(--latest 10 --protocol https --sort rate
  --threads 5 --connection-timeout 3 --download-timeout 5 --save "$ML_TMP")
if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
  _reflector_args+=(--country "$REFLECTOR_COUNTRY")
fi
if [[ $SKIP_REFLECTOR == Y ]]; then
  ok "reflector skipped by operator — using ISO mirrorlist"
elif run_progress "refreshing live mirrors (best-effort, ≤45s)" \
     timeout 45 reflector "${_reflector_args[@]}" \
   && (( $(grep -c '^Server' "$ML_TMP") >= 3 )); then
  cat "$ML_TMP" > /etc/pacman.d/mirrorlist   # keep existing inode/perms (0644)
  ok "mirrorlist refreshed ($(grep -c '^Server' "$ML_TMP") mirrors)"
else
  warn "reflector skipped, timed out, or returned too few mirrors — keeping current mirrorlist"
fi
rm -f "$ML_TMP"
unset -v _reflector_args

# Live ISO pacman (pacstrap uses this file). Built-in downloader only:
# XferCommand makes pacman fetch one file at a time and ignore ParallelDownloads
# (old runs of this script added a curl XferCommand — drop it on re-runs).
# DisableDownloadTimeout keeps slow mirrors from aborting ("Operation too slow").
# Single pacstrap — no retry loop, which would re-run on a partially-populated
# root and hit 'conflicting files'.
pacman_tune /etc/pacman.conf "$PACMAN_PARALLEL"

BASE_PKGS=(
  base base-devel
  linux-lts linux-lts-headers linux-hardened linux-hardened-headers
  linux-firmware "$UCODE"
  btrfs-progs cryptsetup
  bluez bluez-utils
  networkmanager sudo zsh git vim nano
  reflector pacman-contrib
  mkinitcpio snapper snap-pac zram-generator
  apparmor ufw sbctl efibootmgr
  wireless-regdb
  xdg-user-dirs
)
if yn_on "${INSTALL_LINUX_STABLE:-N}"; then
  BASE_PKGS+=(linux linux-headers)
fi
if yn_on "${INSTALL_PLYMOUTH:-N}"; then
  BASE_PKGS+=(plymouth)
fi
# Deduplicate extras already in the fixed base set.
if ((${#EXTRA_PKGS[@]})); then
  _seen=' '
  for _p in "${BASE_PKGS[@]}"; do _seen+="$_p "; done
  _extra_clean=()
  for _p in "${EXTRA_PKGS[@]}"; do
    [[ $_seen == *" $_p "* ]] && continue
    _extra_clean+=("$_p")
    _seen+="$_p "
  done
  EXTRA_PKGS=("${_extra_clean[@]}")
  unset -v _seen _extra_clean _p
fi
run_gauge "pacstrap base system ($UCODE) — downloading/installing packages" 0 100 \
  pacstrap -K /mnt "${BASE_PKGS[@]}" ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"}

step "genfstab"
genfstab -U /mnt >> /mnt/etc/fstab
# add nofail to the /tmp line (failure must not block boot)
sed -i -E '/[[:space:]]\/tmp[[:space:]]+btrfs/ s/(subvol=\/?@tmp)/\1,nofail/' /mnt/etc/fstab || true
# ESP root-only: systemd-boot refuses a world-readable random-seed
# ("Mount point '/boot' … is world accessible, which is a security hole").
sed -i -E '/[[:space:]]\/boot[[:space:]]+vfat/ s/fmask=[0-7]+/fmask=0077/; /[[:space:]]\/boot[[:space:]]+vfat/ s/dmask=[0-7]+/dmask=0077/' /mnt/etc/fstab || true
ok "base installed"

# ── 7. chroot configuration ─────────────────────────────────
step "writing chroot config"
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
# Files written here must be world-readable (locale.conf, dconf, sysctl.d…).
umask 022
# "WARN: …" lines are also collected for the host finish screen.
WARN_FILE=/root/t14s-warnings.txt
say(){
  printf '\e[1;34m>>\e[0m %s\n' "$*"
  if [[ $* == WARN:* ]]; then printf '%s\n' "${*#WARN: }" >>"$WARN_FILE"; fi
  return 0
}
# Progress marker for the host gauge (progress_filter): stage <lo%> <hi%> <text>
stage(){ printf '@@STAGE %s %s %s\n' "$1" "$2" "$3"; }
yn_on() { local v=${1,,}; [[ $v == y || $v == yes || $v == on || $v == 1 ]]; }
# Optional package set: install or record pacman's own error (not just "failed").
# Usage: pkg_try "label" pkg…   → 0 on success, 1 after a WARN with the reason.
pkg_try() {
  local label=$1 out rc=0; shift
  out=$(mktemp)
  pacman -S --noconfirm --needed "$@" 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}
  # New packager keys can postdate the pacstrap keyring: refresh once, retry.
  # Match pacman's error lines only — normal output always says "checking keys
  # in keyring". Keyring sync is followed by -Su (never a bare -Sy install).
  if (( rc != 0 )) && grep -qiE '^error:.*(signature|PGP|keyring|key "[^"]+")' "$out"; then
    say "$label: pacman key/signature error — refreshing archlinux-keyring, retrying once"
    rc=0
    { pacman -Sy --noconfirm --needed archlinux-keyring \
        && pacman -Su --noconfirm \
        && pacman -S --noconfirm --needed "$@"; } 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}
  fi
  if (( rc != 0 )); then
    say "WARN: $label install failed (pacman exit $rc): $(grep -m1 -E '^error:' "$out" || tail -n1 "$out")"
  fi
  rm -f "$out"
  return "$rc"
}
# Shared host helpers (pacman_tune) — written by the installer before arch-chroot.
# shellcheck disable=SC1091
source /root/t14s-lib.sh

stage 0 4 "locale, time, hostname, pacman"
# time / locale / keymap
if [[ $TIMEZONE == UTC ]]; then
  ln -sf /usr/share/zoneinfo/UTC /etc/localtime
else
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
fi
hwclock --systohc
# Escape BRE metacharacters so en_US.UTF-8 dots are literal in sed.
_loc_esc=$(printf '%s\n' "$LOCALE" | sed 's/[.[\\*^$]/\\&/g')
sed -i "s/^#${_loc_esc} UTF-8/${LOCALE} UTF-8/" /etc/locale.gen
grep -qxF "${LOCALE} UTF-8" /etc/locale.gen \
  || echo "${LOCALE} UTF-8" >> /etc/locale.gen
unset -v _loc_esc
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname / hosts: FQDN first, then short label (Debian/Ubuntu convention).
echo "$HOSTNAME" > /etc/hostname
_host_short=${HOSTNAME%%.*}
if [[ $_host_short == "$HOSTNAME" ]]; then
  cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
else
  cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME} ${_host_short}
EOF
fi
unset -v _host_short

# pacman before the UKI stage: a multilib -Syu that upgrades a kernel then
# runs its mkinitcpio hook before our presets exist (no double UKI build).
# pacman: parallel built-in downloader, no download timeout abort, Color/
# ILoveCandy/VerbosePkgLists, optional [multilib] (same helper as the live ISO).
PACMAN_PARALLEL="${PACMAN_PARALLEL:-10}"
pacman_tune /etc/pacman.conf "$PACMAN_PARALLEL" "$(yn_on "${INSTALL_MULTILIB:-N}" && echo Y || echo N)"
if yn_on "${INSTALL_MULTILIB:-N}"; then
  # -Syu, never bare -Sy (partial upgrades); target is fresh so this is cheap.
  pacman -Syu --noconfirm || say "WARN: could not sync [multilib] database"
fi
# makepkg (yay / AUR builds): all cores, Zen 3+ x86-64-v3, no -debug split packages
# (Arch default OPTIONS with debug → !debug; zstd is already -T0 upstream).
mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/t14s.conf <<'EOF'
# Local/AUR builds: Zen 3+ Rembrandt (T14s Gen 3) is x86-64-v3 (AVX2/BMI2/FMA).
MAKEFLAGS="-j$(nproc)"
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
if [[ ${CFLAGS-} == *"-march=x86-64"* && ${CFLAGS-} != *"-march=x86-64-v"* ]]; then
  CFLAGS="${CFLAGS/-march=x86-64/-march=x86-64-v3}"
  CFLAGS="${CFLAGS/-mtune=generic /}"
fi
if [[ ${CXXFLAGS-} == *"-march=x86-64"* && ${CXXFLAGS-} != *"-march=x86-64-v"* ]]; then
  CXXFLAGS="${CXXFLAGS/-march=x86-64/-march=x86-64-v3}"
  CXXFLAGS="${CXXFLAGS/-mtune=generic /}"
fi
case "${RUSTFLAGS-} " in
  *" -C target-cpu="* | *" target-cpu="*) ;;
  *) RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }-C target-cpu=x86-64-v3" ;;
esac
GOAMD64="${GOAMD64:-v3}"
EOF
# Weekly cache trim (keeps 3 versions; pacman-contrib is in the base set).
systemctl enable paccache.timer

stage 4 6 "users and passwords"
# users — secrets from /root/.t14s-install-secrets (0600; shredded after chroot)
# shellcheck disable=SC1091
source /root/.t14s-install-secrets
echo "root:${ROOT_PASS}" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
unset -v USER_PASS ROOT_PASS
rm -f /root/.t14s-install-secrets
stage 6 8 "initramfs and kernel cmdline"
# initramfs (systemd + sd-encrypt for LUKS; optional plymouth)
_HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)'
if yn_on "${INSTALL_PLYMOUTH}"; then
  _HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt plymouth filesystems fsck)'
fi
sed -i "s/^HOOKS=.*/${_HOOKS}/" /etc/mkinitcpio.conf
unset -v _HOOKS
grep -Eq '^HOOKS=.*sd-encrypt' /etc/mkinitcpio.conf \
  || { echo "ERROR: mkinitcpio HOOKS missing sd-encrypt after sed" >&2; exit 1; }

# kernel cmdline (shared by UKIs)
mkdir -p /etc/kernel
# AMD Rembrandt: amd_iommu + amd_pstate (no intel_iommu / i915). BIOS Sleep =
# "Windows and Linux" pairs with mem_sleep_default=s2idle.
_cmdline="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3 mem_sleep_default=s2idle apparmor=1 security=apparmor amd_iommu=on amd_pstate=active"
if yn_on "${INSTALL_PLYMOUTH}"; then
  _cmdline+=" splash"
fi
printf '%s\n' "$_cmdline" > /etc/kernel/cmdline
unset -v _cmdline

# systemd sleep: enforce s2idle (matches mem_sleep_default=s2idle on Rembrandt).
mkdir -p /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/s2idle.conf <<'EOF'
[Sleep]
SuspendState=mem
MemorySleepMode=s2idle
HibernateMode=shutdown
EOF

# Charge window 70–80, touchpad s2idle wakeup disable, lid policy — skipped on VM / SKIP_THINKPAD_HW.
mkdir -p /etc/tmpfiles.d /usr/local/lib/thinkpad /etc/udev/rules.d /etc/systemd/logind.conf.d
if ! yn_on "${SKIP_THINKPAD_HW}"; then
cat > /etc/tmpfiles.d/thinkpad-charge-thresholds.conf <<'EOF'
# ThinkPad charge thresholds 70–80 (PPD host; no TLP).
# Best-effort at boot; see thinkpad-charge-thresholds.service if BAT* appears late.
w /sys/class/power_supply/BAT0/charge_control_start_threshold - - - - 70
w /sys/class/power_supply/BAT0/charge_control_end_threshold - - - - 80
EOF
cat > /etc/udev/rules.d/61-thinkpad-charge-limit.rules <<'EOF'
# UPower 1.90+ / GNOME Preserve Battery Health:
# 60-upower-battery.rules only imports CHARGE_LIMIT from hwdb if
# charge_control_start_threshold already exists when BAT0 is added (races
# thinkpad_acpi) and defaults to 75,80. Explicitly export CHARGE_LIMIT=70,80
# on BAT* so upowerd writes 70-80 instead of clobbering start_threshold to 0.
ACTION!="remove", SUBSYSTEM=="power_supply", KERNEL=="BAT*", ENV{CHARGE_LIMIT}="70,80"
EOF
cat > /etc/udev/rules.d/71-thinkpad-t14s-touchpad-wakeup.rules <<'EOF'
# ThinkPad T14s Gen 3 AMD (21CQ/21CR): disable I2C touchpad wakeup from s2idle.
# Prevents spurious wakeups when the lid flexes in transit (ArchWiki T14s Gen 3 AMD).
# Matches both Elan (i2c-ELAN0678:00) and Synaptics (i2c-SYNA8018:00) SKUs.
ACTION=="add|change", SUBSYSTEM=="i2c", KERNEL=="i2c-ELAN0678:*|i2c-SYNA8018:*", ATTR{power/wakeup}="disabled"
EOF
cat > /etc/systemd/logind.conf.d/thinkpad-lid.conf <<'EOF'
[Login]
# Battery / unknown: suspend on lid. On charger: stay awake (GNOME mirrors this).
HandleLidSwitch=suspend
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF
cat > /usr/local/lib/thinkpad/apply-charge-thresholds.sh <<'EOF'
#!/usr/bin/env bash
# Wait for thinkpad_acpi BAT* charge_control_*, then apply 70–80. Exit 0 if absent (VM).
set -euo pipefail
START=70 END=80
for _ in $(seq 1 60); do
  shopt -s nullglob
  found=(/sys/class/power_supply/BAT*/charge_control_end_threshold)
  shopt -u nullglob
  ((${#found[@]} > 0)) && break
  sleep 1
done
shopt -s nullglob
for bat in /sys/class/power_supply/BAT*; do
  [[ -d $bat ]] || continue
  if [[ -e $bat/charge_control_start_threshold ]]; then
    printf '%s\n' "$START" >"$bat/charge_control_start_threshold" || true
  fi
  if [[ -e $bat/charge_control_end_threshold ]]; then
    printf '%s\n' "$END" >"$bat/charge_control_end_threshold" || true
  fi
done
shopt -u nullglob
exit 0
EOF
chmod 755 /usr/local/lib/thinkpad/apply-charge-thresholds.sh
cat > /etc/systemd/system/thinkpad-charge-thresholds.service <<'EOF'
[Unit]
Description=ThinkPad battery charge thresholds (70-80)
Documentation=file:///usr/local/lib/thinkpad/apply-charge-thresholds.sh
After=multi-user.target
# Do not use ConditionPathExists*: BAT* may appear after early boot.

[Service]
Type=oneshot
ExecStart=/usr/local/lib/thinkpad/apply-charge-thresholds.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable thinkpad-charge-thresholds.service
else
  say "SKIP_THINKPAD_HW — charge thresholds not installed"
fi

stage 8 24 "building unified kernel images"
# UKI presets: linux-lts (primary) + linux-hardened (fallback)
# Re-clean Arch EFI artifacts before rebuild (host already cleaned /mnt/boot).
if yn_on "${CLEAN_ESP_ARCH}"; then
  say "CLEAN_ESP_ARCH — removing old Arch UKIs / loader entries / EFI/arch"
fi
# Do NOT touch /boot/vmlinuz-* or *-ucode.img here: pacstrap just installed
# them and mkinitcpio -P below reads ALL_kver from vmlinuz. Stale copies were
# already removed on the host before pacstrap (clean_esp_arch_files).
# Full UKI / loader-entry clean only when CLEAN_ESP_ARCH=Y.
# (Function inlined — chroot has no host helpers.)
if yn_on "${CLEAN_ESP_ARCH}"; then
  rm -f /boot/EFI/Linux/arch-linux*.efi /boot/EFI/Linux/arch*.efi 2>/dev/null || true
  if [[ -d /boot/loader/entries ]]; then
    find /boot/loader/entries -maxdepth 1 -type f \
      -name 'arch*.conf' -delete 2>/dev/null || true
  fi
  rm -rf /boot/EFI/arch /boot/EFI/Arch /boot/EFI/ARCH 2>/dev/null || true
fi
mkdir -p /boot/EFI/Linux
cat > /etc/mkinitcpio.d/linux-lts.preset <<EOF
# ALL_kver is REQUIRED — mkinitcpio reads the kernel version from this vmlinuz.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-lts.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-lts-fallback.efi"
fallback_options="-S autodetect"
EOF
cat > /etc/mkinitcpio.d/linux-hardened.preset <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-hardened"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-hardened.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-hardened-fallback.efi"
fallback_options="-S autodetect"
EOF
if yn_on "${INSTALL_LINUX_STABLE}"; then
  cat > /etc/mkinitcpio.d/linux.preset <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOF
fi
say "building UKIs"
mkinitcpio -P
# drop redundant non-UKI initramfs left by the pacstrap install hook — UKI-only
# presets won't regenerate them, so this frees ESP space permanently.
rm -f /boot/initramfs-linux-lts.img /boot/initramfs-linux-lts-fallback.img \
      /boot/initramfs-linux-hardened.img /boot/initramfs-linux-hardened-fallback.img \
      /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img
# ESP free-space gate after UKI build (dual UKIs need headroom for updates).
_esp_free_mb="$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')"
if [[ ${_esp_free_mb:-} =~ ^[0-9]+$ ]]; then
  if (( _esp_free_mb < 64 )); then
    echo "ERROR: ESP nearly full after UKI build (${_esp_free_mb}MB free). Enlarge ESP or drop linux-stable." >&2
    exit 1
  elif (( _esp_free_mb < 200 )); then
    say "WARN: ESP low after UKI build (${_esp_free_mb}MB free) — leave room for kernel updates"
  else
    say "ESP free after UKI build: ${_esp_free_mb}MB"
  fi
fi
unset -v _esp_free_mb

stage 24 27 "systemd-boot"
# bootloader — when reusing a shared/multiboot ESP, back up another OS's fallback
# loader first. On a freshly-formatted ESP there's nothing to preserve (no clutter).
say "systemd-boot"
if [[ ${FORMAT_EFI:-1} == 0 && -f /boot/EFI/BOOT/BOOTX64.EFI ]]; then
  cp -n /boot/EFI/BOOT/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI.pre-arch.bak 2>/dev/null || true
  say "backed up existing /EFI/BOOT/BOOTX64.EFI -> .pre-arch.bak"
fi
bootctl install
# inform: coexisting loaders systemd-boot will auto-detect (Windows, other Linux)
find /boot/EFI -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's,^,   loader dir: ,' || true
cat > /boot/loader/loader.conf <<EOF
default arch-linux-lts.efi
timeout 3
editor no
console-mode max
EOF

stage 27 30 "zram, sysctl, firewall, mirrors"
# zram size from wizard (half / quarter / fixed 8G)
case ${ZRAM_SIZE:-half} in
  quarter) _zram_expr='min(ram / 4, 8192)' ;;
  8192) _zram_expr='8192' ;;
  *) _zram_expr='min(ram / 2, 16384)' ;;
esac
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${_zram_expr}
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF
unset -v _zram_expr

# sysctl hardening
cat > /etc/sysctl.d/99-security.conf <<EOF
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 1
net.core.bpf_jit_harden = 2
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
vm.swappiness = 100
EOF
# userns: needed for Flatpak under linux-hardened; '-' = ignore on LTS (key absent)
echo '-kernel.unprivileged_userns_clone = 1' > /etc/sysctl.d/99-userns.conf

# firewall — set ENABLED=yes so it's active on first boot (rule-apply may warn in chroot)
ufw default deny incoming
ufw default allow outgoing
ufw --force enable >/dev/null 2>&1 || true
grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null || sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf 2>/dev/null || true

# reflector mirrors (weekly timer; rate-rating must not serialize on dead mirrors)
{
  printf '%s\n' '--latest 10' '--protocol https' '--sort rate' '--threads 5'
  printf '%s\n' '--connection-timeout 3' '--download-timeout 5'
  printf '%s\n' '--save /etc/pacman.d/mirrorlist'
  if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
    printf -- '--country %s\n' "$REFLECTOR_COUNTRY"
  fi
} > /etc/xdg/reflector/reflector.conf


stage 30 34 "services and snapshots"
# services
systemctl enable NetworkManager apparmor ufw bluetooth fstrim.timer reflector.timer \
                 systemd-tmpfiles-clean.timer

# snapper config for / (handle pre-existing @snapshots mount) — non-fatal
umount /.snapshots 2>/dev/null || true
rmdir  /.snapshots 2>/dev/null || true
if snapper --no-dbus -c root create-config /; then
  btrfs subvolume delete /.snapshots 2>/dev/null || true
  mkdir -p /.snapshots; mount -a || true; chmod 750 /.snapshots
  # Bounded retention (defaults keep 10 hourly + 10 daily + 10 monthly + 10
  # yearly); wheel may browse snapshots (btrfs-assistant, snapper list).
  snapper --no-dbus -c root set-config \
    TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=0 \
    TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=10 \
    ALLOW_GROUPS=wheel SYNC_ACL=yes \
    || say "WARN: snapper root set-config failed — default retention kept"
  systemctl enable snapper-timeline.timer snapper-cleanup.timer
else
  say "WARN: snapper create-config failed — skipping snapshots (configure post-boot)"
  mkdir -p /.snapshots; mount -a || true
fi
if yn_on "${INSTALL_SNAPPER_HOME}"; then
  say "snapper config for /home"
  if snapper --no-dbus -c home create-config /home; then
    snapper --no-dbus -c home set-config \
      TIMELINE_LIMIT_HOURLY=5 TIMELINE_LIMIT_DAILY=7 TIMELINE_LIMIT_WEEKLY=0 \
      TIMELINE_LIMIT_MONTHLY=0 TIMELINE_LIMIT_YEARLY=0 NUMBER_LIMIT=10 \
      ALLOW_GROUPS=wheel SYNC_ACL=yes \
      || say "WARN: snapper home set-config failed — default retention kept"
    say "snapper home config created"
  else
    say "WARN: snapper home create-config failed — configure post-boot"
  fi
fi

stage 34 72 "GNOME desktop, apps and Flatpaks"
# minimal GNOME (optional)
if yn_on "$DESKTOP"; then
  say "installing minimal GNOME + browsers + VPN + software center"
  # sof-firmware+alsa-ucm-conf: Rembrandt audio.
  # mesa+vulkan-radeon+fprintd: Radeon 680M (libva via mesa Provides). No Yoga / iio.
  # FP (D-Bus-activated — do NOT systemctl enable). Skip fprintd on VM.
  # browsers + proton-vpn: Flatpak. gnome-software: Flatpak software center.
  # Non-fatal: a network hiccup here must not abort an otherwise-bootable base system.
  _gnome_pkgs=(
    gnome-shell gnome-session gdm gnome-control-center gnome-keyring
    gnome-backgrounds nautilus gnome-console gnome-text-editor
    gnome-system-monitor gnome-calculator loupe evince gnome-disk-utility
    xdg-user-dirs-gtk xdg-desktop-portal xdg-desktop-portal-gnome polkit
    flatpak fwupd bolt pipewire pipewire-pulse wireplumber earlyoom
    rtkit evolution-data-server
    sof-firmware alsa-ucm-conf
    mesa vulkan-radeon libva-utils
    gnome-software
  )
  # rtkit: realtime for PipeWire + gnome-shell KMS thread.
  # evolution-data-server: gnome-shell CalendarServer (top-bar calendar).
  # Power profiles: tuned + tuned-ppd (provides/conflicts power-profiles-daemon;
  # GNOME's power menu talks to tuned-ppd; tuned ships tuned-gui) or plain PPD.
  if yn_on "${INSTALL_TUNED}"; then
    _gnome_pkgs+=(tuned tuned-ppd)
    _power_units=(tuned.service tuned-ppd.service)
  else
    _gnome_pkgs+=(power-profiles-daemon)
    _power_units=(power-profiles-daemon.service)
  fi
  if yn_on "${INSTALL_BTRFS_ASSISTANT}"; then
    _gnome_pkgs+=(btrfs-assistant)
  fi
  if ! yn_on "${SKIP_THINKPAD_HW}"; then
    _gnome_pkgs+=(fprintd)
  fi
  if pkg_try "GNOME desktop" "${_gnome_pkgs[@]}"
  then
    unset -v _gnome_pkgs
    systemctl enable gdm bolt.service earlyoom.service "${_power_units[@]}"
    mkdir -p /etc/gdm /etc/environment.d /etc/udev/rules.d /etc/systemd/system/gdm.service.d \
      /etc/dconf/db/gdm.d /etc/dconf/profile
    cat > /etc/gdm/custom.conf <<'EOF'
[daemon]
WaylandEnable=true
AutomaticLoginEnable=false
TimedLoginEnable=false

[security]
DisallowTCP=true

[xdmcp]
Enable=false
EOF
    printf '%s\n' 'user-db:user' 'system-db:gdm' 'file-db:/usr/share/gdm/greeter-dconf-defaults' \
      > /etc/dconf/profile/gdm
    # GDM greeter (not user session); compiled by the dconf update below.
    cat > /etc/dconf/db/gdm.d/00-login-screen <<'EOF'
[org/gnome/login-screen]
disable-user-list=true
banner-message-enable=false
enable-fingerprint-authentication=true
enable-smartcard-authentication=false

[org/gnome/desktop/session]
idle-delay=uint32 60

[org/gnome/desktop/interface]
clock-show-seconds=false
clock-show-date=true
clock-format='24h'
color-scheme='prefer-dark'
cursor-theme='Adwaita'
cursor-size=24
icon-theme='Adwaita'

[org/gnome/desktop/background]
picture-uri=''
picture-uri-dark=''
primary-color='#2b2e30'
secondary-color='#2b2e30'
color-shading-type='solid'
picture-options='none'

[org/gnome/desktop/screensaver]
picture-uri=''
primary-color='#2b2e30'
color-shading-type='solid'
picture-options='none'

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='blank'
sleep-inactive-battery-timeout=180

[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=false
screen-magnifier-enabled=false

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']
EOF
    # No fprintd on VM / SKIP_THINKPAD_HW: don't offer fingerprint at the greeter.
    if yn_on "${SKIP_THINKPAD_HW}"; then
      sed -i 's/^enable-fingerprint-authentication=true$/enable-fingerprint-authentication=false/' \
        /etc/dconf/db/gdm.d/00-login-screen
    fi
    cat > /etc/environment.d/99-wayland.conf <<'EOF'
# Wayland + VA-API defaults for GNOME Shell on AMD Radeon 680M (radeonsi)
OZONE_PLATFORM=wayland
MOZ_ENABLE_WAYLAND=1
MOZ_DBUS_REMOTE=1
QT_QPA_PLATFORM=wayland
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
SDL_VIDEODRIVER=wayland
CLUTTER_BACKEND=wayland
LIBVA_DRIVER_NAME=radeonsi
EOF
    cat > /etc/udev/rules.d/61-gdm-wayland.rules <<'EOF'
# AMD Radeon 680M Rembrandt (1002:1681) — keep GDM on Wayland
SUBSYSTEM=="drm", KERNEL=="card*", \
  ATTRS{vendor}=="0x1002", ATTRS{device}=="0x1681", \
  TAG+="seat", TAG+="uaccess", \
  ENV{GDM_DISABLE_WAYLAND}=""

SUBSYSTEM=="drm", KERNEL=="card*", \
  ATTRS{vendor}=="0x1002", \
  ENV{GDM_DISABLE_WAYLAND}=""
EOF
    cat > /etc/systemd/system/gdm.service.d/override.conf <<'EOF'
# /etc/systemd/system/gdm.service.d/override.conf

[Service]
Environment=GDK_BACKEND=wayland
Environment=CLUTTER_BACKEND=wayland
Environment=QT_QPA_PLATFORM=wayland
Environment=LIBVA_DRIVER_NAME=radeonsi
OOMScoreAdjust=-500
Restart=always
RestartSec=1s
EOF
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    # Flatpak apps install on FIRST BOOT, not here: their runtimes (two
    # freedesktop versions + GL/codecs/locale + GNOME) are pure download and
    # took ~11 min of the last install. A oneshot after network-online does
    # one transaction; on failure it retries every 5 min (stamp only on success).
    # Chrome (extra-data) still needs the user helper (bwrap userns).
    stage 58 72 "Flatpak first-boot service"
    mkdir -p /usr/local/sbin
    cat > /usr/local/sbin/t14s-flatpak-apps <<'FP'
#!/usr/bin/env bash
# First-boot Flatpak apps (written by t14s-arch-install). Log: journalctl -u t14s-flatpak-apps
set -uo pipefail
apps=(com.brave.Browser app.zen_browser.zen io.gitlab.librewolf-community com.protonvpn.www)
flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
if ! flatpak install --system -y --noninteractive flathub "${apps[@]}"; then
  for a in "${apps[@]}"; do
    flatpak info --system "$a" >/dev/null 2>&1 \
      || flatpak install --system -y --noninteractive flathub "$a" || echo "failed: $a"
  done
fi
for a in "${apps[@]}"; do
  flatpak info --system "$a" >/dev/null 2>&1 || { echo "missing $a — will retry next boot"; exit 1; }
done
mkdir -p /var/lib/t14s && touch /var/lib/t14s/flatpak-apps.done
FP
    chmod 755 /usr/local/sbin/t14s-flatpak-apps
    cat > /etc/systemd/system/t14s-flatpak-apps.service <<'FP'
[Unit]
Description=Install Flatpak apps (first boot, t14s-arch-install)
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/t14s/flatpak-apps.done
# First boot often has no saved Wi-Fi yet: keep retrying every 5 min
# (oneshot + Restart= needs systemd >= 244) until the user connects.
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/t14s-flatpak-apps
Restart=on-failure
RestartSec=5min
TimeoutStartSec=30min
Nice=10

[Install]
WantedBy=multi-user.target
FP
    # Explicit (NetworkManager's Also= enables it too) so network-online
    # really waits for NM on boot.
    systemctl enable NetworkManager-wait-online.service t14s-flatpak-apps.service
    # archdi-style X11/Wayland keymap from console KEYMAP.
    # Console map names ≠ XKB layout/variant; remap commons, else best-effort.
    XKB_LAYOUT='' XKB_VARIANT=''
    case $KEYMAP in
      us|de|fr|es|it|ru) XKB_LAYOUT=$KEYMAP ;;
      uk) XKB_LAYOUT=gb ;;
      jp106) XKB_LAYOUT=jp ;;
      pt-latin1) XKB_LAYOUT=pt ;;
      br-abnt2) XKB_LAYOUT=br; XKB_VARIANT=abnt2 ;;
      dvorak) XKB_LAYOUT=us; XKB_VARIANT=dvorak ;;
      colemak) XKB_LAYOUT=us; XKB_VARIANT=colemak ;;
      *)
        XKB_LAYOUT=${KEYMAP%%-*}
        [[ $KEYMAP == *-* ]] && XKB_VARIANT=${KEYMAP#*-}
        ;;
    esac
    [[ -n $XKB_LAYOUT ]] || XKB_LAYOUT=us
    write_xkb_conf() {
      mkdir -p /etc/X11/xorg.conf.d
      {
        printf '%s\n' 'Section "InputClass"'
        printf '%s\n' '        Identifier "system-keyboard"'
        printf '%s\n' '        MatchIsKeyboard "on"'
        printf '        Option "XkbLayout" "%s"\n' "$XKB_LAYOUT"
        [[ -n $XKB_VARIANT ]] \
          && printf '        Option "XkbVariant" "%s"\n' "$XKB_VARIANT"
        printf '%s\n' 'EndSection'
      } > /etc/X11/xorg.conf.d/00-keyboard.conf
    }
    if command -v localectl >/dev/null 2>&1 \
      && localectl set-x11-keymap "$XKB_LAYOUT" "" "$XKB_VARIANT" "" 2>/dev/null; then
      :
    else
      write_xkb_conf
      say "WARN: localectl set-x11-keymap failed or missing — wrote 00-keyboard.conf ($XKB_LAYOUT${XKB_VARIANT:+|$XKB_VARIANT})"
    fi
    unset -f write_xkb_conf
  else
    unset -v _gnome_pkgs
    say "WARN: GNOME install incomplete (network?) — base system is fine. Finish post-boot:"
    say "      pacman -S gnome-shell gdm && systemctl enable gdm"
  fi
fi

stage 72 78 "fonts and GNOME defaults"
# Curated Nerd Fonts + UI fonts (matches HelllGuest install-fonts.sh; not full group).
if yn_on "${INSTALL_NERD_FONTS}"; then
  say "installing Nerd Fonts + Inter/Noto"
  if pkg_try "Nerd Fonts" \
    ttf-jetbrains-mono-nerd ttf-meslo-nerd ttf-firacode-nerd \
    ttf-cascadia-mono-nerd ttf-cascadia-code-nerd ttf-hack-nerd \
    ttf-iosevka-nerd ttf-iosevkaterm-nerd ttf-victor-mono-nerd \
    ttf-ibmplex-mono-nerd ttf-sourcecodepro-nerd ttf-dejavu-nerd \
    otf-geist-mono-nerd otf-commit-mono-nerd \
    ttf-nerd-fonts-symbols-common \
    inter-font noto-fonts noto-fonts-emoji
  then
    fc-cache -f >/dev/null 2>&1 || true
  fi
fi

# GNOME dconf defaults (color-scheme; fonts only when Nerd Fonts installed).
if yn_on "$DESKTOP"; then
  say "applying GNOME dconf defaults for $USERNAME"
  sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.config/dconf"
  mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
  printf '%s\n' 'user-db:user' 'system-db:local' > /etc/dconf/profile/user
  cat > /etc/dconf/db/local.d/00-t14s <<'DCONF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/desktop/peripherals/touchpad]
tap-to-click=true
natural-scroll=true

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']
DCONF
  if yn_on "${INSTALL_NERD_FONTS}"; then
    cat >> /etc/dconf/db/local.d/00-t14s <<'DCONF'

[org/gnome/desktop/interface]
font-name='Inter 11'
document-font-name='Inter 11'
monospace-font-name='JetBrainsMono Nerd Font Mono 11'

[org/gnome/Console]
font='JetBrainsMono Nerd Font Mono 12'
DCONF
  fi
  dconf update || say "WARN: dconf update failed; GNOME/GDM dconf defaults not applied"
fi

stage 78 92 "optional packages"
# archdi print stack (optional)
if yn_on "${INSTALL_CUPS}"; then
  say "installing CUPS printing stack"
  if pkg_try "CUPS" cups cups-pdf ghostscript; then
    systemctl enable cups.service
  fi
fi

# CLI tools
if yn_on "${INSTALL_CLI}"; then
  say "installing CLI tools (ripgrep fd fzf bat eza jq git-delta)"
  pkg_try "CLI tools" ripgrep fd fzf bat eza jq git-delta || true
fi

# Starship
if yn_on "${INSTALL_STARSHIP}"; then
  say "installing starship"
  if pkg_try "starship" starship; then
    sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.config"
    sudo -u "$USERNAME" tee "/home/$USERNAME/.config/starship.toml" >/dev/null <<'S'
# t14s default — customize after first boot
add_newline = false
S
    if ! grep -q 'starship init zsh' "/home/$USERNAME/.zshrc" 2>/dev/null; then
      printf '%s\n' 'eval "$(starship init zsh)"' \
        | sudo -u "$USERNAME" tee -a "/home/$USERNAME/.zshrc" >/dev/null
    fi
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.config" "/home/$USERNAME/.zshrc"
  fi
fi

# Podman
if yn_on "${INSTALL_PODMAN}"; then
  say "installing podman + buildah"
  pkg_try "podman" podman buildah || true
fi

# Docker
if yn_on "${INSTALL_DOCKER}"; then
  say "installing docker"
  if pkg_try "docker" docker docker-compose; then
    systemctl enable docker.service
    usermod -aG docker "$USERNAME" || true
  fi
fi

# libvirt / qemu
if yn_on "${INSTALL_VIRT}"; then
  say "installing libvirt + qemu + virt-manager"
  if pkg_try "libvirt/qemu" libvirt qemu-desktop virt-manager edk2-ovmf dnsmasq; then
    systemctl enable libvirtd.service
    usermod -aG libvirt "$USERNAME" || true
  fi
fi

# tuned without GNOME (GNOME path installs tuned + tuned-ppd above).
if yn_on "${INSTALL_TUNED}" && ! yn_on "$DESKTOP"; then
  if pkg_try "tuned" tuned; then
    systemctl enable tuned.service
  fi
fi

# TLP (console-only — desktop path already cleared INSTALL_TLP)
if yn_on "${INSTALL_TLP}"; then
  say "installing TLP"
  if pkg_try "TLP" tlp tlp-rdw; then
    systemctl enable tlp.service
  fi
fi

# thinkfan is AUR-only — leave a post-boot note instead of a failing pacman -S.
if yn_on "${INSTALL_THINKFAN}"; then
  cat > /root/t14s-thinkfan.txt <<'TF'
thinkfan is not in official Arch repos (AUR). After first boot with an AUR helper:
  yay -S thinkfan
  # then configure /etc/thinkfan.conf for your T14s and:
  sudo systemctl enable --now thinkfan
TF
  say "wrote /root/t14s-thinkfan.txt (AUR install notes)"
fi

# Avahi / mDNS
if yn_on "${INSTALL_AVAHI}"; then
  say "installing avahi + nss-mdns"
  if pkg_try "avahi" avahi nss-mdns; then
    systemctl enable avahi-daemon.service
    # Ensure .local resolution (nss-mdns package may not patch hosts line alone).
    if [[ -f /etc/nsswitch.conf ]] \
      && ! grep -q 'mdns_minimal' /etc/nsswitch.conf; then
      sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
        /etc/nsswitch.conf \
        || say "WARN: could not patch nsswitch.conf for mdns_minimal"
    fi
  fi
fi

# WireGuard / Tailscale
if yn_on "${INSTALL_WIREGUARD}"; then
  pkg_try "wireguard-tools" wireguard-tools || true
fi
if yn_on "${INSTALL_TAILSCALE}"; then
  if pkg_try "tailscale" tailscale; then
    systemctl enable tailscaled.service
  fi
fi

# Developer tools (toolchains, debuggers, editors). rustup: run
# `rustup default stable` after first login (per-user toolchain).
if yn_on "${INSTALL_DEVTOOLS}"; then
  say "installing developer tools"
  _dev_pkgs=(
    git-lfs github-cli lazygit neovim
    python python-pip python-pipx nodejs npm go rustup
    cmake ninja meson clang lldb gdb valgrind perf strace ltrace
    shellcheck shfmt httpie man-db man-pages tealdeer
  )
  yn_on "$DESKTOP" && _dev_pkgs+=(code)
  pkg_try "developer tools" "${_dev_pkgs[@]}" || true
  unset -v _dev_pkgs
fi

# yay (AUR helper): build yay-bin as the new user, install with pacman -U as
# root — makepkg refuses root, and no sudoers NOPASSWD change is needed.
if yn_on "${INSTALL_YAY}"; then
  say "building yay (AUR yay-bin)"
  _yay_dir="/home/$USERNAME/.cache/t14s-yay"
  rm -rf "$_yay_dir"
  if pkg_try "yay build deps" git base-devel \
    && runuser -u "$USERNAME" -- mkdir -p "/home/$USERNAME/.cache" \
    && runuser -u "$USERNAME" -- git clone --depth 1 https://aur.archlinux.org/yay-bin.git "$_yay_dir" \
    && runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" \
         bash -c 'cd "$1" && makepkg --noconfirm --nocheck' _ "$_yay_dir"; then
    _yay_pkg=$(find "$_yay_dir" -maxdepth 1 -name 'yay-bin-[0-9]*.pkg.tar.*' ! -name '*.sig' | head -n1)
    if [[ -n $_yay_pkg ]] && pacman -U --noconfirm --needed "$_yay_pkg"; then
      say "yay installed ($(pacman -Q yay-bin 2>/dev/null || echo yay-bin))"
    else
      say "WARN: yay package build produced nothing installable — install post-boot from AUR yay-bin"
    fi
  else
    say "WARN: yay build failed — after first boot: git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si"
  fi
  rm -rf "$_yay_dir"
  unset -v _yay_dir _yay_pkg
fi

# UFW extras
if yn_on "${UFW_SYNCTHING}"; then
  ufw allow 22000/tcp comment 'syncthing' || true
  ufw allow 22000/udp comment 'syncthing' || true
fi
if yn_on "${UFW_KDECONNECT}"; then
  ufw allow 1714:1764/tcp comment 'kdeconnect' || true
  ufw allow 1714:1764/udp comment 'kdeconnect' || true
fi

stage 92 95 "helpers and self-test"
# Chrome Flatpak helper (post-boot — bwrap often fails in chroot)
if yn_on "${INSTALL_CHROME_HINT}"; then
  sudo -u "$USERNAME" tee "/home/$USERNAME/install-chrome-flatpak.sh" >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub com.google.Chrome
SH
  chmod 755 "/home/$USERNAME/install-chrome-flatpak.sh"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/install-chrome-flatpak.sh"
fi

# XDG user dirs after packages exist (GNOME pulls xdg-user-dirs; base may too).
if command -v xdg-user-dirs-update >/dev/null 2>&1; then
  sudo -u "$USERNAME" env HOME="/home/$USERNAME" xdg-user-dirs-update || true
fi

# Post-boot BT/audio self-test helper (optional).
if yn_on "${INSTALL_SELFTEST}"; then
  cat > /usr/local/bin/t14s-selftest <<'ST'
#!/usr/bin/env bash
# Quick Rembrandt laptop sanity after first boot.
set -euo pipefail
ok=0; bad=0
check() {
  local name=$1; shift
  if "$@"; then echo "OK  $name"; ok=$((ok+1)); else echo "FAIL $name"; bad=$((bad+1)); fi
}
check_pipewire() {
  systemctl --user is-active --quiet pipewire 2>/dev/null || pactl info >/dev/null 2>&1
}
check_wifi() {
  nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | grep -q ':wifi:connected' \
    || nmcli networking connectivity 2>/dev/null | grep -qi full
}
check_ufw() {
  ufw status 2>/dev/null | grep -qi 'Status: active'
}
check bluetooth systemctl is-active --quiet bluetooth
check pipewire check_pipewire
check wifi check_wifi
check apparmor systemctl is-active --quiet apparmor
check ufw check_ufw
check mem_sleep grep -q '\[s2idle\]' /sys/power/mem_sleep
if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver ]]; then
  check amd_pstate grep -q '^amd-pstate' /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
fi
if [[ -f /sys/class/power_supply/BAT0/charge_control_start_threshold ]]; then
  check bat_start grep -qx '70' /sys/class/power_supply/BAT0/charge_control_start_threshold
  check bat_end grep -qx '80' /sys/class/power_supply/BAT0/charge_control_end_threshold
fi
for _tp in /sys/bus/i2c/devices/i2c-ELAN0678:*/power/wakeup /sys/bus/i2c/devices/i2c-SYNA8018:*/power/wakeup; do
  if [[ -f $_tp ]]; then
    check touchpad_wakeup grep -qx 'disabled' "$_tp"
  fi
done
if [[ -d /etc/dconf/db/gdm.d ]]; then
  check gdm_dconf test -s /etc/dconf/db/gdm
fi
echo "t14s-selftest: $ok ok, $bad fail"
(( bad == 0 ))
ST
  chmod 755 /usr/local/bin/t14s-selftest
  say "wrote /usr/local/bin/t14s-selftest"
fi

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
  say "enabling OpenSSH (sshd + UFW 22/tcp)"
  if pkg_try "openssh" openssh; then
    systemctl enable sshd
    ufw allow 22/tcp comment 'ssh' || true
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
    systemctl enable fail2ban.service
  fi
fi
CHROOT

# Passwords via 0600 file (not arch-chroot env — visible in /proc/*/environ).
# umask 077 only in this subshell: a script-wide umask leaks into arch-chroot
# and leaves /etc/locale.conf, sysctl.d, dconf … at 0600 (LANG unset for users).
(
  umask 077
  {
    printf 'USERNAME=%q\n' "$USERNAME"
    printf 'USER_PASS=%q\n' "$USER_PASS"
    printf 'ROOT_PASS=%q\n' "$ROOT_PASS"
  } > /mnt/root/.t14s-install-secrets
)
chmod 600 /mnt/root/.t14s-install-secrets
unset -v USER_PASS ROOT_PASS

chmod +x /mnt/root/chroot-setup.sh
# Host helpers the chroot reuses (single source: no duplicated function bodies).
declare -f pacman_tune >/mnt/root/t14s-lib.sh
rm -f /mnt/root/t14s-warnings.txt
cleanup_chroot_secrets() {
  shred -u /mnt/root/chroot-setup.sh /mnt/root/.t14s-install-secrets 2>/dev/null \
    || rm -f /mnt/root/chroot-setup.sh /mnt/root/.t14s-install-secrets
  rm -f /mnt/root/t14s-lib.sh
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
    UFW_SYNCTHING="$UFW_SYNCTHING" UFW_KDECONNECT="$UFW_KDECONNECT" \
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

# Collected chroot warnings → finish screen + /root/t14s-post-install.txt.
INSTALL_WARNINGS=""
if [[ -s /mnt/root/t14s-warnings.txt ]]; then
  INSTALL_WARNINGS=$(sort -u /mnt/root/t14s-warnings.txt)
fi

# Persist answers + optional post-install hook (dotfiles bootstrap URL).
answers_save /mnt/root/t14s-answers.env || true
if [[ -n ${POST_HOOK_URL:-} ]]; then
  # Remote script runs as root in the new system — require explicit consent.
  _hook_ok=0
  if (( NONINTERACTIVE )); then
    if [[ ${T14S_POST_HOOK_I_UNDERSTAND:-0} == 1 ]]; then
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
    if run_progress "post-install hook" \
         env HOOK_URL="$POST_HOOK_URL" \
         bash -c 'set -o pipefail; curl -fsSL --proto "=https" --tlsv1.2 --max-time 120 "$HOOK_URL" | arch-chroot /mnt bash -s'
    then
      ok "post-install hook finished"
    else
      warn "post-install hook failed — re-run manually after boot"
    fi
  fi
  unset -v _hook_ok
fi

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
  SELFTEST_HINT="Self-test: /usr/local/bin/t14s-selftest (BT/audio/wifi/apparmor/ufw/s2idle/amd_pstate/BAT0/touchpad)"
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

POST_TXT="T14s install — next steps

  Reboot and remove the ISO:   reboot
  Boot menu: Arch Linux (LTS) default, Hardened as fallback.
  Answers file: /root/t14s-answers.env (T14S_ANSWERS=... to reuse)
  Passwords: use T14S_PASS_FILE for unattended (never stored in answers)
  Verify after boot: lscpu | grep -i ryzen
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
  Post-boot check: grep -E 'amd_iommu|amd_pstate' /proc/cmdline
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
