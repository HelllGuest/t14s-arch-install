#!/usr/bin/env bash
# install.sh — interactive hardened Arch install for ThinkPad T14s Gen 3 AMD
#               (machine type 21CQ / 21CR; example MTM 21CRS1PU00)
#
# Target: Rembrandt-U (Ryzen 5/7 PRO 6650U/6850U), soldered LPDDR5, amdgpu,
#         Wi-Fi 6E, 57Wh, s2idle.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
#
# Stack: LUKS2(argon2id) + Btrfs + linux-lts/hardened UKIs + systemd-boot +
#        sbctl Secure Boot + minimal GNOME. AMD defaults: amd-ucode,
#        amd_iommu=on, amd_pstate=active. Hostname default: thinkpad-t14s.
#
# BIOS (F1): Secure Boot off for install; Sleep State = "Windows and Linux"
# (s2idle); enable AMD SVM + IOMMU. Re-enable Secure Boot after sbctl enroll.
#
# RUN FROM THE ARCH ISO (live environment), as root, UEFI mode, with internet.
# THIS ERASES DATA on the partitions you select. Reads prompts from /dev/tty.
set -euo pipefail

# ── ui helpers ──────────────────────────────────────────────
c0=$'\e[0m'; cR=$'\e[1;31m'; cG=$'\e[1;32m'; cY=$'\e[1;33m'; cB=$'\e[1;34m'
say()  { printf '%s>>%s %s\n' "$cB" "$c0" "$*"; }
ok()   { printf '%s ok%s %s\n' "$cG" "$c0" "$*"; }
warn() { printf '%s !!%s %s\n' "$cY" "$c0" "$*" >&2; }
die()  { printf '%sERR%s %s\n' "$cR" "$c0" "$*" >&2; exit 1; }
trap 'die "failed at line $LINENO"' ERR

ask()       { local p="$1" d="${2:-}" v; read -r  -p "$p" v </dev/tty || true; printf '%s' "${v:-$d}"; }
ask_secret(){ local p="$1" v; read -rs -p "$p" v </dev/tty || true; printf '\n' >&2; printf '%s' "$v"; }
confirm()   { local v; read -r -p "${1:-proceed?} [type YES] " v </dev/tty || true; [[ $v == YES ]]; }

part_of() { # $1 disk, $2 num -> partition path (nvme/mmc need 'p')
  local d="$1" n="$2"
  [[ $d == *nvme* || $d == *mmcblk* || $d == *loop* ]] && printf '%sp%s' "$d" "$n" || printf '%s%s' "$d" "$n"
}

# ── 0. preflight ────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "run as root (from the Arch ISO)"
[[ -d /sys/firmware/efi/efivars ]] || die "not booted in UEFI mode — enable UEFI and reboot the ISO"
{ ping -c1 -W3 archlinux.org || curl -fsS --max-time 6 https://archlinux.org; } >/dev/null 2>&1 \
  || die "no internet — connect first (iwctl / dhcp), then re-run"
timedatectl set-ntp true || true
say "preflight ok (UEFI + network + ntp)"

# clean leftover state from a previous interrupted run so re-runs start fresh
# (otherwise an open cryptroot / mounted /mnt keeps the disk busy → sgdisk/mkfs
#  can't reformat → stale files survive → pacstrap 'conflicting files')
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

cat <<EOF

${cR}╔══════════════════════════════════════════════════════════════╗
║  T14s Gen 3 AMD ARCH INSTALLER — DESTROYS DATA ON DISK        ║
╚══════════════════════════════════════════════════════════════╝${c0}
Machine: ThinkPad T14s Gen 3 AMD (Type 21CQ/21CR) — Rembrandt + amdgpu
Stack:   LUKS2 + Btrfs(+@tmp) + linux-lts/hardened + UKI + systemd-boot
         + minimal GNOME + zram + AppArmor + UFW + Snapper + Secure Boot
EOF

# Soft DMI check — Gen 3 AMD types only (21CQ/21CR). VM / off-hardware: confirm.
_dmi="$(cat /sys/class/dmi/id/product_family /sys/class/dmi/id/product_version \
          /sys/class/dmi/id/product_name /sys/class/dmi/id/product_sku 2>/dev/null \
        | tr '\n' ' ')"
if ! echo "$_dmi" | grep -qiE '21CQ|21CR'; then
  warn "DMI is not T14s Gen 3 AMD type 21CQ/21CR: ${_dmi:-unknown}"
  warn "Continue only if intentional (VM rehearsal / forced). Wrong machine? Abort."
  confirm "continue on this hardware anyway?" || die "aborted — this installer is for type 21CQ/21CR only"
fi
ok "target profile: T14s Gen 3 AMD (21CQ/21CR)"

# ── 1. choose disk ──────────────────────────────────────────
say "block devices:"; lsblk -dpo NAME,SIZE,MODEL | grep -vE 'loop|sr0' || true
DISK="$(ask 'Target disk (e.g. /dev/nvme0n1): ')"
[[ -b $DISK ]] || die "not a block device: $DISK"

# ── 2. partition strategy ───────────────────────────────────
echo
say "partition mode:"
echo "  1) AUTO  — wipe ALL of $DISK, create 2G EFI + LUKS root"
echo "  2) MANUAL — pick existing partitions (EFI optional: format or reuse)"
MODE="$(ask 'choose [1/2]: ' 1)"

FORMAT_EFI=1
if [[ $MODE == 1 ]]; then
  warn "AUTO mode ERASES the ENTIRE disk $DISK — including any Windows / other-OS partitions on it."
  lsblk "$DISK" || true
  echo "Type the disk path to confirm total wipe:"
  [[ "$(ask 'confirm disk: ')" == "$DISK" ]] || die "disk confirmation mismatch — aborting"
  confirm "ERASE $DISK now?" || die "aborted"
  say "partitioning $DISK (GPT: 2G ESP + LUKS)"
  sgdisk --zap-all "$DISK" >/dev/null
  sgdisk -n1:0:+2G   -t1:ef00 -c1:EFI       "$DISK" >/dev/null
  sgdisk -n2:0:0     -t2:8309 -c2:cryptroot "$DISK" >/dev/null
  partprobe "$DISK"; udevadm settle 2>/dev/null || sleep 2
  EFI_PART="$(part_of "$DISK" 1)"
  ROOT_PART="$(part_of "$DISK" 2)"
else
  say "current layout:"; lsblk -po NAME,SIZE,FSTYPE,PARTTYPENAME "$DISK" || true
  ROOT_PART="$(ask 'ROOT partition to LUKS-format (e.g. /dev/nvme0n1p2): ')"
  [[ -b $ROOT_PART ]] || die "not a partition: $ROOT_PART"
  echo "EFI options:  1) format a partition as ESP   2) reuse existing ESP (no format — multiboot)"
  EFIMODE="$(ask 'choose [1/2]: ' 2)"
  EFI_PART="$(ask 'EFI partition (e.g. /dev/nvme0n1p1): ')"
  [[ -b $EFI_PART ]] || die "not a partition: $EFI_PART"
  [[ $EFI_PART != "$ROOT_PART" ]] || die "EFI and ROOT cannot be the same partition"
  [[ $EFIMODE == 2 ]] && FORMAT_EFI=0
  efifs="$(lsblk -no FSTYPE "$EFI_PART" 2>/dev/null | head -1)"
  if [[ $FORMAT_EFI == 0 ]]; then
    # reuse: must already be a FAT ESP — never format a shared/multiboot ESP
    [[ $efifs == vfat ]] || die "reuse needs an existing FAT32 ESP — $EFI_PART is '${efifs:-empty}'. Use option 1 to format, or pick the real ESP."
    say "reuse ESP $EFI_PART (FAT, kept). Existing /EFI entries (other OSes stay bootable):"
    _m="$(mktemp -d)"
    if mount -o ro "$EFI_PART" "$_m" 2>/dev/null; then
      find "$_m/EFI" -maxdepth 1 -mindepth 1 2>/dev/null | sed 's,^,   ,' || true
      umount "$_m" || true
    fi
    rmdir "$_m" 2>/dev/null || true
  else
    # format mode: hard-warn if the target already looks like a live ESP
    [[ $efifs == vfat ]] && warn "DANGER: $EFI_PART is ALREADY FAT — likely a shared ESP. Formatting ERASES other OSes' bootloaders."
  fi
  warn "ROOT $ROOT_PART will be ERASED (LUKS format)."
  [[ $FORMAT_EFI == 1 ]] && warn "EFI $EFI_PART will be FORMATTED (FAT32)." || say "EFI $EFI_PART will be REUSED (kept, multiboot-safe)."
  confirm "proceed with these partitions?" || die "aborted"
fi
ok "EFI=$EFI_PART  ROOT=$ROOT_PART  (format_efi=$FORMAT_EFI)"

# ── 3. luks passphrase ──────────────────────────────────────
while :; do
  LUKS_PASS="$(ask_secret 'LUKS passphrase: ')"
  LUKS_PASS2="$(ask_secret 'repeat passphrase: ')"
  [[ -n $LUKS_PASS && $LUKS_PASS == "$LUKS_PASS2" ]] && break
  warn "empty or mismatch — retry"
done

# ── 4. identity ─────────────────────────────────────────────
HOSTNAME="$(ask 'hostname: ' thinkpad-t14s)"
TIMEZONE="$(ask 'timezone (Region/City): ' America/New_York)"
LOCALE="$(ask 'locale: ' en_US.UTF-8)"
KEYMAP="$(ask 'console keymap: ' us)"
USERNAME="$(ask 'username: ')"
while :; do
  USER_PASS="$(ask_secret "password for $USERNAME: ")"
  USER_PASS2="$(ask_secret 'repeat: ')"
  [[ -n $USER_PASS && $USER_PASS == "$USER_PASS2" ]] && break; warn "mismatch — retry"
done
while :; do
  ROOT_PASS="$(ask_secret 'root password: ')"
  ROOT_PASS2="$(ask_secret 'repeat: ')"
  [[ -n $ROOT_PASS && $ROOT_PASS == "$ROOT_PASS2" ]] && break; warn "mismatch — retry"
done

DESKTOP="$(ask 'install minimal GNOME desktop? [Y/n]: ' Y)"
ENROLL_SB="$(ask 'enroll Secure Boot keys now if firmware in Setup Mode? [y/N]: ' N)"

# ── 5. encrypt + filesystems ────────────────────────────────
say "LUKS2 format (argon2id) on $ROOT_PART"
wipefs -a "$ROOT_PART" >/dev/null 2>&1 || true   # clear stale signatures (dirty/reused disk)
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode "$ROOT_PART" -
printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"   # LUKS header UUID (for rd.luks.name)
[[ -n $LUKS_UUID ]] || die "could not read LUKS UUID from $ROOT_PART"
ok "LUKS open as /dev/mapper/cryptroot (LUKS UUID=$LUKS_UUID)"

say "btrfs + subvolumes"
mkfs.btrfs -f -L archroot /dev/mapper/cryptroot >/dev/null
mount /dev/mapper/cryptroot /mnt
for sv in @ @home @snapshots @var_log @var_cache @tmp; do btrfs subvolume create "/mnt/$sv" >/dev/null; done
chattr +C /mnt/@tmp 2>/dev/null || true   # nodatacow inheritance
umount /mnt

CO="noatime,compress=zstd:3,ssd,space_cache=v2"
mount -o "$CO,subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,var/log,var/cache,tmp,boot}
mount -o "$CO,subvol=@home"      /dev/mapper/cryptroot /mnt/home
mount -o "$CO,subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount -o "$CO,subvol=@var_log"   /dev/mapper/cryptroot /mnt/var/log
mount -o "$CO,subvol=@var_cache" /dev/mapper/cryptroot /mnt/var/cache
mount -o "noatime,nodatacow,nosuid,nodev,subvol=@tmp" /dev/mapper/cryptroot /mnt/tmp
chmod 1777 /mnt/tmp

if [[ $FORMAT_EFI == 1 ]]; then
  say "format ESP $EFI_PART"
  wipefs -a "$EFI_PART" >/dev/null 2>&1 || true   # clear stale fs signatures that confuse blkid/mount
  mkfs.fat -F32 -n EFI "$EFI_PART"                 # show output — surface real errors
  sync
fi
udevadm settle 2>/dev/null || true
mount -t vfat "$EFI_PART" /mnt/boot                # explicit type: don't rely on auto-detect
esp_mb=$(df -Pm /mnt/boot | awk 'NR==2{print $2}'); esp_mb=${esp_mb:-0}
(( esp_mb >= 1024 )) || warn "ESP is ${esp_mb}MB — dual-kernel UKIs want >=1024MB; install may fill it"
# defensive: drop leftover Arch boot files from a prior install so pacstrap won't hit
# 'conflicting files' (Arch-specific names only — other /EFI/* loaders stay intact)
say "cleaning prior Arch boot artifacts on ESP"
rm -f /mnt/boot/intel-ucode.img /mnt/boot/amd-ucode.img \
      /mnt/boot/vmlinuz-linux* /mnt/boot/initramfs-linux* \
      /mnt/boot/EFI/Linux/arch-linux*.efi 2>/dev/null || true
if [[ -d /mnt/boot/loader/entries ]]; then
  find /mnt/boot/loader/entries -maxdepth 1 -type f \
    \( -name 'arch*.conf' -o -name 'linux-*.conf' \) -delete 2>/dev/null || true
fi
ok "filesystems mounted (ESP ${esp_mb}MB)"

# ── 6. base install ─────────────────────────────────────────
# This installer targets Rembrandt AMD — default amd-ucode. Warn on non-AMD (VM).
UCODE=amd-ucode
if ! grep -q AuthenticAMD /proc/cpuinfo; then
  warn "CPU is not AuthenticAMD — still pacstrapping amd-ucode. VM rehearsal OK."
fi

say "refreshing live mirrors (best-effort)"
reflector --latest 20 --protocol https --sort rate --download-timeout 5 \
  --save /etc/pacman.d/mirrorlist 2>/dev/null || warn "reflector skipped — using current mirrorlist"

# Robust downloads: route pacman through curl with retries + resume and NO
# low-speed abort, so a slow mirror stalls but doesn't kill the transaction
# (the default libcurl path aborts with "Operation too slow"). Failover across
# the 20 reflector mirrors still applies. Single pacstrap — no retry loop, which
# would re-run on a partially-populated root and hit 'conflicting files'.
if ! grep -q '^XferCommand' /etc/pacman.conf; then
  sed -i '/^\[options\]/a XferCommand = /usr/bin/curl -fL -C - -o %o %u --retry 5 --retry-connrefused --connect-timeout 15' /etc/pacman.conf
fi

BASE_PKGS=(
  base base-devel
  linux-lts linux-lts-headers linux-hardened linux-hardened-headers
  linux-firmware "$UCODE"
  btrfs-progs cryptsetup
  bluez bluez-utils
  networkmanager sudo zsh git vim nano
  reflector pacman-contrib
  mkinitcpio snapper snap-pac zram-generator
  apparmor ufw sbctl efibootmgr
)
say "pacstrap base system ($UCODE)"
pacstrap -K /mnt "${BASE_PKGS[@]}"

say "genfstab"
genfstab -U /mnt >> /mnt/etc/fstab
# add nofail to the /tmp line (failure must not block boot)
sed -i -E '/[[:space:]]\/tmp[[:space:]]+btrfs/ s/(subvol=\/?@tmp)/\1,nofail/' /mnt/etc/fstab || true
ok "base installed"

# ── 7. chroot configuration ─────────────────────────────────
say "writing chroot config"
cat > /mnt/root/chroot-setup.sh <<'CHROOT'
#!/usr/bin/env bash
set -euo pipefail
say(){ printf '\e[1;34m>>\e[0m %s\n' "$*"; }

# time / locale / keymap
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc
sed -i "s/^#\(${LOCALE} \)/\1/" /etc/locale.gen
grep -q "^${LOCALE} " /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# hostname / hosts
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# users
echo "root:${ROOT_PASS}" | chpasswd
id "$USERNAME" &>/dev/null || useradd -m -G wheel -s /bin/zsh "$USERNAME"
echo "${USERNAME}:${USER_PASS}" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# initramfs (systemd + sd-encrypt for LUKS)
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# kernel cmdline (shared by both UKIs)
mkdir -p /etc/kernel
# AMD Rembrandt: amd_iommu + amd_pstate (no intel_iommu / i915). BIOS Sleep =
# "Windows and Linux" pairs with mem_sleep_default=s2idle.
echo "rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet loglevel=3 mem_sleep_default=s2idle apparmor=1 security=apparmor amd_iommu=on amd_pstate=active" > /etc/kernel/cmdline

# UKI presets: linux-lts (primary) + linux-hardened (fallback)
# reuse ESP: clear stale UKIs + loader entries before rebuild (multiboot-safe names)
if [[ ${FORMAT_EFI:-1} == 0 ]]; then
  say "reuse ESP — removing old Arch UKIs and loader entries"
  rm -f /boot/EFI/Linux/arch-linux*.efi 2>/dev/null || true
  if [[ -d /boot/loader/entries ]]; then
    find /boot/loader/entries -maxdepth 1 -type f \
      \( -name 'arch*.conf' -o -name 'linux-*.conf' \) -delete 2>/dev/null || true
  fi
fi
mkdir -p /boot/EFI/Linux
cat > /etc/mkinitcpio.d/linux-lts.preset <<EOF
# ALL_kver is REQUIRED — mkinitcpio reads the kernel version from this vmlinuz.
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-lts"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-lts.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-lts-fallback.efi"
fallback_options="-S autodetect"
EOF
cat > /etc/mkinitcpio.d/linux-hardened.preset <<EOF
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-hardened"
PRESETS=('default' 'fallback')
default_uki="/boot/EFI/Linux/arch-linux-hardened.efi"
default_options=""
fallback_uki="/boot/EFI/Linux/arch-linux-hardened-fallback.efi"
fallback_options="-S autodetect"
EOF
say "building UKIs"
mkinitcpio -P
# drop redundant non-UKI initramfs left by the pacstrap install hook — UKI-only
# presets won't regenerate them, so this frees ESP space permanently.
rm -f /boot/initramfs-linux-lts.img /boot/initramfs-linux-lts-fallback.img \
      /boot/initramfs-linux-hardened.img /boot/initramfs-linux-hardened-fallback.img

# bootloader — when reusing a shared/multiboot ESP, back up another OS's fallback
# loader first. On a freshly-formatted ESP there's nothing to preserve (no clutter).
say "systemd-boot"
if [[ ${FORMAT_EFI:-1} == 0 && -f /boot/EFI/BOOT/BOOTX64.EFI ]]; then
  cp -n /boot/EFI/BOOT/BOOTX64.EFI /boot/EFI/BOOT/BOOTX64.EFI.pre-arch.bak 2>/dev/null || true
  say "backed up existing /EFI/BOOT/BOOTX64.EFI -> .pre-arch.bak"
fi
bootctl install
# inform: coexisting loaders systemd-boot will auto-detect (Windows, other Linux)
find /boot/EFI -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's,^,   loader dir: ,' || true
cat > /boot/loader/loader.conf <<EOF
default arch-linux-lts.efi
timeout 3
editor no
console-mode max
EOF

# zram (RAM/2 cap 16G — T14s often ships 16–32G soldered LPDDR5)
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 16384)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# sysctl hardening
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
# userns: needed for Flatpak/Podman under linux-hardened; '-' = ignore on LTS (key absent)
echo '-kernel.unprivileged_userns_clone = 1' > /etc/sysctl.d/99-userns.conf

# firewall — set ENABLED=yes so it's active on first boot (rule-apply may warn in chroot)
ufw default deny incoming
ufw default allow outgoing
ufw --force enable >/dev/null 2>&1 || true
grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null || sed -i 's/^ENABLED=.*/ENABLED=yes/' /etc/ufw/ufw.conf 2>/dev/null || true

# reflector mirrors
cat > /etc/xdg/reflector/reflector.conf <<EOF
--latest 10
--protocol https
--sort rate
--save /etc/pacman.d/mirrorlist
EOF

# pacman niceties
sed -i 's/^#Color/Color/; s/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf

# services
systemctl enable NetworkManager apparmor ufw bluetooth fstrim.timer reflector.timer \
                 systemd-tmpfiles-clean.timer

# snapper config for / (handle pre-existing @snapshots mount) — non-fatal
umount /.snapshots 2>/dev/null || true
rmdir  /.snapshots 2>/dev/null || true
if snapper --no-dbus -c root create-config /; then
  btrfs subvolume delete /.snapshots 2>/dev/null || true
  mkdir -p /.snapshots; mount -a || true; chmod 750 /.snapshots
  systemctl enable snapper-timeline.timer snapper-cleanup.timer
else
  say "WARN: snapper create-config failed — skipping snapshots (configure post-boot)"
  mkdir -p /.snapshots; mount -a || true
fi

# minimal GNOME (optional)
if [[ ${DESKTOP^^} != N* ]]; then
  say "installing minimal GNOME + browsers + VPN + software center"
  # sof-firmware+alsa-ucm-conf: Rembrandt audio. fprintd: power-button match-on-chip
  # FP (D-Bus-activated — do NOT systemctl enable). No Yoga tablet / iio rotate.
  # browsers + proton-vpn: Flatpak. gnome-software: Flatpak software center.
  # Non-fatal: a network hiccup here must not abort an otherwise-bootable base system.
  if pacman -S --noconfirm --needed --disable-download-timeout \
    gnome-shell gnome-session gdm gnome-control-center gnome-keyring \
    gnome-backgrounds nautilus gnome-console gnome-text-editor \
    gnome-system-monitor gnome-calculator loupe evince gnome-disk-utility \
    xdg-user-dirs-gtk xdg-desktop-portal xdg-desktop-portal-gnome polkit \
    flatpak fwupd bolt pipewire pipewire-pulse wireplumber earlyoom \
    power-profiles-daemon \
    sof-firmware alsa-ucm-conf fprintd \
    gnome-software
  then
    systemctl enable gdm bolt.service earlyoom.service power-profiles-daemon
    mkdir -p /etc/gdm
    printf '[daemon]\nWaylandEnable=true\n' > /etc/gdm/custom.conf
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    # One install per app: a single failure must not abort the rest. Extra-data apps
    # (Chrome) need bwrap user namespaces, which the kernel refuses inside a chroot;
    # drop any half-installed ref so you can retry after first boot.
    failed_fp=()
    for app in com.brave.Browser app.zen_browser.zen com.google.Chrome \
               io.gitlab.librewolf-community com.protonvpn.www; do
      if ! flatpak install --system -y --noninteractive flathub "$app"; then
        failed_fp+=("$app")
        flatpak uninstall --system -y --noninteractive "$app" >/dev/null 2>&1 || true
        flatpak info --system "$app" >/dev/null 2>&1 || rm -rf "/var/lib/flatpak/app/$app"
      fi
    done
    if (( ${#failed_fp[@]} )); then
      say "WARN: flatpak install failed: ${failed_fp[*]}"
      say "      retry after first boot: flatpak install --system -y flathub <app>"
    fi
  else
    say "WARN: GNOME install incomplete (network?) — base system is fine. Finish post-boot:"
    say "      pacman -S gnome-shell gdm && systemctl enable gdm"
  fi
fi

# Secure Boot: create + sign now; enroll post-reboot (needs firmware Setup Mode)
say "sbctl: create keys + sign"
sbctl create-keys
for f in /boot/EFI/Linux/arch-linux-lts.efi /boot/EFI/Linux/arch-linux-lts-fallback.efi \
         /boot/EFI/Linux/arch-linux-hardened.efi /boot/EFI/Linux/arch-linux-hardened-fallback.efi \
         /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI; do
  [[ -f $f ]] && sbctl sign -s "$f" || true
done
if [[ ${ENROLL_SB^^} == Y* ]] && sbctl status 2>/dev/null | grep -qi 'setup mode.*enabled'; then
  say "enrolling Secure Boot keys (-m)"; sbctl enroll-keys -m || echo "enroll failed — do it post-reboot"
fi
sbctl verify || true
CHROOT

chmod +x /mnt/root/chroot-setup.sh
say "running chroot config"
arch-chroot /mnt env \
  TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" KEYMAP="$KEYMAP" HOSTNAME="$HOSTNAME" \
  USERNAME="$USERNAME" USER_PASS="$USER_PASS" ROOT_PASS="$ROOT_PASS" \
  LUKS_UUID="$LUKS_UUID" DESKTOP="$DESKTOP" ENROLL_SB="$ENROLL_SB" FORMAT_EFI="$FORMAT_EFI" \
  bash /root/chroot-setup.sh

shred -u /mnt/root/chroot-setup.sh 2>/dev/null || rm -f /mnt/root/chroot-setup.sh
ok "chroot config complete"

# ── 8. finish ───────────────────────────────────────────────
say "unmounting"
umount -R /mnt
cryptsetup close cryptroot

cat <<EOF

${cG}╔══════════════════════════════════════════════════════════════╗
║  T14s Gen 3 AMD — INSTALL COMPLETE                            ║
╚══════════════════════════════════════════════════════════════╝${c0}
 • Reboot, remove the ISO:   ${cY}reboot${c0}
 • Boot menu: Arch Linux (LTS) default · Hardened as fallback.
 • Verify after boot: ${cY}lscpu | grep -i ryzen${c0} · ${cY}cat /sys/power/mem_sleep${c0}
   (expect s2idle bracketed; BIOS Sleep = Windows and Linux).
 • Secure Boot: keys created + binaries signed. To ENABLE:
     1) BIOS → clear Secure Boot keys → Setup Mode
     2) booted OS:  ${cY}sudo sbctl enroll-keys -m${c0}
     3) BIOS → Secure Boot → Enabled   (pacman hook auto-resigns on updates)
     ${cY}multiboot:${c0} '-m' keeps Microsoft keys so Windows still boots; other
     unsigned Linux loaders won't boot under SB until you 'sbctl sign' them.
 • linux-hardened + Flatpak/Podman: userns sysctl already set (99-userns.conf).
 • Hostname: ${cY}${HOSTNAME}${c0}
 • First login via GDM (Wayland). Post-boot checks:
     ${cY}lscpu | grep -i ryzen${c0}
     ${cY}cat /sys/power/mem_sleep${c0}
     ${cY}grep -E 'amd_iommu|amd_pstate' /proc/cmdline${c0}
 • Optional rice/dotfiles: ${cY}https://github.com/HelllGuest/dotfiles${c0}
EOF
ok "done — reboot when ready"
