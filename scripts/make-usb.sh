#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Make Bootable USB
# GRUB2 loopback 多启动盘：FAT32 ESP + exFAT 数据分区（不依赖 Ventoy）
# 详细说明见 docs/bootable-usb.md
# ============================================================

# 交互式脚本，强制走真实终端，避免重定向掩盖输入输出。
if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'ERROR: /dev/tty is not available. Run this script from an interactive console.\n' >&2
    exit 1
fi
exec </dev/tty >/dev/tty 2>/dev/tty

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { printf '%b[+]%b %s\n' "$GREEN" "$NC" "$*"; }
info() { printf '%b[*]%b %s\n' "$BLUE" "$NC" "$*"; }
warn() { printf '%b[!]%b %s\n' "$YELLOW" "$NC" "$*"; }
die()  { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

confirm() {
    local prompt="$1" value
    while true; do
        IFS= read -r -p "$prompt [y/N]: " value
        value="${value:-n}"
        case "$value" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No)   return 1 ;;
            *) warn 'Please enter y or n.' ;;
        esac
    done
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1 (install package: $2)"
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 可调参数 ----
ESP_SIZE_MIB=1024                 # ESP 大小（MiB）
ESP_LABEL=GRUBEFI                 # ESP 卷标
DATA_LABEL=DATA                   # 数据分区卷标（grub-usb.cfg 按它搜索）
WIPE_MODE="${WIPE_MODE:-fast}"    # fast = 只擦关键区域；full = 全盘写 0
MNT_ESP=/mnt/esp
MNT_DATA=/mnt/data

# ---- 依赖检查 ----
require_command lsblk       util-linux
require_command parted      parted
require_command mkfs.fat    dosfstools
require_command mkfs.exfat  exfatprogs
require_command grub-install grub
command -v wipefs >/dev/null 2>&1 || die 'Required command not found: wipefs (install package: util-linux)'

# ---- 选择目标设备 ----
info '当前块设备：'
lsblk -dpno NAME,TRAN,SIZE,MODEL
printf '\n'
read -r -p '请输入目标 U 盘设备（例如 /dev/sda）: ' DEV
[[ -b "$DEV" ]] || die "不是块设备: $DEV"
[[ "$(lsblk -dnro TRAN "$DEV")" == "usb" ]] || die "$DEV 不是 USB 设备，拒绝操作"

# 分区设备名前缀（/dev/sda -> /dev/sda1，/dev/nvme0n1 -> /dev/nvme0n1p1）
if [[ "$DEV" =~ [0-9]$ ]]; then
    PART_PREFIX="${DEV}p"
else
    PART_PREFIX="${DEV}"
fi

printf '\n'
info "目标设备: $DEV"
lsblk -o NAME,SIZE,TRAN,FSTYPE,LABEL,MOUNTPOINT "$DEV"
printf '\n'
warn "即将【清空 $DEV】并重建为 GRUB 多启动盘（擦除模式: $WIPE_MODE）。盘上文件都会消失。"
confirm '确认继续' || die 'Aborted by user.'

# ---- 卸载该盘所有分区 ----
for p in "$DEV"?*; do
    sudo umount "$p" 2>/dev/null || true
done

# ---- [1/6] 清除签名 ----
log '[1/6] 清除文件系统 / 分区签名'
sudo wipefs -a "$DEV" || true

# ---- [2/6] 擦除 ----
log "[2/6] 擦除关键区域（模式: $WIPE_MODE）"
if [[ "$WIPE_MODE" == "full" ]]; then
    sudo dd if=/dev/zero of="$DEV" bs=4M status=progress oflag=sync
    sudo sync
else
    disk_mib=$(( $(sudo blockdev --getsize64 "$DEV") / 1048576 ))
    # 头部：0 号扇区（MBR）+ GPT 主分区表 + 旧 ESP / 旧文件系统头
    sudo dd if=/dev/zero of="$DEV" bs=1M count=256 status=progress conv=fsync
    # 尾部：GPT 备份分区表
    sudo dd if=/dev/zero of="$DEV" bs=1M seek=$(( disk_mib - 16 )) count=16 status=progress conv=fsync
    sudo sync
    sudo wipefs -a "$DEV" || true
fi

# ---- [3/6] 新建分区 ----
log '[3/6] 新建 GPT 分区表'
sudo parted -s "$DEV" mklabel gpt
sudo parted -s "$DEV" mkpart ESP  fat32 1MiB "${ESP_SIZE_MIB}MiB"
sudo parted -s "$DEV" set 1 esp on
sudo parted -s "$DEV" mkpart DATA "${ESP_SIZE_MIB}MiB" 100%
sudo partprobe "$DEV" 2>/dev/null || sudo udevadm settle
sleep 1

# ---- [4/6] 格式化 ----
log '[4/6] 格式化 ESP(FAT32) 与数据区(exFAT)'
sudo mkfs.fat -F 32 -n "$ESP_LABEL" "${PART_PREFIX}1"
sudo mkfs.exfat     -n "$DATA_LABEL" "${PART_PREFIX}2"

# ---- [5/6] 安装 GRUB ----
log '[5/6] 安装 GRUB 到 ESP (UEFI)'
sudo mkdir -p "$MNT_ESP"
sudo mount "${PART_PREFIX}1" "$MNT_ESP"
sudo grub-install \
    --target=x86_64-efi \
    --efi-directory="$MNT_ESP" \
    --boot-directory="$MNT_ESP/boot" \
    --removable --no-nvram \
    --modules="part_gpt part_msdos fat exfat ntfs ntfscomp iso9660 udf loopback normal linux search search_label search_fs_uuid configfile echo test all_video gfxterm gfxmenu"
sudo install -m 0644 "$HERE/grub-usb.cfg" "$MNT_ESP/boot/grub/grub.cfg"
df -h "$MNT_ESP"
sudo sync
sudo umount "$MNT_ESP"

# ---- [6/6] 数据分区：建 ISO 目录 ----
log '[6/6] 挂载数据分区并创建 /ISO'
sudo mkdir -p "$MNT_DATA"
sudo mount "${PART_PREFIX}2" "$MNT_DATA"
sudo mkdir -p "$MNT_DATA/ISO"

printf '\n'
log '完成。'
info "把 ISO 拷进 $MNT_DATA/ISO/ ，然后："
printf '  sudo cp <你的.iso> %s/ISO/\n' "$MNT_DATA"
printf '  sync && sudo umount %s\n' "$MNT_DATA"
printf '\n'
info '然后重新插拔 U 盘，开机按 F12/F9/Esc 选择它启动。'
