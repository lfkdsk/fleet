#!/usr/bin/env python3
"""fleet trace: normalized steps from CLI logs and transcripts, kept per attempt."""

import gzip
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
FLEET = Path(os.environ.get("FLEET_UNDER_TEST", ROOT / "bin" / "fleet"))
sys.path.insert(0, str(FLEET.parent))
import fleet_trace as ft  # noqa: E402

CODEX_LOG = """OpenAI Codex v0.1
--------
workdir: /tmp/w
model: gpt-x
--------
user
# Fleet task 7: demo

body of the prompt
codex
I will look first.
exec
/bin/bash -lc 'ls' in /tmp/w
 succeeded in 3ms:
a.txt
exec
/bin/bash -lc 'false' in /tmp/w
 exited 1 in 1ms:
mcp: fleet/fleet_claim started
mcp: fleet/fleet_claim (completed)
apply patch
patch: completed
/tmp/w/a.txt
tokens used
1,234
All done.
"""

HOOK_LOG = """OpenAI Codex v0.2
--------
workdir: /tmp/w
model: GPT-y
--------
user
# Fleet task 8: parallel
hook: UserPromptSubmit
codex
Plan: read three things.
hook: PreToolUse
hook: PreToolUse Completed
exec
cat one in /tmp/w
exec
cat two in /tmp/w
exec
Read
 succeeded in 1ms:
TWO
 exited 1 in 0ms:
 succeeded:
ONE
hook: PostToolUse
hook: PostToolUse Completed
Next I fix it.
hook: PreToolUse
exec
make in /tmp/w
 failed:
boom
tokens used
99
Fixed.
"""


def claude_lines(tid):
    rows = [
        {"type": "user", "timestamp": "t0", "message": {"role": "user", "content": f"# Fleet task {tid}: c\n\nprompt"}},
        {"type": "assistant", "timestamp": "t1", "message": {"model": "m", "usage": {"output_tokens": 5}, "content": [
            {"type": "thinking", "thinking": "hmm"},
            {"type": "text", "text": "Looking."},
            {"type": "tool_use", "id": "a", "name": "Bash", "input": {"command": "ls -la"}},
            {"type": "tool_use", "id": "b", "name": "Edit", "input": {"file_path": "/x.py", "old_string": "1", "new_string": "2"}}]}},
        {"type": "user", "timestamp": "t2", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "a", "content": "total 0"},
            {"type": "tool_result", "tool_use_id": "b", "content": "no match", "is_error": True}]}},
        {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "subagent chatter"}]}},
        {"type": "assistant", "timestamp": "t3", "message": {"usage": {"output_tokens": 7}, "content": [{"type": "text", "text": "Done."}]}},
    ]
    return [json.dumps(r) for r in rows]


class ParseTests(unittest.TestCase):
    def test_codex_log_steps_statuses_tokens(self):
        header, steps, tokens = ft.parse_text_log(CODEX_LOG)
        self.assertEqual(header["model"], "gpt-x")
        self.assertEqual(tokens, 1234)
        kinds = [s["k"] for s in steps]
        self.assertEqual(kinds, ["user", "say", "exec", "exec", "tool", "patch", "result"])
        self.assertEqual(steps[0]["title"], "Fleet task 7: demo")
        self.assertEqual(steps[2]["title"], "/bin/bash -lc 'ls'  (3ms)")
        self.assertEqual((steps[2]["status"], steps[2]["body"]), ("ok", "a.txt"))
        self.assertEqual(steps[3]["status"], "exit 1")
        self.assertEqual((steps[4]["title"], steps[4]["status"]), ("fleet/fleet_claim", "ok"))
        self.assertEqual(steps[5]["status"], "ok")
        self.assertEqual(steps[6]["body"], "All done.")

    def test_parallel_batch_and_hook_prose(self):
        _, steps, tokens = ft.parse_text_log(HOOK_LOG)
        self.assertEqual(tokens, 99)
        self.assertEqual([s["k"] for s in steps], ["user", "say", "exec", "say", "exec", "result"])
        batch = steps[2]
        self.assertEqual(batch["title"], "3 commands in parallel")
        self.assertEqual(batch["status"], "exit 1")  # worst of ok / exit 1 / ok
        self.assertIn("$ cat one", batch["body"])
        self.assertIn("ONE", batch["body"])
        self.assertIn("── exit 1 (0ms) ──", batch["body"])
        self.assertEqual(steps[3]["body"], "Next I fix it.")
        self.assertEqual((steps[4]["title"], steps[4]["status"]), ("make", "failed"))
        self.assertNotIn("hook:", json.dumps(steps))

    def test_claude_transcript(self):
        header, steps, tokens = ft.parse_claude_jsonl(claude_lines(5))
        self.assertEqual(header["model"], "m")
        self.assertEqual(tokens, 12)
        self.assertEqual([s["k"] for s in steps], ["user", "think", "say", "exec", "patch", "result"])
        self.assertEqual((steps[3]["title"], steps[3]["status"]), ("Bash: ls -la", "ok"))
        self.assertIn("total 0", steps[3]["body"])
        self.assertEqual(steps[4]["status"], "error")
        self.assertNotIn("subagent chatter", json.dumps(steps))
        self.assertEqual(steps[-1]["ts"], "t3")

    def test_multiline_command_and_reasoning_heading(self):
        log = ("hook: PostToolUse Completed\n**Planning the fetch**\n\nI will curl it.\nhook: PreToolUse\n"
               "exec\nmkdir -p /tmp/x &&\ncurl -o /tmp/x/a https://e.x in /tmp/w\n succeeded in 9ms:\nfetched\n")
        _, steps, _ = ft.parse_text_log(log)
        self.assertEqual([s["k"] for s in steps], ["think", "exec"])
        self.assertEqual(steps[0]["title"], "Planning the fetch")
        self.assertEqual(steps[0]["body"], "I will curl it.")
        self.assertEqual(steps[1]["title"], "mkdir -p /tmp/x &&  (9ms)")
        self.assertIn("$ mkdir -p /tmp/x &&\ncurl -o /tmp/x/a https://e.x\n── output ──\nfetched", steps[1]["body"])
        self.assertEqual(steps[1]["status"], "ok")

    def test_orphan_result_is_a_command_not_speech(self):
        log = ("exec\ngh api x in /w\n succeeded in 160ms:\n{}\nhook: PostToolUse\n"
               " succeeded in 565ms:\nGet:31 https://packages.example/noble\n")
        _, steps, _ = ft.parse_text_log(log)
        self.assertEqual([s["k"] for s in steps], ["exec", "exec"])
        self.assertEqual(steps[1]["title"], "(result of an earlier command)  (565ms)")
        self.assertIn("Get:31", steps[1]["body"])

    def test_turn_diff_is_a_file_edit_not_speech(self):
        log = ("hook: PostToolUse Completed\ndiff --git a/x.py b/x.py\n--- a/x.py\n+++ b/x.py\n@@ -1 +1,2 @@\n-a\n+b\n+c\n"
               "hook: PreToolUse\napply patch\npatch: completed\n/w/y.py\n")
        _, steps, _ = ft.parse_text_log(log)
        self.assertEqual([s["k"] for s in steps], ["patch", "patch"])
        self.assertEqual(steps[0]["title"], "working tree diff: x.py  (+2 −1)")
        self.assertEqual(steps[1]["title"], "/w/y.py")

    def test_cli_error_lines_and_collab_calls_are_tools(self):
        log = ("codex\nTrying.\n2026-09-24T11:05:34.5Z ERROR codex_core::tools::router: error=apply_patch failed\n"
               "collab: Wait\nagent a1 done\n")
        _, steps, _ = ft.parse_text_log(log)
        self.assertEqual([s["k"] for s in steps], ["say", "tool", "tool"])
        self.assertEqual(steps[1]["status"], "error")
        self.assertTrue(steps[1]["title"].startswith("CLI error: codex_core"))
        self.assertEqual(steps[2]["title"], "collab: Wait")
        self.assertIn("agent a1 done", steps[2]["body"])

    def test_repeated_working_tree_diff_kept_once(self):
        d = "diff --git a/x b/x\n+1\n"
        log = f"hook: A\n{d}hook: B\nexec\nls in /w\n succeeded in 1ms:\nx\nhook: C\n{d}hook: D\n{d}+2\nhook: E\n"
        _, steps, _ = ft.parse_text_log(log)
        self.assertEqual([s["k"] for s in steps], ["patch", "exec", "patch"])
        self.assertIn("+2", steps[2]["body"])

    def test_final_message_not_repeated_as_speech(self):
        log = ("codex\nworking\nexec\nls in /w\n succeeded in 1ms:\nx\ncodex\nAll done.\n\n"
               "diff --git a/r.md b/r.md\n+new\ntokens used\n5\nAll done.\n")
        _, steps, _ = ft.parse_text_log(log)
        self.assertEqual([s["k"] for s in steps], ["say", "exec", "patch", "result"])

    def test_body_cap_records_cut(self):
        _, steps, _ = ft.parse_text_log("exec\nyes in /\n succeeded in 1ms:\n" + "y\n" * 20000)
        self.assertEqual(len(steps[0]["body"].encode()), ft.BODY_CAP)
        self.assertGreater(steps[0]["cut"], 0)

    def test_persist_copies_session_and_subagents(self):
        with tempfile.TemporaryDirectory(dir="/var/tmp") as d:
            d = Path(d)
            sess = d / "s" / "abc.jsonl"
            (d / "s" / "abc" / "subagents").mkdir(parents=True)
            sess.write_text("\n".join(claude_lines(9)) + "\n")
            (d / "s" / "abc" / "subagents" / "agent-1.jsonl").write_text("{}\n")
            run = d / "attempt-1"
            r = ft.persist(run, None, str(sess), "claude")
            self.assertEqual(r["source"], "claude")
            self.assertEqual(sorted(r["kept"]), ["transcript.claude.jsonl.gz",
                                                 "transcript.subagents/agent-1.jsonl.gz"])
            with gzip.open(run / "transcript.claude.jsonl.gz", "rt") as f:
                self.assertEqual(f.read(), sess.read_text())
            tr = ft.load(run)
            self.assertEqual(tr["session_source"], str(sess))
            self.assertEqual(tr["steps"][-1]["body"], "Done.")

    def test_unparsable_log_writes_nothing(self):
        with tempfile.TemporaryDirectory(dir="/var/tmp") as d:
            log = Path(d) / "log.txt"
            log.write_text("just one stderr line\n")
            self.assertIsNone(ft.persist(d, log)["source"])
            self.assertIsNone(ft.trace_path(d))


class WrapperTests(unittest.TestCase):
    """The wrapper writes the trace before settling, and keeps the exit code."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-trace-", dir="/var/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = dict(os.environ, FLEET_HOME=str(self.home))
        subprocess.run([str(FLEET), "init"], check=True, env=self.env, capture_output=True)

    def fleet(self, *args, check=True):
        return subprocess.run([str(FLEET), *map(str, args)], check=check, env=self.env,
                              capture_output=True, text=True)

    def settle(self, tid, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            conn = sqlite3.connect(self.home / "fleet.db")
            row = conn.execute("SELECT status, exit_code, run_dir FROM task WHERE id=?", (tid,)).fetchone()
            conn.close()
            if row[0] in ("done", "failed"):
                return row
            time.sleep(0.05)
        self.fail(f"task {tid} did not settle")

    def test_failed_task_keeps_exit_code_and_gets_trace(self):
        script = self.home / "fake-codex.sh"
        script.write_text("cat >&2 <<'EOF'\n" + CODEX_LOG + "EOF\nexit 3\n")
        tid = int(self.fleet("add", "trace me", "--channel", "shell", "--spec", script).stdout)
        self.fleet("run", tid)
        status, code, run_dir = self.settle(tid)
        self.assertEqual((status, code), ("failed", 3))
        tr = ft.load(run_dir)
        self.assertEqual(ft.trace_path(run_dir).name, "trace.json.gz")
        self.assertEqual(tr["source"], "log")
        self.assertEqual(tr["tokens"], 1234)
        out = self.fleet("trace", tid).stdout
        self.assertIn("source log", out)
        self.assertIn("[exit 1]", out)
        js = json.loads(self.fleet("trace", tid, "--json").stdout)
        self.assertEqual(js["steps"][-1]["body"], "All done.")

    def test_plain_shell_task_has_no_trace_and_still_settles(self):
        script = self.home / "plain.sh"
        script.write_text("echo hi\n")
        tid = int(self.fleet("add", "plain", "--channel", "shell", "--spec", script).stdout)
        self.fleet("run", tid)
        status, code, run_dir = self.settle(tid)
        self.assertEqual((status, code), ("done", 0))
        self.assertIsNone(ft.trace_path(run_dir))
        self.assertIn("no trace", self.fleet("trace", tid).stdout)

    def test_backfill_traces_finished_attempts(self):
        script = self.home / "fake.sh"
        script.write_text("cat >&2 <<'EOF'\n" + CODEX_LOG + "EOF\n")
        tid = int(self.fleet("add", "bf", "--channel", "shell", "--spec", script).stdout)
        self.fleet("run", tid)
        _, _, run_dir = self.settle(tid)
        ft.trace_path(run_dir).unlink()
        out = self.fleet("trace", "--backfill").stdout
        self.assertIn("traced 1 attempt(s)", out)
        self.assertIsNotNone(ft.trace_path(run_dir))
        self.assertIn("traced 0 attempt(s)", self.fleet("trace", "--backfill").stdout)


class SessionKindTests(unittest.TestCase):
    """A channel is matched to its session files by its adapter, not only its name."""

    def setUp(self):
        import importlib.machinery
        import importlib.util
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-trace-", dir="/var/tmp")
        self.addCleanup(self.temp.cleanup)
        home = Path(self.temp.name)
        (home / "channels.json").write_text(json.dumps({"channels": {
            "codex-high": {"adapter": "codex.sh"},
            "magpie-claude": {"adapter": "claude_magpie.sh"},
            "remote-codex": {"adapter": "ssh.sh"},
        }}))
        old = os.environ.get("FLEET_HOME")
        os.environ["FLEET_HOME"] = str(home)
        self.addCleanup(lambda: os.environ.__setitem__("FLEET_HOME", old) if old is not None
                        else os.environ.pop("FLEET_HOME", None))
        loader = importlib.machinery.SourceFileLoader("fleet_under_test", str(FLEET))
        spec = importlib.util.spec_from_loader("fleet_under_test", loader)
        self.m = importlib.util.module_from_spec(spec)
        loader.exec_module(self.m)

    def ok(self, kind, channel):
        return self.m._kind_compatible(kind, {"channel": channel, "family": "x"})

    def test_named_channels_unchanged(self):
        self.assertTrue(self.ok("claude", "claude-p"))
        self.assertTrue(self.ok("rollout", "codex"))
        self.assertFalse(self.ok("rollout", "claude-p"))

    def test_sub_and_gateway_channels_follow_their_adapter(self):
        self.assertTrue(self.ok("rollout", "codex-high"))
        self.assertTrue(self.ok("claude", "magpie-claude"))
        self.assertFalse(self.ok("claude", "codex-high"))
        self.assertFalse(self.ok("rollout", "magpie-claude"))

    def test_remote_and_unknown_channels_match_nothing(self):
        self.assertFalse(self.ok("rollout", "remote-codex"))
        self.assertFalse(self.ok("claude", "no-such-channel"))


class TapResult(unittest.TextTestResult):
    """Stable `ok N - name` lines for tests/run-all.sh."""

    def startTest(self, test):
        super().startTest(test)
        self._failed = False

    def addFailure(self, test, err):
        self._failed = True
        super().addFailure(test, err)

    def addError(self, test, err):
        self._failed = True
        super().addError(test, err)

    def stopTest(self, test):
        print(f"{'not ok' if self._failed else 'ok'} {self.testsRun} - {test.id().rsplit('.', 1)[-1]}")
        super().stopTest(test)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2, resultclass=TapResult).run(
        unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    )
    failed = len(result.failures) + len(result.errors)
    print("---")
    print(f"passed {result.testsRun - failed} / {result.testsRun}")
    raise SystemExit(not result.wasSuccessful())
