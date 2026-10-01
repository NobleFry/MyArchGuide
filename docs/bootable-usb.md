# 制作可启动 U 盘（GRUB2 loopback 多启动）

> 索引：[项目说明](../README.md) · [系统基本配置](environment.md) · [虚拟机与显卡直通](virtualization.md) · [脚本说明](../scripts/)

在裸机上跑 [install.sh](../scripts/install.sh) 之前，先得有一张能启动的 Arch Live U 盘。本页给出一套**不依赖 Ventoy** 的做法：用 GRUB2 的 `loopback` 模块，把 exFAT 数据分区里的多个 ISO 当作虚拟光驱直接引导。

## 1 方案说明

### 1.1 与 Ventoy 的取舍

Ventoy 会自动扫描盘里的 ISO 并识别各发行版，还内置了引导 Windows 安装盘的驱动，代价是引导部分是个比较复杂的定制镜像。

本方案改用发行版自带的 GRUB2：所有组件都来自官方仓库、可审计。代价是**不会自动识别 ISO**——每个 ISO 都要在 `grub.cfg` 里手写一条菜单项，而且 **Windows 安装盘无法用 loopback 引导**，见第 6 节。

### 1.2 盘布局

```text
/dev/sdX
├── sdX1   1 GiB   FAT32   卷标 GRUBEFI   ESP：GRUB 引导器 + grub.cfg
└── sdX2   其余    exFAT   卷标 DATA      /ISO/ 放各系统 ISO，同时当数据盘
```

GRUB 2.16 自带 `exfat.mod`，能直接读 exFAT，因此数据分区保持 exFAT 即可（Windows / macOS 也能读写）。

## 2 前置条件

- 目标电脑为 **x86_64 + UEFI** 启动。
- 目标电脑需**关闭 Secure Boot**：本方案的 GRUB 未签名，开着安全启动会被固件拒绝加载。
- 制作机已装依赖：

```bash
sudo pacman -S dosfstools exfatprogs parted grub
```

## 3 制作

### 3.1 运行脚本

```bash
sudo bash scripts/make-usb.sh
```

交互流程：列出 U 盘 → 选择设备 → 选择擦除模式 → 分区/格式化/装 GRUB → 部署 `grub.cfg`，最后把数据分区挂到 `/mnt/data` 并建好 `/ISO`。

### 3.2 放入 ISO

```bash
sudo cp ~/Downloads/archlinux-2026.09.01-x86_64.iso /mnt/data/ISO/
sync
sudo umount /mnt/data
```

放进去前先核对 ISO 与原版一致，以 Arch 为例：

```bash
sha256sum ~/Downloads/archlinux-2026.09.01-x86_64.iso
# 与官方 https://archlinux.org/iso/2026.09.01/sha256sums.txt 对比
```

### 3.3 启动

弹出 U 盘，插到目标机，进一次性启动菜单（一般 `F12` / `F9` / `Esc`）选它。因为装的是 `--removable` 布局（`/EFI/BOOT/BOOTX64.EFI`），即使主板 NVRAM 里没有该启动项也能引导。

## 4 擦除模式

`make-usb.sh` 用环境变量 `WIPE_MODE` 选择两种擦除：

| 模式 | 命令 | 耗时 | 作用 |
| --- | --- | --- | --- |
| `fast`（默认） | `sudo bash scripts/make-usb.sh` | 秒级 | 清签名，并擦掉头部 256MiB、尾部 16MiB（MBR / GPT 主副表 / 旧 ESP） |
| `full` | `sudo WIPE_MODE=full bash scripts/make-usb.sh` | 15~50 分钟 | 全盘写 0，额外可防止旧文件被取证恢复 |

`fast` 足以清除「可被自动加载执行的引导代码」，适合重做盘或当普通启动盘用；`full` 用于转手、送修等需要防止旧文件被恢复的场景。

> 两者都无法清除 U 盘**主控固件**层面的植入（BadUSB）。若怀疑此类威胁，只能刷固件或直接换盘。

## 5 添加启动项

`grub-usb.cfg` 里已给出 Arch、Debian/Ubuntu、Fedora 的模板。加一个新系统：

1. 把 ISO 拷进 `/mnt/data/ISO/`。
2. 在 `grub.cfg` 里照模板加一条 `menuentry`（不同发行版参数不同）。
3. 把新的 `grub.cfg` 覆盖到 ESP：

```bash
sudo mount /dev/sdX1 /mnt/esp
sudo cp scripts/grub-usb.cfg /mnt/esp/boot/grub/grub.cfg
sync
sudo umount /mnt/esp
```

Arch 的写法依赖 `archiso` 的 `img_dev` 与 `img_loop`：

```text
menuentry "Arch Linux" {
    search --no-floppy --label --set=isopart DATA
    set isofile=/ISO/archlinux-x86_64.iso
    loopback loop ($isopart)$isofile
    linux  (loop)/arch/boot/x86_64/vmlinuz-linux img_dev=/dev/disk/by-label/DATA img_loop=$isofile
    initrd (loop)/arch/boot/x86_64/initramfs-linux.img
}
```

## 6 Windows 镜像

GRUB 的 `loopback` **无法引导 Windows 安装 ISO**：Windows 走自己的 `bootmgr` / BCD 引导链，需要专门的 ntboot / wimboot 驱动，这正是 Ventoy 内置的部分。

需要 Windows 安装盘时，用另一个 U 盘直接 `dd`（最简单）：

```bash
sudo umount /dev/sdY* 2>/dev/null
sudo dd if=~/Downloads/Win11_25H2_Chinese_Simplified_x64_v2.iso of=/dev/sdY bs=4M status=progress oflag=sync
sync
```

如果必须在同一张盘上同时放 Windows 与 Linux，就改用 Ventoy。

## 7 在虚拟机中预演

真机重启前，先用 QEMU + OVMF(UEFI) 验证引导是否正常：

```bash
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd /tmp/OVMF_VARS.fd
sudo qemu-system-x86_64 -m 4G -enable-kvm -machine q35 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=/tmp/OVMF_VARS.fd \
  -device qemu-xhci -device usb-storage,drive=usb \
  -drive id=usb,format=raw,file=/dev/sdX \
  -boot menu=on
```

能看到 GRUB 菜单并进入安装器，就说明这块盘可用。
