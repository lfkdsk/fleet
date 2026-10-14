#!/usr/bin/env bash
# Wire contrib's glue into this machine. DRY RUN unless --apply.
#
# Everything here used to live as prose in contrib/README.md ("systemd user
# timer, 10s 一次"), which did not ensure it was actually installed. Executable
# wiring makes the described timers and Stop hook verifiable; a template that
# nobody can run is a plan, not a configuration.
#
# Usage:
#   install.sh                     # print what would change, touch nothing
#   install.sh --apply             # do it
#   install.sh --only stop-hook    # one part (stop-hook | activity | notify | daemon)
#   install.sh --apply --only activity,notify
#
# Line prefixes: '+' create, '~' change in place, '=' already correct,
# '!' refused or unavailable (with the reason).
#
# Honours $HOME and $XDG_CONFIG_HOME, so the tests drive it against a temp
# home. FLEET_WIRING_SYSTEMCTL overrides the systemctl binary (the tests point
# it at a recorder); an absent systemctl is reported, not fatal.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CONTRIB="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APPLY=0
PARTS="stop-hook,activity,notify,daemon"
SYSTEMCTL="${FLEET_WIRING_SYSTEMCTL:-systemctl}"
rc=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --only)
      [ $# -ge 2 ] || { echo "install: --only needs a value" >&2; exit 2; }
      PARTS="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "install: unknown arg: $1" >&2; exit 2 ;;
  esac
done

for want in ${PARTS//,/ }; do
  case "$want" in
    stop-hook|activity|notify|daemon) ;;
    *) echo "install: unknown part: $want (stop-hook|activity|notify|daemon)" >&2; exit 2 ;;
  esac
done
wants(){ case ",$PARTS," in *",$1,"*) return 0 ;; *) return 1 ;; esac }

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
UNIT_DIR="$CONFIG_HOME/systemd/user"

say(){ printf '%s %s\n' "$1" "$2"; }

# --- the Stop hook ----------------------------------------------------------
# Merged into settings.json rather than written over it: that file carries
# permissions, env and other hooks, and this is the one part of the wiring
# that is edited by hand often enough to matter.
if wants stop-hook; then
  SETTINGS="$HOME/.claude/settings.json"
  python3 - "$SETTINGS" "$CONTRIB" "$APPLY" <<'PYHOOK'
import json, os, shlex, sys, tempfile, time
settings, contrib, apply = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
# The harness runs this command through a shell. An unquoted path with a space
# in it splits into two arguments and the hook never runs again -- and a
# checkout path is not something this script gets to assume anything about.
cmd = "python3 " + shlex.quote(f"{contrib}/surface-decisions.py")
try:
    with open(settings) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        print(f"! {settings} does not hold a JSON object; left alone")
        sys.exit(1)
except FileNotFoundError:
    data = {}
except ValueError as e:
    # Never rewrite a file we could not parse: the hand-edited content in it
    # is worth more than this hook.
    print(f"! {settings} is not valid JSON ({e}); left alone")
    sys.exit(1)

# Valid JSON of the wrong shape is still someone's settings file: say what is
# wrong and leave it alone, rather than tracebacking half way through.
hooks = data.setdefault("hooks", {})
if not isinstance(hooks, dict):
    print(f"! {settings}: \"hooks\" is not an object; left alone")
    sys.exit(1)
stop = hooks.setdefault("Stop", [])
if not isinstance(stop, list) or not all(isinstance(g, dict) for g in stop):
    print(f"! {settings}: \"hooks.Stop\" is not a list of objects; left alone")
    sys.exit(1)
found = None
for group in stop:
    entries = group.get("hooks")
    if not isinstance(entries, list):
        continue
    for h in entries:
        if isinstance(h, dict) and "surface-decisions.py" in str(h.get("command", "")):
            found = h
if found is not None and found.get("command") == cmd:
    print(f"= Stop hook already points at {contrib}/surface-decisions.py")
    sys.exit(0)
verb = "~" if found is not None else "+"
what = ("repoint the Stop hook at" if found is not None
        else "add a Stop hook running")
if not apply:
    print(f"{verb} would {what} {contrib}/surface-decisions.py  ({settings})")
    sys.exit(0)
if found is not None:
    found["command"] = cmd
else:
    stop.append({"hooks": [{"type": "command", "command": cmd,
                            "timeout": 10,
                            "statusMessage": "checking fleet decisions"}]})
os.makedirs(os.path.dirname(settings), exist_ok=True)
if os.path.exists(settings):
    backup = f"{settings}.bak-{int(time.time())}"
    with open(settings) as f, open(backup, "w") as b:
        b.write(f.read())
    print(f"  backup: {backup}")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings), prefix=".settings.")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, settings)
print(f"{verb} {what} {contrib}/surface-decisions.py  ({settings})")
PYHOOK
  [ $? -ge 1 ] && rc=1
fi

# --- systemd units ----------------------------------------------------------
have_systemctl(){ command -v "$SYSTEMCTL" >/dev/null 2>&1; }

install_unit(){   # $1 = unit file name
  local name="$1" src="$HERE/$1" dst="$UNIT_DIR/$1" rendered
  # Substitution is literal (Python replace), and the result is then quoted
  # the way systemd needs. Three separate lessons are baked in here:
  #   * not sed -- an unescaped & in a sed replacement means "the whole match",
  #     so a path containing & rendered back to @CONTRIB@;
  #   * not bash ${raw//@CONTRIB@/$CONTRIB} -- since 5.2 (this box: 5.2.21) &
  #     is special in that replacement too, which reproduced the same bug in a
  #     second language;
  #   * literal substitution alone is still not enough. ExecStart is word-split
  #     by systemd, so a space in the path silently runs a different command; a
  #     single quote is "Unbalanced quoting ... unit will not be started"; and %
  #     is a unit specifier whether quoted or not. Measured, not assumed.
  # So each token that carries a path is emitted as one double-quoted
  # systemd token with \ " escaped and % doubled. A checkout path is not this
  # script's to constrain.
  #
  # Two markers: @CONTRIB@ is the contrib/ dir (the timers' scripts live
  # there); @REPO@ is the repo root one level up (the daemon binary is
  # <repo>/bin/fleet). Both go through the same literal-then-quote path.
  rendered="$(SRC="$src" SUB="$CONTRIB" REPO="$REPO" python3 -c 'import os, sys


def q(tok):
    tok = tok.replace("\\", "\\\\").replace(chr(34), "\\" + chr(34)).replace("%", "%%")
    return chr(34) + tok + chr(34)


subs = {"@CONTRIB@": os.environ["SUB"], "@REPO@": os.environ["REPO"]}
out = []
for line in open(os.environ["SRC"]).read().splitlines():
    if any(mark in line for mark in subs):
        k, sep, v = line.partition("=")
        toks = []
        for t in v.split(" "):
            for mark, val in subs.items():
                if mark in t:
                    t = q(t.replace(mark, val))
                    break
            toks.append(t)
        v = " ".join(toks)
        line = k + sep + v
    out.append(line)
sys.stdout.write("\n".join(out) + "\n")')" || return 1
  if [ -f "$dst" ] && [ "$rendered" = "$(cat "$dst")" ]; then
    say "=" "$dst"
    return 0
  fi
  local verb="+"; [ -f "$dst" ] && verb="~"
  if [ "$APPLY" = 0 ]; then
    say "$verb" "would write $dst"
    return 0
  fi
  mkdir -p "$UNIT_DIR" || return 1
  printf '%s\n' "$rendered" > "$dst" || return 1
  say "$verb" "$dst"
}

enable_unit(){   # $1 = unit name (timer or service); enable --now
  local name="$1"
  if ! have_systemctl; then
    say "!" "$name not enabled: no systemctl on PATH (units are in place; enable them however this box starts things)"
    return 0
  fi
  if [ "$APPLY" = 0 ]; then
    say "+" "would run: $SYSTEMCTL --user enable --now $name"
    return 0
  fi
  "$SYSTEMCTL" --user daemon-reload >/dev/null 2>&1
  if "$SYSTEMCTL" --user enable --now "$name" >/dev/null 2>&1; then
    say "+" "$SYSTEMCTL --user enable --now $name"
  else
    say "!" "$SYSTEMCTL --user enable --now $name failed (no user bus, or the unit did not load; the file is in place)"
    return 1
  fi
}

if wants activity; then
  # The script itself exits 0 when the directory is missing, so this is a
  # note about what the timer will accomplish, not a refusal.
  [ -d "$HOME/.switchboard/activity.d" ] \
    || say "!" "$HOME/.switchboard/activity.d does not exist: the timer will run and write nothing until Switchboard is set up"
  install_unit fleet-activity.service || rc=1
  install_unit fleet-activity.timer || rc=1
  enable_unit fleet-activity.timer || rc=1
fi

if wants notify; then
  NOTIFY_CFG="$CONFIG_HOME/fleet-contrib/notify-lark.json"
  install_unit fleet-notify-lark.service || rc=1
  install_unit fleet-notify-lark.timer || rc=1
  target=""
  if [ -f "$NOTIFY_CFG" ]; then
    target="$(python3 -c 'import json,sys
try: c=json.load(open(sys.argv[1]))
except Exception: c={}
print((c.get("chat_id") or c.get("user_id") or "") if isinstance(c,dict) else "")' "$NOTIFY_CFG")"
  else
    if [ "$APPLY" = 1 ]; then
      mkdir -p "$(dirname "$NOTIFY_CFG")" \
        && cp "$HERE/notify-lark.example.json" "$NOTIFY_CFG" \
        && say "+" "$NOTIFY_CFG (from the example; fill in chat_id or user_id)"
    else
      say "+" "would copy the example config to $NOTIFY_CFG"
    fi
  fi
  if [ -n "$target" ]; then
    enable_unit fleet-notify-lark.timer || rc=1
  else
    # Enabling it now would mean a --send that exits 2 every single minute.
    say "!" "fleet-notify-lark.timer not enabled: $NOTIFY_CFG names no chat_id or user_id. Fill one in, then: $SYSTEMCTL --user enable --now fleet-notify-lark.timer"
  fi
fi

if wants daemon; then
  # The long-running poll loop as a user service, with Restart=always so a
  # crash, a `fleet daemon stop` (code reload) or a reboot (with linger) brings
  # it back. The enable step is best-effort on purpose: the unit file is the
  # durable artifact, and a box without a systemd user bus still wants it
  # written down. Unlike the timers, a failed enable here is reported, not
  # fatal -- there is nothing further this script can do about the bus.
  install_unit fleet-daemon.service || rc=1
  enable_unit fleet-daemon.service || true
  if [ "$APPLY" = 0 ]; then
    say "!" "note: once enabled, 'fleet daemon stop' only restarts the loop (it reloads the code); to stop it for real: $SYSTEMCTL --user stop fleet-daemon"
  fi
fi

[ "$APPLY" = 0 ] && echo "(dry run -- nothing was changed; re-run with --apply)"
exit "$rc"
