# 安装脚本

> 索引：[项目说明](../README.md) · [系统基本配置](../docs/environment.md) · [虚拟机与显卡直通](../docs/virtualization.md)

| 脚本 | 用途 | 运行环境 |
| --- | --- | --- |
| [install.sh](install.sh) | 基础系统安装：UEFI + LUKS2 + Btrfs + systemd/sd-encrypt + GRUB，含全盘加密与休眠 | Arch Live ISO（root） |
| [post-install.sh](post-install.sh) | 桌面环境安装：KDE Plasma 6 + SDDM、multilib、Fcitx5、字体、蓝牙、Timeshift、休眠参数、可选 linux-zen | 已装好的系统（root） |
| [check.sh](check.sh) | 排查脚本：核对加密启动与休眠相关配置 | 已装好的系统 |
| [make-usb.sh](make-usb.sh) | 制作可启动 U 盘：清空/重建 + FAT32 ESP + exFAT 数据区 + GRUB2 loopback 多启动菜单 | 已装好的系统（root） |

## install.sh

```bash
# 在 Arch Live ISO 中
bash install.sh
```

交互式流程：网络 → 代理（可选）→ 时间同步 → 镜像源 → 分区（可选 cfdisk）→ EFI → LUKS2 + Btrfs 子卷 → swap/休眠 → CPU microcode → pacstrap → fstab → Windows 双系统 ESP → 主机名/时区/用户 → chroot 配置 GRUB 与 mkinitcpio → 校验。

- Btrfs 子卷布局：`@` → `/`，`@home` → `/home`，`@swap` → `/swap`
- 挂载选项：`noatime,compress=zstd:3,discard=async`
- 复用 Windows 的 ESP 时**不要格式化**，脚本会二次确认
- 破坏性操作需手动输入 `ERASE-ROOT` / `FORMAT-EFI` 确认
- 代理为可选：输入局域网 IP 与端口（HTTP/HTTPS 默认 7890，SOCKS5 默认 7891），脚本会在当前 Live 终端 `export` 代理变量，并在 `arch-chroot` 内重新导出

## post-install.sh

```bash
sudo bash post-install.sh
```

需要先有网络与 root 权限；会执行全系统升级 `pacman -Syu`，结束时可选择重启进入 SDDM。

开头可选择配置局域网代理（同 `install.sh`，输入 IP 与端口），导出后供 `pacman -Syu` 与后续装包使用；直连时选 “No proxy”。

## check.sh

用于检查 LUKS 加密启动与 Btrfs swapfile 休眠配置的现状，逐项输出内核参数、GRUB 配置、mkinitcpio HOOKS、swap 与 resume 相关信息。

```bash
bash check.sh
```

## 检查项

| 输出段 | 含义 |
| --- | --- |
| `cat /proc/cmdline` | 当前生效的内核启动参数（确认 `resume=`、`resume_offset=`、`rd.luks.name=` 是否存在） |
| `----- GRUB -----` | `/etc/default/grub` 里的 `GRUB_CMDLINE_LINUX*` |
| `----- MKINITCPIO -----` | `/etc/mkinitcpio.conf` 的 `HOOKS=`（systemd 方案无需单独 resume hook） |
| `----- SWAP -----` | `swapon --show`，确认 swapfile 已启用 |
| `----- FSTAB -----` | `/etc/fstab` 中 swap / `@swap` 子卷相关行 |
| `----- BTRFS OFFSET -----` | `btrfs inspect-internal map-swapfile -r /swap/swapfile`，正确的 resume_offset |
| `----- RESUME DEVICE -----` | `/sys/power/resume`，内核实际使用的休眠设备 |
| `----- RESUME OFFSET -----` | `/sys/power/resume_offset`，内核实际使用的偏移 |
| `----- MAPPER -----` | `/dev/mapper/`，确认 `cryptroot` 存在 |
| `----- PREVIOUS BOOT ERRORS -----` | 上一次启动的内核 warning 及以上日志，定位唤醒失败原因 |

## 对照要点

1. `----- BTRFS OFFSET -----` 输出的数值应与 `----- RESUME OFFSET -----` 一致；不一致说明 GRUB 参数没生效，需重新 `grub-mkconfig -o /boot/grub/grub.cfg` 并重启。
2. `----- RESUME DEVICE -----` 应为休眠分区/设备的 `major:minor`，加密根通常对应 `/dev/mapper/cryptroot` 的设备号（`ls -l /dev/mapper/` 与 `stat -c '%t:%T'` 可核对）。
3. swapfile 重建或 `btrfs filesystem resize` 后 offset 会变化，必须重新写入 GRUB 参数并再生 initramfs（`mkinitcpio -P`）。

## make-usb.sh

```bash
sudo bash make-usb.sh                 # 默认 fast 擦除（秒级）
sudo WIPE_MODE=full bash make-usb.sh  # 全盘写 0（慢，可防取证恢复）
```

交互流程：列出 U 盘 → 输入设备（如 `/dev/sda`）→ 确认 → 擦除 → 建 GPT（`1 GiB FAT32 ESP` + `其余 exFAT`）→ 装 GRUB → 部署同目录的 [grub-usb.cfg](grub-usb.cfg) → 挂载数据区到 `/mnt/data` 并建 `/ISO`。

- 只对 `TRAN=usb` 的设备生效，认错会直接报错退出。
- 需要已装 `dosfstools`、`exfatprogs`、`parted`、`grub`。
- 制作与用法（含 Windows 镜像限制、QEMU 预演）见 [制作可启动 U 盘](../docs/bootable-usb.md)。
