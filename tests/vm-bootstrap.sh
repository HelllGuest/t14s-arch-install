#!/usr/bin/env bash
# Runs inside the Arch ISO guest (root). Fetched via archiso script= URL.
# Host serves the t14s-arch-install tree at http://10.0.2.2:${HOST_PORT:-8000}/
set -euo pipefail

HOST="${T14S_VM_HOST:-10.0.2.2}"
PORT="${T14S_VM_PORT:-8000}"
BASE="http://${HOST}:${PORT}"
DISK="${T14S_VM_DISK:-/dev/vda}"
LOG=/tmp/t14s-vm-install.log
RESULT=/tmp/t14s-vm-result.txt

exec > >(tee -a "$LOG") 2>&1
echo "=== t14s VM bootstrap $(date -Is) ==="
echo "BASE=$BASE DISK=$DISK"

# Wait for DHCP / DNS
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "$BASE/install.sh" >/dev/null; then
    break
  fi
  sleep 2
done
curl -fsS --max-time 10 "$BASE/install.sh" >/dev/null \
  || { echo "FAIL: cannot reach $BASE/install.sh"; echo FAIL >"$RESULT"; exit 1; }

# Answers + secrets (minimal preset; verify firewalld + ssh path)
cat >/tmp/t14s-answers.env <<EOF
DISK=$DISK
MODE=auto
ESP_MB=2048
HOSTNAME=t14s-vm
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
USERNAME=t14svm
PRESET=minimal
DESKTOP=N
ENABLE_SSHD=Y
FW_SYNCTHING=N
FW_KDECONNECT=N
LUKS_WIPE=none
PACMAN_PARALLEL=5
BTRFS_COMPRESS=zstd3
ZRAM_SIZE=half
SKIP_THINKPAD_HW=Y
SKIP_REFLECTOR=Y
CLEAN_ESP_ARCH=Y
INSTALL_SELFTEST=Y
EOF
cat >/tmp/t14s-pass.env <<'EOF'
LUKS_PASS=vmtest-luks-pass-change-me
USER_PASS=vmtest-user-pass-change-me
ROOT_PASS=vmtest-root-pass-change-me
EOF
chmod 600 /tmp/t14s-answers.env /tmp/t14s-pass.env

export T14S_BASE_URL="$BASE"
export T14S_UI=plain
export T14S_NONINTERACTIVE=1
export T14S_I_WILL_ERASE=1
export T14S_ANSWERS=/tmp/t14s-answers.env
export T14S_PASS_FILE=/tmp/t14s-pass.env
export T14S_ANSWERS_OUT=/tmp/t14s-answers.out

echo "=== starting installer ==="
set +e
bash <(curl -fsSL "$BASE/install.sh")
rc=$?
set -e
echo "=== installer exit $rc ==="

# Quick post-chroot probes while still in ISO (target mounted? cleanup may umount)
if [[ -d /mnt/etc/firewalld ]]; then
  grep -H '^DefaultZone=' /mnt/etc/firewalld/firewalld.conf || true
  ls /mnt/etc/firewalld/zones 2>/dev/null | head || true
fi
if [[ -x /mnt/usr/bin/firewall-offline-cmd ]] || [[ -x /mnt/usr/bin/firewall-cmd ]]; then
  arch-chroot /mnt firewall-offline-cmd --list-all 2>/dev/null | head -40 || true
fi

if (( rc == 0 )); then
  echo PASS >"$RESULT"
  # Drop a marker on the ESP so host can inspect after reboot if needed
  if mountpoint -q /mnt/boot 2>/dev/null || mount /dev/disk/by-label/EFI /mnt/boot 2>/dev/null; then
    echo "t14s-vm PASS $(date -Is)" >/mnt/boot/t14s-vm-pass.txt 2>/dev/null || true
  fi
else
  echo FAIL >"$RESULT"
fi

# Print result on serial for the host harness
echo "T14S_VM_RESULT=$(cat "$RESULT")"
exit "$rc"
