# t14s-arch-install

Interactive hardened **Arch Linux** installer for **Lenovo ThinkPad T14s Gen 3 AMD**
(machine type **21CQ / 21CR**; example MTM `21CRS1PU00`).

## What you get

* LUKS2 (argon2id) full-disk encryption
* Btrfs subvolumes (`@` `@home` `@snapshots` `@var_log` `@var_cache` `@tmp`)
* `linux-lts` (primary) + `linux-hardened` (fallback) as Unified Kernel Images
* systemd-boot + `sbctl` Secure Boot keys/signing
* Minimal GNOME Wayland (**optional**), zram, AppArmor, UFW, Snapper
* AMD defaults: `amd-ucode`, `amd_iommu=on`, `amd_pstate=active`, s2idle
* With GNOME: `mesa` + `vulkan-radeon` + `fprintd` + `sof-firmware`
* Battery charge window **70–80** (ThinkPad `BAT*`): tmpfiles +
  `thinkpad-charge-thresholds.service` (`After=multi-user.target`, waits for sysfs).
  No-op on VMs without a battery.

## Requirements

* Arch ISO, **UEFI**, root shell, working network
* Target hardware type **21CQ** or **21CR** (soft DMI check)
* **AuthenticAMD** CPU (confirm to force on a non-AMD VM)
* A target disk with room for the ESP plus an 8 GB root (AUTO needs a whole disk;
  MANUAL can keep the other partitions)
* For a shared/multiboot ESP: an existing FAT32 partition of 1 GB or more

## BIOS (F1)

* Secure Boot: **Disabled** for the install (enroll keys later)
* Sleep State: **Windows and Linux** (s2idle)
* Enable AMD **SVM** + **IOMMU**

## Run (from the Arch ISO)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
```

Prefer process substitution (`bash <(curl …)`) so the UI keeps a real TTY.
The installation runs as a full-screen `whiptail`/`dialog` TUI on `/dev/tty`;
`dialog` is installed from the live repos if neither backend exists. Without a
usable TTY it falls back to plain line prompts.

### Screens

1. Hardware warnings (DMI / AMD), each with a safe default
2. Target disk picker (retries on invalid input; partitions are rejected)
3. Partition mode, then either:
   * **AUTO** — choose the ESP size (`1G`, `2G` default, `4G`); the rest becomes
     LUKS2. Rejected if the disk cannot also hold an 8 GB root.
   * **MANUAL** — pick ROOT, then pick EFI; both come from a list showing size,
     filesystem and partition type, with a "type a path" escape. The disk itself
     is filtered out. ROOT is the only partition written.
4. Manual guards: EFI and ROOT must differ, reuse needs an existing FAT32 ESP,
   and an ESP under 512 MB or a ROOT under 8 GB needs an explicit confirmation
5. LUKS passphrase (entered twice)
6. Hostname (default `thinkpad-t14s`), timezone, locale, keymap
7. Username (non-empty, not `root`, lowercase POSIX) + user/root passwords
8. Minimal GNOME? Secure Boot enroll now (if Setup Mode)?
9. Review screen with per-partition actions and sizes, then a final confirm

### Controls

* Arrow keys move; **Space** toggles a radio choice; **Enter** accepts
* **Tab** moves to the buttons (`<Ok>`/`<Cancel>`)
* **Esc** or selecting `<Cancel>` aborts the menu; the install aborts too if a
  required answer is cancelled
* In MANUAL mode, reuse lists every partition but only FAT32 passes validation

**AUTO mode erases the entire disk.** The disk path must be typed in full and
the wipe confirmed again.

### Safety model

Nothing is written before the final confirm. Once started, all command output
goes to `/tmp/t14s-install.*.log`; a failure restores the screen and opens the
log in a textbox instead of scrolling it away. Passwords are passed to the
chroot through a `0600` file, not the environment, and shredded afterwards.

## After first boot

```bash
reboot   # remove the ISO
lscpu | grep -i ryzen
cat /sys/power/mem_sleep          # expect [s2idle]
grep -E 'amd_iommu|amd_pstate' /proc/cmdline
# ThinkPad only — paths missing on a VM is normal
cat /sys/class/power_supply/BAT0/charge_control_start_threshold  # expect 70
cat /sys/class/power_supply/BAT0/charge_control_end_threshold    # expect 80
systemctl status thinkpad-charge-thresholds.service --no-pager
```

The same checklist is written to `/root/t14s-post-install.txt`.

* **With GNOME (default):** log in at GDM (Wayland). Chrome is skipped in the
  chroot; optional: `flatpak install --system -y flathub com.google.Chrome`
* **Without GNOME (`n`):** log in on a virtual console. Optional later:
  `pacman -S gnome-shell gdm flatpak && systemctl enable gdm`

### Secure Boot (optional)

1. BIOS → clear Secure Boot keys → Setup Mode  
2. `sudo sbctl enroll-keys -m`  
3. BIOS → Secure Boot → Enabled  

`-m` keeps Microsoft keys (shared ESP / Windows multiboot).

## Rehearse in a VM

This repo is the installer only. On a machine that already has the HelllGuest
dotfiles checkout, you can serve this script from a UEFI qemu harness:

```bash
# from a clone of this repo on the host HTTP path, or copy install.sh next to
# arch-install-vmtest.sh and:
INSTALLER=install.sh scripts/arch-install-vmtest.sh
```

Confirm past the DMI + AMD warnings inside the VM. To rehearse only the screens
(no disk writes), use `T14S_DRYRUN=1` from a normal shell.

## Develop / CI

```bash
bash -n install.sh
bash tests/smoke.test.sh

# walk every screen without touching a disk, and dump the result
T14S_DRYRUN=1 bash install.sh
# force a backend: T14S_UI=whiptail | dialog | plain
```

`T14S_DRYRUN=1` skips root/UEFI/network checks and does **not** run
`umount`/`swapoff`/`cryptsetup close` (safe on a normal host). It still needs
a TTY for the menus.

GitHub Actions runs the same smoke checks on push.

## License

MIT — see [LICENSE](LICENSE).
