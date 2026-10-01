# nvidia-switch

> 索引：[项目说明](../../README.md) · [虚拟机与显卡直通](../../docs/virtualization.md)

在 **vfio-pci 直通**（把独显让给 Windows 虚拟机）与 **NVIDIA 原生驱动**（Linux 下正常使用）之间一键切换的本地工具，附带 Tk 图形界面。针对机器 Hasee QNLXS / RTX 4060 Laptop，设备为 `0000:01:00.0`（显卡）与 `0000:01:00.1`（音频）。

它是 [虚拟机与显卡直通](../../docs/virtualization.md) 第 4 节（绑定 vfio_pci）与第 6 节（VFIO 解绑）手动步骤的自动化封装。

## 1 两个入口

| 入口 | 文件 | 说明 |
| --- | --- | --- |
| 图形界面 | `switch_gui.py` | Tk 窗口，点按钮切换；点操作时用 pkexec 弹密码框 |
| 命令行 | `switch` | root 下运行的交互式菜单（1 = 绑 VFIO，2 = 恢复 NVIDIA） |

## 2 图形界面用法

以普通用户运行即可，**不要加 sudo**（Wayland 下 root 连不上显示服务器，提权交给 pkexec）：

```bash
./switch_gui.py
```

## 3 命令行用法

```bash
sudo ./switch
```

## 4 权限模型

- GUI 进程始终以普通用户运行，绝不整体提权、绝不重启。
- 点击操作后由 `pkexec` 调用系统 Polkit 弹窗索取密码。
- 密码只对本次操作有效；核心脚本 `switch` 以 root 在纯命令行子进程中执行。
- 会话中没有 Polkit 图形代理时（niri 等合成器常见），会自动拉起 `polkit-kde-authentication-agent-1` 并重试一次。

## 5 可选：内存大页

绑定 VFIO 时可选择一并申请 `TARGET_HUGEPAGES`（4096 × 2MB = 8GB）大页，用于提升虚拟机性能。

## 6 安装（本地打包）

```bash
cd tools/nvidia-switch
makepkg -si    # 依据 PKGBUILD 构建并安装 nvidia-switch-gui
```

安装后可在应用菜单搜索「NVIDIA GPU 驱动切换」，或直接运行 `nvidia-switch-gui`。

## 7 文件结构

```text
nvidia-switch/
├── switch                  # 核心脚本（root，交互式菜单）
├── switch_gui.py           # Tk 图形前端（pkexec 提权）
├── nvidia-switch.desktop   # 应用启动器
└── PKGBUILD                # 本地打包（makepkg -si）
```

## 8 与温控工具的关系

独显绑定到 vfio-pci 后 `nvidia-smi` 不可用，[thermal-tuning](../thermal-tuning/README.md) 的 `tempctl` 将无法设置 GPU 功耗墙（脚本会优雅跳过，仅 CPU 侧生效）。直通期间请以 CPU 侧温控为准。
