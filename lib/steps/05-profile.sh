# 05-profile.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Wizard step 3/11: install profile preset (feeds checklist defaults).
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# ── profile preset (feeds checklist defaults) ───────────────
: "${PRESET:=gnome}"
ui_step 3 Profile
if (( ! NONINTERACTIVE )); then
  _pg=off; _pd=off; _pm=off
  case $PRESET in
    dev) _pd=on ;;
    minimal) _pm=on ;;
    *) _pg=on; PRESET=gnome ;;
  esac
  PRESET="$(ui_radio "Install profile (sets checklist defaults; you can still change)" \
    gnome "GNOME laptop — desktop + Nerd Fonts + mDNS" "$_pg" \
    dev "Dev laptop — GNOME + CLI tools + Podman + Starship" "$_pd" \
    minimal "Minimal — no desktop, small tool set" "$_pm")" || die "aborted"
  unset -v _pg _pd _pm
fi
case $PRESET in
  minimal)
    DESKTOP=${DESKTOP:-N}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-N}
    INSTALL_CLI=${INSTALL_CLI:-N}; INSTALL_PODMAN=${INSTALL_PODMAN:-N}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-N}; INSTALL_AVAHI=${INSTALL_AVAHI:-N}
    INSTALL_TLP=${INSTALL_TLP:-Y}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-N}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-N}; INSTALL_YAY=${INSTALL_YAY:-N}
    INSTALL_TUNED=${INSTALL_TUNED:-N}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-N}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-N}
    ;;
  dev)
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-Y}; INSTALL_PODMAN=${INSTALL_PODMAN:-Y}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-Y}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_CHROME_HINT=${INSTALL_CHROME_HINT:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-Y}; INSTALL_YAY=${INSTALL_YAY:-Y}
    INSTALL_TUNED=${INSTALL_TUNED:-Y}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-Y}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-Y}
    INSTALL_SNAPPER_HOME=${INSTALL_SNAPPER_HOME:-Y}
    ;;
  *)
    PRESET=gnome
    DESKTOP=${DESKTOP:-Y}; INSTALL_NERD_FONTS=${INSTALL_NERD_FONTS:-Y}
    INSTALL_CLI=${INSTALL_CLI:-N}; INSTALL_PODMAN=${INSTALL_PODMAN:-N}
    INSTALL_STARSHIP=${INSTALL_STARSHIP:-N}; INSTALL_AVAHI=${INSTALL_AVAHI:-Y}
    INSTALL_TLP=${INSTALL_TLP:-N}; INSTALL_SELFTEST=${INSTALL_SELFTEST:-Y}
    INSTALL_MULTILIB=${INSTALL_MULTILIB:-Y}; INSTALL_YAY=${INSTALL_YAY:-Y}
    INSTALL_TUNED=${INSTALL_TUNED:-Y}; INSTALL_DEVTOOLS=${INSTALL_DEVTOOLS:-N}
    INSTALL_BTRFS_ASSISTANT=${INSTALL_BTRFS_ASSISTANT:-Y}
    ;;
esac
# Fill remaining flags with N if unset
: "${ENROLL_SB:=N}" "${ENABLE_SSHD:=N}" "${INSTALL_CUPS:=N}" "${SKIP_REFLECTOR:=N}"
: "${INSTALL_DOCKER:=N}" "${INSTALL_VIRT:=N}" "${INSTALL_WIREGUARD:=N}"
: "${INSTALL_TAILSCALE:=N}" "${INSTALL_CHROME_HINT:=N}" "${INSTALL_FAIL2BAN:=N}"
: "${INSTALL_THINKFAN:=N}" "${FW_SYNCTHING:=N}" "${FW_KDECONNECT:=N}"
: "${INSTALL_OLLAMA:=N}"
: "${INSTALL_SNAPPER_HOME:=N}" "${INSTALL_LINUX_STABLE:=N}" "${INSTALL_PLYMOUTH:=N}"
: "${INSTALL_SELFTEST:=N}" "${CLEAN_ESP_ARCH:=Y}"
: "${INSTALL_MULTILIB:=N}" "${INSTALL_YAY:=N}" "${INSTALL_TUNED:=N}"
: "${INSTALL_DEVTOOLS:=N}" "${INSTALL_BTRFS_ASSISTANT:=N}"
: "${PACMAN_PARALLEL:=10}" "${LUKS_WIPE:=none}"
: "${BTRFS_COMPRESS:=zstd3}" "${ZRAM_SIZE:=half}" "${REFLECTOR_COUNTRY:=}"
: "${FORMAT_EFI:=1}"

# clean_esp_arch_files: lib/30-hardware.sh (kernels/ucode always; Arch UKIs when CLEAN_ESP_ARCH=Y).
apply_extra_pkgs_list
detect_vm_thinkpad_skip
