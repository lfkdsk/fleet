English | [中文](guide.zh-CN.md)

# Fleet guide

This guide starts after the [README quick start](../README.md). It covers the operating path from channel configuration to archived work. Run `fleet <command> --help` when a script needs the exact current option set.

## Runtime and channel configuration

`fleet init` creates `$FLEET_HOME/fleet.db` and copies the shipped `channels.json` to `$FLEET_HOME/channels.json`. The runtime copy is the effective registry and is meant to be edited. `fleet channels --sync` replaces it with the shipped file after saving a timestamped backup.

The factory registry has six channels:

| Channel | Adapter | Default | Requirement |
|---|---|---|---|
| `shell` | `shell.sh` | no model | Bash; test-only |
| `claude-p` | `claude_p.sh` | `opus` | authenticated `claude` |
| `codex` | `codex.sh` | `gpt-5.6-sol` | authenticated `codex`; channel limit 2 |
| `cursor` | `cursor.sh` | `claude-opus-5-thinking-max` | authenticated `cursor-agent` |
| `grok` | `grok.sh` | `grok-4.6`, effort `high` | authenticated `grok` |
| `magpie` | `claude_magpie.sh` | `deepseek/deepseek-chat` | local Magpie gateway; disabled with `max_parallel: 0` |

There is also a generic `adapters/claude_api.sh`, but no factory channel points to it. See [Adapters](adapters.md#anthropic-compatible-endpoints).

### `channels.json` fields

At the top level:

| Field | Meaning |
|---|---|
| `max_parallel` | Global ceiling used by `run --ready` and the daemon. |
| `model_families` | Ordered shell-style glob to family map. The first match classifies the effective model for review. Unknown models are rejected. |
| `channels` | Object whose keys are the names accepted by `--channel`. |

Each channel may use these fields:

| Field | Meaning |
|---|---|
| `adapter` | Executable filename under `adapters/`. |
| `desc` | Human-readable description; it does not affect scheduling. |
| `model` | Default model passed as `FLEET_MODEL`. |
| `models` | Models the channel declares it can serve. An ordinary task's `--model` override must be in this list when the list exists; probing checks every entry. |
| `family` | Only `shell` uses `"none"`, because it runs no model. Model-backed channels are classified through `model_families`. |
| `max_parallel` | Per-channel running limit. `0` disables the channel without deleting it. |
| `model_max_parallel` | Ordered model globs and per-model limits. First match wins; both model and channel limits apply. |
| `quota` | Default launch quota for the current `YYYY-MM` period. `fleet budget set` overrides it for a named period. |
| `fallback` | Ordered channel names for one scheduler degradation when channel capacity or quota blocks a task. Fleet rechecks capacity, quota, family, and review constraints before changing the task. |
| `effort` | Channel default passed as `FLEET_EFFORT`. Values are CLI-specific. |
| `model_effort` | Exact model-to-effort overrides. Resolution is task `--effort`, then `model_effort`, then `effort`, then the CLI default. |
| `subagent_model` | Optional model passed as `FLEET_SUBAGENT_MODEL` for adapters that distinguish main and subagent models. |
| `agent` | Optional named agent passed as `FLEET_AGENT`; supported by the Claude-based adapters. |
| `env_passthrough` | Extra environment variable names copied into the adapter process. Use it to grant endpoint credentials explicitly. |
| `prompt_extra` | Channel-specific text inserted before the task body for model-backed channels. |
| `ssh_host` / `node` | Select the `ssh.sh` host or `switchboard.sh` node for a custom remote channel. |
| `remote_cmd` | Command executed by a remote adapter. A model channel must consume the injected `$FLEET_MODEL`; remote channels cannot certify reviews. |

Fleet starts adapter environments from an allowlist, plus `FLEET_`, proxy, locale, and a few runtime variables. It does not copy arbitrary credentials. A typical API channel therefore declares its credential names in `env_passthrough`.

### Probe before spending a task

```bash
fleet channels
fleet probe claude-p codex
```

`fleet probe [channels ...]` invokes every declared model through its real adapter. It requires provider access and consumes quota. The result is stored per channel and model. A failed latest probe blocks normal enqueue for that model; rerun the probe after fixing the channel, or use `--skip-probe-check` only when deliberately overriding that evidence. Old successful probes are shown as stale by `brief`, but staleness alone is not a failure.

## Enqueue and run tasks

A task specification should name the problem, allowed scope, deliverables, verification commands, and required evidence. Pass a file with `--spec FILE` or stdin with `--spec -`.

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

`fleet run` starts eligible work detached and returns. `fleet run --ready` starts every currently runnable queued task within the configured gates; `--max-parallel N` adds a limit for that invocation. `fleet wait` remains in the foreground. With several IDs, `--any` returns after the first settles and `--all` waits for all of them.

The task options most often needed are:

| Option | Effect |
|---|---|
| `--worktree` | Run in a private Git worktree. `--cwd` must be a repository with a `HEAD`; the adapter receives the worktree path. |
| `--dep ID` | Wait for task `ID` to finish successfully. Repeat for several dependencies. |
| `--dep ID:base` | Also base this task's worktree on the dependency's branch. `--dep-base` is the single-dependency spelling and requires `--worktree`. |
| `--dep ID:verified` | Wait for the dependency's current required mechanical checks. |
| `--review-of ID` | Create a review edge, include review context, and enforce a different model family for model-backed local reviewers. |
| `--lens TEXT` | Label the review focus; default `correctness`. |
| `--timeout SECONDS` | Terminate the task process group after the limit. |
| `--model MODEL` | Override the channel default. It is checked against `models`, model family rules, and probe evidence. |
| `--effort VALUE` | Override effort for this task. Fleet treats it as opaque but rejects whitespace and quotes. |
| `--context FILE` | Insert project context after Fleet's preamble and before the task spec. Repeatable; goal context comes first. Missing files refuse enqueue. |
| `--lease NAME` | Hold one exclusive named resource while running. |
| `--priority N` | Prefer higher-priority runnable work. |
| `--max-attempts N` | Allow a nonzero adapter exit or recovered orphan to be retried up to the limit. |

Use `fleet cancel ID` for queued or running work. For a worktree task, `fleet diff ID` compares its branch with the launch base. Fleet does not commit, merge, push, or discard the task's changes.

### Claims, artifacts, and reviews

Model adapters configure the task-scoped MCP server so a worker can record evidence during its attempt. Operators can use the CLI equivalents:

```bash
fleet claim add "$task_id" "The empty-input regression is covered" \
  --evidence "tests/parser/test_empty.py:24"
fleet artifact add "$task_id" --path reports/parser.md --kind report \
  --summary "Parser fix verification"
fleet claim list --task "$task_id"
fleet claim verify 42 --status confirmed --note "Reproduced locally"
```

A successful model-backed review must record at least one claim. Reviews are ordinary tasks, so they can have a spec, timeout, worktree context, and their own artifacts:

```bash
review_id=$(fleet add "Review parser fix" --channel claude-p \
  --review-of "$task_id" --lens correctness --spec review.md)
```

## Goals, commander rounds, and budgets

A goal keeps intent and acceptance criteria outside any one agent session:

```bash
goal_id=$(fleet goal add "Fix and review parser boundaries" \
  --acceptance "Focused tests pass and review claims are confirmed" \
  --budget 12 \
  --context project-context.md)
```

`--budget` caps total attempts under the goal. `--gate GLOB` may be repeated for paths that require operator approval, and `--verify-required` makes current mechanical checks a closure and review-ready gate. List goals with `fleet goal list`; close one with `fleet goal close ID`, or use `--abandon` for an abandoned outcome.

Plans are versioned JSON rules plus rationale:

```bash
fleet plan set "$goal_id" --rules rules.json \
  --rationale "Review completed work and repair refuted claims"
fleet plan show "$goal_id"
```

Setting a plan always creates a revision and re-arms its rules. Do not reissue it only to edit prose if previous firings should remain deduplicated.

Autonomy is off until enabled for a goal:

```bash
fleet autonomy enable "$goal_id" --channel codex --cwd "$PWD" \
  --max-rounds 8 --max-failures 2 --max-new-tasks 4 --cooldown 120
fleet daemon start
fleet autonomy show "$goal_id"
```

The daemon creates a short-lived `role=commander` task only when the goal is open, no task is live, no unresolved user decision blocks it, budgets and round limits allow it, cooldown has passed, and there is new information. The commander receives a bounded ledger snapshot and returns a structured proposal. Fleet validates channel, family, review, limit, baseline, and deduplication rules before inserting proposed tasks.

There is no persistent commander chat. Use a mailbox message for later consideration, or `ask` when you want a round and a reply:

```bash
fleet msg send --from user --to commander --goal "$goal_id" \
  "Keep the public interface unchanged"
fleet ask "$goal_id" "What risk remains?" --timeout 900
fleet decisions --needs-user --goal "$goal_id"
fleet decisions resolve 17 --note "Use the compatibility path"
fleet autonomy disable "$goal_id"
```

Channel accounting defaults to the current month. Override a quota explicitly with:

```bash
fleet budget set codex 2026-10 40
```

Exhausted goal or channel budgets leave work queued with a visible blocking reason.

## Read state without reconstructing it

Use the smallest view that answers the question:

| Command | Best use |
|---|---|
| `fleet brief` | Open goals, intent, live work, recent events, pending decisions, and daemon health. Start here after taking over. |
| `fleet status` | One line per task under the current directory; `--all` removes that scope and `--goal ID` narrows it. |
| `fleet top` | Interactive live monitor. `--once` prints one screen; add `--json` for consumers. |
| `fleet show ID` | Every stored field, current paths, attempt identity, and attempt history. |
| `fleet digest ID` | Bounded final output; `--max-bytes` changes the limit. |
| `fleet since [WATERMARK]` | Folded events after a watermark. Use `--goal ID`, `--raw`, or `--all` when needed. |
| `fleet trace ID` | Reconstructed tool and command steps. `--attempt N` selects an attempt; `--json` and `--rebuild` are available. |
| `fleet tail ID` | Raw log tail for diagnosis; `--milestones` selects milestone lines. |

For a queue that is not moving, inspect:

```bash
fleet daemon status
fleet brief
fleet channels
fleet lease list
fleet decisions --needs-user
```

Dependencies, failed probes, leases, budgets, concurrency limits, checks, and user decisions are reported as gates. A displayed `blocked` task remains durably `queued`; it can start after the gate clears.

## Mechanical checks

Checks are operator-owned commands bound to a goal and executed against a settled delivery commit. A JSON file may be an array or an object with one `checks` key. Every check has exactly `id`, `argv`, `timeout_s`, `expected_exit`, and `required`, and at least one must be required:

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

`argv` is executed directly, not through an implicit shell. Use `['bash', '-lc', '...']` only when shell syntax is intentional. The normal timeout ceiling is 3600 seconds; `checks set --allow-long` raises it to the absolute 86400-second ceiling. JSON needs no extra package; YAML input requires PyYAML.

The first check run requires a successful task with a clean, committed Fleet worktree. A detached runner uses another worktree and a reduced environment. Project failure creates mechanical refutation evidence; an unavailable command or runner problem is recorded as infrastructure failure. If integrity triggers were deliberately repaired after inspection, `fleet checks reseal` rebuilds them and clears the tamper latch.

Checks detect inconsistent ledger history under the same user account; they are not a sandbox against code running as that user.

## Archive and clean up

All cleanup is explicit. Preview targets first:

```bash
fleet worktree list
fleet worktree prune --dry-run --merged-only
fleet tmp list
fleet tmp prune --dry-run --before 3
fleet archive --dry-run --before 2026-01-01
```

`worktree prune` only considers terminal tasks; `--merged-only` also requires the task branch to be merged into the repository `HEAD` and refuses dirty worktrees. `tmp prune` removes old terminal-task scratch and orphaned ledger namespaces only without `--dry-run`. `archive` moves eligible terminal history into `$FLEET_HOME/fleet-archive.db`; `archive --status` reports an unfinished batch.

Claude-based task sessions use Fleet-owned configuration homes. `fleet worktree prune-claude-projects` previews stale session directories and `--apply` removes proven stale entries.

## Optional integrations

Core Fleet does not depend on `contrib/`. The directory contains the local `fleet-web` view, usage estimation, notifications, a decision hook, activity publication, worktree audit, and user-service templates. Installation, dependencies, and safety defaults are documented in [contrib/README.md](../contrib/README.md).

For the reasons behind these behaviors, continue with [Architecture](architecture.md).
