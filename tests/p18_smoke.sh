#!/usr/bin/env bash
# P18: task.blocked records state changes, not one row per poll.
#
# The daemon re-evaluates every queued task every round, and the old code
# wrote a task.blocked each time: the real ledger held 47,204 of them against
# under 3,000 of everything else, one dep contributing 11,818 by itself. That
# drowned `fleet since --raw` and pushed whole-goal event dumps past the
# 256 KiB a model will accept. These cases pin the contract that replaced it:
# one row per block EPISODE, a new row whenever the payload actually differs,
# and every existing reader (brief's reason, since's fold) still working off
# that single row.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
unset _FLEET_LOCK_FD
PASS=0 FAIL=0 N=0 HOMES=()
ok(){ N=$((N+1)); echo "ok $N - $1"; PASS=$((PASS+1)); }
no(){ N=$((N+1)); echo "not ok $N - $1"; FAIL=$((FAIL+1)); }
field(){ fleet show "$1" | awk -v f="$2" '$1==f":"{print $2}'; }
sql(){ sqlite3 "$FLEET_HOME/fleet.db" "$1"; }
# Blocked rows for one task, oldest first: "<payload>" per line.
blocked(){ sql "select payload from event where task_id=$1 and kind='task.blocked' order by id"; }
nblocked(){ sql "select count(*) from event where task_id=$1 and kind='task.blocked'"; }
cleanup(){
  local h id
  for h in "${HOMES[@]}"; do
    FLEET_HOME="$h" fleet daemon stop >/dev/null 2>&1 || true
    while read -r id; do FLEET_HOME="$h" fleet cancel "$id" >/dev/null 2>&1 || true; done \
      < <(sqlite3 "$h/fleet.db" "select id from task where status='running'" 2>/dev/null)
    rm -rf "$h"
  done
}
trap cleanup EXIT

fresh(){
  export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p18-test-XXXX)"
  HOMES+=("$FLEET_HOME")
  fleet init >/dev/null
  printf 'sleep 30\n' > "$FLEET_HOME/sleep.sh"
  printf 'exit 1\n' > "$FLEET_HOME/fail.sh"
}
# Tasks hang for the duration so a dep/lease holder stays put; --no-preamble
# keeps the shell channel's spec the whole prompt.
add(){ fleet add "$1" --channel shell --no-preamble --spec "$FLEET_HOME/sleep.sh" "${@:2}"; }
polls(){ local i; for i in $(seq "$1"); do fleet daemon run --once >/dev/null 2>&1; done; }

# 1. Ten poll rounds against an unchanged dep block write exactly one event.
# The old code wrote ten. `--once` is the same start_ready the resident
# daemon runs, so this is the real poll path and not a stand-in.
fresh
D1=$(add dep-holder)
T1=$(add dep-waiter --dep "$D1")
polls 10
n1=$(nblocked "$T1")
if [ "$n1" = 1 ] \
 && [ "$(blocked "$T1")" = "{\"reason\": \"dep\", \"dep\": $D1}" ] \
 && [ "$(field "$T1" status)" = queued ]; then
  ok "ten polls of an unchanged dep block write exactly one task.blocked"
else no "1: dep block repeated (n=$n1 rows=$(blocked "$T1"))"; fi

# 2. The judgement survives a daemon restart: it queries the ledger, so a
# fresh process must not re-announce a block that is still the same block.
# In-process memoization would pass case 1 and fail here.
fleet daemon stop >/dev/null 2>&1 || true
polls 3
fleet daemon stop >/dev/null 2>&1 || true
polls 3
n2=$(nblocked "$T1")
if [ "$n2" = 1 ]; then
  ok "the same block stays one event across daemon stop/restart"
else no "2: restart re-announced the block (n=$n2)"; fi

# 3. A different dep is different information: the second block writes, and
# carries the new dep id. Dedup that swallowed this would hide a real change.
fleet cancel "$D1" >/dev/null
D3=$(add dep-holder-2)
sql "update task set deps='$D3' where id=$T1;" >/dev/null
polls 4
n3=$(nblocked "$T1")
rows3=$(blocked "$T1")
if [ "$n3" = 2 ] \
 && [ "$(printf '%s\n' "$rows3" | tail -1)" = "{\"reason\": \"dep\", \"dep\": $D3}" ] \
 && [ "$(printf '%s\n' "$rows3" | sort -u | wc -l)" = 2 ]; then
  ok "a swapped dep writes a second event with a different payload"
else no "3: dep swap (n=$n3 rows=$rows3)"; fi

# 4. A start ends the episode. The task must be blocked with payload P,
# then start, then be blocked again with the very same P -- and the second
# block must write. Review 366 caught the first version of this case: it
# never blocked the task before its start (pre=0), so dropping task.start
# from _BLOCK_EPISODE_KINDS left the suite green. Route: H1 holds the lease
# for two seconds and T4 blocks on it (row 1); H1 finishes, T4 starts and
# fails onto its retry slot; a rival enqueued after the failure at higher
# priority takes the freed lease (start_ready walks (priority DESC, id ASC),
# so a rival present from the start would lose to the lower-id T4); T4 is
# blocked again with the identical payload (row 2).
fresh
printf 'sleep 2\n' > "$FLEET_HOME/short.sh"
H1=$(fleet add lease-holder-1 --channel shell --no-preamble \
     --spec "$FLEET_HOME/short.sh" --lease p18-shared)
T4=$(fleet add self-lease --channel shell --no-preamble \
     --spec "$FLEET_HOME/fail.sh" --lease p18-shared --max-attempts 2)
polls 4                                    # H1 holds the lease, T4 blocks on it
pre4=$(nblocked "$T4")
fleet wait --ids "$H1" --timeout 20 >/dev/null 2>&1 || true
polls 1                                    # T4 takes the lease, starts, fails
started4=$(sql "select count(*) from event where task_id=$T4 and kind='task.start'")
# T4 is not terminal after its first failure (retry slot), so wait on the
# finish event rather than on a terminal status.
for _ in $(seq 40); do
  [ "$(sql "select count(*) from event where task_id=$T4 and kind='task.finish'")" -ge 1 ] && break; sleep 0.5
done
H4=$(add lease-rival --lease p18-shared --priority 5)
polls 1                                    # the rival wins the freed lease
polls 4                                    # T4 is back in the queue, blocked again
post4=$(nblocked "$T4")
rows4=$(blocked "$T4")
if [ "$pre4" = 1 ] && [ "$started4" = 1 ] && [ "$post4" = 2 ] \
 && [ "$(printf '%s\n' "$rows4" | sort -u | wc -l)" = 1 ] \
 && [ "$(field "$H4" status)" = running ] \
 && printf '%s' "$rows4" | grep -q '"reason": "lease"'; then
  ok "a block after task.start opens a new episode and writes again"
else no "4: post-start block (started=$started4 pre=$pre4 post=$post4 rows=$rows4)"; fi

# 5. The readers still work off the single row: brief renders the reason from
# it (the P14 display), and the folded `since` line names the task once
# instead of once per poll -- the noise this change exists to remove.
fresh
G5=$(fleet goal add p18-brief)
D5=$(add dep-holder --goal "$G5")
T5=$(add dep-waiter --goal "$G5" --dep "$D5")
polls 10
b5=$(fleet brief)
raw5=$(fleet since --raw 0 | grep -c " task.blocked $T5 " || true)
if [ "$(nblocked "$T5")" = 1 ] \
 && printf '%s' "$b5" | grep -q "$T5 queued(shell, blocked: dep $D5)" \
 && [ "$raw5" = 1 ]; then
  ok "brief shows the reason from one row; since --raw names the task once"
else no "5: readers (n=$(nblocked "$T5") raw=$raw5 brief=$b5)"; fi

# 6. Lease blocking dedupes on the same rule as dep blocking. It is a
# separate write site in start_ready, so a fix applied to only the dep path
# would leave this red.
fresh
H6=$(add lease-holder --lease p18-l6)
polls 1
T6=$(add lease-waiter --lease p18-l6)
polls 10
n6=$(nblocked "$T6")
if [ "$(field "$H6" status)" = running ] && [ "$n6" = 1 ] \
 && [ "$(blocked "$T6")" = '{"reason": "lease", "resource": "p18-l6"}' ]; then
  ok "ten polls of an unchanged lease block write exactly one task.blocked"
else no "6: lease block repeated (n=$n6 rows=$(blocked "$T6"))"; fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = 0 ]
