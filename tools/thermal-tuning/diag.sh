#!/usr/bin/env bash
# =============================================================================
#  diag.sh —— 游戏期间记录系统状态，跑完直接给"瓶颈判断"
#    用法: bash diag.sh [时长秒] [csv文件]
#          bash diag.sh 180 ~/eldenring-1.csv
#    流程: 先开这个脚本，再启动游戏，玩 2~3 分钟（尽量跑到掉帧的场景），退出后看"结论"段。
#    全部只读、不需要 root；游戏内建议同时开 MangoHud 看 fps/frametime 曲线。
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUR=${1:-120}
OUT=${2:-$ROOT/logs/thermal-diag-$(date +%m%d-%H%M%S).csv}
IV=2
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
GAME_RE=${GAME_RE:-'eldenring|\.exe|wine|proton|gamescope'}

hwmon_path() { local w=$1 d; for d in /sys/class/hwmon/hwmon*; do
    [[ -r $d/name && "$(<"$d/name")" == "$w" ]] && { echo "$d"; return 0; }; done; return 1; }
pkg_temp()   { local d; d=$(hwmon_path coretemp) || return 1; echo $(( $(<"$d/temp1_input") / 1000 )); }
hot_temp()   { local d f m=0 v; d=$(hwmon_path coretemp) || return 1
    for f in "$d"/temp*_input; do [[ -r $f ]] || continue; v=$(( $(<"$f") / 1000 )); (( v > m )) && m=$v; done; echo "$m"; }
zone_temp()  { local z n; for z in /sys/class/thermal/thermal_zone*; do
    n=$(cat "$z/type" 2>/dev/null) || continue; [[ $n == "$1" ]] && { echo $(( $(cat "$z/temp") / 1000 )); return 0; }; done; return 1; }
pl_w()       { local f="/sys/class/powercap/intel-rapl:0/constraint_${1}_power_limit_uw"
    if [[ -r $f ]]; then echo $(( $(<"$f") / 1000000 )); else echo 0; fi; }
pfreq()      { # P 核当前最高频率(MHz)
    local p m=0 v maxf
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        maxf=$(cat "$p/cpuinfo_max_freq" 2>/dev/null || echo 0)
        (( maxf >= 4000000 )) || continue
        v=$(cat "$p/scaling_cur_freq" 2>/dev/null || echo 0)
        (( v > m )) && m=$v
    done
    echo $(( m / 1000 ))
}
throttle_cnt() { # 功耗/温度限频事件累计计数（把 package 与 core 相加）
    local a b
    a=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count 2>/dev/null || echo 0)
    b=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo 0)
    echo $(( a + b ))
}
epp_now()    { local p v out=""; for p in /sys/devices/system/cpu/cpufreq/policy*; do
    [[ -r $p/energy_performance_preference ]] || continue; v=$(<"$p/energy_performance_preference")
    case " $out " in *" $v "*) ;; *) out="$out $v";; esac; done; echo "${out# }"; }
cpu_snap()   { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }
game_procs() { ps -eo pid=,comm=,args= --no-headers 2>/dev/null | grep -Ei "$GAME_RE" | grep -v 'diag.sh' | awk '{print $1}'; }

summarize() {
    awk -F, -v dur="$DUR" '
    NR == 1 { next }
    { n++
      for (i = 2; i <= NF; i++) { v = $i + 0; s[i] += v; if (v > mx[i]) mx[i] = v; if (min[i] == "" || v < min[i]) min[i] = v }
      if (first_swap == "") first_swap = $14
      last_swap = $14
      if (first_th == "") first_th = $20
      last_th = $20
    }
    END {
      if (!n) { print "  没有采到数据（游戏进程没被识别？可用 GAME_RE=... 调整匹配）"; exit }
      printf "  采样 %d 次 / %s 秒\n", n, dur
      printf "  CPU 封装温度   平均 %.0f°C  峰值 %.0f°C（最热核峰值 %.0f°C）\n", s[2]/n, mx[2], mx[3]
      printf "  热区 TCPU      峰值 %.0f°C\n", mx[4]
      printf "  GPU 温度       平均 %.0f°C  峰值 %.0f°C\n", s[9]/n, mx[9]
      printf "  GPU 利用率     平均 %.0f%%  峰值 %.0f%%\n", s[11]/n, mx[11]
      printf "  GPU 功耗/墙    平均 %.1fW  峰值 %.1fW（当前墙 %dW）\n", s[10]/n, mx[10], mx[12]
      printf "  系统繁忙/游戏  平均 %.0f%% / %.0f%%（一个核=100%%）\n", s[7]/n, s[8]/n
      printf "  内存          游戏峰值 %.0fMB  可用最低 %.0fMB  交换峰值 %.0fMB（增量 %.0fMB）\n", \
             mx[15], min[13], mx[14], last_swap - first_swap
      printf "  PL1 区间       %dW ~ %dW\n", min[5], mx[5]
      printf "  P 核频率       平均 %d MHz  峰值 %d MHz（上限 4900）\n", s[19]/n, mx[19]
      printf "  限频事件       本次会话 %d 次（%.1f 次/分钟；PL1 或温度触发）\n", last_th - first_th, (last_th - first_th) / (n * 2 / 60)
      print  "  结论："
      hit = 0
      if (mx[11] >= 85 && s[10]/n >= mx[12] * 0.8) {
          print "    → GPU 瓶颈（利用率高且贴着功耗墙）：降画质/分辨率，或把 GPU 墙抬到 80W"; hit++
      }
      if (s[8]/n >= 250 && s[11]/n < 85) {
          print "    → CPU 侧紧张（游戏吃满多个核、GPU 没跑满）：别压 PL1/别限睿频，关掉抢 CPU 的程序（Steam 窗口/浏览器/OBS）"; hit++
      }
      if (last_swap - first_swap >= 200 || min[13] < 1200) {
          print "    → 内存压力（本次会话新增换出 ≥200MB 或可用内存最低 <1.2GB）：关程序、装 zram"; hit++
      } else if (mx[14] >= 500) {
          print "    → 注意：系统里本来就有 " int(mx[14]) " MB 被换出（不是本次产生的），游戏触发换回时会瞬间卡顿，重启可清掉"; hit++
      }
      if (mx[2] >= 95) {
          print "    → 撞温度墙（CPU 封装 ≥95°C）：靠功耗墙/降压/清灰换硅脂解决，降画质没用"; hit++
      }
      if (last_th - first_th >= n / 2) {
          printf "    → CPU 被限频 %d 次（%.0f 次/分钟）：帧数不够稳就把 PL1 放开，例如 PL1=65W + EPP=performance\n", last_th - first_th, (last_th - first_th) / (n * 2 / 60); hit++
      }
      if (s[11]/n < 70 && s[7]/n < 60 && s[8]/n < 100) {
          print "    → CPU/GPU 都没跑满：典型是垂直同步/合成器/帧率上限不匹配（开 VRR、核对刷新率、试关游戏内垂直同步）"; hit++
      }
      if (!hit) print "    → 没有单项瓶颈：用 MangoHud 看 frametime 曲线，抖动多来自着色器编译或内存换页"
    }' "$OUT"
}


echo "== 记录开始：时长 ${DUR}s，间隔 ${IV}s → $OUT =="
mkdir -p "$(dirname "$OUT")"
echo "   现在启动游戏，玩 2~3 分钟（尽量跑到掉帧的场景）。Ctrl-C 可提前结束并直接看结论。"
echo "时间,CPU封装,最热核,TCPU,PL1,PL2,系统繁忙,游戏CPU,GPU温度,GPU功耗,GPU利用率,GPU墙,可用内存MB,Swap已用MB,游戏内存MB,GPU频率,EPP,max_perf,P核频率MHz,限频计数" >"$OUT"
trap 'echo; echo "== 提前结束，汇总 =="; summarize; echo; echo "  原始数据: '"$OUT"'"; exit 0' INT TERM

declare -A PREV_T
start=$SECONDS; pb=0; pi=0; first=1
while (( SECONDS - start < DUR )); do
    read -r tot idle < <(cpu_snap)
    if (( first )); then busy=0; first=0; else
        dt=$(( tot - pb )); di=$(( idle - pi )); busy=$(( dt > 0 ? (dt - di) * 100 / dt : 0 ))
    fi
    pb=$tot; pi=$idle

    gtotal=0; grss=0
    for p in $(game_procs); do
        t=$(awk '{print $14+$15}' "/proc/$p/stat" 2>/dev/null) || continue
        r=$(awk '{print $2}' "/proc/$p/statm" 2>/dev/null) || r=0
        d=$(( t - ${PREV_T[$p]:-$t} )); (( d < 0 )) && d=0
        gtotal=$(( gtotal + d )); grss=$(( grss + r * 4 / 1024 ))
        PREV_T[$p]=$t
    done
    gcpu=$(( gtotal * 100 / (IV * HZ) ))

    avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
    swap=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{print int((t-f)/1024)}' /proc/meminfo)

    g=$(nvidia-smi --query-gpu=temperature.gpu,power.draw,utilization.gpu,enforced.power.limit,clocks.sm \
        --format=csv,noheader,nounits 2>/dev/null | head -1)
    IFS=',' read -r gt gp gu gl gclk <<<"${g:-0,0,0,0,0}"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date '+%H:%M:%S')" "$(pkg_temp || echo 0)" "$(hot_temp || echo 0)" "$(zone_temp TCPU || echo 0)" \
        "$(pl_w 0)" "$(pl_w 1)" "$busy" "$gcpu" "${gt// /}" "${gp// /}" "${gu// /}" "${gl// /}" \
        "$avail" "$swap" "$grss" "${gclk// /}" "$(epp_now)" \
        "$(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct 2>/dev/null || echo 0)" \
        "$(pfreq)" "$(throttle_cnt)" >>"$OUT"

    printf '\r[%s] 封装 %s°C  游戏 %s%%  GPU %s%%/%sW  P核 %sMHz  可用 %sMB  swap %sMB    ' \
        "$(date '+%T')" "$(pkg_temp || echo '?')" "$gcpu" "${gu// /}" "${gp// /}" "$(pfreq)" "$avail" "$swap"
    sleep "$IV"
done

echo; echo "== 汇总 =="
summarize
echo
echo "  原始数据: $OUT"
echo "  当前最吃 CPU 的进程（瞬时，参考用）:"
ps -eo pcpu,pmem,comm --sort=-pcpu --no-headers 2>/dev/null | head -5 | sed 's/^/    /'

