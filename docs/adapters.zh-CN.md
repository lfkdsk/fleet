[English](adapters.md) | 中文

# 编写 Fleet 适配器

Adapter 是唯一需要了解某个具体 agent CLI 的组件。Fleet 提供渲染后的 prompt、执行目录、输出路径和已经解析的渠道设置；adapter 把这些输入翻译为一次非交互式调用。

## 调用约定

Fleet 用五个位置参数执行 `adapters/` 下配置的文件：

```text
adapter TASK_ID PROMPT CWD OUT LOG
```

| 参数 | 约定 |
|---|---|
| `TASK_ID` | Ledger 中的数字 task ID，只用于 task-scoped 配置或诊断。 |
| `PROMPT` | 渲染后 prompt 的绝对路径。通过 stdin 或文件读取，不要把整段 prompt 放进 argv。 |
| `CWD` | 实际工作目录。使用 `--worktree` 时就是任务私有 worktree。Adapter 必须进入该目录，否则失败。 |
| `OUT` | Agent 最终回答文件，`fleet digest` 读取这里。 |
| `LOG` | 诊断与 CLI stderr 文件，`fleet tail` 读取这里。 |

Wrapper 从 adapter 第一条指令开始就会把 stderr 追加到 `LOG`，因此早期配置错误也不会丢失。Adapter 仍可把子 CLI 的 stderr 明确追加到同一文件。

Adapter 不能要求 TTY。Prompt 应通过 stdin 或文件传递，不出现在进程参数中，并返回子 CLI 的退出码。切换目录必须带失败保护：

```bash
cd "$CWD" || exit 1
```

退出 `0` 表示 adapter 调用完成；Fleet 仍可能拒绝没有 claim 的空 review，或既没改动也没证据的实现任务。任何非零状态都进入普通重试策略，并在最终 attempt 保留。内置 adapter 的一些配置错误使用状态 `2`；Claude 系在回答明确表示仍未完成时使用 `75`。对 Fleet 来说，它们都是非零 adapter failure，没有隐藏的额外 task 状态。

## 环境变量

Launcher 向每个 adapter 提供下面这些值。可选渠道设置不存在时传空字符串：

| 变量 | 值 |
|---|---|
| `FLEET_MODEL` | 应用任务 override 和渠道默认值后的生效模型。 |
| `FLEET_EFFORT` | 从任务、模型或渠道解析出的 effort。 |
| `FLEET_AGENT` | 渠道可选的具名 agent。 |
| `FLEET_SUBAGENT_MODEL` | 可选的独立子模型。 |
| `FLEET_HOME` | 本任务使用的 ledger home。 |
| `FLEET_TASK_ID` | 与 `TASK_ID` 相同的数字 ID。 |
| `FLEET_ATTEMPT` | 本次启动的不透明 UUID；worker 写入必须携带它。 |
| `FLEET_RUN_DIR` | 当前 attempt 目录。生成的 task-scoped CLI 配置应放这里，不要写进目标 checkout。 |
| `TMPDIR` | 按 ledger、task 与 attempt 隔离的 scratch 目录。 |
| `FLEET_MCP_JSON` | 包含 task-scoped `fleet-mcp` stdio server 的 JSON；CLI 支持 MCP 配置时使用。 |
| `FLEET_ADAPTER_STDERR_LOGGED` | 内部标记，表示 wrapper 已经捕获 adapter stderr。 |

远端 adapter 还会按需收到 `FLEET_SSH_HOST`、`FLEET_REMOTE_CMD`、`FLEET_SB_NODE`、`FLEET_SB_REMOTE_CMD` 和 `FLEET_SB_MCP_CMD`。

基础进程环境采用 allowlist。`FLEET_` 前缀、代理、locale、基本用户/运行时变量以及少量 CLI 路径默认可用；渠道的 `env_passthrough` 显式增加其他精确名称。新 adapter 不应把无关的环境凭据当作兜底来源。

### Dry-run 模式

Agent 与远端 adapter 应实现：

```text
FLEET_ADAPTER_DRYRUN=1
```

该模式应完成足够的配置校验以渲染真实命令，打印以 `DRYRUN:` 开头的行，不调用供应商、不打印 secret，并以 `0` 退出。Dry-run 应使用 live path 的同一个 argv 数组，避免测试只验证一份手写近似命令。`shell.sh` 本身就是测试执行器，是唯一没有该模式的出厂 adapter。

## 内置适配器

`claude_config.sh` 是共享 helper，不是渠道 adapter。

| Adapter | Prompt 与 CLI | 模型控制 | Task-scoped MCP 与配置 |
|---|---|---|---|
| `shell.sh` | 运行 `bash "$PROMPT"`；只用于测试。 | 无；对应渠道为 `family: none`。 | 不配置 MCP。 |
| `claude_p.sh` | 把一次性 prompt pipe 给 `claude -p`。 | Model、effort、具名 agent、subagent model。 | Inline MCP JSON；Fleet 管理的 Claude config home 隔离任务 transcript，并处理操作者支持的登录来源。明确表示仍在等待的输出会被拒绝。 |
| `codex.sh` | stdin 交给 `codex exec -`，关闭 repo 检查和 CLI sandbox。 | Model。 | 通过 `-c` override 加入 task-scoped MCP，不在 checkout 写配置。 |
| `cursor.sh` | stdin 交给 headless `cursor-agent`，开启 trust 并把 workspace 设为 `CWD`。 | Model。 | 在 `FLEET_RUN_DIR` 下生成 per-attempt plugin，并加载其中的 MCP 文件。 |
| `grok.sh` | 以 prompt file 调用 `grok`，启用 verbatim 解析与 bypass permissions。 | Model 与 reasoning effort。 | 生成 per-attempt `GROK_HOME`，按需链接操作者 CLI 文件，只写自己的 MCP 配置，并关闭外部 MCP/hook 自动发现。 |
| `claude_magpie.sh` | 用 Claude Code 作为本机 Magpie Anthropic endpoint 的客户端。 | 通过 API 环境设置 model，同时支持 effort、具名 agent 和 subagent model。 | 隔离的 API 配置、inline MCP、endpoint 探活和按 provider 读取 gateway key；出厂渠道默认关闭。 |
| `claude_api.sh` | 用 Claude Code 连接任意 Anthropic 兼容 base URL 和 auth token。 | 通过 API 环境设置 model，同时支持 effort、具名 agent 和 subagent model。 | 隔离的 API 配置，不链接操作者 OAuth credential；inline MCP。没有对应出厂渠道。 |
| `ssh.sh` | 把 prompt stream 给 `ssh -o BatchMode=yes HOST REMOTE_CMD`，远端 stdout/stderr 回到本机文件。 | 注入 `FLEET_MODEL`；模型渠道的命令必须实际使用它。 | Ledger 留在本机，没有 task MCP callback；远端渠道不能 review。 |
| `switchboard.sh` | 把 prompt 复制到 attempt-scoped 远端文件，启动 detached job、跟随日志、等待并取回输出。 | 注入 `FLEET_MODEL`。 | 提供回连本机 MCP server 的命令，尽力清理远端 scratch；远端渠道不能 review。 |

Cursor 和 Grok 把生成的 MCP 文件放在 working tree 之外，避免 agent 接线混入交付 diff。Claude 系也把一次性 session 状态放在 `FLEET_HOME`，不向项目添加配置文件。

## Anthropic 兼容端点

`claude_api.sh` 接受下面任意一组：

```text
ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN
FLEET_API_BASE_URL + FLEET_API_KEY
```

模型必须通过 `FLEET_MODEL` 提供。Adapter 把它导出为主 Anthropic model；配置了 `FLEET_SUBAGENT_MODEL` 时子模型使用该值，否则复用主模型。

执行 `fleet init` 后，在 `$FLEET_HOME/channels.json` 中加入渠道：

```json
{
  "channels": {
    "compatible-api": {
      "adapter": "claude_api.sh",
      "model": "claude-sonnet-compatible",
      "models": ["claude-sonnet-compatible"],
      "max_parallel": 1,
      "env_passthrough": [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN"
      ],
      "desc": "Claude Code through an Anthropic-compatible endpoint."
    }
  }
}
```

这段内容应合并到现有顶层 `channels` 对象中，不要覆盖 `model_families` 或其他出厂渠道。示例模型以 `claude-` 开头，出厂 family map 可以识别；端点使用其他命名方式时，应增加一条有序 `model_families` 映射。

```bash
export ANTHROPIC_BASE_URL=https://api.example.com
export ANTHROPIC_AUTH_TOKEN=replace-me
fleet probe compatible-api
```

另一组 `FLEET_API_*` 名称已经符合 Fleet 的前缀 allowlist，不需要加入 `env_passthrough`。不要把真实 token 存进 `channels.json`。

## 实现一个适配器

最小 agent adapter 可以从下面的结构开始：

```bash
#!/usr/bin/env bash
set -u

TASK_ID="$1"
PROMPT="$2"
CWD="$3"
OUT="$4"
LOG="$5"

cd "$CWD" || exit 1

ARGS=(run --non-interactive)
if [ -n "${FLEET_MODEL:-}" ]; then
    ARGS+=(--model "$FLEET_MODEL")
fi

if [ "${FLEET_ADAPTER_DRYRUN:-}" = 1 ]; then
    printf 'DRYRUN:'
    printf ' %q' my-agent "${ARGS[@]}"
    printf '\n'
    exit 0
fi

my-agent "${ARGS[@]}" < "$PROMPT" > "$OUT" 2>> "$LOG"
```

真实 adapter 还应在 CLI 支持时接入 `FLEET_MCP_JSON`，把生成的配置放在 `FLEET_RUN_DIR`，并转发 CLI 支持的 effort 或 agent 设置。不要把 task identity 写进共享全局配置；并发任务会互相覆盖，证据可能写到错误 ledger row。

随后在运行时渠道表中配置 adapter 文件名和模型菜单。Family 必须能从生效模型解析。只有真正不运行模型的 adapter 才能使用 `family: none`。

## 测试

先做语法检查和直接 dry-run。临时目录放在 `/var/tmp/fleet` 下：

```bash
work=$(mktemp -d /var/tmp/fleet-adapter-XXXXXX)
printf '%s\n' 'Reply with ok' > "$work/prompt.md"
bash -n adapters/my_agent.sh
FLEET_ADAPTER_DRYRUN=1 \
FLEET_MODEL=claude-test \
FLEET_EFFORT=high \
FLEET_RUN_DIR="$work/run" \
adapters/my_agent.sh 7 "$work/prompt.md" "$PWD" "$work/out.md" "$work/log.txt"
```

仓库 smoke test 应在 `PATH` 前端放一个 fake CLI，捕获 argv、stdin 与环境，全程不消耗供应商额度。至少覆盖：

- model 和 effort argv 完全正确；
- prompt 通过 stdin 或文件传递，包括超过常见 argv 限制的大 prompt；
- `CWD` 无效时受控失败；
- 子进程退出码透传，stderr 写入 `LOG`；
- dry-run 输出不泄露 secret；
- MCP identity 同时包含 task ID 和 attempt UUID；
- 两次并发调用使用不同 `FLEET_RUN_DIR`；
- 目标 checkout 中没有生成配置残留。

运行定向测试后，再跑公开检查：

```bash
bash tests/smoke.sh
bash tests/run-all.sh
bash tests/mutate.sh --check-only
```

完整矩阵要求仓库支持的 Python interpreter，其中包括 Python 3.14。贡献流程见 [CONTRIBUTING.zh-CN.md](../CONTRIBUTING.zh-CN.md)。
