#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Arch Linux Post-Install / Desktop Setup
#
# Intended to run AFTER the base installation script.
#
# Features:
#   - Optional LAN proxy (HTTP/HTTPS or SOCKS5) for updates and package installs
#   - Full system upgrade
#   - Root/user default editor = vim
#   - Regular wheel user setup
#   - multilib enablement
#   - KDE Plasma 6 + SDDM
#   - Wayland-first setup, optional X11 session
#   - Base desktop applications and fonts
#   - Fcitx5 Chinese input method
#   - Optional Bluetooth
#   - Optional Timeshift
#   - Optional Btrfs swapfile hibernation configuration
#   - Optional linux-zen kernel
#
# Notes:
#   - This script is designed for the systemd-based mkinitcpio
#     configuration created by the first installer.
#   - With the systemd mkinitcpio hook, a separate "resume" hook
#     is NOT required for hibernation.
# ============================================================

# ----------------------------- Colors -----------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()      { printf '%b[+]%b %s\n' "$GREEN" "$NC" "$*"; }
info()     { printf '%b[*]%b %s\n' "$BLUE" "$NC" "$*"; }
warn()     { printf '%b[!]%b %s\n' "$YELLOW" "$NC" "$*"; }
die()      { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
selected() { printf '%b[Selected]%b %s\n' "$GREEN" "$NC" "$*"; }

pause() {
    local dummy
    read -r -p "Press Enter to continue..." dummy
}

confirm() {
    local prompt="$1" answer
    read -r -p "$prompt [y/N]: " answer
    printf '\n'
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        selected "Yes"
        return 0
    fi
    selected "No"
    return 1
}

read_choice() {
    local __var="$1" prompt="$2" regex="$3" value
    while true; do
        read -r -p "$prompt" value
        printf '\n'
        if [[ "$value" =~ $regex ]]; then
            selected "$value"
            printf -v "$__var" '%s' "$value"
            return 0
        fi
        warn "Invalid selection: ${value:-<empty>}"
    done
}

# ----------------------------- TTY safety -----------------------------

# Rebind stdio to the controlling terminal when possible.
# This avoids inherited redirections and broken echo/canonical settings.
if [[ -r /dev/tty && -w /dev/tty ]]; then
    exec </dev/tty >/dev/tty 2>/dev/tty
    stty sane 2>/dev/null || true
    stty echo 2>/dev/null || true
fi

# ----------------------------- Error handling -----------------------------

error_handler() {
    local ec=$?
    local line="${1:-unknown}"
    printf '\n'
    printf '%b[ERROR]%b Post-install setup failed at line %s (exit code %s).\n' \
        "$RED" "$NC" "$line" "$ec" >&2
    printf 'No automatic rollback was attempted.\n' >&2
    exit "$ec"
}
trap 'error_handler "$LINENO"' ERR

# ----------------------------- Self-check -----------------------------

[[ $EUID -eq 0 ]] || die "Run this script as root."
[[ -r /etc/arch-release ]] || die "This is not an Arch Linux system."
command -v pacman >/dev/null 2>&1 || die "pacman is not available."

# Refuse common copy/paste contamination that can launch nested shells.
SELF_PATH="${BASH_SOURCE[0]}"
if [[ -f "$SELF_PATH" ]]; then
    BAD_LINES="$(
        grep -nE '^[[:space:]]*(bash|install\.sh|post-install\.sh|```[[:alnum:]_-]*)[[:space:]]*$' \
            "$SELF_PATH" || true
    )"
    if [[ -n "$BAD_LINES" ]]; then
        printf '%s\n' "$BAD_LINES" >&2
        die "The script contains suspicious standalone shell/Markdown lines. Remove them first."
    fi
fi

# ----------------------------- Package helpers -----------------------------

pkg_exists() {
    pacman -Si "$1" >/dev/null 2>&1
}

install_required() {
    local missing=() pkg
    for pkg in "$@"; do
        if ! pkg_exists "$pkg"; then
            missing+=("$pkg")
        fi
    done
    if ((${#missing[@]})); then
        die "Required package(s) not found in enabled repositories: ${missing[*]}"
    fi
    pacman -S --needed --noconfirm "$@"
}

install_optional_available() {
    local available=() skipped=() pkg
    for pkg in "$@"; do
        if pkg_exists "$pkg"; then
            available+=("$pkg")
        else
            skipped+=("$pkg")
        fi
    done

    if ((${#available[@]})); then
        pacman -S --needed --noconfirm "${available[@]}"
    fi

    if ((${#skipped[@]})); then
        warn "Skipped unavailable optional package(s): ${skipped[*]}"
    fi
}

# ----------------------------- File helpers -----------------------------

ensure_line() {
    local file="$1" line="$2"
    touch "$file"
    grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
}

backup_once() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    [[ -e "${file}.postinstall-backup" ]] || cp -a "$file" "${file}.postinstall-backup"
}

# Add or replace a kernel parameter in GRUB_CMDLINE_LINUX_DEFAULT.
# Usage: set_grub_param "resume" "/dev/mapper/cryptroot"
set_grub_param() {
    local key="$1" value="$2"
    local grub="/etc/default/grub"
    local line params token newparams=""

    [[ -f "$grub" ]] || die "$grub does not exist."
    backup_once "$grub"

    line="$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub" || true)"
    if [[ -z "$line" ]]; then
        printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s=%s"\n' "$key" "$value" >> "$grub"
        return
    fi

    params="${line#*=}"
    params="${params#\"}"
    params="${params%\"}"

    for token in $params; do
        [[ "$token" == "${key}="* ]] && continue
        newparams+="${newparams:+ }${token}"
    done
    newparams+="${newparams:+ }${key}=${value}"

    local escaped
    escaped="$(printf '%s' "$newparams" | sed 's/[&|]/\\&/g')"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${escaped}\"|" "$grub"
}

# Add a flag-style kernel parameter if it is not present.
add_grub_flag() {
    local flag="$1"
    local grub="/etc/default/grub"
    local line params

    [[ -f "$grub" ]] || die "$grub does not exist."
    backup_once "$grub"

    line="$(grep -m1 '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub" || true)"
    if [[ -z "$line" ]]; then
        printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$flag" >> "$grub"
        return
    fi

    params="${line#*=}"
    params="${params#\"}"
    params="${params%\"}"

    if grep -qw -- "$flag" <<<"$params"; then
        return
    fi

    params="${params:+$params }$flag"

    local escaped
    escaped="$(printf '%s' "$params" | sed 's/[&|]/\\&/g')"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${escaped}\"|" "$grub"
}

# ----------------------------- Header -----------------------------

clear
cat <<'EOF'
============================================================
        Arch Linux Desktop / Post-Install Setup
============================================================

This script is intended to be run after the base Arch Linux
installation is complete and the installed system has booted.

Main tasks:
  - Configure an optional LAN proxy
  - Update the system
  - Configure a regular sudo user
  - Enable multilib
  - Install KDE Plasma
  - Install desktop utilities/fonts/browsers
  - Configure Fcitx5
  - Optionally configure Bluetooth
  - Optionally install Timeshift
  - Optionally configure hibernation
  - Optionally install linux-zen

Plasma is configured Wayland-first.
X11 can be installed as an optional session.

============================================================
EOF
pause

# ============================================================
# 0. NETWORK + FULL UPDATE
# ============================================================

echo
echo "=== 0. Network and system update ==="
echo

# --- Optional LAN proxy ---
echo "Proxy configuration (needed when this machine only reaches the Internet"
echo "through a proxy on the local network):"
echo
echo "  1) No proxy"
echo "  2) HTTP/HTTPS proxy"
echo "  3) SOCKS5 proxy"
echo

read_choice PROXY_TYPE "Select proxy type [1/2/3]: " '^[123]$'

PROXY_URL=""
case "$PROXY_TYPE" in
    1)
        selected "No proxy"
        ;;
    2|3)
        if [[ "$PROXY_TYPE" == 2 ]]; then
            PROXY_SCHEME=http
            PROXY_DEFAULT_PORT=7890
        else
            PROXY_SCHEME=socks5
            PROXY_DEFAULT_PORT=7891
        fi

        read -r -p "Proxy address (LAN IP or hostname) [192.168.1.1]: " PROXY_HOST
        printf '\n'
        PROXY_HOST="${PROXY_HOST:-192.168.1.1}"

        read -r -p "Proxy port [$PROXY_DEFAULT_PORT]: " PROXY_PORT
        printf '\n'
        PROXY_PORT="${PROXY_PORT:-$PROXY_DEFAULT_PORT}"
        [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die "Proxy port must be numeric."

        PROXY_URL="${PROXY_SCHEME}://${PROXY_HOST}:${PROXY_PORT}"
        export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" ftp_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" FTP_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
        export no_proxy='localhost,127.0.0.1,::1'
        export NO_PROXY="$no_proxy"
        selected "Proxy: $PROXY_URL"
        log "Proxy exported for this shell."
        ;;
esac

log "Checking Internet connectivity..."

if [[ -n "$PROXY_URL" ]]; then
    info "Proxy configured: $PROXY_URL (the update below validates connectivity through it)."
elif ping -c 2 -W 3 archlinux.org >/dev/null 2>&1; then
    info "Direct Internet connection detected."
else
    die "Internet connectivity test failed. Connect NetworkManager first and rerun the script."
fi

log "Updating the entire system..."
pacman -Syu --noconfirm

# Ensure tools this script depends on are present after the update.
install_required sudo vim grub mkinitcpio btrfs-progs networkmanager

# ============================================================
# 1. ROOT EDITOR
# ============================================================

echo
echo "=== 1. Root default editor ==="
echo

log "Setting root EDITOR to vim..."
ensure_line /root/.bash_profile "export EDITOR='vim'"
ensure_line /root/.bash_profile "export VISUAL='vim'"

# ============================================================
# 2. REGULAR USER
# ============================================================

echo
echo "=== 2. Regular user ==="
echo

echo "Existing regular users:"
mapfile -t REGULAR_USERS < <(
    awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" {print $1}' /etc/passwd
)

if ((${#REGULAR_USERS[@]})); then
    printf '  %s\n' "${REGULAR_USERS[@]}"
else
    echo "  (none)"
fi
echo

while true; do
    read -r -p "Enter the regular username to configure/create: " USERNAME
    printf '\n'
    if [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        selected "$USERNAME"
        break
    fi
    warn "Invalid username."
done

if id "$USERNAME" >/dev/null 2>&1; then
    info "User $USERNAME already exists."
    usermod -aG wheel "$USERNAME"
else
    log "Creating user $USERNAME..."
    useradd -m -G wheel -s /bin/bash "$USERNAME"
    echo
    echo "Set the password for $USERNAME:"
    passwd "$USERNAME"
fi

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
[[ -d "$USER_HOME" ]] || die "Unable to locate home directory for $USERNAME."

log "Enabling sudo for the wheel group..."
cat > /etc/sudoers.d/10-wheel <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
chmod 0440 /etc/sudoers.d/10-wheel
EDITOR=vim visudo -cf /etc/sudoers.d/10-wheel >/dev/null

log "Setting $USERNAME default editor to vim..."
ensure_line "$USER_HOME/.bashrc" "export EDITOR='vim'"
ensure_line "$USER_HOME/.bashrc" "export VISUAL='vim'"
chown "$USERNAME:$USERNAME" "$USER_HOME/.bashrc"

# ============================================================
# 3. MULTILIB
# ============================================================

echo
echo "=== 3. multilib ==="
echo

PACMAN_CONF="/etc/pacman.conf"
backup_once "$PACMAN_CONF"

if grep -q '^\[multilib\]' "$PACMAN_CONF"; then
    info "multilib is already enabled."
else
    log "Enabling multilib..."

    # Handles the standard:
    # #[multilib]
    # #Include = /etc/pacman.d/mirrorlist
    sed -i \
        '/^#\[multilib\]/{s/^#//; n; s/^#//;}' \
        "$PACMAN_CONF"
fi

grep -q '^\[multilib\]' "$PACMAN_CONF" || \
    die "Failed to enable [multilib] in /etc/pacman.conf."

log "Refreshing repositories after enabling multilib..."
pacman -Syu --noconfirm

# ============================================================
# 4. KDE PLASMA
# ============================================================

echo
echo "=== 4. KDE Plasma ==="
echo

log "Installing KDE Plasma, SDDM, and core KDE applications..."

install_required \
    plasma-meta \
    sddm \
    sddm-kcm \
    konsole \
    dolphin \
    ark \
    gwenview \
    xdg-desktop-portal \
    xdg-desktop-portal-kde

echo
if confirm "Install the optional Plasma X11 session as well?"; then
    install_optional_available plasma-x11-session kwin-x11
else
    info "Keeping the default Wayland-first Plasma installation."
fi

# NVIDIA systems benefit from egl-wayland.
if lspci -nnk 2>/dev/null | grep -qiE 'VGA|3D|Display' &&
   lspci -nnk 2>/dev/null | grep -qi nvidia; then
    log "NVIDIA GPU detected; installing egl-wayland."
    install_optional_available egl-wayland
fi

# ============================================================
# 5. SDDM
# ============================================================

echo
echo "=== 5. SDDM ==="
echo

log "Enabling SDDM for the next boot..."
systemctl enable sddm.service

# Do not start it in the middle of the installer.
info "SDDM is enabled but will not be started until reboot."

# ============================================================
# 6. BASE DESKTOP PACKAGES
# ============================================================

echo
echo "=== 6. Desktop packages ==="
echo

log "Installing audio firmware and filesystem support..."
install_optional_available \
    sof-firmware \
    alsa-firmware \
    alsa-ucm-conf \
    ntfs-3g

log "Installing fonts..."
install_optional_available \
    adobe-source-han-serif-cn-fonts \
    wqy-zenhei \
    noto-fonts \
    noto-fonts-cjk \
    noto-fonts-emoji \
    noto-fonts-extra

log "Installing browsers and desktop utilities..."
install_optional_available \
    firefox \
    chromium \
    packagekit \
    packagekit-qt6 \
    appstream \
    appstream-qt

echo
if confirm "Install Steam now?"; then
    install_required steam
    warn "Install/configure the correct GPU driver before launching games."
fi

# ============================================================
# 7. LOCALE / PLASMA LANGUAGE
# ============================================================

echo
echo "=== 7. Locale and Plasma language ==="
echo

log "Ensuring English and Simplified Chinese locales exist..."

sed -i \
    -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    -e 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' \
    /etc/locale.gen

locale-gen

echo
echo "User interface language:"
echo "1) Keep English"
echo "2) Prefer Simplified Chinese for the regular user"
read_choice LANGUAGE_CHOICE "Select [1/2]: " '^[12]$'

mkdir -p "$USER_HOME/.config/environment.d"

if [[ "$LANGUAGE_CHOICE" == "2" ]]; then
    cat > "$USER_HOME/.config/environment.d/locale.conf" <<'EOF'
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:en_US
EOF
    log "Configured Simplified Chinese locale for $USERNAME."
else
    cat > "$USER_HOME/.config/environment.d/locale.conf" <<'EOF'
LANG=en_US.UTF-8
EOF
    log "Configured English locale for $USERNAME."
fi

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

# ============================================================
# 8. FCITX5
# ============================================================

echo
echo "=== 8. Fcitx5 Chinese input method ==="
echo

log "Installing Fcitx5 and Chinese input packages..."

install_required \
    fcitx5 \
    fcitx5-configtool \
    fcitx5-gtk \
    fcitx5-qt \
    fcitx5-chinese-addons

install_optional_available \
    fcitx5-material-color \
    fcitx5-pinyin-zhwiki

mkdir -p "$USER_HOME/.config/environment.d"

# Wayland-first configuration:
# Do not force GTK_IM_MODULE/QT_IM_MODULE globally on modern Plasma Wayland.
# XMODIFIERS remains useful for XWayland/X11 compatibility.
cat > "$USER_HOME/.config/environment.d/fcitx5.conf" <<'EOF'
XMODIFIERS=@im=fcitx
QT_IM_MODULES=wayland;fcitx
SDL_IM_MODULE=fcitx
EOF

chown "$USERNAME:$USERNAME" \
    "$USER_HOME/.config/environment.d/fcitx5.conf"

echo
info "Fcitx5 packages are installed."
info "After logging into Plasma:"
echo "  System Settings -> Keyboard -> Virtual Keyboard -> Fcitx 5"
echo "  Then open Fcitx 5 Configuration and add:"
echo "  Chinese -> Pinyin"
echo
info "Ctrl+Space normally switches input methods after configuration."

# ============================================================
# 9. BLUETOOTH
# ============================================================

echo
echo "=== 9. Bluetooth ==="
echo

if confirm "Install and enable Bluetooth support?"; then
    install_required bluez bluez-utils
    systemctl enable bluetooth.service
    info "Bluetooth will start automatically on boot."
fi

# ============================================================
# 10. TIMESHIFT
# ============================================================

echo
echo "=== 10. Timeshift ==="
echo

if confirm "Install Timeshift for system snapshots?"; then
    install_required timeshift
    info "Configure snapshot schedules from the Timeshift GUI after login."
    warn "Review Timeshift's Btrfs subvolume requirements before relying on snapshots."
fi

# ============================================================
# 11. HIBERNATION
# ============================================================

echo
echo "=== 11. Hibernation ==="
echo

if confirm "Configure hibernation using /swap/swapfile?"; then

    SWAPFILE="/swap/swapfile"

    [[ -f "$SWAPFILE" ]] || \
        die "$SWAPFILE does not exist. Create the Btrfs swapfile first."

    command -v btrfs >/dev/null 2>&1 || \
        die "btrfs command is unavailable."

    # Ensure the swapfile is valid and can be mapped.
    RESUME_OFFSET="$(
        btrfs inspect-internal map-swapfile -r "$SWAPFILE"
    )"

    [[ "$RESUME_OFFSET" =~ ^[0-9]+$ ]] || \
        die "Could not determine a valid Btrfs resume offset."

    # The first-stage installer maps LUKS root as cryptroot.
    [[ -e /dev/mapper/cryptroot ]] || \
        warn "/dev/mapper/cryptroot is not currently present. The boot configuration will still target it."

    log "Btrfs resume offset: $RESUME_OFFSET"

    # systemd-based initramfs already supplies the resume mechanism.
    if grep -Eq '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf; then
        info "systemd mkinitcpio hook detected."
        info "No separate resume hook is required."
    else
        warn "The mkinitcpio configuration does not appear to use the systemd hook."
        warn "This script will not automatically rewrite a custom BusyBox hook chain."
        warn "For a BusyBox initramfs, the resume hook must be added in the correct order."
    fi

    set_grub_param "resume" "/dev/mapper/cryptroot"
    set_grub_param "resume_offset" "$RESUME_OFFSET"

    echo
    if confirm "Add nvme_core.default_ps_max_latency_us=0 workaround?"; then
        add_grub_flag "nvme_core.default_ps_max_latency_us=0"
        warn "This NVMe power-management workaround can increase power consumption."
        warn "Use it only if your hardware suffers NVMe timeout/resume problems."
    fi

    log "Regenerating initramfs..."
    mkinitcpio -P

    log "Regenerating GRUB configuration..."
    grub-mkconfig -o /boot/grub/grub.cfg

    info "Hibernation boot parameters configured."
    info "After reboot, test with: systemctl hibernate"
fi

# ============================================================
# 12. OPTIONAL ZEN KERNEL
# ============================================================

echo
echo "=== 12. Optional linux-zen kernel ==="
echo

if confirm "Install linux-zen and linux-zen-headers?"; then
    install_required linux-zen linux-zen-headers

    log "Regenerating initramfs for installed kernels..."
    mkinitcpio -P

    log "Regenerating GRUB configuration..."
    grub-mkconfig -o /boot/grub/grub.cfg

    info "linux-zen is installed and should appear in GRUB."
fi

# ============================================================
# 13. FINAL OWNERSHIP + SUMMARY
# ============================================================

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

echo
echo "============================================================"
echo "        Desktop setup completed successfully"
echo "============================================================"
echo
echo "Configured user:"
echo "  $USERNAME"
echo
echo "Desktop:"
echo "  KDE Plasma"
echo
echo "Default session:"
echo "  Wayland"
echo
echo "Display manager:"
echo "  SDDM (enabled for next boot)"
echo
echo "Input method:"
echo "  Fcitx5"
echo
echo "Recommended next steps:"
echo
echo "  1. Reboot:"
echo "       reboot"
echo
echo "  2. Log in through SDDM."
echo
echo "  3. Configure Fcitx5 Pinyin:"
echo "       System Settings -> Keyboard -> Virtual Keyboard -> Fcitx 5"
echo "       Fcitx 5 Configuration -> Add Input Method -> Chinese -> Pinyin"
echo
echo "  4. Configure Timeshift if you installed it."
echo "  5. Install/configure the correct GPU driver before gaming."
echo
echo "  6. If hibernation was configured, test it only after reboot:"
echo "       systemctl hibernate"
echo

if confirm "Reboot now?"; then
    reboot
else
    info "Reboot when convenient to start SDDM and apply the new user environment."
fi
