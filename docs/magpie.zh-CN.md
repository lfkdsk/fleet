[English](magpie.md) | 中文

# 通过 Magpie 使用其他模型

[Magpie](https://usemagpie.ai/docs/zh/start) 是需要单独安装的本机网关，不属于 Fleet。它默认监听 `127.0.0.1:3425`，接收 Anthropic、OpenAI 和 Gemini API 流量，并把请求转换后交给已配置的 provider。模型标识采用 `provider/model` 形式。

请按 Magpie 公开文档安装 Magpie 并添加 provider。Fleet 不负责安装网关，也不保存上游 provider 凭据。运行 Fleet 的机器还需要有该 adapter 使用的 `claude` 可执行文件。

## `claude_magpie.sh` 做什么

出厂 `magpie` 渠道使用 `adapters/claude_magpie.sh`。它把 Claude Code 作为 Magpie Anthropic 兼容端点的一次性客户端；所选 `provider/model` 在网关后面可以由其他 provider 协议提供。

每个 attempt 中，adapter 会：

- 进入 task 工作目录，创建 Fleet 管理的隔离 Claude API 配置目录，并且不链接操作者的 OAuth 凭据；
- 把 `ANTHROPIC_BASE_URL` 设为 `FLEET_MAGPIE_URL`，未设置时使用 `http://127.0.0.1:3425`；
- 选择 gateway key，检查 `BASE_URL/v1/models`，若网关在五秒内没有响应，则在启动 Claude Code 前报告配置失败；
- 把生效的 `FLEET_MODEL` 导出为 Claude Code 主 Anthropic 模型；配置了 `FLEET_SUBAGENT_MODEL` 时让 subagent 使用该模型；
- 向 Claude Code 提供本机 task-scoped Fleet MCP server，以及渠道可选的 `agent` 和 `effort`；
- 把渲染后的 prompt 传给 `claude -p`，将最终回答写入 Fleet 输出文件。通常返回 Claude Code 的状态；若回答明确表示工作仍未完成，则以状态 `75` 拒绝该结果。

探活失败会以如下形式写入 task 诊断和输出：

```text
claude_magpie adapter: Magpie gateway not answering at <base-url> (systemctl --user status magpie-web)
```

Adapter 随后非零退出，进入 Fleet 的普通重试与失败处理。

## Gateway key

上游 provider 凭据由 Magpie 保存。`claude_magpie.sh` 把 Magpie gateway key 作为 Anthropic auth token 发送，优先级如下：

1. `FLEET_MAGPIE_KEY`。
2. `~/.config/fleet-magpie/<provider>.key` 的第一行，其中 `<provider>` 是 `FLEET_MODEL` 第一个 `/` 之前的部分。
3. 本机占位值 `magpie`。

设置 `FLEET_MAGPIE_KEY_DIR` 可以替换默认 key 目录。`FLEET_` 前缀的变量会自动通过 Fleet adapter 环境。

按 provider 划分的文件可以保存仅允许访问该 provider 模型的 Magpie gateway key。这样，不同 Fleet 渠道可以使用不同网关权限，又不必把 key 写入 `channels.json`。Gateway key 的创建与权限范围应在 Magpie 中配置；每个 key 文件只允许本机用户读取，并把 key 单独放在第一行。

## 上下文窗口

Claude Code 不认识任意 `provider/model` 标识，否则会按自身默认窗口处理。Adapter 会设置：

```text
CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000
```

已有的 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` 会覆盖该默认值。这个变量不在 Fleet 默认环境 allowlist 中；若从启动 Fleet 的 shell 传入，需要把它加入渠道 `env_passthrough`。该设置只控制 Claude Code 的 compact 阈值，不会扩大 provider 模型真实的上下文上限。应根据渠道提供的模型设置保守值。

## 打开出厂渠道

`fleet init` 会把出厂渠道表复制到 `$FLEET_HOME/channels.json`。其中 `magpie` 渠道有意以 `max_parallel: 0` 关闭。启动 Magpie 并配置 provider 后：

1. 编辑运行时 `$FLEET_HOME/channels.json`，不要改出厂副本。
2. 把渠道 `models` 列表换成允许使用的准确 Magpie ID，并让 `model` 指向其中一项。
3. 确保每个模型都能命中顶层有序 `model_families` 模式。例如，在已有出厂模式尚未覆盖时，为 DeepSeek 模型加入 `"deepseek/*": "deepseek"`。
4. 把渠道 `max_parallel` 改为正数。
5. 如果网关要求认证，配置 gateway key，然后执行 `fleet probe magpie`。
6. 探活成功后再派任务。

运行时配置片段可以写成：

```json
{
  "model_families": {
    "deepseek/*": "deepseek"
  },
  "channels": {
    "magpie": {
      "adapter": "claude_magpie.sh",
      "model": "deepseek/deepseek-chat",
      "models": [
        "deepseek/deepseek-chat"
      ],
      "max_parallel": 2,
      "desc": "Claude Code through the local Magpie gateway."
    }
  }
}
```

这只是片段；编辑运行时文件时，应保留其他出厂 `model_families` 条目和渠道。需要覆盖上下文窗口时，再加入：

```json
"env_passthrough": ["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]
```

随后探活并执行：

```bash
fleet probe magpie
task_id=$(fleet add "Check the gateway client" --channel magpie \
  --spec task.md --cwd "$PWD")
fleet run "$task_id"
fleet wait --ids "$task_id"
```

`fleet probe` 会通过真实 adapter 调用 `models` 中的每一项，因此会使用 provider 访问权限和额度。修改模型列表后应重新探活。

## 模型族仍按真实模型划分

Magpie 是执行路径，不是模型族。每个生效的 `provider/model` 都应按它实际选择的模型归类。同一网关后的两个 provider 可以提供不同模型族；因此，使用同一 Magpie URL 的两个渠道也可能构成有效的跨族组合。

例如，`provider-a/deepseek*` 与 `provider-b/claude*` 两类模式应分别解析为 `deepseek` 与 `claude`。不要因为请求共用一个网关，就把所有 Magpie 模型统一归为 `magpie` 族。

Fleet 仍不会让远端 adapter 担任 reviewer。这里的模型族区别适用于本机 `claude_magpie.sh` 渠道，因为 Fleet 能控制 adapter 与生效模型 ID。

## 与 `claude_api.sh` 的区别

两个 adapter 都使用 Claude Code 作为客户端，并隔离其 API 配置，但路由约定不同：

| | `claude_magpie.sh` | `claude_api.sh` |
|---|---|---|
| 端点 | 默认本机 Magpie 网关，可用 `FLEET_MAGPIE_URL` 覆盖。 | 由 `ANTHROPIC_BASE_URL` 或 `FLEET_API_BASE_URL` 指定的单个 Anthropic 兼容端点。 |
| 认证 | Magpie gateway key，包括按 provider 的 key 文件和本机占位值。 | 来自 `ANTHROPIC_AUTH_TOKEN` 或 `FLEET_API_KEY` 的单个端点 token。 |
| 模型 | Magpie `provider/model`，可路由到多个已配置 provider。 | 由该单一端点直接提供的模型。 |
| 启动前检查 | 启动 Claude Code 前请求 `/v1/models`。 | 检查 URL 与 token 是否存在，没有 Magpie 探活。 |
| 出厂渠道 | 已提供，但配置前默认关闭。 | 没有出厂渠道，需要时自行添加。 |

连接一个明确的 Anthropic 兼容服务时使用 `claude_api.sh`；由本机 Magpie 负责 provider 选择、协议转换与 gateway key 策略时使用 `claude_magpie.sh`。
