[English](README.md) | 中文

# 可选集成

初始化 ledger、调度任务、运行 adapter 和使用 `fleet-mcp` 都不依赖 `contrib/`。这里的程序只消费 Fleet 输出，或安装本机便利接线。只需要核心功能时可以完全不安装它们。

## `fleet-web`：本机只读视图

`fleet-web/` 从 `~/.fleet/fleet.db` 提供 overview、goal 和 task 页面，并调用 Fleet 读取 live data。它只使用 Python 标准库，默认监听 `127.0.0.1:8790`，默认可执行文件是 `~/.local/bin/fleet`，可用 `FLEET_BIN` 覆盖。启动前创建本机 access token：

```bash
mkdir -p "$HOME/.config/fleet-web"
python3 -c 'import secrets; print(secrets.token_hex(32))' > "$HOME/.config/fleet-web/token"
chmod 600 "$HOME/.config/fleet-web/token"
python3 contrib/fleet-web/fleet_web.py
```

打开 `http://127.0.0.1:8790/?t=<token>`。`FLEET_WEB_HOST` 和 `FLEET_WEB_PORT` 可修改监听地址。只有同时配置 `FLEET_WEB_ORG`、`FLEET_WEB_GH_CLIENT_ID`、`FLEET_WEB_AUTH_WORKER` 才会启用 GitHub 登录；该模式还会调用已认证的 `gh` CLI 查询组织 owner。它是运维视图，不是加固过的公网 dashboard；除非外层已有认证边界，否则保持 loopback。

## `claude-weekly-usage.py`：本机用量估算

这个只读脚本根据本机 assistant transcript 的 token 数和人工记录的百分比锚点，估算 Claude Code 订阅周用量。它只用标准库，读取 `~/.claude/projects`、`~/.claude.json` 和 `~/.local/state/claude-usage/anchors.json`：

```bash
python3 contrib/claude-weekly-usage.py
```

结果是按公开价格权重换算的启发式估算，不是供应商账单。脚本需要近期交互式 usage 快照来确定刷新边界；只有存在锚点时才能估算百分比。涉及额度判断时，以供应商自己的 usage 页面为准。

## `notify-lark.py`：筛选后的 ledger 通知

Notifier 会整理已确认或驳回的 claim、新的用户 decision、最终失败与 stalled。Dry-run 只需要 Python；实际发送还需要 `lark-cli`。不带 `--send` 时绝不发送：

```bash
python3 contrib/notify-lark.py
python3 contrib/notify-lark.py --send
```

默认配置是 `${XDG_CONFIG_HOME:-$HOME/.config}/fleet-contrib/notify-lark.json`：

```json
{
  "chat_id": "",
  "user_id": ""
}
```

设置一个目标即可；两者都有时 `chat_id` 优先。缺少目标会让 `--send` 在调用后端前失败。状态和 event watermark 放在 `${XDG_STATE_HOME:-$HOME/.local/state}/fleet-contrib/`。可用参数包括 `--config`、`--state`、`--max-lines`、`--fleet-bin`、`--lark-bin`；对应覆盖变量是 `FLEET_NOTIFY_CONFIG`、`FLEET_NOTIFY_STATE`、`FLEET_NOTIFY_FLEET`、`FLEET_NOTIFY_LARK`。

## `surface-decisions.py`：Claude Code Stop hook

这个标准库脚本以只读 SQLite 模式读取 ledger。它按 session 展示尚未处理的 `needs_user` decision；同一组 in-flight task 没有存活的 `fleet wait` watcher 时，最多阻止三次 Stop。Watcher 检查依赖 `/proc`，因此这部分只适用于 Linux。Ledger 或进程表出错时会 fail-open 并写警告，不会卡住所属 session。

通过默认 dry-run 的 wiring 工具安装，不要把它当成交互命令运行：

```bash
contrib/wiring/install.sh --only stop-hook
contrib/wiring/install.sh --apply --only stop-hook
```

安装器会把 hook 合并到 `~/.claude/settings.json`，修改有效的现有文件前做备份，并拒绝无效 JSON。用 `FLEET_SURFACE_STATE` 覆盖 hook 的 per-session 状态路径。

## `publish-activity.py`：紧凑 activity 快照

该脚本把 `fleet top --once --json` 转成小型 `fleet.json` activity 文件。stdin 有 JSON 时直接读取，否则自行调用 Fleet。目标目录为 `SWITCHBOARD_ACTIVITY_DIR` 或 `~/.switchboard/activity.d`：

```bash
fleet top --once --json | python3 contrib/publish-activity.py
```

它只使用标准库，通过原子替换写入；目标目录不存在时不写文件并成功退出。可选的 `fleet-activity.timer` 每十秒刷新一次。

## `worktree-audit.sh`：prune 前检查

审计脚本调用 `fleet worktree list --json`，再用 Git 和 `du` 分类已登记 worktree。`risky` 表示有未提交文件、存在领先当前仓库分支的 commit，或检查失败；`clean` 没有领先 commit 和脏文件；`stale` 表示目录不存在：

```bash
contrib/worktree-audit.sh
contrib/worktree-audit.sh --json
```

发现 risky worktree 时返回 `1`，无法读取 Fleet 输出时返回 `2`。它只报告，不删除；应在显式执行 `fleet worktree prune` 前查看结果。

## `wiring/`：user service 与 timer

`wiring/install.sh` 支持 `stop-hook`、`activity`、`notify` 和 `daemon`。它需要 Python；安装 service 还要求 systemd user manager。默认只做 dry-run：

```bash
contrib/wiring/install.sh
contrib/wiring/install.sh --only daemon
contrib/wiring/install.sh --apply --only daemon
contrib/wiring/install.sh --apply --only stop-hook,activity
```

输出前缀分别是 `+` 新建、`~` 更新、`=` 已正确、`!` 拒绝或不可用。安装器会渲染当前 checkout 路径，把 unit 写到 user config 目录，并用 `systemctl --user enable --now` 启用就绪项。通知配置没有目标时，不会启用 notification timer。

Daemon unit 使用 `Restart=always`。由该 unit 管理时，`fleet daemon stop` 会触发 systemd 再次启动；需要持续停止时使用 `systemctl --user stop fleet-daemon`。`wiring/fleet-web.service` 是独立模板，不由 `install.sh` 安装，且要求 web 目录位于 `~/.local/share/fleet-web`。

## 验证与状态位置

集成自身的状态应放在各自 config 或 state 目录，只有真实 Fleet 状态才进入 ledger。会发送信息或修改配置的脚本默认 dry-run，或要求显式开关。

改动任何 contrib 组件后运行：

```bash
bash tests/contrib_smoke.sh
```

核心操作见 [Fleet 使用指南](../docs/guide.zh-CN.md)。
