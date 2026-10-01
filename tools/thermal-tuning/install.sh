#!/usr/bin/env bash
# =============================================================================
#  tempctl 安装/卸载（需要 root）
#    sudo bash install.sh               # 安装/升级：/usr/local/bin/tempctl + 开机应用 normal + 免密切档
#    sudo bash install.sh --no-sudoers  # 同上，但不安装免密规则
#    sudo bash install.sh --remove      # 完全卸载（并清理旧版遗留）
#    sudo bash install.sh --mask-ppd    # 额外屏蔽 power-profiles-daemon（推荐，见 README）
#    sudo bash install.sh --unmask-ppd  # 恢复 power-profiles-daemon
#  预演（不落盘）: DRY_RUN=1 bash install.sh
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DST=/usr/local/bin/tempctl
UNIT_DIR=/etc/systemd/system
SUDOERS_FILE=/etc/sudoers.d/tempctl
DRY="${DRY_RUN:-0}"
MODE=install
WANT_SUDOERS=1

run() { if [[ $DRY == 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }

for a in "$@"; do
    case $a in
        --no-sudoers) WANT_SUDOERS=0 ;;
        --remove)     MODE=remove ;;
        --mask-ppd)   MODE=maskppd ;;
        --unmask-ppd) MODE=unmaskppd ;;
        -h|--help)    sed -n '2,8p' "$0"; exit 0 ;;
        *)            echo "未知参数: $a" >&2; exit 1 ;;
    esac
done

[[ -f $SRC_DIR/tempctl ]] || { echo "找不到 $SRC_DIR/tempctl" >&2; exit 1; }
if [[ $DRY != 1 && ${EUID} -ne 0 ]]; then echo "请用 sudo 运行: sudo bash $0 $*" >&2; exit 1; fi

USER_HOME="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"

cleanup_legacy() {
    # 旧版（1.x）遗留：温度守护服务、指向源码目录的软链
    if [[ -e $UNIT_DIR/tempctl-guard.service ]]; then
        echo "  清理旧版温度守护服务 tempctl-guard.service"
        run systemctl disable --now tempctl-guard.service || true
        run rm -f "$UNIT_DIR/tempctl-guard.service"
    fi
    # 兜底：清掉可能残留的启用软链，避免开机报依赖错误
    run rm -f "$UNIT_DIR/multi-user.target.wants/tempctl-guard.service"
    if [[ -n $USER_HOME && -L "$USER_HOME/.local/bin/tempctl" ]]; then
        echo "  清理旧版软链 $USER_HOME/.local/bin/tempctl"
        run rm -f "$USER_HOME/.local/bin/tempctl"
    fi
}

if [[ $MODE == maskppd ]]; then
    echo "== 屏蔽 power-profiles-daemon（让 tempctl 独占 EPP/睿频开关）=="
    run systemctl mask --now power-profiles-daemon.service
    echo "  已 mask；它会写 EPP 与 no_turbo，屏蔽后 tempctl 的档位不会再被覆盖"
    echo "  恢复：sudo bash $0 --unmask-ppd"
    exit 0
fi

if [[ $MODE == unmaskppd ]]; then
    echo "== 恢复 power-profiles-daemon =="
    run systemctl unmask power-profiles-daemon.service
    run systemctl start power-profiles-daemon.service || true
    echo "  已恢复（注意：它切档时会覆盖 EPP）"
    exit 0
fi

if [[ $MODE == remove ]]; then
    echo "== 卸载 tempctl =="
    cleanup_legacy
    run systemctl disable --now tempctl-boot.service || true
    run rm -f "$UNIT_DIR/tempctl-boot.service" "$SUDOERS_FILE" "$BIN_DST"
    run systemctl daemon-reload
    echo "已卸载（CPU/GPU 设置属运行时参数，重启后自动恢复主板默认）"
    exit 0
fi

echo "== 1/3 安装命令 → $BIN_DST =="
run install -o root -g root -m 0755 "$SRC_DIR/tempctl" "$BIN_DST"

echo "== 2/3 开机自动应用 max 档（不设限；想降温用快捷键切）=="
run install -o root -g root -m 0644 "$SRC_DIR/systemd/tempctl-boot.service" "$UNIT_DIR/tempctl-boot.service"
run systemctl daemon-reload
cleanup_legacy
if run systemctl enable --now tempctl-boot.service; then
    echo "  tempctl-boot.service 已启用并重新应用档位"
else
    echo "  ✗ 启动失败，排查: systemctl status tempctl-boot.service"
fi
# oneshot + RemainAfterExit：已处于 active(exited) 时 enable --now 不会重跑，这里显式重启一次让新档位立即生效
run systemctl restart tempctl-boot.service || true

echo "== 3/3 免密规则 =="
if [[ $WANT_SUDOERS == 1 ]]; then
    run install -o root -g root -m 0440 "$SRC_DIR/sudoers.d/tempctl" "$SUDOERS_FILE"
    echo "  wheel 组可免密执行: tempctl save | normal | game | max"
else
    echo "  跳过（--no-sudoers）"
fi

echo
run "$BIN_DST" || true
echo
if systemctl is-active --quiet power-profiles-daemon.service 2>/dev/null; then
    echo "提示: power-profiles-daemon 仍在运行，它切档会覆盖 EPP；"
    echo "      想让它别插手: sudo bash $0 --mask-ppd"
    echo
fi
echo "完成。日常用法："
echo "  tempctl              查看状态"
echo "  sudo tempctl save    省电码字档"
echo "  sudo tempctl normal  日常均衡档"
echo "  sudo tempctl game    游戏档"
echo "  sudo tempctl max     不设限档（CPU 115W / GPU 105W）"
