# 12-ui-screens.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# TUI screens: plain prompts, message/yes-no/input boxes, menus, radio lists, checklists.

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

# Height for a message body: MH floor, H ceiling, scales with line count.
msg_height() {
  local text=$1 lines need
  # Visible lines: wc -l counts newlines, so add the final unterminated line.
  # whiptail/dialog need text + 6 rows (borders, padding, button row).
  lines=$(printf '%s\n' "$text" | wc -l)
  need=$(( lines + 6 ))
  (( need < MH )) && need=$MH
  (( need > ${XH:-$H} )) && need=${XH:-$H}
  printf '%s' "$need"
}

# whiptail --scrolltext moves focus into the text, where Enter does nothing
# (the box looks frozen until Tab). Only scroll bodies taller than the screen.
msg_overflows() {
  local lines
  lines=$(printf '%s\n' "$1" | wc -l)
  (( lines + 6 > ${XH:-$H} ))
}

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
  ui_geometry  # console font/size may have changed since the last step
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
  # whiptail cuts text taller than the box unless --scrolltext (REVIEW and the
  # finish screen are 30+ lines; an 80x24 console fits ~16). Only then: in a
  # scrolling box Enter is ignored until Tab reaches the button, so say so.
  local scroll=()
  if [[ $UI == whiptail ]] && msg_overflows "$show"; then
    scroll=(--scrolltext)
    show=$'[ arrows scroll · Tab, then Enter to continue ]\n'"$show"
  fi
  tui "${scroll[@]}" "${_btns[@]}" --msgbox "$show" "$h" "$MW" || true
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
  ui_geometry
  TUI_TITLE="Install log — $APP_TITLE"
  tui --textbox "$LOG" "$H" "$W" || true
  TUI_TITLE=""
}

ui_console_help() {
  ui_info "Console / log tips

• Backtitle shows Step N/M · phase name
• Full log:  $LOG
• Other TTY: Ctrl+Alt+F2 → root →  tail -f $LOG
• Menus: Next advances, Abort quits (Esc too with dialog; whiptail: Tab to Abort); [log] / [help] always available
• Checklist: Space toggles, Enter = Next
• Radio/menu: arrows (+ Space on radio), Enter = Next
• Severity badge + chrome (not color alone): INFO / WARN / ERROR / CRITICAL / OK
• Destructive confirms default No
• Hard gates (DMI/hook): Continue / Abort · wipe confirms: Erase / Abort
• Live steps (pacstrap/chroot): dialog progress box; whiptail/plain stream to TTY
• Kernel messages are kept off this console while the installer runs: dmesg -w on another TTY"
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
  ui_geometry
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
  if [[ $UI == whiptail ]] && msg_overflows "$folded"; then
    extra+=(--scrolltext)
    folded=$'[ arrows scroll · Tab, then Enter to answer ]\n'"$folded"
  fi
  _tui_btns "$btn_role"
  local rc=0
  tui "${extra[@]}" "${_btns[@]}" --yesno "$folded" "$(msg_height "$folded")" "$MW" || rc=$?
  TUI_TITLE=$old_title; TUI_NEWT=$old_newt; TUI_DIALOGRC=$old_drc
  return "$rc"
}

ui_input() { # prompt [default]
  if [[ $UI == plain ]]; then ask "$1: " "${2:-}"; return; fi
  ui_geometry
  _tui_btns nav
  tui "${_btns[@]}" --inputbox "$1" 10 "$MW" "${2:-}"
}

ui_password() { # prompt
  if [[ $UI == plain ]]; then ask_secret "$1: "; return; fi
  ui_geometry
  _tui_btns nav
  tui "${_btns[@]}" --passwordbox "$1" 10 "$MW"
}

# list_height TEXT — list rows for a menu/radio/checklist whose prompt is TEXT.
# whiptail shows only H - list - 6 prompt rows and cuts the rest (the key hint
# under every prompt was never visible); dialog shrinks its list by itself.
list_height() {
  local line rows=0 tw=$(( W - 6 )) lh
  [[ $UI == whiptail ]] || { printf '%s' "$LH"; return 0; }
  (( tw < 20 )) && tw=20
  while IFS= read -r line; do
    rows=$(( rows + (${#line} > 0 ? (${#line} + tw - 1) / tw : 1) ))
  done <<<"$1"
  lh=$(( H - 6 - rows ))
  (( lh > LH )) && lh=$LH
  (( lh < 3 )) && lh=3
  printf '%s' "$lh"
}

# ui_menu prompt tag description [tag description ...]  -> tag on stdout
# Always offers log / help as extra entries. Next advances; Abort (Esc: dialog only) quits.
ui_menu() {
  local prompt=$1; shift
  local args=("$@") choice
  while true; do
    set -- "${args[@]}"
    ui_geometry
    if [[ $UI != plain ]]; then
      _tui_btns nav
      choice=$(tui "${_btns[@]}" --menu "${prompt}

$TUI_HINT_MENU" \
        "$H" "$W" "$(list_height "${prompt}"$'\n\n'"$TUI_HINT_MENU")" "$@" \
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
    ui_geometry
    if [[ $UI != plain ]]; then
      _tui_btns nav
      choice=$(tui "${_btns[@]}" --radiolist "${prompt}

$TUI_HINT_RADIO" \
        "$H" "$W" "$(list_height "${prompt}"$'\n\n'"$TUI_HINT_RADIO")" "$@" \
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
    ui_geometry
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
        "$H" "$W" "$(list_height "${prompt}"$'\n\n'"${TUI_HINT_CHECK}")" "$@" \
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

ui_infobox() { [[ $UI == plain ]] && return 0; ui_geometry; tui --infobox "$1" "$(msg_height "$1")" "$MW"; }
step() { say "$*"; ui_infobox "$*"; }
