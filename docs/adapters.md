English | [中文](adapters.zh-CN.md)

# Writing a Fleet adapter

An adapter is the only component that needs to know a particular agent CLI. Fleet supplies a rendered prompt, execution directory, output paths, and resolved channel settings; the adapter turns them into one non-interactive invocation.

## Invocation contract

Fleet executes the configured file from `adapters/` with five positional arguments:

```text
adapter TASK_ID PROMPT CWD OUT LOG
```

| Argument | Contract |
|---|---|
| `TASK_ID` | Numeric ledger task ID. Use it only for task-scoped configuration or diagnostics. |
| `PROMPT` | Absolute path to the rendered prompt. Read it from stdin or by file; do not copy the full prompt into argv. |
| `CWD` | Effective working directory. For `--worktree`, this is the private task worktree. The adapter must enter it or fail. |
| `OUT` | File for the agent's final answer. This is what `fleet digest` reads. |
| `LOG` | File for diagnostics and CLI stderr. This is what `fleet tail` reads. |

The wrapper already appends adapter stderr to `LOG` from the first instruction, so an early configuration error is not lost. Adapters may also redirect the child CLI's stderr there explicitly.

The adapter must not require a TTY. Pass the prompt through stdin or a file, keep it out of process arguments, and return the child CLI's exit status. A guarded directory change is essential:

```bash
cd "$CWD" || exit 1
```

Exiting `0` tells Fleet that the adapter completed. Fleet may still reject an empty review or an implementation that produced no change and no evidence. Any nonzero status follows the normal retry policy and is preserved on the final attempt. Built-ins use status `2` for several configuration errors and the Claude-based adapters use `75` when the answer says work is still pending; Fleet treats both as nonzero adapter failures rather than adding hidden status semantics.

## Environment

The launcher supplies these values to every adapter, using an empty string when an optional channel setting is absent:

| Variable | Value |
|---|---|
| `FLEET_MODEL` | Effective model after applying the task override and channel default. |
| `FLEET_EFFORT` | Effective task, model, or channel effort. |
| `FLEET_AGENT` | Optional named agent from the channel. |
| `FLEET_SUBAGENT_MODEL` | Optional separate subagent model. |
| `FLEET_HOME` | Ledger home used by the task. |
| `FLEET_TASK_ID` | The same numeric ID as `TASK_ID`. |
| `FLEET_ATTEMPT` | Opaque UUID for this launch. Worker writes must carry it. |
| `FLEET_RUN_DIR` | Current attempt directory. Store generated per-task CLI configuration here, not in the target checkout. |
| `TMPDIR` | Scratch directory namespaced by ledger, task, and attempt. |
| `FLEET_MCP_JSON` | JSON containing the task-scoped `fleet-mcp` stdio server. Use it when the CLI can load MCP configuration. |
| `FLEET_ADAPTER_STDERR_LOGGED` | Internal flag saying the wrapper already captures adapter stderr. |

Remote adapters additionally receive `FLEET_SSH_HOST`, `FLEET_REMOTE_CMD`, `FLEET_SB_NODE`, `FLEET_SB_REMOTE_CMD`, and `FLEET_SB_MCP_CMD` as applicable.

The base process environment is allowlisted. Variables prefixed with `FLEET_`, proxy settings, locale, basic user/runtime values, and a small set of CLI paths pass by default. A channel's `env_passthrough` explicitly adds exact names. New adapters should not read unrelated ambient credentials as a fallback.

### Dry-run mode

Agent and remote adapters should implement:

```text
FLEET_ADAPTER_DRYRUN=1
```

In this mode, validate enough configuration to render the real command, print lines beginning with `DRYRUN:`, do not invoke the provider, do not print secrets, and exit `0`. Build the dry-run line from the same argv array used by the live path so tests cannot pass against a hand-written approximation. `shell.sh` is the test executor itself and is the only shipped adapter without this mode.

## Built-in adapters

`claude_config.sh` is a shared helper, not a channel adapter.

| Adapter | Prompt and CLI | Model controls | Task-scoped MCP and configuration |
|---|---|---|---|
| `shell.sh` | Runs `bash "$PROMPT"`; test-only. | None; its channel is `family: none`. | No MCP setup. |
| `claude_p.sh` | Pipes a one-shot prompt to `claude -p`. | Model, effort, named agent, subagent model. | Inline MCP JSON; Fleet-owned Claude config home keeps task transcripts separate while handling the operator's supported login source. Rejects output that explicitly remains waiting. |
| `codex.sh` | Pipes stdin to `codex exec -` with the repository check and CLI sandbox disabled. | Model. | Adds a task-scoped MCP server through a `-c` override; does not write config into the checkout. |
| `cursor.sh` | Pipes stdin to headless `cursor-agent` with trust enabled and the workspace set to `CWD`. | Model. | Builds a per-attempt plugin under `FLEET_RUN_DIR` and loads its MCP file. |
| `grok.sh` | Gives `grok` the prompt file with verbatim parsing and bypass permissions. | Model and reasoning effort. | Builds a per-attempt `GROK_HOME`, carries the operator's needed CLI files by links, writes only its own MCP config, and disables imported external MCP/hook discovery. |
| `claude_magpie.sh` | Uses Claude Code as a client for a local Magpie Anthropic endpoint. | Model through API environment, effort, named agent, subagent model. | Isolated API config, inline MCP, endpoint health check, and per-provider gateway key support. The factory channel is disabled until configured. |
| `claude_api.sh` | Uses Claude Code against any Anthropic-compatible base URL and auth token. | Model through API environment, effort, named agent, subagent model. | Isolated API config with no operator OAuth credential link; inline MCP. No factory channel is created. |
| `ssh.sh` | Streams the prompt to `ssh -o BatchMode=yes HOST REMOTE_CMD`; remote stdout and stderr return to local files. | Injects `FLEET_MODEL`; a model channel's command must use it. | Ledger remains local; no task MCP callback. Remote channels cannot review. |
| `switchboard.sh` | Copies the prompt to an attempt-scoped remote file, starts a detached job, follows logs, waits, and fetches output. | Injects `FLEET_MODEL`. | Supplies a callback command that reaches the local MCP server; cleans remote scratch best-effort. Remote channels cannot review. |

Cursor and Grok keep generated MCP files outside the working tree so agent plumbing never appears in the delivered diff. Claude-based adapters likewise keep one-shot session state under `FLEET_HOME` rather than adding project files.

## Anthropic-compatible endpoints

`claude_api.sh` accepts either of these pairs:

```text
ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN
FLEET_API_BASE_URL + FLEET_API_KEY
```

The model is required through `FLEET_MODEL`. The adapter exports it as the main Anthropic model and uses `FLEET_SUBAGENT_MODEL` when configured, otherwise the same model for subagents.

Add a channel to `$FLEET_HOME/channels.json` after `fleet init`:

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

This fragment belongs inside the existing top-level `channels` object; do not replace `model_families` or the other factory channels. The example model begins with `claude-`, so the shipped family map classifies it. Add an ordered `model_families` entry when your endpoint uses another naming scheme.

```bash
export ANTHROPIC_BASE_URL=https://api.example.com
export ANTHROPIC_AUTH_TOKEN=replace-me
fleet probe compatible-api
```

The alternative `FLEET_API_*` names already pass through Fleet's prefix allowlist and do not need `env_passthrough`. Do not store live tokens in `channels.json`.

## Implement an adapter

A minimal agent adapter follows this shape:

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

Real adapters should also wire `FLEET_MCP_JSON` when the CLI supports MCP, keep generated config under `FLEET_RUN_DIR`, and forward supported effort or agent settings. Never write task identity into a shared global config: concurrent tasks would race and evidence could land on the wrong ledger row.

Add the adapter filename and model menu to a runtime channel. Family must resolve from the effective model. Reserve `family: none` for an adapter that truly runs no model.

## Test it

Start with syntax and a direct dry run. Use a task-specific directory under `/var/tmp/fleet`:

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

A repository smoke test should put a fake CLI earlier on `PATH`, capture its argv/stdin/environment, and never spend provider quota. Cover at least:

- exact model and effort argv;
- prompt delivery by stdin or file, including a prompt larger than normal argv limits;
- guarded failure when `CWD` is invalid;
- child exit-code propagation and stderr in `LOG`;
- dry-run output with secrets redacted;
- MCP identity containing task ID and attempt UUID;
- two concurrent invocations using different `FLEET_RUN_DIR` values;
- no generated files in the target checkout.

Run the focused test, then the public checks:

```bash
bash tests/smoke.sh
bash tests/run-all.sh
bash tests/mutate.sh --check-only
```

The full matrix expects the repository's supported Python interpreters, including Python 3.14. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the contribution workflow.
