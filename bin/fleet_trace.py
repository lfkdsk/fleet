"""What a task did, kept next to its output.

`persist()` runs once per attempt, from the wrapper, just before `_finish`:

  attempt-N/transcript.<kind>.jsonl.gz   the CLI's own session file, copied
                                         (Claude also keeps subagents/*.jsonl)
  attempt-N/trace.json.gz                the steps, normalized across CLIs

Sources, best first:
  * a Claude Code transcript (claude-p, hybrid and other claude-family
    channels): their log.txt only holds stderr, so without the copy the
    process lives solely in an isolated config home under $FLEET_HOME;
  * the text log that codex-style CLIs print to log.txt (also what remote
    ssh channels bring back, whose session files stay remote);
  * rollout/grok session files are copied for keeping but not parsed yet.

A step is {"k", "title", "body", "status", "ts", "cut"}:
  k      user | say | think | exec | tool | patch | compact | result
  body   capped at BODY_CAP bytes; "cut" is how many bytes were dropped
         (the full text is still in log.txt or the transcript copy)
Nothing here may fail a task: callers wrap it and ignore errors.
"""
import gzip
import json
import os
import re
import shutil
import time
from pathlib import Path

VERSION = 1
TRACE_FILE = "trace.json.gz"  # traces run ~1.5 MB plain; gzip keeps them ~10x smaller
BODY_CAP = 16 * 1024
MAX_STEPS = 4000

_TEXT_MARKERS = {"user", "thinking", "codex", "assistant", "exec", "apply patch",
                 "context compacted", "tokens used", "file update"}
_KIND_OF_MARKER = {"user": "user", "thinking": "think", "codex": "say", "assistant": "say",
                   "exec": "exec", "apply patch": "patch", "file update": "patch",
                   "context compacted": "compact", "tokens used": "result"}
_EXEC_STATUS = re.compile(r"^ (succeeded|failed|backgrounded|exited (-?\d+))(?: in ([\d.]+m?s))?:$")
_EXEC_CWD = re.compile(r" in (/\S*)$")
_MCP_START = re.compile(r"^mcp: (\S+) started$")
_MCP_END = re.compile(r"^mcp: (\S+) \((completed|failed|error)\)$")
_PATCH_STATUS = re.compile(r"^patch: (completed|failed)$")
_CLI_LOG = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z +(ERROR|WARN)\b")


def _cap(text):
    b = text.encode("utf-8", "replace")
    if len(b) <= BODY_CAP:
        return text, 0
    return b[:BODY_CAP].decode("utf-8", "ignore"), len(b) - BODY_CAP


def _step(k, title="", ts=None):
    return {"k": k, "title": title, "lines": [], "status": None, "ts": ts}


def _seal(steps):
    out = []
    last_diff = None
    for s in steps:
        if s["k"] == "patch" and s["title"] == "working tree diff":
            # reprinted after every tool call; keep it only when it changed
            body = "\n".join(s["lines"])
            if body == last_diff:
                continue
            last_diff = body
        s.pop("left", None)
        s.pop("bad", None)
        s.pop("cmd", None)
        if s["k"] in ("say", "think") and s["lines"] and re.match(r"^\*\*[^*].*\*\*$", s["lines"][0].strip()):
            # codex-style reasoning summaries open with a **Heading**
            s["k"] = "think"
            s["title"] = s["lines"].pop(0).strip().strip("*").strip()
        if s["k"] == "patch":
            files = [l[len("diff --git a/"):].split(" b/")[0] for l in s["lines"] if l.startswith("diff --git a/")]
            if files:
                add = sum(1 for l in s["lines"] if l.startswith("+") and not l.startswith("+++"))
                rem = sum(1 for l in s["lines"] if l.startswith("-") and not l.startswith("---"))
                names = ", ".join(files[:3]) + (f" +{len(files) - 3}" if len(files) > 3 else "")
                s["title"] = f"{s['title'] + ': ' if s['title'] else ''}{names}  (+{add} −{rem})"
            elif not s["title"]:
                first = next((l.strip() for l in s["lines"] if l.strip()), "")
                s["title"] = first
        body = "\n".join(s.pop("lines")).strip("\n")
        if s["k"] == "say" and not body.strip() and not s["title"]:
            continue
        s["body"], s["cut"] = _cap(body)
        out.append(s)
    if len(out) > MAX_STEPS:
        head, tail = out[: MAX_STEPS // 2], out[-MAX_STEPS // 2:]
        out = head + [{"k": "compact", "title": f"{len(out) - MAX_STEPS} steps omitted",
                       "body": "", "status": None, "ts": None, "cut": 0}] + tail
    return out


# ---------------------------------------------------------------- text logs
def parse_text_log(text):
    """codex `exec`-style transcript -> (header, steps, tokens)."""
    lines = text.splitlines()
    header, i = {}, 0
    if lines and lines[0].startswith("OpenAI Codex"):
        header["cli"] = lines[0].strip()
        seps = [n for n, l in enumerate(lines[:40]) if l.strip() == "--------"]
        if len(seps) >= 2:
            for l in lines[seps[0] + 1: seps[1]]:
                k, sep, v = l.partition(": ")
                if sep:
                    header[k.strip()] = v.strip()
            i = seps[1] + 1
    steps, cur, tokens = [], None, None
    open_tools = {}
    # Parallel calls print every `exec` header first and then the results in
    # completion order, so a result cannot be paired with its command. A batch
    # becomes one step: the commands, then each result under its status.
    pending, group = [], None

    def status_of(m):
        return {"succeeded": "ok", "failed": "failed", "backgrounded": "background"}.get(m.group(1)) or f"exit {m.group(2)}"

    def start(k, title=""):
        nonlocal cur
        cur = _step(k, title)
        steps.append(cur)
        return cur

    while i < len(lines):
        line = lines[i]
        i += 1
        if line.startswith("hook: "):
            cur = None  # some codex-style CLIs bracket every tool call with hooks
            continue
        m = _MCP_START.match(line)
        if m:
            open_tools[m.group(1)] = start("tool", m.group(1))
            cur = None
            continue
        m = _MCP_END.match(line)
        if m:
            s = open_tools.pop(m.group(1), None)
            if s is not None:
                s["status"] = "ok" if m.group(2) == "completed" else m.group(2)
            continue
        if line in _TEXT_MARKERS:
            k = _KIND_OF_MARKER[line]
            group = None
            s = start(k)
            if k == "exec" and i < len(lines):
                # A command may span lines; it ends at the " in <cwd>" suffix,
                # or at the status line / next marker when the CLI prints none.
                cmd = []
                while i < len(lines) and len(cmd) < 400:
                    l = lines[i]
                    if (_EXEC_STATUS.match(l) or l in _TEXT_MARKERS or l.startswith("hook: ")
                            or _MCP_START.match(l)):
                        break
                    cmd.append(l)
                    i += 1
                    if _EXEC_CWD.search(l):
                        break
                if cmd:
                    cmd[-1] = _EXEC_CWD.sub("", cmd[-1])
                s["title"] = cmd[0] if cmd else ""
                s["cmd"] = "\n".join(cmd)
                if len(cmd) > 1:
                    s["lines"].append("$ " + s["cmd"])
                    s["lines"].append("── output ──")
                pending.append(s)
                cur = None
            elif k == "result" and i < len(lines):
                tokens = lines[i].strip().replace(",", "") or None
                i += 1
            continue
        m = _EXEC_STATUS.match(line)
        if m and len(pending) == 1:
            cur = pending.pop()
            cur["status"] = status_of(m)
            if m.group(3):
                cur["title"] += f"  ({m.group(3)})"
            continue
        if m and len(pending) > 1:
            at = steps.index(pending[0])
            group = _step("exec", f"{len(pending)} commands in parallel")
            group["lines"] = [f"$ {p.get('cmd') or p['title']}" for p in pending]
            group["left"], group["bad"] = len(pending), []
            for p in pending:
                steps.remove(p)
            steps.insert(at, group)
            pending = []
        if m and not pending and (group is None or group["left"] <= 0):
            # A result whose `exec` header was consumed long before (parallel
            # calls interleaved with other steps): keep it a command result,
            # never speech.
            cur = start("exec", "(result of an earlier command)")
            cur["status"] = status_of(m)
            if m.group(3):
                cur["title"] += f"  ({m.group(3)})"
            continue
        if m and group is not None and group["left"] > 0:
            st = status_of(m)
            group["left"] -= 1
            if st != "ok":
                group["bad"].append(st)
            group["status"] = group["bad"][0] if group["bad"] else "ok"
            group["lines"].append(f"── {st}{' (' + m.group(3) + ')' if m.group(3) else ''} ──")
            cur = group
            continue
        m = _PATCH_STATUS.match(line)
        if m and cur is not None and cur["k"] == "patch":
            cur["status"] = "ok" if m.group(1) == "completed" else "failed"
            continue
        m = _CLI_LOG.match(line)
        if m or line.startswith("collab: "):
            # the CLI's own error log lines and collab (subagent) calls
            s = start("tool", line if not m else f"CLI {m.group(1).lower()}: " + line.split(m.group(1), 1)[1].strip())
            if m:
                s["status"] = "error" if m.group(1) == "ERROR" else None
            s["lines"].append(line)
            continue
        if line.startswith("diff --git ") and (cur is None or cur["k"] in ("say", "think")):
            # some CLIs reprint the whole working-tree diff after tool calls,
            # sometimes straight after the speech with no hook in between
            start("patch", "working tree diff")
        elif cur is None:
            start("say")
        cur["lines"].append(line)
    # the final message can print as speech and again after `tokens used`
    res = next((s for s in reversed(steps) if s["k"] == "result"), None)
    if res is not None:
        final = "\n".join(res["lines"]).strip()
        for s in reversed(steps[: steps.index(res)]):
            if s["k"] != "say":
                continue
            body = "\n".join(s["lines"]).strip()
            if final and (body == final or body.endswith(final)):
                steps.remove(s)
            break
    for s in steps:
        if s["k"] == "user" and s["lines"]:
            s["title"] = s["lines"][0].lstrip("# ").strip()
    try:
        tokens = int(tokens) if tokens else None
    except ValueError:
        tokens = None
    return header, _seal(steps), tokens


# ---------------------------------------------------------------- claude jsonl
def _tool_title(name, inp):
    if not isinstance(inp, dict):
        return name
    for key in ("command", "file_path", "path", "pattern", "url", "description", "prompt"):
        v = inp.get(key)
        if isinstance(v, str) and v:
            v = v.strip().splitlines()[0] if v.strip() else v
            return f"{name}: {v[:300]}"
    return name


def _result_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict):
                if b.get("type") == "text":
                    parts.append(b.get("text") or "")
                elif b.get("type") == "image":
                    parts.append("[image]")
        return "\n".join(parts)
    return ""


def parse_claude_jsonl(lines_iter):
    steps, by_id, tokens, model = [], {}, 0, None
    for raw in lines_iter:
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        if d.get("isSidechain"):
            continue
        t, ts = d.get("type"), d.get("timestamp")
        msg = d.get("message") or {}
        content = msg.get("content")
        if t == "system" and d.get("subtype") == "compact_boundary":
            steps.append(_step("compact", "context compacted", ts))
            continue
        if t == "user":
            if isinstance(content, str):
                s = _step("user", content.strip().splitlines()[0].lstrip("# ") if content.strip() else "", ts)
                s["lines"].append(content)
                steps.append(s)
            elif isinstance(content, list):
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_result":
                        s = by_id.get(b.get("tool_use_id"))
                        if s is not None:
                            s["lines"].append("── result ──")
                            s["lines"].append(_result_text(b.get("content")))
                            s["status"] = "error" if b.get("is_error") else "ok"
                    elif b.get("type") == "text" and not d.get("isMeta"):
                        s = _step("user", (b.get("text") or "").strip()[:200], ts)
                        s["lines"].append(b.get("text") or "")
                        steps.append(s)
            continue
        if t != "assistant" or not isinstance(content, list):
            continue
        model = msg.get("model") or model
        u = msg.get("usage") or {}
        tokens += int(u.get("output_tokens") or 0)
        for b in content:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text":
                s = _step("say", "", ts)
                s["lines"].append(b.get("text") or "")
                steps.append(s)
            elif bt == "thinking":
                text = b.get("thinking") or ""
                if text.strip():
                    s = _step("think", "", ts)
                    s["lines"].append(text)
                    steps.append(s)
            elif bt == "tool_use":
                name, inp = b.get("name") or "tool", b.get("input")
                k = "exec" if name == "Bash" else "patch" if name in ("Edit", "Write", "MultiEdit", "NotebookEdit") else "tool"
                s = _step(k, _tool_title(name, inp), ts)
                body = inp.get("command") if (name == "Bash" and isinstance(inp, dict)) else json.dumps(inp, ensure_ascii=False, indent=1)
                s["lines"].append(body or "")
                steps.append(s)
                by_id[b.get("id")] = s
    if steps and steps[-1]["k"] == "say":
        steps[-1]["k"] = "result"
    return {"model": model}, _seal(steps), tokens or None


# ---------------------------------------------------------------- persistence
def _gzip_copy(src, dst):
    tmp = dst.with_name(dst.name + ".tmp")
    with open(src, "rb") as f, gzip.open(tmp, "wb", compresslevel=6) as g:
        shutil.copyfileobj(f, g)
    os.replace(tmp, dst)


def _open_text(path):
    p = str(path)
    return gzip.open(p, "rt", errors="replace") if p.endswith(".gz") else open(p, errors="replace")


def build(run_dir, log_path=None, session=None, session_kind=None):
    """Steps for one attempt, from the best source available. Pure: no writes."""
    run_dir = Path(run_dir)
    src = None
    if session_kind == "claude" and session:
        with _open_text(session) as f:
            header, steps, tokens = parse_claude_jsonl(f)
        src = "claude"
    if src is None and log_path and Path(log_path).is_file():
        with _open_text(log_path) as f:
            text = f.read()
        header, steps, tokens = parse_text_log(text)
        if header.get("cli") or len(steps) > 1:
            src = "log"
        else:
            src = None
    if src is None:
        return None
    return {"version": VERSION, "source": src, "header": header, "tokens": tokens,
            "steps": steps, "built_at": int(time.time())}


def persist(run_dir, log_path=None, session=None, session_kind=None):
    """Copy the session file into run_dir and write trace.json.gz. Returns a summary."""
    run_dir = Path(run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    kept = []
    if session and Path(session).is_file():
        dst = run_dir / f"transcript.{session_kind or 'session'}.jsonl.gz"
        _gzip_copy(session, dst)
        kept.append(dst.name)
        sub = Path(str(session)[: -len(".jsonl")]) / "subagents" if str(session).endswith(".jsonl") else None
        if session_kind == "claude" and sub and sub.is_dir():
            out = run_dir / "transcript.subagents"
            out.mkdir(exist_ok=True)
            for p in sorted(sub.glob("*.jsonl")):
                _gzip_copy(p, out / (p.name + ".gz"))
                kept.append(f"transcript.subagents/{p.name}.gz")
    copied = run_dir / f"transcript.{session_kind}.jsonl.gz" if kept else None
    trace = build(run_dir, log_path, copied or session, session_kind)
    if trace is not None:
        trace["session_source"] = str(session) if session else None
        trace["kept"] = kept
        tmp = run_dir / (TRACE_FILE + ".tmp")
        with gzip.open(tmp, "wt", compresslevel=6) as f:
            f.write(json.dumps(trace, ensure_ascii=False))
        os.replace(tmp, run_dir / TRACE_FILE)
        try:
            (run_dir / "trace.json").unlink()  # the uncompressed form of earlier builds
        except OSError:
            pass
    return {"kept": kept, "steps": len(trace["steps"]) if trace else 0,
            "source": trace["source"] if trace else None}


def trace_path(run_dir):
    """The stored trace for an attempt dir, or None (gzip, or the older plain file)."""
    for name in (TRACE_FILE, "trace.json"):
        p = Path(run_dir) / name
        if p.is_file():
            return p
    return None


def load(run_dir):
    try:
        p = trace_path(run_dir)
        if p is None:
            return None
        with _open_text(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
