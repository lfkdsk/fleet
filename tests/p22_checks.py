#!/usr/bin/env python3
"""P22 acceptance regression using isolated ledgers and real Git repos."""

import importlib.machinery
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import traceback
from types import SimpleNamespace
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "bin"))
loader = importlib.machinery.SourceFileLoader("fleet_p22_test", str(ROOT / "bin/fleet"))
spec = importlib.util.spec_from_loader(loader.name, loader)
api = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = api
loader.exec_module(api)
import fleet_checks as checks


def command(*args, cwd=None, env=None, good=True):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, env=env, text=True,
        capture_output=True,
    )
    if good:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result


class Fixture:
    def __enter__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-p22-")
        self.root = Path(self.temp.name)
        os.environ["FLEET_HOME"] = str(self.root / "fleet-home")
        os.environ.pop("FLEET_TASK_ID", None)
        self.fleet("init")
        self.conn = api.db_connect()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        command("git", "init", "-q", self.repo)
        self.git("config", "user.email", "checks@example.test")
        self.git("config", "user.name", "Fleet checks")
        (self.repo / "leaf.py").write_text("def leaf(): return 42\n")
        (self.repo / "middle.py").write_text(
            "from leaf import leaf\ndef middle(): return 42\n"
        )
        (self.repo / "graph.py").write_text(
            "import ast\n"
            "from pathlib import Path\n"
            "source = Path('middle.py')\n"
            "tree = ast.parse(source.read_text()) if source.exists() else ast.parse('')\n"
            "imports = {alias.asname or alias.name: alias.name for node in tree.body "
            "if isinstance(node, ast.ImportFrom) and node.module == 'leaf' "
            "for alias in node.names}\n"
            "EDGES = [('middle', imports[node.func.id]) for node in ast.walk(tree) "
            "if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) "
            "and node.func.id in imports and Path('leaf.py').exists()]\n"
        )
        (self.repo / "test_graph.py").write_text(
            "from graph import EDGES\n"
            "assert ('middle', 'leaf') in EDGES, 'missing cross-file call edge'\n"
        )
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.goal = int(
            self.fleet("goal", "add", "checks", "--verify-required")
            .stdout.strip()
        )
        worker = self.root / "worker.sh"
        worker.write_text("#!/bin/sh\nprintf 'PASS\\n'\n")
        self.task = int(
            self.fleet(
                "add", "worker", "--goal", self.goal,
                "--channel", "shell", "--cwd", self.repo,
                "--worktree", "--spec", worker,
            ).stdout.strip()
        )
        self.fleet("run", self.task)
        row = self.wait_task(self.task)
        assert row["status"] == "done" and row["exit_code"] == 0, dict(row)
        self.worktree = Path(row["worktree"])
        return self

    def __exit__(self, *_):
        self.conn.close()
        self.temp.cleanup()

    def fleet(self, *args, env=None, good=True):
        return command(ROOT / "bin/fleet", *args, env=env, good=good)

    def git(self, *args, cwd=None):
        return command("git", "-C", cwd or self.repo, *args)

    def wait_task(self, task_id):
        for _ in range(300):
            row = self.conn.execute(
                "SELECT * FROM task WHERE id=?", (task_id,)
            ).fetchone()
            if row["status"] in ("done", "failed", "cancelled"):
                return row
            time.sleep(0.02)
        raise AssertionError(f"task {task_id} did not settle: {dict(row)}")

    def row(self):
        return self.conn.execute(
            "SELECT * FROM task WHERE id=?", (self.task,)
        ).fetchone()

    def configure(self, argv=None, timeout=3, expected=0, required=True):
        argv = argv or ["python3", "-B", "test_graph.py"]
        return self.configure_checks([{
            "id": "graph", "argv": argv, "timeout_s": timeout,
            "expected_exit": expected, "required": required,
        }])

    def configure_checks(self, definitions, allow_long=False):
        # JSON exercises the same canonical checks path without depending on
        # optional PyYAML in the interpreter selected by run-all's matrix.
        body = json.dumps({"checks": definitions}, indent=2)
        path = self.root / "checks.json"
        path.write_text(body)
        # This suite itself runs below a Fleet adapter in production CI.
        # Simulate an independent operator only around the in-process call;
        # case L separately proves the real CLI refuses managed callers.
        parent_chain = checks._parent_chain
        checks._parent_chain = lambda limit=16: [{
            "pid": 123, "command": "/usr/bin/bash",
            "executable": "/usr/bin/bash",
        }]
        try:
            return checks.set_spec(
                self.conn, self.goal, path, self.root / "fleet-home", allow_long
            )
        finally:
            checks._parent_chain = parent_chain

    def run_checks(self, wait=True):
        result = self.fleet("checks", "run", self.task)
        if wait:
            self.wait_checks()
        return result

    def wait_checks(self, timeout=12):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            rows = self.run_rows()
            if rows and all(
                    row["status"] not in ("pending", "running")
                    and (row["status"] == "tampered"
                         or checks._authenticated(
                             row, self.root / "fleet-home"
                         ))
                    for row in rows):
                return rows
            time.sleep(0.02)
        raise AssertionError([dict(row) for row in self.run_rows()])

    def commit_graph(self, fixed):
        (self.worktree / "middle.py").write_text(
            "from leaf import leaf\ndef middle(): return leaf()\n" if fixed else
            "from leaf import leaf\ndef middle(): return 42\n"
        )
        self.git("add", "middle.py", cwd=self.worktree)
        self.git(
            "commit", "-qm", "fix graph" if fixed else "revert graph",
            cwd=self.worktree,
        )

    def verified_dep(self):
        return {"deps": f"{self.task}:verified"}

    def run_rows(self):
        return self.conn.execute(
            "SELECT * FROM check_run WHERE task_id=? ORDER BY started_at,id",
            (self.task,),
        ).fetchall()


def case_a():
    """Worker success is separate from a red mechanical check and repair."""
    with Fixture() as fixture:
        fixture.configure()
        fixture.run_checks()
        row = fixture.run_rows()[0]
        assert fixture.row()["exit_code"] == 0
        assert row["status"] == "failed"
        assert not api.deps_done(fixture.conn, fixture.verified_dep())[0]
        closed = fixture.fleet(
            "goal", "close", fixture.goal, "--force", good=False
        )
        assert closed.returncode != 0 and "required checks" in closed.stderr
        claim = fixture.conn.execute(
            "SELECT * FROM claim WHERE task_id=? AND status='refuted'",
            (fixture.task,),
        ).fetchone()
        assert claim and claim["claim"] == "Mechanical check failed: graph"
        rules = fixture.root / "rules.json"
        rules.write_text(json.dumps([{
            "on": "check_failed", "do": "enqueue_fix",
            "with": {"channel": "shell"},
        }]))
        fixture.fleet(
            "plan", "set", fixture.goal, "--rules", rules,
            "--rationale", "mechanical repair",
        )
        api.evaluate_rules(fixture.conn, api.load_channels())
        fix = fixture.conn.execute(
            "SELECT * FROM task WHERE parent_id=?", (fixture.task,)
        ).fetchone()
        assert fix and fix["base_commit"] == row["commit_sha"]


def case_b():
    """Worker prose/model verdicts cannot forge mechanical evidence."""
    with Fixture() as fixture:
        fixture.configure()
        assert Path(fixture.row()["out_path"]).read_text().strip() == "PASS"
        fixture.conn.execute(
            "UPDATE task SET verdict='pass' WHERE id=?", (fixture.task,)
        )
        fixture.conn.commit()
        assert not checks.passed(fixture.conn, fixture.row())
        assert fixture.conn.execute("SELECT COUNT(*) FROM check_run").fetchone()[0] == 0
        worker_env = dict(os.environ, FLEET_TASK_ID=str(fixture.task))
        assert fixture.fleet(
            "checks", "set", fixture.goal, "--file",
            fixture.root / "checks.yaml", env=worker_env, good=False,
        ).returncode != 0
        assert fixture.fleet(
            "checks", "run", fixture.task, env=worker_env, good=False
        ).returncode != 0
        fixture.run_checks()
        failed_claim = fixture.conn.execute(
            "SELECT id FROM claim WHERE task_id=? AND status='refuted'",
            (fixture.task,),
        ).fetchone()
        assert failed_claim
        fixture.fleet(
            "claim", "verify", failed_claim["id"], "--status", "confirmed"
        )
        assert not checks.passed(fixture.conn, fixture.row())
        marker = fixture.root / "shell-injection"
        literal = f"$(touch {marker})"
        fixture.configure([
            "python3", "-c",
            "import sys; assert sys.argv[1].startswith('$(touch ')", literal,
        ])
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row()) and not marker.exists()
        stored = json.loads(fixture.run_rows()[-1]["argv"])
        assert stored[-1] == literal


def case_c():
    """Moving the delivery branch invalidates green evidence."""
    with Fixture() as fixture:
        fixture.configure()
        fixture.commit_graph(True)
        fixture.run_checks()
        old = fixture.run_rows()[0]["commit_sha"]
        assert api.deps_done(fixture.conn, fixture.verified_dep())[0]
        fixture.commit_graph(False)
        assert checks.delivery(fixture.row()) != old
        assert not api.deps_done(fixture.conn, fixture.verified_dep())[0]
        assert fixture.fleet(
            "goal", "close", fixture.goal, "--force", good=False
        ).returncode != 0


def case_d():
    """Changing or restoring configuration never resurrects old evidence."""
    with Fixture() as fixture:
        first = fixture.configure()
        fixture.commit_graph(True)
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row())
        second = fixture.configure(["sh", "-c", "exit 1"])
        assert second != first and not checks.passed(fixture.conn, fixture.row())
        fixture.run_checks()
        third = fixture.configure()
        assert len({first, second, third}) == 3
        assert not checks.passed(fixture.conn, fixture.row())
        assert [row["status"] for row in fixture.run_rows()] == [
            "passed", "failed"
        ]


def case_e():
    """Timeout settles the run and kills the full child process group."""
    with Fixture() as fixture:
        pidfile = fixture.root / "child.pid"
        fixture.configure(
            ["sh", "-c", f"sleep 90 & echo $! > {pidfile}; wait"],
            timeout=0.2,
        )
        fixture.run_checks()
        row = fixture.run_rows()[0]
        assert row["status"] == "failed" and row["timed_out"] == 1
        assert row["ended_at"] and row["stdout_hash"] and row["stderr_hash"]
        child = int(pidfile.read_text())
        stat = Path(f"/proc/{child}/stat")
        assert not stat.exists() or stat.read_text().split()[2] == "Z"
        assert not fixture.conn.execute(
            "SELECT 1 FROM check_run WHERE status='running'"
        ).fetchone()


def case_f():
    """Repeated daemon rounds do not duplicate one check identity."""
    with Fixture() as fixture:
        fixture.configure()
        fixture.commit_graph(True)
        fixture.fleet("daemon", "run", "--once")
        fixture.fleet("daemon", "run", "--once")
        fixture.wait_checks()
        assert len(fixture.run_rows()) == 1
        assert checks.passed(fixture.conn, fixture.row())
        try:
            fixture.conn.execute(
                "UPDATE check_run SET status='failed' WHERE task_id=?",
                (fixture.task,),
            )
            raise AssertionError("terminal result was overwritten")
        except sqlite3.IntegrityError:
            fixture.conn.rollback()
        fixture.fleet("goal", "close", fixture.goal)


def case_g():
    """A killed runner is explainable on restart and never counts green."""
    with Fixture() as fixture:
        fixture.configure(["sleep", "90"])
        proc = subprocess.Popen(
            [str(ROOT / "bin/fleet"), "checks", "run", str(fixture.task)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        try:
            row = None
            for _ in range(300):
                row = fixture.conn.execute(
                    "SELECT * FROM check_run WHERE task_id=?", (fixture.task,)
                ).fetchone()
                if row and row["pgid"]:
                    break
                time.sleep(0.02)
            assert row and row["status"] == "running" and row["pgid"]
            proc.wait()
            os.kill(row["runner_pid"], signal.SIGKILL)
            for _ in range(300):
                if not checks._process_matches(
                        row["runner_pid"], row["runner_starttime"], live=True):
                    break
                time.sleep(0.02)
            assert not checks.passed(fixture.conn, fixture.row())
            fixture.fleet("daemon", "run", "--once")
            row = fixture.run_rows()[0]
            assert row["status"] == "infrastructure"
            assert "interrupted" in row["detail"]
            assert len(fixture.run_rows()) == 1
            assert fixture.conn.execute(
                "SELECT COUNT(*) FROM decision WHERE task_id=? AND needs_user=1",
                (fixture.task,),
            ).fetchone()[0] == 1
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()


def case_h():
    """Cross-file call graph goes red, green after fix, red after revert."""
    with Fixture() as fixture:
        spec_hash = fixture.configure()
        fixture.run_checks()
        fixture.commit_graph(True)
        fixture.run_checks()
        fixture.commit_graph(False)
        fixture.run_checks()
        fixture.commit_graph(True)
        fixture.run_checks()
        (fixture.worktree / "leaf.py").unlink()
        fixture.git("add", "leaf.py", cwd=fixture.worktree)
        fixture.git("commit", "-qm", "remove leaf", cwd=fixture.worktree)
        fixture.run_checks()
        (fixture.worktree / "leaf.py").write_text("def leaf(): return 42\n")
        (fixture.worktree / "middle.py").unlink()
        fixture.git("add", "leaf.py", "middle.py", cwd=fixture.worktree)
        fixture.git("commit", "-qm", "remove middle", cwd=fixture.worktree)
        fixture.run_checks()
        rows = fixture.run_rows()
        assert [row["status"] for row in rows] == [
            "failed", "passed", "failed", "passed", "failed", "failed"
        ]
        assert {row["spec_hash"] for row in rows} == {spec_hash}
        assert len({row["commit_sha"] for row in rows}) == 6
        for row in rows:
            assert row["cwd"] != str(fixture.worktree)
            assert checks.digest(Path(row["stdout_path"]).read_bytes()) == row["stdout_hash"]
            assert checks.digest(Path(row["stderr_path"]).read_bytes()) == row["stderr_hash"]


def case_i():
    """Old ledgers migrate, plain deps stay plain, infra blocks separately."""
    with Fixture() as fixture:
        assert api.deps_done(fixture.conn, {"deps": str(fixture.task)})[0]
        downstream = int(fixture.fleet(
            "add", "verified downstream", "--channel", "shell",
            "--cwd", fixture.repo, "--dep", f"{fixture.task}:verified"
        ).stdout.strip())
        assert fixture.conn.execute(
            "SELECT deps FROM task WHERE id=?", (downstream,)
        ).fetchone()[0] == f"{fixture.task}:verified"
        fixture.conn.execute("DROP TABLE check_run")
        fixture.conn.execute("DROP TABLE check_spec")
        fixture.conn.execute("DROP TRIGGER goal_verify_required_guard")
        fixture.conn.execute("DROP TRIGGER goal_verify_required_audit")
        fixture.conn.execute("ALTER TABLE goal DROP COLUMN verify_required")
        fixture.conn.execute("DELETE FROM meta WHERE k LIKE 'checks.%'")
        fixture.conn.commit()
        fixture.fleet("init")
        fixture.fleet("init")
        assert fixture.conn.execute(
            "SELECT verify_required FROM goal WHERE id=?", (fixture.goal,)
        ).fetchone()[0] == 0
        fixture.configure(["p22-command-that-does-not-exist"])
        fixture.run_checks()
        assert fixture.run_rows()[-1]["status"] == "infrastructure"
        decision = fixture.conn.execute(
            "SELECT * FROM decision WHERE task_id=?", (fixture.task,)
        ).fetchone()
        assert decision and decision["needs_user"] == 1
        assert decision["verdict"] == "conflict"
        assert fixture.conn.execute(
            "SELECT COUNT(*) FROM claim WHERE task_id=?", (fixture.task,)
        ).fetchone()[0] == 0
        for exit_code in (126, 127):
            fixture.configure(["sh", "-c", f"exit {exit_code}"])
            fixture.run_checks()
            assert fixture.run_rows()[-1]["status"] == "infrastructure"
        (fixture.worktree / "dirty").write_text("untracked\n")
        before = len(fixture.run_rows())
        fixture.configure(["true"])
        fixture.run_checks()
        assert len(fixture.run_rows()) == before
        assert not checks.passed(fixture.conn, fixture.row())
        (fixture.worktree / "dirty").unlink()
        fixture.worktree.rename(fixture.worktree.with_name("missing"))
        assert not checks.passed(fixture.conn, fixture.row())


def case_j():
    """Commander review_ready waits until verify-required is truly green."""
    with Fixture() as fixture:
        fixture.configure()
        driver = fixture.root / "commander.sh"
        driver.write_text(
            (ROOT / "tests/p20_driver.sh").read_text().replace(
                "__P20_MODE__", "plain"
            )
        )
        driver.chmod(0o755)
        os.environ["FLEET_COMMANDER_SHELL_SCRIPT"] = str(driver)
        try:
            fixture.fleet(
                "autonomy", "enable", fixture.goal, "--channel", "shell",
                "--cooldown", 0,
            )
            fixture.fleet("daemon", "run", "--once")
            commander = None
            for _ in range(300):
                commander = fixture.conn.execute(
                    "SELECT * FROM task WHERE goal_id=? AND role='commander' "
                    "ORDER BY id DESC LIMIT 1", (fixture.goal,),
                ).fetchone()
                if commander and commander["status"] in ("done", "failed"):
                    break
                time.sleep(0.02)
            assert commander and commander["status"] == "done", (
                dict(commander) if commander else None
            )
            state = json.loads(fixture.conn.execute(
                "SELECT autonomy FROM goal WHERE id=?", (fixture.goal,)
            ).fetchone()[0])
            assert state["last_next_wake"] == "waiting_for_checks", state
            event = fixture.conn.execute(
                "SELECT payload FROM event WHERE kind='commander.round' "
                "AND goal_id=? ORDER BY id DESC LIMIT 1", (fixture.goal,),
            ).fetchone()
            assert json.loads(event[0])["next_wake"] == "waiting_for_checks"
            fixture.commit_graph(True)
            fixture.run_checks()
            assert checks.gate_reason(
                fixture.conn, fixture.goal, "review_ready"
            ) == "review_ready"
            fixture.fleet("daemon", "run", "--once")
            next_commander = fixture.conn.execute(
                "SELECT * FROM task WHERE goal_id=? AND role='commander' "
                "AND id>? ORDER BY id DESC LIMIT 1",
                (fixture.goal, commander["id"]),
            ).fetchone()
            assert next_commander, "green checks did not autonomously wake a round"
            fixture.wait_task(next_commander["id"])
            passed_event = fixture.conn.execute(
                "SELECT goal_id FROM event WHERE kind='check.passed' "
                "AND task_id=? ORDER BY id DESC LIMIT 1", (fixture.task,),
            ).fetchone()
            assert passed_event and passed_event["goal_id"] == fixture.goal
        finally:
            os.environ.pop("FLEET_COMMANDER_SHELL_SCRIPT", None)


def case_k():
    """Forged terminal rows fail authentication and cannot skip honest."""
    with Fixture() as fixture:
        marker = fixture.root / "honest-ran"
        db_path = fixture.root / "fleet-home" / "fleet.db"
        evil = fixture.worktree / "evil.py"
        evil.write_text(
            "import os,sqlite3,time\n"
            "assert not any(k.startswith(('FLEET_','ANTHROPIC_','CLAUDE_')) "
            "for k in os.environ)\n"
            "assert os.environ.get('PATH') and os.environ.get('HOME')\n"
            f"db={str(db_path)!r}\n"
            "for attempt in range(100):\n"
            " try:\n"
            "  c=sqlite3.connect(db,timeout=.1)\n"
            "  me=c.execute(\"SELECT task_id,attempt,commit_sha,spec_hash "
            "FROM check_run WHERE check_id='evil' AND cwd=?\","
            "(os.getcwd(),)).fetchone()\n"
            "  assert me and c.execute(\"SELECT COUNT(*) FROM check_run "
            "WHERE task_id=? AND attempt=? AND commit_sha=? AND spec_hash=?\","
            "me).fetchone()[0] == 2\n"
            "  try:\n"
            "   c.execute(\"INSERT INTO check_run(id,task_id,attempt,commit_sha,"
            "spec_hash,check_id,argv,cwd,started_at,status,stdout_path,stderr_path) "
            "VALUES('forged-row',?,?,?,?,?,'[]','.',?,'passed','.','.')\","
            "(*me,'honest',time.time()))\n"
            "   raise AssertionError('missing honest row was insertable')\n"
            "  except sqlite3.IntegrityError: pass\n"
            "  c.execute(\"UPDATE check_run SET status='passed',"
            "runner_token='forged',ended_at=? WHERE check_id='honest' "
            "AND status IN ('pending','running')\",(time.time(),))\n"
            "  c.commit(); break\n"
            " except sqlite3.OperationalError: time.sleep(.02)\n"
            "print(os.getcwd())\n"
        )
        (fixture.worktree / "honest.py").write_text(
            "from pathlib import Path\nimport time\n"
            f"Path({str(marker)!r}).write_text('ran')\n"
            "time.sleep(.5)\nraise SystemExit(1)\n"
        )
        fixture.git("add", "evil.py", "honest.py", cwd=fixture.worktree)
        fixture.git("commit", "-qm", "evil and honest checks", cwd=fixture.worktree)
        fixture.configure_checks([
            {"id": "evil", "argv": ["python3", "evil.py"],
             "timeout_s": 3, "expected_exit": 0, "required": True},
            {"id": "honest", "argv": ["python3", "honest.py"],
             "timeout_s": 3, "expected_exit": 0, "required": True},
        ])
        fixture.run_checks()
        rows = {row["check_id"]: row for row in fixture.run_rows()}
        assert marker.read_text() == "ran", "forged row skipped the honest command"
        assert rows["evil"]["status"] == "passed"
        assert rows["honest"]["status"] == "tampered", {
            key: dict(value) for key, value in rows.items()
        }
        assert not checks.passed(fixture.conn, fixture.row())
        assert fixture.conn.execute(
            "SELECT COUNT(*) FROM event WHERE kind='check.tampered' "
            "AND task_id=?", (fixture.task,),
        ).fetchone()[0] == 1
        assert fixture.conn.execute(
            "SELECT 1 FROM decision WHERE task_id=? AND needs_user=1 "
            "AND (question LIKE '%authentication%' "
            "OR question LIKE '%token%' OR question LIKE '%HMAC%')",
            (fixture.task,),
        ).fetchone()
        assert Path(rows["evil"]["stdout_path"]).read_text().strip() == rows["evil"]["cwd"]
        # Predicate-only forgery: even a complete-looking set of terminal rows
        # for the current commit/spec is foreign without matching token hashes.
        foreign_spec = fixture.configure_checks([
            {"id": "evil", "argv": ["true"], "timeout_s": 3,
             "expected_exit": 0, "required": True},
            {"id": "honest", "argv": ["true"], "timeout_s": 3,
             "expected_exit": 0, "required": True},
        ])
        commit = checks._delivery_tip(fixture.row())
        for check_id in ("evil", "honest"):
            fixture.conn.execute(
                "INSERT INTO check_run(id,task_id,attempt,commit_sha,spec_hash,"
                "check_id,argv,cwd,started_at,ended_at,status,stdout_path,"
                "stderr_path,runner_token_hash,runner_token,delivery_clean) "
                "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)",
                (uuid.uuid4().hex, fixture.task, fixture.row()["attempt"], commit,
                 foreign_spec, check_id, '[\"true\"]', str(fixture.root),
                 time.time() + 1, time.time() + 1, "passed",
                 str(fixture.root / "fake-out"), str(fixture.root / "fake-err"),
                 checks.digest(b"real token"), "forged token"),
            )
        fixture.conn.commit()
        assert not checks.passed(fixture.conn, fixture.row())


def case_l():
    """Managed callers cannot set specs; long timeouts need opt-in."""
    with Fixture() as fixture:
        fixture.configure()
        audit = fixture.conn.execute(
            "SELECT payload FROM event WHERE kind='checks.set' AND goal_id=? "
            "ORDER BY id DESC LIMIT 1", (fixture.goal,),
        ).fetchone()
        caller = json.loads(audit["payload"])["caller"]
        assert caller["cwd"] and isinstance(caller["ppid_chain"], list)
        assert caller["ppid_chain"] and all(
                   set(entry) == {"pid", "executable"}
                   for entry in caller["ppid_chain"])
        managed = fixture.root / "fleet-home" / "worktrees" / "caller"
        managed.mkdir(parents=True)
        old_cwd = Path.cwd()
        old_task = os.environ.pop("FLEET_TASK_ID", None)
        parent_chain = checks._parent_chain
        checks._parent_chain = lambda limit=16: []
        try:
            os.chdir(managed)
            denied_env = dict(os.environ)
            denied_env.pop("FLEET_TASK_ID", None)
            denied = command(
                ROOT / "bin/fleet", "checks", "set", fixture.goal,
                "--file", fixture.root / "checks.yaml", cwd=managed,
                env=denied_env, good=False,
            )
            assert denied.returncode != 0 and "operator operation" in denied.stderr
            try:
                checks.set_spec(
                    fixture.conn, fixture.goal, fixture.root / "checks.yaml",
                    fixture.root / "fleet-home",
                )
                raise AssertionError("managed cwd changed checks")
            except ValueError as exc:
                assert "operator operation" in str(exc)
        finally:
            os.chdir(old_cwd)
            checks._parent_chain = parent_chain
            if old_task is not None:
                os.environ["FLEET_TASK_ID"] = old_task
        long = [{"id": "long", "argv": ["true"], "timeout_s": 3601,
                 "expected_exit": 0, "required": True}]
        try:
            fixture.configure_checks(long)
            raise AssertionError("long timeout accepted without opt-in")
        except ValueError as exc:
            assert "--allow-long" in str(exc)
        fixture.configure_checks(long, allow_long=True)


def case_m():
    """A real eight-second check never blocks a daemon poll."""
    with Fixture() as fixture:
        fixture.configure(["sleep", "8"], timeout=10)
        started = time.monotonic()
        fixture.fleet("daemon", "run", "--once")
        elapsed = time.monotonic() - started
        assert elapsed < 1, elapsed
        assert fixture.run_rows()[0]["status"] in ("pending", "running")
        fixture.wait_checks(timeout=12)
        fixture.fleet("daemon", "run", "--once")
        assert checks.passed(fixture.conn, fixture.row())


def case_n():
    """Authenticated green evidence survives delivery-worktree pruning."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row())
        fixture.git("worktree", "remove", "--force", fixture.worktree)
        assert not fixture.worktree.exists()
        assert checks.passed(fixture.conn, fixture.row())
        closed = fixture.fleet("goal", "close", fixture.goal)
        assert "done" in closed.stdout


def case_o():
    """Recovery never signals a recycled process-group identity."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        task = fixture.row()
        spec = checks.current(fixture.conn, fixture.goal)
        prepared = checks._prepare_rows(
            fixture.conn, api, task, spec, checks.delivery(task)
        )
        run_id, _ = prepared[0]
        actual = checks._proc_starttime(os.getpid())
        fixture.conn.execute(
            "UPDATE check_run SET status='running',pgid=?,pgid_starttime=?,"
            "runner_pid=NULL,runner_starttime=NULL WHERE id=?",
            (os.getpid(), actual + 1, run_id),
        )
        fixture.conn.commit()
        killed = []
        original = checks.os.killpg
        checks.os.killpg = lambda pgid, sig: killed.append((pgid, sig))
        try:
            checks._recover_running(fixture.conn, api)
        finally:
            checks.os.killpg = original
        row = fixture.run_rows()[0]
        assert row["status"] == "infrastructure"
        assert "no longer matches (not killed)" in row["detail"]
        assert killed == []


def case_p():
    """verify_required changes only through the audited goal command."""
    with Fixture() as fixture:
        assert fixture.conn.execute(
            "SELECT verify_required FROM goal WHERE id=?", (fixture.goal,)
        ).fetchone()[0] == 1
        try:
            fixture.conn.execute(
                "UPDATE goal SET verify_required=0 WHERE id=?", (fixture.goal,)
            )
            raise AssertionError("direct SQL disabled the verification gate")
        except sqlite3.DatabaseError as exc:
            fixture.conn.rollback()
            assert "verify-required" in str(exc) or "function" in str(exc)
        parent_chain = checks._parent_chain
        checks._parent_chain = lambda limit=16: []
        try:
            api.cmd_goal_verify_required(
                SimpleNamespace(id=fixture.goal, state="off")
            )
            api.cmd_goal_verify_required(
                SimpleNamespace(id=fixture.goal, state="on")
            )
        finally:
            checks._parent_chain = parent_chain
        events = fixture.conn.execute(
            "SELECT payload FROM event WHERE kind='goal.verify_changed' "
            "AND goal_id=? ORDER BY id", (fixture.goal,),
        ).fetchall()
        assert [json.loads(row[0])["to"] for row in events] == [False, True]


def case_q():
    """Review-473 trigger deletion/row forgery latches fail-closed."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row())
        token_path = fixture.root / "fleet-home" / ".runner-token"
        assert token_path.stat().st_mode & 0o777 == 0o600
        token_before = token_path.read_bytes()
        fixture.fleet("daemon", "run", "--once")
        assert token_path.read_bytes() != token_before
        assert token_path.stat().st_mode & 0o777 == 0o600
        assert checks.passed(fixture.conn, fixture.row())
        row = dict(fixture.run_rows()[0])
        columns = [item[1] for item in fixture.conn.execute(
            "PRAGMA table_info(check_run)"
        )]
        for name in checks.LEGACY_CHECK_TRIGGER_NAMES:
            fixture.conn.execute(f'DROP TRIGGER IF EXISTS "{name}"')
        fixture.conn.execute("DELETE FROM check_run WHERE id=?", (row["id"],))
        assert not checks.passed(fixture.conn, fixture.row())
        forged_token = "attacker-token"
        forged = dict(row)
        forged.update({
            "id": "forged", "status": "passed", "exit_code": 0,
            "runner_token": forged_token,
            "runner_token_hash": hashlib.sha256(
                forged_token.encode()
            ).hexdigest(),
            "delivery_clean": 1, "detail": None,
        })
        fixture.conn.execute(
            f"INSERT INTO check_run({','.join(columns)}) "
            f"VALUES({','.join('?' * len(columns))})",
            [forged[column] for column in columns],
        )
        fixture.conn.commit()
        fixture.fleet("init")
        fixture.fleet("init")
        assert not checks.passed(fixture.conn, fixture.row())
        tampered = fixture.conn.execute(
            "SELECT payload FROM event WHERE kind='check.tampered' "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()
        assert tampered and json.loads(tampered[0])["reason"] == "triggers"
        assert fixture.conn.execute(
            "SELECT 1 FROM decision WHERE needs_user=1 AND resolved_at IS NULL "
            "AND question LIKE '%triggers%'"
        ).fetchone()
        assert fixture.conn.execute(
            "SELECT COUNT(*) FROM event WHERE kind='check.tampered' "
            "AND json_extract(payload,'$.reason')='triggers'"
        ).fetchone()[0] == 1
        closed = fixture.fleet(
            "goal", "close", fixture.goal, "--force", good=False
        )
        assert closed.returncode == 1 and "required checks" in closed.stderr
        parent_chain = checks._parent_chain
        checks._parent_chain = lambda limit=16: []
        try:
            checks.reseal(fixture.conn, api)
        finally:
            checks._parent_chain = parent_chain
        assert fixture.conn.execute(
            "SELECT 1 FROM event WHERE kind='checks.resealed'"
        ).fetchone()
        assert checks.trigger_set_intact(fixture.conn)
        # Reseal repairs/lifts the global trigger latch, but the self-consistent
        # SHA-256 pair is still not a valid key-backed HMAC proof.
        assert not checks.passed(fixture.conn, fixture.row())
        fixture.conn.execute("DROP TRIGGER check_run_no_delete")
        fixture.conn.execute(
            "CREATE TRIGGER check_run_no_delete BEFORE DELETE ON check_run "
            "BEGIN SELECT RAISE(ABORT, 'changed trigger'); END"
        )
        fixture.conn.commit()
        fixture.fleet("daemon", "run", "--once")
        changed = fixture.conn.execute(
            "SELECT payload FROM event WHERE kind='check.tampered' "
            "AND json_extract(payload,'$.reason')='triggers' "
            "ORDER BY id DESC LIMIT 1"
        ).fetchone()
        assert "check_run_no_delete" in json.loads(changed[0])["changed"]


def case_r():
    """A red verdict is attributed to the attempt the run judged, not to
    whatever attempt the task has moved on to by the time it is recorded."""
    with Fixture() as fixture:
        fixture.configure()
        fixture.run_checks()
        row = fixture.run_rows()[0]
        assert row["status"] == "failed"
        judged = fixture.conn.execute(
            "SELECT attempt_id FROM attempt WHERE task_id=? AND generation=?",
            (fixture.task, row["attempt"]),
        ).fetchone()[0]
        # Simulate a retry that happened after the run started: generation+1
        # is now the task's current attempt.
        newer = uuid.uuid4().hex
        fixture.conn.execute(
            "INSERT INTO attempt(attempt_id,task_id,generation,status,run_dir,"
            "out_path,log_path,started_at) VALUES(?,?,?,?,?,?,?,?)",
            (newer, fixture.task, row["attempt"] + 1, "running", "/nonexistent",
             "/nonexistent/out.md", "/nonexistent/log.txt", api.now()),
        )
        fixture.conn.execute(
            "UPDATE task SET attempt_id=?, attempt=? WHERE id=?",
            (newer, row["attempt"] + 1, fixture.task),
        )
        fixture.conn.commit()
        before = fixture.conn.execute(
            "SELECT COUNT(*) FROM claim WHERE task_id=?", (fixture.task,)
        ).fetchone()[0]
        checks._emit_terminal(fixture.conn, api, row, "failed", 1, False, None)
        fixture.conn.commit()
        rows = fixture.conn.execute(
            "SELECT attempt_id FROM claim WHERE task_id=? AND status='refuted' "
            "ORDER BY id", (fixture.task,),
        ).fetchall()
        assert len(rows) == before + 1
        assert rows[-1]["attempt_id"] == judged != newer
        # And a retry-era rule evaluation does not consume it as a refutation
        # of the newer attempt.
        rules = fixture.root / "rules.json"
        rules.write_text(json.dumps([{
            "on": "check_failed", "do": "enqueue_fix",
            "with": {"channel": "shell"},
        }]))
        fixture.fleet(
            "plan", "set", fixture.goal, "--rules", rules,
            "--rationale", "attribution",
        )
        api.evaluate_rules(fixture.conn, api.load_channels())
        fix = fixture.conn.execute(
            "SELECT * FROM task WHERE parent_id=?", (fixture.task,)
        ).fetchone()
        assert fix is None


def _assert_trigger_tamper_blocks_close(fixture):
    tampered = fixture.conn.execute(
        "SELECT payload FROM event WHERE kind='check.tampered' "
        "AND task_id IS NULL ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert tampered and json.loads(tampered[0])["reason"] == "triggers"
    assert fixture.conn.execute(
        "SELECT 1 FROM decision WHERE needs_user=1 AND resolved_at IS NULL "
        "AND question LIKE '%triggers%'"
    ).fetchone()
    closed = fixture.fleet(
        "goal", "close", fixture.goal, "--force", good=False
    )
    assert closed.returncode == 1 and "required checks" in closed.stderr
    return json.loads(tampered[0])


def _replace_check_rows(fixture, rows):
    columns = [item[1] for item in fixture.conn.execute(
        "PRAGMA table_info(check_run)"
    )]
    fixture.conn.execute("DELETE FROM check_run")
    for row in rows:
        fixture.conn.execute(
            f"INSERT INTO check_run({','.join(columns)}) "
            f"VALUES({','.join('?' * len(columns))})",
            [row[column] for column in columns],
        )


def _drop_and_restore_expected(fixture, operation):
    expected = checks._expected_triggers()
    for name in expected:
        fixture.conn.execute(f'DROP TRIGGER IF EXISTS "{name}"')
    operation()
    for sql in expected.values():
        fixture.conn.execute(sql)
    fixture.conn.commit()


def case_s():
    """Restored triggers cannot hide a forged green, and the event latch
    survives deletion of its old meta cache until an audited reseal."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row())
        witness = fixture.conn.execute(
            "SELECT payload FROM event WHERE kind='check.passed_witness' "
            "AND task_id=?", (fixture.task,),
        ).fetchone()
        assert witness
        witness = json.loads(witness[0])
        assert witness["runner_nonce"] and witness["runner_proof"].startswith(
            checks.RUNNER_PROOF_PREFIX + ":"
        )
        original = dict(fixture.run_rows()[0])
        keyring = json.loads(
            (fixture.root / "fleet-home" / ".runner-token").read_text()
        )
        key_id = keyring["current"]
        nonce = "same-uid-forgery"
        forged = dict(original)
        forged.update({
            "id": "forged-green", "runner_token": nonce,
            "runner_token_hash": checks._runner_proof(
                key_id, keyring["keys"][key_id], nonce,
                original["task_id"], original["attempt"],
                original["commit_sha"], original["check_id"],
            ),
        })
        _drop_and_restore_expected(
            fixture, lambda: _replace_check_rows(fixture, [forged])
        )
        assert not checks.passed(fixture.conn, fixture.row())
        fixture.fleet("daemon", "run", "--once")
        payload = _assert_trigger_tamper_blocks_close(fixture)
        assert payload["unaudited_passed"] == ["forged-green"]

        # Repair the row/trigger surface, then delete the old meta cache. The
        # append-only event is now the only latch source and must still win.
        _drop_and_restore_expected(
            fixture, lambda: _replace_check_rows(fixture, [original])
        )
        fixture.conn.execute(
            "DELETE FROM meta WHERE k=?", (checks.TRIGGER_TAMPER_KEY,)
        )
        fixture.conn.commit()
        assert checks._unaudited_passed_runs(fixture.conn) == []
        assert checks._trigger_diff(fixture.conn)[3:] == ([], [], [])
        # Event writers that do not register Fleet's goal-gate UDF must remain
        # able to append unrelated events. The reseal guard uses a transient
        # transaction marker rather than imposing a UDF on every event insert.
        raw = sqlite3.connect(
            fixture.root / "fleet-home" / "fleet.db", timeout=15
        )
        try:
            raw.execute(
                "INSERT INTO event(ts,kind,payload) VALUES(?,?,?)",
                (int(time.time()), "test.unrelated", "{}"),
            )
            raw.commit()
            try:
                raw.execute(
                    "INSERT INTO check_reseal_permit(id,nonce) "
                    "VALUES(1,'forged')"
                )
                raise AssertionError("raw SQL minted a reseal permit")
            except sqlite3.DatabaseError as exc:
                raw.rollback()
                assert "fleet_verify_authorized" in str(exc)
        finally:
            raw.close()
        try:
            fixture.conn.execute(
                "DELETE FROM event WHERE kind='check.tampered' "
                "AND task_id IS NULL"
            )
            raise AssertionError("append-only trigger tamper event was deleted")
        except sqlite3.DatabaseError as exc:
            fixture.conn.rollback()
            assert "append-only" in str(exc)
        assert not checks.trigger_set_intact(fixture.conn)
        try:
            api.log_event(fixture.conn, "checks.resealed", payload={})
            raise AssertionError("forged reseal event cleared the latch")
        except sqlite3.DatabaseError as exc:
            fixture.conn.rollback()
            assert "checks reseal" in str(exc)
        fixture.fleet("daemon", "run", "--once")
        _assert_trigger_tamper_blocks_close(fixture)
        parent_chain = checks._parent_chain
        checks._parent_chain = lambda limit=16: []
        try:
            checks.reseal(fixture.conn, api)
        finally:
            checks._parent_chain = parent_chain
        assert checks.trigger_set_intact(fixture.conn)


def case_t():
    """Every trigger on a protected table is compared, regardless of name."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row())
        fixture.conn.execute(
            "CREATE TRIGGER zz_backdoor AFTER INSERT ON check_run "
            "BEGIN SELECT 1; END"
        )
        fixture.conn.commit()
        fixture.fleet("daemon", "run", "--once")
        payload = _assert_trigger_tamper_blocks_close(fixture)
        assert payload["unexpected"] == ["zz_backdoor"]


def case_u():
    """Legacy-set init amnesty applies only before any seal/tamper history."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row())
        assert fixture.conn.execute(
            "SELECT 1 FROM event WHERE kind='checks.sealed'"
        ).fetchone()
        for name in sorted(
                set(checks._expected_triggers())
                - checks.LEGACY_CHECK_TRIGGER_NAMES):
            fixture.conn.execute(f'DROP TRIGGER IF EXISTS "{name}"')
        fixture.conn.execute("DELETE FROM meta WHERE k LIKE 'checks.%'")
        fixture.conn.commit()
        fixture.fleet("init")
        fixture.fleet("daemon", "run", "--once")
        payload = _assert_trigger_tamper_blocks_close(fixture)
        assert set(payload["missing"]) == (
            set(checks._expected_triggers())
            - checks.LEGACY_CHECK_TRIGGER_NAMES
        )


def case_v():
    """A genuine sealed B3 ledger upgrades and backfills only authenticated
    green evidence; the new audit-trigger set is not mistaken for tampering."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        fixture.run_checks()
        assert checks.passed(fixture.conn, fixture.row())
        for name in (
                "event_check_audit_no_update",
                "event_check_audit_no_delete",
                "event_checks_resealed_guard"):
            fixture.conn.execute(f'DROP TRIGGER IF EXISTS "{name}"')
        fixture.conn.execute(
            "DELETE FROM event WHERE kind IN ('checks.sealed',"
            "'check.passed_witness')"
        )
        for name in sorted(
                set(checks._expected_triggers()) - checks.B3_CHECK_TRIGGER_NAMES):
            fixture.conn.execute(f'DROP TRIGGER IF EXISTS "{name}"')
        fixture.conn.execute(
            "INSERT INTO meta(k,v) VALUES(?,?) "
            "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
            (checks.TRIGGER_SEAL_KEY, checks._trigger_hash(
                {name: checks._expected_triggers()[name]
                 for name in checks.B3_CHECK_TRIGGER_NAMES}
            )),
        )
        fixture.conn.commit()
        fixture.fleet("init")
        assert not fixture.conn.execute(
            "SELECT 1 FROM event WHERE kind='check.tampered' "
            "AND task_id IS NULL"
        ).fetchone()
        witness = fixture.conn.execute(
            "SELECT payload FROM event WHERE kind='check.passed_witness' "
            "AND task_id=?", (fixture.task,),
        ).fetchone()
        assert witness and json.loads(witness[0])["migrated"] is True
        assert checks.trigger_set_intact(fixture.conn)
        assert checks.passed(fixture.conn, fixture.row())


def case_w():
    """A witness-forging trigger on any table is unexpected and latches."""
    with Fixture() as fixture:
        fixture.configure(["sh", "-c", "exit 1"])
        fixture.run_checks()
        row = fixture.run_rows()[0]
        assert row["status"] == "failed"
        keyring = json.loads(
            (fixture.root / "fleet-home" / ".runner-token").read_text()
        )
        key_id = keyring["current"]
        nonce = "same-uid-persistent-forgery"
        proof = checks._runner_proof(
            key_id, keyring["keys"][key_id], nonce, row["task_id"],
            row["attempt"], row["commit_sha"], row["check_id"],
        )
        payload = json.dumps({
            "run": row["id"], "check_id": row["check_id"],
            "commit": row["commit_sha"], "spec_hash": row["spec_hash"],
            "exit_code": 0, "timed_out": False,
            "runner_nonce": nonce, "runner_proof": proof,
        }).replace("'", "''")
        raw = sqlite3.connect(fixture.root / "fleet-home" / "fleet.db")
        try:
            raw.execute(
                "CREATE TRIGGER zz_mint AFTER UPDATE ON attempt BEGIN "
                "INSERT INTO event(ts,task_id,goal_id,kind,payload) "
                f"SELECT unixepoch(),{row['task_id']},{fixture.goal},"
                f"'check.passed_witness','{payload}' "
                "WHERE NOT EXISTS (SELECT 1 FROM event "
                "WHERE kind='check.passed_witness'); END"
            )
            expected = checks._expected_triggers()
            for name in expected:
                raw.execute(f'DROP TRIGGER IF EXISTS \"{name}\"')
            raw.execute(
                "UPDATE check_run SET status='passed',exit_code=0,"
                "runner_token=?,runner_token_hash=? WHERE id=?",
                (nonce, proof, row["id"]),
            )
            for sql in expected.values():
                raw.execute(sql)
            raw.commit()
            # The attacker's session leaves the trigger dormant. A normal
            # Fleet-owned write later fires it and supplies the forged audit.
            raw.execute("UPDATE attempt SET status=status")
            raw.commit()
        finally:
            raw.close()
        assert fixture.conn.execute(
            "SELECT 1 FROM event WHERE kind='check.passed_witness'"
        ).fetchone()
        fixture.fleet("daemon", "run", "--once")
        payload = _assert_trigger_tamper_blocks_close(fixture)
        assert payload["unexpected"] == ["zz_mint"]
        assert not checks.passed(fixture.conn, fixture.row())
        assert fixture.conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type='trigger' "
            "AND name='zz_mint'"
        ).fetchone()


def case_x():
    """A complete B4 ledger, archive schema, and trigger cache stay clean."""
    with Fixture() as fixture:
        fixture.configure(["true"])
        fixture.run_checks()
        expected = checks._expected_triggers()
        assert len(expected) == 14
        assert set(checks._actual_triggers(fixture.conn)) == set(expected)

        # Exercise the archive schema before two idempotent init passes. The
        # checked task is retained by immutable evidence, but archive creates
        # and migrates every derived archive table before making that choice.
        fixture.fleet("archive", "--before", "2999-01-01")
        archive_path = fixture.root / "fleet-home" / "fleet-archive.db"
        archive = sqlite3.connect(archive_path)
        try:
            tables = {row[0] for row in archive.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )}
            assert set(api.ARCHIVED_TABLES).issubset(tables)
            assert all(
                "archived_seq" in {
                    column[1] for column in archive.execute(
                        f"PRAGMA table_info({table})"
                    )
                }
                for table in api.ARCHIVED_TABLES
            )
        finally:
            archive.close()
        fixture.fleet("init")
        fixture.fleet("init")
        fixture.fleet("daemon", "run", "--once")
        assert not fixture.conn.execute(
            "SELECT 1 FROM event WHERE kind='check.tampered'"
        ).fetchone()
        assert checks.trigger_set_intact(fixture.conn)
        assert checks.passed(fixture.conn, fixture.row())

        # The parser cache reuses an unchanged mtime/size tuple, but both
        # stamp components invalidate it. A trigger on a formerly unprotected
        # table also proves future schema additions join the expected set.
        cache_schema = fixture.root / "schema-cache.sql"
        cache_schema.write_text((ROOT / "schema.sql").read_text())
        first = checks._expected_triggers(cache_schema)
        assert checks._expected_triggers(cache_schema) is first
        stat = cache_schema.stat()
        cache_schema.write_text(cache_schema.read_text().replace(
            "event_check_audit_no_update",
            "event_check_audit_no_updatf", 1,
        ))
        os.utime(
            cache_schema,
            ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000_000),
        )
        mtime_changed = checks._expected_triggers(cache_schema)
        assert len(mtime_changed) == 14
        assert "event_check_audit_no_updatf" in mtime_changed
        cache_schema.write_text(
            cache_schema.read_text()
            + "\nCREATE TRIGGER IF NOT EXISTS future_attempt_trigger "
              "AFTER UPDATE ON attempt BEGIN SELECT 1; END;\n"
        )
        size_changed = checks._expected_triggers(cache_schema)
        assert len(size_changed) == 15
        assert "future_attempt_trigger" in size_changed


CASES = [
    case_a, case_b, case_c, case_d, case_e, case_f, case_g, case_h, case_i,
    case_j, case_k, case_l, case_m, case_n, case_o, case_p, case_q, case_r,
    case_s, case_t, case_u, case_v, case_w, case_x,
]
if os.environ.get("P22_CASE"):
    CASES = [CASES[int(os.environ["P22_CASE"]) - 1]]

passed_count = 0
for number, case in enumerate(CASES, 1):
    label = chr(64 + (int(os.environ.get("P22_CASE", number))))
    try:
        case()
        passed_count += 1
        print(f"ok {number} - {label} checks acceptance", flush=True)
    except Exception:
        traceback.print_exc()
        print(f"not ok {number} - {label} checks acceptance", flush=True)
print(f"passed {passed_count} / {len(CASES)}")
sys.exit(passed_count != len(CASES))
