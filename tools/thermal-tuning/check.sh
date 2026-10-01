#!/usr/bin/env bash
# =============================================================================
#  tempctl 自检：静态检查 + 状态输出，不改动任何系统设置
#    bash check.sh        # 全部检查
#    bash check.sh -q     # 只输出结论
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
QUIET=0; [[ ${1:-} == -q ]] && QUIET=1

pass=0; fail=0
ok()   { pass=$(( pass + 1 )); printf '  [PASS] %s\n' "$*"; }
bad()  { fail=$(( fail + 1 )); printf '  [FAIL] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
sec()  { [[ $QUIET == 1 ]] || printf '\n== %s ==\n' "$*"; }

sec "1 脚本语法"
for f in tempctl install.sh check.sh diag.sh; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f 语法错误"; fi
done

sec "2 shellcheck（可选）"
if command -v shellcheck >/dev/null; then
    if shellcheck -S error tempctl install.sh check.sh >/dev/null 2>&1; then ok "shellcheck 无 error"; else warn "shellcheck 有告警（非致命）"; fi
else
    warn "未安装 shellcheck，跳过"
fi

sec "3 sudoers 规则"
if visudo -cf sudoers.d/tempctl >/dev/null 2>&1; then ok "visudo -cf sudoers.d/tempctl"; else bad "sudoers 语法不合法"; fi

sec "4 systemd 单元"
out="$(systemd-analyze verify systemd/tempctl-boot.service 2>&1 || true)"
if [[ -z $out ]]; then ok "tempctl-boot.service 校验通过"
elif [[ $(grep -vc 'not executable' <<<"$out") -eq 0 ]]; then ok "unit 结构正常（仅提示尚未安装到 /usr/local/bin）"
else bad "unit 校验报错:"; printf '%s\n' "$out" | sed 's/^/       /'; fi

sec "5 安装预演（不落盘）"
if DRY_RUN=1 bash install.sh >/tmp/tempctl-dryrun.log 2>&1; then ok "install.sh 预演通过"
else bad "install.sh 预演失败，日志: /tmp/tempctl-dryrun.log"; sed 's/^/       /' /tmp/tempctl-dryrun.log | tail -8; fi

sec "6 安装状态"
[[ -x /usr/local/bin/tempctl ]] && ok "已安装 /usr/local/bin/tempctl" || warn "未安装（sudo ./install.sh）"
if systemctl is-enabled tempctl-boot.service >/dev/null 2>&1; then
    ok "tempctl-boot.service 已启用（$(systemctl is-active tempctl-boot.service 2>/dev/null)）"
else
    warn "tempctl-boot.service 未启用"
fi
if [[ -e /etc/systemd/system/tempctl-guard.service ]]; then
    warn "检测到旧版 tempctl-guard.service（再跑一次 sudo ./install.sh 会自动清理）"
else
    ok "无旧版 guard 服务残留"
fi

sec "7 当前状态"
if [[ $QUIET == 1 ]]; then ./tempctl >/dev/null 2>&1 || true; else ./tempctl; fi

printf '\n== 结论 ==\n  PASS=%d  FAIL=%d\n' "$pass" "$fail"
if (( fail == 0 )); then
    echo "  静态检查全绿。装机: sudo bash $ROOT/install.sh"
    exit 0
fi
echo "  有 $fail 项失败，请先修复再安装。"
exit 1
