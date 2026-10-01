#!/usr/bin/env bash
# =============================================================================
#  switch.sh —— tempctl 的快捷键前端（给 niri/DMS 键位调用）
#    switch.sh save|normal|game|max   切换档位（带通知反馈）
#    switch.sh status                 弹通知显示当前温度 / 功耗墙
#  依赖：/usr/local/bin/tempctl 已安装，且 /etc/sudoers.d/tempctl 放行了这些档位
# =============================================================================
set -uo pipefail
TEMPCTL=/usr/local/bin/tempctl
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

notify() { # notify <标题> <正文> [超时ms]
    notify-send -a tempctl -t "${3:-4000}" "$1" "$2" 2>/dev/null || true
}

case ${1:-} in
    save|normal|game|max)
        if ! out=$(sudo -n "$TEMPCTL" "$1" 2>&1); then
            notify "tempctl $1 失败" "免密规则没生效？跑一次：
sudo bash $SCRIPT_DIR/install.sh" 8000
            exit 1
        fi
        case $1 in
            save)   d="省电码字：CPU 25W / 睿频 60% / GPU 60W";;
            normal) d="日常均衡：CPU 45W / 睿频 90% / GPU 70W";;
            game)   d="游戏：CPU 65W / EPP performance / GPU 80W";;
            max)    d="不设限：CPU 115W / GPU 105W（会到 100°C）";;
        esac
        notify "tempctl → $1 档" "$d"
        ;;
    status)
        body=$("$TEMPCTL" 2>/dev/null | sed -n '2,4p')
        [[ -n $body ]] || body="读取失败"
        notify "tempctl 当前状态" "$body" 8000
        ;;
    *)
        notify "tempctl" "用法: switch.sh save|normal|game|max|status"
        exit 1
        ;;
esac
