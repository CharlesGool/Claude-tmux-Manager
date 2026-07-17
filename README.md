# claude-tmux Code 会话与后台托管管理系统

在一台 root 权限的 Debian/Ubuntu 服务器上，把 `claude --remote-control` 变成一个
**常驻的、可自愈的后台服务**，而不是一次性的交互终端会话：Claude Code 跑在 tmux
里，掉线/崩溃了会被每分钟一次的巡检自动拉起来，管理员可以随时通过一个纯文本
菜单查看、连接、新建、杀死、恢复这些会话，也可以在手机或
https://claude.ai/code 上远程接管。

## 设计思路

Claude Code 的 `--remote-control` 模式需要一个持续运行的前台进程；但服务器会
重启、进程会因为各种原因退出，普通用户又不希望每次都手动 `tmux attach` 再敲
命令确认目录信任对话框。这套系统把这几件事拆成三个职责单一的脚本，外加一个
统一的管理入口：

- **创建 (`claude-tmux-create.sh`)**：只管"从零生成一个新的、干净的
  remote-control 会话"，用 `tmux send-keys` 模拟按键自动确认两类一次性对话框：
  工作区信任对话框（默认高亮在"1. Yes, I trust this folder"，直接回车）；以及
  `--resume` 一个较老/较大的对话时可能出现的"Resume from summary / Resume full
  session as-is"选择框（默认高亮在推荐的"1. Resume from summary"，同样直接
  回车，避免无人值守时卡死在这个对话框上）。轮询捕获 pane 内容直到看到
  `auto mode on` 这个底部状态提示（说明已经到了正常空闲输入界面，不再卡在任何
  弹窗上）才认为启动完成，随后调用 `ctm_ensure_remote_control` 用 claude 自带的
  `/rc` 命令确认/纠正远程控制状态（见下方"远程控制"判定方法）。每次运行都新建
  一个独立会话（`claude-<时间戳>`），互不影响。

- **保活 (`claude-tmux-keep_alive.sh`)**：只管"发现问题就地修复"。每分钟由
  systemd timer 触发一次：遍历所有 `claude-*` 会话，用
  `tmux list-panes -F '#{pane_current_command}'` 判断 claude 进程是否还活着
  （活着是 `claude`，死了会掉回 `bash`/`sh`）；死了就在同一个 tmux 会话里原地
  重新拉起，会话的名字/身份不变。如果连一个 `claude-*` 会话都没有了，直接调用
  创建脚本补一个，保证任何时候都至少有一个可远程使用的会话。除了"进程死了"，
  也会处理"进程活着但 remote-control 还没确认打开"：只要 `state/sessions.json`
  里这个会话还没被标记为已确认、且确实处于正常的空闲聊天输入框（不是在忙，
  也不是卡在其它弹窗上），就会用 `/rc` 命令去检查并纠正（见下方"远程控制"
  判定方法）；一旦确认打开过一次，之后每一轮就不会再对这个会话发 `/rc` 了，
  避免健康的会话每分钟都被硬塞一条 `/rc` 命令、白白吃 token。

- **管理中心 (`claude-tmux-manager.sh` + `claude_tmux_manager.py`)**：只管
  "展示状态、执行动作"，本身不做任何后台巡检。所有 JSON 解析（`~/.claude/`
  的会话记录、状态映射文件）、tmux 状态判定、以及中英文混排表格的严格对齐，
  都在 Python 里完成（用 `unicodedata.east_asian_width` 按显示宽度而不是字符数
  对齐，避免中文表格错位）。sh 脚本只是一层保证 `python3`/`tmux` 存在的启动壳。

状态判定全部基于对 tmux/claude 真实行为的实测，而不是猜测：

| 状态 | 判定方法 |
|---|---|
| Tmux 已连接 / 挂起中 | `tmux list-clients -t <session>` 有输出 = 已连接，无输出 = 挂起中 |
| Claude Code 正在工作 / 未在工作 | 捕获 pane 最后几行，出现 `esc to interrupt` = 正在工作 |
| 远程控制 启用中 / 未启用 | 不看命令行参数、不猜屏幕文字，而是直接问 claude 本身：向 pane 发送内置的 `/rc` 命令（`ctm_ensure_remote_control`，`common.sh`），然后在最多 10 秒内轮询三种可能结果：① 弹出"Remote Control"状态面板（Disconnect this session / Show QR code / Continue）——本来就是开着的，发一个 Escape 关掉面板即可（不会断开连接）；② 出现明确的失败提示（`Remote Control failed` / `...credentials fetch failed` / `...Session creation failed`，实测证实确实会发生，即使命令行正常带了 `--remote-control` 且进程运行完全正常）——如实记为未启用，交给下一轮保活重试；③ 两者都没出现——按"本来关着、/rc 已经静默打开"处理。只有前两种是确定结果，第三种是尽力而为的兜底假设。结果写入 `state/sessions.json` 的 `remote_control_on`，管理中心界面只读这个字段，不会每次刷新界面都现场探测。发送 `/rc` 前必须先用 `ctm_at_idle_prompt` 确认 pane 正处于正常的空闲聊天输入框（而不仅仅是"没有在 `esc to interrupt`"）——光看"没在工作"不够，会话也可能正卡在另一个完全不相关的确认框上（比如 `--resume` 一个很旧的对话时弹出的"Resume from summary"框），那种情况下盲目把 `/rc` 当按键发过去，等于是往一个自己看不懂的对话框里乱敲字符，行为不可预期。 |
| 对话是否已归档 | 该对话 ID（`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl` 的文件名）当前是否有存活的 tmux 会话与之对应（记录在 `state/sessions.json`） |

三个脚本之间通过 `state/sessions.json` 传递"tmux 会话 <-> 对话 ID"的映射，且这个
对话 ID 从不靠事后猜文件时间戳得来——`ctm_launch_claude_in_session`（`common.sh`）
在真正拉起 claude 之前就已经确定了它：`--resume <id>` 时就是给定的 `<id>`；全新
对话时则自己生成一个 uuid，通过 `claude --session-id <uuid>` 强制 claude 使用这个
ID。两种情况下启动完成后都直接把这个已知 ID 记进 `state/sessions.json`
（`claude_tmux_manager.py --record-session ... --conversation-id <id>`），管理中心
读这个映射来判断"这个对话现在有没有对应的 tmux 会话"。
（早期版本靠"在对应项目目录下找最近创建的 `.jsonl` 文件"猜测 ID，但当同一个
cwd 下同时有多个对话在跑时——例如所有会话都默认落在 `/root`——这个猜测经常
会把好几个不相关的 tmux 会话全部关联到同一个、恰好最活跃的对话上，界面上
显示出错误的对话 ID 和内容。现仅在会话完全没有记录、且该 cwd 下确实只有唯一
一个候选 `.jsonl` 文件时才会退回这种猜测，猜不准时如实显示为"-"，不会显示
一个看似确定但其实错误的 ID。）

## 目录结构

```
claude-tmux-manager/
├── claude-tmux-create.sh        # 创建新的 claude-tmux 会话
├── claude-tmux-keep_alive.sh    # 每分钟巡检保活
├── claude-tmux-manager.sh       # 管理中心启动壳 (-> python3)
├── claude_tmux_manager.py       # 管理中心核心逻辑 (状态判定/表格/菜单)
├── common.sh                    # create.sh / keep_alive.sh 共用的函数库
├── CLAUDE.md                    # 写入 Claude Code 记忆的内容（源文件）
├── install.sh                   # 一键部署 + 自检
├── uninstall.sh                 # 一键卸载
├── systemd/
│   ├── claude-tmux-create.service       # 开机启动一次
│   ├── claude-tmux-keepalive.service    # 保活任务本体
│   └── claude-tmux-keepalive.timer      # 每 60 秒触发一次
└── state/                       # 运行时状态与日志（sessions.json / *.log）
```

## 安装

```bash
git clone https://github.com/CharlesGool/Claude-tmux-Manager /root/claude-tmux-manager
cd /root/claude-tmux-manager
bash install.sh
```

（如果不是从 GitHub 克隆，把整个 `claude-tmux-manager` 目录拷贝到目标服务器
的 `/root/` 下，效果一样，脚本里所有路径都是基于自身所在目录解析的。）

`install.sh` 会依次完成：

1. 检查是否为 root。
2. 缺什么装什么：`tmux`、`python3`（apt）。
3. 检查 `claude` 命令是否存在，不存在则用官方脚本安装
   （`curl -fsSL https://claude.ai/install.sh | bash`）；额外把它软链到
   `/usr/local/bin/claude`（默认就在任何 shell/cron/systemd 的 PATH 上），
   这样当前终端立刻就能用 `claude`，不需要重开一个 shell 或手动
   `source ~/.bashrc`。然后检查是否已登录——**未登录会直接终止安装**并提示你
   先手动运行一次 `claude` 完成登录再重新执行，不会继续往下跑（未登录状态下
   继续只会造出一堆卡在登录/信任对话框上的僵尸 tmux 会话）。
4. 把这套系统的使用说明写进 Claude Code 的记忆文件 `/root/.claude/CLAUDE.md`
   （用 `<!-- Claude-Tmux Manager's Start/End -->` 包裹，方便日后精准移除）。
5. 注册并启动 `claude-tmux-create.service`（开机启动一次）。
6. 注册并启动 `claude-tmux-keepalive.timer`（每分钟跑一次保活）；如果这台机器
   没有 systemd，会自动退化为写一条 root crontab。
7. 自检：确认 tmux 会话已建好、里面的 claude 进程活着、远程控制已通过 `/rc`
   确认开启、保活巡检日志正常、管理中心 UI 能正常拉起。任何一步失败都会在
   最后汇总里标红，并给出对应的日志路径。

## 日常使用

```bash
/root/claude-tmux-manager/claude-tmux-manager.sh
```

```
=============================
  claude-tmux Code 管理中心 
=============================
1.claude-tmux 会话管理中心
2.claude code 对话管理中心
3.退出
4.卸载claude-tmux Code 管理服务
```

- **会话管理中心**：列出所有正在运行的 `claude-*` tmux 会话及其状态，可以
  连接（`tmux attach`，`Ctrl-b d` 分离后自动回到菜单）、杀死、或按 `n` 手动
  新建一个。
- **对话管理中心**：列出 `~/.claude/projects/` 下所有历史对话（分页展示，每页
  15 条，按最近活跃时间排序）。有对应存活 tmux 会话的可以直接连接/杀死；已
  归档（没有对应 tmux 会话）的可以一键"重激活"——会新建一个 tmux 会话并用
  `claude --resume <id> --permission-mode auto --remote-control` 恢复现场，
  或者彻底删除（需要输入 `y` 二次确认，且只允许删除确认无存活 tmux 关联的
  已归档对话，删除前会再次校验，避免误删正在使用的会话）。

也可以完全不打开菜单，直接单独调用脚本：

```bash
# 新建一个会话
/root/claude-tmux-manager/claude-tmux-create.sh

# 手动触发一次保活巡检
/root/claude-tmux-manager/claude-tmux-keep_alive.sh
```

Claude Code 自己也已经被告知这套系统的存在（见"安装"第 4 步写入的记忆）：
如果你在跟当前这个交互式会话聊天时说"帮我再开一个后台窗口"，它知道应该调用
`claude-tmux-create.sh`。

## 卸载

```bash
bash /root/claude-tmux-manager/uninstall.sh
```

必做的两步：停止并禁用 systemd 服务/定时器（或对应的 crontab 项）；从
`/root/.claude/CLAUDE.md` 里精确移除本项目写入的那一段记忆，不动其他任何
记忆内容。

默认不会动正在运行的 tmux 会话，也不会删除 `/root/claude-tmux-manager` 目录
本身——运行时会交互式询问是否要顺便清理；非交互环境下（比如脚本化调用）默认
跳过这两项，除非显式加上 `--purge` 一次性全部清理：

```bash
bash uninstall.sh --purge
```

## 已知限制

- 对话 ID 与 tmux 会话的映射是在(重新)启动那一刻记录的；如果在某个已被托管的
  会话内部手动执行 `/clear` 或 `/resume` 切换到另一个对话，管理中心不会实时
  感知这次切换（要到该 tmux 会话被保活脚本重启时才会重新探测）。
- 远程控制一旦被 `/rc` 确认打开过一次（`state/sessions.json` 里
  `remote_control_on` 为 true），保活脚本此后就不会再对这个会话探测/发送
  `/rc` 了。如果它后续因为网络等原因中途掉线，不会被自动发现和重新打开，
  只能手动在会话里再输入一次 `/rc` 自己确认。这是刻意的取舍：换取"每分钟
  巡检不会对着健康会话反复发 `/rc`、白白往对话记录里塞命令、吃 token"。
- 实测中 `/rc` 本身不是 100% 可靠——同一台机器上同时开着好几个
  `claude --remote-control` 会话时，偶尔会遇到 `Remote Control failed ·
  Session creation failed` / `...credentials fetch failed` 这类明确的失败提示
  （原因未知，可能与并发的远程连接数量有关，也可能是网络/服务端瞬时问题）。
  `ctm_ensure_remote_control` 会如实把这种情况记为未启用而不是误报成功，失败
  的会话会在之后的保活轮次里自动重试，直到成功为止；不代表这套机制能保证
  每次都在几秒内连上。
