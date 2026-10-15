English | [中文](magpie.zh-CN.md)

# Using other models through Magpie

[Magpie](https://usemagpie.ai/docs/start) is a separately installed local gateway, not part of Fleet. By default it listens on `127.0.0.1:3425`, accepts Anthropic, OpenAI, and Gemini API traffic, and translates requests to configured providers. Its model identifiers use the `provider/model` form.

Install Magpie and add providers by following its public documentation. Fleet neither installs the gateway nor owns upstream provider credentials. The machine running Fleet also needs the `claude` executable used by this adapter.

## What `claude_magpie.sh` does

The factory `magpie` channel uses `adapters/claude_magpie.sh`. It runs Claude Code as a one-shot client of Magpie's Anthropic-compatible endpoint, while the selected `provider/model` may be served through another provider protocol behind the gateway.

For each attempt, the adapter:

- enters the task working directory and creates a Fleet-owned, isolated Claude API configuration home without linking the operator's OAuth credentials;
- sets `ANTHROPIC_BASE_URL` to `FLEET_MAGPIE_URL`, or `http://127.0.0.1:3425` when it is unset;
- chooses a gateway key, checks `BASE_URL/v1/models`, and reports a configuration failure before starting Claude Code if the gateway does not answer within five seconds;
- exports the effective `FLEET_MODEL` as Claude Code's main Anthropic model, and uses `FLEET_SUBAGENT_MODEL` for subagents when configured;
- gives Claude Code the local task-scoped Fleet MCP server, along with the channel's optional `agent` and `effort` settings;
- pipes the rendered prompt to `claude -p` and writes the final answer to Fleet's output file. It returns Claude Code's status, except that an answer which explicitly says work is still pending is rejected with status `75`.

The health-check failure is written to the task diagnostics and output in this form:

```text
claude_magpie adapter: Magpie gateway not answering at <base-url> (systemctl --user status magpie-web)
```

The adapter exits nonzero, so normal Fleet retry and failure handling applies.

## Gateway keys

Magpie holds the upstream provider credentials. `claude_magpie.sh` sends a Magpie gateway key as the Anthropic auth token, using this precedence:

1. `FLEET_MAGPIE_KEY`.
2. The first line of `~/.config/fleet-magpie/<provider>.key`, where `<provider>` is the part of `FLEET_MODEL` before the first `/`.
3. The local placeholder `magpie`.

Set `FLEET_MAGPIE_KEY_DIR` to replace the default key directory. Variables beginning with `FLEET_` pass through Fleet's adapter environment automatically.

A provider-specific file can contain a Magpie gateway key restricted to that provider's models. This lets separate Fleet channels use different gateway permissions without putting keys in `channels.json`. Create and scope gateway keys in Magpie, keep each key file readable only by the local user, and put only the key on its first line.

## Context window

Claude Code does not recognize arbitrary `provider/model` identifiers and otherwise assumes its own default window. The adapter sets:

```text
CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000
```

An existing `CLAUDE_CODE_MAX_CONTEXT_TOKENS` value overrides that default. Because this name is outside Fleet's default environment allowlist, add it to the channel's `env_passthrough` list when setting it in the shell that starts Fleet. This setting controls Claude Code's compaction threshold; it does not increase the provider model's real context limit. Set it to a safe value for the models offered by that channel.

## Enable the factory channel

`fleet init` copies the factory registry to `$FLEET_HOME/channels.json`. Its `magpie` channel is deliberately disabled with `max_parallel: 0`. After Magpie is running and a provider is configured:

1. Edit the runtime `$FLEET_HOME/channels.json`, not the shipped copy.
2. Replace the channel's `models` list with the exact Magpie IDs it may use, and set `model` to one member of that list.
3. Make sure every offered model matches an ordered top-level `model_families` pattern. For example, add `"deepseek/*": "deepseek"` for DeepSeek models when an earlier shipped pattern does not already classify them.
4. Set the channel's `max_parallel` to a positive value.
5. Configure a gateway key if the gateway requires one, then run `fleet probe magpie`.
6. Enqueue work only after the probe succeeds.

A configured runtime fragment can look like this:

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

This is a fragment: preserve the other shipped `model_families` entries and channels when editing the runtime file. If you override the context window, also add:

```json
"env_passthrough": ["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]
```

Then verify and run:

```bash
fleet probe magpie
task_id=$(fleet add "Check the gateway client" --channel magpie \
  --spec task.md --cwd "$PWD")
fleet run "$task_id"
fleet wait --ids "$task_id"
```

`fleet probe` calls every entry in `models` through the real adapter and therefore uses provider access and quota. After changing the model list, probe again.

## Model families still follow the real model

Magpie is a route, not a model family. Classify each effective `provider/model` according to the actual model it selects. Two providers behind the same gateway may expose models from different families, and two channels using the same Magpie URL can therefore be valid cross-family peers.

For example, patterns for `provider-a/deepseek*` and `provider-b/claude*` should resolve to `deepseek` and `claude`, respectively. Do not classify every Magpie model as one `magpie` family merely because the requests share a gateway.

Fleet still does not treat a remote adapter as a reviewer. The distinction above applies to local `claude_magpie.sh` channels, where Fleet controls the adapter and effective model ID.

## Difference from `claude_api.sh`

Both adapters use Claude Code as the client and isolate its API configuration, but their routing contracts differ:

| | `claude_magpie.sh` | `claude_api.sh` |
|---|---|---|
| Endpoint | Local Magpie gateway by default; override with `FLEET_MAGPIE_URL`. | One Anthropic-compatible endpoint from `ANTHROPIC_BASE_URL` or `FLEET_API_BASE_URL`. |
| Authentication | Magpie gateway key, including per-provider key files and a local placeholder. | One endpoint token from `ANTHROPIC_AUTH_TOKEN` or `FLEET_API_KEY`. |
| Models | Magpie `provider/model` routes across configured providers. | Models served directly by that one endpoint. |
| Preflight | Requests `/v1/models` before starting Claude Code. | Validates that URL and token are present; it has no Magpie health check. |
| Factory channel | Present but disabled until configured. | No factory channel; add a custom one when needed. |

Use `claude_api.sh` for one known Anthropic-compatible service. Use `claude_magpie.sh` when the local Magpie gateway owns provider selection, translation, and gateway-key policy.
