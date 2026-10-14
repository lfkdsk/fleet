English | [中文](README.zh-CN.md)

# Fleet

Fleet is a local orchestrator for CLI coding agents: it runs bounded tasks through the CLIs you already use and keeps scheduling state, evidence, and decisions in a SQLite ledger.

Opening several terminals works until one task depends on another, two agents edit the same checkout, a process disappears, or “tests pass” needs independent review. Fleet gives those situations explicit state without replacing the agents themselves.

## The model in one example

Suppose a parser bug needs a fix and an independent review.

| Concept | What it means in Fleet | In the parser example |
|---|---|---|
| **Goal** | The outcome and acceptance criteria shared by several tasks. | “Fix empty input; tests and review must pass.” |
| **Task** | One schedulable unit with a prompt, channel, dependencies, and state. | Implement the fix, then review it. |
| **Channel** | A named execution route: adapter, model choices, limits, and accounting. | Run the fix through `codex`. |
| **Adapter** | A small shell boundary that translates Fleet's task contract into one CLI call. | `codex.sh` invokes `codex exec`. |
| **Ledger** | The SQLite source of truth. Claims state conclusions, artifacts name files, decisions record judgments, and events record transitions. | The worker claims the regression is covered and registers its report. |
| **Daemon** | The process that starts ready work, enforces gates, reaps processes, retries, and applies rules. | Start review only after the fix settles. |
| **Commander** | An optional short-lived agent role that proposes the next bounded tasks for a goal. | Propose a follow-up for a failed edge case. |
| **Review** | A task linked with `review_of`; model-backed reviews must use another model family. | A Claude-family worker reviews a GPT-family fix. |
| **Worktree** | A private Git checkout for one task. | The fixer cannot overwrite the reviewer's checkout. |
| **Lease** | A named exclusive resource held while a task runs. | Only one task may rewrite a shared fixture. |

Fleet does not choose the right model, merge or push code, or provide an OS sandbox. It makes coordination recoverable and inspectable.

## Install

Requirements:

- Python 3.10 or newer; core Fleet uses the standard library.
- Bash, and Git for `--worktree` tasks.
- Each agent CLI you enable, installed and authenticated separately: Claude Code (`claude`), Codex (`codex`), Cursor Agent (`cursor-agent`), or Grok (`grok`).

```bash
git clone https://github.com/lfkdsk/fleet.git
cd fleet
export PATH="$PWD/bin:$PATH"
fleet --help
```

Keep the checkout in place: `bin/fleet` locates its schema, adapters, templates, and channel registry relative to the repository. Runtime state defaults to `~/.fleet`; set `FLEET_HOME` before `fleet init` to move it.

## Ten-minute start

Start with the zero-provider `shell` channel. It is a test channel that executes the prompt as Bash, so use only input you trust.

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

This exact flow was run against the shipped code. The relevant output was:

```text
initialized /tmp/fleet-demo/home
started 1
id: 1
status: done
exit_code: 0
fleet is ready
1
```

Now change only the channel and prompt. This run used an authenticated Claude Code installation; use `codex`, `cursor`, or `grok` if that is the CLI you have configured.

```bash
agent_id=$(printf '%s\n' 'Do not modify files. Reply exactly: agent channel is ready' |
  fleet add "Check a real agent channel" --channel claude-p --spec - \
    --cwd /tmp/fleet-demo --timeout 180)
fleet run "$agent_id"
fleet wait --ids "$agent_id" --timeout 240
fleet digest "$agent_id"
```

The real run settled as `done` with `resolved_model: opus`, `exit_code: 0`, and:

```text
agent channel is ready
```

For project work, put the instructions in a spec file and add `--worktree`:

```bash
task_id=$(fleet add "Fix empty parser input" \
  --channel codex --spec task.md --cwd "$PWD" --worktree --timeout 1800)
fleet run "$task_id"
fleet wait --ids "$task_id"
fleet diff "$task_id"
fleet claim list --task "$task_id"
```

## Repository map

```text
bin/            CLI, daemon implementation, MCP server, checks, and trace support
adapters/       CLI and remote-execution adapters
docs/           operating guide, architecture, and adapter contract
contrib/        optional web, notification, usage, and local wiring integrations
templates/      worker rendezvous preamble
tests/          smoke suites and mutation manifest
channels.json   shipped channel registry
schema.sql      ledger schema and integrity triggers
```

## Documentation

- [Guide](docs/guide.md): channels, probing, task options, goals, autonomy, observation, checks, and cleanup.
- [Architecture](docs/architecture.md): process boundaries, task lifecycle, ledger design, isolation, and recovery.
- [Adapters](docs/adapters.md): the adapter contract, built-in differences, API endpoints, and tests.
- [Contributing](CONTRIBUTING.md): development checks and repository guards.
- [Optional integrations](contrib/README.md): local web view, notifications, usage estimates, and service wiring.

## License

Fleet is released under the [MIT License](LICENSE).
