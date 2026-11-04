# t14s-arch-install

Interactive hardened **Arch Linux** installer for **Lenovo ThinkPad T14s Gen 3 AMD**
(machine type **21CQ / 21CR**; example MTM `21CRS1PU00`).

## What you get

* LUKS2 (argon2id) full-disk encryption
* Btrfs subvolumes (`@` `@home` `@snapshots` `@var_log` `@var_cache` `@tmp`)
* `linux-lts` (primary) + `linux-hardened` (fallback) as Unified Kernel Images
* systemd-boot + `sbctl` Secure Boot keys/signing
* Minimal GNOME Wayland (optional), zram, AppArmor, UFW, Snapper
* AMD defaults: `amd-ucode`, `amd_iommu=on`, `amd_pstate=active`, s2idle

## Requirements

* Arch ISO, **UEFI**, root shell, working network
* Target hardware type **21CQ** or **21CR** (soft check; confirm to force on a VM)

## BIOS (F1)

* Secure Boot: **Disabled** for the install (enroll keys later)
* Sleep State: **Windows and Linux** (s2idle)
* Enable AMD **SVM** + **IOMMU**

## Run (from the Arch ISO)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/HelllGuest/t14s-arch-install/main/install.sh)
```

Prefer process substitution (`bash <(curl …)`) so prompts keep a real TTY.
The script reads all answers from `/dev/tty`.

### Interactive prompts

1. Target disk + AUTO wipe or MANUAL partitions (EFI format or reuse)
2. LUKS passphrase
3. Hostname (default `thinkpad-t14s`), timezone, locale, keymap
4. Username + user/root passwords
5. Minimal GNOME? Secure Boot enroll now (if Setup Mode)?

**AUTO mode erases the entire disk.** Type the disk path and `YES` to confirm.

## After first boot

```bash
reboot   # remove the ISO
# verify
lscpu | grep -i ryzen
cat /sys/power/mem_sleep          # expect [s2idle]
grep -E 'amd_iommu|amd_pstate' /proc/cmdline
```

### Secure Boot (optional)

1. BIOS → clear Secure Boot keys → Setup Mode  
2. `sudo sbctl enroll-keys -m`  
3. BIOS → Secure Boot → Enabled  

`-m` keeps Microsoft keys (shared ESP / Windows multiboot).

## License

MIT — see [LICENSE](LICENSE).

## Related

Optional post-install rice: [HelllGuest/dotfiles](https://github.com/HelllGuest/dotfiles)
(`profiles/thinkpad-t14s.sh` when that repo is public/available).
