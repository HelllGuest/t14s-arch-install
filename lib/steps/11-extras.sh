# 11-extras.sh — part of HelllGuest/t14s-arch-install
# shellcheck shell=bash
# Wizard step 9/11: extras checklists, reflector country, post-install hook.
# Sourced by install.sh at top level, in order: shares its globals, set -e
# and ERR/EXIT traps exactly as if the code were inline.

# Split checklists (Core / Tools / Network). Defaults from preset + answers.
flag_from_opts() {
  local opts=$1 tag=$2
  printf '%s\n' "$opts" | grep -qx "$tag"
}

ui_step 9 Extras
if (( NONINTERACTIVE )); then
  # Keep EXTRA_PKGS already filled from EXTRA_PKGS_LIST (answers replay).
  :
else
  OPTS_CORE="$(ui_checklist "Core extras — Space toggles, Enter = Next" \
    gnome "Minimal GNOME desktop + Flatpak browsers/VPN" "$(def_onoff "$DESKTOP")" \
    nerd_fonts "Nerd Fonts + Inter/Noto" "$(def_onoff "$INSTALL_NERD_FONTS")" \
    sbctl "Enroll Secure Boot keys now (Setup Mode)" "$(def_onoff "$ENROLL_SB")" \
    sshd "Enable SSH server (sshd) after install" "$(def_onoff "$ENABLE_SSHD")" \
    cups "CUPS printing (cups + cups-pdf + ghostscript)" "$(def_onoff "$INSTALL_CUPS")" \
    skip_reflector "Skip live reflector; keep ISO mirrorlist" "$(def_onoff "$SKIP_REFLECTOR")" \
    tlp "TLP power mgmt (console-only; skipped if GNOME)" "$(def_onoff "$INSTALL_TLP")" \
    thinkfan "Write thinkfan AUR note (not in official repos)" "$(def_onoff "$INSTALL_THINKFAN")" \
    snapper_home "Snapper config for @home" "$(def_onoff "$INSTALL_SNAPPER_HOME")" \
    btrfs_assistant "btrfs-assistant (snapshot GUI; needs GNOME)" "$(def_onoff "$INSTALL_BTRFS_ASSISTANT")" \
    tuned "tuned + tuned-ppd + tuned-gui (replaces power-profiles-daemon)" "$(def_onoff "$INSTALL_TUNED")" \
    multilib "Enable [multilib] (32-bit: Steam, Wine)" "$(def_onoff "$INSTALL_MULTILIB")" \
    yay "yay AUR helper (yay-bin, built as your user)" "$(def_onoff "$INSTALL_YAY")" \
    linux_stable "Also install linux (stable) UKI" "$(def_onoff "$INSTALL_LINUX_STABLE")" \
    plymouth "Plymouth splash (optional)" "$(def_onoff "$INSTALL_PLYMOUTH")" \
    selftest "Write post-boot BT/audio self-test script" "$(def_onoff "$INSTALL_SELFTEST")" \
    clean_esp "Clean old Arch files from ESP (UKIs/entries/EFI/arch)" "$(def_onoff "$CLEAN_ESP_ARCH")" \
    chrome_hint "Write post-boot Chrome Flatpak helper script" "$(def_onoff "$INSTALL_CHROME_HINT")")" \
    || die "aborted"

  OPTS_TOOLS="$(ui_checklist "Dev / CLI tools" \
    devtools "Dev toolchains: gcc/clang/gdb, python, node, go, rustup, gh, nvim, code" "$(def_onoff "$INSTALL_DEVTOOLS")" \
    cli "ripgrep fd fzf bat eza jq git-delta" "$(def_onoff "$INSTALL_CLI")" \
    starship "starship prompt (+ wire into user zsh)" "$(def_onoff "$INSTALL_STARSHIP")" \
    podman "podman + buildah (rootless)" "$(def_onoff "$INSTALL_PODMAN")" \
    docker "docker + docker-compose (heavier)" "$(def_onoff "$INSTALL_DOCKER")" \
    virt "libvirt + qemu-desktop + virt-manager" "$(def_onoff "$INSTALL_VIRT")" \
    ollama "ollama-cuda (P15 only; localhost:11434)" "$([[ ${HW_PROFILE:-} == p15 ]] && def_onoff "${INSTALL_OLLAMA:-N}" || echo off)" \
    tmux "tmux" off \
    rsync "rsync" off \
    bash_completion "bash-completion" off \
    wget "wget" off \
    usbutils "usbutils" off \
    lsof "lsof" off \
    dmidecode "dmidecode" off \
    powertop "powertop" off \
    mc "mc (midnight commander)" off \
    traceroute "traceroute" off \
    bind "bind (dig/nslookup)" off \
    smartmontools "smartmontools (smartctl)" off)" || die "aborted"

  OPTS_NET="$(ui_checklist "Network / security extras" \
    avahi "avahi + nss-mdns (.local discovery)" "$(def_onoff "$INSTALL_AVAHI")" \
    wireguard "wireguard-tools" "$(def_onoff "$INSTALL_WIREGUARD")" \
    tailscale "tailscale" "$(def_onoff "$INSTALL_TAILSCALE")" \
    fail2ban "fail2ban (useful with sshd)" "$(def_onoff "$INSTALL_FAIL2BAN")" \
    fw_syncthing "firewalld allow Syncthing 22000/tcp+udp" "$(def_onoff "$FW_SYNCTHING")" \
    fw_kdeconnect "firewalld allow KDE Connect 1714:1764/tcp+udp" "$(def_onoff "$FW_KDECONNECT")" )" \
    || die "aborted"

  DESKTOP=N; INSTALL_NERD_FONTS=N; ENROLL_SB=N; ENABLE_SSHD=N
  INSTALL_CUPS=N; SKIP_REFLECTOR=N; INSTALL_TLP=N; INSTALL_THINKFAN=N
  INSTALL_SNAPPER_HOME=N; INSTALL_LINUX_STABLE=N; INSTALL_PLYMOUTH=N
  INSTALL_SELFTEST=N; CLEAN_ESP_ARCH=N; INSTALL_CHROME_HINT=N
  INSTALL_MULTILIB=N; INSTALL_YAY=N; INSTALL_TUNED=N; INSTALL_DEVTOOLS=N
  INSTALL_BTRFS_ASSISTANT=N
  INSTALL_CLI=N; INSTALL_STARSHIP=N
  INSTALL_PODMAN=N; INSTALL_DOCKER=N; INSTALL_VIRT=N
  INSTALL_AVAHI=N; INSTALL_WIREGUARD=N; INSTALL_TAILSCALE=N
  INSTALL_FAIL2BAN=N; FW_SYNCTHING=N; FW_KDECONNECT=N; INSTALL_OLLAMA=N
  # Preserve packages already loaded from EXTRA_PKGS_LIST (answers replay).
  _extras_keep=("${EXTRA_PKGS[@]}")
  EXTRA_PKGS=()

  flag_from_opts "$OPTS_CORE" gnome && DESKTOP=Y || true
  flag_from_opts "$OPTS_CORE" nerd_fonts && INSTALL_NERD_FONTS=Y || true
  flag_from_opts "$OPTS_CORE" sbctl && ENROLL_SB=Y || true
  flag_from_opts "$OPTS_CORE" sshd && ENABLE_SSHD=Y || true
  flag_from_opts "$OPTS_CORE" cups && INSTALL_CUPS=Y || true
  flag_from_opts "$OPTS_CORE" skip_reflector && SKIP_REFLECTOR=Y || true
  flag_from_opts "$OPTS_CORE" tlp && INSTALL_TLP=Y || true
  flag_from_opts "$OPTS_CORE" thinkfan && INSTALL_THINKFAN=Y || true
  flag_from_opts "$OPTS_CORE" snapper_home && INSTALL_SNAPPER_HOME=Y || true
  flag_from_opts "$OPTS_CORE" linux_stable && INSTALL_LINUX_STABLE=Y || true
  flag_from_opts "$OPTS_CORE" plymouth && INSTALL_PLYMOUTH=Y || true
  flag_from_opts "$OPTS_CORE" selftest && INSTALL_SELFTEST=Y || true
  flag_from_opts "$OPTS_CORE" clean_esp && CLEAN_ESP_ARCH=Y || true
  flag_from_opts "$OPTS_CORE" chrome_hint && INSTALL_CHROME_HINT=Y || true
  flag_from_opts "$OPTS_CORE" btrfs_assistant && INSTALL_BTRFS_ASSISTANT=Y || true
  flag_from_opts "$OPTS_CORE" tuned && INSTALL_TUNED=Y || true
  flag_from_opts "$OPTS_CORE" multilib && INSTALL_MULTILIB=Y || true
  flag_from_opts "$OPTS_CORE" yay && INSTALL_YAY=Y || true

  flag_from_opts "$OPTS_TOOLS" devtools && INSTALL_DEVTOOLS=Y || true
  flag_from_opts "$OPTS_TOOLS" cli && INSTALL_CLI=Y || true
  flag_from_opts "$OPTS_TOOLS" starship && INSTALL_STARSHIP=Y || true
  flag_from_opts "$OPTS_TOOLS" podman && INSTALL_PODMAN=Y || true
  flag_from_opts "$OPTS_TOOLS" docker && INSTALL_DOCKER=Y || true
  flag_from_opts "$OPTS_TOOLS" virt && INSTALL_VIRT=Y || true
  flag_from_opts "$OPTS_TOOLS" ollama && INSTALL_OLLAMA=Y || true
  [[ ${HW_PROFILE:-} == p15 ]] || INSTALL_OLLAMA=N
  # htop/btop/fastfetch ship in BASE_PKGS (always installed with firewalld).
  flag_from_opts "$OPTS_TOOLS" tmux && EXTRA_PKGS+=(tmux) || true
  flag_from_opts "$OPTS_TOOLS" rsync && EXTRA_PKGS+=(rsync) || true
  flag_from_opts "$OPTS_TOOLS" bash_completion && EXTRA_PKGS+=(bash-completion) || true
  flag_from_opts "$OPTS_TOOLS" wget && EXTRA_PKGS+=(wget) || true
  flag_from_opts "$OPTS_TOOLS" usbutils && EXTRA_PKGS+=(usbutils) || true
  flag_from_opts "$OPTS_TOOLS" lsof && EXTRA_PKGS+=(lsof) || true
  flag_from_opts "$OPTS_TOOLS" dmidecode && EXTRA_PKGS+=(dmidecode) || true
  flag_from_opts "$OPTS_TOOLS" powertop && EXTRA_PKGS+=(powertop) || true
  flag_from_opts "$OPTS_TOOLS" mc && EXTRA_PKGS+=(mc) || true
  flag_from_opts "$OPTS_TOOLS" traceroute && EXTRA_PKGS+=(traceroute) || true
  flag_from_opts "$OPTS_TOOLS" bind && EXTRA_PKGS+=(bind) || true
  flag_from_opts "$OPTS_TOOLS" smartmontools && EXTRA_PKGS+=(smartmontools) || true

  flag_from_opts "$OPTS_NET" avahi && INSTALL_AVAHI=Y || true
  flag_from_opts "$OPTS_NET" wireguard && INSTALL_WIREGUARD=Y || true
  flag_from_opts "$OPTS_NET" tailscale && INSTALL_TAILSCALE=Y || true
  flag_from_opts "$OPTS_NET" fail2ban && INSTALL_FAIL2BAN=Y || true
  flag_from_opts "$OPTS_NET" fw_syncthing && FW_SYNCTHING=Y || true
  flag_from_opts "$OPTS_NET" fw_kdeconnect && FW_KDECONNECT=Y || true

  # Re-apply answers extras after checklist rebuild (dedupe later at pacstrap).
  if ((${#_extras_keep[@]})); then
    EXTRA_PKGS+=("${_extras_keep[@]}")
  fi
  unset -v _extras_keep

  if [[ $SKIP_REFLECTOR != Y ]]; then
    while :; do
      REFLECTOR_COUNTRY="$(ui_input "Reflector --country (ISO codes, comma-ok; empty=worldwide)" \
        "${REFLECTOR_COUNTRY:-}")" || die "aborted"
      [[ -z $REFLECTOR_COUNTRY ]] || valid_reflector_country "$REFLECTOR_COUNTRY" && break
      ui_error "Reflector country: letters, spaces and commas only (e.g. DE,NL or Germany). Got: $REFLECTOR_COUNTRY"
    done
  else
    REFLECTOR_COUNTRY=
  fi

  # Hook preset: none / env default (T14S_DEFAULT_HOOK_URL) / custom URL.
  # Never hardcode a private repo URL (smoke forbids linking private trees).
  _hp_none=on; _hp_env=off; _hp_custom=off
  if [[ -n ${POST_HOOK_URL:-} ]]; then
    _hp_none=off; _hp_custom=on
  elif [[ -n ${T14S_DEFAULT_HOOK_URL:-} ]]; then
    _hp_none=off; _hp_env=on
  fi
  _hook_menu=(none "skip post-install hook" "$_hp_none")
  if [[ -n ${T14S_DEFAULT_HOOK_URL:-} ]]; then
    _hook_menu+=(env "use T14S_DEFAULT_HOOK_URL" "$_hp_env")
  fi
  _hook_menu+=(custom "type a HTTPS hook URL" "$_hp_custom")
  HOOK_PRESET="$(ui_radio "Post-install hook (curl|bash as root in new system)" \
    "${_hook_menu[@]}")" || die "aborted"
  unset -v _hp_none _hp_env _hp_custom _hook_menu
  case $HOOK_PRESET in
    env)
      POST_HOOK_URL=${T14S_DEFAULT_HOOK_URL:-}
      [[ -n $POST_HOOK_URL ]] || die "T14S_DEFAULT_HOOK_URL empty"
      ;;
    custom)
      POST_HOOK_URL="$(ui_input "Post-install hook URL (HTTPS; empty=skip)" \
        "${POST_HOOK_URL:-}")" || die "aborted"
      ;;
    *) POST_HOOK_URL= ;;
  esac
  unset -v HOOK_PRESET
fi

# TLP conflicts with GNOME power-profiles-daemon and with tuned — force off.
if yn_on "$DESKTOP" && yn_on "$INSTALL_TLP"; then
  warn "TLP skipped — GNOME uses power-profiles-daemon / tuned-ppd"
  INSTALL_TLP=N
fi
if yn_on "$INSTALL_TUNED" && yn_on "$INSTALL_TLP"; then
  warn "TLP skipped — tuned selected (tlp conflicts with tuned)"
  INSTALL_TLP=N
fi
# btrfs-assistant is a GUI (Qt) — only with the desktop.
if yn_on "$INSTALL_BTRFS_ASSISTANT" && ! yn_on "$DESKTOP"; then
  warn "btrfs-assistant skipped — no desktop (use snapper CLI)"
  INSTALL_BTRFS_ASSISTANT=N
fi
# Re-apply VM/ThinkPad skip after checklist (thinkfan may have been re-enabled).
if yn_on "$SKIP_THINKPAD_HW"; then
  INSTALL_THINKFAN=N
fi
# Fresh-format ESP already empty; CLEAN_ESP_ARCH is ignored (forced Y in answers).
if [[ ${FORMAT_EFI:-1} == 1 ]]; then
  CLEAN_ESP_ARCH=Y
elif ! yn_on "${CLEAN_ESP_ARCH:-Y}"; then
  warn "CLEAN_ESP_ARCH=N — keeping prior Arch UKIs/arch*.conf; kernels/ucode still removed (pacstrap). Boot menu may show dead entries until you delete them."
fi
# Reflector country sanitize (answers file / env; the prompt already re-asks).
if [[ -n ${REFLECTOR_COUNTRY:-} ]] && ! valid_reflector_country "$REFLECTOR_COUNTRY"; then
  ui_warn "Ignoring invalid REFLECTOR_COUNTRY=$REFLECTOR_COUNTRY (letters, spaces and commas only): mirrors will be ranked worldwide."
  REFLECTOR_COUNTRY=
fi

# Optional free-form extras (archfi -cpl spirit). Env T14S_EXTRA_PKGS appends.
if (( ! NONINTERACTIVE )); then
  _extra_in="$(ui_input "More pacstrap packages (space-separated, empty=none)" \
    "${T14S_EXTRA_PKGS:-}")" || die "aborted"
else
  _extra_in=${T14S_EXTRA_PKGS:-}
fi
if [[ -n ${_extra_in// /} ]]; then
  read -r -a _pkgs <<<"$_extra_in"
  for _p in "${_pkgs[@]}"; do
    if [[ $_p =~ ^[a-z0-9][a-z0-9@._+-]*$ ]]; then
      EXTRA_PKGS+=("$_p")
    else
      ui_warn "Skipping invalid package name: $_p"
    fi
  done
fi
unset -v _extra_in _p _pkgs
# Persist extras for answers replay (space-separated).
EXTRA_PKGS_LIST="${EXTRA_PKGS[*]:-}"

# Canonicalize boolean flags (answers may use on/1; chroot + saves want Y/N).
for _flag in DESKTOP INSTALL_NERD_FONTS ENROLL_SB ENABLE_SSHD INSTALL_CUPS \
  SKIP_REFLECTOR INSTALL_TLP INSTALL_CLI INSTALL_PODMAN INSTALL_DOCKER \
  INSTALL_VIRT INSTALL_AVAHI INSTALL_WIREGUARD INSTALL_TAILSCALE \
  INSTALL_STARSHIP INSTALL_CHROME_HINT INSTALL_FAIL2BAN INSTALL_THINKFAN \
  INSTALL_SNAPPER_HOME INSTALL_LINUX_STABLE INSTALL_PLYMOUTH INSTALL_SELFTEST \
  CLEAN_ESP_ARCH INSTALL_MULTILIB INSTALL_YAY INSTALL_TUNED INSTALL_DEVTOOLS INSTALL_BTRFS_ASSISTANT \
  INSTALL_OLLAMA FW_SYNCTHING FW_KDECONNECT \
  SKIP_THINKPAD_HW
do
  [[ -v $_flag ]] || printf -v "$_flag" '%s' N
  yn_canon "$_flag"
done
unset -v _flag
