#!/usr/bin/env bash
# install.sh - deploy the claude-tmux Code session & background hosting
# management system on this machine.
#
# Steps:
#   1. Verify running as root.
#   2. Install missing dependencies (tmux, python3) via apt.
#   3. Install Claude Code itself if missing, and check it is logged in.
#   4. Write usage notes into Claude Code's memory (CLAUDE.md).
#   5. Register + start the systemd boot-time create service.
#   6. Register + start the systemd per-minute keep-alive timer.
#   7. Self-test every component end to end.
set -uo pipefail

CTM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$CTM_HOME/state"
mkdir -p "$STATE_DIR"

PASS=0
FAIL=0
pass() { echo "  [OK]   $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
step() { echo; echo "== $1 =="; }

# --------------------------------------------------------------------------
# 1. root check
# --------------------------------------------------------------------------
step "1/7 检查运行用户"
if [ "$(id -u)" -ne 0 ]; then
    echo "本脚本必须以 root 用户运行（此系统设计目的就是托管 root 上的服务）。" >&2
    echo "请使用: sudo bash install.sh" >&2
    exit 1
fi
pass "以 root 身份运行"

# --------------------------------------------------------------------------
# 2. dependencies: tmux, python3
# --------------------------------------------------------------------------
step "2/7 检查并安装依赖 (tmux, python3)"
APT_UPDATED=0
ensure_apt_pkg() {
    local bin="$1" pkg="$2"
    if command -v "$bin" >/dev/null 2>&1; then
        pass "$bin 已安装"
        return
    fi
    echo "  未检测到 $bin, 尝试通过 apt 安装 $pkg ..."
    if [ "$APT_UPDATED" -eq 0 ]; then
        apt-get update -y >/dev/null 2>&1 || true
        APT_UPDATED=1
    fi
    if apt-get install -y "$pkg" >/dev/null 2>&1 && command -v "$bin" >/dev/null 2>&1; then
        pass "$pkg 安装成功"
    else
        fail "$pkg 安装失败，请手动执行: apt-get install -y $pkg"
    fi
}
ensure_apt_pkg tmux tmux
ensure_apt_pkg python3 python3

# --------------------------------------------------------------------------
# 3. Claude Code CLI: install if missing, check login state
# --------------------------------------------------------------------------
step "3/7 检查 Claude Code CLI 与登录状态"
export PATH="/root/.local/bin:$PATH"
if ! command -v claude >/dev/null 2>&1; then
    echo "  未检测到 claude CLI, 使用官方脚本安装 ..."
    curl -fsSL https://claude.ai/install.sh | bash
    export PATH="/root/.local/bin:$PATH"
fi
if command -v claude >/dev/null 2>&1; then
    CLAUDE_BIN="$(command -v claude)"
    pass "claude CLI 可用: $CLAUDE_BIN ($(claude --version 2>/dev/null))"
else
    fail "claude CLI 安装失败，请手动执行: curl -fsSL https://claude.ai/install.sh | bash"
    exit 1
fi

# The official installer only puts claude on PATH via ~/.local/bin, and only
# takes effect for *new* shells that (re-)source ~/.bashrc. Anyone already
# sitting in the terminal that ran this script - or any non-interactive
# caller (cron, systemd) - will still get "claude: command not found" even
# though the check above just succeeded in-process. Symlink it into
# /usr/local/bin, which is on PATH by default for every shell and service on
# this host (see /etc/environment), so `claude` works immediately everywhere
# without needing a new login shell.
if [ ! -e /usr/local/bin/claude ] || [ "$(readlink -f /usr/local/bin/claude 2>/dev/null)" != "$(readlink -f "$CLAUDE_BIN")" ]; then
    ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
fi
if [ "$(readlink -f /usr/local/bin/claude 2>/dev/null)" = "$(readlink -f "$CLAUDE_BIN")" ]; then
    pass "claude 已链接到 /usr/local/bin/claude (任意新终端/cron/systemd 均可直接使用，无需重新登录 shell)"
else
    fail "为 claude 创建 /usr/local/bin 软链接失败"
fi

if ! grep -q '.local/bin' /root/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /root/.bashrc
fi

if [ -f /root/.claude/.credentials.json ] || python3 -c "
import json,sys
try:
    d=json.load(open('/root/.claude.json'))
    sys.exit(0 if d.get('oauthAccount') else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    pass "Claude Code 已登录"
else
    fail "Claude Code 尚未登录"
    echo >&2
    echo "  Claude Code 尚未登录。后续步骤（写入记忆、拉起 tmux 会话、注册保活服务）都需要一个" >&2
    echo "  已登录的 claude 才能正常工作，在未登录状态下继续只会产生一堆卡在登录/信任对话框上的" >&2
    echo "  僵尸 tmux 会话。请先手动运行一次: claude   完成登录，再重新执行:" >&2
    echo "    bash $CTM_HOME/install.sh" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# 4. write usage notes into Claude Code memory (CLAUDE.md)
# --------------------------------------------------------------------------
step "4/7 写入 Claude Code 记忆 (CLAUDE.md)"
TARGET_MD="/root/.claude/CLAUDE.md"
mkdir -p "$(dirname "$TARGET_MD")"
touch "$TARGET_MD"

python3 - "$TARGET_MD" "$CTM_HOME/CLAUDE.md" << 'PYEOF'
import sys, re
target_path, block_path = sys.argv[1], sys.argv[2]
block = open(block_path, encoding="utf-8").read().strip("\n")
try:
    existing = open(target_path, encoding="utf-8").read()
except FileNotFoundError:
    existing = ""
start_marker = "<!-- Claude-Tmux Manager's Start -->"
end_marker = "<!-- Claude-Tmux Manager's End -->"
pattern = re.compile(re.escape(start_marker) + r".*?" + re.escape(end_marker), re.DOTALL)
if pattern.search(existing):
    existing = pattern.sub(block, existing)
else:
    existing = existing.rstrip("\n")
    existing = (existing + "\n\n" + block + "\n") if existing else (block + "\n")
open(target_path, "w", encoding="utf-8").write(existing)
PYEOF
if grep -q "Claude-Tmux Manager's Start" "$TARGET_MD"; then
    pass "记忆已写入 $TARGET_MD"
else
    fail "记忆写入 $TARGET_MD 失败"
fi

# --------------------------------------------------------------------------
# 5 & 6. systemd: boot-time create service + per-minute keep-alive timer
# --------------------------------------------------------------------------
step "5/7 注册开机启动服务 (claude-tmux-create.service)"
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    cp "$CTM_HOME/systemd/claude-tmux-create.service" /etc/systemd/system/claude-tmux-create.service
    cp "$CTM_HOME/systemd/claude-tmux-keepalive.service" /etc/systemd/system/claude-tmux-keepalive.service
    cp "$CTM_HOME/systemd/claude-tmux-keepalive.timer" /etc/systemd/system/claude-tmux-keepalive.timer
    systemctl daemon-reload

    systemctl enable claude-tmux-create.service >/dev/null 2>&1
    if systemctl start claude-tmux-create.service; then
        pass "claude-tmux-create.service 已注册并启动 (开机时会自动运行一次)"
    else
        fail "claude-tmux-create.service 启动失败"
    fi

    step "6/7 注册每分钟保活定时器 (claude-tmux-keepalive.timer)"
    systemctl enable claude-tmux-keepalive.timer >/dev/null 2>&1
    if systemctl start claude-tmux-keepalive.timer; then
        pass "claude-tmux-keepalive.timer 已注册并启动 (每 60 秒巡检一次)"
    else
        fail "claude-tmux-keepalive.timer 启动失败"
    fi
    USED_CRON=0
else
    step "6/7 systemd 不可用，回退到 root crontab"
    echo "  未检测到可用的 systemd，改用 crontab 实现每分钟保活。"
    ( crontab -l 2>/dev/null | grep -v "claude-tmux-keep_alive.sh" ; echo "* * * * * $CTM_HOME/claude-tmux-keep_alive.sh >> $STATE_DIR/keepalive.cron.log 2>&1" ) | crontab -
    if crontab -l 2>/dev/null | grep -q "claude-tmux-keep_alive.sh"; then
        pass "crontab 每分钟保活任务已注册"
    else
        fail "crontab 保活任务注册失败"
    fi
    "$CTM_HOME/claude-tmux-create.sh" >> "$STATE_DIR/create.log" 2>&1 && pass "初始 claude-tmux 会话已创建" || fail "初始 claude-tmux 会话创建失败"
    USED_CRON=1
fi

# --------------------------------------------------------------------------
# 7. self-test
# --------------------------------------------------------------------------
step "7/7 功能自检"
sleep 3

if tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -q "^claude-"; then
    pass "至少存在一个 claude-* tmux 会话"
else
    fail "未找到任何 claude-* tmux 会话"
fi

SESSION_NAME="$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^claude-" | head -1)"
if [ -n "$SESSION_NAME" ]; then
    PANE_CMD="$(tmux list-panes -t "$SESSION_NAME" -F "#{pane_current_command}" 2>/dev/null | head -1)"
    if [ "$PANE_CMD" = "claude" ]; then
        pass "$SESSION_NAME 内 claude 进程正在运行"
    else
        fail "$SESSION_NAME 内未检测到 claude 进程 (pane_current_command=$PANE_CMD)"
    fi

    if tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null | grep -qi "remote-control is active"; then
        pass "$SESSION_NAME 远程控制已激活"
    else
        echo "  [WARN] $SESSION_NAME 远程控制横幅暂未捕获到（可能仍在启动中，不计入失败）"
    fi
fi

if [ "$USED_CRON" -eq 0 ]; then
    if systemctl start claude-tmux-keepalive.service; then
        pass "手动触发 keepalive.service 成功"
    else
        fail "手动触发 keepalive.service 失败"
    fi
    sleep 1
    if grep -q "keep-alive pass finished" "$STATE_DIR/ctm.log" 2>/dev/null; then
        pass "keep-alive 巡检日志正常"
    else
        fail "keep-alive 巡检日志缺失"
    fi
fi

if echo "3" | python3 "$CTM_HOME/claude_tmux_manager.py" 2>>"$STATE_DIR/selftest.log" | grep -q "claude-tmux Code 管理中心"; then
    pass "管理中心 Python UI 可正常启动"
else
    fail "管理中心 Python UI 启动异常，详见 $STATE_DIR/selftest.log"
fi

echo
echo "================================================"
echo " 部署自检完成: $PASS 项通过, $FAIL 项失败"
echo "================================================"
if [ "$FAIL" -gt 0 ]; then
    echo "存在失败项，请检查上方 [FAIL] 提示以及日志目录: $STATE_DIR"
    exit 1
fi
echo "全部通过。运行管理中心: $CTM_HOME/claude-tmux-manager.sh"
