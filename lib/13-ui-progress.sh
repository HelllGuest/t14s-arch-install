# 13-ui-progress.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Install-phase logging and live progress (progress box, gauge, plain stream).

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
  ui_geometry
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
    # whiptail leaves its last box on screen: clear it, or the live output
    # scrolls underneath a stale "Continue" box.
    [[ $UI != plain ]] && printf '\e[H\e[2J' >/dev/tty
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
  ui_geometry
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
