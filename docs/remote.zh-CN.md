[English](remote.md) | 中文

# 在其他机器上运行任务

Fleet 可以把普通 worker task 送到另一台机器执行，同时仍在本机调度并保存 SQLite 台账。远端 adapter 有两种：

| Adapter | 传输方式 | Prompt 与结果 | 台账工具 |
|---|---|---|---|
| `ssh.sh` | OpenSSH | Prompt 通过 stdin 流式传输，stdout 与 stderr 通过 SSH 连接返回。 | 没有远端回调。 |
| `switchboard.sh` | Switchboard peer execution | 复制 attempt 级 prompt，启动 detached job，跟随日志、等待并取回最终输出。 | 可通过 Switchboard 回调暴露本机 task-scoped MCP server。 |

两种 adapter 都执行渠道 `remote_cmd` 中配置的命令。远端机器必须事先具备所选 agent CLI、对应认证、命令依赖和工作数据；Fleet 不负责安装或同步这些内容。

远端渠道可以执行普通工作，但不能配合 `--review-of` 使用。Fleet 无法证明远端服务实际运行了哪个模型，因此不能让远端渠道为跨模型族 review 不变量背书。

## SSH

SSH 渠道用 `adapter: "ssh.sh"`，通过 `ssh_host` 选择目标，并把非交互命令写入 `remote_cmd`。Adapter 实际执行的形状是：

```text
ssh -o BatchMode=yes HOST REMOTE_CMD < PROMPT > OUT 2>> LOG
```

`BatchMode=yes` 避免 detached task 卡在密码或密钥口令提示上。入队前应配好非交互认证并确认 host key。远端命令必须从 stdin 读取 prompt，把最终回答写到 stdout，并把诊断写到 stderr。SSH 的退出状态——包括连接失败和远端命令状态——会成为 adapter 退出状态。

SSH adapter 不会在远端使用 Fleet 的 `CWD`。命令依赖特定远端路径时，应在 `remote_cmd` 里显式切换目录。例如，在 `$FLEET_HOME/channels.json` 现有顶层 `channels` 对象中加入：

```json
"ssh-build-box": {
  "adapter": "ssh.sh",
  "ssh_host": "user@host.example",
  "remote_cmd": "sh -c 'cd /srv/work && exec codex exec - -m \"$FLEET_MODEL\"'",
  "model": "gpt-5.6-sol",
  "models": ["gpt-5.6-sol"],
  "max_parallel": 1,
  "desc": "Codex on build-box over SSH."
}
```

Fleet 会在远端命令前加上经过转义的 `FLEET_MODEL=<model>` 环境赋值。声明模型的 SSH 或 Switchboard 渠道，如果 `remote_cmd` 没有引用 `$FLEET_MODEL`，或引用不在单引号包住的内层命令中，会在入队时被拒绝。示例中的引号是有意为之：外层远端 shell 必须把变量引用原样传给 `sh -c`，再由拿到注入值的内层 shell 展开。双引号或不加引号的引用可能在环境赋值生效前就被展开。

上例的远端机器需要 `sh`、`codex`、已完成的 Codex 登录以及 `/srv/work`。SSH 没有 task-scoped MCP 回调，因此远端 agent 不能直接调用 Fleet 的 claim 或 artifact 工具。应在本机检查返回的输出或文件后，再登记这些记录。

SSH 命令不会作为持久远端 job 启动。关闭执行 `fleet run` 的终端不会终止 Fleet 已 detached 的本机 wrapper，但 SSH 连接中断会返回非零状态，也可能终止远端进程。需要远端保留 job 时应使用 Switchboard。

## Switchboard

Switchboard 通过 relay 暴露机器的 shell，并提供 peer `exec`、`cp`、detached job、logs 和 wait。两台机器都应安装并登录 Switchboard CLI，目标机器保持可达且允许 peer 命令，然后查看节点：

```bash
fleet nodes
fleet nodes --json
```

文本输出依次包含节点名、online 标记、往返时延、CPU 值和以 GiB 计的已用内存。渠道的 `node` 可以是完整名称，也可以是不含歧义的前缀。Fleet 通常在 task 入队时解析它，并把最终目标与供回调使用的本机 `self` 节点一起保存；使用 `--allow-offline` 时则保留配置中的 selector。

Switchboard 会把 Fleet 的 `CWD` 作为 `switchboard exec --cwd` 传给远端。这里应使用远端真实存在的路径，例如 `/srv/work`：

```json
"switchboard-gpu": {
  "adapter": "switchboard.sh",
  "node": "gpu-1",
  "remote_cmd": "sh -c 'codex exec - --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -m \"$FLEET_MODEL\"'",
  "model": "gpt-5.6-sol",
  "models": ["gpt-5.6-sol"],
  "max_parallel": 1,
  "desc": "Codex on gpu-1 through Switchboard."
}
```

上例的远端机器需要 `sh`、`codex`、已完成的 Codex 登录以及 `/srv/work`。命令从 stdin 读取 prompt，并使用出厂已有的 `gpt-*` 模型族映射。这个直接命令执行任务时不带 Fleet 工具；如果需要远端 agent 登记台账记录，应按下文扩展它的 MCP 配置。

准备好远端目录、CLI 与认证后，即可入队并执行：

```bash
task_id=$(fleet add "Run the remote build" --channel switchboard-gpu \
  --spec task.md --cwd /srv/work --max-attempts 2)
fleet run "$task_id"
fleet wait --ids "$task_id"
```

### 一次 Switchboard attempt

每个 attempt 中，`switchboard.sh` 会依次执行：

1. 把渲染后的 prompt 复制到节点的 `/tmp/fleet-task-<task>-attempt-<attempt>-prompt.md`。路径包含 attempt 身份，重试不会覆盖旧 job 的文件。
2. 用 `switchboard exec --detach --cwd CWD` 启动 `remote_cmd`。远端命令读取该 prompt 文件，并把 stdout 写入对应的 attempt 级输出文件。
3. 后台执行 `switchboard logs NODE JOB --follow`，把远端 job 保存的诊断追加到 Fleet 本机日志。
4. 执行 `switchboard wait NODE JOB`，并保留它返回的远端 job 状态。
5. 把远端输出文件复制到 Fleet 本机 task 输出。即使 job 以零退出，取回失败也会让本次 attempt 失败。远端 scratch 只做尽力清理。

Detached Switchboard job 一旦被接受，就不再依赖启动它的终端或 stdin session，因此客户端断线后仍可在远端继续运行。但这不代表 Fleet attempt 会自动重连：`logs` 连接丢失时诊断流可能停止，而 `wait` 或最终 `cp` 失败会让 adapter 非零退出。重试会创建新的 Fleet attempt 和新的远端 job，不会接回旧 job。应让可能重试的远端命令具有幂等性；排查旧 job 时可直接使用 `switchboard jobs`、`switchboard logs` 或 `switchboard wait`。

### 离线节点与重试

默认情况下，目标节点未知、名称有歧义或处于离线状态时，Fleet 会拒绝 Switchboard task 入队。`--allow-offline` 只跳过目标节点的可达性检查：

```bash
task_id=$(fleet add "Run when gpu-1 returns" --channel switchboard-gpu \
  --spec task.md --cwd /srv/work --max-attempts 3 --allow-offline)
```

Fleet 仍必须能执行 `switchboard nodes --json`，并解析出用于回调的本机 `self` 节点。若目标在启动时仍不可达，复制 prompt 或启动 job 会失败，adapter 返回非零状态。只要还有 attempt，Fleet 就把 task 放回 `queued`；之后由下一次 `fleet run` 或 daemon poll 启动新 attempt。耗尽 `max_attempts` 后，task 进入 `failed`。

### Claim 与 artifact 如何回到本机台账

SQLite 台账始终留在本机。启动时，Fleet 会生成一条带 attempt 身份的回调命令，形状如下：

```text
switchboard exec LOCAL_NODE "env FLEET_HOME=... FLEET_TASK_ID=... FLEET_ATTEMPT=... /path/to/fleet-mcp"
```

Adapter 把这段字符串导出为 `FLEET_SB_MCP_CMD`。要启用 Fleet 工具，远端命令或操作者提供的 wrapper 需要把它配置成 agent 的 `fleet` stdio MCP server 命令。不同 agent CLI 的 MCP 配置接口不同，因此 Fleet 不提供通用 wrapper。此后工具请求通过 Switchboard 回到本机，并在绑定当前 task 与 attempt 的本机 `fleet-mcp` 中执行。Claim、message 和其他台账写入因此落入本机数据库；旧 attempt 的迟到写入会被拒绝。

登记 artifact 不等于传输文件。回调中的 `fleet_artifact` 进程在本机执行，要求 `path` 已在本机存在，以便计算大小和 SHA-256。仅存在于远端的文件必须先复制到本机或共享路径，再在本机用 `fleet artifact add` 登记。Adapter 自动复制回来的只有 task 最终回答。

`fleet _mcp-callback TASK_ID` 可以打印已有 task 选用的回调命令，适合诊断 adapter；正常启动会自动创建并注入它。

## 文件与工作目录不会自动同步

远端 adapter 不会复制本机 checkout 或 Fleet worktree。SSH 只发送 prompt stream；Switchboard 只复制 prompt 与最终回答，其 `--cwd` 指的是远端机器上的目录。`--worktree` 仍只会创建本机 worktree，无法让内容出现在远端，因此通常不应与这些渠道组合使用。

可明确选择下面一种工作方式：

- 处理输入本来就在远端的任务。让 `remote_cmd` 或 Switchboard task 的 `--cwd` 指向该远端目录；结果保留在远端，或显式复制回来。
- 让 task 在远端 clone 仓库、创建 task 专用分支、提交修改并推送该分支。把分支名和目标写进 task spec；Fleet 不会替 agent clone、merge 或 push。

无论哪种方式，在文件真正出现在本机或本机回调可见的共享文件系统之前，都不要把它当作本机文件证据登记。
