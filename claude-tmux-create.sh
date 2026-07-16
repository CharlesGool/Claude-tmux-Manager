#!/usr/bin/env bash
# claude-tmux-create.sh
#
# Creates a brand-new tmux session named "claude-<timestamp>", cd's into /root,
# and launches `claude --permission-mode auto --remote-control` inside it.
# Automatically resolves the one-time "do you trust this workspace" dialog by
# simulating keystrokes (tmux send-keys) so the whole thing runs unattended.
#
# Safe to run repeatedly: every invocation creates a fresh, independent session.
#
# Usage:
#   ./claude-tmux-create.sh              # new session in /root
#   ./claude-tmux-create.sh --resume <conversation-id> [--cwd <dir>]
#                                         # new session that resumes an archived conversation
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
source "$SCRIPT_DIR/common.sh"

RESUME_ID=""
TARGET_CWD="$CTM_WORK_DIR"

while [ $# -gt 0 ]; do
    case "$1" in
        --resume)
            RESUME_ID="${2:-}"
            shift 2
            ;;
        --cwd)
            TARGET_CWD="${2:-$CTM_WORK_DIR}"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is not installed." >&2
    exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "ERROR: claude CLI not found on PATH ($PATH)." >&2
    exit 1
fi

mkdir -p "$TARGET_CWD" 2>/dev/null || true

SESSION_NAME="$(ctm_next_session_name)"
ctm_log "creating new tmux session $SESSION_NAME (cwd=$TARGET_CWD resume=${RESUME_ID:-none})"

tmux new-session -d -s "$SESSION_NAME" -c "$TARGET_CWD" -x 220 -y 50

EXTRA_ARGS=""
if [ -n "$RESUME_ID" ]; then
    EXTRA_ARGS="--resume $RESUME_ID"
fi

ctm_launch_claude_in_session "$SESSION_NAME" "$TARGET_CWD" "$EXTRA_ARGS"
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
    echo "OK: $SESSION_NAME"
else
    echo "WARNING: $SESSION_NAME created but remote-control banner not confirmed yet, check with: tmux attach -t $SESSION_NAME"
fi

echo "$SESSION_NAME"
