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

# Checks/ensures remote-control is on by using claude's own `/rc` slash
# command - not by scraping terminal text or /proc/<pid>/cmdline, both of
# which only reflect launch-time intent, not live truth (a session can be
# running perfectly normally, with --remote-control on its command line, and
# still have silently failed to actually connect - confirmed happening in
# practice, not just a theoretical case).
#
# `/rc` behaves as a query-and-fix in one: if remote-control is already on,
# claude shows a "Remote Control" status panel (Disconnect this session /
# Show QR code / Continue) - Escape dismisses it without disconnecting. If it
# was off, running /rc is *supposed* to turn it on silently (no panel) - but
# in testing, /rc can also outright fail ("Remote Control failed - Session
# creation failed" / "...credentials fetch failed").
#
# Critically, the panel itself is NOT reliable evidence by itself: observed
# in testing rendering optimistically, immediately, before the connection
# has actually finished verifying - and a few seconds later turning into one
# of the failure messages above once verification actually completes,
# *after* the panel was already dismissed. So seeing the panel does not end
# the poll early; only an explicit failure message does. This costs a few
# extra seconds of latency on the success path in exchange for not recording
# a confident-looking wrong answer.
ctm_ensure_remote_control() {
    local session="$1"
    tmux send-keys -t "$session" "/rc" Enter

    local failed=0 panel_seen=0 pane i
    for i in $(seq 1 15); do
        sleep 1
        pane=$(tmux capture-pane -t "$session" -p 2>/dev/null || true)
        if echo "$pane" | grep -qi "remote control failed\|credentials fetch failed\|session creation failed"; then
            failed=1
            break
        fi
        if echo "$pane" | grep -qi "remote control" && echo "$pane" | grep -qi "disconnect this session"; then
            panel_seen=1
        fi
    done

    if [ "$panel_seen" -eq 1 ] && [ "$failed" -eq 0 ]; then
        tmux send-keys -t "$session" Escape
    fi

    if [ "$failed" -eq 1 ]; then
        ctm_log "$session: WARNING /rc reported remote-control failed to connect - will retry on a later keep-alive pass"
        python3 "$CTM_PY" --set-remote-control "$session" --on 0 >> "$CTM_LOG_FILE" 2>&1
    elif [ "$panel_seen" -eq 1 ]; then
        ctm_log "$session: remote-control confirmed on (status panel stayed stable, dismissed)"
        python3 "$CTM_PY" --set-remote-control "$session" --on 1 >> "$CTM_LOG_FILE" 2>&1
    else
        ctm_log "$session: remote-control was off - /rc turned it on (no panel/failure text within 15s)"
        python3 "$CTM_PY" --set-remote-control "$session" --on 1 >> "$CTM_LOG_FILE" 2>&1
    fi
}

# True only if claude is sitting at its normal idle chat prompt (the "auto
# mode on" footer is showing, and it's not mid-task). "Not mid-task" alone
# isn't a safe enough gate for sending /rc: a pane can be idle in the sense
# of not actively working while still sitting on some *other* dialog it's
# waiting on (e.g. the resume-from-summary prompt from a slow/old --resume -
# observed happening in practice) - the idle chat prompt's footer is absent
# in that state too, so requiring it positively (not just requiring "esc to
# interrupt" to be absent) avoids blindly typing "/rc" + Enter into whatever
# unrelated dialog happens to be showing.
ctm_at_idle_prompt() {
    local pane
    pane=$(tmux capture-pane -t "$1" -p -S -10 2>/dev/null || true)
    echo "$pane" | grep -qi "auto mode on" && ! echo "$pane" | grep -qi "esc to interrupt"
}

# Launch `claude --permission-mode auto --remote-control [extra args]` inside an
# existing tmux session/pane, then resolve known one-time dialogs automatically
# by polling the pane content and pressing Enter:
#   - "trust this folder"          -> accepts the default-highlighted
#                                      "Yes, I trust this folder" option.
#   - "resume from summary" (only shown for old/large --resume sessions) ->
#                                      accepts the default-highlighted
#                                      "Resume from summary (recommended)"
#                                      option, so an unattended relaunch never
#                                      just sits there forever waiting for a
#                                      keypress that will never come.
# Waits up to ~30s for claude to settle at its normal idle prompt ("auto mode
# on" footer), then runs ctm_ensure_remote_control to confirm/fix remote
# control - see its own comment for why that's more reliable than waiting for
# a startup banner.
#
# Which conversation (jsonl) this launch ends up using is never *guessed*
# after the fact: for a --resume, it's the given id; for a brand-new
# conversation, we mint a uuid ourselves and force claude to use it via
# --session-id. Both are known with certainty before claude even starts, so
# claude_tmux_manager.py never has to fall back to matching files by
# birth/mtime in a shared project directory (which misidentifies the
# conversation whenever another session is concurrently active in the same
# cwd - see README/CLAUDE.md for the cwd-sharing note).
ctm_launch_claude_in_session() {
    local session="$1"
    local cwd="$2"
    local resume_id="$3"
    shift 3
    local extra_args="$*"

    local conv_id
    if [ -n "$resume_id" ]; then
        conv_id="$resume_id"
    else
        conv_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
        extra_args="$extra_args --session-id $conv_id"
    fi

    tmux send-keys -t "$session" "cd '$cwd' && claude --permission-mode auto --remote-control $extra_args" Enter

    local settled=0
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
        if echo "$pane" | grep -qi "resume from summary\|resuming the full session will consume"; then
            # Default cursor is on "1. Resume from summary (recommended)" - Enter confirms it.
            tmux send-keys -t "$session" Enter
            ctm_log "$session: resolved resume-from-summary dialog"
            continue
        fi
        if echo "$pane" | grep -qi "auto mode on"; then
            settled=1
            break
        fi
    done

    python3 "$CTM_PY" --record-session "$session" --cwd "$cwd" --conversation-id "$conv_id" >> "$CTM_LOG_FILE" 2>&1

    if [ "$settled" -ne 1 ]; then
        ctm_log "$session: WARNING claude did not reach an idle prompt within 30s (may still be starting)"
        return 1
    fi

    # --remote-control on the command line already triggers an automatic
    # connection attempt at startup, running concurrently with (and shortly
    # after) the TUI becoming idle. Probing immediately with /rc races that
    # in-flight attempt (observed causing spurious "Session creation failed"
    # failures in testing); a few seconds' grace lets it resolve on its own
    # first, so /rc more often just finds it already connected.
    sleep 3
    ctm_ensure_remote_control "$session"
    ctm_log "$session: claude started (conversation_id=$conv_id)"
    return 0
}

# Returns the foreground command name running in a tmux session's first pane
# (e.g. "claude" or "bash"). Empty string if the session does not exist.
ctm_pane_command() {
    tmux list-panes -t "$1" -F "#{pane_current_command}" 2>/dev/null | head -1
}
