#!/usr/bin/env bash
# claude-tmux-keep_alive.sh
#
# Patrol/keep-alive daemon. Meant to run once a minute (via systemd timer, see
# systemd/claude-tmux-keepalive.timer, with cron as a fallback on non-systemd hosts).
#
# For every "claude-*" tmux session:
#   - if the claude process inside it has died (pane fell back to a plain shell),
#     it is relaunched in-place so the same tmux session keeps its remote-control
#     link alive.
# If there are no "claude-*" sessions at all, a brand new one is created so this
# host always has at least one Claude Code remote-control session available.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

ctm_log "keep-alive pass starting"

mapfile -t SESSIONS < <(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${CTM_SESSION_PREFIX}" || true)

if [ "${#SESSIONS[@]}" -eq 0 ]; then
    ctm_log "no claude-* sessions found, bootstrapping one via claude-tmux-create.sh"
    "$SCRIPT_DIR/claude-tmux-create.sh" >> "$CTM_LOG_FILE" 2>&1
    ctm_log "keep-alive pass finished"
    exit 0
fi

for session in "${SESSIONS[@]}"; do
    cmd="$(ctm_pane_command "$session")"

    if [ "$cmd" = "claude" ]; then
        pane_pid="$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null | head -1)"
        claude_pid="$(pgrep -P "$pane_pid" -x claude 2>/dev/null | head -1)"
        remote_control_on=0
        if [ -n "$claude_pid" ] && tr '\0' ' ' < "/proc/$claude_pid/cmdline" 2>/dev/null | grep -q -- "--remote-control"; then
            remote_control_on=1
        fi

        if [ "$remote_control_on" -eq 1 ]; then
            ctm_log "$session: healthy (claude running, remote-control on)"
        else
            ctm_log "$session: WARNING claude is running but --remote-control flag not detected on its process; leaving it alone to avoid interrupting an active session"
        fi
        continue
    fi

    # The claude process is gone (crashed, /exit, killed, etc). The pane is sitting
    # at a bare shell prompt - relaunch claude in-place so the tmux session identity
    # (and thus anything pointing at it, e.g. the manager UI) survives the restart.
    ctm_log "$session: remote-control is down (pane shows '$cmd', not claude) - reactivating"
    cwd="$(tmux display-message -p -t "$session" '#{pane_current_path}' 2>/dev/null || echo "$CTM_WORK_DIR")"
    ctm_launch_claude_in_session "$session" "$cwd"
done

ctm_log "keep-alive pass finished"
