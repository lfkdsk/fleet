English | [中文](remote.zh-CN.md)

# Running tasks on another machine

Fleet can send ordinary worker tasks to another machine while keeping scheduling and the SQLite ledger local. There are two remote adapters:

| Adapter | Transport | Prompt and result | Ledger tools |
|---|---|---|---|
| `ssh.sh` | OpenSSH | Streams the prompt over stdin and returns stdout and stderr over the SSH connection. | No remote callback. |
| `switchboard.sh` | Switchboard peer execution | Copies an attempt-scoped prompt, runs a detached job, follows its log, waits, and copies the final output back. | Can expose the local task-scoped MCP server through a Switchboard callback. |

Both adapters run the command configured in `remote_cmd`. The remote machine must already have the selected agent CLI, its authentication, the command's other dependencies, and the working data. Fleet does not install or synchronize any of them.

Remote channels may run work, but they cannot be used with `--review-of`. Fleet cannot prove which model a remote service actually ran, so a remote channel cannot certify the cross-family review invariant.

## SSH

An SSH channel sets `adapter` to `ssh.sh`, selects a destination with `ssh_host`, and supplies the non-interactive command as `remote_cmd`. The adapter executes this shape:

```text
ssh -o BatchMode=yes HOST REMOTE_CMD < PROMPT > OUT 2>> LOG
```

`BatchMode=yes` prevents a detached task from hanging on a password or passphrase prompt. Set up non-interactive authentication and host-key trust before enqueueing work. The remote command must read the prompt from stdin, write its final answer to stdout, and send diagnostics to stderr. The exit status from SSH, including connection failures and the remote command's status, becomes the adapter exit status.

The SSH adapter does not use Fleet's `CWD` on the remote host. Change directory inside `remote_cmd` when the command needs a particular remote path. For example, add this entry inside the existing top-level `channels` object in `$FLEET_HOME/channels.json`:

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

Fleet prefixes the remote line with an escaped `FLEET_MODEL=<model>` assignment. A model-backed SSH or Switchboard channel is rejected at enqueue if `remote_cmd` does not reference `$FLEET_MODEL`, or if that reference is outside a single-quoted inner command. The quoting in the example is intentional: the outer remote shell must pass the reference to `sh -c`, whose environment contains the injected value. A double-quoted or unquoted reference can expand before that assignment takes effect.

The remote machine in this example needs `sh`, `codex`, a completed Codex login, and `/srv/work`. SSH has no task-scoped MCP callback, so the remote agent cannot directly call Fleet's claim or artifact tools. Record those entries locally after examining the returned output or files.

An SSH command is not launched as a durable remote job. Closing the terminal that ran `fleet run` does not stop Fleet's detached local wrapper, but losing the SSH connection returns a nonzero status and may also terminate the remote process. Use Switchboard when a remotely retained job is required.

## Switchboard

Switchboard exposes a machine's shell through a relay and provides peer `exec`, `cp`, detached jobs, logs, and wait operations. Install and sign in to its CLI on both machines, leave the target reachable and willing to accept peer commands, then inspect the available nodes:

```bash
fleet nodes
fleet nodes --json
```

Text output contains the node name, online flag, round-trip time, CPU value, and used memory in GiB. A channel's `node` may be an exact name or an unambiguous prefix. Fleet normally resolves it when the task is enqueued and stores the resolved target with the local `self` node used for callbacks; `--allow-offline` retains the configured selector instead.

A Switchboard command receives Fleet's `CWD` as `switchboard exec --cwd`. Use a path that exists on the remote machine, such as `/srv/work`:

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

The remote machine in this example needs `sh`, `codex`, a completed Codex login, and `/srv/work`. The command reads the prompt from stdin and uses the shipped `gpt-*` family mapping. It runs the task without Fleet tools; to let the remote agent record ledger entries, extend its MCP configuration as described below.

Enqueue and run a task after the remote directory, CLI, and authentication are ready:

```bash
task_id=$(fleet add "Run the remote build" --channel switchboard-gpu \
  --spec task.md --cwd /srv/work --max-attempts 2)
fleet run "$task_id"
fleet wait --ids "$task_id"
```

### One Switchboard attempt

For each attempt, `switchboard.sh` performs these operations:

1. Copies the rendered prompt to `/tmp/fleet-task-<task>-attempt-<attempt>-prompt.md` on the node. Attempt identity prevents a retry from overwriting an older job's files.
2. Starts `remote_cmd` with `switchboard exec --detach --cwd CWD`. The remote command reads that prompt file and writes stdout to a matching attempt-scoped output file.
3. Runs `switchboard logs NODE JOB --follow` in the background and appends the remote job's saved diagnostics to Fleet's local log.
4. Runs `switchboard wait NODE JOB`; its status is kept as the adapter status.
5. Copies the remote output file to Fleet's local task output. A failed fetch fails the attempt even if the job itself exited zero. Remote scratch cleanup is best-effort.

Once accepted, the detached Switchboard job is not tied to the terminal or stdin session that started it, so it can keep running after that client disconnects. This does not make a Fleet attempt automatically reconnectable: the diagnostic log stream may stop if `logs` loses its connection, while a failed `wait` or final `cp` makes the adapter exit nonzero. A retry starts a new Fleet attempt and a new remote job; it does not reattach to the previous job. Make remotely retried commands idempotent, and use `switchboard jobs`, `switchboard logs`, or `switchboard wait` directly when diagnosing an older detached job.

### Offline nodes and retries

By default, Fleet refuses to enqueue a Switchboard task when the selected node is unknown, ambiguous, or offline. `--allow-offline` skips only that target reachability check:

```bash
task_id=$(fleet add "Run when gpu-1 returns" --channel switchboard-gpu \
  --spec task.md --cwd /srv/work --max-attempts 3 --allow-offline)
```

Fleet must still be able to run `switchboard nodes --json` and resolve its local `self` node for the callback. If the target remains unreachable at launch, prompt copy or job start fails and the adapter returns nonzero. With attempts remaining, Fleet puts the task back in `queued`; a later `fleet run` or daemon poll launches the next attempt. After `max_attempts` is exhausted, the task is `failed`.

### Claims and artifacts return to the local ledger

The SQLite ledger never moves to the remote machine. At launch, Fleet builds an attempt-scoped callback command equivalent to:

```text
switchboard exec LOCAL_NODE "env FLEET_HOME=... FLEET_TASK_ID=... FLEET_ATTEMPT=... /path/to/fleet-mcp"
```

The adapter exports that string as `FLEET_SB_MCP_CMD`. To enable Fleet tools, the remote command or an operator-provided wrapper must install it as the command for the agent's `fleet` stdio MCP server. Fleet does not ship a generic wrapper because agent CLIs have different MCP configuration surfaces. Tool requests then travel back through Switchboard and run `fleet-mcp` on the local machine, pinned to the current task and attempt. Claims, messages, and other ledger writes therefore land in the local database; stale writes from an older attempt are rejected.

Artifact registration is not file transfer. The callback's `fleet_artifact` process runs locally and requires its `path` to exist on the local machine so it can compute the size and SHA-256. A remote-only file must first be copied to a local or shared path, then registered locally with `fleet artifact add`. The adapter automatically copies only the task's final answer to Fleet's output path.

`fleet _mcp-callback TASK_ID` prints the callback chosen for an existing task and is useful for adapter diagnostics. Normal launches create and inject it automatically.

## Files and working directories do not synchronize

Remote adapters do not copy the local checkout or a Fleet worktree. SSH sends only the prompt stream. Switchboard copies the prompt and final answer; its `--cwd` names a directory on the remote machine. `--worktree` still creates a local worktree, so it does not make that content appear remotely and normally should not be combined with these channels.

Use one of these explicit workflows:

- Run work whose inputs already live on the remote machine. Point `remote_cmd` or the Switchboard task's `--cwd` at that remote directory, and keep generated results there or copy them back deliberately.
- Have the task clone the repository on the remote machine, create a task-specific branch, commit its changes, and push that branch. Treat the branch name and destination as part of the task specification; Fleet does not clone, merge, or push it for the agent.

In both cases, do not claim a local file as evidence until the file actually exists locally or on a filesystem visible to the local callback.
