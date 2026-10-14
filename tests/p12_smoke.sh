#!/usr/bin/env bash
# fleet P12 smoke tests: the three archive data-corruption bugs and the
# remaining medium audit items.
#
# A1  archive used to commit the archive copy first and only then delete;
#     decision.task_id / task.parent_id / task.review_of /
#     review.reviewer_task_id all reference task(id), so the DELETE failed
#     on foreign keys and the same rows sat committed in BOTH databases.
# A2  task.deps is TEXT with no foreign key, so archiving a task a queued
#     task still names in its deps blocked that task forever (deps_done
#     reads a missing row as not-done).
# A3  fleet-archive.db was never migrated: CREATE TABLE IF NOT EXISTS is a
#     no-op on an old table, so an old archive db kept the pre-P7 structure
#     and every INSERT failed ('table task has no column named worktree').
# B1  the API adapter passed --agent twice (byte-identical duplicated block).
# B2  cursor.sh put the whole prompt in argv: E2BIG past ~128 KiB, and
#     because `> "$OUT"` opens first, out.md was truncated to empty, so the
#     failure looked like success with no output. cursor-agent reads the
#     prompt from stdin (verified empirically), so the prompt now travels
#     via stdin like every other adapter.
# B3  `fleet since` advanced the watermark over lines --max-lines cut, so
#     the cut lines were gone and the hint's "用 --all 查看" was a lie.
# B4  start_ready printed "blocked N unknown channel" to stdout, which under
#     the daemon lands in fleetd.log where nobody reads it.
# B5  a channel without a models list accepted any --model for a --review-of
#     task, so the review's family was an unverified assertion.
# P12b (the review's four refutations):
# A   re-archiving reused ids silently: task.id is a reusable INTEGER PRIMARY
#     KEY, so once a batch emptied the live table the next task reused id 1
#     and INSERT OR REPLACE overwrote batch 1's archived row. The archive
#     tables now key on (archived_seq, id); both batches survive.
# B   the closure was computed before the transaction and the delete ran on a
#     second, FK-off connection, so a referrer born in between met a silent
#     success (deps has no FK) and the dep task stayed blocked forever. The
#     closure is now recomputed inside the delete transaction; the batch
#     rolls back cleanly instead.
# C   nothing is atomic across two WAL databases; the batch is now staged
#     (receipt -> copy -> verify+delete) and a crashed run is recovered by
#     the next one instead of leaving the rows in both databases.
# D   on a channel that HAS a models list, the strict list check fired before
#     the review path, so a --review-of model with a successful probe but no
#     list entry was refused and the probe-success branch was unreachable.
# Zero model quota: shell channel + adapter dryruns + a stub cursor-agent.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p12-test-XXXX)"
export PATH="$ROOT/bin:$PATH"
unset _FLEET_LOCK_FD

PASS=0
FAIL=0
N=0

ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }

field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }

wait_status(){
  local id="$1" want="$2" i got
  for i in $(seq 1 150); do
    got=$(field "$id" status)
    [ "$got" = "$want" ] && return 0
    sleep 0.2
  done
  return 1
}

cleanup(){ fleet daemon stop >/dev/null 2>&1 || true; rm -rf "$FLEET_HOME"; }
trap cleanup EXIT

fleet init >/dev/null
printf 'echo hi\n' > "$FLEET_HOME/spec_echo.sh"

age_task(){  # ended_at = 100 days ago, so --before today selects the task
  python3 - "${2:-$FLEET_HOME}/fleet.db" "$1" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE task SET ended_at=? WHERE id=?",
          (int(time.time()) - 864000, sys.argv[2]))
c.commit()
EOF
}

# 1. A1: a task carrying every referencing row type (decision, review by it,
#    claim, artifact, events) archives whole, and no row survives in the
#    live db. Pre-fix the DELETE failed on foreign keys after the archive
#    copy was already committed, leaving the rows in both databases.
T1=$(fleet add "p12 a1 old" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T1" >/dev/null
wait_status "$T1" done
fleet claim add "$T1" "a1 claim" --evidence "spec:1" >/dev/null
age_task "$T1"
python3 - "$FLEET_HOME/fleet.db" "$T1" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1]); now = int(time.time()); t = sys.argv[2]
c.execute("INSERT INTO artifact(task_id,kind,path,ts) VALUES(?,?,?,?)",
          (t, "note", "x", now))
c.execute("INSERT INTO decision(goal_id,task_id,question,ts) VALUES(NULL,?,?,?)",
          (t, "q", now))
c.execute("INSERT INTO review(task_id,reviewer_task_id,lens,channel,family,round,ts) "
          "VALUES(?,?,?,?,?,1,?)", (t, t, "correctness", "shell", "none", now))
c.commit()
EOF
arch1=$(fleet archive --before "$(date +%F)")
M1=$(python3 - "$FLEET_HOME/fleet.db" "$FLEET_HOME/fleet-archive.db" "$T1" <<'EOF'
import sqlite3, sys
hot, arch, t = sys.argv[1], sys.argv[2], sys.argv[3]
h = sqlite3.connect(hot); a = sqlite3.connect(arch)
for tbl, col in (("task", "id"), ("event", "task_id"), ("claim", "task_id"),
                 ("review", "task_id"), ("artifact", "task_id"),
                 ("decision", "task_id")):
    assert h.execute(f"SELECT COUNT(*) FROM {tbl} WHERE {col}=?",
                     (t,)).fetchone()[0] == 0, f"live {tbl} not empty"
assert a.execute("SELECT COUNT(*) FROM task WHERE id=?", (t,)).fetchone()[0] == 1
assert a.execute("SELECT COUNT(*) FROM event WHERE task_id=?", (t,)).fetchone()[0] >= 1
assert a.execute("SELECT COUNT(*) FROM claim WHERE task_id=?", (t,)).fetchone()[0] == 1
assert a.execute("SELECT COUNT(*) FROM artifact WHERE task_id=?", (t,)).fetchone()[0] == 1
assert a.execute("SELECT COUNT(*) FROM decision WHERE task_id=?", (t,)).fetchone()[0] == 1
assert a.execute("SELECT COUNT(*) FROM review WHERE reviewer_task_id=?", (t,)).fetchone()[0] == 1
print("ok")
EOF
)
if printf '%s\n' "$arch1" | grep -q "archived 1" && [ "$M1" = "ok" ]; then
  ok "A1: task with decision/review/claim/artifact rows archived whole, live db clean"
else
  no "A1: atomic archive across both DBs (M1=$M1 out=$arch1)"
fi

# 2. A2: a task a non-terminal task still names in its deps is skipped with
#    a reason, in both --dry-run and the real run; the dep task is untouched.
A2=$(fleet add "p12 a2 old" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$A2" >/dev/null
wait_status "$A2" done
age_task "$A2"
B2=$(fleet add "p12 a2 dep" --channel shell --dep "$A2" --spec "$FLEET_HOME/spec_echo.sh")
dry2=$(fleet archive --before "$(date +%F)" --dry-run)
real2=$(fleet archive --before "$(date +%F)")
fleet show "$A2" >/dev/null 2>&1 && a2_live=1 || a2_live=0
if printf '%s\n' "$dry2" | grep -q "skipped 1" \
   && printf '%s\n' "$dry2" | grep -q "referenced in deps by non-terminal task $B2" \
   && printf '%s\n' "$real2" | grep -q "skipped 1" \
   && [ "$a2_live" = "1" ] \
   && [ "$(field "$B2" status)" = "queued" ]; then
  ok "A2: dep-referenced task skipped with reason, still live, dep task untouched"
else
  no "A2: dep skip (dry='$dry2' real='$real2' live=$a2_live)"
fi

# 3. A2 resolved: once the dep task is terminal, the archive proceeds (the
#    dep task itself stays, being too young).
fleet run "$B2" >/dev/null
wait_status "$B2" done
arch2b=$(fleet archive --before "$(date +%F)")
M2b=$(python3 - "$FLEET_HOME/fleet.db" "$FLEET_HOME/fleet-archive.db" "$A2" "$B2" <<'EOF'
import sqlite3, sys
h = sqlite3.connect(sys.argv[1]); a = sqlite3.connect(sys.argv[2])
a2, b2 = sys.argv[3], sys.argv[4]
# A2's id is reused (T1 had it and was archived+deleted in test 1), so the
# archive legitimately holds TWO rows with that id -- one per batch. Scope
# to the latest batch: the old INSERT OR REPLACE would have collapsed them.
latest = a.execute("SELECT COALESCE(MAX(archived_seq),0) FROM task").fetchone()[0]
ok = (a.execute("SELECT COUNT(*) FROM task WHERE id=? AND archived_seq=?",
                (a2, latest)).fetchone()[0] == 1
      and h.execute("SELECT COUNT(*) FROM task WHERE id=?", (a2,)).fetchone()[0] == 0
      and h.execute("SELECT COUNT(*) FROM task WHERE id=?", (b2,)).fetchone()[0] == 1)
print("ok" if ok else "no")
EOF
)
if printf '%s\n' "$arch2b" | grep -q "archived 1" && [ "$M2b" = "ok" ]; then
  ok "A2: archive proceeds once the dep task is terminal"
else
  no "A2: archive after dep terminal (M2b=$M2b out=$arch2b)"
fi

# 4. A3: an old batched fleet-archive.db (pre-P7/C0, no worktree or attempt
#    columns) is rebuilt before the next INSERT. Existing rows keep their
#    archived_seq and gain explicit legacy attempt provenance.
T4=$(fleet add "p12 a3 old" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T4" >/dev/null
wait_status "$T4" done
age_task "$T4"
rm -f "$FLEET_HOME"/fleet-archive.db*
python3 - "$FLEET_HOME/fleet-archive.db" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("""CREATE TABLE task(
  id INTEGER NOT NULL, goal_id INTEGER, parent_id INTEGER, title TEXT NOT NULL,
  spec_path TEXT, channel TEXT NOT NULL, family TEXT NOT NULL, model TEXT,
  status TEXT NOT NULL DEFAULT 'queued', cwd TEXT NOT NULL,
  deps TEXT NOT NULL DEFAULT '', lease TEXT, priority INTEGER NOT NULL DEFAULT 0,
  attempt INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 1,
  pid INTEGER, session_id TEXT, exit_code INTEGER, run_dir TEXT, out_path TEXT,
  log_path TEXT, review_of INTEGER, lens TEXT, timeout_s INTEGER,
  created_at INTEGER NOT NULL, started_at INTEGER, ended_at INTEGER,
  verdict TEXT, verdict_by TEXT, archived_seq INTEGER NOT NULL,
  PRIMARY KEY(archived_seq,id))""")
c.execute("INSERT INTO task(id,title,channel,family,cwd,created_at,archived_seq) "
          "VALUES(99,'old archived row','shell','none','/',1,1)")
cols = [r[1] for r in c.execute("PRAGMA table_info(task)")]
assert "worktree" not in cols and "resolved_model" not in cols, cols
c.commit()
EOF
arch4=$(fleet archive --before "$(date +%F)")
M4=$(python3 - "$FLEET_HOME/fleet.db" "$FLEET_HOME/fleet-archive.db" "$T4" <<'EOF'
import sqlite3, sys
h = sqlite3.connect(sys.argv[1]); a = sqlite3.connect(sys.argv[2]); t = sys.argv[3]
cols = {r[1] for r in a.execute("PRAGMA table_info(task)")}
ok = ({"worktree", "worktree_branch", "resolved_model", "resolved_agent",
       "attempt_id", "commander_lease_generation"} <= cols
      and a.execute("SELECT COUNT(*) FROM task WHERE id=?", (t,)).fetchone()[0] == 1
      and a.execute("SELECT attempt_id FROM task WHERE id=99").fetchone()[0] == "legacy"
      and h.execute("SELECT COUNT(*) FROM task WHERE id=?", (t,)).fetchone()[0] == 0)
print("ok" if ok else "no")
EOF
)
if printf '%s\n' "$arch4" | grep -q "archived 1" && [ "$M4" = "ok" ]; then
  ok "A3: old batched archive gains current columns and legacy provenance"
else
  no "A3: archive db migration (M4=$M4 out=$arch4)"
fi

# 5. B1: claude_api.sh passes --agent exactly once (the block was
#    duplicated byte-for-byte, so agent channels got `--agent X --agent X`).
printf 'x\n' > "$FLEET_HOME/p5.md"
d5=$(FLEET_ADAPTER_DRYRUN=1 FLEET_AGENT=reviewer FLEET_MODEL=claude-test \
     FLEET_API_BASE_URL=https://api.example.test FLEET_API_KEY=test-key \
     bash "$ROOT/adapters/claude_api.sh" 1 "$FLEET_HOME/p5.md" "$FLEET_HOME" \
     "$FLEET_HOME/o5" "$FLEET_HOME/l5")
n5=$(printf '%s\n' "$d5" | grep -o -- '--agent reviewer' | wc -l | tr -d ' ')
d5b=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=claude-test \
      FLEET_API_BASE_URL=https://api.example.test FLEET_API_KEY=test-key \
      bash "$ROOT/adapters/claude_api.sh" 1 "$FLEET_HOME/p5.md" "$FLEET_HOME" \
      "$FLEET_HOME/o5" "$FLEET_HOME/l5")
if [ "$n5" = "1" ] && ! printf '%s\n' "$d5b" | grep -q -- '--agent'; then
  ok "B1: API --agent exactly once when set, absent when unset"
else
  no "B1: API --agent dedup (n=$n5)"
fi

# 6. B1 audit: no adapter carries a repeated 3-line code block (the API
#    defect was a copy-paste; this check catches the same shape anywhere).
D6=$(python3 - "$ROOT/adapters" <<'EOF'
import pathlib, sys
bad = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.sh")):
    lines = [l.strip() for l in f.read_text().splitlines()
             if l.strip() and not l.strip().startswith("#")]
    seen = set()
    for i in range(len(lines) - 2):
        block = "\n".join(lines[i:i+3])
        if block in seen:
            bad.append(f"{f.name}: {block!r}")
        seen.add(block)
print("\n".join(bad) if bad else "ok")
EOF
)
if [ "$D6" = "ok" ]; then
  ok "B1: no repeated 3-line code blocks in any adapter"
else
  no "B1: adapter duplicate-block audit ($D6)"
fi

# 7. B2 dryrun: the prompt text never appears in cursor's argv.
printf 'PROMPT-SECRET-P12\n' > "$FLEET_HOME/p7.md"
d7=$(FLEET_ADAPTER_DRYRUN=1 \
     bash "$ROOT/adapters/cursor.sh" 1 "$FLEET_HOME/p7.md" "$FLEET_HOME" \
     "$FLEET_HOME/o7" "$FLEET_HOME/l7")
if ! printf '%s\n' "$d7" | grep -q "PROMPT-SECRET-P12" \
   && printf '%s\n' "$d7" | grep -q "cursor-agent"; then
  ok "B2: cursor dryrun argv carries no prompt text"
else
  no "B2: cursor dryrun argv ($d7)"
fi

# 8. B2 real: a 200KiB prompt (>MAX_ARG_STRLEN 128KiB) reaches a stub
#    cursor-agent whole via stdin, argv stays small, output is intact.
#    Pre-fix the exec died with E2BIG after `> "$OUT"` truncated out.md,
#    which presented as success with no output.
mkdir -p "$FLEET_HOME/stubbin"
cat > "$FLEET_HOME/stubbin/cursor-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" | awk '{print length}' > "${FLEET_HOME}/argv_lens"
cat
EOF
chmod +x "$FLEET_HOME/stubbin/cursor-agent"
python3 -c "import sys; sys.stdout.write('x'*200000 + '\n')" > "$FLEET_HOME/big.md"
PATH="$FLEET_HOME/stubbin:$PATH" \
  bash "$ROOT/adapters/cursor.sh" 8 "$FLEET_HOME/big.md" "$FLEET_HOME" \
  "$FLEET_HOME/big.out" "$FLEET_HOME/big.log"
rc8=$?
maxarg=$(sort -rn "$FLEET_HOME/argv_lens" 2>/dev/null | head -1); maxarg=${maxarg:-0}
outsize=$(wc -c < "$FLEET_HOME/big.out" | tr -d ' ')
if [ "$rc8" = "0" ] && [ "$outsize" = "200001" ] && [ "$maxarg" -lt 10000 ]; then
  ok "B2: 200KiB prompt via stdin, argv small, output intact (rc=$rc8)"
else
  no "B2: big prompt via stdin (rc=$rc8 out=$outsize maxarg=$maxarg)"
fi

# 9. B5: a --review-of model must be verifiable -- on the channel's models
#    list or backed by a successful probe. Unlisted+unprobed is refused with
#    exit 10; ordinary tasks on the same channel stay lenient; a successful
#    probe or family=none (shell) lets the review through.
# A reviewer needs a different family from the target AND no models list, so
# the probe rule is what decides. No production channel is both since codex was
# removed, so the case builds its own rather than borrowing one -- a test that
# depends on the shipped registry breaks whenever the registry changes.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["b5rev"] = {"adapter": "shell.sh", "model": "GPT-5.5"}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF
T9=$(fleet add "p12 b5 target" --channel cursor)
fleet add "p12 b5 rev" --channel b5rev --model GPT-5.5 --review-of "$T9" \
  >/dev/null 2>"$FLEET_HOME/b5.err"
rc9=$?
X9=$(fleet add "p12 b5 plain" --channel b5rev --model GPT-5.5 \
     --spec "$FLEET_HOME/spec_echo.sh" 2>/dev/null)
rc9b=$?
python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO model_probe(channel,model,ok,checked_at,note) "
          "VALUES('b5rev','GPT-5.5',1,?,'probe ok')", (int(time.time()),))
c.commit()
EOF
R9=$(fleet add "p12 b5 rev2" --channel b5rev --model GPT-5.5 --review-of "$T9" 2>/dev/null)
rc9c=$?
S9=$(fleet add "p12 b5 rev3" --channel shell --review-of "$T9" \
     --spec "$FLEET_HOME/spec_echo.sh" 2>/dev/null)
rc9d=$?
for x in "$T9" "$X9" "$R9" "$S9"; do
  [ -n "$x" ] && fleet cancel "$x" >/dev/null 2>&1 || true
done
if [ "$rc9" = "10" ] && grep -q "neither listed" "$FLEET_HOME/b5.err" \
   && [ "$rc9b" = "0" ] && [ -n "$X9" ] \
   && [ "$rc9c" = "0" ] && [ -n "$R9" ] \
   && [ "$rc9d" = "0" ] && [ -n "$S9" ]; then
  ok "B5: unverified review-of model refused (exit 10); probe/list/shell pass"
else
  no "B5: review-of verification (rc=$rc9/$rc9b/$rc9c/$rc9d R9=$R9 S9=$S9)"
fi

# 10. B4: an unknown-channel task logs task.blocked(reason=unknown channel)
#     instead of printing to a stdout the daemon sends to fleetd.log.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["channels"]["ghost"] = {"adapter": "shell.sh", "family": "none"}
json.dump(d, open(p, "w"))
EOF
G10=$(fleet add "p12 b4 ghost" --channel ghost --spec "$FLEET_HOME/spec_echo.sh")
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
del d["channels"]["ghost"]
json.dump(d, open(p, "w"))
EOF
fleet run --ready >/dev/null 2>&1
M10=$(python3 - "$FLEET_HOME/fleet.db" "$G10" <<'EOF'
import sqlite3, sys, json
c = sqlite3.connect(sys.argv[1])
r = c.execute("SELECT payload FROM event WHERE task_id=? AND kind='task.blocked' "
              "ORDER BY id DESC LIMIT 1", (sys.argv[2],)).fetchone()
ok = bool(r) and json.loads(r[0]).get("reason") == "unknown channel"
print("ok" if ok else "no")
EOF
)
if [ "$M10" = "ok" ] && [ "$(field "$G10" status)" = "queued" ]; then
  ok "B4: unknown channel logs task.blocked(unknown channel), task stays queued"
else
  no "B4: unknown channel event (M10=$M10 status=$(field "$G10" status))"
fi

# 11. B3: --max-lines truncation does not advance the watermark past the
#     cut lines. Two consecutive truncated runs must show the same first
#     line; a full --all run then advances, and the next run shows nothing.
for i in 1 2 3 4; do fleet add "p12 b3 t$i" --channel shell >/dev/null; done
r11a=$(FLEET_CONSUMER=p12b3 fleet since --max-lines 2)
r11b=$(FLEET_CONSUMER=p12b3 fleet since --max-lines 2)
first11=$(printf '%s\n' "$r11a" | grep -v '^watermark=' | head -1)
FLEET_CONSUMER=p12b3 fleet since --all >/dev/null
r11d=$(FLEET_CONSUMER=p12b3 fleet since)
if printf '%s\n' "$r11a" | grep -q "另有" \
   && [ -n "$first11" ] \
   && printf '%s\n' "$r11b" | grep -qF -- "$first11" \
   && ! printf '%s\n' "$r11d" | grep -v '^watermark=' | grep -q .; then
  ok "B3: truncated since keeps the watermark; --all advances it"
else
  no "B3: since watermark on truncation (first='$first11' tail='$(printf '%s\n' "$r11d" | grep -v '^watermark=' | head -1)')"
fi

# 12. P12b A: re-archiving with a reused id keeps both batches. The live
#     table is emptied by the first archive, so the next task reuses id 1;
#     pre-fix INSERT OR REPLACE silently replaced batch 1's row. Runs in its
#     own FLEET_HOME so the id space is fully under the test's control.
MAIN_HOME="$FLEET_HOME"
SPEC_ECHO="$MAIN_HOME/spec_echo.sh"
A12_HOME="$(mktemp -d /var/tmp/fleet-p12-a12-XXXX)"
export FLEET_HOME="$A12_HOME"
fleet init >/dev/null
T12=$(fleet add "p12b a first" --channel shell --spec "$SPEC_ECHO")
fleet run "$T12" >/dev/null
wait_status "$T12" done
age_task "$T12"
a12_out=$(fleet archive --before "$(date +%F)")
python3 - "$A12_HOME/fleet.db" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA foreign_keys=OFF")
for t in ("attempt", "review", "claim", "artifact", "decision", "event", "task"):
    c.execute(f"DELETE FROM {t}")
c.commit()
EOF
T12b=$(fleet add "p12b a second" --channel shell --spec "$SPEC_ECHO")
fleet run "$T12b" >/dev/null
wait_status "$T12b" done
age_task "$T12b"
a12_out2=$(fleet archive --before "$(date +%F)")
M12=$(python3 - "$A12_HOME/fleet.db" "$A12_HOME/fleet-archive.db" <<'EOF'
import sqlite3, sys
h, a = sqlite3.connect(sys.argv[1]), sqlite3.connect(sys.argv[2])
rows = a.execute(
    "SELECT archived_seq, title FROM task WHERE id=1 ORDER BY archived_seq"
).fetchall()
live = h.execute("SELECT COUNT(*) FROM task").fetchone()[0]
ok = (live == 0 and len(rows) == 2
      and [r[0] for r in rows] == [1, 2]
      and rows[0][1] != rows[1][1])
print("ok" if ok else f"no rows={rows} live={live}")
EOF
)
export FLEET_HOME="$MAIN_HOME"
rm -rf "$A12_HOME"
if printf '%s\n' "$a12_out" | grep -q "archived 1" \
   && printf '%s\n' "$a12_out2" | grep -q "archived 1" \
   && [ "$M12" = "ok" ]; then
  ok "A: re-archive with reused id keeps both batches (no silent overwrite)"
else
  no "A: duplicate archive (out1='$a12_out' out2='$a12_out2' M12=$M12)"
fi

# 13. P12b B: a queued task naming the candidate in its deps is inserted
#     while the archive is between copy and delete (FLEET_ARCHIVE_WAIT_FOR
#     parks the batch there deterministically). The closure is recomputed
#     inside the delete transaction, so the batch rolls back cleanly: the
#     candidate stays live, nothing is half-archived, the dep task is
#     untouched. Pre-fix the FK-off second connection deleted the candidate
#     and the dep task stayed blocked forever.
T13=$(fleet add "p12b b old" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T13" >/dev/null
wait_status "$T13" done
age_task "$T13"
rm -f "$FLEET_HOME/gate13"
FLEET_ARCHIVE_WAIT_FOR="$FLEET_HOME/gate13" \
  fleet archive --before "$(date +%F)" >"$FLEET_HOME/arch13.out" 2>&1 &
APID13=$!
st13_pre=""
for i in $(seq 1 50); do
  s=$(fleet archive --status 2>/dev/null)
  if printf '%s\n' "$s" | grep -q "phase verify"; then st13_pre="$s"; break; fi
  sleep 0.2
done
C13=$(fleet add "p12b b dep" --channel shell --dep "$T13" \
      --spec "$FLEET_HOME/spec_echo.sh")
touch "$FLEET_HOME/gate13"
wait $APID13; rc13=$?
M13=$(python3 - "$FLEET_HOME/fleet.db" "$FLEET_HOME/fleet-archive.db" "$T13" <<'EOF'
import sqlite3, sys
h, a, t = sqlite3.connect(sys.argv[1]), sqlite3.connect(sys.argv[2]), sys.argv[3]
live = h.execute("SELECT COUNT(*) FROM task WHERE id=?", (t,)).fetchone()[0]
arch = a.execute("SELECT COUNT(*) FROM task WHERE id=?", (t,)).fetchone()[0]
print("ok" if live == 1 and arch == 0 else f"no live={live} arch={arch}")
EOF
)
st13=$(fleet archive --status)
if [ -n "$st13_pre" ] && [ "$rc13" = "13" ] && [ "$M13" = "ok" ] \
   && [ "$(field "$C13" status)" = "queued" ] \
   && printf '%s\n' "$st13" | grep -q "no archive in progress"; then
  ok "B: concurrent deps referrer rolls the batch back, no dangling reference"
else
  no "B: concurrent insert (pre='$st13_pre' rc=$rc13 M13=$M13 st='$st13')"
fi

# 14. P12b C: a SIGKILL between copy and delete is a crash; the next run
#     recovers the batch (re-copy, re-verify, delete) instead of starting a
#     new one -- the rows end up archived exactly once, live db clean,
#     receipt cleared. --status shows the unfinished batch before recovery.
T14=$(fleet add "p12b c old" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$T14" >/dev/null
wait_status "$T14" done
age_task "$T14"
rm -f "$FLEET_HOME/gate14"
FLEET_ARCHIVE_WAIT_FOR="$FLEET_HOME/gate14" \
  fleet archive --before "$(date +%F)" >"$FLEET_HOME/arch14.out" 2>&1 &
APID14=$!
st14_pre=""
for i in $(seq 1 50); do
  s=$(fleet archive --status 2>/dev/null)
  if printf '%s\n' "$s" | grep -q "phase verify"; then st14_pre="$s"; break; fi
  sleep 0.2
done
kill -9 "$APID14" 2>/dev/null
wait "$APID14" 2>/dev/null
rec14=$(fleet archive --before "$(date +%F)" 2>&1); rc14=$?
st14=$(fleet archive --status)
M14=$(python3 - "$FLEET_HOME/fleet.db" "$FLEET_HOME/fleet-archive.db" "$T14" <<'EOF'
import sqlite3, sys
h, a, t = sqlite3.connect(sys.argv[1]), sqlite3.connect(sys.argv[2]), sys.argv[3]
live = h.execute("SELECT COUNT(*) FROM task WHERE id=?", (t,)).fetchone()[0]
seqs = [r[0] for r in a.execute(
    "SELECT archived_seq FROM task WHERE id=?", (t,)).fetchall()]
print("ok" if live == 0 and len(seqs) == 1 else f"no live={live} seqs={seqs}")
EOF
)
if [ -n "$st14_pre" ] && [ "$rc14" = "0" ] \
   && printf '%s\n' "$rec14" | grep -q "recovering unfinished batch" \
   && printf '%s\n' "$rec14" | grep -q "recovered" \
   && [ "$M14" = "ok" ] \
   && printf '%s\n' "$st14" | grep -q "no archive in progress"; then
  ok "C: crashed batch recovered; rows neither duplicated nor lost"
else
  no "C: crash recovery (pre='$st14_pre' rc=$rc14 rec='$rec14' M14=$M14 st='$st14')"
fi

# 15. P12b D: cursor HAS a models list; GPT-5.5 is not on it. A --review-of
#     model is refused without a probe (exit 10), accepted with a successful
#     probe, refused again after a failed probe (exit 6); an ordinary task
#     keeps the strict list-only gate (exit 5). Pre-fix the strict list
#     check fired before the review path, so the probe-success branch was
#     unreachable.
TD=$(fleet add "p12b d target" --channel shell --spec "$FLEET_HOME/spec_echo.sh")
fleet add "p12b d rev" --channel cursor --model GPT-5.5 --review-of "$TD" \
  >"$FLEET_HOME/d15a.out" 2>&1; rc15a=$?
python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO model_probe(channel,model,ok,checked_at,note) "
          "VALUES('cursor','GPT-5.5',1,?,'probe ok')", (int(time.time()),))
c.commit()
EOF
RD=$(fleet add "p12b d rev2" --channel cursor --model GPT-5.5 --review-of "$TD" \
     2>/dev/null); rc15b=$?
python3 - "$FLEET_HOME/fleet.db" <<'EOF'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("UPDATE model_probe SET ok=0 WHERE channel='cursor' AND model='GPT-5.5'")
c.commit()
EOF
fleet add "p12b d rev3" --channel cursor --model GPT-5.5 --review-of "$TD" \
  >/dev/null 2>&1; rc15c=$?
fleet add "p12b d plain" --channel cursor --model GPT-5.5 \
  --spec "$FLEET_HOME/spec_echo.sh" >/dev/null 2>&1; rc15d=$?
for x in "$TD" "$RD"; do [ -n "$x" ] && fleet cancel "$x" >/dev/null 2>&1 || true; done
if [ "$rc15a" = "10" ] && grep -q "neither listed" "$FLEET_HOME/d15a.out" \
   && [ "$rc15b" = "0" ] && [ -n "$RD" ] \
   && [ "$rc15c" = "6" ] && [ "$rc15d" = "5" ]; then
  ok "D: unlisted review model accepted on probe, refused without/after; plain stays strict"
else
  no "D: probe reviewer (rc=$rc15a/$rc15b/$rc15c/$rc15d RD=$RD)"
fi

echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
