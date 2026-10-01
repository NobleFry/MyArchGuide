# 温度/功耗调优笔记（Hasee QNLXS · i7-13620H · RTX 4060 Laptop · Arch + Xanmod）

> ⚠️ 本文是**调查过程与决策依据的历史记录**，文中出现的 `guard` / `eco` / `balanced` / `perf` / `game-max` / `game-on` / `game-off` / `watch` / `csv` / `gpu` 等命令**都已经删除**。
> 最终方案只有三个档位：`tempctl save | normal | game`，以 [../README.md](../README.md) 为准。
> 索引：[项目说明](../README.md)

## 一、先回答你的问题

**能调，而且可调空间很大。** 但先纠正一个概念：

- `linux-xanmod` 是**内核**（带 BORE 调度、x64v3 优化），不是"调度策略"。它本身**不会**让你热 90°C。
- 真正决定你温度的是这三样：**CPU 功耗墙（RAPL PL1/PL2）**、**EPP 能效偏好**、**睿频上限**。
- 你现在的实测状态（`tempctl show`）：

| 项目 | 当前值 | 说明 |
| --- | --- | --- |
| RAPL PL1（长时功耗墙） | **65 W** | 主板给的，非常激进（这颗 U 是 45W 级别） |
| RAPL PL2（短时功耗墙） | **115 W** | 瞬时尖峰的元凶，风扇经常被拉满 |
| 峰值功耗墙 | 210 W | 主板设定 |
| EPP（能效偏好） | **performance** | 由 power-profiles-daemon 的 `performance` 档写入（实测：切 balanced → `balance_performance`，切 power-saver → `power`） |
| governor | powersave（intel_pstate 主动模式） | 名字叫 powersave，实际由 EPP 决定激进度 |
| max_perf_pct / no_turbo | 100 / 0 | 睿频全开，P 核冲 4.9 GHz |
| GPU 功耗墙 | 70 W（出厂 70W，**上限 105W**） | `enforced.power.limit`，目标温度 87°C |
| 风扇 | **内核完全看不到** | hwmon 里只有 coretemp/nvme/acpi/wifi/电池；无 fan*/pwm* 接口 → 风扇曲线只能走 EC 方案 |

**90°C 会不会烧坏？** 不会立刻坏：这颗 U 的 Tjmax = 100°C，到 100 自己会降频保护（你 jc 里 TCPU 临界 101°C）。但 65W 长时功耗已经超出这台模具的散热能力，长期 90-95°C 的代价是：硅脂加速老化（通常一年内就明显退化）、风扇长期满转磨损、VRM/固态/电池泡在热区。**建议把稳态目标定在 CPU ≤ 88°C、GPU ≤ 80°C。**

另外注意：你日志里 `RAPL PL1(65W) > constraint_0_max_power_uw(45W)`，说明 65W 是 BIOS 绕过 sysfs 直接写 MSR 设的；我们写回 sysfs 时固件可能限幅，脚本会把"实际生效值"打出来。

---

## 二、已经给你做好的工具

```text
/home/admin/Projects/MyArchGuide/tools/thermal-tuning/
├── README.md                      项目入口：快速开始与命令速查
├── docs/thermal.md                本文件
├── tempctl                        主程序（也可用 ~/.local/bin/tempctl 软链调用）
├── install.sh                     一键安装/卸载（含 systemd 服务、可选 sudoers）
├── check.sh                       自检：语法/sudoers/systemd/安装状态/当前温度
├── Makefile                       快捷入口（make install / status / check ...）
├── systemd/tempctl-boot.service   开机自动应用 balanced
├── systemd/tempctl-guard.service  温度守护进程（超温自动降压、降温自动恢复）
├── sudoers.d/tempctl              gamemode 免密切档用（仅限固定几条命令）
└── gamemode.ini                   丢到 ~/.config/gamemode.ini 即可玩时自动切档
```

安装（需要你输一次密码，我这边没有 sudo 权限所以没替你执行）：

```bash
# 先看现状（不用 root）
tempctl show

# 安装：开机 balanced + 温度守护，并允许 gamemode 免密切档
sudo bash /home/admin/Projects/MyArchGuide/tools/thermal-tuning/install.sh --with-sudoers
```

装好后：

```bash
# 游戏档(保帧数优先): PL1 55W PL2 90W EPP balance_performance max_perf 100%
sudo tempctl game
# 日常档: PL1 45W PL2 65W EPP balance_performance max_perf 90%
sudo tempctl balanced
# 凉快档: PL1 35W PL2 55W EPP power max_perf 60%
sudo tempctl eco
# 一键回到主板激进默认（做对比用）
sudo tempctl perf
# GPU 功耗墙 70W → 60W；gpu-reset 复原
sudo tempctl gpu 60
# 看守护日志
journalctl -u tempctl-guard -f
# 卸载（设置重启即复原）
sudo bash /home/admin/Projects/MyArchGuide/tools/thermal-tuning/install.sh --remove
```

> 装完后建议 `rm ~/.local/bin/tempctl`，避免 `~/.local/bin` 抢占 PATH 后 `sudo tempctl` 用到用户可写的那份（`~/.local/bin` 排在 `/usr/local/bin` 前面）。
> 另外 `~/.local/bin/tempctl` 是我留的软链，源码只有一份：`/home/admin/Projects/MyArchGuide/tools/thermal-tuning/tempctl`。

---

## 三、方案清单（按性价比排序，可叠加）

### 方案 A：零成本、立刻见效（不需要 root，不动配置文件）

1. **把 PPD 从 performance 换成 balanced**（实测 EPP 会从 `performance` 变成 `balance_performance`）：

   ```bash
   # 要极致凉快可 set power-saver（EPP=power）
   powerprofilesctl set balanced
   ```

   预估 -3~8°C，游戏帧数损失通常 <3%（你玩法环是 GPU 瓶颈，基本无感）。
   ⚠️ PPD 只在你"切档位"时写 EPP；重启后按上次档位重新写。装的 `tempctl-boot` 服务会在开机 3 秒后再覆盖一次，保证最终生效。
2. **确认游戏真的跑在 NVIDIA 上**（别再套 `gamemoderun`/`MangoHud`，见下面第 3 条的踩坑记录）：
   用 `prime-run` 或直接在第二个终端里查：

   ```bash
   nvidia-smi pmon -c 1
   ```

   输出里出现 `eldenring.exe` 就说明**用的是独显**（本机实测：即使启动项为空，DXVK 也会选 NVIDIA）。
   ⚠️ 不要给 EAC 游戏（法环）加 `gamemoderun` / `MANGOHUD=1` 这类注入，本机实测会**启动 9 秒后闪退**。
3. **不要在法环上用 gamemode / MangoHud 注入**（实测踩坑）：
   - `gamemoderun` 注入的 `libgamemodeauto.so.0` 在 Proton 进程里 `dlopen("libgamemode.so")` 失败（Proton 覆盖了 `LD_LIBRARY_PATH`），日志里刷 28 条 `gamemodeauto: dlopen failed` —— 也就是说 gamemode 在本机 Proton 下**根本没生效**，只是往 EAC 游戏里塞了个第三方 .so。
   - EAC 本身是**加载成功**的（`Launcher finished with: 301, 'Easy Anti-Cheat successfully loaded in-game'`），所以不是反作弊拦截。
   - ⚠️ 但注意：**清空启动项后仍然闪退过**（00:13:58→00:14:05，7 秒，无任何注入），所以"注入导致闪退"只解释了一半，完整排查见 7.7。
   - gamemode 的作用（EPP/性能模式/IO 优先级）我们已经用 `sudo tempctl game-on` 自己实现了，不需要它。
   - 想看帧数/温度就用第二个终端的 `tempctl watch` / `diag.sh`，零注入、零风险。
4. 法环内**保持 60 帧锁**（游戏自带，别解限）；菜单/过场别长时间挂着。

### 方案 B：RAPL 功耗墙（⭐ 最推荐，降温幅度最大、接口最官方）

就是 `tempctl game / balanced / eco` 干的事：写
`/sys/class/powercap/intel-rapl:0/constraint_{0,1}_power_limit_uw`。

- PL1 65W → 45W：满载封装温度预估 **-8~15°C**。法环是 60 帧封顶 + GPU 瓶颈，帧数几乎不变；代价只在多核生产力（编译/渲染）掉 10~20%。
- PL2 115W → 65~75W：削掉瞬时尖峰，风扇不会一进游戏就狂转。
- 想"我全都要"就用 `tempctl game`（PL2 保留 75W、max_perf 100%）。

### 方案 C：温度守护（动态自动，推荐和 B 一起用）

```bash
# 前台运行；装成服务后 systemd 常驻
sudo tempctl guard
```

逻辑：封装温度 ≥88°C → 逐级降压（每 8 秒最多一档：EPP→power，再 PL1 -4W，再 max_perf 80%→60%）；≤80°C 稳定 30 秒 → 缓慢恢复。阈值可在 `/etc/systemd/system/tempctl-guard.service` 里改
`TEMPCTL_TARGET / TEMPCTL_FLOOR / TEMPCTL_MIN_PL1 / TEMPCTL_MAX_PL1`。

> 打游戏时手动 `sudo tempctl game/perf` 切档不会和守护对打：guard 检测到外部改了 PL1 会先跟随实际值，再（按 2W/30 秒）逐步把 PL1 收拢回 `TEMPCTL_MAX_PL1`。想完全放手就把 `TEMPCTL_MAX_PL1` 调大，或临时 `sudo systemctl stop tempctl-guard`。
> 这是 thermald 的简化替代品。thermald 也能装（`sudo pacman -S thermald && sudo systemctl enable --now thermald`），功能重叠，**二选一**，别同时开。

### 方案 D：GPU 侧

```bash
# 70W → 60W，预估 -3~6°C，法环 60 帧下基本无感
sudo tempctl gpu 60
sudo tempctl gpu-reset
```

- 想图形化 + 持久化：`sudo pacman -S lact && sudo systemctl enable --now lactd`（LACT 支持 NVIDIA 功耗墙/频率偏移，比手敲命令稳）。
- 也可用 `sudo nvidia-smi -lgc 300,1800` 锁 GPU 频率上限（降峰温，对帧率比功耗墙更平滑）。
- 105W 那档是 EC 动态加速上限，正常游戏基本吃不到，不用管。

### 方案 E："调度"这条路（你想折腾的点）

1. 你的内核**支持 sched_ext**（实测 `CONFIG_SCHED_CLASS_EXT=y`、`/sys/kernel/sched_ext` 存在、`CONFIG_HZ=250`）。装 `scx-scheds` 后用调度器把任务"压在少数核心上"，让其余核心保持空闲低频，对 6P+4E 的 13620H 有实际降温效果：

   ```bash
   sudo pacman -S scx-scheds
   # 或 scx_bpfland / scx_rusty；--powersave 更省电更凉
   sudo scx_lavd --performance
   ```

   注意：调度器只影响 CPU 侧温度，解决不了 65W 功耗墙；和方案 B/C 叠加最舒服。
2. 内核不用换：Xanmod 的 BORE 与温度无关；想对比可以装 AUR 的 `linux-cachyos-bore`，但别期待温度差异。
3. 最直接的"睿频限制"就是 `max_perf_pct=90`（单核 4.9 → ~4.4GHz），比 `no_turbo=1`（直接掉到 3.6GHz 基频，游戏会崩帧）温和得多。

### 方案 F：风扇 / 性能模式（实验性，有风险，想更进一步再看）

前提：你这台机器**内核看不到任何风扇接口**，唯一途径是碰 EC（Embedded Controller）。

1. **先试内核自带的 `uniwill-laptop` 驱动**（Hasee 用的就是 Uniwill/Tongfang 准系统，你的 Xanmod 内核里正好有这个模块）：

   ```bash
   # 已确认: /lib/modules/$(uname -r)/.../uniwill/uniwill-laptop.ko
   modinfo uniwill-laptop | head -3
   # DMI 白名单里没有 Hasee，只能 force
   sudo modprobe uniwill-laptop force=1
   # 成功的话会多出这些
   ls /sys/class/platform_profile/ /sys/class/hwmon/*/pwm1
   ```

   - 成功 → 你就能有 `platform_profile`（low-power/balanced/performance）和风扇转速/手动风速，**这是最优雅的方案**。
   - 失败/异常（风扇停转、灯乱、卡顿）→ `sudo modprobe -r uniwill-laptop` 然后重启即可，不落盘、不改固件。
   - 想持久化要建 `/etc/modules-load.d/uniwill.conf` + `/etc/modprobe.d/uniwill.conf`（`options uniwill-laptop force=1`），但**确认稳定后再做**。
   - 风险提示：force 加载会往 EC 寄存器写"这台机器不保证支持"的值。建议空闲时测，先备份工作内容。
2. **NBFC-Linux**（AUR `nbfc-linux`）：配置文件库里只有 1 个 Tongfang 机型（`Tongfang_X6RP57TW_AIstone.json`），**没有你的 QNLXS**，得自己用 EC 读写找寄存器。
3. **tongfang-control**（AUR `tongfang-control-git`）：Tongfang 系开源控制中心，可能识别你的机型，同样属于碰 EC。
4. 自研路线：`sudo modprobe ec_sys write_support=1` → 从 `/sys/kernel/debug/ec/ec0/io` 读写字节（NBFC 就是这么工作的）。**这是最容易搞出问题的路线，不确定就别玩**。
5. 最保险的做法：**不碰 EC**，靠方案 B/C/D 把温度压下来（实测通常足够）。

### 方案 G：硬件层面（效果大、一次性投入）

- **清灰 + 换硅脂**：2023 年的机器 + 长期 90°C，硅脂大概率已退化。用**霍尼韦尔 PTM7950 相变片**替代硅脂，笔记本上通常能再降 **5~10°C**，而且比硅脂耐老化。注意 RTX 4060 Laptop 的显存/供电也要用对厚度导热垫（0.5/1.0/1.5mm 混用，别乱贴）。
- **抬高机身/散热底座/抽风散热器**：进风口在底部，垫高 2~3cm 就能 -3~5°C。
- 不要在床上/沙发上用，别堵后出风口。
- BIOS 里如果有"性能模式/办公模式"、风扇模式选项，选办公/静音档（Hasee 的 BIOS 选项少，若没有可跳过）。

### 方案 H：其他可选项

- **TLP**（`extra/tlp`）：能持久化管理 EPP、boost、max_perf_pct，非常适合笔记本；但它和 power-profiles-daemon 功能重叠，**装了要先 mask 掉 PPD**。用 TLP 的话就不需要 tempctl-boot 服务了（但 RAPL 功耗墙 TLP 管不了，那是 `tempctl` 的活）。
- **intel-undervolt**（`extra/intel-undervolt`）：如果 BIOS 没锁 MSR 0x150，降压 -50~-100mV 是**性价比最高的降温手段**（通常 -5~12°C）。先 `sudo intel-undervolt read` 再小步试 `sudo intel-undervolt apply`；13 代很多机型被锁，写不进去就直接放弃，别硬来。
- **cpupower**（`extra/cpupower`）：`cpupower frequency-set -e balance_performance` 之类的替代写法，非必须。

---

## 四、验证方法（改完一定要看数据）

```bash
# CPU 封装/最热核心/热区 TCPU/GPU 温度 + 功耗墙 + EPP
tempctl show
# 追加"封装瞬时功耗(W)"
sudo tempctl show
# 确认 PL1 真的写进去了
cat /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference
# 看守护有没有在降压
journalctl -u tempctl-guard -f
```

建议做法：进法环玩 10 分钟（营地/大世界跑一跑），记录 `TCPU` 和 `x86_pkg_temp` 的峰值，再和 `sudo tempctl perf` 的默认状态对比。**每次只改一项**，才知道是哪一项起作用。

## 五、回退

```bash
# CPU/GPU 全部回主板默认
sudo tempctl perf && sudo tempctl gpu-reset
# 停守护
sudo systemctl stop tempctl-guard
# 完整卸载
sudo bash /home/admin/Projects/MyArchGuide/tools/thermal-tuning/install.sh --remove
```

所有设置都是**运行时 sysfs**，**重启 100% 复原**，不会写坏固件（唯一例外是方案 F 的 `force=1` 加载驱动，重启也会恢复）。

## 六、最终方案（三档，取代前面所有组合）

| 命令 | 档位 | 用途 |
| --- | --- | --- |
| `sudo tempctl save` | CPU 25W / 睿频 60% / EPP power / GPU 60W | 码字、看片、低负载 |
| `sudo tempctl normal` | CPU 45W / 睿频 90% / EPP balance_performance / GPU 70W | 日常默认，开机自动应用 |
| `sudo tempctl game` | CPU 65W / 睿频 100% / EPP performance / GPU 80W | 游戏，帧数优先 |
| `sudo tempctl max` | CPU 115W（软件不设限）/ 睿频 100% / EPP performance / GPU 105W（硬件上限） | 短时爆发、压测；会贴着 100°C 温度墙 |

决策依据（都在本文里能找到数据）：

1. **游戏档直接给 65W**：实测 55W 时 5 核满载把 P 核从 4.7GHz 压到 3.0GHz，而 CPU 温度只有 63~67°C ⇒ 限制是功耗墙不是散热（见 7.8）。
2. **不留 `guard`**：它降档/恢复的过程本身就是帧数波动源，实际收益为负（见 7.2 第 1 条与守护日志）。
3. **不用 gamemode / MangoHud 注入**：EAC 游戏会闪退，且 gamemode 在本机 Proton 下本来就不生效（见 7.7）。
4. **剩下的空间在硬件**：清灰 + PTM7950 相变片，通常再降 5~10°C。

## 七、帧数不稳排查（法环 40~50fps 实录）

### 7.1 现场数据与判断

| 观测 | 数值 | 结论 |
| --- | --- | --- |
| 游戏是否用独显 | `nvidia-smi pmon` 显示 eldenring.exe 在 GPU 0（C+G） | 独显正常 |
| 游戏吃 CPU | 采样那刻整机忙 ~10%（大概率在菜单/暂停，需战斗中复测） | 要用 `diag.sh` 抓实战 |
| GPU | 27% 利用率 / 40W / 2520MHz，无热限无功耗墙 | GPU 没跑满 → 瓶颈不在 GPU |
| 内存 | 15.7G 用满，**1.9GB 已换出**到 LUKS+Btrfs 的 swapfile | ⚠️ 帧生成时间的头号杀手 |
| Steam | 主进程 + steamwebhelper + WebKit ≈ **1.26 个核** | ⚠️ 白抢一个核 |
| guard | 日志里 45W↔41W、EPP balance↔power、max_perf 100↔80 **来回切** | ⚠️ 撤档/恢复本身就是抖动源 |
| 屏幕 | 内屏 2560x1440@165Hz，**VRR: disabled** | ⚠️ 40~60fps 时抖动感被放大 |
| 启动项 | appid 1245620（法环）**没有任何启动项** | 建议显式 `prime-run` |

### 7.2 按影响力排序的修法

1. **停掉 guard 或放宽阈值**（别让它自己制造抖动）：

   ```bash
   # 打游戏期间停；平时 sudo systemctl start
   sudo systemctl stop tempctl-guard
   # 长期放宽：改 /etc/systemd/system/tempctl-guard.service
   #   TEMPCTL_TARGET=92  TEMPCTL_FLOOR=86  TEMPCTL_MAX_PL1=55
   ```

2. **打游戏前关掉 Steam 主窗口**（客户端留在后台即可）：Steam 的 CEF 界面在 Wayland/Xwayland 下经常吃满一个核。
   顺带关掉 OBS、浏览器、IDE/CLI 服务（`code-sidecar`、`cline-desktop` 也吃内存和 CPU）。
3. **内存**：15.7GB 装不下"法环 6.5GB + 一堆常驻服务"。两个做法：
   - 装 zram 当压缩内存：`sudo pacman -S --asdeps zram-generator`，写 `/etc/systemd/zram-generator.conf`：

     ```ini
     [zram0]
     zram-size = ram / 2
     compression-algorithm = zstd
     ```

     比 LUKS+Btrfs 上的换页快一个数量级，掉帧会明显缓解。
   - 有 SO-DIMM 空槽就加内存条，最省心。
4. **开 VRR**（让 40~60fps 的波动看起来顺）：DMS 生成的 `~/.config/niri/dms/outputs.kdl` 给 eDP-1 加 `variable-refresh-rate`，
   或在 DMS 的显示设置里打开 VRR；改完 `niri msg outputs` 应显示 `Variable refresh rate: supported, enabled`。
5. **游戏档改成保帧数优先**：`sudo tempctl game` 现在是 **PL1 55W / PL2 90W / EPP balance_performance / max_perf 100%**。
   想更凉用 `balanced`/`eco`，但要接受帧数波动。
6. **启动项保持"零注入"**：法环（EAC）不要加 `gamemoderun`/`MANGOHUD=1`（实测 9 秒闪退）。要限制核心用
   `taskset -c 0-11 %command%`，要指定独显用 `prime-run %command%`，但**一次只加一个**、每个跑 1 分钟验证。
7. **画质/分辨率**：1440p 内屏对 70W 的 4060 偏重，重场景掉帧就降一档画质，或用 gamescope + FSR 内部分辨率缩放。

### 7.3 实战数据（法环跑图 180 秒）

| 指标 | 实测（PL1 55W / EPP balance_performance / 守护已停） | 判断 |
| --- | --- | --- |
| 游戏占用 CPU | **平均 406%**（≈4 个核跑满） | CPU 是瓶颈 |
| 系统繁忙 | 平均 29% | 其余负载不大 |
| GPU 利用率 | 平均 **50%**、峰值 78% | GPU 有一半时间在等 CPU |
| GPU 功耗/墙 | 平均 54.9W、峰值 63.9W（墙 70W） | 没撞 GPU 墙 |
| CPU 封装温度 | 平均 66°C、**峰值 83°C** | 离 95/100°C 还有 12°C 余量 |
| PL1 | 全程 55W 未被动过 | 没有被守护干预 |
| 内存 | 游戏峰值 7.4GB、可用最低 3.1GB、swap 增量 −1MB | 本次没恶化（但存量 2.2GB） |

**结论：CPU 瓶颈 + 没有帧同步补偿。** 温度与 GPU 都不是问题，所以修法方向是"喂饱 CPU / 减少它的等待"，而不是继续压温度。

### 7.4 针对 CPU 瓶颈的具体做法

1. **法环启动项**：先确认基线能进游戏（清空启动项），再**一次只加一个**逐步试，每个跑 1 分钟：
   1. `taskset -c 0-11 %command%` ← 推荐保留：Linux 层绑 P 核，**零注入、不改 Wine 环境**，EAC 完全看不见
   2. `WINE_CPU_TOPOLOGY=6:12 %command%` ← 可选：让 Wine 只看到 6 个 P 核（换了 CPU 拓扑，若闪退就丢掉）
   3. 想要的独显指定用 `prime-run %command%`（本机即使不加也已经跑在 NVIDIA 上，所以非必要）
   ⚠️ **不要加 `gamemoderun` / `MANGOHUD=1`**：实测 `libgamemodeauto.so.0` 在 Proton 里 `dlopen` 失败（28 条报错）；不过"清空启动项后仍闪退"说明它不是唯一原因，完整排查见 7.7。
   ⚠️ 想精确定位哪一个出问题：临时用 `PROTON_LOG=1 <你的启动项> %command%`，会生成 `~/steam-1245620.log`，把里面的 error 段发我。
2. **开 VRR**（现在 `niri msg outputs` 仍是 `disabled`）：165Hz 固定刷新下，40~60fps 的节奏不匀会被放大成"卡"的感觉。
3. **混合核调度器**（可选，针对 6P+4E 很明显）：

   ```bash
   sudo pacman -S scx-scheds
   sudo scx_lavd --performance
   ```

4. **把温度余量换成帧数**：峰值才 83°C，可以把 PL1 放到 65W、EPP 放 performance 试试（预计 88~90°C）：

   ```bash
   sudo env TEMPCTL_GAME_PL1=65 TEMPCTL_GAME_PL2=115 TEMPCTL_GAME_EPP=performance tempctl game
   ```

   （档位现在支持用 `TEMPCTL_*` 环境变量临时覆盖，见 `tempctl --help`）
5. **减少 CPU 竞争者**：关掉 Steam 主窗口（CEF 界面 + steamwebhelper 实测约 1.26 个核）、OBS、浏览器、IDE；重启一次可清掉存量 2.2GB 的 swap。
6. **降 CPU 侧的画质项**（降分辨率对 CPU 瓶颈没用）：阴影质量、草木/植被、绘制距离、光照等。
7. **着色器编译**：法环首次进入新场景的卡顿来自 DXVK 管线编译，同一场景多跑几次会明显好转（状态缓存落盘）。

### 7.5 下次怎么看有没有被限频

`diag.sh` 已新增两列：`P核频率MHz` 与 `限频计数`（`package_throttle_count + core_throttle_count`）。
如果"限频事件"每分钟几十次以上、同时 P 核频率上不去（<3500MHz），就说明是 PL1/温度在卡帧数，直接按 7.4 第 4 条放开 PL1。

### 7.6 抓实战数据的办法（diag.sh）

```bash
cd /home/admin/Projects/MyArchGuide/tools/thermal-tuning
# 先跑它，再启动游戏玩 2~3 分钟，跑完看最后的"结论"段
bash diag.sh 180 ~/eldenring-1.csv
```

跑完直接给结论段（GPU 瓶颈 / CPU 紧张 / 内存压力 / 撞温度墙 / 都没跑满），CSV 留着做前后对比。
游戏内同时开 MangoHud 看 fps + frametime 曲线，两者对照即可定位抖动来源。

### 7.7 法环闪退排查记录（2026-09-30 00:0x）

现象：游戏启动后 5~9 秒静默退出（无报错弹窗、无崩溃转储）。

启动对照（Steam `content_log.txt` + `console-linux.txt` 按行号切分）：

| 时间 | 结果 | `gamemodeauto` 报错 | MANGOHUD | 启动项 |
| --- | --- | --- | --- | --- |
| 23:39:56 | ✅ 8.5 分钟 | 0 | 0 | 空 |
| 00:01:19 | ✅ 5.7 分钟 | 0 | 0 | 空 |
| 00:08:52 | ❌ 9 秒 | 28 | 3 条 | `gamemoderun MANGOHUD=1 ...` |
| 00:13:58 | ❌ 7 秒 | 0 | 0 | 空 |

已逐项排除：

| 假设 | 证据 | 结论 |
| --- | --- | --- |
| EAC 拦截 | `anticheatlauncher.log`: `301, 'Easy Anti-Cheat successfully loaded in-game'`（每次都有） | 排除 |
| GPU/驱动故障 | `dmesg`/`journalctl -k` 该窗口无 `Xid`/`nvrm` 记录；模块与用户态同为 `615.71.09` | 排除 |
| 存档损坏 | `ER0000.sl2` 28,967,888 字节，文件头 `BND4` 合法 | 排除 |
| Proton 被中途更新 | 最近一次更新是 09-28 12:22；崩溃时用的是 `experimental-11.0-20260924` | 排除 |
| 残留 wineserver 锁 | `pgrep wineserver` 无输出 | 排除 |
| sched_ext 调度器干扰 | `/sys/kernel/sched_ext/root/ops` 未加载 | 排除 |
| 系统包被改 | `pacman.log` 近 6 小时只有 cline-desktop | 排除 |
| 独占全屏模式不匹配 | `xrandr` 显示 Xwayland 给游戏的就是 2560x1440@164.9，与 `GraphicsConfig.xml` 一致 | 证伪（但仍建议改无边框规避） |
| 管线缓存损坏 | `vkd3d-proton.cache` mtime 停留在正常运行的 00:01，且无 `.write` 残留 | 可能性低 |

已做的处理：

- 把 `AppData/Roaming/EldenRing/GraphicsConfig.xml` 的 `<ScreenMode>FULLSCREEN</ScreenMode>` 改成 `BORDERLESS`
  （备份：`GraphicsConfig.xml.bak-before-borderless`）。独占全屏在 Xwayland/Wayland 合成器下是最常见的秒退诱因之一，值得先规避。
- **结果：改成无边框后游戏正常进入并连续跑了 3 分钟（00:18~00:20 跑图），闪退问题解决。**
  （不能 100% 归因于这一项——期间也没有其他改动，但同样的排除法说明它就是唯一变量。）

### 7.8 跑图只有 33fps：实测是"功耗墙压主频"，不是温度

同一套工具复测 3 分钟（PL1 55W / EPP balance_performance）：

| 时间 | 游戏CPU | GPU | CPU温度 | P核频率 | 限频计数 |
| --- | --- | --- | --- | --- | --- |
| 00:18:28 | 465% | 69% | 72°C | **4700MHz** | 18777 |
| 00:19:03 | 539% | 55% | 86°C | 3823MHz | 18777 |
| 00:19:21 | 511% | 55% | 63°C | 3334MHz | +6 |
| 00:19:40 | 510% | 41% | **67°C** | **3071MHz** | +28 |

**关键：温度只有 63~67°C 时 P 核已被压到 3.0GHz ⇒ 55W 的 PL1 撑不住 5 个核跑 4.7GHz ⇒ 主频掉 25%，帧数跟着掉。**
（限频计数 21 次/分钟，全部是功耗墙事件，不是热降频。）

处置（按收益）：

1. **放开 PL1 换频率**（一条命令，先做这个 A/B）：

   ```bash
   sudo tempctl game-on game-max
   ```

   等价于"停守护 + PL1 65W / PL2 115W / EPP performance / max_perf 100%"（内置档位，免密、不用记环境变量）。
   也可以用环境变量临时微调任意档位（**只影响当次运行，不写任何配置文件**）：

   ```bash
   sudo env TEMPCTL_GAME_PL1=60 TEMPCTL_GAME_EPP=performance tempctl game
   ```

   预期 P 核能稳在 4.2~4.7GHz，帧数 +15~25%；代价是峰值温度回到 90~95°C。
   如果持续 ≥95°C 再退到 `TEMPCTL_GAME_PL1=60`。
2. **GPU 墙抬到 80W**（实测峰值 68.4W/70W 已贴墙）：`sudo tempctl gpu 80`
3. **打开 VRR**（仍是 disabled）：33~45fps 在固定 165Hz 下的"卡"感大半来自帧同步。
4. **重启清掉 2.5GB 存量 swap**（本次会话又新增 128MB 换出）。
5. 降低 CPU 侧画质（阴影 / 草木 / 绘制距离 / SSAO），比降分辨率有用。
6. 可选 A/B：`taskset -c 0-11 %command%`、或换 GE-Proton11-7 对比。

后续排查阶梯（按成本从低到高）：

1. 直接再启动一次（此时已是无边框）。
2. 重启系统后重试（清掉 GPU/ntsync/prefix 的残留状态）。
3. Steam → 法环 → 属性 → 已安装文件 → **验证游戏文件完整性**。
4. 清理管线缓存：删除游戏目录下的 `vkd3d-proton.cache` 与 `~/.local/share/Steam/steamapps/shadercache/1245620/fozpipelinesv6`，让它重建。
5. 换 Proton：属性 → 兼容性 → 强制使用 **GE-Proton11-7**（已装）或 **Proton 11.0**。
6. 抓真实报错：启动项临时写 `PROTON_LOG=1 %command%`，崩溃后把 `~/steam-1245620.log` 的最后 100 行发出来分析
   （`grep -iE 'err:|wine:|vkd3d|vulkan|device' ~/steam-1245620.log | tail -50`）。

## 八、修复记录

| 版本 | 内容 |
| --- | --- |
| 2.3.0 | 开机默认改为 `max`（不设限，想降温自己切）；新增 `switch.sh`（切档/看状态 + `notify-send` 通知反馈）并绑定 niri 快捷键 `Super+Alt+1~4`（省电/日常/游戏/不设限）与 `Super+Alt+0`（看状态），已用 `niri validate` 校验、键位与原 DMS 绑定无冲突；`install.sh` 装完会 `restart tempctl-boot.service` 让新档位立即生效。 |
| 2.2.0 | 查清并与 PPD 的关系：PPD 只写 `EPP`/`no_turbo`（不碰 RAPL 功耗墙、不碰 GPU），是本机唯一会覆盖档位的程序；`tempctl` 查看状态时会提示 PPD 是否在运行及当前档位；`install.sh` 新增 `--mask-ppd` / `--unmask-ppd`（本机 niri+DMS 无任何配置引用 PPD，屏蔽无副作用）；README 新增 1.1 节冲突矩阵。 |
| 2.1.0 | 新增第 4 个档位 `max`（不设限）：CPU PL1/PL2 = 115W（软件不设限，实际由 100°C 温度墙兜底）、GPU = 105W（硬件上限）、EPP performance、睿频 100%，并在应用时提示高温风险；sudoers / Makefile / install.sh / README 同步。另：所有档位现在都会写 `no_turbo=0`。 |
| 2.0.0 | 大简化：只保留 `save / normal / game` 三个档 + `show`，删除 `guard` 服务与 `balanced/eco/perf/game-max/game-on/game-off/epp/gpu/watch/csv` 子命令、`gamemode.ini`、`mangohud.conf`；GPU 墙并入档位；`install.sh` 自动清理旧版遗留；`diag.sh` 输出改到 `logs/`。 |
| 1.0.9 | 新增内置档位 `game-max`（PL1 65W / PL2 115W / EPP performance / max_perf 100%），并支持 `tempctl game-on game-max` 一步到位（停守护 + 切档）；sudoers 白名单与 Makefile（`make game-max`）同步；文档补充说明"`TEMPCTL_*` 环境变量覆盖只影响当次运行、不写任何配置文件"。 |
| 1.0.8 | 新增 7.8「跑图只有 33fps」实测分析：温度仅 63~67°C 时 P 核被压到 3.0GHz（PL1 55W 功耗墙），限频 21 次/分钟 ⇒ 结论是"功耗墙压主频"而非温度；给出 A/B 命令（PL1 65W + EPP performance）、GPU 墙 80W、开 VRR、清 swap、降 CPU 侧画质。7.7 记录"改无边框后不再闪退（连续跑 3 分钟）"。 |
| 1.0.7 | 新增 7.7「法环闪退排查记录」：完整证据链 + 逐项排除（EAC 加载成功、GPU 无 Xid、存档 BND4 合法、Proton 未更新、无残留 wineserver、无 sched_ext、包未变）+ 处理阶梯（无边框/重启/校验文件/清缓存/换 Proton/`PROTON_LOG=1`）；修正 1.0.6 里"闪退=注入造成"的过满结论（清空启动项后仍有一次 7 秒闪退）；已把 `GraphicsConfig.xml` 的 `ScreenMode` 从 `FULLSCREEN` 改为 `BORDERLESS`（留备份）。 |
| --- | --- |
| 1.0.6 | 修正文档里的错误建议：法环（EAC）**不能**用 `gamemoderun`/`MANGOHUD=1` 注入 —— 实测 `libgamemodeauto.so.0` 在 Proton 中 `dlopen("libgamemode.so")` 失败（Steam 控制台刷 28 条报错）并导致启动 9 秒闪退（两次零注入启动分别正常跑 5.7/8.5 分钟，EAC 日志显示其自身加载成功 `301`）。`gamemode.ini` 与 docs 第六/七节均加上警告，推荐的零注入替代：`taskset -c 0-11 %command%` + 外部 `tempctl watch`/`diag.sh` 监控。 |
| 1.0.5 | `diag.sh` 新增 `P核频率MHz` 与 `限频计数`（package+core throttle 计数）两列，并在结论里报告"限频事件/分钟"；所有档位的 PL1/PL2/EPP/max_perf 支持用 `TEMPCTL_*` 环境变量临时覆盖（例：`sudo env TEMPCTL_GAME_PL1=65 TEMPCTL_GAME_EPP=performance tempctl game`）；docs 补上法环 180 秒实战数据与 CPU 瓶颈的处置方案。 |
| 1.0.4 | 新增 `game-on` / `game-off` 游戏模式（一条命令：暂停/恢复温度守护 + 切 game/balanced 档），`make game-on`、sudoers 白名单同步更新；`SYSTEMCTL` 可用环境变量覆盖以便离线自测；文档里所有"命令 + 行内注释"改成独立注释行（zsh 交互式默认不把行内 `#` 当注释，直接粘贴会报错），并在 `~/.zshrc` 加入 `setopt INTERACTIVE_COMMENTS`。 |
| 1.0.3 | `game` 档改为保帧数优先（PL1 55W/PL2 90W/EPP balance_performance/max_perf 100%）；`guard` 默认不再切 EPP（新增 `TEMPCTL_GUARD_EPP_FLIP`，默认 0），降压改为 PL1 + 睿频上限分级，回到 0 档时还原启动时的 EPP/max_perf；新增 `diag.sh` 游戏期诊断与瓶颈结论。 |
| 1.0.2 | 新增 `watch`（实时一行式监控）与 `csv`（采样落盘对比）；`guard` 现在会跟随外部 PL1 改动（手动切档不会被守护进程对打）；`csv` 修正 Ctrl-C/SIGTERM 不能退出的问题；`install.sh` 覆盖脚本后 `try-restart` 守护进程（bash 是按需读文件，否则会读到半新半旧的代码）；新增 `mangohud.conf` 与 `make mangohud`。 |
| 1.0.1 | 修正 `apply()` 末尾 `[[ $name == perf* ]] && info` 泄漏退出码（非 perf 档位时脚本 exit 1），导致 `tempctl-boot.service` 被 systemd 判为失败；现在改为"逐项记录失败、末尾统一返回"，只有真的写不进去才返回非零。`install.sh` 也改成单个服务启动失败不再中断整个安装。 |
| 1.0.0 | 首版：`show` / `balanced` / `game` / `eco` / `perf` / `guard` / `gpu`。 |
