#!/usr/bin/env bash
# fleet P4 smoke tests: agent channel key, ssh adapter, mutation runner.
# Zero model quota: model-backed CLIs are only exercised via
# FLEET_ADAPTER_DRYRUN=1 (print argv, do not execute).
set -u

# An ambient FLEET_MODEL from the calling session would otherwise reach the
# adapter invocations below and change their argv (the ssh dryrun renders
# it); cases that need a model set one explicitly.
unset FLEET_MODEL

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export FLEET_HOME="$(mktemp -d /var/tmp/fleet-p4-test-XXXX)"
trap 'rm -rf "$FLEET_HOME"' EXIT
export PATH="$ROOT/bin:$PATH"

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

fleet init >/dev/null
printf 'echo hi\n' > "$FLEET_HOME/spec_echo.sh"

# Test registry: agent key on a claude channel and on codex (which must
# ignore it), a shell channel with agent (launch-path probe), and an ssh
# channel pointing at a host that cannot resolve.
python3 - "$FLEET_HOME/channels.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["channels"]["claude-p"]["agent"] = "reviewer"
d["channels"]["codex"]["agent"] = "reviewer"
d["channels"]["agent-probe"] = {
    "family": "none",
    "adapter": "shell.sh",
    "agent": "probe-x",
    "desc": "test: shell.sh must ignore the agent key",
}
d["channels"]["ssh-bad"] = {
    "family": "none",
    "adapter": "ssh.sh",
    "ssh_host": "fleet-test-no-such-host.invalid",
    "desc": "test: guaranteed-unreachable ssh target (RFC 6761 .invalid)",
}
json.dump(d, open(sys.argv[1], "w"), indent=2)
EOF

# 1. dryrun: subscription and API adapters append --agent only when set
printf 'x\n' > "$FLEET_HOME/p1.md"
d1=$(FLEET_ADAPTER_DRYRUN=1 FLEET_AGENT=reviewer \
     bash "$ROOT/adapters/claude_p.sh" 1 "$FLEET_HOME/p1.md" "$FLEET_HOME" \
     "$FLEET_HOME/o1" "$FLEET_HOME/l1")
d2=$(FLEET_ADAPTER_DRYRUN=1 \
     bash "$ROOT/adapters/claude_p.sh" 1 "$FLEET_HOME/p1.md" "$FLEET_HOME" \
     "$FLEET_HOME/o1" "$FLEET_HOME/l1")
d3=$(FLEET_ADAPTER_DRYRUN=1 FLEET_AGENT=reviewer FLEET_MODEL=claude-test \
     FLEET_API_BASE_URL=https://api.example.test FLEET_API_KEY=test-key \
     bash "$ROOT/adapters/claude_api.sh" 1 "$FLEET_HOME/p1.md" "$FLEET_HOME" \
     "$FLEET_HOME/o1" "$FLEET_HOME/l1")
d4=$(FLEET_ADAPTER_DRYRUN=1 FLEET_MODEL=claude-test \
     FLEET_API_BASE_URL=https://api.example.test FLEET_API_KEY=test-key \
     bash "$ROOT/adapters/claude_api.sh" 1 "$FLEET_HOME/p1.md" "$FLEET_HOME" \
     "$FLEET_HOME/o1" "$FLEET_HOME/l1")
if printf '%s\n' "$d1" | grep -q -- '--agent reviewer' \
   && printf '%s\n' "$d3" | grep -q -- '--agent reviewer' \
   && ! printf '%s\n' "$d2" | grep -q -- '--agent' \
   && ! printf '%s\n' "$d4" | grep -q -- '--agent'; then
  ok "dryrun: --agent appended when FLEET_AGENT set, absent otherwise"
else
  no "dryrun: --agent appended when FLEET_AGENT set, absent otherwise"
fi

# 2. channels that do not support agent ignore the key: a gpt source enqueues fine,
#    and a shell channel with the key runs to done. The shell probe also
#    proves launch() exports FLEET_AGENT to the child.
C2=$(fleet add "gpt source with agent key" --channel codex \
     --spec "$FLEET_HOME/spec_echo.sh" 2>"$FLEET_HOME/err2")
rc2=$?
fleet cancel "$C2" >/dev/null 2>&1 || true
printf 'echo "AG=[${FLEET_AGENT:-}]"\n' > "$FLEET_HOME/spec_agent.sh"
AP=$(fleet add "agent probe" --channel agent-probe --spec "$FLEET_HOME/spec_agent.sh")
fleet run "$AP" >/dev/null
wait_status "$AP" done >/dev/null 2>&1
got=$(fleet digest "$AP" | tr -d '\n')
if [ "$rc2" = "0" ] && [ "$got" = "AG=[probe-x]" ]; then
  ok "agent key ignored by non-claude channels; launch exports FLEET_AGENT"
else
  no "agent key ignored by non-claude channels; launch exports FLEET_AGENT (rc2=$rc2 got=$got)"
fi

# 3. `fleet channels` carries the agent column (text and json)
if fleet channels | awk '$1=="agent-probe"{print $5}' | grep -qx "probe-x" \
   && fleet channels | awk '$1=="shell"{print $5}' | grep -qx -- "-" \
   && fleet --json channels | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert any(r["name"]=="agent-probe" and r["agent"]=="probe-x" for r in rows)
assert any(r["name"]=="shell" and r["agent"]=="-" for r in rows)'; then
  ok "channels: agent column present in text and json output"
else
  no "channels: agent column present in text and json output"
fi

# 4. agent does not change family: a claude channel with agent set still
#    cannot review a claude-family task (cross-family invariant holds)
T4=$(fleet add "review target" --channel cursor)
fleet add "agent review" --channel claude-p --review-of "$T4" \
  >/dev/null 2>"$FLEET_HOME/err4"
rc4=$?
fleet cancel "$T4" >/dev/null 2>&1 || true
if [ "$rc4" = "2" ] && grep -q "cross-family violation" "$FLEET_HOME/err4"; then
  ok "agent key does not change family: same-family review still rejected"
else
  no "agent key does not change family: same-family review still rejected (rc=$rc4)"
fi

# 5. ssh dryrun renders the REAL argv array (single source): the exact
#    command line, prompt content never in argv, remote_cmd and FLEET_MODEL
#    honored. The old assertion grepped a hand-written DRYRUN literal that
#    drifted from the execution line independently.
printf 'PROMPT-SECRET-MARKER-p4\n' > "$FLEET_HOME/p5.md"
d5=$(FLEET_ADAPTER_DRYRUN=1 FLEET_SSH_HOST=somehost.example \
     bash "$ROOT/adapters/ssh.sh" 5 "$FLEET_HOME/p5.md" "$FLEET_HOME" \
     "$FLEET_HOME/o5" "$FLEET_HOME/l5")
rc5=$?
d5b=$(FLEET_ADAPTER_DRYRUN=1 FLEET_SSH_HOST=somehost.example FLEET_REMOTE_CMD=zsh \
      bash "$ROOT/adapters/ssh.sh" 5 "$FLEET_HOME/p5.md" "$FLEET_HOME" \
      "$FLEET_HOME/o5" "$FLEET_HOME/l5")
d5c=$(FLEET_ADAPTER_DRYRUN=1 FLEET_SSH_HOST=somehost.example FLEET_REMOTE_CMD=bash \
      FLEET_MODEL=GPT-test-x \
      bash "$ROOT/adapters/ssh.sh" 5 "$FLEET_HOME/p5.md" "$FLEET_HOME" \
      "$FLEET_HOME/o5" "$FLEET_HOME/l5")
if [ "$rc5" = "0" ] \
   && printf '%s\n' "$d5" | grep -qxF 'DRYRUN: ssh -o BatchMode=yes somehost.example bash' \
   && printf '%s\n' "$d5b" | grep -qxF 'DRYRUN: ssh -o BatchMode=yes somehost.example zsh' \
   && printf '%s\n' "$d5c" | grep -qF 'FLEET_MODEL=' \
   && printf '%s\n' "$d5c" | grep -qF 'GPT-test-x' \
   && ! printf '%s\n' "$d5" | grep -q 'PROMPT-SECRET-MARKER'; then
  ok "ssh dryrun: real argv rendered, prompt via stdin, remote_cmd+model honored"
else
  no "ssh dryrun: real argv rendered ($d5 / $d5b / $d5c)"
fi

# 5b. the REAL execution line is the same argv array as the dryrun -- a fake
#     ssh records its argv, and it must match the dryrun exactly. The old
#     suite only asserted the dryrun, so a hand-written execution line could
#     drift (drop BatchMode, drop the model prefix) and stay green.
FAKESSH="$FLEET_HOME/fakebin"
mkdir -p "$FAKESSH"
cat > "$FAKESSH/ssh" <<'EOS'
#!/usr/bin/env bash
# Record the real argv the adapter handed us, one per line. $@ excludes the
# command name, so the comparison prepends it below.
printf '%s\n' "$@" > "${FAKE_SSH_ARGV:?}"
exit 0
EOS
chmod +x "$FAKESSH/ssh"
: > "$FLEET_HOME/sshargv.txt"
FAKE_SSH_ARGV="$FLEET_HOME/sshargv.txt" PATH="$FAKESSH:$PATH" \
  FLEET_SSH_HOST=somehost.example FLEET_REMOTE_CMD=zsh \
  bash "$ROOT/adapters/ssh.sh" 5 "$FLEET_HOME/p5.md" "$FLEET_HOME" \
  "$FLEET_HOME/o5real" "$FLEET_HOME/l5real" >/dev/null 2>&1
# The dryrun for the same inputs, minus the "DRYRUN: " prefix, split into
# one-arg-per-line, must equal the argv the fake ssh recorded (plus argv[0]).
d5dry=$(FLEET_ADAPTER_DRYRUN=1 FLEET_SSH_HOST=somehost.example FLEET_REMOTE_CMD=zsh \
        bash "$ROOT/adapters/ssh.sh" 5 "$FLEET_HOME/p5.md" "$FLEET_HOME" \
        "$FLEET_HOME/o5dry" "$FLEET_HOME/l5dry")
printf '%s\n' "$d5dry" | sed 's/^DRYRUN: //' | tr ' ' '\n' > "$FLEET_HOME/dryargv.txt"
printf 'ssh\n' > "$FLEET_HOME/realargv.txt"
cat "$FLEET_HOME/sshargv.txt" >> "$FLEET_HOME/realargv.txt"
if diff -u "$FLEET_HOME/dryargv.txt" "$FLEET_HOME/realargv.txt" >/dev/null; then
  ok "ssh: real execution argv matches the dryrun (single source)"
else
  no "ssh: real execution argv drifted from dryrun"
fi

# 6. unreachable ssh target: task lands failed with a non-zero exit code
S6=$(fleet add "ssh unreachable" --channel ssh-bad --spec "$FLEET_HOME/spec_echo.sh")
fleet run "$S6" >/dev/null
st6=""
for i in $(seq 1 200); do
  st6=$(field "$S6" status)
  [ "$st6" = "failed" ] && break
  sleep 0.3
done
ec6=$(field "$S6" exit_code)
if [ "$st6" = "failed" ] && [ -n "$ec6" ] && [ "$ec6" != "0" ]; then
  ok "ssh unreachable: task failed with non-zero exit code ($ec6)"
else
  no "ssh unreachable: task failed with non-zero exit code (status=$st6 ec=$ec6)"
fi

# 7. mutate.sh flags a deliberately inert mutation and fails the run
printf 'inert-probe\tbin/fleet\ts|THIS_PATTERN_NEVER_MATCHES_zzz|x|\tsmoke\t1\n' \
  > "$FLEET_HOME/inert.tsv"
FLEET_MUTATIONS="$FLEET_HOME/inert.tsv" bash "$ROOT/tests/mutate.sh" \
  > "$FLEET_HOME/mut7.out" 2>&1
rc7=$?
if [ "$rc7" != "0" ] && grep -q '^inert-probe  INERT' "$FLEET_HOME/mut7.out"; then
  ok "mutate.sh: inert mutation reported INERT, run exits non-zero"
else
  no "mutate.sh: inert mutation reported INERT, run exits non-zero (rc=$rc7)"
  cat "$FLEET_HOME/mut7.out" >&2
fi

# 8. mutate.sh runs one real mutation and reports HAS-TEETH
bash "$ROOT/tests/mutate.sh" no-spill > "$FLEET_HOME/mut8.out" 2>&1
rc8=$?
if [ "$rc8" = "0" ] && grep -q '^no-spill  HAS-TEETH' "$FLEET_HOME/mut8.out"; then
  ok "mutate.sh: no-spill reported HAS-TEETH"
else
  no "mutate.sh: no-spill reported HAS-TEETH (rc=$rc8)"
  cat "$FLEET_HOME/mut8.out" >&2
fi

echo "---"
echo "passed $PASS / $((PASS+FAIL))"
[ "$FAIL" = "0" ]
