# 22-install-base.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Mirrors, package prefetch, pacstrap.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 6. base install ─────────────────────────────────────────
case ${HW_PROFILE:-t14s} in
  p15) UCODE=intel-ucode ;;
  *)   UCODE=amd-ucode ;;
esac

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
else
  _rfl_rc=0
  run_progress "refreshing live mirrors (best-effort, ≤45s)" \
    timeout 45 reflector "${_reflector_args[@]}" || _rfl_rc=$?
  _rfl_n=$(grep -c '^Server' "$ML_TMP" || true)
  if (( _rfl_rc == 0 && _rfl_n >= 3 )); then
    cat "$ML_TMP" > /etc/pacman.d/mirrorlist   # keep existing inode/perms (0644)
    ok "mirrorlist refreshed ($_rfl_n mirrors)"
  else
    case $_rfl_rc in
      0) _rfl_why="returned only ${_rfl_n} mirror(s)" ;;
      124) _rfl_why="timed out after 45s" ;;
      *) _rfl_why="failed (exit $_rfl_rc)" ;;
    esac
    warn "reflector $_rfl_why — keeping current mirrorlist"
    # A bare warn line is drawn over by the download gauge right away.
    (( NONINTERACTIVE )) || ui_warn "Mirror refresh: reflector ${_rfl_why}.

Continuing with the ISO mirrorlist (every mirror, unranked). The installed
system keeps that list until reflector's first weekly run; after the first
boot you can refresh it now: sudo systemctl start reflector.service"
  fi
  unset -v _rfl_rc _rfl_n _rfl_why
fi
rm -f "$ML_TMP"
unset -v _reflector_args

# Live ISO pacman (pacstrap uses this file). Built-in downloader only:
# XferCommand makes pacman fetch one file at a time and ignore ParallelDownloads
# (old runs of this script added a curl XferCommand — drop it on re-runs).
# DisableDownloadTimeout keeps slow mirrors from aborting ("Operation too slow").
# Single pacstrap — no retry loop, which would re-run on a partially-populated
# root and hit 'conflicting files'. Retries happen in prefetch_pkgs (download only).
pacman_tune /etc/pacman.conf "$PACMAN_PARALLEL"

t14s_base_packages
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
# Downloads first, with retries (prefetch_pkgs); a mirror that resets
# connections mid-download used to abort the whole install here.
run_gauge "downloading packages ($UCODE base + extras) — retried on mirror errors" 0 50 \
  prefetch_pkgs /mnt/var/cache/pacman/pkg "${BASE_PKGS[@]}" ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"} \
  || die "package download failed after ${PREFETCH_TRIES:-4} attempts (network / mirrors) — nothing installed yet; re-run the installer"
run_gauge "pacstrap base system ($UCODE) — installing packages" 50 100 \
  pacstrap -K /mnt "${BASE_PKGS[@]}" ${EXTRA_PKGS[@]+"${EXTRA_PKGS[@]}"}

step "genfstab"
genfstab -U /mnt >> /mnt/etc/fstab
# add nofail to the /tmp line (failure must not block boot)
sed -i -E '/[[:space:]]\/tmp[[:space:]]+btrfs/ s/(subvol=\/?@tmp)/\1,nofail/' /mnt/etc/fstab || true
# ESP root-only: systemd-boot refuses a world-readable random-seed
# ("Mount point '/boot' … is world accessible, which is a security hole").
sed -i -E '/[[:space:]]\/boot[[:space:]]+vfat/ s/fmask=[0-7]+/fmask=0077/; /[[:space:]]\/boot[[:space:]]+vfat/ s/dmask=[0-7]+/dmask=0077/' /mnt/etc/fstab || true
ok "base installed"
