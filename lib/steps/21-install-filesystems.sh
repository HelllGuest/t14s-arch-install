# 21-install-filesystems.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# LUKS2 format, Btrfs subvolumes, mounts.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── 5. encrypt + filesystems ────────────────────────────────
step "LUKS2 format (argon2id) on $ROOT_PART"
wipefs -a "$ROOT_PART" >/dev/null 2>&1 || true   # clear stale signatures (dirty/reused disk)
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode "$ROOT_PART" -
printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
unset -v LUKS_PASS
LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"   # LUKS header UUID (for rd.luks.name)
[[ -n $LUKS_UUID ]] || die "could not read LUKS UUID from $ROOT_PART"
ok "LUKS open as /dev/mapper/cryptroot (LUKS UUID=$LUKS_UUID)"

# Optional full-volume wipe before mkfs; then btrfs subvols + ESP mount.
apply_luks_wipe
do_btrfs_and_mount
