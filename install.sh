#!/usr/bin/env bash
# Globals are shared with lib/*.sh. Dynamic `_load_lib` uses source=/dev/null,
# so shellcheck cannot see those reads/writes (SC2034). CI also excludes SC2034.
# shellcheck disable=SC2034
# install.sh — interactive hardened Arch Stage A for ThinkPad T14s Gen 3 AMD
#               (21CQ/21CR) and ThinkPad P15 Gen 1 (20SU, Optimus NVIDIA).
#
# Modular layout (see README): helper functions live in lib/*.sh, the wizard
# and install stages in lib/steps/*.sh. This file is the curl-able
# orchestrator: it loads both from a local lib/ or fetches them from GitHub.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
#   T14S_LIB_DIR=./lib bash install.sh   # local/dev without network fetches
#
# Stack: LUKS2(argon2id) + Btrfs + linux-lts/hardened UKIs + systemd-boot +
#        sbctl Secure Boot + minimal GNOME + firewalld (nftables, default drop).
#        T14s: amd-ucode, amd_iommu/amd_pstate. P15: intel-ucode, nvidia modeset.
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

# ── library loader ──────────────────────────────────────────
# Prefer local lib/ (checkout or T14S_LIB_DIR). Only then resolve one commit for
# curl fetches (install.sh + every lib/*.sh share that SHA; no mixed tip).
# Override: T14S_REF=<sha|branch|tag>, T14S_BASE_URL=…, or local T14S_LIB_DIR.
T14S_LIB_DIR="${T14S_LIB_DIR:-}"
if [[ -z $T14S_LIB_DIR ]]; then
  _t14s_self="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [[ -n $_t14s_self && -d $_t14s_self/lib ]]; then
    T14S_LIB_DIR="$_t14s_self/lib"
  fi
  unset -v _t14s_self
fi
# Remote resolve only when libs must be fetched (local checkout stays offline).
if [[ -z $T14S_LIB_DIR && -z ${T14S_BASE_URL:-} ]]; then
  if [[ -z ${T14S_REF:-} ]]; then
    T14S_REF="$(curl -fsSL -H 'Accept: application/vnd.github.sha' \
      https://api.github.com/repos/HelllGuest/t14s-arch-install/commits/main 2>/dev/null || true)"
    T14S_REF="${T14S_REF//$'\n'/}"
    if [[ ! $T14S_REF =~ ^[0-9a-f]{40}$ ]]; then
      printf 'ERR: could not resolve t14s-arch-install main SHA (set T14S_REF or T14S_BASE_URL)\n' >&2
      exit 1
    fi
  fi
  T14S_BASE_URL="https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/${T14S_REF}"
fi
export T14S_REF="${T14S_REF:-}" T14S_BASE_URL="${T14S_BASE_URL:-}" T14S_LIB_DIR

# Defaults needed before any sourced lib runs say()/die under set -u
# (colors come from lib/00-common.sh, which loads first).
LOGGING=0
UI=${T14S_UI:-plain}
NONINTERACTIVE=0
LOG="$(mktemp /tmp/t14s-install.XXXXXX.log)"

# _lib_path FILE: set _LIB_PATH to lib/FILE (local checkout, or fetched once
# into a temp dir on the curl path). Sets a global instead of printing so the
# fetch dir survives (a $(…) subshell would lose T14S_LIB_FETCH_DIR).
_lib_path() {
  local f=$1
  if [[ -n ${T14S_LIB_DIR:-} && -f $T14S_LIB_DIR/$f ]]; then
    _LIB_PATH=$T14S_LIB_DIR/$f
    return 0
  fi
  if [[ -z ${T14S_LIB_FETCH_DIR:-} ]]; then
    T14S_LIB_FETCH_DIR="$(mktemp -d /tmp/t14s-lib.XXXXXX)"
  fi
  if [[ ! -f $T14S_LIB_FETCH_DIR/$f ]]; then
    mkdir -p "$(dirname "$T14S_LIB_FETCH_DIR/$f")"
    curl -fsSL "$T14S_BASE_URL/lib/$f" -o "$T14S_LIB_FETCH_DIR/$f" \
      || { printf 'ERR: failed to fetch lib/%s from %s\n' "$f" "$T14S_BASE_URL" >&2; exit 1; }
  fi
  _LIB_PATH=$T14S_LIB_FETCH_DIR/$f
}
# Function libraries only (definitions): sourcing inside a function is fine.
_load_lib() {
  _lib_path "$1"
  # shellcheck source=/dev/null
  source "$_LIB_PATH"
}

for _lib in 00-common.sh 10-ui.sh 11-ui-theme.sh 12-ui-screens.sh 13-ui-progress.sh \
            20-answers.sh 30-hardware.sh 40-disk.sh 50-packages.sh 70-firewall.sh; do
  _load_lib "$_lib"
done
unset -v _lib

# ── globals / session ───────────────────────────────────────
# Parse before any (( DRYRUN )): raw env text in arithmetic can run $(…), and an
# unrecognized value must never fall through to a real install.
_dr=${T14S_DRYRUN:-0}
case ${_dr,,} in
  0 | n | no | off | false) DRYRUN=0 ;;
  1 | y | yes | on | true) DRYRUN=1 ;;
  *) printf 'T14S_DRYRUN=%q not recognized (use 1 or 0)\n' "$_dr" >&2; exit 2 ;;
esac
unset -v _dr
# Accept 1/y/yes/on (case-insensitive) for env toggles — same spirit as yn_on.
_env_on() { local v=${1,,}; [[ $v == 1 || $v == y || $v == yes || $v == on ]]; }
if _env_on "${T14S_NONINTERACTIVE:-0}"; then NONINTERACTIVE=1; else NONINTERACTIVE=0; fi
ANSWERS_IN=${T14S_ANSWERS:-}
PASS_FILE=${T14S_PASS_FILE:-}
if _env_on "${T14S_I_WILL_ERASE:-0}"; then WILL_ERASE=1; else WILL_ERASE=0; fi
if _env_on "${T14S_ALLOW_NON_ISO:-0}"; then ALLOW_NON_ISO=1; else ALLOW_NON_ISO=0; fi
if _env_on "${T14S_POST_HOOK_I_UNDERSTAND:-0}"; then POST_HOOK_CONSENT=1; else POST_HOOK_CONSENT=0; fi
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


# _on_err RC LINE CMD: name the file that failed (a stage, or install.sh itself;
# `bash <(curl …)` runs it as /dev/fd/N). $? is passed in first: any $(…) in
# the trap string would reset it before the message is built.
_on_err() {
  local rc=$1 line=$2 cmd=$3 src=${BASH_SOURCE[1]:-install.sh}
  [[ $src == /dev/fd/* || $src == /proc/* ]] && src=install.sh
  die "failed at ${src##*/}:$line (exit $rc): $cmd" "$rc"
}
trap '_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
T14S_DIED=0
trap 'on_exit $?' EXIT

# ── stages ──────────────────────────────────────────────────
# Wizard (01-12: questions only; no disk is touched before 12-review's DRYRUN
# exit and Erase confirm), then the install (20-30). Each stage is sourced
# here at top level, not inside a function, so its globals stay global.
for _t14s_step in \
    01-preflight.sh 02-welcome.sh 03-hardware.sh 04-answers.sh 05-profile.sh \
    06-disk.sh 07-partition.sh 08-luks.sh 09-identity.sh 10-downloads.sh \
    11-extras.sh 12-review.sh 20-install-disk.sh 21-install-filesystems.sh \
    22-install-base.sh 23-install-chroot.sh 30-finish.sh; do
  _lib_path "steps/$_t14s_step"
  # shellcheck source=/dev/null
  source "$_LIB_PATH"
done
unset -v _t14s_step
