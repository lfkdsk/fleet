#!/usr/bin/env bash
# P20: the user's channel into a commander round -- messages reach the prompt,
# wake the next round, and `fleet ask` answers synchronously.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
PASS=0 FAIL=0 N=0
SCRATCH=()
cleanup(){ for p in "${SCRATCH[@]}"; do rm -rf "$p"; done; }
trap cleanup EXIT
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
new_home(){ FLEET_HOME="$(mktemp -d /var/tmp/fleet-p20-test-XXXXXX)"; SCRATCH+=("$FLEET_HOME"); export FLEET_HOME; fleet init >/dev/null; }
sql(){ sqlite3 -cmd '.timeout 10000' "$FLEET_HOME/fleet.db" "$1"; }
wait_terminal(){ local id="$1" i s; for i in $(seq 1 200); do s=$(sql "SELECT status FROM task WHERE id=$id"); case "$s" in done|failed|cancelled) return 0;; esac; sleep .05; done; return 1; }
poll(){ fleet daemon run --once >/dev/null; }
install_driver(){ local mode="$1" path="$FLEET_HOME/p20-driver.sh"; sed "s/__P20_MODE__/$mode/" "$ROOT/tests/p20_driver.sh" >"$path"; chmod +x "$path"; export FLEET_COMMANDER_SHELL_SCRIPT="$path"; }
# Park autonomy at review_ready with the watermark caught up, so the ONLY thing
# that can wake the next round is what the test adds afterwards.
settle(){ local g="$1" t; poll; t=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$g AND role='commander'"); wait_terminal "$t"; poll; echo "$t"; }

# 1. A user message wakes a round, reaches its prompt verbatim, and is marked
# read by the apply -- the whole asynchronous path in one case.
new_home; install_driver plain
G1=$(fleet goal add "1: message wakes a round")
fleet autonomy enable "$G1" --channel shell --cooldown 0 >/dev/null
t1a=$(settle "$G1")
before=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G1 AND role='commander'")
reason=$(sql "SELECT json_extract(autonomy,'\$.last_reason') FROM goal WHERE id=$G1")
idle=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G1 AND role='commander'")
poll   # no new information: still one round
m1=$(fleet msg send --from user --to commander --topic "goal-$G1" "先把 parser 的边界补齐，别动 CLI")
poll
t1b=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$G1 AND role='commander'")
wait_terminal "$t1b"
p1="$FLEET_HOME/runs/$t1b/prompt.md"
read1=$(sql "SELECT read_at IS NOT NULL FROM message WHERE id=$m1")
# The msg.send event must be tied to the goal, not just present in the mailbox:
# that is what puts the arrival in the goal's own event stream (and its
# watermark), so the round can see WHEN the instruction landed relative to
# everything else it is reading.
folded1=$(python3 - "$p1" <<'PY'
import json,re,sys
s=open(sys.argv[1]).read()
dec=json.JSONDecoder(); best=None
for m in re.finditer(r'\{',s):
    try: v,end=dec.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(v,dict) and 'since' in v and (best is None or end>best[0]):
        best=(end,v)
print(sum(1 for line in best[1]['since']['folded'] if 'msg.send' in line))
PY
)
if [ "$before" = 1 ] && [ "$idle" = 1 ] && [ "$reason" = review_ready ] \
   && [ "$t1b" != "$t1a" ] \
   && grep -q '先把 parser 的边界补齐，别动 CLI' "$p1" \
   && [ "$folded1" -ge 1 ] \
   && [ "$read1" = 1 ]; then
  ok "1: a user message wakes the next round, reaches its prompt, and is marked read"
else
  no "1: message-driven wake (before=$before idle=$idle reason=$reason rounds=$t1a/$t1b folded=$folded1 read=$read1)"
fi

# 2. Order and survival under pressure: the message sits after needs_user and
# before the task table, and neither a 60 KiB artifact summary nor 200 noise
# events nor a folded increment far past the cap can push it out of a prompt
# that still fits 48 KiB. The bulk has to exceed the cap even after every
# summary is clipped -- otherwise only the clip stage runs and the ORDER in
# which whole fields give up room is never exercised.
new_home; install_driver plain
G2=$(fleet goal add "2: ordering under truncation")
w2=$(fleet add "noise" --channel shell --goal "$G2" --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
python3 - "$FLEET_HOME/fleet.db" "$w2" "$G2" <<'PY'
import sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); tid=int(sys.argv[2]); gid=int(sys.argv[3])
ts=int(time.time())
c.execute("insert into artifact(task_id,path,summary,ts) values(?,?,?,?)",
          (tid,'/tmp/huge','Z'*60000,ts))
for _ in range(200):
    c.execute("insert into event(ts,task_id,kind,payload) values(?,?,?,?)",
              (ts,tid,'task.blocked','{"reason":"dep"}'))
# Goal-level events fold to one line each and are never clipped by field, so
# 400 of them at 300 bytes is ~120 KiB of increment: past this point something
# whole has to be dropped, and the test is about WHAT.
for i in range(400):
    c.execute("insert into event(ts,goal_id,kind,payload) values(?,?,?,?)",
              (ts,gid,'note.add','{"n":%d,"pad":"%s"}' % (i,'Q'*300)))
c.commit()
PY
d2=$(fleet decide "谁来拍板发布口径" --goal "$G2" --needs-user)
fleet msg send --from user --to commander --topic "goal-$G2" \
  "留言正文 UNIQUE-MARKER-2 必须完整活下来" >/dev/null
t2=$(fleet add --role commander --goal "$G2" --channel shell)
p2="$FLEET_HOME/runs/$t2/prompt.md"
size2=$(wc -c <"$p2")
v2=$(python3 - "$p2" <<'PY'
import json,re,sys
s=open(sys.argv[1]).read()
dec=json.JSONDecoder(); p=None
for m in re.finditer(r'\{',s):
    try: value,end=dec.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(value,dict) and 'protocol_version' in value: p=value
i_needs=s.index('"unresolved_needs_user"')
i_msgs=s.index('"user_messages"')
i_tasks=s.index('"tasks"')
assert i_needs < i_msgs < i_tasks, (i_needs,i_msgs,i_tasks)
assert '留言正文 UNIQUE-MARKER-2 必须完整活下来' in s
assert '谁来拍板发布口径' in s          # the human gate survives too
assert 'Z'*60000 not in s              # the bulk is what gave up room
assert p['truncation']['omitted'], 'nothing was shed: the case is not applying pressure'
print('ok')
PY
)
if [ "$v2" = ok ] && [ "$size2" -le 49152 ]; then
  ok "2: the message sits between needs_user and tasks and survives the 48 KiB cap"
else
  no "2: ordering/survival under truncation (v=$v2 size=$size2)"
fi

# 3. Eleven messages: ten in the prompt with a pointer for the rest, and the
# eleventh arrives in the round after (it was never marked read).
new_home; install_driver plain
G3=$(fleet goal add "3: ten per round plus a pointer")
fleet autonomy enable "$G3" --channel shell --cooldown 0 >/dev/null
for i in $(seq 1 11); do
  fleet msg send --from user --to commander --topic "goal-$G3" "留言编号 M$i" >/dev/null
done
poll; t3a=$(sql "SELECT MAX(id) FROM task WHERE role='commander'"); wait_terminal "$t3a"
p3a="$FLEET_HOME/runs/$t3a/prompt.md"
shown=$(python3 - "$p3a" <<'PY'
import json,re,sys
s=open(sys.argv[1]).read()
dec=json.JSONDecoder(); best=None
for m in re.finditer(r'\{',s):
    try: v,end=dec.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(v,dict) and 'user_messages' in v and (best is None or end>best[0]):
        best=(end,v)
p=best[1]
print(len(p['user_messages']), 'ptr' if p['user_messages_note'] else 'noptr',
      'M11' if any('M11' in m['body'] for m in p['user_messages']) else 'no-M11')
PY
)
poll; t3b=$(sql "SELECT MAX(id) FROM task WHERE role='commander'"); wait_terminal "$t3b"
next3=$(grep -c '留言编号 M11' "$FLEET_HOME/runs/$t3b/prompt.md")
if [ "$shown" = "10 ptr no-M11" ] && [ "$t3b" != "$t3a" ] && [ "$next3" -ge 1 ]; then
  ok "3: ten messages per round plus a pointer; the surplus arrives next round"
else
  no "3: per-round message cap (shown='$shown' rounds=$t3a/$t3b next=$next3)"
fi

# 4. Worker mail and user mail are different sections and do not leak into
# each other, even with the same topic on both.
new_home; install_driver plain
G4=$(fleet goal add "4: worker mail vs user mail")
w4=$(fleet add "worker" --channel shell --goal "$G4" --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
fleet msg send --from "task-$w4" --to commander --topic "goal-$G4" "WORKER-SAYS-4" >/dev/null
fleet msg send --from user --to commander --topic "goal-$G4" "USER-SAYS-4" >/dev/null
t4=$(fleet add --role commander --goal "$G4" --channel shell)
v4=$(python3 - "$FLEET_HOME/runs/$t4/prompt.md" <<'PY'
import json,re,sys
s=open(sys.argv[1]).read()
dec=json.JSONDecoder(); best=None
for m in re.finditer(r'\{',s):
    try: v,end=dec.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(v,dict) and 'user_messages' in v and (best is None or end>best[0]):
        best=(end,v)
p=best[1]
users=json.dumps(p['user_messages'],ensure_ascii=False)
mail=json.dumps(p['commander_mail_and_spawn_proposals'],ensure_ascii=False)
assert 'USER-SAYS-4' in users and 'WORKER-SAYS-4' not in users, users
assert 'WORKER-SAYS-4' in mail and 'USER-SAYS-4' not in mail, mail
print('ok')
PY
)
[ "$v4" = ok ] && ok "4: worker mail and user messages stay in separate sections" \
  || no "4: mail separation ($v4)"

# 5. `fleet ask` answers synchronously; --no-apply records candidates without
# creating tasks and says so in the round.
new_home; install_driver propose
G5=$(fleet goal add "5: ask returns a reply")
fleet autonomy enable "$G5" --channel shell --cooldown 0 >/dev/null
a5=$(fleet ask "$G5" "你打算先做什么" --timeout 60)
t5=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$G5 AND role='commander'")
r5=$(sql "SELECT json_extract(payload,'\$.reply') FROM event WHERE kind='commander.round' AND task_id=$t5")
new_home; install_driver noapply
G5b=$(fleet goal add "5b: ask --no-apply")
a5b=$(fleet ask "$G5b" "只问不做" --channel shell --no-apply --timeout 60); rc5b=$?
w5b=$(sql "SELECT COUNT(*) FROM task WHERE role='worker'")
ap5b=$(sql "SELECT json_extract(payload,'\$.applied') FROM event WHERE kind='commander.round'")
pr5b=$(sql "SELECT json_array_length(json_extract(payload,'\$.proposed')) FROM event WHERE kind='commander.round'")
if printf '%s' "$a5" | grep -q '你打算先做什么' \
   && printf '%s' "$r5" | grep -q '你打算先做什么' \
   && [ "$rc5b" = 0 ] && [ "$w5b" = 0 ] && [ "$ap5b" = 0 ] && [ "$pr5b" = 1 ]; then
  ok "5: ask prints the round's reply; --no-apply records candidates only"
else
  no "5: ask reply / --no-apply (reply='$r5' workers=$w5b applied=$ap5b proposed=$pr5b)"
fi

# 6. With a round already in flight, ask refuses to start a second one, exits
# 0, and still banks the message.
new_home; install_driver propose
G6=$(fleet goal add "6: no second round")
t6=$(fleet add --role commander --goal "$G6" --channel shell)
out6=$(fleet ask "$G6" "并发时的留言" --channel shell --timeout 30); rc6=$?
n6=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G6 AND role='commander'")
m6=$(sql "SELECT COUNT(*) FROM message WHERE topic='goal-$G6' AND read_at IS NULL")
if [ "$rc6" = 0 ] && [ "$n6" = 1 ] && [ "$m6" = 1 ] \
   && printf '%s' "$out6" | grep -q '轮在跑'; then
  ok "6: ask banks the message and starts no second round while one is live"
else
  no "6: concurrent ask (rc=$rc6 commanders=$n6 unread=$m6 out='$out6')"
fi

# 7. A round rejected as stale must not consume the message: the words are
# instructions, and a rejected round never acted on them.
new_home; install_driver plain
G7=$(fleet goal add "7: stale round keeps the message")
m7=$(fleet msg send --from user --to commander --topic "goal-$G7" "STALE-KEEP-7")
t7=$(fleet add --role commander --goal "$G7" --channel shell)
printf '[]\n' >"$FLEET_HOME/rules"
fleet plan set "$G7" --rules "$FLEET_HOME/rules" --rationale newer >/dev/null
fleet run "$t7" >/dev/null; wait_terminal "$t7"
read7=$(sql "SELECT read_at IS NULL FROM message WHERE id=$m7")
t7b=$(fleet add --role commander --goal "$G7" --channel shell)
again7=$(grep -c 'STALE-KEEP-7' "$FLEET_HOME/runs/$t7b/prompt.md")
stale7=$(sql "SELECT COUNT(*) FROM event WHERE kind='commander.rejected' AND json_extract(payload,'\$.reason')='stale'")
if [ "$stale7" = 1 ] && [ "$read7" = 1 ] && [ "$again7" -ge 1 ]; then
  ok "7: a stale-rejected round leaves the message unread for the next one"
else
  no "7: stale keeps the message (stale=$stale7 unread=$read7 again=$again7)"
fi

# 8. brief shows the latest reply, clipped, under its goal.
new_home; install_driver plain
G8=$(fleet goal add "8: brief shows the reply")
fleet msg send --from user --to commander --topic "goal-$G8" "BRIEF-REPLY-8" >/dev/null
t8=$(fleet add --role commander --goal "$G8" --channel shell)
fleet run "$t8" >/dev/null; wait_terminal "$t8"
b8=$(fleet brief)
if printf '%s' "$b8" | grep -q 'reply:' && printf '%s' "$b8" | grep -q 'BRIEF-REPLY-8'; then
  ok "8: brief surfaces the commander's latest reply"
else
  no "8: brief reply line"
fi

# 9. `--goal` and the topic are one fact with two spellings. A disagreement
# used to give the worst of both: the event woke a round (it carried goal_id)
# whose prompt did not contain the message (the topic did not match), so the
# words were never delivered and never marked read. It is refused instead.
new_home; install_driver plain
G9=$(fleet goal add "9: goal and topic agree or refuse")
conflict=$(fleet msg send --from user --to commander --goal "$G9" --topic urgent "x" 2>&1); rc_c=$?
fleet msg send --from user --to commander --goal "$G9" --topic "goal-$G9" "AGREE-9" >/dev/null; rc_a=$?
fleet msg send --from user --to commander --goal "$G9" "GOALFLAG-9" >/dev/null; rc_g=$?
missing=$(fleet msg send --from user --to commander --goal 99999 "x" 2>&1); rc_m=$?
fleet msg send --from a --to b "no goal at all" >/dev/null; rc_p=$?
topics9=$(sql "SELECT group_concat(COALESCE(topic,'<null>'),'|') FROM message ORDER BY id")
t9=$(fleet add --role commander --goal "$G9" --channel shell)
both9=$(grep -c 'AGREE-9\|GOALFLAG-9' "$FLEET_HOME/runs/$t9/prompt.md")
if [ "$rc_c" != 0 ] && printf '%s' "$conflict" | grep -q 'conflicts with --topic' \
   && [ "$rc_a" = 0 ] && [ "$rc_g" = 0 ] && [ "$rc_p" = 0 ] \
   && [ "$rc_m" != 0 ] && printf '%s' "$missing" | grep -q 'goal 99999 not found' \
   && [ "$topics9" = "goal-$G9|goal-$G9|<null>" ] && [ "$both9" -ge 2 ]; then
  ok "9: --goal fills the topic, disagreement is refused, plain mail is untouched"
else
  no "9: goal/topic agreement (rc=$rc_c/$rc_a/$rc_g/$rc_m/$rc_p topics=$topics9 in_prompt=$both9)"
fi

# 10. An explicit ask past --max-rounds still runs (you asked; `add --role
# commander` has always been allowed to), but it consumes the round like any
# other and says on stderr that autonomy will now report exhausted. Silence
# here would let a user spend the goal's last round without knowing.
new_home; install_driver plain
G10=$(fleet goal add "10: ask past the round cap")
fleet autonomy enable "$G10" --channel shell --max-rounds 1 --cooldown 0 >/dev/null
fleet ask "$G10" "第一轮" --timeout 60 >/dev/null 2>&1
warn10=$(fleet ask "$G10" "第二轮" --timeout 60 2>&1 >/dev/null); rc10=$?
used10=$(sql "SELECT json_extract(autonomy,'\$.rounds_used') FROM goal WHERE id=$G10")
n10=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G10 AND role='commander'")
poll   # autonomy itself must now refuse, not quietly start a third
after10=$(sql "SELECT json_extract(autonomy,'\$.last_reason') FROM goal WHERE id=$G10")
n10b=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G10 AND role='commander'")
if [ "$rc10" = 0 ] && [ "$used10" = 2 ] && [ "$n10" = 2 ] && [ "$n10b" = 2 ] \
   && [ "$after10" = "rounds exhausted" ] \
   && printf '%s' "$warn10" | grep -q 'rounds exhausted'; then
  ok "10: an explicit ask past the cap runs, consumes a round, and warns"
else
  no "10: ask past --max-rounds (rc=$rc10 used=$used10 n=$n10/$n10b after=$after10 warn='$warn10')"
fi

# 11. The tightest ladder rung keeps ten 1000-character messages and the
# unresolved-needs-user protocol envelope as valid JSON under 48 KiB.
new_home
G11=$(fleet goal add "11: tight rung keeps bounded user input")
d11=$(fleet decide "TIGHT-NEEDS-USER-11" --goal "$G11" --needs-user)
for i in $(seq 1 10); do
  body=$(python3 - "$i" <<'PY'
import sys
prefix='M'+sys.argv[1]+'-'
print(prefix + '界'*(1000-len(prefix)))
PY
)
  fleet msg send --from user --to commander --goal "$G11" "$body" >/dev/null
done
v11=$(python3 - "$ROOT/bin/fleet" "$FLEET_HOME" "$G11" <<'PY'
import importlib.machinery,importlib.util,json,os,sys
os.environ['FLEET_HOME']=sys.argv[2]
loader=importlib.machinery.SourceFileLoader('fleet_mod',sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec); loader.exec_module(m)
m.COMMANDER_PROMPT_LADDER=((0,0),)
c=m.db_connect(); goal=c.execute('select * from goal where id=?',(int(sys.argv[3]),)).fetchone()
cwd,body,rev,through,mids=m.commander_construction(
    c,goal,cwd=os.getcwd(),return_message_ids=True)
p=json.loads(body)
assert len(body.encode()) <= m.COMMANDER_PROMPT_CAP
assert len(p['user_messages']) == 10
assert all(len(x['body']) == 1000 for x in p['user_messages'])
assert p['unresolved_needs_user']['present']
assert p['unresolved_needs_user']['ids']
assert 'reply' in p['response_example']
print('ok',len(body.encode()))
PY
)
case "$v11" in ok\ *) ok "11: tightest rung keeps 10 bounded messages and needs_user as valid JSON ($v11 bytes)";;
*) no "11: tightest rung user input ($v11)";; esac

# 12. Two asks racing from an empty goal atomically create exactly one round.
new_home; install_driver slow
G12=$(fleet goal add "12: concurrent asks are atomic")
(fleet ask "$G12" "PARALLEL-A-12" --channel shell --timeout 60 >"$FLEET_HOME/a.out" 2>"$FLEET_HOME/a.err"; echo $? >"$FLEET_HOME/a.rc") &
p12a=$!
(fleet ask "$G12" "PARALLEL-B-12" --channel shell --timeout 60 >"$FLEET_HOME/b.out" 2>"$FLEET_HOME/b.err"; echo $? >"$FLEET_HOME/b.rc") &
p12b=$!
wait "$p12a" "$p12b"
n12=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G12 AND role='commander'")
live12=$(grep -h -c '轮在跑' "$FLEET_HOME/a.out" "$FLEET_HOME/b.out" | awk '{s+=$1} END{print s+0}')
if [ "$n12" = 1 ] && [ "$live12" = 1 ] && [ "$(cat "$FLEET_HOME/a.rc")" = 0 ] && [ "$(cat "$FLEET_HOME/b.rc")" = 0 ]; then
  ok "12: parallel asks create exactly one commander round"
else
  no "12: parallel asks (commanders=$n12 live_notice=$live12)"
fi

# 13. The question written by this ask is pinned into its own round even when
# ten older unread messages already fill the normal window.
new_home; install_driver plain
G13=$(fleet goal add "13: ask message is in this round")
for i in $(seq 1 10); do fleet msg send --from user --to commander --goal "$G13" "OLD-$i" >/dev/null; done
a13=$(fleet ask "$G13" "CURRENT-QUESTION-13" --channel shell --timeout 60)
t13=$(sql "SELECT MAX(id) FROM task WHERE goal_id=$G13 AND role='commander'")
if printf '%s' "$a13" | grep -q 'CURRENT-QUESTION-13' \
   && grep -q 'CURRENT-QUESTION-13' "$FLEET_HOME/runs/$t13/prompt.md"; then
  ok "13: ask pins its own message into a full mailbox window and replies to it"
else
  no "13: ask message priority (reply='$a13')"
fi

# 14. User-message classification excludes every exact task-N sender, orders
# by ts (not insertion id), and hard-clips without folding whitespace.
new_home; install_driver plain
G14=$(fleet goal add "14: message filtering sorting and clipping")
python3 - "$FLEET_HOME/fleet.db" "$G14" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2]); topic=f'goal-{g}'
rows=[(30,'task-999','DROP-FOREIGN'),(20,'user','SECOND'),
      (10,'user','A  B\nC'+'x'*1200),(25,'task-x','KEEP-TASK-X')]
for ts,sender,body in rows:
    c.execute('insert into message(ts,from_agent,to_agent,topic,body) values(?,?,?,?,?)',
              (ts,sender,'commander',topic,body))
c.commit()
PY
t14=$(fleet add --role commander --goal "$G14" --channel shell)
v14=$(python3 - "$FLEET_HOME/runs/$t14/prompt.md" <<'PY'
import json,re,sys
s=open(sys.argv[1]).read(); d=json.JSONDecoder(); found=None
for m in re.finditer(r'\{',s):
    try: v,end=d.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(v,dict) and 'user_messages' in v: found=v
msgs=found['user_messages']; assert [m['ts'] for m in msgs] == [10,20,25]
assert 'DROP-FOREIGN' not in json.dumps(msgs)
assert msgs[0]['body'].startswith('A  B\nC') and len(msgs[0]['body']) == 1000
assert msgs[0]['body_truncated'] is True and '[已截断]' not in msgs[0]['body']
print('ok')
PY
)
[ "$v14" = ok ] && ok "14: all task-N senders are excluded; ts order and hard body cap hold" \
  || no "14: message filtering/sorting/clipping ($v14)"

# 15. Goal budget exhaustion declines the round but commits the message.
new_home; install_driver plain
G15=$(fleet goal add "15: ask obeys goal budget" --budget 0)
o15=$(fleet ask "$G15" "BANKED-BUDGET-15" --channel shell --timeout 60); r15=$?
n15=$(sql "SELECT COUNT(*) FROM task WHERE goal_id=$G15 AND role='commander'")
m15=$(sql "SELECT COUNT(*) FROM message WHERE topic='goal-$G15' AND read_at IS NULL")
if [ "$r15" = 0 ] && [ "$n15" = 0 ] && [ "$m15" = 1 ] \
   && printf '%s' "$o15" | grep -q 'goal budget exhausted'; then
  ok "15: budget-exhausted ask banks its message and creates no round"
else
  no "15: ask goal budget gate (rc=$r15 commanders=$n15 unread=$m15 out='$o15')"
fi

# 16. --json reserves stdout for exactly one JSON document; progress is stderr.
new_home; install_driver plain
G16=$(fleet goal add "16: clean JSON stdout")
fleet ask "$G16" "JSON-QUESTION-16" --channel shell --json --timeout 60 \
  >"$FLEET_HOME/json.out" 2>"$FLEET_HOME/json.err"; r16=$?
v16=$(python3 - "$FLEET_HOME/json.out" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert p['reply']; print('ok')
PY
)
if [ "$r16" = 0 ] && [ "$v16" = ok ] && grep -q 'round task .* started' "$FLEET_HOME/json.err"; then
  ok "16: ask --json emits only JSON on stdout and status on stderr"
else
  no "16: ask JSON streams (rc=$r16 parse=$v16)"
fi

# 17. A p19-sized ledger plus the p20 user channel keeps every integrated
# protocol section in a real generated prompt under 48 KiB.
new_home; install_driver plain
repo17="$FLEET_HOME/repo"; mkdir -p "$repo17"; git -C "$repo17" init -q
git -C "$repo17" config user.email p20@example.invalid
git -C "$repo17" config user.name p20
printf 'base\n' >"$repo17/README"; git -C "$repo17" add README; git -C "$repo17" commit -qm base
G17=$(fleet goal add "17: integrated realistic prompt")
fleet autonomy enable "$G17" --channel shell --cwd "$repo17" --cooldown 0 >/dev/null
w17=$(fleet add "base candidate" --channel shell --goal "$G17" --cwd "$repo17" \
  --worktree --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
fleet run "$w17" >/dev/null; wait_terminal "$w17"
fleet decide "REAL-NEEDS-USER-17" --goal "$G17" --needs-user >/dev/null
for i in $(seq 1 10); do fleet msg send --from user --to commander --goal "$G17" "REAL-MESSAGE-$i-$(printf '%0900d' 0)" >/dev/null; done
python3 - "$FLEET_HOME/fleet.db" "$G17" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); g=int(sys.argv[2])
c.execute('update goal set statement=?,acceptance=? where id=?',('S'*60000,'A'*60000,g))
c.commit()
PY
t17=$(fleet add --role commander --goal "$G17" --channel shell)
p17="$FLEET_HOME/runs/$t17/prompt.md"
v17=$(python3 - "$p17" <<'PY'
import json,re,sys
s=open(sys.argv[1]).read(); d=json.JSONDecoder(); found=None
for m in re.finditer(r'\{',s):
    try: v,end=d.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(v,dict) and 'protocol_version' in v: found=v
assert found and len(s.encode()) <= 49152
assert len(found['user_messages']) == 10
assert found['execution_target']['kind'] == 'git'
assert found['base_candidates'] and found['base_candidates'][0]['base_task']
assert found['unresolved_needs_user']['present']
assert 'reply' in found['response_example'] and found['response_constraints']
print('ok',len(s.encode()))
PY
)
case "$v17" in ok\ *) ok "17: realistic integrated prompt retains user/execution/base/gate/schema ($v17 bytes)";;
*) no "17: realistic integrated prompt ($v17)";; esac

# 18. Metadata kept outside the prose ladder has its own hard cap.  In
# particular, the CLI accepts an arbitrary --from value and records it in both
# the message and msg.send event; neither copy may make the tightest prompt
# exceed 48 KiB.  A task message supplies the same adversarial check for topic.
new_home; install_driver plain
G18=$(fleet goal add "18: bounded message metadata")
sender18=$(python3 - <<'PY'
print('S'*60000)
PY
)
fleet msg send --from "$sender18" --to commander --goal "$G18" "BODY-18" >/dev/null
W18=$(fleet add "mail source" --channel shell --goal "$G18" \
  --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
python3 - "$FLEET_HOME/fleet.db" "$W18" "$G18" <<'PY'
import json,sqlite3,sys,time
c=sqlite3.connect(sys.argv[1]); source=int(sys.argv[2]); goal=int(sys.argv[3])
c.execute("insert into message(ts,from_agent,to_agent,topic,body) "
          "values(?,?,?,?,?)",
          (int(time.time()),f'task-{source}','commander','T'*60000,'MAIL-18'))
c.execute("update task set title=?,channel=?,role=?,status=? where id=?",
          ('X'*60000,'C'*60000,'R'*60000,'Z'*60000,source))
c.execute("update goal set autonomy=? where id=?",(json.dumps({
    'channel':'A'*60000,'model':'M'*60000,'last_next_wake':'W'*60000,
}),goal))
c.commit()
PY
T18=$(fleet add --role commander --goal "$G18" --channel shell \
  --spec "$FLEET_COMMANDER_SHELL_SCRIPT")
P18="$FLEET_HOME/runs/$T18/prompt.md"
v18=$(python3 - "$P18" <<'PY'
import json,re,sys
s=open(sys.argv[1]).read(); d=json.JSONDecoder(); found=None
for m in re.finditer(r'\{',s):
    try: v,end=d.raw_decode(s,m.start())
    except ValueError: continue
    if isinstance(v,dict) and 'protocol_version' in v: found=v
assert found and len(s.encode()) <= 49152
user=found['user_messages'][0]
mail=found['commander_mail_and_spawn_proposals'][0]
assert len(user['from']) <= 64 and user['from'].endswith('…[truncated]')
assert len(mail['topic']) <= 64 and mail['topic'].endswith('…[truncated]')
task=found['tasks'][0]
assert len(task['title']) <= 200
assert all(len(task[key]) <= 64 for key in ('channel','role','status'))
assert max(map(len,found['since']['folded'])) <= 1000
auto=found['goal']['autonomy']
assert all(len(auto[key]) <= 64 for key in ('channel','model','last_next_wake'))
assert found['user_messages_note']['truncated_senders']==1
fields={e['field'] for e in found['truncation']['fields']}
assert f"user_messages[{user['id']}].from" in fields
assert f"commander_mail_and_spawn_proposals[{mail['id']}].topic" in fields
print('ok',len(s.encode()))
PY
)
case "$v18" in ok\ *) ok "18: 60k sender/topic metadata is marked, capped at 64 chars, and prompt stays bounded ($v18 bytes)";;
*) no "18: bounded message metadata ($v18)";; esac

# 19. One real channel round, opt-in only. Spending someone's quota is not a CI
# pass condition (same rule as p19's CLI probe), so this runs on
# FLEET_P20_REAL_CHANNEL=<channel> and is otherwise silent.
if [ -n "${FLEET_P20_REAL_CHANNEL:-}" ]; then
  new_home
  G11=$(fleet goal add "11: real channel ask")
  out11=$(fleet ask "$G11" "你打算先做什么？只回答一句，不要建任务。" \
    --channel "$FLEET_P20_REAL_CHANNEL" --no-apply --timeout 600 2>&1)
  t11=$(sql "SELECT MAX(id) FROM task WHERE role='commander'")
  r11=$(sql "SELECT json_extract(payload,'\$.reply') FROM event WHERE kind='commander.round' AND task_id=$t11")
  # The prompt must have carried the words, and the reply must be the model's
  # own text rather than an echo of them.
  saw11=$(grep -c '你打算先做什么' "$FLEET_HOME/runs/$t11/prompt.md")
  if [ -n "$r11" ] && [ "$r11" != "null" ] && [ "$saw11" -ge 1 ]; then
  ok "19: a real $FLEET_P20_REAL_CHANNEL round answers through reply"
  else
    no "19: real channel ask (reply='$r11' saw=$saw11 out='$out11')"
  fi
fi

echo ---
echo "passed $PASS / $N"
[ "$FAIL" = 0 ]
