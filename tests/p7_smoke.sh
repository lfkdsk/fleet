#!/usr/bin/env bash
# fleet P7: task-level worktree isolation + cursor MCP wiring. Cases 1-9 and
# 13-15 use the shell channel and throwaway git repos -- zero model quota;
# 10-12 are adapter dryruns -- zero quota.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p7-test-XXXX)"
SCRATCH=()
cleanup(){ rm -rf "$FLEET_HOME" "${SCRATCH[@]}"; }
trap cleanup EXIT
export PATH="$ROOT/bin:$PATH"
export REAL_GIT="$(command -v git)"

PASS=0
FAIL=0
N=0
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
wait_status(){ local id="$1" want="$2" i; for i in $(seq 1 150); do
  [ "$(field "$id" status)" = "$want" ] && return 0; sleep 0.2; done; return 1; }
wt_of(){ field "$1" worktree; }

fleet init >/dev/null

# A transparent git shim lets the orphan test assert that a same-name tag did
# not route branch existence through merge-base; it logs only when enabled.
mkdir -p "$FLEET_HOME/test-bin"
cat > "$FLEET_HOME/test-bin/git" <<'SH'
#!/usr/bin/env bash
if [ -n "${FLEET_GIT_WATCH:-}" ] && [ "${1:-}" = "-C" ] \
   && [ "${3:-}" = "merge-base" ] && printf '%s\n' "$*" | grep -Fq "$FLEET_GIT_WATCH"; then
  printf '%s\n' "$*" >> "$FLEET_GIT_LOG"
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$FLEET_HOME/test-bin/git"
export PATH="$FLEET_HOME/test-bin:$PATH"

# A throwaway git repo plays the "user's repository" tasks isolate from.
REPO="$FLEET_HOME/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'original\n' > "$REPO/same.txt"
git -C "$REPO" add same.txt
git -C "$REPO" commit -qm base

printf 'echo "PWD=$PWD"\necho task1 > newfile.txt\n' > "$FLEET_HOME/spec1.sh"
printf 'echo A > same.txt\n' > "$FLEET_HOME/specA.sh"
printf 'echo B > same.txt\n' > "$FLEET_HOME/specB.sh"
printf 'sleep 15\n' > "$FLEET_HOME/spec_sleep.sh"
printf ':\n' > "$FLEET_HOME/spec_noop.sh"
printf 'prompt body\n' > "$FLEET_HOME/spec9.md"

# 1. enqueue records the planned branch but creates no worktree yet (a task
# may queue for hours; the worktree is a launch-time artifact)
T1=$(fleet add "wt one" --channel shell --worktree --cwd "$REPO" \
      --spec "$FLEET_HOME/spec1.sh")
if [ ! -d "$FLEET_HOME/worktrees/task-$T1" ] && [ -z "$(wt_of "$T1")" ] \
   && [ "$(field "$T1" worktree_branch)" = "fleet/task-$T1" ]; then
  ok "enqueue plans the branch without creating the worktree"
else
  no "enqueue plans the branch without creating the worktree"
fi

# 2. after launch the worktree exists on branch fleet/task-<id>
fleet run "$T1" >/dev/null
wait_status "$T1" done
W1=$(wt_of "$T1")
if [ -d "$W1" ] \
   && [ "$(git -C "$REPO" branch --list --format='%(refname:short)' 'fleet/task-*')" = "fleet/task-$T1" ]; then
  ok "worktree created on branch fleet/task-$T1"
else
  no "worktree created on branch fleet/task-$T1 (wt=$W1 branches=$(git -C "$REPO" branch --list --format='%(refname:short)' 'fleet/task-*'))"
fi

# 3. the adapter's cwd IS the worktree, not the repository
if fleet digest "$T1" | grep -q "PWD=$W1"; then
  ok "adapter received the worktree path as its cwd"
else
  no "adapter received the worktree path as its cwd (got: $(fleet digest "$T1"))"
fi

# 4. changes stay in the worktree; the original repo stays clean
if [ -z "$(git -C "$REPO" status --porcelain -uall)" ] && [ -f "$W1/newfile.txt" ]; then
  ok "worktree changes do not touch the original repo"
else
  no "worktree changes do not touch the original repo (status=$(git -C "$REPO" status --porcelain -uall))"
fi

# 5. two worktree tasks editing the SAME file in parallel do not overwrite
TA=$(fleet add "wt A" --channel shell --worktree --cwd "$REPO" \
      --spec "$FLEET_HOME/specA.sh")
TB=$(fleet add "wt B" --channel shell --worktree --cwd "$REPO" \
      --spec "$FLEET_HOME/specB.sh")
fleet run "$TA" "$TB" >/dev/null
wait_status "$TA" done
wait_status "$TB" done
WA=$(wt_of "$TA"); WB=$(wt_of "$TB")
if [ "$(cat "$WA/same.txt")" = "A" ] && [ "$(cat "$WB/same.txt")" = "B" ] \
   && [ "$(cat "$REPO/same.txt")" = "original" ]; then
  ok "parallel worktree tasks on the same file stay isolated"
else
  no "parallel worktree tasks on the same file stay isolated"
fi

# 6. the worktree survives the task's end (the diff is the deliverable), and
# fleet diff lists the changed files
if [ -d "$W1" ] && fleet diff "$T1" | grep -q "newfile.txt"; then
  ok "worktree outlives the task; fleet diff lists changed files"
else
  no "worktree outlives the task; fleet diff lists changed files"
fi

# 7. --worktree on a non-git cwd is refused at enqueue, not at run time
mkdir -p "$FLEET_HOME/nogit"
fleet add "nogit" --channel shell --worktree --cwd "$FLEET_HOME/nogit" \
  --spec "$FLEET_HOME/spec1.sh" >/dev/null 2>"$FLEET_HOME/e7"
rc7=$?
if [ "$rc7" = "8" ] && grep -qi "git" "$FLEET_HOME/e7"; then
  ok "non-git cwd with --worktree refused with exit 8"
else
  no "non-git cwd with --worktree refused with exit 8 (rc=$rc7)"
fi

# 8. worktree list shows the tasks; prune removes only terminal tasks' trees
TR=$(fleet add "wt running" --channel shell --worktree --cwd "$REPO" \
      --spec "$FLEET_HOME/spec_sleep.sh")
fleet run "$TR" >/dev/null
for i in $(seq 1 50); do [ -n "$(wt_of "$TR")" ] && break; sleep 0.2; done
WR=$(wt_of "$TR")
if fleet worktree list | grep -q "^$T1 " && fleet worktree list | grep -q "^$TR "; then
  ok "fleet worktree list lists worktree tasks"
else
  no "fleet worktree list lists worktree tasks"
fi
fleet worktree prune > "$FLEET_HOME/prune.out"
if [ ! -d "$W1" ] \
   && ! git -C "$REPO" branch --list | grep -q "fleet/task-$T1" \
   && [ -d "$WR" ]; then
  ok "prune removes terminal tasks' worktrees, never a running task's"
else
  no "prune removes terminal tasks' worktrees, never a running task's"
fi
fleet cancel "$TR" >/dev/null 2>&1 || true

# 9. --merged-only removes a clean merged branch, preserves a committed but
# unmerged branch, and preserves an uncommitted worktree whose tip equals HEAD.
printf 'echo merged > merged.txt\n' > "$FLEET_HOME/spec_merged.sh"
printf 'echo dirty > same.txt\necho untracked > loose.txt\n' > "$FLEET_HOME/spec_dirty.sh"
TM=$(fleet add "wt merged" --channel shell --worktree --cwd "$REPO" \
      --spec "$FLEET_HOME/spec_merged.sh")
TU=$(fleet add "wt unmerged" --channel shell --worktree --cwd "$REPO" \
      --spec "$FLEET_HOME/spec1.sh")
TD=$(fleet add "wt dirty" --channel shell --worktree --cwd "$REPO" \
      --spec "$FLEET_HOME/spec_dirty.sh")
fleet run "$TM" "$TU" "$TD" >/dev/null
wait_status "$TM" done; wait_status "$TU" done; wait_status "$TD" done
WM=$(wt_of "$TM"); WU=$(wt_of "$TU"); WD=$(wt_of "$TD")
git -C "$WM" add merged.txt
git -C "$WM" commit -qm merged-worktree
git -C "$WU" add newfile.txt
git -C "$WU" commit -qm unmerged-worktree
git -C "$REPO" merge --no-ff -qm merge-worktree "fleet/task-$TM"
# A tag with the same short name must not stand in for the unmerged branch.
git -C "$REPO" tag "fleet/task-$TU" HEAD
dirty_dry_out=$(fleet worktree prune --merged-only --dry-run)
merged_out=$(fleet worktree prune --merged-only)
if [ ! -d "$WM" ] && [ -d "$WU" ] && [ -d "$WD" ] \
   && [ "$(cat "$WD/same.txt")" = "dirty" ] && [ "$(cat "$WD/loose.txt")" = "untracked" ] \
   && ! git -C "$REPO" show-ref --verify --quiet "refs/heads/fleet/task-$TM" \
   && git -C "$REPO" show-ref --verify --quiet "refs/heads/fleet/task-$TU" \
   && git -C "$REPO" show-ref --verify --quiet "refs/heads/fleet/task-$TD" \
   && printf '%s\n' "$dirty_dry_out" | grep -Fq "skip $TD fleet/task-$TD: uncommitted changes in $WD" \
   && printf '%s\n' "$merged_out" | grep -Fq "skip $TD fleet/task-$TD: uncommitted changes in $WD" \
   && printf '%s\n' "$merged_out" | grep -Fq "skip $TU fleet/task-$TU: not merged into $REPO HEAD"; then
  ok "--merged-only prunes only clean merged worktrees and reports/preserves dirty or unmerged worktrees"
else
  no "--merged-only guards dirty and unmerged worktrees (dry='$dirty_dry_out' out='$merged_out')"
fi

# 10. --dry-run changes neither disk nor ledger/events.
before_events=$(python3 - "$FLEET_HOME/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT count(*) FROM event WHERE kind='worktree.pruned'").fetchone()[0])
PY
)
dry_out=$(fleet worktree prune --dry-run)
after_events=$(python3 - "$FLEET_HOME/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT count(*) FROM event WHERE kind='worktree.pruned'").fetchone()[0])
PY
)
if [ -d "$WU" ] && [ "$(wt_of "$TU")" = "$WU" ] \
   && git -C "$REPO" show-ref --verify --quiet "refs/heads/fleet/task-$TU" \
   && [ "$before_events" = "$after_events" ] \
   && printf '%s\n' "$dry_out" | grep -Fq "would prune $TU fleet/task-$TU $WU"; then
  ok "--dry-run reports candidates without changing disk, ledger, or events"
else
  no "--dry-run is side-effect free (out='$dry_out' events=$before_events/$after_events)"
fi

# 11. fleet diff on a non-worktree task is an error, not a diff of the repo
TN=$(fleet add "no wt" --channel shell --spec "$FLEET_HOME/spec1.sh")
if fleet diff "$TN" >/dev/null 2>&1; then
  no "fleet diff on a non-worktree task fails"
else
  ok "fleet diff on a non-worktree task fails"
fi
fleet cancel "$TN" >/dev/null 2>&1 || true

# 10. cursor dryrun in a worktree: the worktree stays clean and the MCP config
# is handed over by --plugin-dir out of the task's run dir. Writing it into the
# worktree (the P7 form) left an untracked .cursor/ behind, and
# `worktree prune --merged-only` reads a dirty worktree as unmerged -- case 10
# above is the one that then refuses to reclaim it. See tests/p16_smoke.sh.
MCP=$(python3 -c "import json; print(json.dumps({'mcpServers':{'fleet':{'command':'$ROOT/bin/fleet-mcp','args':[],'env':{'FLEET_HOME':'$FLEET_HOME','FLEET_TASK_ID':'99'}}}}))")
mkdir -p "$FLEET_HOME/worktrees/task-99"
d10=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$MCP" \
  bash "$ROOT/adapters/cursor.sh" 99 "$FLEET_HOME/spec9.md" \
  "$FLEET_HOME/worktrees/task-99" "$FLEET_HOME/o10" "$FLEET_HOME/l10" 2>&1)
if [ ! -e "$FLEET_HOME/worktrees/task-99/.cursor" ] \
   && [ -f "$FLEET_HOME/runs/99/cursor-plugin/.mcp.json" ] \
   && echo "$d10" | grep -q -- "--plugin-dir $FLEET_HOME/runs/99/cursor-plugin" \
   && echo "$d10" | grep -q -- "--approve-mcps"; then
  ok "cursor dryrun keeps the worktree clean and passes --plugin-dir --approve-mcps"
else
  no "cursor dryrun keeps the worktree clean and passes --plugin-dir --approve-mcps (dryrun='$d10')"
fi

# 11. The degradation that is left. A task without --worktree now gets MCP like
# any other -- the config no longer needs a worktree to live in -- but a run dir
# that cannot be written still costs the agent its ledger, and that must be
# loud: an agent that silently cannot file a claim is how a fake-successful task
# gets through.
mkdir -p "$FLEET_HOME/notawt" "$FLEET_HOME/runs"
printf 'not a directory\n' > "$FLEET_HOME/runs/100"
d11out=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MCP_JSON="$MCP" \
  bash "$ROOT/adapters/cursor.sh" 100 "$FLEET_HOME/spec9.md" \
  "$FLEET_HOME/notawt" "$FLEET_HOME/o11" "$FLEET_HOME/l11" 2>"$FLEET_HOME/e11")
if [ ! -e "$FLEET_HOME/notawt/.cursor" ] \
   && ! printf '%s\n' "$d11out" | grep -q -- "--plugin-dir" \
   && grep -qi "MCP" "$FLEET_HOME/e11" \
   && grep -qi "claim" "$FLEET_HOME/e11"; then
  ok "cursor warns loudly when its MCP config cannot be written, and writes nothing"
else
  no "cursor warns loudly when its MCP config cannot be written (stderr='$(cat "$FLEET_HOME/e11")')"
fi

# 12. the written file is valid JSON: the fleet server, correct task id
if python3 - "$FLEET_HOME/runs/99/cursor-plugin/.mcp.json" "$ROOT/bin/fleet-mcp" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
srv = d["mcpServers"]["fleet"]
assert srv["command"] == sys.argv[2], srv
assert srv["env"]["FLEET_TASK_ID"] == "99", srv
assert srv["env"]["FLEET_HOME"], srv
PY
then
  ok "the run dir's .mcp.json is valid JSON with the fleet server and FLEET_TASK_ID"
else
  no "the run dir's .mcp.json is valid JSON with the fleet server and FLEET_TASK_ID"
fi

# 13. launch() generates FLEET_MCP_JSON for every task (envdump test channel)
cat > "$FLEET_HOME/envdump.sh" <<'SH'
#!/usr/bin/env bash
# test-only adapter: dump FLEET_MCP_JSON into the task output file.
printf '%s' "${FLEET_MCP_JSON:-}" > "$4"
SH
chmod +x "$FLEET_HOME/envdump.sh"
python3 - "$FLEET_HOME/channels.json" "$FLEET_HOME/envdump.sh" <<'PY'
import json, sys
p, ad = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["channels"]["envdump"] = {"adapter": ad, "family": "none"}
json.dump(d, open(p, "w"), indent=2)
PY
TE=$(fleet add "envdump" --channel envdump --spec "$FLEET_HOME/spec1.sh")
fleet run "$TE" >/dev/null
wait_status "$TE" done
if fleet digest "$TE" | TE="$TE" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
srv = d["mcpServers"]["fleet"]
assert srv["env"]["FLEET_TASK_ID"] == os.environ["TE"], srv
assert srv["command"].endswith("fleet-mcp"), srv
'; then
  ok "launch passes a generated FLEET_MCP_JSON to the adapter"
else
  no "launch passes a generated FLEET_MCP_JSON to the adapter"
fi

# 14. schema migration: a pre-P7 ledger keeps its data and gains the columns,
# and re-running init does not fail (the migration is idempotent)
OLD="$(mktemp -d /var/tmp/fleet-p7-old-XXXX)"; SCRATCH+=("$OLD"); SCRATCH+=("$OLD")
python3 - "$OLD/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE task(
  id INTEGER PRIMARY KEY,
  goal_id INTEGER, parent_id INTEGER, title TEXT NOT NULL, spec_path TEXT,
  channel TEXT NOT NULL, family TEXT NOT NULL, model TEXT,
  status TEXT NOT NULL DEFAULT 'queued',
  cwd TEXT NOT NULL, deps TEXT NOT NULL DEFAULT '', lease TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  attempt INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 1,
  pid INTEGER, session_id TEXT, exit_code INTEGER,
  run_dir TEXT, out_path TEXT, log_path TEXT,
  review_of INTEGER, lens TEXT, timeout_s INTEGER,
  created_at INTEGER NOT NULL, started_at INTEGER, ended_at INTEGER,
  verdict TEXT, verdict_by TEXT)""")
c.execute("INSERT INTO task(id,title,channel,family,status,cwd,created_at) "
          "VALUES(7,'old task','shell','none','done','/var/tmp',12345)")
c.commit()
PY
FLEET_HOME="$OLD" fleet init >/dev/null
FLEET_HOME="$OLD" fleet init >/dev/null
if python3 - "$OLD/fleet.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
cols = {r[1] for r in c.execute("PRAGMA table_info(task)")}
assert "worktree" in cols and "worktree_branch" in cols, cols
row = c.execute("SELECT id,title,status FROM task WHERE id=7").fetchone()
assert row == (7, "old task", "done"), row
PY
then
  ok "init migrates a pre-P7 ledger in place, data intact, idempotently"
else
  no "init migrates a pre-P7 ledger in place, data intact, idempotently"
fi

# 15. --worktree and --lease compose: the lease still serializes, the
# worktree still isolates
TL=$(fleet add "wt lease" --channel shell --worktree --lease p7-lease \
      --cwd "$REPO" --spec "$FLEET_HOME/spec_sleep.sh")
TLL=$(fleet add "wt lease waiter" --channel shell --worktree --lease p7-lease \
      --cwd "$REPO" --spec "$FLEET_HOME/spec1.sh")
fleet run "$TL" >/dev/null
fleet run "$TLL" >/dev/null 2>&1
if [ "$(field "$TLL" status)" = "queued" ]; then
  ok "lease still blocks a second worktree task while the first runs"
else
  no "lease still blocks a second worktree task while the first runs"
fi
fleet cancel "$TL" >/dev/null 2>&1 || true
fleet run "$TLL" >/dev/null
wait_status "$TLL" done
if [ -n "$(wt_of "$TLL")" ] && [ -z "$(fleet lease list)" ]; then
  ok "worktree and lease compose; lease released after the task settles"
else
  no "worktree and lease compose; lease released after the task settles"
fi

# 16. project-agnostic
PAT="${FLEET_FORBIDDEN_NAMES:-Acme""Corp|acme""-internal}"
if grep -rIn -E "$PAT" "$ROOT" --exclude-dir=.git --exclude-dir=docs; then
  no "project-agnostic: no concrete project names"
else
  ok "project-agnostic: no concrete project names"
fi

# 17-18. --merged-only treats a missing branch or repository as an orphan,
# while a missing branch whose surviving worktree is dirty remains protected.
ORPHAN_REPO="$FLEET_HOME/orphan-repo"
LOST_REPO="$FLEET_HOME/lost-repo"
mkdir -p "$ORPHAN_REPO"
git -C "$ORPHAN_REPO" init -q
git -C "$ORPHAN_REPO" config user.email t@t.t
git -C "$ORPHAN_REPO" config user.name t
printf 'base\n' > "$ORPHAN_REPO/base.txt"
git -C "$ORPHAN_REPO" add base.txt
git -C "$ORPHAN_REPO" commit -qm base
git clone -q "$ORPHAN_REPO" "$LOST_REPO"
OC=$(fleet add "orphan clean" --channel shell --worktree --cwd "$ORPHAN_REPO" --spec "$FLEET_HOME/spec_noop.sh")
OD=$(fleet add "orphan dirty" --channel shell --worktree --cwd "$ORPHAN_REPO" --spec "$FLEET_HOME/spec_noop.sh")
OR=$(fleet add "orphan repo gone" --channel shell --worktree --cwd "$LOST_REPO" --spec "$FLEET_HOME/spec_noop.sh")
fleet run "$OC" "$OD" "$OR" >/dev/null
wait_status "$OC" done; wait_status "$OD" done; wait_status "$OR" done
WC=$(wt_of "$OC"); WD_ORPHAN=$(wt_of "$OD"); WR_ORPHAN=$(wt_of "$OR")
git -C "$WC" checkout -q --detach
git -C "$WD_ORPHAN" checkout -q --detach
git -C "$ORPHAN_REPO" update-ref -d "refs/heads/fleet/task-$OC"
git -C "$ORPHAN_REPO" update-ref -d "refs/heads/fleet/task-$OD"
# A surviving same-name tag must not make the deleted branch look present.
git -C "$ORPHAN_REPO" tag "fleet/task-$OC" HEAD
printf 'dirty\n' > "$WD_ORPHAN/dirty.txt"
rm -rf "$LOST_REPO"
export FLEET_GIT_WATCH="fleet/task-$OC"
export FLEET_GIT_LOG="$FLEET_HOME/orphan-merge-base.log"
dry_orphan_out=$(fleet worktree prune --merged-only --dry-run)
orphan_events_before=$(python3 - "$FLEET_HOME/fleet.db" "$OC" "$OD" "$OR" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT count(*) FROM event WHERE kind='worktree.pruned' AND task_id IN (?,?,?)", sys.argv[2:]).fetchone()[0])
PY
)
if printf '%s\n' "$dry_orphan_out" | grep -Fq "would prune $OC fleet/task-$OC $WC" \
   && printf '%s\n' "$dry_orphan_out" | grep -Fq "skip $OD fleet/task-$OD: branch gone but worktree has changes in $WD_ORPHAN" \
   && printf '%s\n' "$dry_orphan_out" | grep -Fq "would prune $OR fleet/task-$OR $WR_ORPHAN" \
   && [ "$(wt_of "$OC")" = "$WC" ] && [ "$(wt_of "$OD")" = "$WD_ORPHAN" ] \
   && [ "$(wt_of "$OR")" = "$WR_ORPHAN" ] && [ -d "$WD_ORPHAN" ] && [ -d "$WR_ORPHAN" ]; then
  ok "--dry-run --merged-only reports missing-branch/repo orphans and protects dirty orphan worktrees"
else
  no "--dry-run --merged-only classifies orphans without side effects (out='$dry_orphan_out')"
fi
orphan_out=$(fleet worktree prune --merged-only)
orphan_events_after=$(python3 - "$FLEET_HOME/fleet.db" "$OC" "$OD" "$OR" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
print(c.execute("SELECT count(*) FROM event WHERE kind='worktree.pruned' AND task_id IN (?,?,?)", sys.argv[2:]).fetchone()[0])
PY
)
if [ -z "$(wt_of "$OC")" ] && [ ! -d "$WC" ] && [ -z "$(wt_of "$OR")" ] \
   && [ "$(wt_of "$OD")" = "$WD_ORPHAN" ] && [ -d "$WD_ORPHAN" ] \
   && [ ! -e "$WR_ORPHAN" ] \
   && [ ! -s "$FLEET_GIT_LOG" ] \
   && [ $((orphan_events_after - orphan_events_before)) -eq 2 ] \
   && printf '%s\n' "$orphan_out" | grep -Fq "skip $OD fleet/task-$OD: branch gone but worktree has changes in $WD_ORPHAN"; then
  ok "--merged-only reclaims missing-branch/repo orphans and records one event per prune"
else
  no "--merged-only orphan fallback failed (out='$orphan_out' events=$orphan_events_before/$orphan_events_after)"
fi
unset FLEET_GIT_WATCH FLEET_GIT_LOG

# 23-25. The branch-present path checks untracked files recursively, rejects a
# mismatched repository root, and treats a failed status read as unsafe, for
# both dry-run and real prune.
TU_ONLY=$(fleet add "merged untracked only" --channel shell --worktree --cwd "$REPO" --spec "$FLEET_HOME/spec_noop.sh")
TS_FAIL=$(fleet add "merged status failure" --channel shell --worktree --cwd "$REPO" --spec "$FLEET_HOME/spec_noop.sh")
TS_RC_FAIL=$(fleet add "merged status rc failure" --channel shell --worktree --cwd "$REPO" --spec "$FLEET_HOME/spec_noop.sh")
fleet run "$TU_ONLY" "$TS_FAIL" "$TS_RC_FAIL" >/dev/null
wait_status "$TU_ONLY" done; wait_status "$TS_FAIL" done; wait_status "$TS_RC_FAIL" done
WU_ONLY=$(wt_of "$TU_ONLY"); WS_FAIL=$(wt_of "$TS_FAIL"); WS_RC_FAIL=$(wt_of "$TS_RC_FAIL")
mkdir -p "$WU_ONLY/untracked-dir/nested"
printf 'loose\n' > "$WU_ONLY/untracked-dir/nested/file.txt"
# Keep the linked-worktree metadata valid so the toplevel guard passes, then
# corrupt its index so `git status` reaches the returncode != 0 branch.
printf 'bogus' > "$(sed -E 's/^gitdir: //' "$WS_RC_FAIL/.git")/index"
rm "$WS_FAIL/.git"
# Reproduce git's parent-repository discovery: status succeeds and is clean in
# the ignored child, but --show-toplevel identifies the wrong repository.
git -C "$FLEET_HOME" init -q
git -C "$FLEET_HOME" config user.email t@t.t
git -C "$FLEET_HOME" config user.name t
printf 'worktrees/\n' > "$FLEET_HOME/.gitignore"
git -C "$FLEET_HOME" add .gitignore
git -C "$FLEET_HOME" commit -qm parent-repo
branch_guard_dry_out=$(fleet worktree prune --merged-only --dry-run)
branch_guard_out=$(fleet worktree prune --merged-only)
if [ -f "$WU_ONLY/untracked-dir/nested/file.txt" ] \
   && [ "$(wt_of "$TU_ONLY")" = "$WU_ONLY" ] \
   && git -C "$REPO" show-ref --verify --quiet "refs/heads/fleet/task-$TU_ONLY" \
   && printf '%s\n' "$branch_guard_dry_out" | grep -Fq "skip $TU_ONLY fleet/task-$TU_ONLY: uncommitted changes in $WU_ONLY" \
   && printf '%s\n' "$branch_guard_out" | grep -Fq "skip $TU_ONLY fleet/task-$TU_ONLY: uncommitted changes in $WU_ONLY"; then
  ok "branch-present --merged-only and dry-run preserve a worktree with only nested untracked files"
else
  no "branch-present --merged-only missed nested untracked files (dry='$branch_guard_dry_out' out='$branch_guard_out')"
fi
if [ -d "$WS_FAIL" ] && [ ! -e "$WS_FAIL/.git" ] \
   && [ "$(wt_of "$TS_FAIL")" = "$WS_FAIL" ] \
   && git -C "$REPO" show-ref --verify --quiet "refs/heads/fleet/task-$TS_FAIL" \
   && printf '%s\n' "$branch_guard_dry_out" | grep -Fq "skip $TS_FAIL fleet/task-$TS_FAIL: cannot verify worktree state in $WS_FAIL" \
   && printf '%s\n' "$branch_guard_out" | grep -Fq "skip $TS_FAIL fleet/task-$TS_FAIL: cannot verify worktree state in $WS_FAIL"; then
  ok "branch-present --merged-only and dry-run reject a parent repository as the worktree root"
else
  no "branch-present --merged-only accepted the wrong git toplevel (dry='$branch_guard_dry_out' out='$branch_guard_out')"
fi
if [ -d "$WS_RC_FAIL" ] && [ -f "$WS_RC_FAIL/.git" ] \
   && [ "$(wt_of "$TS_RC_FAIL")" = "$WS_RC_FAIL" ] \
   && git -C "$REPO" show-ref --verify --quiet "refs/heads/fleet/task-$TS_RC_FAIL" \
   && printf '%s\n' "$branch_guard_dry_out" | grep -Fq "skip $TS_RC_FAIL fleet/task-$TS_RC_FAIL: cannot read worktree status in $WS_RC_FAIL" \
   && printf '%s\n' "$branch_guard_out" | grep -Fq "skip $TS_RC_FAIL fleet/task-$TS_RC_FAIL: cannot read worktree status in $WS_RC_FAIL"; then
  ok "branch-present --merged-only and dry-run preserve a worktree when git status fails"
else
  no "branch-present --merged-only failed to preserve an unreadable-status worktree (dry='$branch_guard_dry_out' out='$branch_guard_out')"
fi

# 26. Historical Claude session cleanup accepts only an exact Fleet worktree
# slug corroborated by transcript cwd, and only when that worktree is gone.
# A similarly named user project, an ambiguous/spoofed transcript, and a live
# Fleet worktree all survive both the default dry-run and --apply.
CLAUDE_TEST_HOME="$FLEET_HOME/claude-prune-user"
mkdir -p "$CLAUDE_TEST_HOME/.claude/projects" \
  "$FLEET_HOME/worktrees/task-9002"
python3 - "$CLAUDE_TEST_HOME" "$FLEET_HOME" <<'PY'
import json, os, sys
home, fleet = sys.argv[1:]
projects = os.path.join(home, ".claude", "projects")
def slug(path):
    return "".join("-" if c in "/." else c for c in path)
def project(name, cwd):
    path = os.path.join(projects, name)
    os.makedirs(path)
    with open(os.path.join(path, "session.jsonl"), "w") as out:
        out.write(json.dumps({"cwd": cwd}) + "\n")
    return path
stale = os.path.join(fleet, "worktrees", "task-9001")
live = os.path.join(fleet, "worktrees", "task-9002")
spoof = os.path.join(fleet, "worktrees", "task-9003")
paths = {
    "stale": project(slug(stale), stale),
    "live": project(slug(live), live),
    "spoof": project(slug(spoof), os.path.join(home, "code", "task-9003")),
    "user": project(slug(os.path.join(home, "code", "fleet-worktrees-task-9004")),
                    os.path.join(home, "code", "fleet-worktrees-task-9004")),
}
with open(os.path.join(home, "paths.json"), "w") as out:
    json.dump(paths, out)
PY
claude_path(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' \
  "$CLAUDE_TEST_HOME/paths.json" "$1"; }
stale_project=$(claude_path stale); live_project=$(claude_path live)
spoof_project=$(claude_path spoof); user_project=$(claude_path user)
claude_dry=$(HOME="$CLAUDE_TEST_HOME" fleet worktree prune-claude-projects)
if [ -d "$stale_project" ]; then stale_after_dry=1; else stale_after_dry=0; fi
claude_apply=$(HOME="$CLAUDE_TEST_HOME" fleet worktree prune-claude-projects --apply)
if [ "$stale_after_dry" = 1 ] && [ ! -e "$stale_project" ] && [ -d "$live_project" ] \
   && [ -d "$spoof_project" ] && [ -d "$user_project" ] \
   && printf '%s\n' "$claude_dry" | grep -Fq "would prune Claude project for task 9001: $stale_project" \
   && printf '%s\n' "$claude_dry" | grep -Fq "rerun with --apply" \
   && printf '%s\n' "$claude_apply" | grep -Fq "pruned 1 stale Claude project(s)"; then
  ok "Claude project prune is dry-run by default and never touches user, spoofed, or live paths"
else
  no "Claude project prune safety (dry='$claude_dry' apply='$claude_apply')"
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
