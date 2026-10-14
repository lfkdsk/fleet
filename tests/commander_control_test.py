#!/usr/bin/env python3
"""C control regression tests: launch budgets, generations and watermarks."""

import hashlib
import importlib.machinery
import importlib.util
import json
import multiprocessing
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
FLEET = Path(os.environ.get("FLEET_UNDER_TEST", ROOT / "bin" / "fleet"))


def concurrent_run(fleet, home, task_id, gate, queue):
    gate.wait()
    result = subprocess.run(
        [str(fleet), "run", str(task_id)],
        env=dict(os.environ, FLEET_HOME=str(home)), text=True,
        capture_output=True,
    )
    queue.put((task_id, result.returncode, result.stdout, result.stderr))


class CommanderControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-control-", dir="/var/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = dict(os.environ, FLEET_HOME=str(self.home))
        self.cli("init")
        # Control tests need a clean, per-ledger Git execution target. The
        # source checkout can be dirty while this suite tests a patch, and it
        # is shared by every temporary ledger.
        self.repo = self.home / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.email",
             "fleet-control@example.invalid"], check=True,
        )
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "user.name",
             "Fleet Control Test"], check=True,
        )
        (self.repo / "tracked.txt").write_text("base\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "tracked.txt"],
                       check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "base"],
                       check=True)
        self.driver = self.home / "commander.sh"
        self.driver.write_text(
            "#!/usr/bin/env bash\n"
            "python3 - \"$0\" <<'PY'\n"
            "import json,re,sys\n"
            "s=open(sys.argv[1]).read()\n"
            "n=lambda p:int(re.search(p,s).group(1))\n"
            "candidate=lambda k:{'channel':'shell','title':'worker '+k,"
            "'problem':'printf worker','evidence':'ledger','expected_artifact':'out',"
            "'verification':'read output','dedup_key':k,'scope':'test'}\n"
            "print(json.dumps({'goal_id':n(r'\"id\": (\\d+)'),"
            "'based_on_plan_revision':n(r'\"revision\": (\\d+)'),"
            "'through_event_id':n(r'\"through_event_id\": (\\d+)'),"
            "'proposed_tasks':[candidate('a'),candidate('b')],'decisions':[],"
            "'next_wake':{'reason':'waiting_for_tasks'}}))\n"
            "PY\n"
        )
        self.driver.chmod(0o755)
        self.env["FLEET_COMMANDER_SHELL_SCRIPT"] = str(self.driver)

    def cli(self, *args, check=True, env=None):
        return subprocess.run(
            [str(FLEET), *map(str, args)], env=env or self.env, text=True,
            capture_output=True, check=check,
        )

    def finish_as_wrapper(self, task_id, exit_code, attempt_id, env=None):
        code = """
import os
import sqlite3
import sys

fleet, home, task_id, exit_code, attempt_id = sys.argv[1:]
raw = open(f"/proc/{os.getpid()}/stat").read()
starttime = int(raw[raw.rfind(")") + 2:].split()[19])
conn = sqlite3.connect(os.path.join(home, "fleet.db"))
conn.execute(
    "UPDATE task SET pid=?,pid_starttime=? WHERE id=? AND attempt_id=?",
    (os.getpid(), starttime, int(task_id), attempt_id),
)
conn.execute(
    "UPDATE attempt SET pid=?,pid_starttime=? WHERE attempt_id=?",
    (os.getpid(), starttime, attempt_id),
)
conn.commit()
os.execve(
    fleet,
    [fleet, "_finish", task_id, exit_code, "--attempt", attempt_id],
    os.environ,
)
"""
        return subprocess.run(
            ["setsid", "python3", "-c", code, str(FLEET), str(self.home),
             str(task_id), str(exit_code), str(attempt_id)],
            env=env or self.env, text=True, capture_output=True, check=True,
        )

    def db(self):
        conn = sqlite3.connect(self.home / "fleet.db")
        conn.row_factory = sqlite3.Row
        return conn

    def sql(self, statement, params=()):
        conn = self.db()
        try:
            return conn.execute(statement, params).fetchall()
        finally:
            conn.close()

    def wait_status(self, task_id, expected, tries=100):
        for _ in range(tries):
            status = self.sql(
                "SELECT status FROM task WHERE id=?", (task_id,)
            )[0][0]
            if status == expected:
                return
            time.sleep(.03)
        self.fail(f"task {task_id} did not reach {expected}; last status={status}")

    def goal(self, cap=None):
        args = ["goal", "add", "control goal"]
        if cap is not None:
            args += ["--budget", str(cap)]
        return int(self.cli(*args).stdout)

    def task(self, goal, script="printf ok\n", attempts=1, lease=None,
             cwd=None, worktree=False):
        spec = self.home / f"worker-{time.time_ns()}.sh"
        spec.write_text(script)
        args = ["add", "worker", "--channel", "shell", "--goal",
                str(goal), "--spec", str(spec), "--max-attempts", str(attempts)]
        if lease:
            args += ["--lease", lease]
        if cwd is not None:
            args += ["--cwd", str(cwd)]
        if worktree:
            args += ["--worktree"]
        return int(self.cli(*args).stdout)

    def enable(self, goal, max_failures=2, cwd=None):
        args = ["autonomy", "enable", goal, "--channel", "shell",
                "--max-failures", max_failures, "--cooldown", "0"]
        args += ["--cwd", cwd or self.repo]
        self.cli(*args)

    def auto_commander(self, goal, enable=True):
        if enable:
            self.enable(goal)
        loader = importlib.machinery.SourceFileLoader(
            f"fleet_control_{time.time_ns()}", str(FLEET)
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        old = os.environ.get("FLEET_HOME")
        old_driver = os.environ.get("FLEET_COMMANDER_SHELL_SCRIPT")
        os.environ["FLEET_HOME"] = str(self.home)
        os.environ["FLEET_COMMANDER_SHELL_SCRIPT"] = str(self.driver)
        try:
            conn = module.db_connect()
            try:
                created = module.schedule_autonomy(conn, module.load_channels())
                row = conn.execute(
                    "SELECT id FROM task WHERE goal_id=? AND role='commander' "
                    "ORDER BY id DESC LIMIT 1", (goal,),
                ).fetchone()
                if not row or row["id"] not in created:
                    raise AssertionError(
                        f"scheduler did not create commander for goal {goal}: {created}"
                    )
                task_id = row["id"]
            finally:
                conn.close()
        finally:
            if old is None:
                os.environ.pop("FLEET_HOME", None)
            else:
                os.environ["FLEET_HOME"] = old
            if old_driver is None:
                os.environ.pop("FLEET_COMMANDER_SHELL_SCRIPT", None)
            else:
                os.environ["FLEET_COMMANDER_SHELL_SCRIPT"] = old_driver
        return task_id

    def mark_running_with_output(self, task_id):
        prompt = self.sql("SELECT spec_path FROM task WHERE id=?", (task_id,))[0][0]
        out = self.sql("SELECT out_path FROM task WHERE id=?", (task_id,))[0][0]
        output = subprocess.run(["bash", prompt], text=True, capture_output=True, check=True).stdout
        Path(out).write_text(output)
        conn = self.db()
        try:
            attempt_id = f"control-{task_id}-{time.time_ns()}"
            conn.execute(
                "UPDATE task SET status='running',attempt=1,attempt_id=?,"
                "started_at=?,pid=NULL WHERE id=?",
                (attempt_id, int(time.time()) - 20, task_id),
            )
            conn.commit()
        finally:
            conn.close()

    def assert_policy_stale(self, task_id):
        row = self.sql("SELECT status,exit_code FROM task WHERE id=?", (task_id,))[0]
        self.assertEqual(("done", 0), tuple(row))
        self.assertEqual(0, self.sql(
            "SELECT COUNT(*) FROM task WHERE parent_id=?", (task_id,)
        )[0][0])
        self.assertEqual(1, self.sql(
            "SELECT COUNT(*) FROM event WHERE task_id=? AND kind='commander.rejected' "
            "AND json_extract(payload,'$.reason')='policy_stale'", (task_id,)
        )[0][0])

    def test_budget_one_blocks_multiple_candidates_and_deduplicates(self):
        goal = self.goal(1)
        self.enable(goal)
        self.cli("daemon", "run", "--once")
        commander = self.sql(
            "SELECT id FROM task WHERE goal_id=? AND role='commander'", (goal,)
        )[0][0]
        self.wait_status(commander, "done")
        workers = [r[0] for r in self.sql(
            "SELECT id FROM task WHERE parent_id=? ORDER BY id", (commander,)
        )]
        self.assertEqual(2, len(workers))
        self.cli("daemon", "run", "--once")
        self.cli("daemon", "run", "--once")
        self.assertEqual(1, self.sql(
            "SELECT COALESCE(SUM(attempt),0) FROM task WHERE goal_id=?", (goal,)
        )[0][0])
        self.assertEqual(["queued", "queued"], [r[0] for r in self.sql(
            "SELECT status FROM task WHERE id IN (?,?) ORDER BY id", workers
        )])
        self.assertEqual(2, self.sql(
            "SELECT COUNT(*) FROM event WHERE kind='task.blocked' "
            "AND json_extract(payload,'$.reason')='budget' "
            "AND json_extract(payload,'$.scope')='goal'"
        )[0][0])

    def test_budget_two_allows_only_one_of_multiple_candidates(self):
        # Reproduce the collision that made this test stable-red after Git
        # execution isolation landed: another ledger's task ids can leave the
        # legacy global branch names in a shared target repository.
        repo = self.repo
        for task_id in (2, 3):
            subprocess.run(
                ["git", "-C", str(repo), "branch", f"fleet/task-{task_id}"],
                check=True,
            )
        goal = self.goal(2)
        self.enable(goal, cwd=repo)
        commander = self.auto_commander(goal, enable=False)
        self.cli("run", commander)
        for _ in range(100):
            if self.sql("SELECT status FROM task WHERE id=?", (commander,))[0][0] == "done":
                break
            time.sleep(.03)
        workers = [r[0] for r in self.sql(
            "SELECT id FROM task WHERE parent_id=? ORDER BY id", (commander,)
        )]
        self.assertEqual(2, len(workers))
        ready = self.cli("run", "--ready")
        self.assertIn(f"started {workers[0]}", ready.stdout)
        for _ in range(100):
            statuses = [r[0] for r in self.sql(
                "SELECT status FROM task WHERE id IN (?,?) ORDER BY id", workers
            )]
            if statuses == ["done", "queued"]:
                break
            time.sleep(.03)
        self.assertEqual(["done", "queued"], statuses)
        self.assertEqual(2, self.sql(
            "SELECT SUM(attempt) FROM task WHERE goal_id=?", (goal,)
        )[0][0])
        rows = self.sql(
            "SELECT cwd,worktree_branch,spec_path FROM task "
            "WHERE id IN (?,?) ORDER BY id", workers,
        )
        self.assertTrue(all(row["cwd"] == str(repo.resolve()) for row in rows))
        namespace = hashlib.sha256(
            str(self.home.resolve()).encode()
        ).hexdigest()[:12]
        self.assertEqual(
            [f"fleet/{namespace}/task-{worker}" for worker in workers],
            [row["worktree_branch"] for row in rows],
        )
        self.assertTrue(all(Path(row["spec_path"]).is_file() for row in rows))
        self.assertEqual(1, self.sql(
            "SELECT COUNT(*) FROM event WHERE task_id=? AND kind='task.blocked' "
            "AND json_extract(payload,'$.reason')='budget' "
            "AND json_extract(payload,'$.scope')='goal'", (workers[1],),
        )[0][0])
        self.assertEqual(0, self.sql(
            "SELECT COUNT(*) FROM event WHERE task_id IN (?,?) "
            "AND kind='task.blocked' "
            "AND json_extract(payload,'$.reason')='launch_failed'", workers,
        )[0][0])

        # A genuine collision on the new branch is visible and actionable.
        # Free one more goal attempt, then occupy worker 2's exact branch in a
        # different worktree so neither Git's create nor reuse path can take it.
        conn = self.db()
        try:
            conn.execute("UPDATE goal SET budget_cap=3 WHERE id=?", (goal,))
            conn.commit()
        finally:
            conn.close()
        occupied = self.home / "occupied-worktree"
        subprocess.run(
            ["git", "-C", str(repo), "worktree", "add", "-q", "-b",
             rows[1]["worktree_branch"], str(occupied), "HEAD"], check=True,
        )
        for _ in range(2):
            blocked = self.cli("run", workers[1], check=False)
            self.assertNotEqual(0, blocked.returncode)
            # Task 401: the refusal names the branch and says the code is not
            # this task's, instead of relaying Git's "worktree add failed" --
            # the old wording could not distinguish a collision from any other
            # Git failure, and the collision is the case that matters.
            self.assertIn(rows[1]["worktree_branch"], blocked.stderr)
            self.assertIn("already exists", blocked.stderr)
            self.assertIn(f"not created by task {workers[1]}", blocked.stderr)
        self.assertEqual(("queued", 0), tuple(self.sql(
            "SELECT status,attempt FROM task WHERE id=?", (workers[1],)
        )[0]))
        self.assertGreaterEqual(self.sql(
            "SELECT COUNT(*) FROM event WHERE task_id=? AND kind='task.blocked' "
            "AND json_extract(payload,'$.reason')='worktree'", (workers[1],),
        )[0][0], 1)
        self.assertEqual(1, self.sql(
            "SELECT COUNT(*) FROM decision WHERE task_id=? AND needs_user=1 "
            "AND question LIKE 'worktree:%'", (workers[1],),
        )[0][0])

    def test_budget_two_retry_and_unlimited_compatibility(self):
        goal = self.goal(2)
        retry = self.task(goal, "exit 7\n", attempts=3)
        self.cli("run", retry)
        for _ in range(100):
            if self.sql("SELECT status FROM task WHERE id=?", (retry,))[0][0] == "queued":
                break
            time.sleep(.03)
        self.cli("run", retry)
        for _ in range(100):
            row = self.sql(
                "SELECT status,attempt FROM task WHERE id=?", (retry,)
            )[0]
            if tuple(row) == ("queued", 2):
                break
            time.sleep(.03)
        blocked = self.cli("run", retry, check=False)
        self.assertNotEqual(0, blocked.returncode)
        self.assertIn("goal budget exhausted (2/2)", blocked.stderr)
        self.assertEqual(("queued", 2), tuple(self.sql(
            "SELECT status,attempt FROM task WHERE id=?", (retry,)
        )[0]))
        unlimited = self.goal()
        tasks = [self.task(unlimited) for _ in range(3)]
        self.cli("run", "--ready")
        for _ in range(100):
            if self.sql(
                "SELECT COUNT(*) FROM task WHERE id IN (?,?,?) AND status='done'", tasks
            )[0][0] == 3:
                break
            time.sleep(.03)
        self.assertEqual(3, self.sql(
            "SELECT COUNT(*) FROM task WHERE id IN (?,?,?) AND status='done'", tasks
        )[0][0])
        self.assertEqual(3, self.sql(
            "SELECT COALESCE(SUM(attempt),0) FROM task WHERE goal_id=?", (unlimited,)
        )[0][0])

    def test_concurrent_last_slot_and_spawn_failure_refund(self):
        goal = self.goal(1)
        tasks = [self.task(goal, "sleep .2; printf ok\n", lease=f"r{i}") for i in range(2)]
        ctx = multiprocessing.get_context("fork")
        gate = ctx.Event()
        queue = ctx.Queue()
        processes = [ctx.Process(
            target=concurrent_run, args=(FLEET, self.home, task_id, gate, queue)
        ) for task_id in tasks]
        for process in processes:
            process.start()
        gate.set()
        for process in processes:
            process.join(10)
            self.assertEqual(0, process.exitcode)
        results = [queue.get(timeout=2) for _ in tasks]
        self.assertEqual([0, 1], sorted(r[1] for r in results))
        self.assertEqual(1, self.sql(
            "SELECT SUM(attempt) FROM task WHERE goal_id=?", (goal,)
        )[0][0])
        self.assertEqual(0, self.sql(
            "SELECT COUNT(*) FROM lease JOIN task ON lease.holder=CAST(task.id AS TEXT) "
            "WHERE task.goal_id=? AND task.status='queued'", (goal,)
        )[0][0])
        running = self.sql(
            "SELECT id FROM task WHERE goal_id=? AND status='running'", (goal,)
        )
        if running:
            self.wait_status(running[0][0], "done")

        refund_goal = self.goal(1)
        task_id = self.task(refund_goal, lease="refund")
        failed_env = dict(self.env, FLEET_LAUNCH_FAIL="1")
        failed = self.cli("run", task_id, check=False, env=failed_env)
        self.assertNotEqual(0, failed.returncode)
        self.assertEqual(("queued", 0), tuple(self.sql(
            "SELECT status,attempt FROM task WHERE id=?", (task_id,)
        )[0]))
        self.assertEqual(0, self.sql(
            "SELECT COUNT(*) FROM lease WHERE resource='refund'"
        )[0][0])
        self.cli("run", task_id)
        self.wait_status(task_id, "done")

    def test_disable_queued_prevents_start_and_manual_still_runs(self):
        goal = self.goal()
        task_id = self.auto_commander(goal)
        origin = self.sql(
            "SELECT commander_origin,commander_policy_generation FROM task WHERE id=?",
            (task_id,),
        )[0]
        self.assertEqual("autonomy", origin[0])
        self.assertGreater(origin[1], 0)
        self.cli("autonomy", "disable", goal)
        self.cli("run", "--ready")
        self.assert_policy_stale(task_id)

        manual = int(self.cli(
            "add", "--role", "commander", "--goal", goal,
            "--channel", "shell", "--spec", self.driver,
        ).stdout)
        self.cli("run", manual)
        for _ in range(100):
            if self.sql("SELECT status FROM task WHERE id=?", (manual,))[0][0] == "done":
                break
            time.sleep(.03)
        self.assertEqual("manual", self.sql(
            "SELECT commander_origin FROM task WHERE id=?", (manual,)
        )[0][0])
        self.assertEqual(2, self.sql(
            "SELECT COUNT(*) FROM task WHERE parent_id=?", (manual,)
        )[0][0])

    def test_disable_running_and_disable_enable_reject_old_callback(self):
        for reenable, exit_code in ((False, 0), (True, 0), (True, 7)):
            goal = self.goal()
            task_id = self.auto_commander(goal)
            self.mark_running_with_output(task_id)
            self.cli("autonomy", "disable", goal)
            if reenable:
                self.enable(goal)
            before = self.sql(
                "SELECT json_extract(autonomy,'$.last_through_event_id'),"
                "json_extract(autonomy,'$.consecutive_failures') FROM goal WHERE id=?",
                (goal,),
            )[0]
            frozen = self.sql(
                "SELECT commander_origin,commander_policy_generation FROM task WHERE id=?",
                (task_id,),
            )[0]
            current_generation = self.sql(
                "SELECT json_extract(autonomy,'$.generation') FROM goal WHERE id=?",
                (goal,),
            )[0][0]
            self.assertEqual("autonomy", frozen[0])
            self.assertNotEqual(frozen[1], current_generation)
            attempt_id = self.sql(
                "SELECT attempt_id FROM task WHERE id=?", (task_id,),
            )[0][0]
            self.finish_as_wrapper(task_id, exit_code, attempt_id)
            self.assert_policy_stale(task_id)
            after = self.sql(
                "SELECT json_extract(autonomy,'$.last_through_event_id'),"
                "json_extract(autonomy,'$.consecutive_failures') FROM goal WHERE id=?",
                (goal,),
            )[0]
            self.assertEqual(tuple(before), tuple(after))

    def test_stale_orphan_replay_only_settles_and_releases(self):
        goal = self.goal()
        task_id = self.auto_commander(goal)
        self.mark_running_with_output(task_id)
        self.cli("autonomy", "disable", goal)
        env = dict(self.env, FLEET_ORPHAN_GRACE_S="0")
        self.cli("daemon", "run", "--once", env=env)
        self.assert_policy_stale(task_id)
        self.assertEqual(0, self.sql(
            "SELECT COUNT(*) FROM lease WHERE resource=?", (f"commander:goal-{goal}",)
        )[0][0])
        payload = self.sql(
            "SELECT payload FROM event WHERE task_id=? AND kind='task.orphaned'",
            (task_id,),
        )[0][0]
        self.assertTrue(json.loads(payload)["policy_stale"])

    def test_successful_auto_apply_clears_consecutive_failures(self):
        goal = self.goal()
        task_id = self.auto_commander(goal)
        conn = self.db()
        try:
            state = json.loads(conn.execute(
                "SELECT autonomy FROM goal WHERE id=?", (goal,)
            ).fetchone()[0])
            state["consecutive_failures"] = 1
            conn.execute("UPDATE goal SET autonomy=? WHERE id=?", (json.dumps(state), goal))
            conn.commit()
        finally:
            conn.close()
        self.mark_running_with_output(task_id)
        attempt_id = self.sql(
            "SELECT attempt_id FROM task WHERE id=?", (task_id,),
        )[0][0]
        self.finish_as_wrapper(task_id, 0, attempt_id)
        self.assertEqual(0, self.sql(
            "SELECT json_extract(autonomy,'$.consecutive_failures') FROM goal WHERE id=?",
            (goal,),
        )[0][0])

    def test_init_migrates_and_classifies_legacy_commanders(self):
        goal = self.goal()
        legacy_auto = int(self.cli(
            "add", "--role", "commander", "--goal", goal,
            "--channel", "shell", "--spec", self.driver,
        ).stdout)
        legacy_manual = int(self.cli(
            "add", "--role", "commander", "--goal", goal,
            "--channel", "shell", "--spec", self.driver,
        ).stdout)
        conn = self.db()
        try:
            conn.execute(
                "UPDATE goal SET autonomy=? WHERE id=?",
                (json.dumps({"enabled": True, "last_round_task": legacy_auto}), goal),
            )
            conn.execute("ALTER TABLE task DROP COLUMN commander_origin")
            conn.execute("ALTER TABLE task DROP COLUMN commander_policy_generation")
            conn.commit()
        finally:
            conn.close()
        self.cli("init")
        cols = {r[1] for r in self.sql("PRAGMA table_info(task)")}
        self.assertIn("commander_origin", cols)
        self.assertIn("commander_policy_generation", cols)
        origins = self.sql(
            "SELECT id,commander_origin,commander_policy_generation FROM task "
            "WHERE id IN (?,?) ORDER BY id", (legacy_auto, legacy_manual),
        )
        self.assertEqual(
            [(legacy_auto, "autonomy", 0), (legacy_manual, "manual", None)],
            [tuple(row) for row in origins],
        )

    def test_exhausted_commander_advances_only_to_frozen_watermark(self):
        self.driver.write_text(
            "#!/usr/bin/env bash\n"
            "sleep .5\n"
            "printf 'not json\n'\n"
        )
        goal = self.goal()
        self.enable(goal, max_failures=5)
        commander = self.auto_commander(goal, enable=False)
        frozen = self.sql(
            "SELECT commander_through_event_id FROM task WHERE id=?",
            (commander,),
        )[0][0]

        self.cli("run", commander)
        self.wait_status(commander, "running")
        self.cli("decide", "arrived while commander was running",
                 "--goal", goal)
        new_information = self.sql(
            "SELECT MAX(id) FROM event WHERE goal_id=? AND kind='decision.add'",
            (goal,),
        )[0][0]
        self.assertGreater(new_information, frozen)

        self.wait_status(commander, "queued")
        self.cli("run", commander)
        self.wait_status(commander, "queued")
        self.cli("run", commander)
        self.wait_status(commander, "failed")
        watermark = self.sql(
            "SELECT json_extract(autonomy,'$.last_through_event_id') "
            "FROM goal WHERE id=?", (goal,),
        )[0][0]

        self.cli("daemon", "run", "--once")
        commanders = self.sql(
            "SELECT id FROM task WHERE goal_id=? AND role='commander' ORDER BY id",
            (goal,),
        )
        if len(commanders) == 2:
            self.wait_status(commanders[1][0], "queued")
        self.assertEqual((frozen, 2), (watermark, len(commanders)))

    def test_worktree_construction_is_not_reaped_or_double_charged(self):
        repo = self.home / "race-repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "config", "user.email",
             "fleet-control@example.invalid"], check=True,
        )
        subprocess.run(
            ["git", "-C", str(repo), "config", "user.name",
             "Fleet Control Test"], check=True,
        )
        (repo / "tracked.txt").write_text("base\n")
        subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"],
                       check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-qm", "base"],
                       check=True)

        goal = self.goal(10)
        task_id = self.task(
            goal, attempts=3, cwd=repo, worktree=True,
            script="printf worktree-ok\n",
        )
        race_env = dict(
            self.env, FLEET_ORPHAN_GRACE_S="1", FLEET_WORKTREE_DELAY_S="3",
        )
        launcher = subprocess.Popen(
            [str(FLEET), "run", str(task_id)], env=race_env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.addCleanup(lambda: launcher.poll() is None and launcher.kill())
        self.wait_status(task_id, "running")
        launching_pid = self.sql(
            "SELECT pid FROM task WHERE id=?", (task_id,),
        )[0][0]
        time.sleep(2.1)

        pollers = [subprocess.Popen(
            [str(FLEET), "daemon", "run", "--once"], env=race_env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        ) for _ in range(2)]
        for poller in pollers:
            poller.communicate(timeout=12)
        launch_out, launch_err = launcher.communicate(timeout=12)
        self.assertEqual(0, launcher.returncode, (launch_out, launch_err))
        self.wait_status(task_id, "done", tries=200)

        row = self.sql(
            "SELECT attempt,worktree FROM task WHERE id=?", (task_id,),
        )[0]
        budget = self.sql(
            "SELECT COALESCE(SUM(used),0) FROM budget WHERE channel='shell'"
        )[0][0]
        starts = self.sql(
            "SELECT COUNT(*) FROM event WHERE task_id=? AND kind='task.start'",
            (task_id,),
        )[0][0]
        worktrees = self.sql(
            "SELECT COUNT(*) FROM event WHERE task_id=? AND kind='task.worktree'",
            (task_id,),
        )[0][0]
        orphans = self.sql(
            "SELECT COUNT(*) FROM event WHERE task_id=? AND kind='task.orphaned'",
            (task_id,),
        )[0][0]
        self.assertEqual(
            (0, 1, 1, 1, 0, True),
            (launching_pid, row["attempt"], budget, starts,
             orphans, worktrees == 1 and Path(row["worktree"]).is_dir()),
        )


class TapResult(unittest.TextTestResult):
    """Keep unittest diagnostics while exposing stable mutation case ids."""

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
        number = self.testsRun
        name = test.id().rsplit(".", 1)[-1]
        print(f"{'not ok' if self._failed else 'ok'} {number} - {name}")
        super().stopTest(test)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CommanderControlTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=TapResult).run(suite)
    print("---")
    print(f"passed {result.testsRun - len(result.failures) - len(result.errors)} "
          f"/ {result.testsRun}")
    raise SystemExit(not result.wasSuccessful())
