#!/usr/bin/env bash
# install.sh — interactive hardened Arch install for ThinkPad T14s Gen 3 AMD
#               (machine type 21CQ / 21CR; example MTM 21CRS1PU00)
#
# Target: Rembrandt-U (Ryzen 5/7 PRO 6650U/6850U), soldered LPDDR5, amdgpu,
#         Wi-Fi 6E, 57Wh, s2idle.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
#
# Stack: LUKS2(argon2id, persistent discards) + Btrfs + linux-lts/hardened UKIs +
#        systemd-boot + sbctl Secure Boot + minimal GNOME. AMD defaults: amd-ucode,
#        amd_iommu=on, amd_pstate=active. Hostname default: thinkpad-t14s.
#
# BIOS (F1): Secure Boot off for install; Sleep State = "Windows and Linux"
# (s2idle); enable AMD SVM + IOMMU. Re-enable Secure Boot after sbctl enroll.
#
# RUN FROM THE ARCH ISO (live environment), as root, UEFI mode, with internet.
# THIS ERASES DATA on the partitions you select.
#
# UI: full-screen dialog/whiptail TUI on /dev/tty. dialog is installed from the
# live repos if no backend exists; plain line prompts are the fallback.
set -euo pipefail

# ── core state (must exist before any helper runs) ──────────
c0=$'\e[0m'; cR=$'\e[1;31m'; cG=$'\e[1;32m'; cY=$'\e[1;33m'; cB=$'\e[1;34m'
cC=$'\e[1;36m'; cX=$'\e[1;33;41m'

HAVE_TTY=0
if { : >/dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi
# Plain-mode prompts must reach the operator even while stdout/stderr -> $LOG.
if (( HAVE_TTY )); then UI_OUT=/dev/tty; else UI_OUT=/dev/stderr; fi

DRYRUN=${T14S_DRYRUN:-0}
UI=${T14S_UI:-plain}
LOGGING=0
DIED=0
NOTICES=()
LOG="$(mktemp /tmp/t14s-install.XXXXXX.log)"

_tty() {
  if (( HAVE_TTY )); then printf '%s\n' "$*" >/dev/tty 2>/dev/null || true; fi
  return 0
}

# During the logged phase in TUI mode, never print raw text on the tty:
# it scribbles over the curses screen. Infobox/progressbox carry status;
# warnings are collected in NOTICES and shown on the final screen.
_emit() { # color tag fd message
  local m
  m=$(printf '%s%s%s %s' "$1" "$2" "$c0" "$4")
  if (( LOGGING )); then
    printf '%s\n' "$m"
    if [[ $UI == plain ]]; then _tty "$m"; fi
  else
    printf '%s\n' "$m" >&"$3"
  fi
  return 0
}
say()  { _emit "$cB" '>>' 1 "$*"; }
ok()   { _emit "$cG" ' ok' 1 "$*"; }
warn() { NOTICES+=("$*"); _emit "$cY" ' !!' 2 "$*"; }

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
# Bash pre-sets $HOSTNAME (= archiso on the ISO); the target name lives elsewhere.
TARGET_HOSTNAME=${TARGET_HOSTNAME:-}
SECRETS_FROM_FILE=0
APP_TITLE="T14s Arch Installer"
PRESET=gnome
POST_HOOK_URL=""
EXTRA_PKGS=()
EXTRA_PKGS_LIST=""
DIALOG_RC=""
DIALOG_RC_DIR=""
DIALOG_RC_INFO="" DIALOG_RC_WARN="" DIALOG_RC_ERROR="" DIALOG_RC_CRITICAL="" DIALOG_RC_OK=""
TUI_TITLE=""
TUI_NEWT=""
TUI_DIALOGRC=""
TUI_KEEP_STDIN=0

# Wizard progress (step in backtitle).
TUI_STEPS=11
TUI_STEP=0
TUI_STEP_NAME=""
TUI_HINT_MENU='[log] view install log · [help] tips · Esc/Abort quits'
TUI_HINT_RADIO='Arrows+Space select · Enter=Next · Esc=Abort · [log]/[help]'
TUI_HINT_CHECK='Space=toggle · Enter=Next · Esc=Abort · [log]/[help]'

# Screen geometry from the real tty (tput lies once stdout/stderr -> $LOG).
# Clamped so boxes never exceed the terminal.
ui_geometry() {
  local sz='' r='' c=''
  if (( HAVE_TTY )); then sz=$(stty size </dev/tty 2>/dev/null || true); fi
  read -r r c <<<"$sz" || true
  [[ $r =~ ^[0-9]+$ && $r -gt 0 ]] || r=24
  [[ $c =~ ^[0-9]+$ && $c -gt 0 ]] || c=80
  ROWS=$r COLS=$c
  H=$(( ROWS - 4 ));  (( H > 22 )) && H=22;  (( H < 10 )) && H=10
  (( H > ROWS - 1 )) && H=$(( ROWS - 1 ))
  W=$(( COLS - 6 ));  (( W > 84 )) && W=84;  (( W < 50 )) && W=50
  (( W > COLS - 2 )) && W=$(( COLS - 2 ))
  LH=$(( H - 8 ));    (( LH < 3 )) && LH=3
  MH=$(( H < 14 ? H : 14 ))
  # Prose fold width: dialog/whiptail eat ~2 cols of border + 2 of margin per side.
  FW=$(( W - 6 ));    (( FW > 76 )) && FW=76; (( FW < 30 )) && FW=30
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

ui_step() {
  TUI_STEP=${1:-0}
  TUI_STEP_NAME=${2:-}
  ui_geometry
}

# Fold prose for msg/confirm bodies.
# Callers that must keep trailing newlines: out=$(ui_fold "$t"; printf x); out=${out%x}
ui_fold() {
  if command -v fold >/dev/null 2>&1; then
    printf '%s' "$1" | fold -s -w "${FW:-72}"
  else
    printf '%s' "$1"
  fi
}

# Button labels by backend + role.
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
  return 0
}

# ── palette ─────────────────────────────────────────────────
# One palette, two renderers. Every severity is defined once in terms of:
#   screen (backdrop), body (window text), border, title, focus (active button /
#   selected item). Windows stay black except CRITICAL (yellow on red).
#   Background colours stick to the 8 the Linux console can render (no bright
#   backgrounds), so the ISO VGA console and modern terminals look the same.
#
#            screen          body         border         title          focus
#   base     cyan/blue       white/black  cyan/black     yellow/black   black/cyan
#   info     cyan/blue       white/black  cyan/black     cyan/black     black/cyan
#   warn     black/brown     white/black  yellow/black   yellow/black   black/brown
#   error    white/red       white/black  red/black      red/black      white/red
#   critical yellow/red      yellow/red   yellow/red     yellow/red     black/brown
#   ok       white/green     white/black  green/black    green/black    black/green
#
# newt colour names are: black red green brown blue magenta cyan lightgray gray
# brightred brightgreen yellow brightblue brightmagenta brightcyan white.
# ("brightyellow" does not exist — newt silently fell back to defaults.)
# whiptail draws <Button> as newt *compact* buttons. Verified under a pty:
# the FOCUSED one is painted with `button`, the unfocused one with `compactbutton`.
# So button = focus accent, compactbutton = idle gray (actbutton kept in sync).
# Severity strings are BASE + overrides: newt applies later entries last, and
# unspecified elements would otherwise revert to newt's stock blue theme.
NEWT_COLORS_BASE='
root=white,blue
roottext=brightcyan,blue
helpline=black,cyan
border=brightcyan,black
window=white,black
shadow=black,black
title=yellow,black
label=brightcyan,black
textbox=white,black
acttextbox=black,cyan
button=black,cyan
actbutton=black,cyan
compactbutton=black,lightgray
checkbox=white,black
actcheckbox=black,cyan
entry=black,lightgray
disentry=gray,black
listbox=white,black
actlistbox=black,cyan
sellistbox=black,lightgray
actsellistbox=black,cyan
emptyscale=black,lightgray
fullscale=black,cyan
'
NEWT_COLORS_INFO="$NEWT_COLORS_BASE"'
title=brightcyan,black
'
NEWT_COLORS_WARN="$NEWT_COLORS_BASE"'
root=black,brown
roottext=black,brown
helpline=black,brown
border=yellow,black
title=yellow,black
actbutton=black,brown
button=black,brown
'
NEWT_COLORS_ERROR="$NEWT_COLORS_BASE"'
root=white,red
roottext=white,red
helpline=white,red
border=brightred,black
title=brightred,black
actbutton=white,red
button=white,red
'
NEWT_COLORS_CRITICAL="$NEWT_COLORS_BASE"'
root=yellow,red
roottext=yellow,red
helpline=yellow,red
border=yellow,red
window=yellow,red
title=yellow,red
textbox=yellow,red
actbutton=black,brown
button=black,brown
'
NEWT_COLORS_OK="$NEWT_COLORS_BASE"'
root=white,green
roottext=white,green
helpline=white,green
border=brightgreen,black
title=brightgreen,black
actbutton=black,green
button=black,green
'

# dialogrc: (FG,BG,HIGHLIGHT). HIGHLIGHT brightens FG only.
_write_one_dialogrc() { # path screen body border title focus
  local path=$1 screen=$2 body=$3 border=$4 title=$5 focus=$6
  local idle='(BLACK,WHITE,OFF)' field='(BLACK,WHITE,OFF)'
  cat >"$path" <<EOF
# T14s installer theme (generated)
use_shadow = ON
use_colors = ON
screen_color = $screen
shadow_color = (BLACK,BLACK,ON)
dialog_color = $body
title_color = $title
border_color = $border
border2_color = $border
button_active_color = $focus
button_inactive_color = $idle
button_key_active_color = $focus
button_key_inactive_color = (RED,WHITE,OFF)
button_label_active_color = $focus
button_label_inactive_color = $idle
inputbox_color = $field
inputbox_border_color = $border
inputbox_border2_color = $border
searchbox_color = $body
searchbox_title_color = $title
searchbox_border_color = $border
searchbox_border2_color = $border
position_indicator_color = $title
menubox_color = $body
menubox_border_color = $border
menubox_border2_color = $border
item_color = $body
item_selected_color = $focus
tag_color = $title
tag_selected_color = $focus
tag_key_color = $title
tag_key_selected_color = $focus
check_color = $body
check_selected_color = $focus
uarrow_color = $border
darrow_color = $border
itemhelp_color = (BLACK,CYAN,OFF)
form_active_text_color = $focus
form_text_color = $body
form_item_readonly_color = $border
gauge_color = $focus
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
  #                    path                 screen              body                border              title               focus
  _write_one_dialogrc "$DIALOG_RC"          '(CYAN,BLUE,ON)'    '(WHITE,BLACK,ON)'  '(CYAN,BLACK,ON)'   '(YELLOW,BLACK,ON)' '(BLACK,CYAN,OFF)'
  _write_one_dialogrc "$DIALOG_RC_INFO"     '(CYAN,BLUE,ON)'    '(WHITE,BLACK,ON)'  '(CYAN,BLACK,ON)'   '(CYAN,BLACK,ON)'   '(BLACK,CYAN,OFF)'
  _write_one_dialogrc "$DIALOG_RC_WARN"     '(BLACK,YELLOW,OFF)' '(WHITE,BLACK,ON)' '(YELLOW,BLACK,ON)' '(YELLOW,BLACK,ON)' '(BLACK,YELLOW,OFF)'
  _write_one_dialogrc "$DIALOG_RC_ERROR"    '(WHITE,RED,ON)'    '(WHITE,BLACK,ON)'  '(RED,BLACK,ON)'    '(RED,BLACK,ON)'    '(WHITE,RED,ON)'
  _write_one_dialogrc "$DIALOG_RC_CRITICAL" '(YELLOW,RED,ON)'   '(YELLOW,RED,ON)'   '(YELLOW,RED,ON)'   '(YELLOW,RED,ON)'   '(BLACK,YELLOW,OFF)'
  _write_one_dialogrc "$DIALOG_RC_OK"       '(WHITE,GREEN,ON)'  '(WHITE,BLACK,ON)'  '(GREEN,BLACK,ON)'  '(GREEN,BLACK,ON)'  '(BLACK,GREEN,OFF)'
  export DIALOGRC="$DIALOG_RC"
  export NEWT_COLORS="$NEWT_COLORS_BASE"
}

cleanup_ui() {
  if [[ -n ${DIALOG_RC_DIR:-} && -d $DIALOG_RC_DIR ]]; then rm -rf -- "$DIALOG_RC_DIR"; fi
  if [[ -f ${LOG:-}.fail ]]; then rm -f -- "$LOG.fail"; fi
  if [[ -n ${LOG:-} && -f $LOG && ! -s $LOG ]]; then rm -f -- "$LOG"; fi
  return 0
}

# dialog/whiptail draw on stdout and return the result on stderr. fd3 carries
# the caller's stdout (the capture channel), so UI is pinned to /dev/tty and keys
# come from /dev/tty even when the script itself arrives on a pipe.
# dialog flags:
#   --cr-wrap      honour embedded newlines (default dialog reflows every message
#                  into one paragraph — review tables / lsblk output were mangled)
#   --no-collapse  keep column alignment (default collapses runs of spaces)
#   --insecure     echo '*' in passwordbox (whiptail does this already)
# TUI_KEEP_STDIN=1: leave stdin alone (required for --progressbox pipe feed).
tui() {
  local title=${TUI_TITLE:-$APP_TITLE} back drc newt
  back=$(ui_backtitle)
  drc=${TUI_DIALOGRC:-${DIALOG_RC:-${DIALOGRC:-}}}
  newt=${TUI_NEWT:-$NEWT_COLORS_BASE}
  case $UI in
    dialog)
      if [[ ${TUI_KEEP_STDIN:-0} == 1 ]]; then
        DIALOGRC="$drc" dialog --colors --cr-wrap --no-collapse --insecure \
          --backtitle "$back" --title "$title" "$@" 3>&1 1>/dev/tty 2>&3
      else
        DIALOGRC="$drc" dialog --colors --cr-wrap --no-collapse --insecure \
          --backtitle "$back" --title "$title" "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty
      fi
      ;;
    whiptail)
      if [[ ${TUI_KEEP_STDIN:-0} == 1 ]]; then
        NEWT_COLORS="$newt" whiptail --backtitle "$back" --title "$title" \
          "$@" 3>&1 1>/dev/tty 2>&3
      else
        NEWT_COLORS="$newt" whiptail --backtitle "$back" --title "$title" \
          "$@" 3>&1 1>/dev/tty 2>&3 </dev/tty
      fi
      ;;
    *) return 1 ;;
  esac
}

_lines() { local n; n=$(printf '%s\n' "$1" | wc -l); printf '%s' "$n"; }

# Height for a message body: MH floor, H ceiling, scales with line count.
# whiptail spends 2 more rows on chrome than dialog.
_chrome() { if [[ $UI == whiptail ]]; then printf 8; else printf 6; fi; }

msg_height() {
  local need=$(( $(_lines "$1") + $(_chrome) ))
  (( need < MH )) && need=$MH
  (( need > H )) && need=$H
  printf '%s' "$need"
}

# Long bodies must scroll instead of being cut off.
_scroll_flags() { # text
  # Only when the body overflows: whiptail's --scrolltext eats the right border.
  _scroll=()
  if (( $(_lines "$1") + $(_chrome) > H )); then
    case $UI in
      whiptail) _scroll=(--scrolltext) ;;
      dialog) _scroll=(--scrollbar) ;;
    esac
  fi
  return 0
}

die() { # message [exit-code]
  local msg=${1:-failed} rc=${2:-1} line
  (( rc == 0 )) && rc=1
  trap - ERR
  DIED=1
  line=$(printf '%sERR%s %s' "$cR" "$c0" "$msg")
  printf '%s\n' "$line" >&2
  if (( LOGGING )); then _tty "$line"; fi
  if [[ $UI != plain ]] && (( HAVE_TTY )); then
    ui_critical "$msg

Full log: $LOG" || true
    if (( LOGGING )); then
      { printf 'FAILED: %s\n\n--- last output ---\n' "$msg"
        tail -n 60 "$LOG" 2>/dev/null; } >"$LOG.fail"
      TUI_TITLE="Failure log — $APP_TITLE"
      TUI_NEWT="$NEWT_COLORS_ERROR"
      TUI_DIALOGRC="${DIALOG_RC_ERROR:-$DIALOG_RC}"
      _scroll=(); [[ $UI == whiptail ]] && _scroll=(--scrolltext)
      tui "${_scroll[@]}" --textbox "$LOG.fail" "$H" "$W" || true
      TUI_TITLE=""; TUI_NEWT=""; TUI_DIALOGRC=""
    fi
  fi
  printf 'full log: %s\n' "$LOG" >&2
  if (( LOGGING )); then _tty "full log: $LOG"; fi
  cleanup_ui
  exit "$rc"
}

# set -e inside a function exits WITHOUT running the top-level ERR trap (ERR is
# not inherited by functions). Catch that here so failures are never silent.
on_exit() {
  local rc=$1 line
  if (( rc != 0 && ! DIED )); then
    DIED=1
    trap - ERR
    line=$(printf '%sERR%s unexpected exit (rc=%s) — log: %s' "$cR" "$c0" "$rc" "$LOG")
    printf '%s\n' "$line" >&2
    if (( LOGGING )); then _tty "$line"; fi
    if [[ $UI != plain ]] && (( HAVE_TTY )); then
      ui_critical "Unexpected exit (rc=$rc).

Full log: $LOG" || true
    fi
  fi
  cleanup_ui
}
trap 'die "failed at line $LINENO: $BASH_COMMAND" $?' ERR
trap 'on_exit $?' EXIT
trap 'die "interrupted" 130' INT

# ── tty prompt primitives (plain fallback) ──────────────────
ask()        { local p=$1 d=${2:-} v=; read -r  -p "$p" v </dev/tty 2>"$UI_OUT" || true; printf '%s' "${v:-$d}"; }
ask_secret() { local p=$1 v=; read -rs -p "$p" v </dev/tty 2>"$UI_OUT" || true; printf '\n' >"$UI_OUT"; printf '%s' "$v"; }
plain_pause(){ read -rsn1 -p ' [enter] ' </dev/tty 2>"$UI_OUT" || true; printf '\n' >"$UI_OUT"; }

# ── semantic UI ─────────────────────────────────────────────
# Severity boxes: ui_info / ui_warn / ui_error / ui_critical / ui_ok.
# Severity is also a text badge (not colour-only).

ui_msg() {
  local sev=$1; shift
  local text=$* folded title badge plain_c body newt drc h show
  folded=$(ui_fold "$text"; printf x); folded=${folded%x}
  # dialog --colors needs literal \Z sequences (single-quoted).
  # Badge colour == that severity's title colour (palette table above).
  case $sev in
    info)
      title="Info — $APP_TITLE"; badge=INFO; plain_c=$cC
      body='\Zb\Z6[ INFO ]\Zn'
      newt=$NEWT_COLORS_INFO; drc=${DIALOG_RC_INFO:-$DIALOG_RC} ;;
    warn)
      title="Warning — $APP_TITLE"; badge=WARNING; plain_c=$cY
      body='\Zb\Z3[ WARNING ]\Zn'
      newt=$NEWT_COLORS_WARN; drc=${DIALOG_RC_WARN:-$DIALOG_RC} ;;
    error)
      title="Error — $APP_TITLE"; badge=ERROR; plain_c=$cR
      body='\Zb\Z1[ ERROR ]\Zn'
      newt=$NEWT_COLORS_ERROR; drc=${DIALOG_RC_ERROR:-$DIALOG_RC} ;;
    critical)
      # Window is yellow-on-red; reverse video gives a red-on-yellow badge.
      title="CRITICAL — $APP_TITLE"; badge=CRITICAL; plain_c=$cX
      body='\Zb\Zr[ CRITICAL ]\Zn'
      newt=$NEWT_COLORS_CRITICAL; drc=${DIALOG_RC_CRITICAL:-$DIALOG_RC} ;;
    ok)
      title="Success — $APP_TITLE"; badge=OK; plain_c=$cG
      body='\Zb\Z2[ OK ]\Zn'
      newt=$NEWT_COLORS_OK; drc=${DIALOG_RC_OK:-$DIALOG_RC} ;;
    *)
      title=$APP_TITLE; badge=NOTE; plain_c=$cB
      body='\Zb[ NOTE ]\Zn'
      newt=$NEWT_COLORS_BASE; drc=$DIALOG_RC ;;
  esac

  if [[ $UI == plain ]]; then
    printf '\n%s[ %s ]%s\n%s\n' "$plain_c" "$badge" "$c0" "$folded" >"$UI_OUT"
    plain_pause
    return 0
  fi

  if [[ $UI == whiptail ]]; then
    show=$(printf '[ %s ]\n\n%s' "$badge" "$folded")
  else
    show="$body"$'\n\n'"$folded"
  fi
  h=$(msg_height "$show")
  _scroll_flags "$show"

  TUI_TITLE=$title; TUI_NEWT=$newt; TUI_DIALOGRC=$drc
  _tui_btns msg
  tui "${_btns[@]}" "${_scroll[@]}" --msgbox "$show" "$h" "$W" || true
  TUI_TITLE=""; TUI_NEWT=""; TUI_DIALOGRC=""
  return 0
}

ui_info()     { ui_msg info "$@"; }
ui_warn()     { ui_msg warn "$@"; }
ui_error()    { ui_msg error "$@"; }
ui_critical() { ui_msg critical "$@"; }
ui_ok()       { ui_msg ok "$@"; }
ui_msgbox()   { ui_info "$@"; }

ui_view_log() {
  touch "$LOG" 2>/dev/null || true
  if [[ ! -s $LOG ]]; then
    ui_info "Install log is empty so far.

Path: $LOG"
    return 0
  fi
  if [[ $UI == plain ]]; then
    printf '\n── log: %s (q to quit less) ──\n' "$LOG" >"$UI_OUT"
    less -R "$LOG" </dev/tty >/dev/tty 2>/dev/null \
      || { tail -n 80 "$LOG" >"$UI_OUT"; plain_pause; }
    return 0
  fi
  TUI_TITLE="Install log — $APP_TITLE"
  _scroll=(); [[ $UI == whiptail ]] && _scroll=(--scrolltext)
  tui "${_scroll[@]}" --textbox "$LOG" "$H" "$W" || true
  TUI_TITLE=""
  return 0
}

ui_console_help() {
  ui_info "Console / log tips

• Backtitle shows Step N/M · phase name
• Full log:  $LOG
• Other TTY: Ctrl+Alt+F2 → root →  tail -f $LOG
• Menus: Next advances, Abort/Esc quits; [log] / [help] always available
• Checklist: Space toggles, Enter = Next
• Radio/menu: arrows (+ Space on radio), Enter = Next
• Long messages scroll: arrows / PgUp / PgDn
• Severity badge + colour: INFO / WARNING / ERROR / CRITICAL / OK
• Destructive confirms default No
• Hard gates (DMI/hook): Continue / Abort · wipe confirms: Erase / Abort
• Live steps (pacstrap/chroot): dialog progress box; whiptail/plain stream to TTY"
}

ui_nav_special() {
  case "$1" in
    log) ui_view_log; return 0 ;;
    help) ui_console_help; return 0 ;;
    *) return 1 ;;
  esac
}

ui_yesno() { # text [default] [severity]
  # severity = info|warn|error|critical|erase
  #   critical → CRITICAL chrome + Continue/Abort (hard gate, not wipe)
  #   erase    → CRITICAL chrome + Erase/Abort (disk/partition wipe only)
  local text=$1 def=${2:-yes} sev=${3:-}
  local folded old_title old_newt old_drc btn_role
  folded=$(ui_fold "$text"; printf x); folded=${folded%x}
  old_title=$TUI_TITLE old_newt=$TUI_NEWT old_drc=$TUI_DIALOGRC
  btn_role=yesno
  case $sev in
    info)
      TUI_TITLE="Confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_INFO; TUI_DIALOGRC=${DIALOG_RC_INFO:-$DIALOG_RC} ;;
    warn)
      TUI_TITLE="Confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_WARN; TUI_DIALOGRC=${DIALOG_RC_WARN:-$DIALOG_RC} ;;
    error)
      TUI_TITLE="Confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_ERROR; TUI_DIALOGRC=${DIALOG_RC_ERROR:-$DIALOG_RC} ;;
    critical)
      TUI_TITLE="CRITICAL confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_CRITICAL; TUI_DIALOGRC=${DIALOG_RC_CRITICAL:-$DIALOG_RC}
      btn_role=critical_yesno ;;
    erase)
      TUI_TITLE="ERASE confirm — $APP_TITLE"
      TUI_NEWT=$NEWT_COLORS_CRITICAL; TUI_DIALOGRC=${DIALOG_RC_CRITICAL:-$DIALOG_RC}
      btn_role=erase_yesno ;;
  esac
  if [[ $UI == plain ]]; then
    local suf=' [Y/n]: ' v='' tag=''
    [[ $def == no ]] && suf=' [y/N]: '
    case $sev in
      info) tag="${cC}[ INFO ]${c0} " ;;
      warn) tag="${cY}[ WARNING ]${c0} " ;;
      error) tag="${cR}[ ERROR ]${c0} " ;;
      critical) tag="${cX}[ CRITICAL ]${c0} " ;;
      erase) tag="${cX}[ ERASE ]${c0} " ;;
    esac
    printf '%s%s\n' "$tag" "$folded" >"$UI_OUT"
    read -r -p "$suf" v </dev/tty 2>"$UI_OUT" || true
    v=${v:-$def}
    TUI_TITLE=$old_title; TUI_NEWT=$old_newt; TUI_DIALOGRC=$old_drc
    [[ ${v,,} == y* ]]
    return
  fi
  local extra=() rc=0
  [[ $def == no ]] && extra=(--defaultno)
  _tui_btns "$btn_role"
  _scroll_flags "$folded"
  tui "${extra[@]}" "${_btns[@]}" "${_scroll[@]}" \
    --yesno "$folded" "$(msg_height "$folded")" "$W" || rc=$?
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

# ui_menu prompt tag description [...] -> tag on stdout
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
      local tags=() t d i=0 pick=
      printf '\n%s\n' "$prompt" >"$UI_OUT"
      while (( $# >= 2 )); do
        t=$1 d=$2; shift 2; tags+=("$t"); i=$((i + 1))
        printf '  %d) %s [%s]\n' "$i" "$d" "$t" >"$UI_OUT"
      done
      tags+=(log help)
      i=$((i + 2))
      printf '  %d) View install log [log]\n  %d) Console / log tips [help]\n' \
        "$((i - 1))" "$i" >"$UI_OUT"
      read -r -p "choose 1-$i (empty=1): " pick </dev/tty 2>"$UI_OUT" || true
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
      local tags=() def='' t d s i=0 pick=
      printf '\n%s\n' "$prompt" >"$UI_OUT"
      while (( $# >= 3 )); do
        t=$1 d=$2 s=$3; shift 3; tags+=("$t"); i=$((i + 1))
        [[ $s == on ]] && def=$t
        printf '  %d) %s [%s]%s\n' "$i" "$d" "$t" "$([[ $s == on ]] && echo ' *')" >"$UI_OUT"
      done
      printf '  L) View install log\n  H) Console / log tips\n' >"$UI_OUT"
      read -r -p "choose 1-$i / L / H (default $def): " pick </dev/tty 2>"$UI_OUT" || true
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
ui_checklist() {
  local prompt=$1; shift
  local args=("$@") out raw real
  while true; do
    set -- "${args[@]}"
    if [[ $UI == dialog || $UI == whiptail ]]; then
      _tui_btns nav
      raw=$(tui "${_btns[@]}" --separate-output --checklist "${prompt}

$TUI_HINT_CHECK" \
        "$H" "$W" "$LH" "$@" \
        log "View install log" off \
        help "Console / log tips" off) || return 1
      out=$raw
    else
      local tags=() descs=() states=() t d s i=0 j pick=
      printf '\n%s\n' "$prompt" >"$UI_OUT"
      printf '(numbers toggle; empty line=Next; L=log H=help)\n' >"$UI_OUT"
      while (( $# >= 3 )); do
        t=$1 d=$2 s=$3; shift 3
        tags+=("$t"); descs+=("$d"); states+=("$s"); i=$((i + 1))
      done
      while true; do
        for (( j=0; j<i; j++ )); do
          printf '  %d) [%s] %s\n' "$((j + 1))" \
            "$([[ ${states[j]} == on ]] && echo x || echo ' ')" "${descs[j]}" >"$UI_OUT"
        done
        pick=
        read -r -p "toggle # / Enter=Next / L=log / H=help: " pick </dev/tty 2>"$UI_OUT" || true
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
    real=$(printf '%s\n' "$out" | grep -Ev '^(log|help)?$' || true)
    if [[ -z $real ]]; then
      if printf '%s\n' "$out" | grep -qx log; then ui_view_log; continue; fi
      if printf '%s\n' "$out" | grep -qx help; then ui_console_help; continue; fi
    fi
    printf '%s' "$real"
    return 0
  done
}

ui_infobox() {
  [[ $UI == plain ]] && return 0
  local h=$(( $(_lines "$1") + 4 ))
  (( h < 5 )) && h=5
  (( h > H )) && h=$H
  tui --infobox "$1" "$h" "$W" || true
}
step() { say "$*"; ui_infobox "$*"; }

# ── logging around the destructive phase ────────────────────
start_log() { LOGGING=1; exec 8>&1 9>&2; exec >>"$LOG" 2>&1; }
stop_log()  { exec >&8 2>&9; LOGGING=0; }

# Run a long command with live TUI/console output AND append to $LOG.
# Returns the command's real exit code (not tee's / dialog's).
# Usage: run_progress "label" cmd [args…]
run_progress() {
  local desc=$1; shift
  local rc=0 rcf
  say "$desc"
  if (( ! HAVE_TTY )); then
    "$@" </dev/null || rc=$?
    return "$rc"
  fi
  rcf=$(mktemp /tmp/t14s-rc.XXXXXX)
  if [[ $UI == dialog ]]; then
    # progressbox reads the pipe on stdin → TUI_KEEP_STDIN=1.
    { _r=0; "$@" </dev/null 2>&1 || _r=$?; printf '%s' "$_r" >"$rcf"; } \
      | tee -a "$LOG" \
      | TUI_KEEP_STDIN=1 tui --progressbox "${desc}

log: $LOG" "$H" "$W" || true
  else
    {
      [[ $UI == whiptail ]] && clear
      printf '\n────────────────────────────────────────────────────────\n'
      printf ' %s\n log: %s\n' "$desc" "$LOG"
      printf ' (live output — can take several minutes)\n'
      printf ' tip: other TTY → tail -f %s\n' "$LOG"
      printf '────────────────────────────────────────────────────────\n\n'
    } >/dev/tty
    { _r=0; "$@" </dev/null 2>&1 || _r=$?; printf '%s' "$_r" >"$rcf"; } \
      | tee -a "$LOG" >/dev/tty || true
  fi
  rc=$(<"$rcf"); rm -f -- "$rcf"
  [[ $rc =~ ^[0-9]+$ ]] || rc=1
  return "$rc"
}

bootstrap_ui() {
  local pkg
  if [[ -n ${T14S_UI:-} ]]; then          # explicit override
    UI=$T14S_UI
    case $UI in
      dialog|whiptail|plain) ;;
      *) warn "unknown T14S_UI=$UI — using plain"; UI=plain ;;
    esac
    if [[ $UI != plain ]] && ! command -v "$UI" >/dev/null 2>&1; then
      pkg=$UI; [[ $UI == whiptail ]] && pkg=libnewt
      (( DRYRUN )) || pacman -Sy --needed --noconfirm "$pkg" >/dev/null 2>&1 || true
      command -v "$UI" >/dev/null 2>&1 || UI=plain
    fi
  else
    [[ -n ${TERM:-} ]] && (( HAVE_TTY )) || return 0
    if command -v dialog >/dev/null 2>&1; then UI=dialog
    elif command -v whiptail >/dev/null 2>&1; then UI=whiptail
    elif (( DRYRUN )); then :
    elif command -v pacman >/dev/null 2>&1 \
      && pacman -Sy --needed --noconfirm dialog >/dev/null 2>&1 \
      && command -v dialog >/dev/null 2>&1; then UI=dialog
    fi
  fi
  if [[ $UI != plain ]] && (( ! HAVE_TTY )); then UI=plain; fi
  if [[ $UI == plain && ${T14S_UI:-} != plain ]]; then warn "no TUI backend (dialog/whiptail) — plain prompts"; fi
  [[ $UI == whiptail ]] && warn "whiptail: no progressbox — long steps stream to the console"
  if [[ $UI == dialog || $UI == whiptail ]]; then
    write_dialogrc
  fi
  ui_geometry
  return 0
}

part_of() { # $1 disk, $2 num -> partition path (nvme/mmc/loop need 'p')
  local d="$1" n="$2"
  if [[ $d == *nvme* || $d == *mmcblk* || $d == *loop* ]]; then
    printf '%sp%s' "$d" "$n"
  else
    printf '%s%s' "$d" "$n"
  fi
}

# Identity validators (before wipe).
# Test fixtures only when T14S_IDENTITY_OVERRIDES=1: LOCALE_FILES, KEYMAP_DIR.
valid_hostname() {
  local h="$1"
  (( ${#h} <= 253 )) || return 1
  [[ $h =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

valid_username() {
  local u="$1"
  [[ $u =~ ^[a-z_][a-z0-9_-]*$ ]] || return 1
  (( ${#u} <= 32 )) || return 1
  id "$u" &>/dev/null && return 1
  getent group "$u" >/dev/null 2>&1 && return 1
  return 0
}

valid_timezone() {
  local tz="$1" f magic
  [[ $tz != *..* ]] || return 1
  [[ $tz =~ ^[A-Za-z_]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
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
    read -r -a files <<<"$LOCALE_FILES"
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
  [[ $km =~ ^[A-Za-z0-9_.+-]+$ ]] || return 1
  if [[ ${T14S_IDENTITY_OVERRIDES:-0} == 1 && -n ${KEYMAP_DIR:-} ]]; then
    root="$KEYMAP_DIR"
  fi
  if command -v localectl >/dev/null 2>&1; then
    localectl list-keymaps 2>/dev/null | grep -qxF -- "$km" && return 0
  fi
  [[ -d $root ]] || return 1
  find "$root" -type f \
    \( -name "${km}.map" -o -name "${km}.map.gz" \
       -o -name "${km}.kmap" -o -name "${km}.kmap.gz" \) \
    2>/dev/null | grep -q .
}

# lsblk helpers never fail (AUTO-mode partitions don't exist until execute).
disk_type() { lsblk -dno TYPE "$1" 2>/dev/null || true; }
size_mb()   { local b; b="$(lsblk -bdnro SIZE "$1" 2>/dev/null || true)"; [[ $b =~ ^[0-9]+$ ]] || b=0; printf '%s' "$(( b / 1048576 ))"; }
part_fs()   { lsblk -no FSTYPE "$1" 2>/dev/null | head -1 || true; }

# build_part_menu ARRAY DISK [filter] [exclude]
build_part_menu() {
  local -n _out=$1
  local _disk=$2 _filter=${3:-any} _excl=${4:-} typ p sz fs tt
  _out=()
  while read -r typ p sz fs tt; do
    [[ $typ == part ]] || continue
    [[ -n $_excl && $p == "$_excl" ]] && continue
    [[ $_filter == vfat && $fs != vfat ]] && continue
    _out+=("$p" "${sz}  ${fs:-empty}  ${tt:-}")
  done < <(lsblk -prno TYPE,PATH,SIZE,FSTYPE,PARTTYPENAME "$_disk" 2>/dev/null || true)
  _out+=(manual "type a partition path")
}

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
    printf '%s' "$ans"; return 0
  done
}

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
        browse_args=()
        while read -r km; do
          [[ -n $km ]] || continue
          browse_args+=("$km" "")
        done < <(find /usr/share/kbd/keymaps -type f \
          \( -name '*.map' -o -name '*.map.gz' \) -printf '%f\n' 2>/dev/null \
          | sed -E 's/\.map(\.gz)?$//' | sort -u || true)
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

pick_timezone() {
  local zroot=/usr/share/zoneinfo region city sub args=() d path
  [[ -d $zroot ]] || { ui_error "Missing $zroot — cannot pick a timezone"; return 1; }
  while read -r d; do
    args+=("$d" "")
  done < <(find "$zroot" -mindepth 1 -maxdepth 1 -type d \
    ! -name right ! -name posix -printf '%f\n' 2>/dev/null | sort || true)
  args+=(UTC "Coordinated Universal Time" other "type Region/City")
  region="$(ui_menu "Timezone region" "${args[@]}")" || return 1
  if [[ $region == other ]]; then
    city="$(ui_input "Timezone (Region/City)" Asia/Dubai)" || return 1
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
    \( -type f -o -type d \) -printf '%f\n' 2>/dev/null | sort || true)
  (( ${#args[@]} >= 2 )) || { ui_error "No zones under $region"; return 1; }
  city="$(ui_menu "Timezone city ($region)" "${args[@]}")" || return 1
  path="$region/$city"
  if [[ -d $zroot/$path ]]; then
    args=()
    while read -r d; do
      args+=("$d" "")
    done < <(find "$zroot/$path" -mindepth 1 -maxdepth 1 \
      \( -type f -o -type d \) -printf '%f\n' 2>/dev/null | sort || true)
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
  { ping -c1 -W3 archlinux.org || curl -fsS --max-time 6 https://archlinux.org; } >/dev/null 2>&1 \
    || die "no internet — connect first (iwctl / dhcp), then re-run"
  timedatectl set-ntp true || true
fi
bootstrap_ui
say "preflight ok (UEFI + network + ntp)"

# Clean leftover state from a previous interrupted run so re-runs start fresh.
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

# Soft DMI check — Gen 3 AMD types only (21CQ/21CR). Missing DMI files (VMs)
# must not trip pipefail.
ui_step 2 Hardware
_dmi="$(cat /sys/class/dmi/id/product_family /sys/class/dmi/id/product_version \
          /sys/class/dmi/id/product_name /sys/class/dmi/id/product_sku 2>/dev/null \
        | tr '\n' ' ' || true)"
if grep -qiE '(^|[[:space:]_/])21C[QR]([[:alnum:]_-]|$)' <<<"$_dmi"; then
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
unset -v _dmi
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
  CLEAN_ESP_ARCH
  UFW_SYNCTHING UFW_KDECONNECT POST_HOOK_URL
  PACMAN_PARALLEL LUKS_WIPE TARGET_HOSTNAME TIMEZONE LOCALE KEYMAP USERNAME
  MODE ESP_MB FORMAT_EFI DISK EFI_PART ROOT_PART
  BTRFS_COMPRESS ZRAM_SIZE REFLECTOR_COUNTRY SKIP_THINKPAD_HW
  EXTRA_PKGS_LIST
)

_strip_kv() { # sets _k/_v from "key=value" line; strips one pair of quotes
  _k=${1%%=*}; _v=${1#*=}
  _k=${_k#"${_k%%[![:space:]]*}"}; _k=${_k%"${_k##*[![:space:]]}"}
  _v=${_v%$'\r'}
  if [[ $_v == \"*\" ]]; then _v=${_v#\"}; _v=${_v%\"}
  elif [[ $_v == \'*\' ]]; then _v=${_v#\'}; _v=${_v%\'}
  fi
  return 0
}

answers_load() {
  local f=$1 line
  [[ -f $f ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line == *=* ]] || continue
    _strip_kv "$line"
    # Back-compat: older answers files used HOSTNAME (clobbers bash's own var).
    [[ $_k == HOSTNAME ]] && _k=TARGET_HOSTNAME
    case " ${ANSWERS_KEYS[*]} " in
      *" $_k "*) printf -v "$_k" '%s' "$_v" ;;
    esac
  done <"$f"
  unset -v _k _v
  return 0
}

answers_save() {
  local f=$1 k val mode
  {
    printf '# t14s-arch-install answers — reload with T14S_ANSWERS=%s\n' "$f"
    printf '# Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    printf '# Passwords NEVER stored here — use T14S_PASS_FILE for unattended secrets.\n'
    for k in "${ANSWERS_KEYS[@]}"; do
      if [[ -v $k ]]; then val=${!k}; else val=; fi
      printf '%s=%s\n' "$k" "$val"
    done
  } >"$f"
  chmod 600 "$f" || die "could not chmod 600 answers file: $f"
  mode=$(stat -c '%a' "$f" 2>/dev/null || echo '')
  [[ $mode == 600 ]] || die "answers file not mode 0600 after chmod (got ${mode:-unknown}): $f"
  return 0
}

# Secrets file (LUKS/USER/ROOT only). Must be mode 0600. Fail closed.
secrets_load() {
  local f=$1 line mode
  [[ -f $f ]] || return 1
  mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%OLp' "$f" 2>/dev/null || true)
  [[ -n $mode ]] || die "cannot read mode of T14S_PASS_FILE (need 0600): $f"
  [[ $mode == 600 || $mode == 0600 ]] || die "T14S_PASS_FILE must be mode 0600 (got $mode): $f"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    [[ $line == *=* ]] || continue
    _strip_kv "$line"
    case $_k in
      LUKS_PASS|USER_PASS|ROOT_PASS) printf -v "$_k" '%s' "$_v" ;;
    esac
  done <"$f"
  unset -v _k _v
  return 0
}

yn_on() {
  local v=${1,,}
  [[ $v == y || $v == yes || $v == on || $v == 1 ]]
}
def_onoff() { if yn_on "$1"; then printf on; else printf off; fi; }
yn_canon() {
  local -n _yc=$1
  if yn_on "${_yc:-}"; then _yc=Y; else _yc=N; fi
}

part_on_disk() {
  local part=$1 disk=$2 pk base rest
  [[ -b $part && -b $disk ]] || return 1
  pk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1 || true)
  base=${disk##*/}
  [[ -n $pk && $pk == "$base" ]] && return 0
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
  answers_load "$ANSWERS_IN" || die "T14S_ANSWERS not readable: $ANSWERS_IN"
  ok "loaded answers from $ANSWERS_IN"
fi
if [[ -n $PASS_FILE ]]; then
  secrets_load "$PASS_FILE" || die "T14S_PASS_FILE not readable: $PASS_FILE"
  SECRETS_FROM_FILE=1
  ok "loaded secrets from $PASS_FILE (passwords not saved to answers)"
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
    ;;
  dev)
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-Y}; INSTALL_PODMAN=${INSTALL_PODMAN:-Y}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-Y}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_CHROME_HINT=${INSTALL_CHROME_HINT:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    ;;
  *)
    PRESET=gnome
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-N}; INSTALL_PODMAN=${INSTALL_PODMAN:-N}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-N}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    ;;
esac
: "${ENROLL_SB:=N}" "${ENABLE_SSHD:=N}" "${INSTALL_CUPS:=N}" "${SKIP_REFLECTOR:=N}"
: "${INSTALL_DOCKER:=N}" "${INSTALL_VIRT:=N}" "${INSTALL_WIREGUARD:=N}"
: "${INSTALL_TAILSCALE:=N}" "${INSTALL_CHROME_HINT:=N}" "${INSTALL_FAIL2BAN:=N}"
: "${INSTALL_THINKFAN:=N}" "${UFW_SYNCTHING:=N}" "${UFW_KDECONNECT:=N}"
: "${INSTALL_SNAPPER_HOME:=N}" "${INSTALL_LINUX_STABLE:=N}" "${INSTALL_PLYMOUTH:=N}"
: "${INSTALL_SELFTEST:=N}" "${CLEAN_ESP_ARCH:=Y}"
: "${PACMAN_PARALLEL:=10}" "${LUKS_WIPE:=none}"
: "${BTRFS_COMPRESS:=zstd3}" "${ZRAM_SIZE:=half}" "${REFLECTOR_COUNTRY:=}"
_FORMAT_EFI_FROM_ANSWERS=${FORMAT_EFI:+1}
: "${FORMAT_EFI:=1}"

# Remove prior Arch boot files under an ESP mount root BEFORE pacstrap.
# Kernels/ucode must go (pacstrap 'conflicting files'). Never call after pacstrap.
clean_esp_arch_files() {
  local root=${1%/}
  [[ -d $root ]] || return 0
  rm -f "$root"/intel-ucode.img "$root"/amd-ucode.img \
        "$root"/vmlinuz-linux* "$root"/initramfs-linux* 2>/dev/null || true
  if yn_on "${CLEAN_ESP_ARCH:-Y}"; then
    rm -f "$root"/EFI/Linux/arch-linux*.efi "$root"/EFI/Linux/arch*.efi 2>/dev/null || true
    if [[ -d $root/loader/entries ]]; then
      find "$root/loader/entries" -maxdepth 1 -type f -name 'arch*.conf' -delete 2>/dev/null || true
    fi
    rm -rf "$root"/EFI/arch "$root"/EFI/Arch "$root"/EFI/ARCH 2>/dev/null || true
  fi
  return 0
}

if [[ -n ${EXTRA_PKGS_LIST:-} ]]; then
  read -r -a _plist <<<"$EXTRA_PKGS_LIST"
  for _p in "${_plist[@]}"; do
    if [[ $_p =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]; then
      EXTRA_PKGS+=("$_p")
    else
      warn "Ignoring invalid EXTRA_PKGS_LIST entry: $_p"
    fi
  done
  unset -v _p _plist
fi

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
    mapfile -t DISKS < <(lsblk -dno PATH,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }' || true)
    menu_args=()
    for d in "${DISKS[@]}"; do
      [[ -b $d ]] || continue
      menu_args+=("$d" "$(lsblk -dnro SIZE,MODEL "$d" 2>/dev/null | sed 's/  */ /g' || true)")
    done
    menu_args+=("manual" "type a device path")

    DISK="$(ui_menu "Select the target disk. AUTO wipes it entirely." "${menu_args[@]}")" \
      || die "no disk selected"
    if [[ $DISK == manual ]]; then
      DISK="$(ui_input "Target disk (e.g. /dev/nvme0n1)" "")" || die "no disk selected"
    fi
    [[ -b $DISK ]] || { ui_error "Not a block device: ${DISK:-<empty>}"; continue; }
    [[ $(disk_type "$DISK") == disk ]] || { ui_error "$DISK is not a whole disk."; continue; }
    break
  done
  unset -v menu_args DISKS d
fi

if command -v smartctl >/dev/null 2>&1; then
  _smart="$(smartctl -H "$DISK" 2>/dev/null | grep -i 'result' | head -1 || true)"
  if [[ -n $_smart ]] && (( ! NONINTERACTIVE )); then
    ui_info "SMART health for $DISK:
$_smart

Full report later: smartctl -a $DISK"
  fi
  unset -v _smart
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

efi_mb=0
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
  efi_mb=$ESP_MB

  if (( NONINTERACTIVE )); then
    require_ni_erase
    warn "NONINTERACTIVE AUTO: will erase entire $DISK (ESP ${ESP_MB}MB + LUKS root)"
  else
    ui_critical "AUTO mode ERASES the ENTIRE disk:

$DISK

Plan: GPT · ${ESP_MB}MB ESP (FAT32) · remainder LUKS2 + Btrfs

That includes any Windows / other-OS partitions on it.

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null || true)"
    CONF="$(ui_input "Type the disk path to confirm total wipe" "")" || die "aborted"
    [[ $CONF == "$DISK" ]] || die "disk confirmation mismatch — aborting"
    ui_yesno "ERASE $DISK now?" no erase || die "aborted"
    unset -v CONF
  fi
  EFI_PART="$(part_of "$DISK" 1)"
  ROOT_PART="$(part_of "$DISK" 2)"
else
  if (( NONINTERACTIVE )); then
    [[ -n ${EFI_PART:-} && -n ${ROOT_PART:-} && -b ${EFI_PART:-/dev/null} && -b ${ROOT_PART:-/dev/null} ]] \
      || die "NONINTERACTIVE MANUAL needs EFI_PART and ROOT_PART block devices in answers"
    require_ni_erase
    [[ $EFI_PART != "$ROOT_PART" ]] || die "EFI_PART and ROOT_PART must differ"
    part_on_disk "$EFI_PART" "$DISK" || die "EFI_PART $EFI_PART is not on DISK $DISK"
    part_on_disk "$ROOT_PART" "$DISK" || die "ROOT_PART $ROOT_PART is not on DISK $DISK"
    [[ ${FORMAT_EFI:-1} =~ ^[01]$ ]] || FORMAT_EFI=1
    efifs="$(part_fs "$EFI_PART")"
    if (( FORMAT_EFI == 0 )) && [[ $efifs != vfat ]]; then
      die "FORMAT_EFI=0 but $EFI_PART is '${efifs:-empty}', not FAT32"
    fi
    efi_mb="$(size_mb "$EFI_PART")"
    root_mb="$(size_mb "$ROOT_PART")"
    (( efi_mb >= 512 )) || die "ESP $EFI_PART is only ${efi_mb}MB (need ≥512; enlarge or pick another)"
    (( root_mb >= 8192 )) || die "ROOT $ROOT_PART is only ${root_mb}MB (need ≥8192)"
    ok "MANUAL partitions from answers: EFI=$EFI_PART ROOT=$ROOT_PART format_efi=$FORMAT_EFI"
  else
    ui_info "Manual partitioning on $DISK.

Current layout (select from lists; sizes and existing filesystems shown):

$(lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" 2>/dev/null || true)"

    ROOT_PART="$(pick_part "Select ROOT — ERASED, becomes LUKS2 + Btrfs" "$DISK")" \
      || die "aborted"
    # Default to REUSE when the disk already carries a FAT ESP (multiboot-safe),
    # unless answers explicitly asked to format.
    _has_vfat=0
    if lsblk -prno FSTYPE "$DISK" 2>/dev/null | grep -qx vfat; then _has_vfat=1; fi
    if [[ -n $_FORMAT_EFI_FROM_ANSWERS ]]; then
      _efi_def=$FORMAT_EFI
    elif (( _has_vfat )); then
      _efi_def=0
    else
      _efi_def=1
    fi
    while :; do
      if [[ $_efi_def == 0 ]]; then _ef_reuse=on; _ef_fmt=off; else _ef_reuse=off; _ef_fmt=on; fi
      EFIMODE="$(ui_radio "EFI handling for $ROOT_PART" \
        reuse "keep an existing FAT32 ESP (multiboot-safe)" "$_ef_reuse" \
        format "format a partition as ESP (destroys its contents)" "$_ef_fmt")" || die "aborted"
      if [[ $EFIMODE == reuse ]]; then FORMAT_EFI=0; else FORMAT_EFI=1; fi
      _efi_def=$FORMAT_EFI

      if (( FORMAT_EFI == 0 && ! _has_vfat )); then
        ui_warn "No FAT32 ESP exists on $DISK. Pick format mode instead (or Abort)."
        continue
      fi

      if (( FORMAT_EFI == 0 )); then
        EFI_PART="$(pick_part "Select the existing ESP (must be FAT32)" "$DISK" vfat "$ROOT_PART")" \
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
    unset -v _has_vfat _efi_def _ef_reuse _ef_fmt EFIMODE

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
      unset -v _m _esp_entries
    elif [[ $efifs == vfat ]]; then
      ui_critical "DANGER: $EFI_PART is ALREADY FAT — likely a shared ESP.
Formatting ERASES other OSes' bootloaders."
    fi

    _proc_efi_lbl=$([[ $FORMAT_EFI == 1 ]] && echo FORMATTED || echo REUSED)
    ui_yesno "Proceed with these partitions?

  ROOT  $ROOT_PART  ${root_mb}MB  ERASED → LUKS2
  EFI   $EFI_PART  ${efi_mb}MB  ${_proc_efi_lbl}" no erase \
      || die "aborted"
    unset -v _proc_efi_lbl
  fi
fi
ok "EFI=$EFI_PART  ROOT=$ROOT_PART  (format_efi=$FORMAT_EFI)"

# ── 3. luks passphrase + optional mapper wipe ───────────────
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
    normal "dd zeros bs=1M (slower, smaller writes)" "$_wo")" || die "aborted"
  unset -v _wn _wf _wo
fi

# ── 4. identity (validated before wipe) ─────────────────────
ui_step 7 Identity
if (( NONINTERACTIVE )); then
  [[ -n ${TARGET_HOSTNAME:-} ]] || die "NONINTERACTIVE needs TARGET_HOSTNAME in answers"
  valid_hostname "$TARGET_HOSTNAME" || die "invalid hostname (DNS labels only): ${TARGET_HOSTNAME}"
else
  while :; do
    TARGET_HOSTNAME="$(ui_input "Hostname" "${TARGET_HOSTNAME:-thinkpad-t14s}")" || die "aborted"
    [[ -n $TARGET_HOSTNAME ]] || { ui_warn "hostname cannot be empty"; continue; }
    valid_hostname "$TARGET_HOSTNAME" && break
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
      other "type a locale (e.g. ar_AE.UTF-8)" "$_lo")" || die "aborted"
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
  [[ $PACMAN_PARALLEL =~ ^(5|10|15)$ ]] || die "NONINTERACTIVE needs PACMAN_PARALLEL=5|10|15"
  [[ $BTRFS_COMPRESS =~ ^(zstd1|zstd3|zstd15|none)$ ]] \
    || die "NONINTERACTIVE needs BTRFS_COMPRESS=zstd1|zstd3|zstd15|none"
  [[ $ZRAM_SIZE =~ ^(half|quarter|8192)$ ]] || die "NONINTERACTIVE needs ZRAM_SIZE=half|quarter|8192"
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

flag_from_opts() {
  local opts=$1 tag=$2
  printf '%s\n' "$opts" | grep -qx "$tag"
}

ui_step 9 Extras
if (( ! NONINTERACTIVE )); then
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
    linux_stable "Also install linux (stable) UKI" "$(def_onoff "$INSTALL_LINUX_STABLE")" \
    plymouth "Plymouth splash (optional)" "$(def_onoff "$INSTALL_PLYMOUTH")" \
    selftest "Write post-boot BT/audio self-test script" "$(def_onoff "$INSTALL_SELFTEST")" \
    clean_esp "Clean old Arch files from ESP (UKIs/entries/EFI/arch)" "$(def_onoff "$CLEAN_ESP_ARCH")" \
    chrome_hint "Write post-boot Chrome Flatpak helper script" "$(def_onoff "$INSTALL_CHROME_HINT")")" \
    || die "aborted"

  OPTS_TOOLS="$(ui_checklist "Dev / CLI tools" \
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
    tailscale "tailscale (sets loose rp_filter)" "$(def_onoff "$INSTALL_TAILSCALE")" \
    fail2ban "fail2ban sshd jail (needs sshd)" "$(def_onoff "$INSTALL_FAIL2BAN")" \
    ufw_syncthing "UFW allow Syncthing 22000/tcp+udp" "$(def_onoff "$UFW_SYNCTHING")" \
    ufw_kdeconnect "UFW allow KDE Connect 1714:1764/tcp+udp" "$(def_onoff "$UFW_KDECONNECT")")" \
    || die "aborted"

  DESKTOP=N; INSTALL_NERD_FONTS=N; ENROLL_SB=N; ENABLE_SSHD=N
  INSTALL_CUPS=N; SKIP_REFLECTOR=N; INSTALL_TLP=N; INSTALL_THINKFAN=N
  INSTALL_SNAPPER_HOME=N; INSTALL_LINUX_STABLE=N; INSTALL_PLYMOUTH=N
  INSTALL_SELFTEST=N; CLEAN_ESP_ARCH=N; INSTALL_CHROME_HINT=N
  INSTALL_CLI=N; INSTALL_STARSHIP=N
  INSTALL_PODMAN=N; INSTALL_DOCKER=N; INSTALL_VIRT=N
  INSTALL_AVAHI=N; INSTALL_WIREGUARD=N; INSTALL_TAILSCALE=N
  INSTALL_FAIL2BAN=N; UFW_SYNCTHING=N; UFW_KDECONNECT=N
  _extras_keep=("${EXTRA_PKGS[@]}")
  EXTRA_PKGS=()

  for _pair in gnome:DESKTOP nerd_fonts:INSTALL_NERD_FONTS sbctl:ENROLL_SB \
    sshd:ENABLE_SSHD cups:INSTALL_CUPS skip_reflector:SKIP_REFLECTOR \
    tlp:INSTALL_TLP thinkfan:INSTALL_THINKFAN snapper_home:INSTALL_SNAPPER_HOME \
    linux_stable:INSTALL_LINUX_STABLE plymouth:INSTALL_PLYMOUTH \
    selftest:INSTALL_SELFTEST clean_esp:CLEAN_ESP_ARCH chrome_hint:INSTALL_CHROME_HINT; do
    if flag_from_opts "$OPTS_CORE" "${_pair%%:*}"; then printf -v "${_pair#*:}" Y; fi
  done
  for _pair in cli:INSTALL_CLI starship:INSTALL_STARSHIP podman:INSTALL_PODMAN \
    docker:INSTALL_DOCKER virt:INSTALL_VIRT; do
    if flag_from_opts "$OPTS_TOOLS" "${_pair%%:*}"; then printf -v "${_pair#*:}" Y; fi
  done
  for _pair in htop:htop tmux:tmux rsync:rsync bash_completion:bash-completion \
    wget:wget usbutils:usbutils lsof:lsof dmidecode:dmidecode powertop:powertop \
    mc:mc traceroute:traceroute bind:bind smartmontools:smartmontools; do
    if flag_from_opts "$OPTS_TOOLS" "${_pair%%:*}"; then EXTRA_PKGS+=("${_pair#*:}"); fi
  done
  for _pair in avahi:INSTALL_AVAHI wireguard:INSTALL_WIREGUARD \
    tailscale:INSTALL_TAILSCALE fail2ban:INSTALL_FAIL2BAN \
    ufw_syncthing:UFW_SYNCTHING ufw_kdeconnect:UFW_KDECONNECT; do
    if flag_from_opts "$OPTS_NET" "${_pair%%:*}"; then printf -v "${_pair#*:}" Y; fi
  done
  unset -v _pair OPTS_CORE OPTS_TOOLS OPTS_NET

  if ((${#_extras_keep[@]})); then
    EXTRA_PKGS+=("${_extras_keep[@]}")
  fi
  unset -v _extras_keep

  if [[ $SKIP_REFLECTOR != Y ]]; then
    REFLECTOR_COUNTRY="$(ui_input "Reflector countries — ISO 3166 codes, comma-separated (e.g. AE,DE); empty=worldwide" \
      "${REFLECTOR_COUNTRY:-}")" || die "aborted"
  else
    REFLECTOR_COUNTRY=
  fi

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

# Post-selection consistency.
if yn_on "$DESKTOP" && yn_on "$INSTALL_TLP"; then
  warn "TLP skipped — GNOME uses power-profiles-daemon"
  INSTALL_TLP=N
fi
if yn_on "$SKIP_THINKPAD_HW"; then
  INSTALL_THINKFAN=N
fi
if yn_on "$INSTALL_FAIL2BAN" && ! yn_on "$ENABLE_SSHD"; then
  warn "fail2ban skipped — its only jail is sshd, which is not enabled"
  INSTALL_FAIL2BAN=N
fi
if [[ ${FORMAT_EFI:-1} == 1 ]]; then
  CLEAN_ESP_ARCH=Y
elif ! yn_on "${CLEAN_ESP_ARCH:-Y}"; then
  warn "CLEAN_ESP_ARCH=N — keeping prior Arch UKIs/arch*.conf; boot menu may show dead entries."
fi
# Reflector: ISO codes only (spaces would split in reflector.conf).
if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
  REFLECTOR_COUNTRY=${REFLECTOR_COUNTRY// /}
  REFLECTOR_COUNTRY=${REFLECTOR_COUNTRY^^}
  if ! [[ $REFLECTOR_COUNTRY =~ ^[A-Z]{2}(,[A-Z]{2})*$ ]]; then
    warn "ignoring invalid REFLECTOR_COUNTRY=$REFLECTOR_COUNTRY (use ISO codes, e.g. AE,DE)"
    REFLECTOR_COUNTRY=
  fi
fi
if [[ -n ${POST_HOOK_URL:-} && ! $POST_HOOK_URL =~ ^https://[^[:space:]]+$ ]]; then
  warn "ignoring non-HTTPS post-install hook URL: $POST_HOOK_URL"
  POST_HOOK_URL=
fi

if (( ! NONINTERACTIVE )); then
  _extra_in="$(ui_input "More pacstrap packages (space-separated, empty=none)" \
    "${T14S_EXTRA_PKGS:-}")" || die "aborted"
else
  _extra_in=${T14S_EXTRA_PKGS:-}
fi
if [[ -n ${_extra_in// /} ]]; then
  read -r -a _plist <<<"$_extra_in"
  for _p in "${_plist[@]}"; do
    if [[ $_p =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]; then
      EXTRA_PKGS+=("$_p")
    else
      ui_warn "Skipping invalid package name: $_p"
    fi
  done
fi
unset -v _extra_in _p _plist
# Dedupe while keeping order, then persist for answers replay.
if ((${#EXTRA_PKGS[@]})); then
  _seen=' '; _uniq=()
  for _p in "${EXTRA_PKGS[@]}"; do
    [[ $_seen == *" $_p "* ]] && continue
    _uniq+=("$_p"); _seen+="$_p "
  done
  EXTRA_PKGS=("${_uniq[@]}")
  unset -v _seen _uniq _p
fi
EXTRA_PKGS_LIST="${EXTRA_PKGS[*]:-}"

for _flag in DESKTOP INSTALL_NERD_FONTS ENROLL_SB ENABLE_SSHD INSTALL_CUPS \
  SKIP_REFLECTOR INSTALL_TLP INSTALL_CLI INSTALL_PODMAN INSTALL_DOCKER \
  INSTALL_VIRT INSTALL_AVAHI INSTALL_WIREGUARD INSTALL_TAILSCALE \
  INSTALL_STARSHIP INSTALL_CHROME_HINT INSTALL_FAIL2BAN INSTALL_THINKFAN \
  INSTALL_SNAPPER_HOME INSTALL_LINUX_STABLE INSTALL_PLYMOUTH INSTALL_SELFTEST \
  CLEAN_ESP_ARCH UFW_SYNCTHING UFW_KDECONNECT SKIP_THINKPAD_HW
do
  [[ -v $_flag ]] || printf -v "$_flag" '%s' N
  yn_canon "$_flag"
done
unset -v _flag

# ── final summary ───────────────────────────────────────────
ui_step 10 Review
if [[ $MODE == auto ]]; then
  _rv_efi="$EFI_PART ${ESP_MB}MB (new, format)"
  _rv_root="$ROOT_PART ~$(( $(size_mb "$DISK") - ESP_MB ))MB (new, LUKS2, wipe=${LUKS_WIPE})"
  _rv_disk="$DISK $(size_mb "$DISK")MB (AUTO wipe)"
else
  _rv_efi="$EFI_PART ${efi_mb}MB ($([[ $FORMAT_EFI == 1 ]] && echo format || echo reuse))"
  _rv_root="$ROOT_PART $(size_mb "$ROOT_PART")MB (LUKS2, wipe=${LUKS_WIPE})"
  _rv_disk="$DISK $(size_mb "$DISK")MB (manual)"
fi
_REVIEW="REVIEW — nothing has been written yet.

  Disk          $_rv_disk
  EFI           $_rv_efi
  Clean ESP     $CLEAN_ESP_ARCH (old Arch UKIs/entries/EFI/arch)
  ROOT          $_rv_root
  Hostname      $TARGET_HOSTNAME
  Timezone      $TIMEZONE
  Locale        $LOCALE
  Keymap        $KEYMAP
  User          $USERNAME
  Profile       $PRESET
  Parallel DL   $PACMAN_PARALLEL
  Btrfs/zram    compress=$BTRFS_COMPRESS zram=$ZRAM_SIZE
  Reflector     $([[ $SKIP_REFLECTOR == Y ]] && echo skip || echo "refresh${REFLECTOR_COUNTRY:+ ($REFLECTOR_COUNTRY)}")
  ThinkPad HW   $([[ $SKIP_THINKPAD_HW == Y ]] && echo skip || echo apply)
  Extra pkgs    ${EXTRA_PKGS_LIST:-none}
  Desktop       $([[ $DESKTOP == Y ]] && echo 'minimal GNOME' || echo none)
  Nerd Fonts    $([[ $INSTALL_NERD_FONTS == Y ]] && echo 'curated set' || echo no)
  Snapper home  $INSTALL_SNAPPER_HOME
  Kernels       lts+hardened$([[ $INSTALL_LINUX_STABLE == Y ]] && echo '+linux') plymouth=$INSTALL_PLYMOUTH
  CLI/Podman    cli=$INSTALL_CLI podman=$INSTALL_PODMAN docker=$INSTALL_DOCKER virt=$INSTALL_VIRT
  Net           avahi=$INSTALL_AVAHI wg=$INSTALL_WIREGUARD tailscale=$INSTALL_TAILSCALE
  CUPS/TLP/SB   cups=$INSTALL_CUPS tlp=$INSTALL_TLP sb=$ENROLL_SB
  SSH/f2b       sshd=$ENABLE_SSHD fail2ban=$INSTALL_FAIL2BAN
  Hook URL      ${POST_HOOK_URL:-none}
  Pass file     ${PASS_FILE:-none}

Typed passwords are not redisplayed."
if ((${#NOTICES[@]})); then
  _REVIEW+=$'\n\nNotices:'
  for _n in "${NOTICES[@]}"; do _REVIEW+=$'\n  • '"$_n"; done
  unset -v _n
fi
unset -v _rv_efi _rv_root _rv_disk
if (( NONINTERACTIVE )); then
  ok "NONINTERACTIVE: skipping REVIEW/confirm UI"
  while IFS= read -r _l; do say "$_l"; done <<<"$_REVIEW"
  unset -v _l
else
  ui_info "$_REVIEW"
  ui_yesno "Start the installation? The partitions above will be ERASED." no erase \
    || die "aborted by user"
fi
unset -v _REVIEW

ANSWERS_OUT="${T14S_ANSWERS_OUT:-/tmp/t14s-answers.env}"
answers_save "$ANSWERS_OUT"
ok "answers saved: $ANSWERS_OUT (reload: T14S_ANSWERS=$ANSWERS_OUT)"

if (( DRYRUN )); then
  printf 'DRYRUN: preset=%s EFI=%s ROOT=%s host=%s user=%s locale=%s tz=%s keymap=%s wipe=%s parallel=%s desktop=%s nerd=%s cli=%s podman=%s docker=%s virt=%s avahi=%s sshd=%s extra=%s\n' \
    "$PRESET" "$EFI_PART" "$ROOT_PART" "$TARGET_HOSTNAME" "$USERNAME" \
    "$LOCALE" "$TIMEZONE" "$KEYMAP" "$LUKS_WIPE" "$PACMAN_PARALLEL" \
    "$DESKTOP" "$INSTALL_NERD_FONTS" "$INSTALL_CLI" "$INSTALL_PODMAN" \
    "$INSTALL_DOCKER" "$INSTALL_VIRT" "$INSTALL_AVAHI" "$ENABLE_SSHD" \
    "${EXTRA_PKGS_LIST:-}"
  exit 0
fi

start_log
ui_step 11 Install

# ── 4b. write the partition table (AUTO only) ───────────────
if [[ $MODE == auto ]]; then
  step "partitioning $DISK (GPT: ${ESP_MB}MB ESP + LUKS)"
  wipefs -af "$DISK" >/dev/null
  sgdisk --zap-all "$DISK" >/dev/null
  sgdisk -n1:0:+"${ESP_MB}"M -t1:ef00 -c1:EFI "$DISK" >/dev/null
  sgdisk -n2:0:0 -t2:8309 -c2:cryptroot "$DISK" >/dev/null
  partprobe "$DISK" || true
  udevadm settle 2>/dev/null || true
  for _i in {1..20}; do
    [[ -b $EFI_PART && -b $ROOT_PART ]] && break
    sleep 0.5
  done
  unset -v _i
  [[ -b $EFI_PART && -b $ROOT_PART ]] || die "partition nodes did not appear: $EFI_PART / $ROOT_PART"
fi

# ── 5. encrypt + filesystems ────────────────────────────────
step "LUKS2 format (argon2id) on $ROOT_PART"
wipefs -a "$ROOT_PART" >/dev/null 2>&1 || true
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id \
  --batch-mode --key-file=- "$ROOT_PART"
# --persistent stores allow-discards in the LUKS2 header: fstrim.timer works
# without any rd.luks.options on the kernel cmdline.
printf '%s' "$LUKS_PASS" | cryptsetup open --allow-discards --persistent \
  --key-file=- "$ROOT_PART" cryptroot
unset -v LUKS_PASS
LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"
[[ -n $LUKS_UUID ]] || die "could not read LUKS UUID from $ROOT_PART"
ok "LUKS open as /dev/mapper/cryptroot (LUKS UUID=$LUKS_UUID, discards persistent)"

# dd exits 1 at end-of-device (ENOSPC) — success only if that's the reason.
_luks_wipe() {
  local desc=$1 rc=0; shift
  run_progress "$desc" "$@" || rc=$?
  if (( rc == 1 )) && tail -n 20 "$LOG" | grep -q 'No space left on device'; then rc=0; fi
  (( rc == 0 )) || die "LUKS wipe failed (dd exit $rc)"
}
case $LUKS_WIPE in
  fast)
    _luks_wipe "wiping cryptroot (dd bs=64M)" \
      dd if=/dev/zero of=/dev/mapper/cryptroot bs=64M oflag=direct status=progress ;;
  normal)
    _luks_wipe "wiping cryptroot (dd bs=1M)" \
      dd if=/dev/zero of=/dev/mapper/cryptroot bs=1M status=progress ;;
esac
unset -f _luks_wipe

step "btrfs + subvolumes"
mkfs.btrfs -f -L archroot /dev/mapper/cryptroot >/dev/null
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @snapshots @var_log @var_cache @tmp; do btrfs subvolume create "/mnt/$sv" >/dev/null; done
chattr +C /mnt/@tmp 2>/dev/null || true
umount /mnt

case ${BTRFS_COMPRESS:-zstd3} in
  zstd1)  CO="noatime,compress=zstd:1,ssd,space_cache=v2" ;;
  zstd15) CO="noatime,compress=zstd:15,ssd,space_cache=v2" ;;
  none)   CO="noatime,ssd,space_cache=v2" ;;
  *)      CO="noatime,compress=zstd:3,ssd,space_cache=v2" ;;
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
  wipefs -a "$EFI_PART" >/dev/null 2>&1 || true
  mkfs.fat -F32 -n EFI "$EFI_PART"
  sync
fi
udevadm settle 2>/dev/null || true
# fmask/dmask 0077: bootctl refuses to be quiet about a world-readable random seed.
mount -t vfat -o fmask=0077,dmask=0077 "$EFI_PART" /mnt/boot
esp_mb=$(df -Pm /mnt/boot | awk 'NR==2{print $2}'); esp_mb=${esp_mb:-0}
(( esp_mb >= 1024 )) || warn "ESP is ${esp_mb}MB — dual-kernel UKIs want >=1024MB; install may fill it"
step "cleaning prior Arch boot artifacts on ESP (CLEAN_ESP_ARCH=$CLEAN_ESP_ARCH)"
clean_esp_arch_files /mnt/boot
ok "filesystems mounted (ESP ${esp_mb}MB)"

# ── 6. base install ─────────────────────────────────────────
UCODE=amd-ucode

# Reflector bounded: concurrent rating, short timeouts, hard deadline, temp file.
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
   && (( $(grep -c '^Server' "$ML_TMP" || true) >= 3 )); then
  cat "$ML_TMP" > /etc/pacman.d/mirrorlist
  ok "mirrorlist refreshed ($(grep -c '^Server' "$ML_TMP") mirrors)"
else
  warn "reflector skipped, timed out, or returned too few mirrors — keeping current mirrorlist"
fi
rm -f "$ML_TMP"
unset -v _reflector_args ML_TMP

# Slow-mirror tolerance via pacman's own DisableDownloadTimeout (pacman ≥ 6.1).
# The old curl XferCommand silently disabled ParallelDownloads. Drop it if a
# previous run of this script inserted it.
sed -i '/^XferCommand = \/usr\/bin\/curl -fL -C - -o %o %u/d' /etc/pacman.conf
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i '/^\[options\]/a DisableDownloadTimeout' /etc/pacman.conf
if grep -q '^#\?ParallelDownloads' /etc/pacman.conf; then
  sed -i "s/^#\\?ParallelDownloads.*/ParallelDownloads = ${PACMAN_PARALLEL}/" /etc/pacman.conf
else
  sed -i "/^\\[options\\]/a ParallelDownloads = ${PACMAN_PARALLEL}" /etc/pacman.conf
fi

BASE_PKGS=(
  base base-devel
  linux-lts linux-lts-headers linux-hardened linux-hardened-headers
  linux-firmware "$UCODE" sof-firmware alsa-ucm-conf
  btrfs-progs cryptsetup dosfstools
  bluez bluez-utils
  networkmanager sudo zsh git vim nano man-db
  reflector pacman-contrib
  mkinitcpio snapper snap-pac zram-generator
  apparmor ufw sbctl efibootmgr
  xdg-user-dirs
)
if yn_on "${INSTALL_LINUX_STABLE:-N}"; then BASE_PKGS+=(linux linux-headers); fi
if yn_on "${INSTALL_PLYMOUTH:-N}"; then BASE_PKGS+=(plymouth); fi
if ((${#EXTRA_PKGS[@]})); then
  _seen=' '
  for _p in "${BASE_PKGS[@]}"; do _seen+="$_p "; done
  _extra_clean=()
  for _p in "${EXTRA_PKGS[@]}"; do
    [[ $_seen == *" $_p "* ]] && continue
    _extra_clean+=("$_p")
  done
  EXTRA_PKGS=("${_extra_clean[@]}")
  unset -v _seen _extra_clean _p
fi
run_progress "pacstrap base system ($UCODE) — downloading/installing packages" \
  pacstrap -K /mnt "${BASE_PKGS[@]}" ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"} \
  || die "pacstrap failed — see $LOG"

step "genfstab"
genfstab -U /mnt >> /mnt/etc/fstab
# subvolid= pins a subvolume ID and breaks snapper rollback; subvol= is enough.
sed -i -E 's/,subvolid=[0-9]+//' /mnt/etc/fstab
sed -i -E '/[[:space:]]\/tmp[[:space:]]+btrfs/ s/(subvol=\/?@tmp)/\1,nofail/' /mnt/etc/fstab
ok "base installed"

# ── 7. chroot configuration ─────────────────────────────────
step "writing chroot config"
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
say(){ printf '\e[1;34m>>\e[0m %s\n' "$*"; }
warn(){ printf '\e[1;33m !!\e[0m %s\n' "$*"; }
yn_on() { local v=${1,,}; [[ $v == y || $v == yes || $v == on || $v == 1 ]]; }

# ── time / locale / keymap ──
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
# Escape BRE/ERE metacharacters so dots in en_US.UTF-8 are literal.
_loc_esc=$(printf '%s\n' "$LOCALE" | sed 's/[].[\*^$]/\\&/g')
# locale.gen lines carry trailing spaces ("#en_US.UTF-8 UTF-8  "): never -x match.
sed -i "s/^#\(${_loc_esc}[[:space:]]\)/\1/" /etc/locale.gen
if ! grep -qE "^${_loc_esc}[[:space:]]" /etc/locale.gen; then
  # Copy the exact SUPPORTED line so the charset is right (en_US → ISO-8859-1).
  _loc_line=$(awk -v l="$LOCALE" '$1 == l { print; exit }' /usr/share/i18n/SUPPORTED 2>/dev/null || true)
  printf '%s\n' "${_loc_line:-$LOCALE UTF-8}" >> /etc/locale.gen
fi
unset -v _loc_esc _loc_line
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# ── hostname / hosts ──
echo "$TARGET_HOSTNAME" > /etc/hostname
_host_short=${TARGET_HOSTNAME%%.*}
if [[ $_host_short == "$TARGET_HOSTNAME" ]]; then
  _host_line="${TARGET_HOSTNAME}.localdomain ${TARGET_HOSTNAME}"
else
  _host_line="${TARGET_HOSTNAME} ${_host_short}"
fi
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${_host_line}
EOF
unset -v _host_short _host_line

# ── users (secrets from 0600 file, shredded by the host after chroot) ──
# shellcheck disable=SC1091
source /root/.t14s-install-secrets
echo "root:${ROOT_PASS}" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
unset -v USER_PASS ROOT_PASS
rm -f /root/.t14s-install-secrets
# Drop-in instead of editing /etc/sudoers (survives sudo package updates).
printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
visudo -cf /etc/sudoers.d/10-wheel >/dev/null
# Without a .zshrc, zsh greets the first login with zsh-newuser-install.
if [[ ! -e /home/$USERNAME/.zshrc ]]; then
  cat > "/home/$USERNAME/.zshrc" <<'ZRC'
# t14s default — edit freely
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt hist_ignore_dups share_history
autoload -Uz compinit && compinit
ZRC
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/.zshrc"
fi

# ── initramfs (systemd + sd-encrypt; plymouth must precede sd-encrypt) ──
_HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)'
if yn_on "${INSTALL_PLYMOUTH}"; then
  _HOOKS='HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)'
fi
sed -i "s/^HOOKS=.*/${_HOOKS}/" /etc/mkinitcpio.conf
unset -v _HOOKS
grep -Eq '^HOOKS=.*sd-encrypt' /etc/mkinitcpio.conf \
  || { echo "ERROR: mkinitcpio HOOKS missing sd-encrypt after sed" >&2; exit 1; }

# ── kernel cmdline (shared by all UKIs) ──
# lsm= replaces the deprecated apparmor=1 security=apparmor.
# Discards come from the LUKS2 header flag (cryptsetup --persistent).
mkdir -p /etc/kernel
_cmdline="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3"
_cmdline+=" mem_sleep_default=s2idle lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
_cmdline+=" amd_iommu=on amd_pstate=active"
if yn_on "${INSTALL_PLYMOUTH}"; then _cmdline+=" splash"; fi
printf '%s\n' "$_cmdline" > /etc/kernel/cmdline
unset -v _cmdline

# ── battery charge window 70–80 (skipped on VM / SKIP_THINKPAD_HW) ──
# A oneshot that waits for thinkpad_acpi is enough; a tmpfiles entry races the
# driver probe and only logs errors. end→start→end avoids EINVAL when the
# current window is on the other side of the new one.
if ! yn_on "${SKIP_THINKPAD_HW}"; then
  mkdir -p /usr/local/lib/thinkpad
  cat > /usr/local/lib/thinkpad/apply-charge-thresholds.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
START=70 END=80
for _ in $(seq 1 60); do
  compgen -G '/sys/class/power_supply/BAT*/charge_control_end_threshold' >/dev/null && break
  sleep 1
done
put() { [[ -e $1 ]] && printf '%s\n' "$2" >"$1" 2>/dev/null; return 0; }
for bat in /sys/class/power_supply/BAT*; do
  [[ -d $bat ]] || continue
  put "$bat/charge_control_end_threshold" "$END"
  put "$bat/charge_control_start_threshold" "$START"
  put "$bat/charge_control_end_threshold" "$END"
done
exit 0
EOF
  chmod 755 /usr/local/lib/thinkpad/apply-charge-thresholds.sh
  cat > /etc/systemd/system/thinkpad-charge-thresholds.service <<'EOF'
[Unit]
Description=ThinkPad battery charge thresholds (70-80)
Documentation=file:///usr/local/lib/thinkpad/apply-charge-thresholds.sh

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

# ── UKI presets: linux-lts (primary) + linux-hardened (fallback) ──
# NOTE: /boot/vmlinuz-* must survive — every preset's ALL_kver reads it.
# Only legacy initramfs images (non-UKI) are dropped here.
rm -f /boot/initramfs-linux*.img 2>/dev/null || true
if yn_on "${CLEAN_ESP_ARCH}"; then
  say "CLEAN_ESP_ARCH — removing old Arch UKIs / loader entries / EFI/arch"
  rm -f /boot/EFI/Linux/arch-linux*.efi /boot/EFI/Linux/arch*.efi 2>/dev/null || true
  if [[ -d /boot/loader/entries ]]; then
    find /boot/loader/entries -maxdepth 1 -type f -name 'arch*.conf' -delete 2>/dev/null || true
  fi
  rm -rf /boot/EFI/arch /boot/EFI/Arch /boot/EFI/ARCH 2>/dev/null || true
fi
mkdir -p /boot/EFI/Linux
write_preset() { # kernel-pkg
  cat > "/etc/mkinitcpio.d/$1.preset" <<EOF
# ALL_kver is REQUIRED — mkinitcpio reads the kernel version from this vmlinuz.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-$1"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-$1.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-$1-fallback.efi"
fallback_options="-S autodetect"
EOF
}
write_preset linux-lts
write_preset linux-hardened
if yn_on "${INSTALL_LINUX_STABLE}"; then write_preset linux; fi
unset -f write_preset
for _k in /boot/vmlinuz-linux-lts /boot/vmlinuz-linux-hardened; do
  [[ -f $_k ]] || { echo "ERROR: $_k missing before UKI build" >&2; exit 1; }
done
unset -v _k
say "building UKIs"
mkinitcpio -P
rm -f /boot/initramfs-linux*.img 2>/dev/null || true
_esp_free_mb="$(df -Pm /boot 2>/dev/null | awk 'NR==2{print $4}')"
if [[ ${_esp_free_mb:-} =~ ^[0-9]+$ ]]; then
  if (( _esp_free_mb < 64 )); then
    echo "ERROR: ESP nearly full after UKI build (${_esp_free_mb}MB free). Enlarge ESP or drop linux-stable." >&2
    exit 1
  elif (( _esp_free_mb < 200 )); then
    warn "ESP low after UKI build (${_esp_free_mb}MB free) — leave room for kernel updates"
  else
    say "ESP free after UKI build: ${_esp_free_mb}MB"
  fi
fi
unset -v _esp_free_mb

# ── Secure Boot keys + signed systemd-boot (before bootctl install) ──
# bootctl install/update prefer systemd-bootx64.efi.signed when present, so
# systemd-boot-update.service never drops an unsigned loader onto the ESP.
say "sbctl: keys + signed systemd-boot"
_sb_keys=0
if [[ -d /var/lib/sbctl/keys || -d /usr/share/secureboot/keys ]]; then
  _sb_keys=1
elif sbctl create-keys; then
  _sb_keys=1
else
  warn "sbctl create-keys failed — Secure Boot setup skipped (do it post-boot)"
fi
_sdb=/usr/lib/systemd/boot/efi/systemd-bootx64.efi
if (( _sb_keys )); then
  sbctl sign -s -o "${_sdb}.signed" "$_sdb" \
    || warn "could not sign systemd-boot — SB enroll will be blocked by verify"
fi
unset -v _sdb

say "systemd-boot"
if [[ ${FORMAT_EFI:-1} == 0 && -f /boot/EFI/BOOT/BOOTX64.EFI ]]; then
  cp -n /boot/EFI/BOOT/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI.pre-arch.bak 2>/dev/null || true
  say "backed up existing /EFI/BOOT/BOOTX64.EFI -> .pre-arch.bak"
fi
bootctl install
find /boot/EFI -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's,^,   loader dir: ,' || true
cat > /boot/loader/loader.conf <<EOF
default arch-linux-lts.efi
timeout 3
editor no
console-mode max
EOF

# ── zram ──
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

# ── sysctl hardening ──
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

# ── firewall ──
# Config files only: running `ufw enable` here would load rules into the LIVE
# ISO's netfilter (arch-chroot shares the host network namespace).
# /etc/default/ufw already ships DEFAULT_INPUT_POLICY="DROP" / OUTPUT ACCEPT.
sed -i 's/^DEFAULT_INPUT_POLICY=.*/DEFAULT_INPUT_POLICY="DROP"/; s/^DEFAULT_OUTPUT_POLICY=.*/DEFAULT_OUTPUT_POLICY="ACCEPT"/' /etc/default/ufw
sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf
# While inactive, `ufw allow` only writes user.rules (no kernel access).
ufw_allow() { ufw allow "$@" >/dev/null 2>&1 || warn "ufw allow $* failed — add post-boot"; }

# ── reflector (weekly timer) ──
{
  printf '%s\n' '--latest 10' '--protocol https' '--sort rate' '--threads 5'
  printf '%s\n' '--connection-timeout 3' '--download-timeout 5'
  printf '%s\n' '--save /etc/pacman.d/mirrorlist'
  if [[ -n ${REFLECTOR_COUNTRY:-} ]]; then
    printf -- '--country %s\n' "$REFLECTOR_COUNTRY"
  fi
} > /etc/xdg/reflector/reflector.conf

# ── pacman ──
PACMAN_PARALLEL="${PACMAN_PARALLEL:-10}"
sed -i "s/^#Color/Color/" /etc/pacman.conf
if grep -q '^#\?ParallelDownloads' /etc/pacman.conf; then
  sed -i "s/^#\\?ParallelDownloads.*/ParallelDownloads = ${PACMAN_PARALLEL}/" /etc/pacman.conf
else
  sed -i "/^\\[options\\]/a ParallelDownloads = ${PACMAN_PARALLEL}" /etc/pacman.conf
fi
grep -q '^DisableDownloadTimeout' /etc/pacman.conf \
  || sed -i '/^\[options\]/a DisableDownloadTimeout' /etc/pacman.conf

# ── core services ──
systemctl enable NetworkManager apparmor ufw bluetooth fstrim.timer reflector.timer \
                 systemd-timesyncd systemd-boot-update.service

# ── minimal GNOME (optional) ──
if yn_on "$DESKTOP"; then
  say "installing minimal GNOME + browsers + VPN + software center"
  _gnome_pkgs=(
    gnome-shell gnome-session gdm gnome-control-center gnome-keyring
    gnome-backgrounds nautilus gnome-console gnome-text-editor
    gnome-system-monitor gnome-calculator loupe evince gnome-disk-utility
    xdg-user-dirs-gtk xdg-desktop-portal xdg-desktop-portal-gnome polkit
    flatpak fwupd bolt pipewire pipewire-pulse wireplumber earlyoom
    power-profiles-daemon noto-fonts
    mesa vulkan-radeon
    gnome-software
  )
  if ! yn_on "${SKIP_THINKPAD_HW}"; then _gnome_pkgs+=(fprintd); fi
  if pacman -S --noconfirm --needed "${_gnome_pkgs[@]}"; then
    systemctl enable gdm bolt.service earlyoom.service power-profiles-daemon
    mkdir -p /etc/gdm
    printf '[daemon]\nWaylandEnable=true\n' > /etc/gdm/custom.conf
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    # Chrome (extra-data) fails under bwrap in chroot — install post-boot.
    failed_fp=()
    for app in com.brave.Browser app.zen_browser.zen \
               io.gitlab.librewolf-community com.protonvpn.www; do
      if ! flatpak install --system -y --noninteractive flathub "$app"; then
        failed_fp+=("$app")
        flatpak uninstall --system -y --noninteractive "$app" >/dev/null 2>&1 || true
        flatpak info --system "$app" >/dev/null 2>&1 || rm -rf "/var/lib/flatpak/app/$app"
      fi
    done
    if (( ${#failed_fp[@]} )); then
      warn "flatpak install failed: ${failed_fp[*]}"
      warn "retry after first boot: flatpak install --system -y flathub <app>"
    fi
    # Console → XKB via systemd's own table (what localectl uses; localed has no
    # D-Bus in the chroot). Handles uk→gb, de-latin1→de, dvorak→us/dvorak, ...
    XKB_LAYOUT='' XKB_VARIANT=''
    if [[ -r /usr/share/systemd/kbd-model-map ]]; then
      read -r XKB_LAYOUT XKB_VARIANT < <(awk -v k="$KEYMAP" \
        '!/^#/ && $1 == k { print $2, ($4 == "-" ? "" : $4); exit }' \
        /usr/share/systemd/kbd-model-map) || true
    fi
    if [[ -z $XKB_LAYOUT ]]; then
      XKB_LAYOUT=us
      warn "no XKB mapping for console keymap '$KEYMAP' — GNOME layout set to us"
    fi
    mkdir -p /etc/X11/xorg.conf.d
    {
      printf '%s\n' 'Section "InputClass"'
      printf '%s\n' '        Identifier "system-keyboard"'
      printf '%s\n' '        MatchIsKeyboard "on"'
      printf '        Option "XkbLayout" "%s"\n' "$XKB_LAYOUT"
      if [[ -n $XKB_VARIANT ]]; then
        printf '        Option "XkbVariant" "%s"\n' "$XKB_VARIANT"
      fi
      printf '%s\n' 'EndSection'
    } > /etc/X11/xorg.conf.d/00-keyboard.conf
    unset -v XKB_LAYOUT XKB_VARIANT
  else
    warn "GNOME install incomplete (network?) — base system is fine. Finish post-boot:"
    warn "  pacman -S gnome-shell gdm && systemctl enable gdm"
  fi
  unset -v _gnome_pkgs
fi

# ── Nerd Fonts + UI fonts ──
if yn_on "${INSTALL_NERD_FONTS}"; then
  say "installing Nerd Fonts + Inter/Noto"
  if pacman -S --noconfirm --needed \
    ttf-jetbrains-mono-nerd ttf-meslo-nerd ttf-firacode-nerd \
    ttf-cascadia-mono-nerd ttf-cascadia-code-nerd ttf-hack-nerd \
    ttf-iosevka-nerd ttf-iosevkaterm-nerd ttf-victor-mono-nerd \
    ttf-ibmplex-mono-nerd ttf-sourcecodepro-nerd ttf-dejavu-nerd \
    otf-geist-mono-nerd otf-commit-mono-nerd \
    ttf-nerd-fonts-symbols-common \
    inter-font noto-fonts noto-fonts-emoji
  then
    fc-cache -f >/dev/null 2>&1 || true
  else
    warn "font install incomplete — retry post-boot"
  fi
fi

# ── GNOME dconf defaults (separate keyfiles: no duplicate group headers) ──
if yn_on "$DESKTOP"; then
  say "applying GNOME dconf defaults"
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
    cat > /etc/dconf/db/local.d/01-t14s-fonts <<'DCONF'
[org/gnome/desktop/interface]
font-name='Inter 11'
document-font-name='Inter 11'
monospace-font-name='JetBrainsMono Nerd Font Mono 11'

[org/gnome/Console]
custom-font='JetBrainsMono Nerd Font Mono 12'
use-system-font=false
DCONF
  fi
  dconf update 2>/dev/null || warn "dconf update failed — run 'dconf update' post-boot"
fi

# ── printing ──
if yn_on "${INSTALL_CUPS}"; then
  say "installing CUPS printing stack"
  if pacman -S --noconfirm --needed cups cups-pdf ghostscript; then
    systemctl enable cups.service
  else
    warn "CUPS install failed — retry post-boot: pacman -S cups cups-pdf ghostscript"
  fi
fi

# ── CLI / starship / containers / virt ──
if yn_on "${INSTALL_CLI}"; then
  say "installing CLI tools (ripgrep fd fzf bat eza jq git-delta)"
  pacman -S --noconfirm --needed ripgrep fd fzf bat eza jq git-delta \
    || warn "CLI tools incomplete"
fi

if yn_on "${INSTALL_STARSHIP}"; then
  say "installing starship"
  if pacman -S --noconfirm --needed starship; then
    install -d -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config"
    if [[ ! -e /home/$USERNAME/.config/starship.toml ]]; then
      printf '%s\n' '# t14s default — customize after first boot' 'add_newline = false' \
        > "/home/$USERNAME/.config/starship.toml"
    fi
    if ! grep -q 'starship init zsh' "/home/$USERNAME/.zshrc" 2>/dev/null; then
      printf '%s\n' 'eval "$(starship init zsh)"' >> "/home/$USERNAME/.zshrc"
    fi
    chown "$USERNAME:$USERNAME" "/home/$USERNAME/.config/starship.toml" "/home/$USERNAME/.zshrc"
  else
    warn "starship install failed"
  fi
fi

if yn_on "${INSTALL_PODMAN}"; then
  say "installing podman + buildah"
  pacman -S --noconfirm --needed podman buildah || warn "podman install failed"
fi

if yn_on "${INSTALL_DOCKER}"; then
  say "installing docker"
  if pacman -S --noconfirm --needed docker docker-compose; then
    systemctl enable docker.service
    usermod -aG docker "$USERNAME" || true
  else
    warn "docker install failed"
  fi
fi

if yn_on "${INSTALL_VIRT}"; then
  say "installing libvirt + qemu + virt-manager"
  if pacman -S --noconfirm --needed libvirt qemu-desktop virt-manager edk2-ovmf dnsmasq; then
    systemctl enable libvirtd.service
    usermod -aG libvirt "$USERNAME" || true
  else
    warn "virt stack install failed"
  fi
fi

# ── TLP (console-only; desktop path already cleared INSTALL_TLP) ──
if yn_on "${INSTALL_TLP}"; then
  say "installing TLP"
  if pacman -S --noconfirm --needed tlp tlp-rdw; then
    systemctl enable tlp.service NetworkManager-dispatcher.service
    # TLP docs: mask rfkill units so TLP owns radio state.
    systemctl mask systemd-rfkill.service systemd-rfkill.socket
  else
    warn "TLP install failed"
  fi
fi

if yn_on "${INSTALL_THINKFAN}"; then
  cat > /root/t14s-thinkfan.txt <<'TF'
thinkfan is not in official Arch repos (AUR). After first boot with an AUR helper:
  paru -S thinkfan
  # then configure /etc/thinkfan.conf for your T14s and:
  sudo systemctl enable --now thinkfan
TF
  say "wrote /root/t14s-thinkfan.txt (AUR install notes)"
fi

# ── mDNS / VPN ──
if yn_on "${INSTALL_AVAHI}"; then
  say "installing avahi + nss-mdns"
  if pacman -S --noconfirm --needed avahi nss-mdns; then
    systemctl enable avahi-daemon.service
    if [[ -f /etc/nsswitch.conf ]] && ! grep -q 'mdns_minimal' /etc/nsswitch.conf; then
      sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
        /etc/nsswitch.conf || warn "could not patch nsswitch.conf for mdns_minimal"
    fi
  else
    warn "avahi install failed"
  fi
fi

if yn_on "${INSTALL_WIREGUARD}"; then
  pacman -S --noconfirm --needed wireguard-tools || warn "wireguard-tools failed"
fi
if yn_on "${INSTALL_TAILSCALE}"; then
  if pacman -S --noconfirm --needed tailscale; then
    systemctl enable tailscaled.service
    # Strict rp_filter breaks subnet routes / exit nodes. Sorts after 99-security.
    printf '%s\n' 'net.ipv4.conf.all.rp_filter = 2' 'net.ipv4.conf.default.rp_filter = 2' \
      > /etc/sysctl.d/99-tailscale.conf
  else
    warn "tailscale failed"
  fi
fi

if yn_on "${UFW_SYNCTHING}"; then
  ufw_allow 22000/tcp comment syncthing
  ufw_allow 22000/udp comment syncthing
fi
if yn_on "${UFW_KDECONNECT}"; then
  ufw_allow 1714:1764/tcp comment kdeconnect
  ufw_allow 1714:1764/udp comment kdeconnect
fi

if yn_on "${INSTALL_CHROME_HINT}"; then
  cat > "/home/$USERNAME/install-chrome-flatpak.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub com.google.Chrome
SH
  chmod 755 "/home/$USERNAME/install-chrome-flatpak.sh"
  chown "$USERNAME:$USERNAME" "/home/$USERNAME/install-chrome-flatpak.sh"
fi

if command -v xdg-user-dirs-update >/dev/null 2>&1; then
  runuser -u "$USERNAME" -- env HOME="/home/$USERNAME" xdg-user-dirs-update || true
fi

# ── post-boot self-test (run as your user) ──
if yn_on "${INSTALL_SELFTEST}"; then
  cat > /usr/local/bin/t14s-selftest <<'ST'
#!/usr/bin/env bash
# Quick Rembrandt laptop sanity after first boot. Run as your normal user.
set -uo pipefail
ok=0 bad=0
check() { # name 'shell expression'
  if bash -c "$2" >/dev/null 2>&1; then
    printf 'OK   %s\n' "$1"; ok=$((ok + 1))
  else
    printf 'FAIL %s\n' "$1"; bad=$((bad + 1))
  fi
}
check bluetooth  'systemctl is-active --quiet bluetooth'
check pipewire   'systemctl --user is-active --quiet pipewire.socket || pactl info'
check wifi       "nmcli -t -f TYPE,STATE device | grep -q '^wifi:connected'"
check apparmor   'systemctl is-active --quiet apparmor'
check ufw        'systemctl is-active --quiet ufw'
check zram       'swapon --show=NAME --noheadings | grep -q zram'
check amd_pstate "grep -q 'amd_pstate=active' /proc/cmdline"
check s2idle     "grep -q '\[s2idle\]' /sys/power/mem_sleep"
check luks_trim  "lsblk -dnD -o DISC-MAX /dev/mapper/cryptroot | grep -qvE '^[[:space:]]*0B?[[:space:]]*\$'"
printf 't14s-selftest: %d ok, %d fail\n' "$ok" "$bad"
(( bad == 0 ))
ST
  chmod 755 /usr/local/bin/t14s-selftest
  say "wrote /usr/local/bin/t14s-selftest"
fi

# ── SSH + fail2ban ──
if yn_on "${ENABLE_SSHD}"; then
  say "enabling OpenSSH (sshd + UFW 22/tcp)"
  if pacman -S --noconfirm --needed openssh; then
    systemctl enable sshd
    ufw_allow 22/tcp comment ssh
    if yn_on "${INSTALL_FAIL2BAN}"; then
      say "installing fail2ban"
      if pacman -S --noconfirm --needed fail2ban; then
        mkdir -p /etc/fail2ban/jail.d
        # journald-only system: no /var/log/auth.log → backend must be systemd.
        cat > /etc/fail2ban/jail.d/sshd.local <<'FB'
[sshd]
enabled = true
backend = systemd
FB
        systemctl enable fail2ban.service
      else
        warn "fail2ban install failed"
      fi
    fi
  else
    warn "openssh install failed — retry post-boot: pacman -S openssh && systemctl enable --now sshd"
  fi
fi

# ── Secure Boot: sign UKIs + loaders; enroll only if verify clean + Setup Mode ──
if (( _sb_keys )); then
  say "sbctl: sign UKIs + loaders"
  for f in /boot/EFI/Linux/arch-linux-lts.efi /boot/EFI/Linux/arch-linux-lts-fallback.efi \
           /boot/EFI/Linux/arch-linux-hardened.efi /boot/EFI/Linux/arch-linux-hardened-fallback.efi \
           /boot/EFI/Linux/arch-linux.efi /boot/EFI/Linux/arch-linux-fallback.efi \
           /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI; do
    if [[ -f $f ]]; then sbctl sign -s "$f" || warn "sbctl sign failed: $f"; fi
  done
  _sb_ok=0
  if sbctl verify; then
    _sb_ok=1; say "sbctl verify OK"
  else
    warn "sbctl verify reported unsigned files — enroll blocked until fixed"
  fi
  if yn_on "${ENROLL_SB}"; then
    if (( _sb_ok )) && sbctl status 2>/dev/null | grep -qi 'setup mode.*enabled'; then
      say "enrolling Secure Boot keys (-m keeps Microsoft keys)"
      sbctl enroll-keys -m || warn "enroll failed — do it post-reboot"
    elif (( ! _sb_ok )); then
      warn "enroll skipped — sbctl verify failed"
    else
      warn "enroll skipped — Setup Mode not enabled (enroll post-reboot)"
    fi
  fi
  unset -v _sb_ok
fi
unset -v _sb_keys

# ── snapper last: snap-pac would otherwise snapshot every install step above ──
umount /.snapshots 2>/dev/null || true
rmdir  /.snapshots 2>/dev/null || true
if snapper --no-dbus -c root create-config /; then
  btrfs subvolume delete /.snapshots 2>/dev/null || true
  mkdir -p /.snapshots; mount /.snapshots || mount -a || true; chmod 750 /.snapshots
  systemctl enable snapper-timeline.timer snapper-cleanup.timer
else
  warn "snapper create-config failed — skipping snapshots (configure post-boot)"
  mkdir -p /.snapshots; mount /.snapshots || mount -a || true
fi
if yn_on "${INSTALL_SNAPPER_HOME}"; then
  say "snapper config for /home"
  snapper --no-dbus -c home create-config /home \
    || warn "snapper home create-config failed — configure post-boot"
fi
say "chroot config done"
CHROOT

# Passwords via 0600 file (not arch-chroot env — visible in /proc/*/environ).
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
_log_mark=$(wc -l <"$LOG")
cleanup_chroot_secrets() {
  shred -u /mnt/root/chroot-setup.sh /mnt/root/.t14s-install-secrets 2>/dev/null \
    || rm -f /mnt/root/chroot-setup.sh /mnt/root/.t14s-install-secrets
  return 0
}
if ! run_progress "running chroot config (UKIs, users, optional GNOME)" \
  arch-chroot /mnt env \
    TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" KEYMAP="$KEYMAP" \
    TARGET_HOSTNAME="$TARGET_HOSTNAME" USERNAME="$USERNAME" \
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
    INSTALL_LINUX_STABLE="$INSTALL_LINUX_STABLE" INSTALL_PLYMOUTH="$INSTALL_PLYMOUTH" \
    INSTALL_SELFTEST="$INSTALL_SELFTEST" CLEAN_ESP_ARCH="$CLEAN_ESP_ARCH" \
    ZRAM_SIZE="$ZRAM_SIZE" REFLECTOR_COUNTRY="$REFLECTOR_COUNTRY" \
    SKIP_THINKPAD_HW="$SKIP_THINKPAD_HW" \
    UFW_SYNCTHING="$UFW_SYNCTHING" UFW_KDECONNECT="$UFW_KDECONNECT" \
    bash /root/chroot-setup.sh
then
  cleanup_chroot_secrets
  die "chroot setup failed — see $LOG"
fi
cleanup_chroot_secrets
# Surface chroot-side warnings (only lines written during the chroot run).
while IFS= read -r _w; do
  NOTICES+=("chroot: ${_w# !! }")
done < <(tail -n "+$(( _log_mark + 1 ))" "$LOG" | sed -n 's/\x1b\[[0-9;]*m//g; /^ !! /p' | tail -n 20 || true)
unset -v _w _log_mark
ok "chroot config complete"

answers_save /mnt/root/t14s-answers.env || true
if [[ -n ${POST_HOOK_URL:-} ]]; then
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
  LOGIN_HINT="First login via GDM (Wayland)."
  FLATPAK_HINT="Optional post-boot: flatpak install --user -y flathub com.google.Chrome"
else
  LOGIN_HINT="Desktop skipped — log in on a virtual console (getty) as ${USERNAME}."
  FLATPAK_HINT="Optional later: pacman -S gnome-shell gdm flatpak && systemctl enable gdm"
fi
if yn_on "$INSTALL_CHROME_HINT"; then
  FLATPAK_HINT="Chrome helper: ~${USERNAME}/install-chrome-flatpak.sh"
fi
if yn_on "$INSTALL_SNAPPER_HOME"; then
  SNAPPER_HINT="root + home configs enabled"
else
  SNAPPER_HINT="root config enabled; add home later: snapper -c home create-config /home"
fi
if yn_on "$INSTALL_SELFTEST"; then
  SELFTEST_HINT="Self-test (as your user): t14s-selftest"
else
  SELFTEST_HINT="Self-test script not installed"
fi

POST_TXT="T14s install — next steps

  Reboot and remove the ISO:   reboot
  Boot menu: Arch Linux (LTS) default, Hardened as fallback.
  Answers file: /root/t14s-answers.env (T14S_ANSWERS=... to reuse)
  Verify after boot:
    lscpu | grep -i ryzen
    cat /sys/power/mem_sleep            (expect [s2idle])
    grep -E 'amd_iommu|amd_pstate|lsm=' /proc/cmdline
    sudo cryptsetup status cryptroot    (flags: discards)
  Secure Boot (to enable):
    1) BIOS -> clear Secure Boot keys -> Setup Mode
    2) booted OS: sudo sbctl enroll-keys -m
    3) BIOS -> Secure Boot -> Enabled
    systemd-boot updates ship pre-signed (.signed + systemd-boot-update).
    '-m' keeps Microsoft keys so Windows still boots.
  Recovery (from Arch ISO):
    cryptsetup open /dev/<root> cryptroot
    mount -o subvol=@ /dev/mapper/cryptroot /mnt
    mount /dev/<esp> /mnt/boot
    arch-chroot /mnt
  Snapper: ${SNAPPER_HINT}
  ${SELFTEST_HINT}
  Fingerprint (GNOME): fprintd-enroll
  Hostname: ${TARGET_HOSTNAME}
  ${LOGIN_HINT}
  Charge thresholds (ThinkPad only):
    cat /sys/class/power_supply/BAT0/charge_control_{start,end}_threshold
    (expect 70 / 80; thinkpad-charge-thresholds.service)
  ${FLATPAK_HINT}"
if ((${#NOTICES[@]})); then
  POST_TXT+=$'\n\nNotices during install:'
  for _n in "${NOTICES[@]}"; do POST_TXT+=$'\n  • '"$_n"; done
  unset -v _n
fi

printf '%s\n' "$POST_TXT" > /mnt/root/t14s-post-install.txt

step "unmounting"
umount -R /mnt
cryptsetup close cryptroot
stop_log

ui_ok "INSTALL COMPLETE — reboot and remove the ISO.

$POST_TXT"
ok "done — reboot when ready (log: $LOG)"
