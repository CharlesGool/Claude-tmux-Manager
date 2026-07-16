#!/usr/bin/env bash
# claude-tmux-manager.sh - thin launcher for the Python management console.
# All table rendering / JSON parsing / tmux introspection logic lives in
# claude_tmux_manager.py; this wrapper just makes sure python3 is available
# and claude is on PATH before handing off.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="/root/.local/bin:$PATH"

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is not installed." >&2
    exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is not installed." >&2
    exit 1
fi

exec python3 "$SCRIPT_DIR/claude_tmux_manager.py" "$@"
