# 个人用的 arch linux 安装脚本和环境配置md

## 参考来源

- [arch简明指南](https://arch.icekylin.online/)
- [Shorin-ArchLinux-Guide](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/tree/main)
- [winapps-org/winapps](https://github.com/winapps-org/winapps/blob/main/docs/libvirt.md)
- [告别重启：Linux 下的 NVIDIA 显卡直通](https://blog.vconet.top/archives/nvidia-kvm-passthrough/)

在参考基础上自己加入了全盘加密与休眠，以及最基础的系统与 kde 安装。

## 目录结构

```text
MyArchGuide/
├── README.md                  # 本文件：总索引
├── docs/
│   ├── environment.md         # 系统基本配置（显卡驱动、niri/dms、zsh、paru、常用应用）
│   ├── virtualization.md      # KVM 虚拟机与显卡直通
│   └── bootable-usb.md        # 制作可启动 U 盘（GRUB2 loopback 多启动）
├── scripts/
│   ├── README.md              # 脚本用法说明
│   ├── install.sh             # 基础系统安装（UEFI + LUKS2 + Btrfs + GRUB）
│   ├── post-install.sh        # 桌面环境安装（KDE Plasma + SDDM + Fcitx5）
│   ├── check.sh               # 休眠 / 加密启动排查
│   ├── make-usb.sh            # 制作多启动 U 盘（清空重建 + 装 GRUB）
│   └── grub-usb.cfg           # GRUB 多启动菜单模板
└── tools/                     # 装机后工具集
    ├── thermal-tuning/        # 温控四档（tempctl）+ niri 快捷键
    └── nvidia-switch/         # 独显 vfio-pci ⇄ 原生驱动切换（Tk GUI）
```

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [系统基本配置](docs/environment.md) | 显卡驱动、dankinstall 安装 niri 和 dms、zsh 配置、aur 助手 paru、常用应用与 xanmod 内核 |
| [虚拟机与显卡直通](docs/virtualization.md) | KVM 安装与嵌套虚拟化、Windows 11 虚拟机、VirtIO-FS 文件共享、独显直通、Looking-glass、VFIO 解绑 |
| [制作启动盘](docs/bootable-usb.md) | GRUB2 loopback 多启动 U 盘、擦除模式、添加启动项、Windows 镜像限制、QEMU 预演 |
| [脚本说明](scripts/README.md) | 四个脚本的用途、运行环境与流程 |

## 工具（装机后）

| 工具 | 作用 | 入口 |
| --- | --- | --- |
| thermal-tuning | 同机 CPU/GPU 功耗与温度四档（`tempctl save/normal/game/max`）与 niri 快捷键 | [tools/thermal-tuning](tools/thermal-tuning/README.md) |
| nvidia-switch | 独显在 vfio-pci 直通与 NVIDIA 原生驱动间一键切换（Tk GUI + pkexec） | [tools/nvidia-switch](tools/nvidia-switch/README.md) |

## 安装流程

1. 用 [scripts/make-usb.sh](scripts/make-usb.sh) 做一张 Arch Live 启动盘，详见 [docs/bootable-usb.md](docs/bootable-usb.md)。
2. 在 Arch Live ISO 中运行 [scripts/install.sh](scripts/install.sh)，装好带全盘加密与休眠的基础系统。
3. 进入系统后以 root 运行 [scripts/post-install.sh](scripts/post-install.sh)，安装 KDE Plasma 与桌面组件。
4. 按 [docs/environment.md](docs/environment.md) 配置显卡驱动、shell 与应用。
5. 需要跑 Windows 虚拟机或做独显直通，参考 [docs/virtualization.md](docs/virtualization.md)。
6. 休眠有问题时用 [scripts/check.sh](scripts/check.sh) 对照排查。
7. 装机后的两件常用调优：温控用 [tools/thermal-tuning](tools/thermal-tuning/README.md)，独显直通切换用 [tools/nvidia-switch](tools/nvidia-switch/README.md)。

## 文档格式检查

统一用 markdownlint 校验所有 md 的格式，规则见 [.markdownlint-cli2.jsonc](.markdownlint-cli2.jsonc)（无需本地安装依赖）：

```bash
npx --yes -p markdownlint-cli2 markdownlint-cli2 "**/*.md"
```

标题统一用带多级编号的 ATX：`## 1` → `### 1.1` → `#### 1.1.1`，不再用 `**加粗小标题**`。有先后顺序的步骤用有序列表，可并列的检查项用 `-` 无序列表。

关闭的规则只有 `MD013`（中文长行不强制折行）与 `MD036`（允许历史文档里残留的加粗小标题，避免批量改写正文）。
