#!/usr/bin/env python3
"""Test per-task effort, per-model caps, and commander model choice."""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
FLEET = Path(os.environ.get("FLEET_UNDER_TEST", ROOT / "bin" / "fleet"))


def load_fleet(tag):
    loader = importlib.machinery.SourceFileLoader(
        f"fleet_p25_{tag}_{time.time_ns()}", str(FLEET)
    )
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class FleetHomeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-p25-", dir="/var/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = dict(os.environ, FLEET_HOME=str(self.home))
        subprocess.run(
            [str(FLEET), "init"], check=True, env=self.env,
            capture_output=True, text=True,
        )
        old = os.environ.get("FLEET_HOME")
        os.environ["FLEET_HOME"] = str(self.home)
        self.addCleanup(
            lambda: os.environ.__setitem__("FLEET_HOME", old)
            if old is not None else os.environ.pop("FLEET_HOME", None)
        )
        self.mod = load_fleet(self.id().rsplit(".", 1)[-1])

    def fleet(self, *args, check=True):
        return subprocess.run(
            [str(FLEET), *map(str, args)], check=check, env=self.env,
            capture_output=True, text=True,
        )

    def wait_status(self, task_id, wanted, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            conn = sqlite3.connect(self.home / "fleet.db")
            status = conn.execute(
                "SELECT status FROM task WHERE id=?", (task_id,)
            ).fetchone()[0]
            conn.close()
            if status == wanted:
                return
            time.sleep(0.05)
        self.fail(f"task {task_id} did not reach {wanted}; last status={status}")


class EffortTests(FleetHomeTest):
    def test_effort_precedence_has_all_four_levels(self):
        configured = {
            "effort": "channel-default",
            "model_effort": {"GPT-A": "model-default"},
        }
        cases = (
            ("task", configured, "GPT-A", "task-override", "task-override"),
            ("task clears defaults", configured, "GPT-A", "", ""),
            ("model hit", configured, "GPT-A", None, "model-default"),
            ("model miss", configured, "GPT-B", None, "channel-default"),
            ("empty", {}, "GPT-A", None, ""),
        )
        for label, channel, model, task_effort, expected in cases:
            with self.subTest(label=label):
                self.assertEqual(
                    self.mod.effective_effort(channel, model, task_effort),
                    expected,
                )
                self.assertEqual(
                    self.mod.adapter_env(channel, model, task_effort)["FLEET_EFFORT"],
                    expected,
                )

    def test_add_persists_and_show_displays_opaque_effort(self):
        added = self.fleet(
            "add", "effort task", "--channel", "shell", "--effort", "ultra+custom"
        )
        task_id = int(added.stdout)
        shown = self.fleet("show", task_id).stdout
        self.assertIn("effort: ultra+custom\n", shown)
        conn = sqlite3.connect(self.home / "fleet.db")
        self.addCleanup(conn.close)
        self.assertEqual(
            conn.execute("SELECT effort FROM task WHERE id=?", (task_id,)).fetchone()[0],
            "ultra+custom",
        )

    def test_effort_rejects_only_whitespace_and_quotes(self):
        for bad in ("extra high", "extra\thigh", "'high'", '"high"'):
            with self.subTest(bad=bad), self.assertRaisesRegex(
                ValueError, "whitespace or quotes"
            ):
                self.mod.validate_effort(bad)
        for good in ("", "xhigh", "vendor/level:7", "ultra+custom"):
            with self.subTest(good=good):
                self.assertEqual(self.mod.validate_effort(good), good)

    def test_retry_attempt_keeps_task_effort(self):
        script = self.home / "retry-effort.sh"
        script.write_text(
            'if [ ! -e "$FLEET_HOME/retry-once" ]; then\n'
            '  touch "$FLEET_HOME/retry-once"\n'
            '  exit 7\n'
            'fi\n'
            'printf "%s\\n" "$FLEET_EFFORT"\n'
        )
        task_id = int(self.fleet(
            "add", "retry effort", "--channel", "shell", "--spec", script,
            "--max-attempts", 2, "--effort", "retry-level",
        ).stdout)
        self.fleet("run", task_id)
        self.wait_status(task_id, "queued")
        self.fleet("run", task_id)
        self.wait_status(task_id, "done")
        self.assertEqual(self.fleet("digest", task_id).stdout.strip(), "retry-level")
        conn = sqlite3.connect(self.home / "fleet.db")
        self.addCleanup(conn.close)
        self.assertEqual(
            conn.execute(
                "SELECT effort,attempt FROM task WHERE id=?", (task_id,)
            ).fetchone(),
            ("retry-level", 2),
        )


class MigrationTests(FleetHomeTest):
    def test_old_ledger_adds_nullable_effort_and_keeps_legacy_default(self):
        task_id = int(self.fleet("add", "legacy", "--channel", "shell").stdout)
        conn = sqlite3.connect(self.home / "fleet.db")
        conn.execute("ALTER TABLE task DROP COLUMN effort")
        conn.commit()
        conn.close()

        self.fleet("init")
        conn = sqlite3.connect(self.home / "fleet.db")
        self.addCleanup(conn.close)
        columns = {row[1] for row in conn.execute("PRAGMA table_info(task)")}
        effort = conn.execute(
            "SELECT effort FROM task WHERE id=?", (task_id,)
        ).fetchone()[0]
        self.assertIn("effort", columns)
        self.assertIsNone(effort)
        self.assertEqual(
            self.mod.effective_effort({"effort": "legacy-default"}, "", effort),
            "legacy-default",
        )


class ModelParallelTests(FleetHomeTest):
    def connect(self):
        conn = self.mod.db_connect()
        self.addCleanup(conn.close)
        return conn

    @staticmethod
    def insert_task(conn, title, model, status="queued", goal_id=None, channel="multi"):
        cur = conn.execute(
            "INSERT INTO task(title,goal_id,channel,family,model,status,cwd,created_at) "
            "VALUES(?,?,?,?,?,?,?,?)",
            (title, goal_id, channel, "gpt", model, status, "/tmp", int(time.time())),
        )
        conn.commit()
        return cur.lastrowid

    @staticmethod
    def fake_start(conn):
        def start(_conn, task, _channel, **_kwargs):
            conn.execute("UPDATE task SET status='running' WHERE id=?", (task["id"],))
            conn.commit()
            return True, None
        return start

    def test_same_model_is_held_while_another_model_starts_and_views_show_reason(self):
        conn = self.connect()
        conn.execute(
            "INSERT INTO goal(id,statement,status,created_at) VALUES(1,'caps','open',?)",
            (int(time.time()),),
        )
        chans = {
            "max_parallel": 8,
            "channels": {
                "multi": {
                    "model": "GPT-A",
                    "model_max_parallel": {"GPT-A": 1, "GPT-B": 1},
                }
            },
        }
        self.insert_task(conn, "already A", "GPT-A", "running", 1)
        held = self.insert_task(conn, "queued A", "GPT-A", goal_id=1)
        other = self.insert_task(conn, "queued B", "GPT-B", goal_id=1)

        with mock.patch.object(
            self.mod, "try_start", side_effect=self.fake_start(conn)
        ):
            started = self.mod.start_ready(conn, chans)

        self.assertEqual(started, [other])
        self.assertEqual(
            conn.execute("SELECT status FROM task WHERE id=?", (held,)).fetchone()[0],
            "queued",
        )
        payload = json.loads(conn.execute(
            "SELECT payload FROM event WHERE task_id=? AND kind='task.blocked'",
            (held,),
        ).fetchone()[0])
        self.assertEqual(
            payload,
            {"reason": "model max_parallel", "model": "GPT-A", "cap": 1},
        )
        brief = self.fleet("brief").stdout
        self.assertIn("blocked: model max_parallel", brief)
        screen = self.mod._top_screen(
            conn, chans,
            SimpleNamespace(
                cwd=None, stall=900, ascii=True, no_doing=True,
            ),
            160,
        )
        rendered = "\n".join("".join(text for text, _style in line) for line in screen)
        self.assertIn("BLOCKED=model max_parallel", rendered)

    def test_one_round_counts_each_start_against_the_model_cap(self):
        # Both tasks are queued, nothing runs yet: only the in-round increment
        # after a successful start can stop the second one (REVIEW-P25 B1).
        conn = self.connect()
        conn.execute(
            "INSERT INTO goal(id,statement,status,created_at) VALUES(1,'caps','open',?)",
            (int(time.time()),),
        )
        chans = {
            "max_parallel": 8,
            "channels": {"multi": {"model": "GPT-A", "model_max_parallel": {"GPT-A": 1}}},
        }
        first = self.insert_task(conn, "queued A1", "GPT-A", goal_id=1)
        second = self.insert_task(conn, "queued A2", "GPT-A", goal_id=1)

        with mock.patch.object(
            self.mod, "try_start", side_effect=self.fake_start(conn)
        ):
            started = self.mod.start_ready(conn, chans)

        self.assertEqual(started, [first])
        self.assertEqual(
            conn.execute("SELECT status FROM task WHERE id=?", (second,)).fetchone()[0],
            "queued",
        )
        payload = json.loads(conn.execute(
            "SELECT payload FROM event WHERE task_id=? AND kind='task.blocked'",
            (second,),
        ).fetchone()[0])
        self.assertEqual(
            payload,
            {"reason": "model max_parallel", "model": "GPT-A", "cap": 1},
        )

    def test_zero_cap_disables_matching_model(self):
        conn = self.connect()
        chans = {
            "max_parallel": 4,
            "channels": {
                "multi": {
                    "model": "GPT-A", "model_max_parallel": {"GPT-*": 0},
                }
            },
        }
        held = self.insert_task(conn, "disabled", "GPT-A")
        with mock.patch.object(self.mod, "try_start") as starter:
            self.assertEqual(self.mod.start_ready(conn, chans), [])
        starter.assert_not_called()
        payload = json.loads(conn.execute(
            "SELECT payload FROM event WHERE task_id=? AND kind='task.blocked'",
            (held,),
        ).fetchone()[0])
        self.assertEqual(payload["cap"], 0)
        self.assertEqual(payload["reason"], "model max_parallel")

    def test_first_matching_glob_owns_the_shared_bucket(self):
        conn = self.connect()
        channel = {
            "model": "GPT-A",
            "model_max_parallel": {"GPT-*": 1, "GPT-A": 99},
        }
        chans = {"max_parallel": 4, "channels": {"multi": channel}}
        self.insert_task(conn, "running Z", "GPT-Z", "running")
        held = self.insert_task(conn, "queued A", "GPT-A")
        self.assertEqual(
            self.mod.model_parallel_limit(channel, "GPT-A"), ("GPT-*", 1)
        )
        with mock.patch.object(self.mod, "try_start") as starter:
            self.assertEqual(self.mod.start_ready(conn, chans), [])
        starter.assert_not_called()
        payload = json.loads(conn.execute(
            "SELECT payload FROM event WHERE task_id=? AND kind='task.blocked'",
            (held,),
        ).fetchone()[0])
        self.assertEqual(payload["cap"], 1)

    def test_fallback_skips_target_whose_effective_model_is_capped(self):
        conn = self.connect()
        chans = {
            "max_parallel": 4,
            "channels": {
                "source": {
                    "adapter": "shell.sh", "family": "none", "max_parallel": 0,
                    "fallback": ["disabled", "open"],
                },
                "disabled": {
                    "adapter": "shell.sh", "family": "none",
                    "model_max_parallel": {"*": 0},
                },
                "open": {"adapter": "shell.sh", "family": "none"},
            },
        }
        task_id = self.mod.create_task(
            conn, chans, title="fallback", channel="source", spec="true\n",
            cwd=str(self.home), no_preamble=True,
        )
        with mock.patch.object(
            self.mod, "try_start", side_effect=self.fake_start(conn)
        ):
            self.assertEqual(self.mod.start_ready(conn, chans), [task_id])
        row = conn.execute(
            "SELECT channel,status FROM task WHERE id=?", (task_id,)
        ).fetchone()
        self.assertEqual(tuple(row), ("open", "running"))

    def test_channel_without_model_cap_keeps_legacy_unlimited_behavior(self):
        conn = self.connect()
        chans = {
            "max_parallel": 4,
            "channels": {"multi": {"model": "GPT-A"}},
        }
        first = self.insert_task(conn, "legacy one", "GPT-A")
        second = self.insert_task(conn, "legacy two", "GPT-A")
        with mock.patch.object(
            self.mod, "try_start", side_effect=self.fake_start(conn)
        ):
            self.assertEqual(self.mod.start_ready(conn, chans), [first, second])


class CommanderChoiceTests(FleetHomeTest):
    @staticmethod
    def proposal(candidate):
        return {
            "goal_id": 7,
            "based_on_plan_revision": 0,
            "through_event_id": 11,
            "proposed_tasks": [candidate],
            "decisions": [],
            "next_wake": {"reason": "waiting_for_tasks"},
        }

    @staticmethod
    def candidate():
        return {
            "channel": "multi", "title": "choice",
            "problem": "true", "evidence": "ledger",
            "expected_artifact": "row", "verification": "query row",
            "dedup_key": "choice", "scope": "test home",
        }

    def test_schema_accepts_omitted_choice_and_rejects_bad_effort(self):
        task = {
            "goal_id": 7, "commander_plan_revision": 0,
            "commander_through_event_id": 11,
        }
        # Backward compatibility: the old candidate shape remains valid.
        self.mod._validate_commander_proposal(
            self.proposal(self.candidate()), task
        )
        selected = self.candidate()
        selected.update({"model": "GPT-A", "effort": "vendor/level:7"})
        self.mod._validate_commander_proposal(self.proposal(selected), task)
        for effort in ("extra high", "'high'", '"high"'):
            bad = self.candidate()
            bad["effort"] = effort
            with self.subTest(effort=effort), self.assertRaisesRegex(
                ValueError, "whitespace or quotes"
            ):
                self.mod._validate_commander_proposal(self.proposal(bad), task)

    def test_invalid_and_failed_models_are_rejected_but_legal_choice_persists(self):
        registry_path = self.home / "channels.json"
        registry = json.loads(registry_path.read_text())
        registry["channels"]["multi"] = {
            "adapter": "shell.sh",
            "model": "GPT-A",
            "models": ["GPT-A", "GPT-B"],
            "model_max_parallel": {"GPT-A": 2, "GPT-*": 1},
            "model_effort": {"GPT-A": "high"},
        }
        registry_path.write_text(json.dumps(registry, indent=2))

        goal_id = int(self.fleet("goal", "add", "commander choice").stdout)
        conn = sqlite3.connect(self.home / "fleet.db")
        conn.execute(
            "INSERT INTO model_probe(channel,model,ok,checked_at,note) "
            "VALUES('multi','GPT-B',0,?,'provider rejected')",
            (int(time.time()),),
        )
        conn.commit()
        conn.close()

        driver = self.home / "choice-driver.sh"
        driver.write_text("""#!/usr/bin/env bash
python3 - "$0" <<'PY'
import json,re,sys
text=open(sys.argv[1]).read()
number=lambda pattern: int(re.search(pattern,text).group(1))
def candidate(title,key,model,effort=None):
    item={'channel':'multi','title':title,'problem':'true',
          'evidence':'ledger','expected_artifact':'task row',
          'verification':'query task','dedup_key':key,'scope':'test home',
          'model':model}
    if effort is not None: item['effort']=effort
    return item
proposal={'goal_id':number(r'"id": (\\d+)'),
          'based_on_plan_revision':number(r'"revision": (\\d+)'),
          'through_event_id':number(r'"through_event_id": (\\d+)'),
          'proposed_tasks':[
              candidate('unlisted','unlisted','GPT-X'),
              candidate('failed probe','failed-probe','GPT-B'),
              candidate('legal choice','legal','GPT-A','xhigh')],
          'decisions':[],
          'next_wake':{'reason':'waiting_for_tasks'}}
print(json.dumps(proposal))
PY
""")
        driver.chmod(0o755)
        commander_id = int(self.fleet(
            "add", "--role", "commander", "--goal", goal_id,
            "--channel", "shell", "--spec", driver, "--cwd", self.home,
        ).stdout)
        self.fleet("run", commander_id)

        deadline = time.time() + 10
        status = None
        while time.time() < deadline:
            conn = sqlite3.connect(self.home / "fleet.db")
            status = conn.execute(
                "SELECT status FROM task WHERE id=?", (commander_id,)
            ).fetchone()[0]
            conn.close()
            if status in ("done", "failed", "cancelled"):
                break
            time.sleep(0.05)
        self.assertEqual(status, "done")

        conn = sqlite3.connect(self.home / "fleet.db")
        self.addCleanup(conn.close)
        workers = conn.execute(
            "SELECT title,model,effort FROM task WHERE parent_id=? ORDER BY id",
            (commander_id,),
        ).fetchall()
        self.assertEqual(workers, [("legal choice", "GPT-A", "xhigh")])
        reasons = [
            json.loads(row[0])["reason"]
            for row in conn.execute(
                "SELECT payload FROM event WHERE task_id=? "
                "AND kind='proposal.rejected' ORDER BY id",
                (commander_id,),
            )
        ]
        self.assertEqual(len(reasons), 2)
        self.assertTrue(any("does not offer model 'GPT-X'" in r for r in reasons))
        self.assertTrue(any("failed its last probe" in r for r in reasons))

        prompt = (self.home / "runs" / str(commander_id) / "prompt.md").read_text()
        body = prompt.split(": <<'FLEET_COMMANDER_PROMPT'\n", 1)[1]
        body = body.rsplit("FLEET_COMMANDER_PROMPT\n", 1)[0]
        options = {
            item["channel"]: item for item in json.loads(body)["channel_options"]
        }
        self.assertEqual(options["multi"]["models"], ["GPT-A", "GPT-B"])
        self.assertEqual(
            list(options["multi"]["model_max_parallel"]), ["GPT-A", "GPT-*"]
        )
        self.assertEqual(options["multi"]["model_effort"], {"GPT-A": "high"})


class TapResult(unittest.TextTestResult):
    """Keep diagnostics while exposing stable case names in smoke output."""

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
        print(
            f"{'not ok' if self._failed else 'ok'} {self.testsRun} - "
            f"{test.id().rsplit('.', 1)[-1]}"
        )
        super().stopTest(test)


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2, resultclass=TapResult).run(
        unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__))
    )
    failed = len(result.failures) + len(result.errors)
    print("---")
    print(f"passed {result.testsRun - failed} / {result.testsRun}")
    raise SystemExit(not result.wasSuccessful())
