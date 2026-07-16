#!/usr/bin/env bash
# common.sh - shared constants and helper functions for claude-tmux-manager
# Sourced by claude-tmux-create.sh and claude-tmux-keep_alive.sh (not meant to be executed directly)

# Resolve the real path of this project directory regardless of caller's cwd.
CTM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CTM_STATE_DIR="$CTM_HOME/state"
CTM_SESSIONS_MAP="$CTM_STATE_DIR/sessions.json"
CTM_LOG_FILE="$CTM_STATE_DIR/ctm.log"
CTM_PY="$CTM_HOME/claude_tmux_manager.py"
CTM_WORK_DIR="/root"
CTM_SESSION_PREFIX="claude-"

mkdir -p "$CTM_STATE_DIR"

# Make sure claude (installed under ~/.local/bin by the official installer) is reachable
# even when this script is invoked by systemd/cron with a minimal PATH.
export PATH="/root/.local/bin:$PATH"

ctm_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$CTM_LOG_FILE"
}

# Find an unused "claude-<timestamp>" tmux session name.
ctm_next_session_name() {
    local name
    name="${CTM_SESSION_PREFIX}$(date +%Y%m%d-%H%M%S)"
    while tmux has-session -t "$name" 2>/dev/null; do
        sleep 1
        name="${CTM_SESSION_PREFIX}$(date +%Y%m%d-%H%M%S)"
    done
    echo "$name"
}

# Launch `claude --permission-mode auto --remote-control [extra args]` inside an
# existing tmux session/pane, then resolve the "trust this folder" dialog automatically
# by polling the pane content and pressing Enter (accepts the default-highlighted
# "Yes, I trust this folder" option). Waits up to ~30s for the remote-control banner
# to confirm the session came up healthy.
ctm_launch_claude_in_session() {
    local session="$1"
    local cwd="$2"
    shift 2
    local extra_args="$*"
    local start_ts
    start_ts=$(date +%s)

    tmux send-keys -t "$session" "cd '$cwd' && claude --permission-mode auto --remote-control $extra_args" Enter

    local ready=0
    local i pane
    for i in $(seq 1 30); do
        sleep 1
        pane=$(tmux capture-pane -t "$session" -p 2>/dev/null || true)
        if echo "$pane" | grep -qi "trust this folder"; then
            # Default cursor is on "1. Yes, I trust this folder" - Enter confirms it.
            tmux send-keys -t "$session" Enter
            ctm_log "$session: resolved workspace-trust dialog"
            continue
        fi
        if echo "$pane" | grep -qi "remote-control is active"; then
            ready=1
            break
        fi
    done

    if [ "$ready" -ne 1 ]; then
        ctm_log "$session: WARNING remote-control banner not observed within 30s (may still be starting)"
        return 1
    fi

    ctm_log "$session: claude started, remote-control active (start_ts=$start_ts)"
    python3 "$CTM_PY" --record-session "$session" --cwd "$cwd" --since "$start_ts" >> "$CTM_LOG_FILE" 2>&1
    return 0
}

# Returns the foreground command name running in a tmux session's first pane
# (e.g. "claude" or "bash"). Empty string if the session does not exist.
ctm_pane_command() {
    tmux list-panes -t "$1" -F "#{pane_current_command}" 2>/dev/null | head -1
}
