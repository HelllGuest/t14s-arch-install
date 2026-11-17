#!/usr/bin/env bash
# Dual-boot reinstall rehearsal (VM_BOOTSTRAP=tests/vm-dual-bootstrap.sh
# bash tests/vm-run.sh): builds a T14s-like disk (shared ESP with Windows
# files, MSR, NTFS C:, recovery, old Arch LUKS, a stale "Linux Boot Manager"
# firmware entry), runs a MANUAL install reusing the ESP, then checks that
# Windows is untouched, old Arch artifacts are gone and the firmware boots Arch.
# Synthetic files only; runs inside the Arch ISO guest (root).
set -uo pipefail
{
exec </dev/null
BASE="http://10.0.2.2:${T14S_VM_PORT:-8000}"
D=/dev/vda
exec > >(tee -a /tmp/dual.log) 2>&1
v() { if "$@"; then echo "DUALCHK PASS: ${CHK}"; else echo "DUALCHK FAIL: ${CHK}"; FAILS=$((FAILS+1)); fi; }
FAILS=0
for _ in $(seq 1 60); do curl -fsS --max-time 3 "$BASE/install.sh" >/dev/null && break; sleep 2; done

echo "=== prep: T14s-like layout ==="
sgdisk -Z $D >/dev/null
sgdisk -n1:0:+2800M -t1:ef00 -c1:EFI -n2:0:+16M -t2:0c01 -n3:0:+3G -t3:0700 -c3:Windows \
       -n4:0:+1G -t4:2700 -c4:Recovery -n5:0:0 -t5:8300 $D
partprobe $D; udevadm settle; sleep 1
mkfs.fat -F32 -n EFI ${D}1 >/dev/null
mkfs.ntfs -Q -L Windows ${D}3 >/dev/null; mkfs.ntfs -Q -L Recovery ${D}4 >/dev/null
head -c 16M /dev/urandom >${D}2
mkdir -p /m && mount ${D}1 /m
mkdir -p /m/EFI/Microsoft/Boot /m/EFI/Microsoft/Recovery /m/EFI/BOOT /m/EFI/Linux /m/loader/entries /m/EFI/arch /m/EFI/systemd
head -c 1500K /dev/urandom >/m/EFI/Microsoft/Boot/bootmgfw.efi
head -c 64K /dev/urandom >/m/EFI/Microsoft/Boot/BCD
head -c 32K /dev/urandom >/m/EFI/Microsoft/Recovery/BCD
cp /m/EFI/Microsoft/Boot/bootmgfw.efi /m/EFI/BOOT/BOOTX64.EFI
head -c 40M /dev/urandom >/m/EFI/Linux/arch-linux-lts.efi
head -c 40M /dev/urandom >/m/EFI/Linux/arch-linux-hardened.efi
printf 'title old arch\nlinux /vmlinuz-linux\n' >/m/loader/entries/arch.conf
printf 'default arch.conf\ntimeout 9\n' >/m/loader/loader.conf
head -c 1M /dev/urandom >/m/vmlinuz-linux; head -c 1M /dev/urandom >/m/initramfs-linux.img
head -c 100K /dev/urandom >/m/amd-ucode.img; head -c 100K /dev/urandom >/m/EFI/arch/grubx64.efi
(cd /m && find EFI/Microsoft -type f -exec sha256sum {} + | sort) >/tmp/ms.sha
sha256sum /m/EFI/BOOT/BOOTX64.EFI | cut -d' ' -f1 >/tmp/fallback.sha
sha256sum /m/EFI/Linux/arch-linux-lts.efi | cut -d' ' -f1 >/tmp/oldlts.sha
sha256sum /m/amd-ucode.img | cut -d' ' -f1 >/tmp/olducode.sha
umount /m
sha256sum ${D}2 ${D}3 ${D}4 >/tmp/parts.sha
printf 'old-arch-pass' | cryptsetup luksFormat --batch-mode --type luks2 ${D}5 - >/dev/null
cryptsetup luksUUID ${D}5 >/tmp/olduuid
efibootmgr -q -c -d $D -p 1 -L "Windows Boot Manager" -l '\EFI\Microsoft\Boot\bootmgfw.efi'
# Stale entry from an earlier install on another partition (must be removed).
efibootmgr -q -c -d $D -p 4 -L "Linux Boot Manager" -l '\EFI\systemd\systemd-bootx64.efi'
lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL $D

cat >/tmp/t14s-answers.env <<A
DISK=$D
MODE=manual
EFI_PART=${D}1
ROOT_PART=${D}5
FORMAT_EFI=0
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
A
cat >/tmp/t14s-pass.env <<'P'
LUKS_PASS=vmtest-luks-pass-change-me
USER_PASS=vmtest-user-pass-change-me
ROOT_PASS=vmtest-root-pass-change-me
P
chmod 600 /tmp/t14s-answers.env /tmp/t14s-pass.env
export T14S_BASE_URL="$BASE" T14S_UI=plain T14S_NONINTERACTIVE=1 T14S_I_WILL_ERASE=1 \
  T14S_ANSWERS=/tmp/t14s-answers.env T14S_PASS_FILE=/tmp/t14s-pass.env T14S_ANSWERS_OUT=/tmp/t14s-answers.out
echo "=== starting installer (MANUAL, reuse ESP) ==="
bash <(curl -fsSL "$BASE/install.sh"); rc=$?
echo "=== installer exit $rc ==="

echo "=== verify ==="
umount -R /mnt 2>/dev/null; cryptsetup close cryptroot 2>/dev/null
mount -o ro ${D}1 /m
CHK="installer exit 0"; v test "$rc" -eq 0
CHK="Windows EFI/Microsoft files byte-identical"; v diff <(cd /m && find EFI/Microsoft -type f -exec sha256sum {} + | sort) /tmp/ms.sha
CHK="MSR/NTFS C:/Recovery partitions byte-identical"; v sha256sum -c --quiet /tmp/parts.sha
CHK="original fallback BOOTX64.EFI kept as .pre-arch.bak"; v test "$(sha256sum /m/EFI/BOOT/BOOTX64.EFI.pre-arch.bak | cut -d' ' -f1)" = "$(cat /tmp/fallback.sha)"
CHK="BOOTX64.EFI is now systemd-boot"; v cmp -s /m/EFI/BOOT/BOOTX64.EFI /m/EFI/systemd/systemd-bootx64.efi
CHK="old Arch loader entry removed"; v test ! -e /m/loader/entries/arch.conf
CHK="old Arch EFI/arch dir removed"; v test ! -e /m/EFI/arch
CHK="old bare kernel/initramfs removed"; v test ! -e /m/vmlinuz-linux -a ! -e /m/initramfs-linux.img
# amd-ucode.img is shipped again by the amd-ucode package: it must be the new file.
CHK="old amd-ucode.img replaced"; v test "$(sha256sum /m/amd-ucode.img 2>/dev/null | cut -d' ' -f1)" != "$(cat /tmp/olducode.sha)"
CHK="new linux-lts UKI (not the old file)"; v bash -c 'f=$(ls /m/EFI/Linux/arch-linux-lts*.efi | head -1) && [ "$(sha256sum "$f" | cut -d" " -f1)" != "$(cat /tmp/oldlts.sha)" ]'
CHK="new linux-hardened UKI"; v bash -c 'ls /m/EFI/Linux/arch-linux-hardened*.efi >/dev/null'
CHK="old loader.conf kept as .pre-arch.bak"; v grep -q 'timeout 9' /m/loader/loader.conf.pre-arch.bak
echo "--- ESP free: $(df -h /m | awk 'NR==2{print $4" of "$2}')"; ls -la /m/EFI/Linux; cat /m/loader/loader.conf
umount /m
CHK="root re-encrypted (new LUKS2 UUID)"; v bash -c '[ "$(cryptsetup luksUUID '${D}5')" != "$(cat /tmp/olduuid)" ] && cryptsetup isLuks --type luks2 '${D}5
CHK="new LUKS opens with new passphrase only"; v bash -c "printf vmtest-luks-pass-change-me | cryptsetup open --test-passphrase ${D}5 - && ! printf old-arch-pass | cryptsetup open --test-passphrase ${D}5 - 2>/dev/null"
efibootmgr -v | grep -iE 'windows|linux|boot0' | head
CHK="NVRAM Windows Boot Manager entry kept"; v bash -c 'efibootmgr | grep -q "Windows Boot Manager"'
ESP_UUID=$(lsblk -dno PARTUUID ${D}1)
CHK="NVRAM Linux Boot Manager on the reused ESP, first in BootOrder"
v bash -c 'o=$(efibootmgr); id=$(grep -iE "^Boot[0-9A-F]{4}\*? +Linux Boot Manager.*GPT,'"$ESP_UUID"',.*systemd-bootx64.efi" <<<"$o" | head -1 | cut -c5-8); [ -n "$id" ] && grep -q "^BootOrder: $id" <<<"$o"'
CHK="stale Linux Boot Manager entry (other partition) removed"
v bash -c '! efibootmgr | grep -i "Linux Boot Manager" | grep -viq "'"$ESP_UUID"'"'
echo "DUALCHK FAILS=$FAILS"
(( rc == 0 && FAILS == 0 )) && echo T14S_VM_RESULT=PASS || echo T14S_VM_RESULT=FAIL
}
