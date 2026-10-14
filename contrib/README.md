English | [中文](README.zh-CN.md)

# Optional integrations

Nothing under `contrib/` is required to initialize a ledger, schedule a task, run an adapter, or use `fleet-mcp`. These programs consume Fleet output or install local convenience wiring. Keep them out of a minimal installation unless you want the specific integration.

## `fleet-web`: local read-only view

`fleet-web/` serves overview, goal, and task pages from `~/.fleet/fleet.db` and calls Fleet for live data. It uses only the Python standard library and defaults to `127.0.0.1:8790`; it expects the executable at `~/.local/bin/fleet`, overridable with `FLEET_BIN`. Create a local access token before starting it:

```bash
mkdir -p "$HOME/.config/fleet-web"
python3 -c 'import secrets; print(secrets.token_hex(32))' > "$HOME/.config/fleet-web/token"
chmod 600 "$HOME/.config/fleet-web/token"
python3 contrib/fleet-web/fleet_web.py
```

Open `http://127.0.0.1:8790/?t=<token>`. `FLEET_WEB_HOST` and `FLEET_WEB_PORT` change the listener. GitHub login is off unless `FLEET_WEB_ORG`, `FLEET_WEB_GH_CLIENT_ID`, and `FLEET_WEB_AUTH_WORKER` are all set; that mode also uses an authenticated `gh` CLI to list organization owners. This is an operations view, not a hardened public dashboard. Keep it on loopback unless another authenticated boundary protects it.

## `claude-weekly-usage.py`: local usage estimate

This read-only script estimates Claude Code weekly subscription usage from local assistant transcript token counts and manually recorded percentage anchors. It uses the standard library and reads `~/.claude/projects`, `~/.claude.json`, and `~/.local/state/claude-usage/anchors.json`:

```bash
python3 contrib/claude-weekly-usage.py
```

The result is a heuristic based on public price weights, not provider billing data. It needs a recent interactive usage snapshot to discover the reset boundary, and it can only estimate a percentage after anchors exist. Use the provider's own usage display for quota decisions.

## `notify-lark.py`: selected ledger notifications

The notifier formats verified or refuted claims, new user decisions, final failures, and stalls. Python itself is sufficient for dry-run output; actual delivery requires `lark-cli`. It sends nothing unless `--send` is present:

```bash
python3 contrib/notify-lark.py
python3 contrib/notify-lark.py --send
```

The default config is `${XDG_CONFIG_HOME:-$HOME/.config}/fleet-contrib/notify-lark.json`:

```json
{
  "chat_id": "",
  "user_id": ""
}
```

Set one target; `chat_id` wins if both are present. A missing target makes `--send` fail before any backend call. State and event watermarks live under `${XDG_STATE_HOME:-$HOME/.local/state}/fleet-contrib/`. Command options include `--config`, `--state`, `--max-lines`, `--fleet-bin`, and `--lark-bin`; the corresponding overrides are `FLEET_NOTIFY_CONFIG`, `FLEET_NOTIFY_STATE`, `FLEET_NOTIFY_FLEET`, and `FLEET_NOTIFY_LARK`.

## `surface-decisions.py`: Claude Code Stop hook

This standard-library hook reads the SQLite ledger in read-only mode. It surfaces unresolved `needs_user` decisions once per session and may block Stop up to three times for an unchanged set of in-flight tasks with no live `fleet wait` watcher. The watcher check uses `/proc`, so that part is Linux-specific. A ledger or process-table error fails open and writes a warning instead of trapping the host session.

Install it with the dry-run-first wiring tool rather than invoking it interactively:

```bash
contrib/wiring/install.sh --only stop-hook
contrib/wiring/install.sh --apply --only stop-hook
```

The installer merges the hook into `~/.claude/settings.json`, backs up an existing valid file before changing it, and refuses invalid JSON. Override the hook's per-session state path with `FLEET_SURFACE_STATE`.

## `publish-activity.py`: compact activity snapshot

This script converts `fleet top --once --json` into a small `fleet.json` activity file. It reads JSON from stdin when supplied; otherwise it invokes Fleet. The destination is `SWITCHBOARD_ACTIVITY_DIR` or `~/.switchboard/activity.d`:

```bash
fleet top --once --json | python3 contrib/publish-activity.py
```

It uses only the standard library, writes by atomic replacement, and exits successfully without writing when the destination directory does not exist. The optional `fleet-activity.timer` refreshes the file every ten seconds.

## `worktree-audit.sh`: prune preflight

The audit calls `fleet worktree list --json`, then uses Git and `du` to classify recorded worktrees. `risky` means uncommitted files, commits ahead of the current repository branch, or an inspection failure; `clean` has neither ahead commits nor dirty files; `stale` has no directory:

```bash
contrib/worktree-audit.sh
contrib/worktree-audit.sh --json
```

It returns `1` when any worktree is risky and `2` when Fleet output cannot be read. It never deletes. Use its report before an explicit `fleet worktree prune`.

## `wiring/`: user services and timers

`wiring/install.sh` supports `stop-hook`, `activity`, `notify`, and `daemon`. It requires Python, and service installation expects a systemd user manager. The default is a dry run:

```bash
contrib/wiring/install.sh
contrib/wiring/install.sh --only daemon
contrib/wiring/install.sh --apply --only daemon
contrib/wiring/install.sh --apply --only stop-hook,activity
```

Output prefixes are `+` create, `~` update, `=` already correct, and `!` refused or unavailable. The installer renders the current checkout paths, installs units under the user configuration directory, and enables ready units with `systemctl --user enable --now`. It will not enable the notification timer until the notification config has a target.

The daemon unit uses `Restart=always`. Under that unit, `fleet daemon stop` causes systemd to start it again; use `systemctl --user stop fleet-daemon` when it must remain stopped. `wiring/fleet-web.service` is a standalone template and is not installed by `install.sh`; it expects the web directory at `~/.local/share/fleet-web`.

## Validation and state

Integration state belongs in each integration's config or state directory, not in the Fleet ledger unless it is actual Fleet state. Scripts that send or modify configuration are dry-run or explicitly gated by default.

Run the contrib acceptance suite after changing any component:

```bash
bash tests/contrib_smoke.sh
```

Core operation is documented in the [Fleet guide](../docs/guide.md).
