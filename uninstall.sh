#!/usr/bin/env bash
# uninstall.sh - remove the claude-tmux Code management system from this host.
#
# Required behavior:
#   1. Stop and disable the systemd service/timer (or the crontab fallback).
#   2. Remove only the Claude-Tmux-Manager block from Claude Code's memory
#      (CLAUDE.md), leaving any other memory content untouched.
#
# Optional (off by default, ask for confirmation / require --purge):
#   - kill any running claude-* tmux sessions
#   - delete /root/claude-tmux-manager itself
set -uo pipefail

CTM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PURGE=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 用户运行本脚本。" >&2
    exit 1
fi

echo "== 1/2 停用 systemd 服务/定时器 (或 crontab 回退项) =="
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop claude-tmux-keepalive.timer 2>/dev/null
    systemctl disable claude-tmux-keepalive.timer 2>/dev/null
    systemctl stop claude-tmux-keepalive.service 2>/dev/null
    systemctl stop claude-tmux-create.service 2>/dev/null
    systemctl disable claude-tmux-create.service 2>/dev/null
    rm -f /etc/systemd/system/claude-tmux-create.service
    rm -f /etc/systemd/system/claude-tmux-keepalive.service
    rm -f /etc/systemd/system/claude-tmux-keepalive.timer
    systemctl daemon-reload
    systemctl reset-failed >/dev/null 2>&1
    echo "  [OK] systemd 服务与定时器已停止、禁用并移除"
fi
if crontab -l 2>/dev/null | grep -q "claude-tmux-keep_alive.sh"; then
    ( crontab -l 2>/dev/null | grep -v "claude-tmux-keep_alive.sh" ) | crontab -
    echo "  [OK] crontab 保活任务已移除"
fi

echo "== 2/2 清理 Claude Code 记忆中与本项目相关的部分 =="
TARGET_MD="/root/.claude/CLAUDE.md"
if [ -f "$TARGET_MD" ]; then
    python3 - "$TARGET_MD" << 'PYEOF'
import sys, re
target_path = sys.argv[1]
start_marker = "<!-- Claude-Tmux Manager's Start -->"
end_marker = "<!-- Claude-Tmux Manager's End -->"
with open(target_path, encoding="utf-8") as f:
    content = f.read()
pattern = re.compile(r"\n?" + re.escape(start_marker) + r".*?" + re.escape(end_marker) + r"\n?", re.DOTALL)
new_content, n = pattern.subn("\n", content)
if n:
    new_content = re.sub(r"\n{3,}", "\n\n", new_content).strip("\n")
    new_content = (new_content + "\n") if new_content else ""
    with open(target_path, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"removed {n} block(s)")
else:
    print("no matching block found")
PYEOF
    echo "  [OK] 已从 $TARGET_MD 中移除 claude-tmux Manager 相关记忆（其余记忆内容保持不变）"
else
    echo "  [SKIP] $TARGET_MD 不存在，无需清理"
fi

echo
echo "systemd/crontab 与记忆清理已完成（必选步骤）。"
echo

kill_sessions() {
    local sessions
    sessions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-' || true)"
    if [ -z "$sessions" ]; then
        echo "  没有正在运行的 claude-* tmux 会话。"
        return
    fi
    echo "$sessions" | while read -r s; do
        tmux kill-session -t "$s" 2>/dev/null && echo "  已杀死会话: $s"
    done
}

remove_dir() {
    echo "  正在删除 $CTM_HOME ..."
    rm -rf "$CTM_HOME"
    echo "  已删除。"
}

if [ "$PURGE" -eq 1 ]; then
    echo "--purge 已指定，继续清理正在运行的 claude-* 会话与安装目录 ..."
    kill_sessions
    remove_dir
    exit 0
fi

if [ "$ASSUME_YES" -eq 1 ]; then
    # non-interactive, safe default: keep sessions and files
    echo "未指定 --purge，保留正在运行的 claude-tmux 会话与已安装文件。"
    exit 0
fi

if [ -t 0 ]; then
    read -r -p "是否同时杀死所有正在运行的 claude-tmux 会话? [y/N] " ans
    if [ "${ans,,}" = "y" ]; then
        kill_sessions
    fi
    read -r -p "是否同时删除安装目录 $CTM_HOME ? [y/N] " ans2
    if [ "${ans2,,}" = "y" ]; then
        remove_dir
    fi
else
    echo "非交互环境，跳过可选的会话清理与目录删除（如需全部清理请加 --purge）。"
fi
