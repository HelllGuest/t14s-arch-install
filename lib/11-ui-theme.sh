# 11-ui-theme.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# TUI colours: whiptail NEWT_COLORS palettes and per-severity dialogrc files.

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
gauge_color = (CYAN,BLUE,ON)
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
