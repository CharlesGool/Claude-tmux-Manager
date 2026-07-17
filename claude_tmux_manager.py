#!/usr/bin/env python3
"""claude-tmux-manager: management console for hosted Claude Code tmux sessions.

Two jobs:
  1. CLI helper mode, called by claude-tmux-create.sh / claude-tmux-keep_alive.sh
     right after they launch a claude process, to record which conversation
     (session-id / jsonl file) that tmux session ended up using:
         claude_tmux_manager.py --record-session <tmux-session> --cwd <dir> --since <epoch>
  2. Interactive text-menu mode (no arguments): the actual management console
     described in the project README - session management center and
     conversation management center.

No third-party dependencies - stdlib only.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

CTM_HOME = Path(__file__).resolve().parent
STATE_DIR = CTM_HOME / "state"
SESSIONS_MAP_FILE = STATE_DIR / "sessions.json"
CREATE_SCRIPT = CTM_HOME / "claude-tmux-create.sh"
CLAUDE_PROJECTS_DIR = Path.home() / ".claude" / "projects"
SESSION_PREFIX = "claude-"

STATE_DIR.mkdir(parents=True, exist_ok=True)


# --------------------------------------------------------------------------
# Display-width-aware text formatting (CJK characters render 2 columns wide)
# --------------------------------------------------------------------------

def display_width(text):
    width = 0
    for ch in text:
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            width += 2
        else:
            width += 1
    return width


def pad(text, width):
    w = display_width(text)
    if w >= width:
        return text
    return text + " " * (width - w)


def truncate(text, limit=10):
    text = "" if text is None else str(text)
    text = text.replace("\n", " ").replace("\r", " ").strip()
    text = " ".join(text.split())
    if len(text) > limit:
        return text[:limit] + "..."
    return text


def render_table(headers, rows, min_gap=2):
    """headers/rows: list[str] columns. Column width = widest cell (display width)."""
    widths = [display_width(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], display_width(cell))
    lines = []
    lines.append((" " * min_gap).join(pad(h, widths[i]) for i, h in enumerate(headers)))
    for row in rows:
        lines.append((" " * min_gap).join(pad(c, widths[i]) for i, c in enumerate(row)))
    return "\n".join(lines)


def banner(title):
    line = "=" * 29
    print(line)
    print(f"  {title} ")
    print(line)


# --------------------------------------------------------------------------
# tmux helpers
# --------------------------------------------------------------------------

def _run(cmd):
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return out.returncode, out.stdout, out.stderr
    except Exception:
        return 1, "", ""


def tmux_list_claude_sessions():
    code, out, _ = _run(["tmux", "list-sessions", "-F", "#{session_name}"])
    if code != 0:
        return []
    return sorted(n for n in out.splitlines() if n.startswith(SESSION_PREFIX))


def tmux_session_exists(name):
    code, _, _ = _run(["tmux", "has-session", "-t", name])
    return code == 0


def tmux_is_connected(name):
    code, out, _ = _run(["tmux", "list-clients", "-t", name])
    return code == 0 and out.strip() != ""


def tmux_pane_command(name):
    code, out, _ = _run(["tmux", "list-panes", "-t", name, "-F", "#{pane_current_command}"])
    if code != 0 or not out.strip():
        return ""
    return out.splitlines()[0].strip()


def tmux_pane_pid(name):
    code, out, _ = _run(["tmux", "list-panes", "-t", name, "-F", "#{pane_pid}"])
    if code != 0 or not out.strip():
        return None
    try:
        return int(out.splitlines()[0].strip())
    except ValueError:
        return None


def tmux_pane_path(name):
    code, out, _ = _run(["tmux", "display-message", "-p", "-t", name, "#{pane_current_path}"])
    if code != 0:
        return None
    return out.strip() or None


def tmux_capture_pane(name, lines=12):
    code, out, _ = _run(["tmux", "capture-pane", "-t", name, "-p", "-S", f"-{lines}"])
    if code != 0:
        return ""
    return out


def tmux_is_working(name):
    tail = tmux_capture_pane(name, lines=10)
    return "esc to interrupt" in tail


def tmux_kill_session(name):
    code, _, _ = _run(["tmux", "kill-session", "-t", name])
    return code == 0


def tmux_attach(name):
    """Blocking foreground attach - hands the real terminal to tmux until the
    user detaches (Ctrl-b d) or the session ends, then returns control here."""
    subprocess.call(["tmux", "attach-session", "-t", name])


def claude_child_pid(pane_pid):
    if not pane_pid:
        return None
    code, out, _ = _run(["pgrep", "-P", str(pane_pid), "-x", "claude"])
    if code != 0 or not out.strip():
        return None
    try:
        return int(out.splitlines()[0].strip())
    except ValueError:
        return None


def remote_control_enabled(claude_pid):
    if not claude_pid:
        return False
    try:
        with open(f"/proc/{claude_pid}/cmdline", "rb") as f:
            cmdline = f.read().replace(b"\0", b" ").decode(errors="ignore")
        return "--remote-control" in cmdline
    except OSError:
        return False


# --------------------------------------------------------------------------
# state/sessions.json - maps a tmux session name to the conversation (jsonl)
# id it is currently driving. Written by ctm_launch_claude_in_session (via
# --record-session) whenever a session is (re)launched.
# --------------------------------------------------------------------------

def load_state():
    if not SESSIONS_MAP_FILE.exists():
        return {}
    try:
        return json.loads(SESSIONS_MAP_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def save_state(state):
    tmp = SESSIONS_MAP_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    tmp.replace(SESSIONS_MAP_FILE)


def prune_state(state):
    """Drop entries for tmux sessions that no longer exist."""
    live = set(tmux_list_claude_sessions())
    changed = False
    for name in list(state.keys()):
        if name not in live:
            del state[name]
            changed = True
    if changed:
        save_state(state)
    return state


# --------------------------------------------------------------------------
# conversation (~/.claude/projects/<encoded-cwd>/<id>.jsonl) discovery
# --------------------------------------------------------------------------

def encode_project_dir(cwd):
    encoded = cwd.replace("/", "-")
    return CLAUDE_PROJECTS_DIR / encoded


def file_birth_time(path):
    """True file-creation time via statx (stat %W), not mtime. Needed because
    mtime is useless for picking "the file just created by this launch" out of
    a project directory where another, unrelated conversation (e.g. the
    operator's own primary interactive session, in the common case where that
    is also rooted at /root) may be actively appended to at the same moment."""
    code, out, _ = _run(["stat", "-c", "%W", str(path)])
    if code != 0:
        return None
    try:
        val = int(out.strip())
        return val if val > 0 else None
    except ValueError:
        return None


def find_new_conversation_id(cwd, since_ts, grace=2, require_unambiguous=False):
    """Best-effort fallback for sessions with no recorded conversation id
    (normal launches record one deterministically - see ctm_launch_claude_in_session
    in common.sh - so this only fires for orphaned/legacy/manual sessions).

    Picking "the newest file in this cwd's project dir" is only trustworthy
    when it is the *only* plausible candidate: cwd is commonly shared by
    several concurrently-active conversations (e.g. everything rooted at
    /root), so with more than one candidate there is no way to tell which
    file belongs to this particular tmux session. Guessing anyway previously
    caused multiple unrelated sessions to all display the same (wrong)
    conversation id/content. When require_unambiguous is set, an ambiguous
    result returns None (shown as unknown) instead of a confident-looking
    wrong answer.
    """
    project_dir = encode_project_dir(cwd)
    if not project_dir.is_dir():
        return None
    candidates = []
    for p in project_dir.glob("*.jsonl"):
        birth = file_birth_time(p)
        if birth is not None and birth >= since_ts - grace:
            candidates.append((birth, p))
    if not candidates:
        # best effort fallback: newest file in the project dir regardless of age
        for p in project_dir.glob("*.jsonl"):
            try:
                st = p.stat()
            except OSError:
                continue
            candidates.append((st.st_mtime, p))
    if not candidates:
        return None
    if require_unambiguous and len(candidates) > 1:
        return None
    candidates.sort(key=lambda t: t[0], reverse=True)
    return candidates[0][1].stem


def read_first_user_text(jsonl_path, max_lines=200):
    """Scan only the first `max_lines` lines - the first user message is always
    near the top, and transcripts can be multi-megabyte."""
    try:
        with open(jsonl_path, "r", errors="ignore") as f:
            for i, line in enumerate(f):
                if i >= max_lines:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if d.get("type") == "user":
                    msg = d.get("message", {})
                    content = msg.get("content")
                    if isinstance(content, str):
                        return content
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get("type") == "text":
                                return block.get("text", "")
    except OSError:
        pass
    return ""


def read_cwd_from_jsonl(jsonl_path, max_lines=50):
    try:
        with open(jsonl_path, "r", errors="ignore") as f:
            for i, line in enumerate(f):
                if i >= max_lines:
                    break
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "cwd" in d:
                    return d["cwd"]
    except OSError:
        pass
    return None


def decode_project_dir_name(dirname):
    """Best-effort reversal of encode_project_dir's "/" -> "-" substitution,
    used only as a fallback when a transcript predates the per-line cwd field."""
    if dirname.startswith("-"):
        return "/" + dirname[1:].replace("-", "/")
    return dirname.replace("-", "/")


def list_all_conversations():
    """Every conversation on disk, newest first."""
    conversations = []
    if not CLAUDE_PROJECTS_DIR.is_dir():
        return conversations
    for project_dir in CLAUDE_PROJECTS_DIR.iterdir():
        if not project_dir.is_dir():
            continue
        for jsonl in project_dir.glob("*.jsonl"):
            try:
                st = jsonl.stat()
            except OSError:
                continue
            cwd = read_cwd_from_jsonl(jsonl) or decode_project_dir_name(project_dir.name)
            conversations.append({
                "id": jsonl.stem,
                "cwd": cwd,
                "mtime": st.st_mtime,
                "path": jsonl,
            })
    conversations.sort(key=lambda c: c["mtime"], reverse=True)
    return conversations


# --------------------------------------------------------------------------
# Aggregated live-session view
# --------------------------------------------------------------------------

def collect_sessions():
    """Returns list of dicts describing every live claude-* tmux session."""
    state = prune_state(load_state())
    sessions = []
    for name in tmux_list_claude_sessions():
        connected = tmux_is_connected(name)
        pane_cmd = tmux_pane_command(name)
        claude_alive = pane_cmd == "claude"
        working = tmux_is_working(name) if claude_alive else False
        pane_pid = tmux_pane_pid(name)
        c_pid = claude_child_pid(pane_pid) if claude_alive else None
        rc_on = remote_control_enabled(c_pid) if claude_alive else False

        conv_id = state.get(name, {}).get("conversation_id")
        cwd = state.get(name, {}).get("cwd") or tmux_pane_path(name) or "/root"
        if not conv_id:
            conv_id = find_new_conversation_id(cwd, since_ts=0, require_unambiguous=True)

        preview = ""
        if conv_id:
            project_dir = encode_project_dir(cwd)
            jsonl_path = project_dir / f"{conv_id}.jsonl"
            preview = read_first_user_text(jsonl_path)

        sessions.append({
            "name": name,
            "connected": connected,
            "claude_alive": claude_alive,
            "working": working,
            "remote_control": rc_on,
            "conversation_id": conv_id or "-",
            "preview": preview,
            "cwd": cwd,
        })
    return sessions


def session_by_conversation_id(sessions, conv_id):
    for s in sessions:
        if s["conversation_id"] == conv_id:
            return s
    return None


# --------------------------------------------------------------------------
# Status label helpers
# --------------------------------------------------------------------------

def lbl_tmux(connected):
    return "[已连接]" if connected else "[挂起中]"


def lbl_claude(claude_alive, working):
    if not claude_alive:
        return "[未在工作]"
    return "[正在工作]" if working else "[未在工作]"


def lbl_rc(on):
    return "[启用中]" if on else "[未启用]"


# --------------------------------------------------------------------------
# UI: session management center (子菜单 1)
# --------------------------------------------------------------------------

def prompt(msg):
    try:
        return input(msg).strip()
    except (EOFError, KeyboardInterrupt):
        return "b"


def screen_session_center():
    while True:
        sessions = collect_sessions()
        banner("claude-tmux 窗口管理中心")
        headers = ["Tmux在线窗口:", "Claude Code", "Claude Code 对话ID", "Claude Code 对话内容", "远程连接状态", "Tmux会话状态"]
        rows = []
        for i, s in enumerate(sessions, 1):
            rows.append([
                f"{i}) {s['name']}",
                lbl_claude(s["claude_alive"], s["working"]),
                s["conversation_id"],
                truncate(s["preview"]),
                lbl_rc(s["remote_control"]),
                lbl_tmux(s["connected"]),
            ])
        if rows:
            print(render_table(headers, rows))
        else:
            print("(当前没有任何 claude-tmux 会话)")
        print()
        choice = prompt("输入序号进入会话操作，r) 刷新，n) 新建, b) 返回: ")

        if choice.lower() == "b":
            return
        if choice.lower() == "r":
            continue
        if choice.lower() == "n":
            print("正在新建 claude-tmux 会话...")
            subprocess.call([str(CREATE_SCRIPT)])
            prompt("完成，按回车继续...")
            continue
        if choice.isdigit() and 1 <= int(choice) <= len(sessions):
            screen_session_detail(sessions[int(choice) - 1]["name"])
            continue
        print("无效输入")
        time.sleep(1)


def screen_session_detail(session_name):
    while True:
        if not tmux_session_exists(session_name):
            print(f"会话 {session_name} 已不存在")
            prompt("按回车返回...")
            return
        sessions = collect_sessions()
        s = next((x for x in sessions if x["name"] == session_name), None)
        if s is None:
            return
        banner(f"{session_name} 窗口")
        headers = ["Claude Code", "Claude Code 对话内容", "Tmux会话状态", "Claude Code 对话ID"]
        row = [lbl_claude(s["claude_alive"], s["working"]), truncate(s["preview"]), lbl_tmux(s["connected"]), s["conversation_id"]]
        print(render_table(headers, [row]))
        print()
        print("1)连接此claude-tmux窗口")
        print("2)杀死此claude-tmux窗口")
        print("3)返回")
        choice = prompt("请选择: ")
        if choice == "1":
            print(f"正在连接 {session_name} ... (Ctrl-b d 分离并返回管理中心)")
            time.sleep(1)
            tmux_attach(session_name)
            continue
        if choice == "2":
            confirm = prompt(f"确认杀死会话 {session_name} ? 输入 y 确认: ")
            if confirm.lower() == "y":
                tmux_kill_session(session_name)
                state = load_state()
                state.pop(session_name, None)
                save_state(state)
                print("已杀死。")
                prompt("按回车返回...")
                return
            continue
        if choice == "3":
            return
        print("无效输入")
        time.sleep(1)


# --------------------------------------------------------------------------
# UI: conversation management center (子菜单 2)
# --------------------------------------------------------------------------

PAGE_SIZE = 15


def screen_conversation_center():
    page = 0
    while True:
        sessions = collect_sessions()
        conversations = list_all_conversations()
        total_pages = max(1, (len(conversations) + PAGE_SIZE - 1) // PAGE_SIZE)
        page = max(0, min(page, total_pages - 1))
        page_items = conversations[page * PAGE_SIZE:(page + 1) * PAGE_SIZE]

        banner("claude code 对话管理中心")
        headers = ["Claude Code 对话ID", "claude-tmux状态", "Claude Code 对话情况", "Claude Code 对话内容", "远程连接状态"]
        rows = []
        row_meta = []
        for i, conv in enumerate(page_items, 1):
            sess = session_by_conversation_id(sessions, conv["id"])
            preview = truncate(read_first_user_text(conv["path"]))
            if sess:
                rows.append([
                    f"{i}) {conv['id']}",
                    lbl_tmux(sess["connected"]),
                    lbl_claude(sess["claude_alive"], sess["working"]),
                    preview,
                    lbl_rc(sess["remote_control"]),
                ])
            else:
                rows.append([
                    f"{i}) {conv['id']}",
                    "[无对应tmux会话]",
                    "[已归档]",
                    preview,
                    "[未启用]",
                ])
            row_meta.append((conv, sess))
        if rows:
            print(render_table(headers, rows))
        else:
            print("(未找到任何历史对话)")
        print()
        print(f"第 {page + 1}/{total_pages} 页，共 {len(conversations)} 条对话")
        choice = prompt("输入序号查看详情，p) 上一页，f) 下一页，b) 返回: ")

        if choice.lower() == "b":
            return
        if choice.lower() == "p":
            page -= 1
            continue
        if choice.lower() == "f":
            page += 1
            continue
        if choice.isdigit() and 1 <= int(choice) <= len(row_meta):
            conv, sess = row_meta[int(choice) - 1]
            if sess:
                screen_conversation_live_detail(conv["id"])
            else:
                screen_conversation_archived_detail(conv["id"])
            continue
        print("无效输入")
        time.sleep(1)


def screen_conversation_live_detail(conv_id):
    while True:
        sessions = collect_sessions()
        sess = session_by_conversation_id(sessions, conv_id)
        if not sess:
            return
        banner(f"Claude Code 对话 {conv_id}")
        headers = ["Claude Code", "Claude Code 对话内容", "Tmux会话状态", "Tmux在线会话"]
        row = [lbl_claude(sess["claude_alive"], sess["working"]), truncate(sess["preview"]), lbl_tmux(sess["connected"]), sess["name"]]
        print(render_table(headers, [row]))
        print()
        print("1)连接此claude-tmux会话")
        print("2)杀死此claude-tmux会话")
        print("3)返回")
        choice = prompt("请选择: ")
        if choice == "1":
            print(f"正在连接 {sess['name']} ... (Ctrl-b d 分离并返回管理中心)")
            time.sleep(1)
            tmux_attach(sess["name"])
            continue
        if choice == "2":
            confirm = prompt(f"确认杀死会话 {sess['name']} ? 输入 y 确认: ")
            if confirm.lower() == "y":
                tmux_kill_session(sess["name"])
                state = load_state()
                state.pop(sess["name"], None)
                save_state(state)
                print("已杀死。")
                prompt("按回车返回...")
                return
            continue
        if choice == "3":
            return
        print("无效输入")
        time.sleep(1)


def screen_conversation_archived_detail(conv_id):
    conversations = {c["id"]: c for c in list_all_conversations()}
    conv = conversations.get(conv_id)
    if not conv:
        return
    while True:
        # re-verify it is still archived (no live tmux) every loop, in case a
        # reactivation happened in a previous iteration.
        sessions = collect_sessions()
        if session_by_conversation_id(sessions, conv_id):
            return
        preview = truncate(read_first_user_text(conv["path"]))
        banner(f"Claude Code 对话 {conv_id}")
        headers = ["Claude Code", "Claude Code 对话内容"]
        print(render_table(headers, [["[已归档]", preview]]))
        print()
        print("1)重激活此对话(在新建claude-tmux中激活,打开auto及rc控制)")
        print("2)删除此对话")
        print("3)返回")
        choice = prompt("请选择: ")
        if choice == "1":
            cwd = conv["cwd"] or "/root"
            print(f"正在新建 claude-tmux 会话并恢复对话 {conv_id} (cwd={cwd}) ...")
            subprocess.call([str(CREATE_SCRIPT), "--resume", conv_id, "--cwd", cwd])
            prompt("完成，按回车继续...")
            return
        if choice == "2":
            confirm = prompt(f"确认删除已归档对话 {conv_id} ? 此操作不可恢复，输入 y 确认: ")
            if confirm.lower() == "y":
                # double-check no live tmux grabbed this conversation in the meantime
                if session_by_conversation_id(collect_sessions(), conv_id):
                    print("该对话刚刚被一个 tmux 会话关联，已取消删除。")
                    prompt("按回车返回...")
                    return
                try:
                    conv["path"].unlink(missing_ok=True)
                    sibling_dir = conv["path"].with_suffix("")
                    if sibling_dir.is_dir():
                        import shutil
                        shutil.rmtree(sibling_dir, ignore_errors=True)
                except OSError as e:
                    print(f"删除失败: {e}")
                    prompt("按回车返回...")
                    return
                print("已删除。")
                prompt("按回车返回...")
                return
            continue
        if choice == "3":
            return
        print("无效输入")
        time.sleep(1)


# --------------------------------------------------------------------------
# UI: main menu
# --------------------------------------------------------------------------

def screen_main_menu():
    while True:
        banner("claude-tmux Code 管理中心")
        print("1.claude-tmux 会话管理中心")
        print("2.claude code 对话管理中心")
        print("3.退出")
        print("4.卸载claude-tmux Code 管理服务")
        choice = prompt("请输入选项: ")
        if choice == "1":
            screen_session_center()
        elif choice == "2":
            screen_conversation_center()
        elif choice == "3":
            sys.exit(0)
        elif choice == "4":
            confirm = prompt("确认卸载 claude-tmux Code 管理服务? 输入 y 确认: ")
            if confirm.lower() == "y":
                uninstall_sh = CTM_HOME / "uninstall.sh"
                subprocess.call(["bash", str(uninstall_sh)])
                sys.exit(0)
        else:
            print("无效输入")
            time.sleep(1)


# --------------------------------------------------------------------------
# CLI entry
# --------------------------------------------------------------------------

def cmd_record_session(args):
    # Preferred path: the caller (ctm_launch_claude_in_session) already knows
    # the conversation id for certain - either it's a --resume of a known id,
    # or it minted the id itself via --session-id before claude even started.
    # Only fall back to guessing-by-file-timestamp for callers that don't
    # supply one (e.g. manual/legacy invocations), since that heuristic is
    # unreliable whenever another conversation is concurrently active in the
    # same cwd.
    if args.conversation_id:
        conv_id = args.conversation_id
    else:
        conv_id = find_new_conversation_id(args.cwd, float(args.since))
    state = load_state()
    if conv_id:
        state[args.session] = {
            "conversation_id": conv_id,
            "cwd": args.cwd,
            "created_at": float(args.since) if not args.conversation_id else time.time(),
            "last_updated": time.time(),
        }
        save_state(state)
        print(f"recorded {args.session} -> {conv_id} (cwd={args.cwd})")
    else:
        print(f"WARNING: could not discover conversation id for {args.session} (cwd={args.cwd})")


def main():
    parser = argparse.ArgumentParser(description="claude-tmux-manager")
    parser.add_argument("--record-session", metavar="SESSION_NAME")
    parser.add_argument("--cwd", default="/root")
    parser.add_argument("--since", default="0")
    parser.add_argument("--conversation-id", metavar="CONV_ID", default=None)
    args = parser.parse_args()

    if args.record_session:
        cmd_record_session(argparse.Namespace(
            session=args.record_session, cwd=args.cwd, since=args.since,
            conversation_id=args.conversation_id,
        ))
        return

    screen_main_menu()


if __name__ == "__main__":
    main()
