<!-- Claude-Tmux Manager's Start -->
## claude-tmux Code 会话与后台托管管理系统

本机部署了 claude-tmux Code 会话与后台托管管理系统，安装目录为
`/root/claude-tmux-manager`。它让 Claude Code 可以脱离当前这一个交互窗口，
在 tmux 中长期以 `--permission-mode auto --remote-control` 方式后台运行，
从手机或 https://claude.ai/code 远程继续操作这台服务器。

如果需要新增一个后台的 claude-tmux 远程控制窗口（例如：需要另开一条并行的
后台任务，或者当前会话希望"分身"出一个可远程连接的常驻实例），直接调用：

    /root/claude-tmux-manager/claude-tmux-create.sh

它会创建一个新的 tmux 会话（命名为 `claude-<时间戳>`），自动处理目录信任
确认对话框，并在其中启动带 `--remote-control` 的 Claude Code。重复运行此
脚本是安全的，每次都会新建一个独立会话，不会互相影响。

系统组成（均在 `/root/claude-tmux-manager` 下）：

- `claude-tmux-create.sh` - 创建新的 claude-tmux 远程控制会话（见上）。
- `claude-tmux-keep_alive.sh` - 由 systemd timer 每分钟自动运行一次的巡检
  脚本：检查所有 `claude-*` tmux 会话，若其中的 Claude Code 进程已经退出
  （远程控制掉线），会在原会话内原地拉起 `claude --permission-mode auto
  --remote-control` 恢复；如果一个 `claude-*` 会话都不存在了，会自动调用
  `claude-tmux-create.sh` 补一个，保证服务器上始终至少有一个可远程使用的
  Claude Code 会话。
- `claude-tmux-manager.sh` - 交互式管理中心（文本菜单，Python3 实现），
  用 root 在终端直接运行即可打开：
    1) claude-tmux 会话管理中心 - 查看/连接/杀死所有正在运行的 tmux 会话。
    2) claude code 对话管理中心 - 浏览 `~/.claude/projects/` 下的历史对话，
       对仍有 tmux 会话在跑的可直接连接/杀死；对已归档（无对应 tmux）的
       对话可以一键在新 tmux 中重新激活（自动带上 auto + remote-control），
       或彻底删除。
    3) 退出
    4) 卸载 claude-tmux Code 管理服务（调用 uninstall.sh）
- `install.sh` / `uninstall.sh` - 部署与卸载脚本。
- `systemd/` 下的单元文件由 install.sh 注册：
  `claude-tmux-create.service`（开机启动一次）、
  `claude-tmux-keepalive.timer` + `.service`（每分钟巡检一次）。

会话运行状态判断依据（供参考，manager.sh 内已自动实现）：
Tmux 连接态看 `tmux list-clients` 是否有输出；Claude Code 是否在工作看
底部状态栏是否出现 `esc to interrupt`；远程控制是否启用看 claude 进程的
启动参数里是否带 `--remote-control`。
<!-- Claude-Tmux Manager's End -->
