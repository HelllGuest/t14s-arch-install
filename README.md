# t14s-arch-install

Hardened **Arch Linux** installer for **Lenovo ThinkPad T14s Gen 3 AMD**
(machine type **21CQ / 21CR**; example MTM `21CRS1PU00`).

One curl-able script (`install.sh`). Interactive TUI by default; unattended
with answers + a secrets file. Profile is fixed for Rembrandt (not a generic
Arch installer).

UX ideas adapted from [archfi](https://github.com/MatMoul/archfi) and
[archdi-pkg](https://github.com/MatMoul/archdi-pkg). Not ported: i18n packs,
DE zoo, AUR helpers, iptables (UFW kept), multi-bootloader/FS, BIOS modes.

---

## What and why (short)

| Goal | Choice | Why |
| ---- | ------ | --- |
| Encrypt disk | LUKS2 + argon2id | Modern default; strong KDF |
| Filesystem | Btrfs subvols + Snapper | Snapshots / rollbacks |
| Kernels | `linux-lts` UKI + `linux-hardened` UKI | Stable daily driver + hardened fallback |
| Boot | systemd-boot + `sbctl` | Simple EFI; Secure Boot ready |
| Desktop | Optional minimal GNOME Wayland | Optional; Rembrandt GPU/audio/FP wired when on |
| Laptop power | Charge window 70–80; PPD or TLP | Battery longevity; no TLP under GNOME |
| Host hardening | AppArmor, UFW, sysctl, zram | Useful defaults without DIY |

---

## Always installed (base)

Pacstrapped into the new root every run:

| Package / piece | Role |
| --------------- | ---- |
| `base` `base-devel` | Minimal Arch userland + build tools |
| `linux-lts` (+ headers) | Primary kernel → UKI |
| `linux-hardened` (+ headers) | Fallback kernel → UKI |
| `linux-firmware` `amd-ucode` | Firmware + AMD microcode (Rembrandt) |
| `btrfs-progs` `cryptsetup` | Btrfs + LUKS |
| `bluez` `bluez-utils` | Bluetooth stack |
| `networkmanager` | Network (enabled) |
| `sudo` `zsh` `git` `vim` `nano` | Admin shell defaults (user shell = zsh) |
| `reflector` `pacman-contrib` | Mirror refresh (live + weekly timer) |
| `mkinitcpio` | UKI / initramfs build |
| `snapper` `snap-pac` | Root snapshots (+ pacman hooks) |
| `zram-generator` | Compressed RAM swap |
| `apparmor` `ufw` | MAC + firewall (enabled) |
| `sbctl` `efibootmgr` | Secure Boot keys / EFI boot entries |
| `xdg-user-dirs` | `~/Downloads` etc. via `xdg-user-dirs-update` |

**Always configured (not always “a package”):**

* GPT layout (AUTO) or selected parts (MANUAL)
* LUKS2 on root; Btrfs subvolumes
  `@` `@home` `@snapshots` `@var_log` `@var_cache` `@tmp` (`@tmp` = nodatacow)
* Mount options: `compress=` from wizard (`zstd3` default)
* Kernel cmdline: `rd.luks.name=…`, `amd_iommu=on`, `amd_pstate=active`,
  `mem_sleep_default=s2idle`, AppArmor
* systemd-boot; UKIs under `/boot/EFI/Linux/`
* Sysctl hardening (`99-security.conf` + Flatpak userns for hardened)
* ThinkPad charge 70–80 (tmpfiles + oneshot) unless `SKIP_THINKPAD_HW=Y` (VMs)

---

## Optional adds (wizard / answers)

Defaults come from preset **`gnome`** / **`dev`** / **`minimal`**, then checklists.

### Core checklist

| Toggle | Adds / does | Why |
| ------ | ----------- | --- |
| GNOME | Shell, GDM, portals, PipeWire, Flatpak browsers/VPN, `mesa`/`vulkan-radeon`, sof audio; `fprintd` unless VM skip | Usable Rembrandt laptop desktop |
| Nerd Fonts | Curated `ttf-*-nerd` + Inter/Noto; GNOME mono font | Readable terminals / editors |
| Enroll sbctl now | `sbctl enroll-keys -m` if Setup Mode **and** `sbctl verify` OK | Optional first-boot SB |
| sshd | `openssh` + UFW 22/tcp | Remote rescue |
| CUPS | `cups` `cups-pdf` `ghostscript` | Printing |
| Skip reflector | Keep ISO mirrorlist | Flaky/offline networks |
| TLP | `tlp` (forced off if GNOME) | Console-only power mgmt |
| thinkfan note | `/root/t14s-thinkfan.txt` (AUR; not pacstrapped) | Fan control hint |
| Snapper `@home` | `snapper -c home` | Home snapshots |
| `linux` stable UKI | `linux` + headers + third UKI pair | Optional bleeding kernel |
| Plymouth | `plymouth` + mkinitcpio hook + `splash` | Optional splash |
| Self-test | `/usr/local/bin/t14s-selftest` | BT / audio / wifi / AppArmor / UFW check |
| Chrome helper | `~/install-chrome-flatpak.sh` | Chrome needs post-boot Flatpak userns |

### Dev / CLI checklist

| Toggle | Adds |
| ------ | ---- |
| CLI bundle | `ripgrep` `fd` `fzf` `bat` `eza` `jq` `git-delta` |
| starship | Prompt + wire into user `.zshrc` |
| podman | `podman` `buildah` (rootless) |
| docker | `docker` `docker-compose`; user in `docker` group |
| virt | `libvirt` `qemu-desktop` `virt-manager` …; user in `libvirt` |
| extras | Optional: htop, tmux, rsync, bash-completion, wget, usbutils, lsof, dmidecode, powertop, mc, traceroute, bind, smartmontools |

### Network checklist

| Toggle | Adds |
| ------ | ---- |
| avahi | `avahi` `nss-mdns` + `nsswitch` mdns |
| wireguard | `wireguard-tools` |
| tailscale | `tailscale` (enabled) |
| fail2ban | `fail2ban` + sshd jail |
| UFW Syncthing / KDE Connect | Port allows only |

Free-form: `T14S_EXTRA_PKGS='pkg1 pkg2'` or the “more packages” prompt.

---

## Modified (live ISO + new system)

| Where | Change | Why |
| ----- | ------ | --- |
| Live ISO `pacman.conf` | `XferCommand` curl retries; `ParallelDownloads` | Reliable pacstrap |
| Live mirrors | Optional `reflector` (country optional) | Faster/fresher mirrors |
| Target `/etc/mkinitcpio.conf` | systemd + `sd-encrypt` (+ plymouth if chosen) | LUKS unlock in UKI |
| Target `/etc/kernel/cmdline` | Rembrandt + LUKS + s2idle + AppArmor | One cmdline for all UKIs |
| Target `/etc/fstab` | UUID mounts; `/tmp` gets `nofail` | Boot even if `@tmp` fails |
| Target pacman / reflector.conf | ParallelDownloads; weekly reflector | Same mirror story post-boot |
| Target UFW | deny in / allow out; enabled | Firewall on first boot |
| Target sudoers | `%wheel` enabled | User admin |
| ESP | Format or reuse; stale Arch UKIs cleaned on reuse | Multiboot-safe |
| Answers files | `/tmp/t14s-answers.env` + `/root/t14s-answers.env` mode `0600` | Replay installs |

---

## Removed / cleaned

| Action | Why |
| ------ | --- |
| `wipefs` + LUKS format on ROOT (and ESP if format) | Clean install surface |
| Optional LUKS mapper `dd` wipe | Paranoia before `mkfs.btrfs` |
| AUTO: entire disk GPT rewrite | Single-disk dedicated install |
| Non-UKI `initramfs-*.img` after UKI build | Free ESP space |
| Stale `arch-linux*.efi` / old loader entries on ESP reuse | Avoid dual-boot clutter |
| `/root/.t14s-install-secrets` + chroot script shredded | Passwords not left on disk |
| Chrome Flatpak **not** installed in chroot | bwrap userns fails in chroot |

---

## Requirements

* Arch ISO, **UEFI**, root shell, working network
* Soft DMI check for **21CQ / 21CR** (confirm or NONINTERACTIVE warn-and-continue)
* **AuthenticAMD** (same)
* Disk with ESP + ≥8 GB root (AUTO = whole disk; MANUAL = pick parts)
* Shared ESP: existing FAT32, ideally ≥1 GB

## BIOS (F1)

* Secure Boot: **Disabled** for install (enroll later)
* Sleep: **Windows and Linux** (s2idle)
* AMD **SVM** + **IOMMU** on

---

## Run (from the Arch ISO)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
```

Prefer `bash <(curl …)` so menus keep a real TTY.
UI order: **`dialog`** → `whiptail` → plain. Override: `T14S_UI=dialog|whiptail|plain`.

### Screens

1. Hardware warnings (DMI / AMD)
2. Profile preset: `gnome` / `dev` / `minimal`
3. Disk + SMART hint
4. AUTO / MANUAL partitioning
5. LUKS passphrase + optional mapper wipe
6. Hostname, timezone, locale, keymap
7. User + passwords
8. ParallelDownloads, Btrfs compress, zram size
9. Core / Dev / Network checklists
10. Reflector country (if not skipped), hook preset, extra packages
11. REVIEW → confirm → answers saved

### Unattended

```bash
T14S_NONINTERACTIVE=1 \
T14S_ANSWERS=/path/to/t14s-answers.env \
T14S_PASS_FILE=/path/to/secrets.env \   # mode 0600; LUKS_PASS USER_PASS ROOT_PASS
T14S_POST_HOOK_I_UNDERSTAND=1 \         # only if POST_HOOK_URL set
bash install.sh
```

Skips: DMI/AMD confirms, AUTO type-DISK wipe confirm, REVIEW UI, final start
confirm (plan still logged). MANUAL parts must sit on `DISK`; ESP ≥512 MB,
ROOT ≥8 GB. Flags (`Y`/`N`/`on`/`1`) become `Y`/`N` before chroot.

Hook preset: none / `T14S_DEFAULT_HOOK_URL` / custom HTTPS URL (no private
repo URL is hardcoded).

### Answers schema (known keys)

`PRESET` `DESKTOP` `INSTALL_*` · `ENROLL_SB` `ENABLE_SSHD` `SKIP_REFLECTOR`
`UFW_SYNCTHING` `UFW_KDECONNECT` `POST_HOOK_URL` · `PACMAN_PARALLEL` `LUKS_WIPE`
`HOSTNAME` `TIMEZONE` `LOCALE` `KEYMAP` `USERNAME` · `MODE` `ESP_MB`
`FORMAT_EFI` `DISK` `EFI_PART` `ROOT_PART` · `BTRFS_COMPRESS`
(`zstd1`/`zstd3`/`zstd15`/`none`) · `ZRAM_SIZE` (`half`/`quarter`/`8192`) ·
`REFLECTOR_COUNTRY` · `SKIP_THINKPAD_HW` (auto `Y` in VMs). Prefer `Y`/`N`.
Passwords are **never** stored in answers.

### Message severity

Colored message / confirm boxes. Theme base: dark blue screen, cyan chrome,
yellow focus. Each severity swaps chrome for both backends (**per-severity**
`DIALOGRC` / `NEWT_COLORS`):

| Severity   | When used                                       | Chrome     |
| ---------- | ----------------------------------------------- | ---------- |
| **info**   | help, review, reuse notes                       | cyan       |
| **warn**   | banner, bad input, small ESP/root               | yellow     |
| **error**  | invalid device/path                             | red        |
| **critical** | wipe/ESP danger, hard gates, fatal `die`      | red+yellow |
| **ok**     | install complete                                | green      |

### Controls

* Arrows move; **Space** toggles; **Enter** accepts; **Tab** to buttons
* **Esc** / Cancel aborts that menu (and the install if required)
* Menus offer **[log]** and **[help]**; log: `/tmp/t14s-install.*.log`
* MANUAL reuse: any partition listed; only FAT32 validates as ESP

**AUTO mode erases the entire disk.** Interactive mode requires typing the
disk path and a second wipe confirm.

### Safety model

Nothing destructive runs before the final confirm (NONINTERACTIVE: confirm
skipped after answers + secrets are validated). Log: `/tmp/t14s-install.*.log`.
Long steps use `dialog --progressbox` when available. Passwords enter chroot
via a `0600` secrets file (not env), then shred. UKI build fails if ESP free
space is under 64 MB. `sbctl verify` must pass before enroll.

Stuck on pacstrap? Other TTY (`Ctrl+Alt+F2`): `tail -f /tmp/t14s-install.*.log`

---

## After first boot

```bash
reboot   # remove the ISO
lscpu | grep -i ryzen
cat /sys/power/mem_sleep          # expect [s2idle]
grep -E 'amd_iommu|amd_pstate' /proc/cmdline
# ThinkPad only — missing on a VM is normal
cat /sys/class/power_supply/BAT0/charge_control_start_threshold  # 70
cat /sys/class/power_supply/BAT0/charge_control_end_threshold    # 80
systemctl status thinkpad-charge-thresholds.service --no-pager
t14s-selftest   # if that option was enabled
```

Same notes land in `/root/t14s-post-install.txt`.

* **GNOME:** GDM Wayland. Chrome: Flatpak helper or
  `flatpak install --system -y flathub com.google.Chrome`
* **No GNOME:** getty login; later
  `pacman -S gnome-shell gdm flatpak && systemctl enable gdm`

### Secure Boot (optional)

1. BIOS → clear keys → Setup Mode  
2. `sudo sbctl enroll-keys -m`  
3. BIOS → Secure Boot → Enabled  

`-m` keeps Microsoft keys (Windows multiboot).

---

## Rehearse in a VM

Installer-only repo. If you already have a UEFI qemu harness that can feed
this script:

```bash
INSTALLER=install.sh scripts/arch-install-vmtest.sh
```

Or dry-run menus only (no disk writes) from a normal shell:

```bash
T14S_DRYRUN=1 bash install.sh
```

`T14S_DRYRUN=1` skips root/UEFI/network checks and does **not**
`umount`/`swapoff`/`cryptsetup close`. Still needs a TTY for menus.
NONINTERACTIVE VM runs auto-set `SKIP_THINKPAD_HW=Y`.

---

## Develop / CI

```bash
bash -n install.sh
bash tests/smoke.test.sh

T14S_DRYRUN=1 bash install.sh
T14S_UI=whiptail|dialog|plain bash install.sh
T14S_EXTRA_PKGS='htop tmux' bash install.sh
T14S_ANSWERS=/tmp/t14s-answers.env bash install.sh
T14S_PASS_FILE=/root/t14s-pass.env   # chmod 600
T14S_DEFAULT_HOOK_URL=https://…      # optional hook preset
T14S_NONINTERACTIVE=1 T14S_ANSWERS=… T14S_PASS_FILE=… bash install.sh
```

GitHub Actions: smoke + shellcheck on push.

## License

MIT — see [LICENSE](LICENSE).
