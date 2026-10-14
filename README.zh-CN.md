[English](README.md) | 中文

# Fleet

Fleet 是一个在本机编排 CLI 编码 agent 的工具：它通过你已经在用的 CLI 执行边界清楚的任务，并把调度状态、证据和决策保存在 SQLite 台账里。

直接开几个终端在简单任务里很好用；一旦任务有先后依赖、两个 agent 可能改同一份 checkout、进程中途消失，或“测试通过”还要独立复审，终端本身就不再是可靠的协调面。Fleet 为这些关系提供明确状态，但不替换 agent。

## 用一个例子理解概念

假设一个 parser 空输入问题需要修复，并由另一个模型独立复审。

| 概念 | 在 Fleet 中是什么 | 在这个例子里 |
|---|---|---|
| **Goal** | 多个任务共同服务的结果与验收条件。 | “修好空输入，测试和复审都通过。” |
| **Task** | 带 prompt、渠道、依赖和状态的最小调度单元。 | 一个任务修改，另一个任务复审。 |
| **Channel** | 一条具名执行路径，包含适配器、模型选择、限流和用量配置。 | 通过 `codex` 执行修复。 |
| **Adapter** | 把 Fleet 调用约定翻译成一次具体 CLI 调用的小型 shell 边界。 | `codex.sh` 调用 `codex exec`。 |
| **Ledger** | SQLite 单一事实源。claim 记录结论，artifact 指向文件，decision 保存判断，event 记录状态变化。 | worker 声明回归测试已覆盖，并登记报告文件。 |
| **Daemon** | 启动就绪任务、执行门禁、回收进程、重试并应用规则的进程。 | 修复结束后才启动复审。 |
| **Commander** | 可选的短生命周期 agent 角色，为一个 goal 提议下一批有限任务。 | 发现边界问题后提议一个修补任务。 |
| **Review** | 通过 `review_of` 连接的任务；模型复审必须跨模型族。 | Claude 族 worker 复审 GPT 族的修改。 |
| **Worktree** | 每个任务独占的 Git checkout。 | 修改者不会覆盖复审者正在看的目录。 |
| **Lease** | 任务运行期间独占的具名资源。 | 同一时间只允许一个任务重写共享 fixture。 |

Fleet 不负责替你选对模型，不自动 merge 或 push，也不是操作系统沙箱。它解决的是协作状态的恢复与核查。

## 安装

需要：

- Python 3.10 或更高版本；Fleet 核心只使用标准库。
- Bash；使用 `--worktree` 时还需要 Git。
- 你准备启用的 agent CLI，需自行安装并完成认证：Claude Code（`claude`）、Codex（`codex`）、Cursor Agent（`cursor-agent`）或 Grok（`grok`）。

```bash
git clone https://github.com/lfkdsk/fleet.git
cd fleet
export PATH="$PWD/bin:$PATH"
fleet --help
```

请保留仓库目录；`bin/fleet` 会相对仓库查找 schema、适配器、模板和出厂渠道表。运行态默认在 `~/.fleet`，如需换位置，请在 `fleet init` 前设置 `FLEET_HOME`。

## 十分钟上手

先用不访问模型供应商的 `shell` 渠道跑通闭环。它是测试渠道，会把 prompt 当作 Bash 执行，只应传入可信内容。

```bash
export FLEET_HOME=/tmp/fleet-demo/home
fleet init

task_id=$(printf '%s\n' 'printf "fleet is ready\n"' |
  fleet add "Check the local runner" --channel shell --spec - --cwd /tmp/fleet-demo)
fleet run "$task_id"
fleet wait --ids "$task_id" --timeout 60
fleet show "$task_id"
fleet digest "$task_id"
fleet claim add "$task_id" "The local runner produced the expected output" \
  --evidence "command: fleet digest $task_id; output: fleet is ready"
```

上面这组命令已用当前仓库实跑，关键输出如下：

```text
initialized /tmp/fleet-demo/home
started 1
id: 1
status: done
exit_code: 0
fleet is ready
1
```

接着只替换渠道和 prompt。下面的实跑使用了已登录的 Claude Code；如果你配置的是其他 CLI，可改成 `codex`、`cursor` 或 `grok`。

```bash
agent_id=$(printf '%s\n' 'Do not modify files. Reply exactly: agent channel is ready' |
  fleet add "Check a real agent channel" --channel claude-p --spec - \
    --cwd /tmp/fleet-demo --timeout 180)
fleet run "$agent_id"
fleet wait --ids "$agent_id" --timeout 240
fleet digest "$agent_id"
```

这次真实运行的状态是 `done`，`resolved_model: opus`，`exit_code: 0`，输出为：

```text
agent channel is ready
```

处理真实项目时，把要求写进 spec 文件，并使用 `--worktree`：

```bash
task_id=$(fleet add "Fix empty parser input" \
  --channel codex --spec task.md --cwd "$PWD" --worktree --timeout 1800)
fleet run "$task_id"
fleet wait --ids "$task_id"
fleet diff "$task_id"
fleet claim list --task "$task_id"
```

## 仓库目录

```text
bin/            CLI、daemon 实现、MCP server、checks 与 trace 支持
adapters/       CLI 与远端执行适配器
docs/           使用指南、架构与适配器约定
contrib/        可选的网页、通知、用量与本机接线集成
templates/      worker 会合协议 preamble
tests/          smoke 套件与 mutation 清单
channels.json   出厂渠道表
schema.sql      ledger schema 与完整性 trigger
```

## 文档

- [使用指南](docs/guide.zh-CN.md)：渠道、探活、任务参数、goal、自治、状态查看、checks 与清理。
- [架构](docs/architecture.zh-CN.md)：进程边界、任务生命周期、ledger、隔离与恢复。
- [适配器](docs/adapters.zh-CN.md)：调用约定、内置适配器差异、API 端点与测试。
- [参与贡献](CONTRIBUTING.zh-CN.md)：开发检查与仓库守卫。
- [可选集成](contrib/README.zh-CN.md)：本机网页、通知、用量估算与 service 接线。

## License

Fleet 使用 [MIT License](LICENSE)。
