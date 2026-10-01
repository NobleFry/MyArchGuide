# thermal-tuning

Hasee QNLXS（i7-13620H + RTX 4060 Laptop）在 Arch + Xanmod 上的**极简温控**：四个档位 + 一个查看命令。

> 调查过程、实测数据和"为什么这么定"记在 [docs/thermal.md](docs/thermal.md)（历史文档）。

## 1 最终方案：四条命令

| 命令 | 档位内容 | 什么时候用 |
| --- | --- | --- |
| `sudo tempctl save` | CPU 25W / 睿频 60% / EPP power / GPU 60W | 码字、看片、低负载（凉、安静） |
| `sudo tempctl normal` | CPU 45W / 睿频 90% / EPP balance_performance / GPU 70W | **日常默认，开机自动应用** |
| `sudo tempctl game` | CPU 65W / 睿频 100% / EPP performance / GPU 80W | 游戏（帧数优先，温度 90~95°C） |
| `sudo tempctl max` | CPU 115W（软件不设限）/ 睿频 100% / EPP performance / GPU 105W（硬件上限） | 短时爆发、跑分、压测 |
| `tempctl` | — | 查看当前温度 / 频率 / 功耗墙（只读，不需要 sudo） |

**关于 `max`（不设限档）**：CPU 功耗墙直接放到 115W、GPU 用硬件上限 105W，
也就是说**软件层面不再限制**，剩下由硬件自己兜底 —— CPU 会贴着 **100°C 温度墙**降频、风扇满转。
适合短时爆发或压测；长时间挂着会让机身持续 95~100°C，对硅脂和风扇不友好。
（想"高性能但可持续"，用 `game` 档；想凉快，用 `normal`/`save`。）

**为什么游戏档是 65W**：实测 55W 时 5 个核满载会把 P 核从 4.7GHz 压到 3.0GHz，
而那时 CPU 温度只有 63~67°C —— 限制来自**功耗墙**而不是散热，放开到 65W 帧数明显更好。

所有档位都只写内核运行时参数（RAPL / intel_pstate / NVML），**不修改任何配置文件，重启全部还原**。

### 1.1 和 power-profiles-daemon（PPD）的关系

| 谁管什么 | tempctl | PPD |
| --- | --- | --- |
| CPU 功耗墙 PL1 / PL2（RAPL） | ✅ 独占 | ❌ 碰不到 |
| GPU 功耗墙（NVML） | ✅ 独占 | ❌ 碰不到 |
| 睿频上限 `max_perf_pct` | ✅ 独占 | ❌ 碰不到 |
| **EPP 能效偏好** | ✅ 每个档位都会写 | ⚠️ **它切档时也会写**（会覆盖我们的值） |
| **`no_turbo` 睿频开关** | ✅ 每档写 0 | ⚠️ 它有能力写 |

**结论：只有 EPP / no_turbo 会打架。** 具体表现：

- 切完 tempctl 档位后，如果再去动 PPD 的档位（`powerprofilesctl set ...` 或桌面上的电源开关），EPP 会被 PPD 改回去
  —— 例如 `save` 档的 `EPP=power` 会被 PPD 的 `performance` 覆盖（功耗墙还在，所以只是能效特性变了）。
- 开机顺序已经处理好：`tempctl-boot.service` 里 `After=power-profiles-daemon.service` + 等 3 秒，
  所以每次开机最终生效的是 `normal`。
- 你机器上**只装了 PPD**（没有 TLP / thermald / auto-cpufreq），而且 niri + DMS 里**没有任何配置引用 PPD**
  （已 grep 确认），所以屏蔽它不会有副作用。

两种处理方式：

```bash
# 方案 A（推荐）：屏蔽 PPD，让 tempctl 独占 —— 档位再也不会被覆盖
sudo ./install.sh --mask-ppd

# 方案 B：留着 PPD，但把它固定在 balanced 并别再切它
powerprofilesctl set balanced
```

方案 A 的代价：`powerprofilesctl` 会失效（daemon 被 mask）。想恢复：`sudo ./install.sh --unmask-ppd`。
另外 `tempctl` 查看状态时会自动提示 PPD 是否在运行。

## 2 安装（一次性）

```bash
cd /home/admin/Projects/MyArchGuide/tools/thermal-tuning
sudo ./install.sh         # 装 /usr/local/bin/tempctl + 开机应用 max + wheel 组免密切档
sudo ./install.sh --mask-ppd   # 推荐：屏蔽 power-profiles-daemon，档位不再被它覆盖
make check                # 自检（PASS/FAIL 汇总）
```

**开机默认是 `max`（不设限）** —— 也就是开机不做任何限制，想降温自己按快捷键切档。
如果你更想"开机就是安静的日常档"，把 `systemd/tempctl-boot.service` 里的 `ExecStart=... max`
改成 `... normal` 再跑一次 `sudo ./install.sh` 即可。

`install.sh` 会顺手清理旧版遗留（旧的温度守护服务、旧的软链），`--remove` 可完整卸载。

## 3 快捷键（niri / DMS）

已写入 `~/.config/niri/config.kdl` 末尾（用 `niri validate` 校验过），按 `Super+Alt+1~4` 直接切档，右下角会弹通知确认：

| 快捷键 | 作用 |
| --- | --- |
| `Super+Alt+1` | 省电码字档（CPU 25W / GPU 60W） |
| `Super+Alt+2` | 日常均衡档（CPU 45W / GPU 70W） |
| `Super+Alt+3` | 游戏档（CPU 65W / GPU 80W） |
| `Super+Alt+4` | 不设限档（CPU 115W / GPU 105W） |
| `Super+Alt+0` | 弹通知看当前温度和功耗墙（不开终端） |

- 这些键位原先都没被占用（DMS 占的是 `Mod+1..9`、`Mod+Shift+1..9`、`Mod+Shift+N` 等）。
- 实际执行的是 [switch.sh](switch.sh)：调 `sudo -n tempctl <档位>` + `notify-send` 反馈。
- 想换成字母键：把 config.kdl 里那几行改成 `Mod+Shift+S`（省电）/ `Mod+Shift+G`（游戏）/ `Mod+Shift+M`（不设限）即可（已确认空闲）。
- 备份：`~/.config/niri/config.kdl.bak-thermal`。

## 4 日常怎么用

1. 开机自动 `max`，觉得热/吵就按 `Super+Alt+1`（省电）或 `Super+Alt+2`（日常）。
2. 打游戏前按 `Super+Alt+3`（游戏档），打完按 `Super+Alt+2` 回日常。
3. 掉帧想查原因：`bash diag.sh 180`（边玩边记录，跑完直接输出瓶颈结论），CSV 落在 `logs/`。
4. 重启会恢复主板默认，随后由开机服务再应用 `max`。

## 4 文件结构

```text
thermal-tuning/
├── README.md              本文件：最终方案
├── tempctl                四档温控（save / normal / game / max + 状态查看）
├── switch.sh              快捷键前端（切档 + 通知反馈）
├── install.sh             安装/卸载（含旧版遗留清理）
├── check.sh               自检
├── diag.sh                游戏期诊断（采样 → 瓶颈结论）
├── Makefile               make install|status|check|save|normal|game|diag
├── systemd/tempctl-boot.service    开机应用 normal
├── sudoers.d/tempctl      免密规则（只放行三个档位）
├── logs/                  diag.sh 产出的 CSV
└── docs/thermal.md        调查记录与决策依据（历史文档）
```

## 5 已经砍掉的东西（以及原因）

| 删掉的 | 原因 |
| --- | --- |
| `tempctl-guard` 温度守护服务 | 实测无用：它反复降档/恢复本身就是帧数波动的来源，游戏里还得手动停掉 |
| `balanced / eco / perf / game-max / game-on / game-off / epp / gpu / watch / csv` 子命令 | 参数太多；已合并成三个档位，GPU 墙随档位自动设置 |
| `gamemode.ini` / `make gamemode` | 本机 Proton 下 gamemode 不生效（`libgamemodeauto.so.0` dlopen 失败），并会让 EAC 游戏（法环）闪退 |
| `mangohud.conf` / `make mangohud` | 往 EAC 游戏里注入 overlay 有风险；监控改用第二终端的 `diag.sh`，零注入 |

## 6 回退与卸载

```bash
sudo tempctl normal            # 回到日常档
sudo ./install.sh --remove     # 完整卸载（重启后一切还原为出厂）
```

## 7 剩下的硬件空间

想在高负载下同时做到低温 + 高频，最后只能靠散热硬件：清灰 + 换 PTM7950 相变片（通常再降 5~10°C）。
软件这一层（功耗墙 / 睿频 / EPP / GPU 墙）已经调到该调的位置了。
