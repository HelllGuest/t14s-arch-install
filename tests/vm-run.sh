#!/usr/bin/env bash
# Headless UEFI qemu rehearsal for t14s-arch-install (NONINTERACTIVE minimal).
#
#   bash tests/vm-run.sh
#   FRESH=1 bash tests/vm-run.sh
#
# Serves this repo on 127.0.0.1:PORT, boots Arch ISO, drives serial console
# (qemu pipe) to run tests/vm-bootstrap.sh. Host disks untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=${WORK:-$HOME/arch-vmtest}
DISK="$WORK/test-disk.qcow2"
DISK_SIZE=${DISK_SIZE:-40G}
RAM=${RAM:-4096}
SMP=${SMP:-4}
PORT=${PORT:-8765}
ISO=${ISO:-$WORK/archlinux-x86_64.iso}
QEMU_IMG=${QEMU_IMG:-/usr/bin/qemu-img}
[[ -x $QEMU_IMG ]] || QEMU_IMG=qemu-img

say(){ printf '\e[1;34m>>\e[0m %s\n' "$*"; }
die(){ printf '\e[1;31mERR\e[0m %s\n' "$*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || die "need qemu-system-x86_64"
[[ -e /dev/kvm ]] || die "need /dev/kvm"
[[ -x $ROOT/install.sh ]] || die "missing $ROOT/install.sh"
[[ -x $ROOT/tests/vm-bootstrap.sh ]] || die "missing vm-bootstrap.sh"

ovmf_code=""; ovmf_vars_src=""
for c in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
         /usr/share/OVMF/OVMF_CODE.4m.fd; do
  [[ -f $c ]] && { ovmf_code="$c"; ovmf_vars_src="${c/CODE/VARS}"; break; }
done
[[ -n $ovmf_code && -f $ovmf_vars_src ]] || die "need edk2-ovmf (OVMF_CODE + VARS)"

mkdir -p "$WORK"

if [[ ! -f $ISO ]]; then
  say "downloading Arch ISO -> $ISO"
  curl -fSL --retry 3 --continue-at - -o "$ISO.partial" \
    https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
  mv -f "$ISO.partial" "$ISO"
fi
say "ISO: $ISO ($(du -h "$ISO" | awk '{print $1}'))"

[[ ${FRESH:-0} == 1 ]] && rm -f "$DISK"
if [[ ! -f $DISK ]]; then
  say "creating blank ${DISK_SIZE} disk"
  "$QEMU_IMG" create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
fi
cp -f "$ovmf_vars_src" "$WORK/OVMF_VARS.fd"

EXTRACT="$WORK/iso-boot"
mkdir -p "$EXTRACT"
K="$EXTRACT/vmlinuz-linux"
I="$EXTRACT/initramfs-linux.img"
if [[ ! -f $K || ! -f $I || $ISO -nt $K ]]; then
  say "extracting kernel/initrd from ISO"
  bsdtar -xOf "$ISO" arch/boot/x86_64/vmlinuz-linux >"$K"
  bsdtar -xOf "$ISO" arch/boot/x86_64/initramfs-linux.img >"$I"
fi
[[ -s $K && -s $I ]] || die "failed to extract kernel/initrd from ISO"
LABEL=$(blkid -o value -s LABEL "$ISO" 2>/dev/null || true)
[[ -n $LABEL ]] || LABEL=ARCH_202611
say "archisolabel=$LABEL"

PIPE="$WORK/guest-serial"
rm -f "$PIPE.in" "$PIPE.out"
QEMU_LOG="$WORK/qemu-serial.log"
: >"$QEMU_LOG"

cleanup() {
  kill "${HTTP_PID:-}" "${QEMU_PID:-}" "${TEE_PID:-}" 2>/dev/null || true
  rm -f "$PIPE.in" "$PIPE.out"
}
trap cleanup EXIT

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" \
  >/tmp/t14s-vm-http.log 2>&1 &
HTTP_PID=$!
sleep 1
curl -fsS --max-time 3 "http://127.0.0.1:$PORT/install.sh" >/dev/null \
  || die "http.server failed (see /tmp/t14s-vm-http.log)"
say "serving $ROOT on 127.0.0.1:$PORT guest=10.0.2.2:$PORT"

# Pre-create pipe ends. Open RDWR so open(2) never blocks (Linux FIFO rule).
mkfifo "$PIPE.in" "$PIPE.out"
exec 3<>"$PIPE.in" 4<>"$PIPE.out"
# Tee guest output into the log (read from FD 4 copy via /proc or cat pipe.out).
cat <&4 | tee -a "$QEMU_LOG" >/dev/null &
TEE_PID=$!

APPEND="archisobasedir=arch archisolabel=${LABEL} cow_spacesize=2G console=ttyS0,115200n8"
say "launching headless qemu (serial pipe)"
say "full pacstrap - expect 20-60+ minutes"

qemu-system-x86_64 \
  -enable-kvm -cpu host -m "$RAM" -smp "$SMP" -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file="$ovmf_code" \
  -drive if=pflash,format=raw,file="$WORK/OVMF_VARS.fd" \
  -drive file="$DISK",if=virtio,format=qcow2 \
  -cdrom "$ISO" \
  -kernel "$K" -initrd "$I" -append "$APPEND" \
  -netdev user,id=n0 -device virtio-net,netdev=n0 \
  -display none \
  -serial pipe:"$PIPE" \
  -monitor none \
  -no-reboot \
  >/tmp/t14s-vm-qemu-stdout.log 2>"$WORK/qemu-stderr.log" &
QEMU_PID=$!

say "waiting for archiso login prompt"
ok_login=0
for i in $(seq 1 180); do
  if grep -a -q 'archiso login:' "$QEMU_LOG" 2>/dev/null; then
    ok_login=1
    break
  fi
  kill -0 "$QEMU_PID" 2>/dev/null || die "qemu died before login (see $WORK/qemu-stderr.log)"
  sleep 2
done
(( ok_login == 1 )) || die "never saw archiso login prompt"

say "logging in over serial and starting bootstrap"
# Arch ISO: user root, empty password. Use CR for getty.
# Root shell may be zsh (eats first key after prompt) — drop into bash --norc.
{
  printf 'root\r'
  sleep 2
  printf '\r'
  sleep 4
  printf 'bash --norc --noprofile\r'
  sleep 2
  printf 'export T14S_VM_PORT=%s\r' "$PORT"
  sleep 1
  printf 'curl -fsSL http://10.0.2.2:%s/tests/vm-bootstrap.sh | bash; echo T14S_VM_DONE=$?\r' "$PORT"
} >&3

say "waiting for installer to finish (up to 90 min)"
deadline=$((SECONDS + 5400))
result=""
while (( SECONDS < deadline )); do
  if grep -a -q 'T14S_VM_RESULT=PASS' "$QEMU_LOG"; then result=PASS; break; fi
  if grep -a -q 'T14S_VM_RESULT=FAIL' "$QEMU_LOG"; then result=FAIL; break; fi
  if grep -a -q 'T14S_VM_DONE=0' "$QEMU_LOG"; then result=PASS; break; fi
  if grep -a -qE 'T14S_VM_DONE=[1-9]' "$QEMU_LOG"; then result=FAIL; break; fi
  kill -0 "$QEMU_PID" 2>/dev/null || { result=DEAD; break; }
  sleep 15
done

if kill -0 "$QEMU_PID" 2>/dev/null; then
  printf 'poweroff\r' >&3 || true
  for i in $(seq 1 30); do
    kill -0 "$QEMU_PID" 2>/dev/null || break
    sleep 2
  done
  kill "$QEMU_PID" 2>/dev/null || true
fi
wait "$QEMU_PID" 2>/dev/null || true
QEMU_PID=

if [[ $result == PASS ]]; then
  say "PASS: VM install reported success"
  grep -a -E 'DefaultZone=|T14S_VM_RESULT=|INSTALL COMPLETE|firewalld configured|ok ' "$QEMU_LOG" | tail -40
  exit 0
fi

say "FAIL: result=${result:-TIMEOUT} - last 100 serial lines:"
tail -c 20000 "$QEMU_LOG" | tr -cd '\11\12\15\40-\176' | tail -n 100
exit 1
