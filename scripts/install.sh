#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Arch Linux Installer
# UEFI + LUKS2 + Btrfs + systemd/sd-encrypt + GRUB
# ============================================================

# This is an interactive installer. Always use the real terminal for
# input/output so a broken redirection or terminal state cannot hide input.
if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'ERROR: /dev/tty is not available. Run this script from an interactive console.\n' >&2
    exit 1
fi
exec </dev/tty >/dev/tty 2>/dev/tty
stty sane </dev/tty || true
stty echo </dev/tty || true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { printf '%b[+]%b %s\n' "$GREEN" "$NC" "$*"; }
info() { printf '%b[*]%b %s\n' "$BLUE" "$NC" "$*"; }
warn() { printf '%b[!]%b %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

pause() {
    local _dummy
    IFS= read -r -p 'Press Enter to continue...' _dummy </dev/tty
    printf '\n'
}

read_text() {
    local prompt="$1" default_value="${2-}" value
    if [[ -n "$default_value" ]]; then
        IFS= read -r -p "$prompt [$default_value]: " value </dev/tty
        value="${value:-$default_value}"
    else
        IFS= read -r -p "$prompt: " value </dev/tty
    fi
    printf '%b[Selected]%b %s\n' "$BLUE" "$NC" "$value"
    REPLY_VALUE="$value"
}

read_choice() {
    local prompt="$1" allowed="$2" value option
    local -a options=()
    IFS='/' read -r -a options <<< "$allowed"
    while true; do
        IFS= read -r -p "$prompt [$allowed]: " value </dev/tty
        printf '%b[Selected]%b %s\n' "$BLUE" "$NC" "${value:-<empty>}"
        for option in "${options[@]}"; do
            if [[ "$value" == "$option" ]]; then
                REPLY_VALUE="$value"
                return 0
            fi
        done
        warn "Invalid choice. Allowed values: $allowed"
    done
}

confirm() {
    local prompt="$1" value
    while true; do
        IFS= read -r -p "$prompt [y/N]: " value </dev/tty
        value="${value:-n}"
        printf '%b[Selected]%b %s\n' "$BLUE" "$NC" "$value"
        case "$value" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No)   return 1 ;;
            *) warn 'Please enter y or n.' ;;
        esac
    done
}

# Export proxy environment variables for the current shell so that pacman,
# pacstrap, git, curl and arch-chroot inherit the proxy for the rest of this session.
export_proxy() {
    local url="$1"
    export http_proxy="$url" https_proxy="$url" ftp_proxy="$url" all_proxy="$url"
    export HTTP_PROXY="$url" HTTPS_PROXY="$url" FTP_PROXY="$url" ALL_PROXY="$url"
    export no_proxy='localhost,127.0.0.1,::1'
    export NO_PROXY="$no_proxy"
}

unset_proxy() {
    unset http_proxy https_proxy ftp_proxy all_proxy
    unset HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY
    unset no_proxy NO_PROXY
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup_hint() {
    printf '\nCleanup commands, if needed:\n'
    printf '  swapoff /mnt/swap/swapfile 2>/dev/null || true\n'
    printf '  umount -R /mnt 2>/dev/null || true\n'
    printf '  cryptsetup close cryptroot 2>/dev/null || true\n\n'
}

on_error() {
    local code=$? line="$1"
    printf '\n%b[ERROR]%b Installer stopped at line %s (exit code %s).\n' "$RED" "$NC" "$line" "$code" >&2
    cleanup_hint >&2
    exit "$code"
}
trap 'on_error "$LINENO"' ERR

# Detect common copy/paste contamination before doing anything destructive.
SELF_PATH="$(readlink -f -- "$0")"
if grep -nE '^[[:space:]]*(bash|install\.sh|```[[:alnum:]_-]*)[[:space:]]*$' "$SELF_PATH" >/tmp/arch-installer-contamination.$$ 2>/dev/null; then
    printf '%b[ERROR]%b The script contains suspicious standalone lines that can create a nested shell or break execution:\n' "$RED" "$NC" >&2
    cat /tmp/arch-installer-contamination.$$ >&2
    rm -f /tmp/arch-installer-contamination.$$
    die 'Remove the lines above, or replace the file with the clean installer.'
fi
rm -f /tmp/arch-installer-contamination.$$ 2>/dev/null || true

[[ $EUID -eq 0 ]] || die 'Run this installer as root.'
[[ -r /etc/arch-release ]] || die 'This does not appear to be an Arch Linux environment.'
[[ -d /sys/firmware/efi/efivars ]] || die 'The Arch ISO is not booted in UEFI mode. Reboot and choose the UEFI entry for the USB device.'

for cmd in pacman pacstrap arch-chroot cryptsetup btrfs lsblk findmnt mountpoint timedatectl ping; do
    require_command "$cmd"
done

if mountpoint -q /mnt; then
    die '/mnt is already mounted. Run: umount -R /mnt'
fi
if [[ -e /dev/mapper/cryptroot ]]; then
    die '/dev/mapper/cryptroot already exists. Run: cryptsetup close cryptroot'
fi

clear
cat <<'EOF'
============================================================
              Arch Linux Installer
============================================================

  Boot mode       : UEFI
  Root encryption : LUKS2
  Filesystem      : Btrfs
  Initramfs       : systemd + sd-encrypt
  Bootloader      : GRUB
  Networking      : NetworkManager

  Btrfs subvolumes:
      @      -> /
      @home  -> /home
      @swap  -> /swap

WARNING: The selected ROOT partition will be erased.
If reusing a Windows EFI System Partition, DO NOT format it.
============================================================
EOF

info "Installer PID: $$ (parent shell PID: $PPID)"
info 'Terminal input/output has been rebound to /dev/tty and echo is enabled.'
pause

# ============================================================
# 1. NETWORK
# ============================================================
printf '\n=== Network configuration ===\n\n'
printf '1) Wired network / already connected\n'
printf '2) Wi-Fi using iwctl\n\n'
read_choice 'Select network method' '1/2'
NETWORK_TYPE="$REPLY_VALUE"

case "$NETWORK_TYPE" in
    1)
        log 'Using existing network connection.'
        ;;
    2)
        require_command iwctl
        printf '\nUseful iwctl commands:\n\n'
        printf '  device list\n'
        printf '  station wlan0 scan\n'
        printf '  station wlan0 get-networks\n'
        printf '  station wlan0 connect "WiFi-Name"\n'
        printf '  exit\n\n'
        pause
        iwctl
        stty sane </dev/tty || true
        stty echo </dev/tty || true
        ;;
esac

# ============================================================
# 2. PROXY
# ============================================================
printf '\n=== Proxy configuration ===\n\n'
printf 'Enter the LAN address and port of your proxy if you need one.\n'
printf 'You can leave this off when using a direct connection.\n\n'
printf '1) No proxy\n'
printf '2) HTTP/HTTPS proxy\n'
printf '3) SOCKS5 proxy\n\n'
read_choice 'Select proxy type' '1/2/3'
PROXY_TYPE="$REPLY_VALUE"

PROXY_URL=''
if [[ "$PROXY_TYPE" == 2 || "$PROXY_TYPE" == 3 ]]; then
    if [[ "$PROXY_TYPE" == 2 ]]; then
        PROXY_SCHEME=http
        PROXY_DEFAULT_PORT=7890
    else
        PROXY_SCHEME=socks5
        PROXY_DEFAULT_PORT=7891
    fi
    read_text 'Proxy address (LAN IP or hostname)' '192.168.1.1'
    PROXY_HOST="$REPLY_VALUE"
    read_text 'Proxy port' "$PROXY_DEFAULT_PORT"
    PROXY_PORT="$REPLY_VALUE"
    [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || die 'Proxy port must be numeric.'
    PROXY_URL="${PROXY_SCHEME}://${PROXY_HOST}:${PROXY_PORT}"
    export_proxy "$PROXY_URL"
    log "Proxy exported for this shell: $PROXY_URL"
    info 'The same proxy variables are re-exported inside arch-chroot.'
else
    unset_proxy
    log 'No proxy configured; using a direct connection.'
fi

log 'Testing network connectivity...'
if ping -c 3 -W 3 archlinux.org >/dev/null 2>&1; then
    log 'Internet connection is working.'
elif ping -c 3 -W 3 1.1.1.1 >/dev/null 2>&1; then
    if [[ -z "$PROXY_URL" ]]; then
        die 'IP connectivity works, but DNS resolution failed.'
    fi
    warn 'Direct DNS resolution failed; continuing with the configured proxy.'
elif [[ -n "$PROXY_URL" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
        warn 'curl is not available; skipping the proxy connectivity test.'
    elif curl -fsS --max-time 10 -x "$PROXY_URL" -o /dev/null https://archlinux.org >/dev/null 2>&1; then
        log "Internet is reachable through the proxy: $PROXY_URL"
    else
        die "No direct Internet connection and the proxy did not respond: $PROXY_URL"
    fi
else
    die 'No Internet connection detected.'
fi

# ============================================================
# 3. CLOCK
# ============================================================
log 'Enabling NTP synchronization...'
timedatectl set-ntp true
sleep 2
timedatectl status --no-pager || true

# ============================================================
# 4. MIRRORS
# ============================================================
printf '\n=== Package mirrors ===\n\n'
printf '1) China mirrors (TUNA + USTC)\n'
printf '2) International mirrors from the Arch ISO\n\n'
read_choice 'Select mirror group' '1/2'
MIRROR_TYPE="$REPLY_VALUE"

MIRRORLIST=/etc/pacman.d/mirrorlist
MIRROR_BACKUP=/etc/pacman.d/mirrorlist.arch-installer-backup
cp -f "$MIRRORLIST" "$MIRROR_BACKUP"

if [[ "$MIRROR_TYPE" == 1 ]]; then
    cat > "$MIRRORLIST" <<'EOF'
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.ustc.edu.cn/archlinux/$repo/os/$arch
EOF
    log 'China mirrors selected.'
else
    log 'International mirror list selected.'
fi

log 'Refreshing package databases and keyring...'
pacman -Sy --needed --noconfirm archlinux-keyring

# ============================================================
# 5. DISK / PARTITIONS
# ============================================================
printf '\n=== Disk configuration ===\n\n'
lsblk -o NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,PARTTYPENAME,LABEL,MOUNTPOINTS,MODEL
printf '\nRecommended layout:\n'
printf '  EFI  : 1-2 GiB, EFI System Partition\n'
printf '  ROOT : remaining space, Linux filesystem\n\n'
warn 'Reuse an existing Windows ESP if appropriate, but do not format it.'

if confirm 'Run cfdisk now?'; then
    read_text 'Target disk (example: /dev/nvme0n1 or /dev/sda)'
    INSTALL_DISK="$REPLY_VALUE"
    [[ -b "$INSTALL_DISK" ]] || die "$INSTALL_DISK is not a valid block device."
    warn "cfdisk will open for $INSTALL_DISK"
    pause
    cfdisk "$INSTALL_DISK"
    partprobe "$INSTALL_DISK" || true
    udevadm settle || true
    sleep 2
fi

printf '\nCurrent partitions:\n\n'
lsblk -f
printf '\n'
read_text 'EFI partition (example: /dev/nvme0n1p1)'
EFI_PART="$REPLY_VALUE"
read_text 'Arch ROOT partition (example: /dev/nvme0n1p2)'
ROOT_PART="$REPLY_VALUE"

[[ -b "$EFI_PART" ]] || die "EFI partition does not exist: $EFI_PART"
[[ -b "$ROOT_PART" ]] || die "ROOT partition does not exist: $ROOT_PART"
[[ "$EFI_PART" != "$ROOT_PART" ]] || die 'EFI and ROOT cannot be the same partition.'
[[ "$(lsblk -ndo TYPE "$ROOT_PART")" == part ]] || die 'ROOT must be a partition.'

if findmnt -rn -S "$ROOT_PART" >/dev/null 2>&1; then
    die 'The selected ROOT partition is already mounted.'
fi

printf '\n%bDESTRUCTIVE OPERATION WARNING%b\n' "$RED$BOLD" "$NC"
printf '  EFI partition : %s\n' "$EFI_PART"
printf '  ROOT to erase : %s\n\n' "$ROOT_PART"
read_text 'Type ERASE-ROOT to continue'
[[ "$REPLY_VALUE" == 'ERASE-ROOT' ]] || die 'Installation cancelled.'

# ============================================================
# 6. EFI
# ============================================================
printf '\n=== EFI System Partition ===\n\n'
EFI_FS="$(lsblk -ndo FSTYPE "$EFI_PART" || true)"
printf 'Selected EFI partition: %s\n' "$EFI_PART"
printf 'Current filesystem    : %s\n\n' "${EFI_FS:-unknown}"

if confirm 'Format the EFI partition as FAT32?'; then
    warn 'Do NOT format an existing Windows EFI partition unless you intentionally want to erase it.'
    read_text 'Type FORMAT-EFI to confirm'
    [[ "$REPLY_VALUE" == 'FORMAT-EFI' ]] || die 'EFI formatting cancelled.'
    umount "$EFI_PART" 2>/dev/null || true
    mkfs.fat -F32 "$EFI_PART"
else
    EFI_FS="$(lsblk -ndo FSTYPE "$EFI_PART" || true)"
    if [[ "$EFI_FS" != vfat ]]; then
        warn "Selected EFI filesystem is '${EFI_FS:-unknown}', not vfat/FAT32."
        confirm 'Continue anyway?' || die 'Installation cancelled.'
    fi
fi

# ============================================================
# 7. LUKS2 + BTRFS
# ============================================================
printf '\n=== LUKS2 encryption ===\n\n'
info 'You will be prompted for the LUKS password twice.'
cryptsetup luksFormat --type luks2 --verify-passphrase "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot
[[ -b /dev/mapper/cryptroot ]] || die 'Failed to open cryptroot.'

log 'Creating Btrfs filesystem...'
mkfs.btrfs -f -L ArchLinux /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@swap
umount /mnt

BTRFS_OPTS='noatime,compress=zstd:3,discard=async'
mount -o "${BTRFS_OPTS},subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,boot,swap}
mount -o "${BTRFS_OPTS},subvol=@home" /dev/mapper/cryptroot /mnt/home
mount -o 'noatime,subvol=@swap' /dev/mapper/cryptroot /mnt/swap
mount "$EFI_PART" /mnt/boot

# ============================================================
# 8. SWAP / HIBERNATION
# ============================================================
printf '\n=== Swap and hibernation ===\n\n'
MEM_KIB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
RAM_GIB="$(awk -v kib="$MEM_KIB" 'BEGIN {printf "%d", (kib + 1048575) / 1048576}')"
printf 'Detected RAM: approximately %s GiB\n\n' "$RAM_GIB"

HIBERNATION=no
if confirm 'Configure hibernation support?'; then
    HIBERNATION=yes
    DEFAULT_SWAP="$RAM_GIB"
else
    DEFAULT_SWAP=8
fi

read_text 'Swap size in GiB (0 disables swap)' "$DEFAULT_SWAP"
SWAP_SIZE="$REPLY_VALUE"
[[ "$SWAP_SIZE" =~ ^[0-9]+$ ]] || die 'Swap size must be an integer.'
if [[ "$HIBERNATION" == yes && "$SWAP_SIZE" -eq 0 ]]; then
    die 'Hibernation requires swap.'
fi

SWAP_OFFSET=''
if (( SWAP_SIZE > 0 )); then
    log "Creating ${SWAP_SIZE} GiB Btrfs swapfile..."
    btrfs filesystem mkswapfile --size "${SWAP_SIZE}G" /mnt/swap/swapfile
    swapon /mnt/swap/swapfile
    if [[ "$HIBERNATION" == yes ]]; then
        SWAP_OFFSET="$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)"
        [[ "$SWAP_OFFSET" =~ ^[0-9]+$ ]] || die 'Could not calculate Btrfs resume offset.'
        log "Resume offset: $SWAP_OFFSET"
    fi
fi

printf '\nMounted filesystems:\n'
findmnt /mnt
if (( SWAP_SIZE > 0 )); then
    printf '\nActive swap:\n'
    swapon --show
fi
pause

# ============================================================
# 9. CPU MICROCODE
# ============================================================
CPU_VENDOR="$(awk -F ': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo)"
MICROCODE=''
case "$CPU_VENDOR" in
    GenuineIntel) MICROCODE='intel-ucode' ;;
    AuthenticAMD) MICROCODE='amd-ucode' ;;
    *) warn 'Intel/AMD CPU vendor was not detected; no microcode package will be added automatically.' ;;
esac
[[ -n "$MICROCODE" ]] && log "Microcode package: $MICROCODE"

# ============================================================
# 10. INSTALL PACKAGES
# ============================================================
printf '\n=== Installing Arch Linux ===\n\n'
PACKAGES=(
    base base-devel linux linux-headers linux-firmware
    btrfs-progs cryptsetup
    grub efibootmgr os-prober fuse3 ntfs-3g
    networkmanager iwd
    sudo vim neovim fish fastfetch
    man-db man-pages
)
[[ -n "$MICROCODE" ]] && PACKAGES+=("$MICROCODE")
pacstrap -K /mnt "${PACKAGES[@]}"

# ============================================================
# 11. FSTAB
# ============================================================
log 'Generating fstab...'
genfstab -U /mnt > /mnt/etc/fstab
if (( SWAP_SIZE > 0 )) && ! grep -q '/swap/swapfile' /mnt/etc/fstab; then
    printf '/swap/swapfile none swap defaults 0 0\n' >> /mnt/etc/fstab
fi
printf '\nGenerated /etc/fstab:\n\n'
cat /mnt/etc/fstab

# ============================================================
# 12. WINDOWS ESP (OPTIONAL)
# ============================================================
printf '\n=== Windows dual boot ===\n\n'
WINDOWS_EFI_PART=''
if [[ -f /mnt/boot/EFI/Microsoft/Boot/bootmgfw.efi ]]; then
    log 'Windows Boot Manager found on the selected ESP.'
else
    info 'Windows Boot Manager was not found on the selected ESP.'
    if confirm 'Mount a separate Windows EFI partition read-only for os-prober?'; then
        lsblk -f
        read_text 'Windows EFI partition'
        WINDOWS_EFI_PART="$REPLY_VALUE"
        [[ -b "$WINDOWS_EFI_PART" ]] || die 'Invalid Windows EFI partition.'
        [[ "$WINDOWS_EFI_PART" != "$ROOT_PART" ]] || die 'Windows EFI cannot be the Arch ROOT partition.'
        mkdir -p /mnt/windows-efi
        mount -o ro "$WINDOWS_EFI_PART" /mnt/windows-efi
    fi
fi

# ============================================================
# 13. SYSTEM SETTINGS
# ============================================================
printf '\n=== System configuration ===\n\n'
read_text 'Hostname' 'archlinux'
HOSTNAME_VALUE="$REPLY_VALUE"
[[ "$HOSTNAME_VALUE" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || die 'Invalid hostname.'

read_text 'Timezone' 'Asia/Singapore'
TIMEZONE="$REPLY_VALUE"
[[ -e "/mnt/usr/share/zoneinfo/$TIMEZONE" ]] || die "Invalid timezone: $TIMEZONE"

CREATE_USER=no
USERNAME=''
if confirm 'Create a regular user?'; then
    CREATE_USER=yes
    read_text 'Username'
    USERNAME="$REPLY_VALUE"
    [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die 'Invalid username.'
fi

LUKS_UUID="$(cryptsetup luksUUID "$ROOT_PART")"
[[ "$LUKS_UUID" =~ ^[0-9A-Fa-f-]+$ ]] || die 'Could not obtain the LUKS UUID.'
log "LUKS UUID: $LUKS_UUID"

# ============================================================
# 14. PASS CONFIG TO CHROOT
# ============================================================
CONFIG_FILE=/mnt/root/arch-install.conf
{
    printf 'HOSTNAME_VALUE=%q\n' "$HOSTNAME_VALUE"
    printf 'TIMEZONE=%q\n' "$TIMEZONE"
    printf 'LUKS_UUID=%q\n' "$LUKS_UUID"
    printf 'HIBERNATION=%q\n' "$HIBERNATION"
    printf 'SWAP_OFFSET=%q\n' "$SWAP_OFFSET"
    printf 'CREATE_USER=%q\n' "$CREATE_USER"
    printf 'USERNAME=%q\n' "$USERNAME"
    printf 'PROXY_URL=%q\n' "$PROXY_URL"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ============================================================
# 15. NON-INTERACTIVE CHROOT CONFIGURATION SCRIPT
# ============================================================
POSTINSTALL=/mnt/root/arch-postinstall.sh
cat > "$POSTINSTALL" <<'CHROOT_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/arch-install.conf

log() { printf '[+] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# Re-export the proxy inside the chroot so pacman and other tools keep working
# even though this runs in a different environment.
if [[ -n "${PROXY_URL:-}" ]]; then
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL" ftp_proxy="$PROXY_URL" all_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL" FTP_PROXY="$PROXY_URL" ALL_PROXY="$PROXY_URL"
    export no_proxy='localhost,127.0.0.1,::1'
    export NO_PROXY="$no_proxy"
    log "Proxy enabled inside chroot: $PROXY_URL"
fi

log 'Configuring timezone...'
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

log 'Configuring locale...'
sed -i \
    -e 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' \
    -e 's/^#zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/' \
    /etc/locale.gen
locale-gen
printf 'LANG=en_US.UTF-8\n' > /etc/locale.conf
printf 'KEYMAP=us\n' > /etc/vconsole.conf

log 'Configuring hostname...'
printf '%s\n' "$HOSTNAME_VALUE" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME_VALUE}.localdomain ${HOSTNAME_VALUE}
EOF

log 'Configuring mkinitcpio...'
cp -f /etc/mkinitcpio.conf /etc/mkinitcpio.conf.arch-installer-backup
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

GRUB_PARAMS="rd.luks.name=${LUKS_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw loglevel=5 nowatchdog"
if [[ "$HIBERNATION" == yes ]]; then
    [[ "$SWAP_OFFSET" =~ ^[0-9]+$ ]] || die 'Invalid swap resume offset.'
    GRUB_PARAMS+=" resume=/dev/mapper/cryptroot resume_offset=${SWAP_OFFSET}"
fi

log 'Configuring GRUB...'
cp -f /etc/default/grub /etc/default/grub.arch-installer-backup
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_PARAMS}\"|" /etc/default/grub
else
    printf 'GRUB_CMDLINE_LINUX_DEFAULT="%s"\n' "$GRUB_PARAMS" >> /etc/default/grub
fi

if grep -q '^#\?GRUB_DEFAULT=' /etc/default/grub; then
    sed -i 's/^#\?GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
else
    printf 'GRUB_DEFAULT=saved\n' >> /etc/default/grub
fi

if grep -q '^#\?GRUB_SAVEDEFAULT=' /etc/default/grub; then
    sed -i 's/^#\?GRUB_SAVEDEFAULT=.*/GRUB_SAVEDEFAULT=true/' /etc/default/grub
else
    printf 'GRUB_SAVEDEFAULT=true\n' >> /etc/default/grub
fi

if grep -q '^#\?GRUB_DISABLE_OS_PROBER=' /etc/default/grub; then
    sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
else
    printf 'GRUB_DISABLE_OS_PROBER=false\n' >> /etc/default/grub
fi

# /boot is the unencrypted ESP, so GRUB_ENABLE_CRYPTODISK is not needed.
log 'Generating initramfs...'
mkinitcpio -P

log 'Installing GRUB UEFI bootloader...'
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck

log 'Running os-prober...'
os-prober || true

log 'Generating GRUB configuration...'
grub-mkconfig -o /boot/grub/grub.cfg

log 'Enabling NetworkManager...'
systemctl enable NetworkManager

printf '\n============================================================\n'
printf 'Set the root password\n'
printf '============================================================\n\n'
passwd root

if [[ "$CREATE_USER" == yes ]]; then
    log "Creating user: $USERNAME"
    useradd -m -G wheel -s /bin/bash "$USERNAME"
    printf '\nSet the password for %s:\n\n' "$USERNAME"
    passwd "$USERNAME"
    printf '%%wheel ALL=(ALL:ALL) ALL\n' > /etc/sudoers.d/10-wheel
    chmod 440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel
fi

log 'Installed-system configuration completed.'
CHROOT_SCRIPT
chmod 700 "$POSTINSTALL"

# Validate before executing it.
bash -n "$POSTINSTALL"

printf '\n=== Configuring installed system ===\n\n'
# This executes a non-interactive script inside the new root. It does not open
# an interactive nested shell. The exported proxy variables are inherited here,
# and the script also re-exports them from /root/arch-install.conf.
arch-chroot /mnt /root/arch-postinstall.sh

rm -f "$POSTINSTALL" "$CONFIG_FILE"

# ============================================================
# 16. VERIFY
# ============================================================
printf '\n=== Installation verification ===\n\n'
[[ -f /mnt/boot/grub/grub.cfg ]] || die 'GRUB configuration is missing.'
[[ -d /mnt/boot/EFI/ARCH ]] || die 'GRUB EFI files are missing.'
[[ -f /mnt/etc/fstab ]] || die 'fstab is missing.'
grep -q "rd.luks.name=${LUKS_UUID}=cryptroot" /mnt/etc/default/grub || die 'LUKS kernel parameter is missing.'
if [[ "$HIBERNATION" == yes ]]; then
    grep -q "resume_offset=${SWAP_OFFSET}" /mnt/etc/default/grub || die 'Hibernation resume offset is missing.'
fi
log 'Verification passed.'

sync

printf '\n============================================================\n'
printf 'Arch Linux installation completed successfully\n'
printf '============================================================\n\n'
printf 'Root partition : %s\n' "$ROOT_PART"
printf 'EFI partition  : %s\n' "$EFI_PART"
printf 'LUKS UUID      : %s\n' "$LUKS_UUID"
printf 'Hostname       : %s\n' "$HOSTNAME_VALUE"
printf 'Timezone       : %s\n' "$TIMEZONE"
printf 'Swap           : %s GiB\n' "$SWAP_SIZE"
printf 'Hibernation    : %s\n' "$HIBERNATION"
[[ "$HIBERNATION" == yes ]] && printf 'Resume offset   : %s\n' "$SWAP_OFFSET"
[[ -n "$PROXY_URL" ]] && printf 'Proxy          : %s\n' "$PROXY_URL"

printf '\nUseful checks before reboot:\n\n'
printf '  cat /mnt/etc/fstab\n'
printf '  cat /mnt/etc/default/grub\n'
printf '  cat /mnt/etc/mkinitcpio.conf\n'
printf '  findmnt /mnt\n'
printf '  lsblk -f\n\n'

if confirm 'Unmount everything and reboot now?'; then
    if (( SWAP_SIZE > 0 )); then
        swapoff /mnt/swap/swapfile || true
    fi
    umount -R /mnt
    cryptsetup close cryptroot
    log 'Remove the Arch installation media when the machine restarts.'
    reboot
else
    printf '\nManual cleanup/reboot commands:\n\n'
    if (( SWAP_SIZE > 0 )); then
        printf '  swapoff /mnt/swap/swapfile\n'
    fi
    printf '  umount -R /mnt\n'
    printf '  cryptsetup close cryptroot\n'
    printf '  reboot\n\n'
fi
