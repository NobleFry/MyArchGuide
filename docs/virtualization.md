# KVM 虚拟机与显卡直通

> 索引：[项目说明](../README.md) · [系统基本配置](environment.md) · [安装脚本](../scripts/)

本指南假设宿主机已装好显卡驱动，见 [系统基本配置](environment.md#1-安装显卡驱动)。

## 1 安装 KVM 虚拟机

### 1.1 安装软件包并启用服务

```bash
sudo pacman -S qemu-full virt-manager swtpm dnsmasq
sudo systemctl enable --now libvirtd
sudo usermod -a -G libvirt $(whoami)
sudo usermod -a -G kvm $(whoami)
sudo virsh net-start default
sudo virsh net-autostart default
```

### 1.2 开启嵌套虚拟化

在 /etc/modprobe.d/kvm_amd.conf 中写入：

```bash
options kvm_amd nested=1
```

重新生成 initramfs：

```bash
sudo mkinitcpio -P
```

### 1.3 打开 virt-manager 的 XML 编辑

打开 virt-manager，在 edit -> preferences 里，确保 Enable XML editing 是开启状态。

## 2 安装 Windows 虚拟机

### 2.1 准备镜像

先准备好 win11 的 iso 文件。

下载 VirtIO 驱动镜像：

<https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/>

### 2.2 virt-manager 配置流程

#### 2.2.1 创建虚拟机

1. 创建一个新的虚拟机
2. 选择 Local install media，然后 Forward
3. 点击 Browse -> Browse Local 选择你下好的 win11 iso
4. 配置 RAM 和 CPU 核心
5. 配置虚拟硬盘的最大容量
6. 点击 Customize configuration before install，并选择一个网络

#### 2.2.2 检查硬件配置

进入自定义界面后，逐项确认以下设置（其中第 10 步会用到前面下载的 VirtIO 驱动镜像）：

- CPUs：Copy host CPU configuration 是开启状态，并建议手动拓扑，有需求时编辑 xml
- Memory：Enable shared memory 是开启状态
- Disk1：Disk bus 是 VirtIO
- Storage：点击 Add Hardware -> Storage，Device type 选 CDROM device，再点击 Manage -> Browse Local 选择下好的 VirtIO 驱动镜像，点击 Finish
- NIC：Device model 是 virtio

全部确认后点击安装。

### 2.3 windows 安装流程

1. 进入安装介质后，在选择硬盘的阶段会找不到硬盘，这是因为 VirtIO 驱动还没有加载，需要先选择 Load driver，然后点击 OK，根据系统选择 win10 或者 win11，加载完成后，硬盘就应该会可见了
2. 因为有关于网卡的驱动还没有安装，所以必须取消联网安装，按 Shfit+F10 打开命令行，输入 OOBE\BYPASSNRO 然后回车，系统重启后，就会允许选择不联网安装
3. 安装完成进入系统后，安装 VirtIO ISO 里的驱动程序，打开文件浏览器，选择 DVD Drive 找到 virtio-win-guest-tool.exe 安装

## 3 文件共享 VirtIO-FS

1. 在 windows 虚拟机安装 WinFSP <https://winfsp.dev/rel/>，并在 service 面板设置服务自动开启
2. 打开 virt-manager，添加硬件，类型为 Filesystem，Driver 选择 virtiofs，Source path 是你想选择共享的 linux 文件夹目录，Target path 是在 windows 里显示的名称

## 4 配置独显直通虚拟机

### 4.1 配置宿主机

本指南针对 niri 桌面环境进行配置，不同的桌面环境可能有不同的禁用独显渲染方案，除桌面配置外，其余流程通用。

#### 4.1.1 启用 IOMMU

在 Grub 的配置文件 /etc/default/grub 中添加：

```bash
# Intel CPU
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt ..."

# AMD CPU
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt ..."
```

#### 4.1.2 修改 mkinitcpio

修改文件 /etc/mkinitcpio.conf：

```bash
MODULES=(vfio_pci vfio vfio_iommu_type1 ...)
```

然后重新生成 Initramfs：

```bash
mkinitcpio -P
```

#### 4.1.3 修改 niri 配置文件

先找到自己显卡的 DRM 文件名和 PCI 路径：

```bash
ls -l /sys/class/drm/card*/device/driver
ls -l /sys/class/drm/render*/device/driver
ls -l /dev/dri/by-path/
```

在 niri 配置文件中加入独显 PCI 路径忽略：

```bash
debug {
    ignore-drm-device "/dev/dri/by-path/pci-0000:01:00.0-card"
    ignore-drm-device "/dev/dri/by-path/pci-0000:01:00.0-render"
}
```

注销重新启动 niri 查看是否占用 niri：

```bash
sudo fuser -v /dev/nvidia*
sudo fuser -v /dev/dri/card0
sudo fuser -v /dev/dri/renderD128
```

如果有其余进程可选杀死进程：

```bash
sudo fuser -k -9 /dev/nvidia*
```

#### 4.1.4 显卡绑定 vfio_pci

> 本节与第 6 节的手动命令已可由 [tools/nvidia-switch](../tools/nvidia-switch/README.md) 一键完成（GUI/CLI 均可）；下面保留手动步骤，便于理解原理与排障。

首先确认无进程使用 NVIDIA 后，移除所有模块：

```bash
sudo rmmod nvidia_drm
sudo rmmod nvidia_modeset
sudo rmmod nvidia_uvm
sudo rmmod nvidia
```

让 VFIO 接管：

```bash
# 加载 VFIO 模块
sudo modprobe vfio-pci

# 覆盖驱动为 VFIO
echo "vfio-pci" | sudo tee /sys/bus/pci/devices/0000:01:00.0/driver_override
echo "vfio-pci" | sudo tee /sys/bus/pci/devices/0000:01:00.1/driver_override

# 重新扫描设备绑定 VFIO
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers_probe
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers_probe

# 命令确认
lspci -k | grep -A 2 -i nvidia
```

### 4.2 给虚拟机添加显卡

在虚拟机里添加你的 PCI 独立显卡设备。

## 5 配置 Looking-glass

### 5.1 安装客户端与服务端

1. 在 linux 里安装 looking-glass 客户端，arch 可以直接下载 aur 里的 looking-glass 和 looking-glass-module-dkms
2. 在 windows 里安装 looking-glass 服务端与 Virtual-Display-Driver，并确保服务开启

### 5.2 配置 shmem 通信

创建文件 /etc/tmpfiles.d/looking-glass.conf：

```bash
f /dev/shm/looking-glass 0660 用户名 kvm -
```

运行下面命令生效：

```bash
sudo systemd-tmpfiles /etc/tmpfiles.d/looking-glass.conf --create
```

创建文件 /etc/looking-glass-client.ini：

```ini
[app]
shmFile=/dev/shm/looking-glass
```

### 5.3 编辑虚拟机的 XML

在 device 段添加：

```xml
        ...
        <shmem name='looking-glass'>
          <model type='ivshmem-plain'/>
          <size unit='M'>64</size>
        </shmem>
    </device>
    ...
</domain>
```

数值的计算方法：分辨率宽 x 分辨率高 x 4 x 2 /（1024 x 1024），将计算的结果以 2 的 n 次方向上取整的整数。如显示器分辨率为 2560x1600，其结果为：

$$
\frac{2560 \times 1600 \times 4 \times 2}{1024 \times 1024} = 31.25
$$

最接近 31.25 的是 $2^6 = 64$，因此上面的值为 64。

## 6 VFIO 解绑

> 同样可用 [tools/nvidia-switch](../tools/nvidia-switch/README.md) 的「恢复 NVIDIA 原生驱动」一键完成。

确认虚拟机已经关闭后，解绑 VFIO：

```bash
# 移除驱动覆盖
echo "" | sudo tee /sys/bus/pci/devices/0000:01:00.0/driver_override
echo "" | sudo tee /sys/bus/pci/devices/0000:01:00.1/driver_override

# 解绑 VFIO
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
```

### 6.1 重新加载 NVIDIA 模块

```bash
sudo modprobe nvidia
sudo modprobe nvidia_drm
sudo modprobe nvidia_modeset
sudo modprobe nvidia_uvm
```

### 6.2 重新检测，激活显卡

```bash
echo "0000:01:00.0" | sudo tee /sys/bus/pci/drivers_probe
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers_probe
```
