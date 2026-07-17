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
#   - if claude is alive but remote-control never actually confirmed (it
#     silently failed to connect - this does happen even with no dialog
#     involved, not just a theoretical case) and the session has been idle
#     past its startup grace period, claude is killed and relaunched in-place
#     (resuming the same conversation id) to give the connection another
#     shot. A session that's actively mid-task (esc to interrupt) is left
#     alone even if unconfirmed, so in-progress agent work is never killed.
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
        verdict="$(python3 "$CTM_PY" --keepalive-check "$session" 2>>"$CTM_LOG_FILE")"
        case "$verdict" in
            healthy)
                ctm_log "$session: healthy (claude running, remote-control confirmed)"
                ;;
            relaunch\ *)
                resume_id="${verdict#relaunch }"
                ctm_log "$session: claude running but remote-control never confirmed and session is idle past its grace period - killing claude and relaunching (resume=${resume_id:-none}) to retry the connection"
                claude_pid="$(pgrep -P "$(tmux list-panes -t "$session" -F "#{pane_pid}" 2>/dev/null | head -1)" -x claude 2>/dev/null | head -1)"
                [ -n "$claude_pid" ] && kill "$claude_pid" 2>/dev/null
                sleep 1
                cwd="$(tmux display-message -p -t "$session" '#{pane_current_path}' 2>/dev/null || echo "$CTM_WORK_DIR")"
                ctm_launch_claude_in_session "$session" "$cwd" "$resume_id"
                ;;
            *)
                ctm_log "$session: claude running, remote-control not yet confirmed (still within grace period or actively working) - leaving it alone"
                ;;
        esac
        continue
    fi

    # The claude process is gone (crashed, /exit, killed, etc). The pane is sitting
    # at a bare shell prompt - relaunch claude in-place so the tmux session identity
    # (and thus anything pointing at it, e.g. the manager UI) survives the restart.
    ctm_log "$session: remote-control is down (pane shows '$cmd', not claude) - reactivating"
    cwd="$(tmux display-message -p -t "$session" '#{pane_current_path}' 2>/dev/null || echo "$CTM_WORK_DIR")"
    ctm_launch_claude_in_session "$session" "$cwd" ""
done

ctm_log "keep-alive pass finished"
