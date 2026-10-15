[English](guide.md) | 中文

# Fleet 使用指南

本文从 [README 快速上手](../README.zh-CN.md)之后讲起，覆盖渠道配置、任务执行、goal、自主推进、状态查看、checks 和归档。脚本若依赖具体参数，请以 `fleet <command> --help` 的当前输出为准。

## 运行态与渠道配置

`fleet init` 会创建 `$FLEET_HOME/fleet.db`，并把出厂 `channels.json` 复制到 `$FLEET_HOME/channels.json`。运行时副本才是实际生效的渠道表，可以直接编辑。`fleet channels --sync` 会先做带时间戳的备份，再用出厂文件覆盖它。

出厂有六个渠道：

| 渠道 | 适配器 | 默认值 | 依赖 |
|---|---|---|---|
| `shell` | `shell.sh` | 无模型 | Bash；只用于测试 |
| `claude-p` | `claude_p.sh` | `opus` | 已认证的 `claude` |
| `codex` | `codex.sh` | `gpt-5.6-sol` | 已认证的 `codex`；渠道并发上限为 2 |
| `cursor` | `cursor.sh` | `claude-opus-5-thinking-max` | 已认证的 `cursor-agent` |
| `grok` | `grok.sh` | `grok-4.6`，effort 为 `high` | 已认证的 `grok` |
| `magpie` | `claude_magpie.sh` | `deepseek/deepseek-chat` | 本机 Magpie 网关；出厂以 `max_parallel: 0` 关闭 |

仓库还带有通用的 `adapters/claude_api.sh`，但没有出厂渠道引用它。配置方式见[适配器文档](adapters.zh-CN.md#anthropic-兼容端点)。

如何配置并打开默认关闭的出厂网关渠道，见[通过 Magpie 使用其他模型](magpie.zh-CN.md)。

### `channels.json` 字段

顶层字段：

| 字段 | 含义 |
|---|---|
| `max_parallel` | `run --ready` 与 daemon 使用的全局并发上限。 |
| `model_families` | 按顺序匹配的 shell 风格 glob 到模型族映射。第一个命中项决定 review 身份；无法归类的模型会被拒绝。 |
| `channels` | 渠道对象，key 就是 `--channel` 接受的名称。 |

每个渠道支持下面这些字段：

| 字段 | 含义 |
|---|---|
| `adapter` | `adapters/` 下的可执行文件名。 |
| `desc` | 给人看的说明，不参与调度。 |
| `model` | 默认模型，以 `FLEET_MODEL` 传给适配器。 |
| `models` | 渠道声明可提供的模型。存在该列表时，普通任务的 `--model` 必须在其中；探活会逐个检查。 |
| `family` | 只有不运行模型的 `shell` 使用 `"none"`；模型渠道由 `model_families` 归类。 |
| `max_parallel` | 渠道级并发上限。设为 `0` 可在不删除配置的情况下关闭渠道。 |
| `model_max_parallel` | 按顺序匹配的模型 glob 与并发上限。第一个命中项生效，同时仍受渠道上限约束。 |
| `quota` | 当前 `YYYY-MM` 周期的默认启动额度。`fleet budget set` 可覆盖指定周期。 |
| `fallback` | 当渠道并发或额度阻塞任务时，可做一次降级的候选渠道顺序。变更前仍会检查并发、额度、模型族与 review 约束。 |
| `effort` | 渠道默认 effort，以 `FLEET_EFFORT` 传入；具体值由对应 CLI 定义。 |
| `model_effort` | 按模型精确匹配的 effort。优先级依次为任务 `--effort`、`model_effort`、`effort`、CLI 默认值。 |
| `subagent_model` | 适配器区分主模型和子模型时，以 `FLEET_SUBAGENT_MODEL` 传入。 |
| `agent` | 可选的具名 agent，以 `FLEET_AGENT` 传入；Claude 系适配器会使用它。 |
| `env_passthrough` | 额外复制到适配器进程的环境变量名，适合显式授予端点凭据。 |
| `prompt_extra` | 模型渠道在任务正文前插入的渠道专用文字。 |
| `ssh_host` / `node` | 自定义远端渠道使用，分别选择 `ssh.sh` 主机或 `switchboard.sh` 节点。 |
| `remote_cmd` | 远端适配器执行的命令。模型渠道必须实际读取注入的 `$FLEET_MODEL`；远端渠道不能担任 reviewer。 |

SSH 与 Switchboard 的完整配置、节点可用性、回调、重试与远端文件系统限制，见[在其他机器上运行任务](remote.zh-CN.md)。

适配器进程只继承白名单环境，以及 `FLEET_`、代理、locale 和少量运行时变量，不会顺手继承任意凭据。API 渠道通常要在 `env_passthrough` 中列出需要的凭据名。

### 先探活，再派任务

```bash
fleet channels
fleet probe claude-p codex
```

`fleet probe [channels ...]` 会通过真实适配器调用所声明的每个模型，需要供应商访问权限，也会消耗额度。结果按渠道和模型写入 ledger。最近一次探活失败会阻止该模型正常入队；修好渠道后应重新探活。`--skip-probe-check` 只适合明确决定忽略这条证据的情况。旧的成功记录会在 `brief` 中显示为 stale，但 stale 本身不等于失败。

## 入队与执行

任务 spec 应写清问题、允许范围、交付物、验证命令和证据要求。用 `--spec FILE` 传文件，或用 `--spec -` 从 stdin 读取。

```bash
task_id=$(fleet add "Fix empty parser input" \
  --channel codex \
  --spec task.md \
  --cwd "$PWD" \
  --worktree \
  --timeout 1800 \
  --max-attempts 2)
fleet run "$task_id"
fleet wait --ids "$task_id" --timeout 1800
```

`fleet run` 脱离终端启动满足条件的任务后立即返回。`fleet run --ready` 会在各项门禁范围内启动当前所有可运行任务；`--max-parallel N` 可为本次调用再加一道限制。`fleet wait` 在前台等待。多个 ID 配合 `--any` 时任意一个结束就返回，配合 `--all` 时等待全部结束。

常用入队参数：

| 参数 | 作用 |
|---|---|
| `--worktree` | 在私有 Git worktree 中运行。`--cwd` 必须是带 `HEAD` 的仓库，适配器拿到的是 worktree 路径。 |
| `--dep ID` | 等任务 `ID` 成功结束；可重复指定。 |
| `--dep ID:base` | 同时以依赖任务的分支作为当前 worktree 基线。单依赖也可写 `--dep-base`，且必须配合 `--worktree`。 |
| `--dep ID:verified` | 等待依赖任务当前版本的 required checks 通过。 |
| `--review-of ID` | 建立 review 关系、加入复审上下文，并要求本机模型 reviewer 使用不同模型族。 |
| `--lens TEXT` | 标注复审关注点，默认是 `correctness`。 |
| `--timeout SECONDS` | 到时终止任务进程组。 |
| `--model MODEL` | 覆盖渠道默认模型；仍要通过 `models`、模型族和探活证据检查。 |
| `--effort VALUE` | 覆盖本任务的 effort。Fleet 不解释具体值，但拒绝空白和引号。 |
| `--context FILE` | 在 Fleet preamble 之后、任务 spec 之前插入项目上下文。可重复；goal context 排在前面；文件缺失会拒绝入队。 |
| `--lease NAME` | 运行时独占一个具名资源。 |
| `--priority N` | 可运行任务中优先选择较高数字。 |
| `--max-attempts N` | 底层 CLI 非零退出或孤儿回收后，最多尝试到这个次数。 |

用 `fleet cancel ID` 取消 queued 或 running 任务。worktree 任务可用 `fleet diff ID` 对比启动基线。Fleet 不会替你 commit、merge、push 或丢弃改动。

### Claim、artifact 与 review

模型适配器会配置 task-scoped MCP server，让 worker 在当前 attempt 内登记证据。操作者也可使用对应 CLI：

```bash
fleet claim add "$task_id" "The empty-input regression is covered" \
  --evidence "tests/parser/test_empty.py:24"
fleet artifact add "$task_id" --path reports/parser.md --kind report \
  --summary "Parser fix verification"
fleet claim list --task "$task_id"
fleet claim verify 42 --status confirmed --note "Reproduced locally"
```

模型 review 成功结束时必须至少留下一个 claim。Review 本身仍是普通任务，可以有自己的 spec、timeout、worktree 上下文与 artifact：

```bash
review_id=$(fleet add "Review parser fix" --channel claude-p \
  --review-of "$task_id" --lens correctness --spec review.md)
```

## Goal、commander 与预算

Goal 把意图和验收条件放在任何一个 agent session 之外：

```bash
goal_id=$(fleet goal add "Fix and review parser boundaries" \
  --acceptance "Focused tests pass and review claims are confirmed" \
  --budget 12 \
  --context project-context.md)
```

`--budget` 限制 goal 下 attempt 总数。`--gate GLOB` 可重复设置需要操作者批准的路径；`--verify-required` 把当前机械 checks 作为关闭 goal 和进入 review-ready 的门禁。`fleet goal list` 查看 goal；`fleet goal close ID` 完成，放弃时加 `--abandon`。

Plan 由带版本的 JSON rules 和 rationale 组成：

```bash
fleet plan set "$goal_id" --rules rules.json \
  --rationale "Review completed work and repair refuted claims"
fleet plan show "$goal_id"
```

每次 `plan set` 都会新建 revision，并重新武装所有规则。如果只是想改说明、又希望之前的触发保持去重，不要重复发布 plan。

自主推进按 goal 显式开启：

```bash
fleet autonomy enable "$goal_id" --channel codex --cwd "$PWD" \
  --max-rounds 8 --max-failures 2 --max-new-tasks 4 --cooldown 120
fleet daemon start
fleet autonomy show "$goal_id"
```

只有在 goal 仍 open、没有 live task、没有未解决的用户 decision、预算和轮数允许、cooldown 已过且出现新信息时，daemon 才创建一个短生命周期的 `role=commander` 任务。Commander 收到有大小上限的 ledger 快照，返回结构化提案。Fleet 在写入候选任务前仍会检查渠道、模型族、review、数量上限、worktree 基线和去重键。

Commander 不是常驻聊天。留给下一轮的信息用 mailbox；需要立刻启动或接入一轮并等待回复时用 `ask`：

```bash
fleet msg send --from user --to commander --goal "$goal_id" \
  "Keep the public interface unchanged"
fleet ask "$goal_id" "What risk remains?" --timeout 900
fleet decisions --needs-user --goal "$goal_id"
fleet decisions resolve 17 --note "Use the compatibility path"
fleet autonomy disable "$goal_id"
```

渠道额度默认按当前月份计算，可显式覆盖：

```bash
fleet budget set codex 2026-10 40
```

Goal 或渠道额度耗尽时，任务会留在 queued，并显示阻塞原因。

## 查看状态

根据问题选最小的视图：

| 命令 | 适用场景 |
|---|---|
| `fleet brief` | 汇总 open goals、意图、live tasks、近期事件、待处理 decision 与 daemon 健康；接手工作先看它。 |
| `fleet status` | 当前目录下每个任务一行；`--all` 取消目录范围，`--goal ID` 限定 goal。 |
| `fleet top` | 交互式实时监视；`--once` 打印一屏，给程序消费时再加 `--json`。 |
| `fleet show ID` | 查看全部字段、当前路径、attempt 身份和历史。 |
| `fleet digest ID` | 有长度上限的最终输出；用 `--max-bytes` 调整。 |
| `fleet since [WATERMARK]` | watermark 之后折叠过的事件；可用 `--goal ID`、`--raw` 或 `--all`。 |
| `fleet trace ID` | 从 transcript 或日志重建工具和命令步骤；`--attempt N` 选 attempt，也支持 `--json`、`--rebuild`。 |
| `fleet tail ID` | 诊断时查看原始日志尾部；`--milestones` 只看里程碑行。 |

队列不动时依次看：

```bash
fleet daemon status
fleet brief
fleet channels
fleet lease list
fleet decisions --needs-user
```

依赖、失败探活、lease、预算、并发、checks 和用户 decision 都会以门禁显示。界面里的 `blocked` 不是持久状态，任务仍是 `queued`，条件解除后可以继续启动。

## 机械 checks

Checks 是操作者拥有的验收命令，属于 goal，并绑定到已结束任务的交付 commit。JSON 可以直接是数组，也可以是只有 `checks` 字段的对象。每项必须恰好包含 `id`、`argv`、`timeout_s`、`expected_exit`、`required`，并且至少有一项 required：

```json
{
  "checks": [
    {
      "id": "parser-tests",
      "argv": ["python3", "-m", "pytest", "tests/parser"],
      "timeout_s": 300,
      "expected_exit": 0,
      "required": true
    }
  ]
}
```

```bash
fleet checks set "$goal_id" --file checks.json
fleet checks run "$task_id"
fleet checks list "$task_id"
```

`argv` 会直接执行，不会隐式套一层 shell。确实需要 shell 语法时，应明确写成 `['bash', '-lc', '...']`。普通 `timeout_s` 上限为 3600 秒；`checks set --allow-long` 可提高到绝对上限 86400 秒。JSON 不需要额外依赖，YAML 输入需要 PyYAML。

第一次创建 check run 时，任务必须成功结束，且 Fleet worktree 已提交、没有脏文件。Detached runner 会再用一个隔离 worktree 和收紧后的环境执行。项目检查失败会产生机械驳回证据；命令不可用或 runner 故障会记为基础设施失败。完整性 trigger 经人工检查并修复后，可用 `fleet checks reseal` 重建并清除 tamper latch。

Checks 能发现同一用户身份下 ledger 历史不一致，但不能把同一用户运行的代码隔离在系统权限之外。

## 归档与清理

清理都需要显式执行，先预览：

```bash
fleet worktree list
fleet worktree prune --dry-run --merged-only
fleet tmp list
fleet tmp prune --dry-run --before 3
fleet archive --dry-run --before 2026-01-01
```

`worktree prune` 只处理 terminal task；`--merged-only` 还要求任务分支已经并入仓库 `HEAD`，并拒绝脏 worktree。`tmp prune` 只有去掉 `--dry-run` 才会删除过期的 terminal-task scratch 和孤立 ledger 命名空间。`archive` 把符合条件的终态历史移到 `$FLEET_HOME/fleet-archive.db`；`archive --status` 查看未完成批次。

Claude 系任务使用 Fleet 管理的配置目录。`fleet worktree prune-claude-projects` 预览过期 session 目录，确认后加 `--apply` 删除。

## 可选集成

Fleet 核心不依赖 `contrib/`。其中包括本机 `fleet-web`、用量估算、通知、decision hook、activity 发布、worktree 审计和 user service 模板。安装方法、依赖与安全默认值见 [contrib/README.zh-CN.md](../contrib/README.zh-CN.md)。

想了解这些行为背后的理由，请继续阅读[架构文档](architecture.zh-CN.md)。
