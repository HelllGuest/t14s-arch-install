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
| Clean ESP Arch | Remove old Arch UKIs, `arch*`/`linux-*` loader entries, `EFI/arch` | Reinstall / multiboot hygiene (default on). Kernels/ucode always cleared. Never touches Windows/other OS dirs |
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
| ESP | Format or reuse; optional Arch cleanup (`CLEAN_ESP_ARCH`) | Multiboot-safe; frees UKI space |
| Answers files | `/tmp/t14s-answers.env` + `/root/t14s-answers.env` mode `0600` | Replay installs |

---

## Removed / cleaned

| Action | Why |
| ------ | --- |
| `wipefs` + LUKS format on ROOT (and ESP if format) | Clean install surface |
| Optional LUKS mapper `dd` wipe | Paranoia before `mkfs.btrfs` |
| AUTO: entire disk GPT rewrite | Single-disk dedicated install |
| Non-UKI `initramfs-*.img` after UKI build | Free ESP space |
| Stale Arch UKIs / `loader/entries` / `EFI/arch` (when `CLEAN_ESP_ARCH=Y`) | Avoid dual Arch boots; free ESP |
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

**Destructive.** Missing or invalid answers never open a TUI — the script
`die`s. Ambient `LUKS_PASS` / `USER_PASS` / `ROOT_PASS` env is ignored
(prevents `/proc` leaks); secrets come only from `T14S_PASS_FILE`.

```bash
T14S_NONINTERACTIVE=1 \
T14S_I_WILL_ERASE=1 \                   # required for AUTO or MANUAL wipe
T14S_ANSWERS=/path/to/t14s-answers.env \
T14S_PASS_FILE=/path/to/secrets.env \   # must be mode 0600
T14S_POST_HOOK_I_UNDERSTAND=1 \         # only if POST_HOOK_URL set
bash install.sh
```

Required in answers: `DISK`, `MODE`, identity (`HOSTNAME` `TIMEZONE` `LOCALE`
`KEYMAP` `USERNAME`), and for AUTO also `ESP_MB` (`1024|2048|4096`). MANUAL
also needs `EFI_PART` / `ROOT_PART` on that same `DISK` (ESP ≥512 MB,
ROOT ≥8 GB). `FORMAT_EFI` optional (`0` reuse / `1` format; default `1`).
`LUKS_WIPE` must be `none|fast|normal` (default `none`).
`PACMAN_PARALLEL` / `BTRFS_COMPRESS` / `ZRAM_SIZE` optional but must be valid
if set (defaults `10` / `zstd3` / `half`).

Skips (after validation): DMI/AMD confirms, type-DISK / partition proceed
confirms, REVIEW UI, final start confirm (plan still logged). Flags accept
`y`/`yes`/`on`/`1` (not `yellow`); saved as `Y`/`N`. Extra pacstrap packages
replay via `EXTRA_PKGS_LIST` (space-separated) and/or `T14S_EXTRA_PKGS`.

Hook preset: none / `T14S_DEFAULT_HOOK_URL` / custom HTTPS URL (no private
repo URL is hardcoded).

### Answers schema (known keys)

`PRESET` `DESKTOP` `INSTALL_*` · `ENROLL_SB` `ENABLE_SSHD` `SKIP_REFLECTOR`
`UFW_SYNCTHING` `UFW_KDECONNECT` `POST_HOOK_URL` · `PACMAN_PARALLEL` `LUKS_WIPE`
`HOSTNAME` `TIMEZONE` `LOCALE` `KEYMAP` `USERNAME` · `MODE` `ESP_MB`
`FORMAT_EFI` `DISK` `EFI_PART` `ROOT_PART` · `BTRFS_COMPRESS`
(`zstd1`/`zstd3`/`zstd15`/`none`) · `ZRAM_SIZE` (`half`/`quarter`/`8192`) ·
`REFLECTOR_COUNTRY` · `SKIP_THINKPAD_HW` (auto `Y` in VMs) ·
`CLEAN_ESP_ARCH` (default `Y`: remove old Arch UKIs, `arch*.conf` /
`linux-*.conf` loader entries, and `EFI/arch` dirs; kernels/ucode always
cleared to avoid pacstrap conflicts; never touches Windows/other OS dirs) ·
`EXTRA_PKGS_LIST`. Prefer `Y`/`N`. Passwords are **never** stored in answers.
`answers_save` hard-requires mode `0600`.

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

Interactive: nothing destructive before the final confirm. Unattended: wipe
starts after answers + `T14S_PASS_FILE` + `T14S_I_WILL_ERASE=1` validate (no
confirm UI). Log: `/tmp/t14s-install.*.log`. Long steps use
`dialog --progressbox` when available. Passwords enter chroot via a `0600`
file (not env), then shred. UKI build fails if ESP free space is under 64 MB.
`sbctl verify` must pass before enroll.

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

* **GNOME:** GDM Wayland. Chrome helper (if enabled) uses
  `flatpak install --user -y flathub com.google.Chrome`
  (system-wide also fine: `flatpak install --system -y flathub com.google.Chrome`)
* **No GNOME:** getty login; later
  `pacman -S gnome-shell gdm flatpak && systemctl enable gdm`

---

## ESP / EFI layout (why files look “scattered”)

The ESP is **FAT**. UEFI, systemd-boot, and UKIs each use **fixed** paths.
That is normal, not installer clutter.

| Path on ESP | Role | Who owns it |
| ----------- | ---- | ----------- |
| `EFI/Linux/arch-linux-*.efi` | Unified Kernel Images | mkinitcpio UKI presets |
| `EFI/systemd/systemd-bootx64.efi` | systemd-boot binary | `bootctl install` |
| `EFI/BOOT/BOOTX64.EFI` | Removable / fallback loader | Firmware default path |
| `loader/loader.conf` | Default entry, timeout | systemd-boot (ESP root) |
| `loader/entries/*.conf` | Classic type-1 entries | Legacy / other tools |

**Leftovers from older installs:**

| Path | When removed | Typical source |
| ---- | ------------ | -------------- |
| ESP root `vmlinuz-linux*`, `initramfs-linux*`, `*-ucode.img` | **Always** (pacstrap safety) | Pre-UKI / bare kernel on ESP |
| `EFI/Linux/arch*.efi` | `CLEAN_ESP_ARCH=Y` | Prior Arch UKIs |
| `EFI/arch/` (also `Arch` / `ARCH`) | `CLEAN_ESP_ARCH=Y` | Old GRUB vendor dir |
| `loader/entries/arch*.conf` / `linux-*.conf` | `CLEAN_ESP_ARCH=Y` | Pre-UKI systemd-boot (**note:** `linux-*.conf` matches any distro using that name on a shared ESP) |

### Can everything live under one directory?

**No**, not with stock systemd-boot + UKIs:

* Firmware expects `EFI/BOOT/BOOTX64.EFI`.
* systemd-boot expects `EFI/systemd/` and `loader/` at the ESP root.
* UKI convention is `EFI/Linux/*.efi` (other paths need hand-written entries).

You can put UKIs under e.g. `EFI/arch/` only with custom `loader/entries`
and more update fragility. This installer keeps the standard layout and uses
`CLEAN_ESP_ARCH` so **old Arch junk** does not pile up across dirs.
Windows / other OS vendor dirs are never touched.

### `CLEAN_ESP_ARCH` (Core checklist, default `Y`)

| Always removed (pacstrap safety) | Also removed when `CLEAN_ESP_ARCH=Y` |
| -------------------------------- | ----------------------------------- |
| `vmlinuz-linux*`, `initramfs-linux*` | `EFI/Linux/arch*.efi` UKIs |
| `amd-ucode.img`, `intel-ucode.img` | `loader/entries` matching `arch*.conf` or `linux-*.conf` |
| | `EFI/arch`, `EFI/Arch`, `EFI/ARCH` |

Fresh-format ESP already empty (`FORMAT_EFI=1` forces `CLEAN_ESP_ARCH=Y`).
`CLEAN_ESP_ARCH=N` keeps prior Arch UKIs/entries; kernels/ucode still cleared.
Does not remove `EFI/Microsoft`, `EFI/ubuntu`, or other non-Arch vendor dirs.

---

## Securing the EFI (ESP)

The ESP is readable FAT. You **cannot** LUKS-encrypt it the way root is
encrypted. Security is a **signed boot chain** + locked firmware + LUKS for
data.

### What this installer already does

* Builds UKIs and signs them with **`sbctl`** (plus systemd-boot / `BOOTX64.EFI`)
* Optional enroll when Setup Mode is on **and** `sbctl verify` passes
* LUKS2 on root; no secrets written to the ESP
* Optional Arch ESP cleanup (`CLEAN_ESP_ARCH`)

### After first boot (recommended)

1. BIOS: clear Secure Boot keys → **Setup Mode** (if not already)
2. In the installed OS:

```bash
sbctl status
sbctl verify
# Only when Setup Mode is enabled and verify is clean:
sudo sbctl enroll-keys -m
```

3. BIOS: Secure Boot → **Enabled**; set a **supervisor** password; prefer
   internal NVMe first; disable unused USB/network boot if policy allows

`-m` keeps Microsoft keys so Windows can still boot on a shared ESP. Other
unsigned Linux loaders will not boot under SB until signed, e.g.
`sudo sbctl sign -s /path/to/loader.efi` (installer uses `sbctl sign -s`).

### After kernel / boot updates

Pacman hooks from `sbctl` should resign UKIs. If something fails to boot or
verify looks wrong:

```bash
sudo sbctl verify
sudo sbctl sign-all          # resign everything sbctl tracks
# or: sudo sbctl sign -s /boot/EFI/Linux/arch-linux-lts.efi
```

### Do / don’t

| Do | Don’t |
| -- | ----- |
| Enable SB after enroll | Leave Setup Mode / SB off “for convenience” |
| Keep BIOS supervisor password | Put LUKS passphrases or keyfiles on the ESP |
| Run `sbctl verify` after big updates | Assume ESP paths are secret (they are not) |
| Use `CLEAN_ESP_ARCH` on reinstall | Wipe `EFI/Microsoft` / other OS dirs by hand unless you mean it |

### Stronger options (not in this script)

* TPM2 PCR-bound LUKS (`systemd-cryptenroll` / Clevis) — less typing, harder recovery
* Boot from a separate USB ESP — smaller local attack surface, worse UX

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
T14S_NONINTERACTIVE=1 T14S_I_WILL_ERASE=1 \
  T14S_ANSWERS=… T14S_PASS_FILE=… bash install.sh
```

GitHub Actions: smoke + shellcheck on push.

## License

MIT — see [LICENSE](LICENSE).
