#!/usr/bin/env python3
"""Focused unit tests for commander execution-target/base fences."""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
FLEET_PATH = ROOT / "bin" / "fleet"
_loader = importlib.machinery.SourceFileLoader(
    "fleet_commander_execution_test", str(FLEET_PATH)
)
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
fleet = importlib.util.module_from_spec(_spec)
_loader.exec_module(fleet)


def git(path, *args):
    return subprocess.run(
        ["git", "-C", str(path), *args], check=True, text=True,
        capture_output=True,
    ).stdout.strip()


def make_repo(path, content="base\n"):
    path.mkdir()
    git(path, "init", "-q")
    git(path, "config", "user.email", "test@example.test")
    git(path, "config", "user.name", "test")
    (path / "tracked.txt").write_text(content)
    git(path, "add", "tracked.txt")
    git(path, "commit", "-qm", "base")


def candidate(base_marker=False):
    value = {
        "channel": "shell", "title": "candidate",
        "problem": "pwd", "evidence": "ledger",
        "expected_artifact": "output", "verification": "read it",
        "dedup_key": "candidate-key", "scope": "temp repo",
    }
    if base_marker:
        value["base_task"] = None
    return value


class ProposalSchemaTests(unittest.TestCase):
    task = {
        "goal_id": 7, "commander_plan_revision": 2,
        "commander_through_event_id": 11,
    }

    def proposal(self, item):
        return {
            "goal_id": 7, "based_on_plan_revision": 2,
            "through_event_id": 11, "proposed_tasks": [item],
            "decisions": [], "next_wake": {"reason": "waiting_for_tasks"},
        }

    def test_required_fields_and_optional_task_references_are_compatible(self):
        fleet._validate_commander_proposal(self.proposal(candidate()), self.task)
        for extra in (
            {"base_task": None}, {"base_task": 1}, {"review_of": 999},
            {"base_task": 1, "review_of": 999},
        ):
            item = candidate()
            item.update(extra)
            fleet._validate_commander_proposal(self.proposal(item), self.task)

    def test_task_references_reject_bool_float_zero_and_negative(self):
        for name in ("base_task", "review_of"):
            for value in (True, False, 1.0, 0, -1):
                with self.subTest(name=name, value=value), self.assertRaisesRegex(
                    ValueError, "positive integer"
                ):
                    item = candidate()
                    item[name] = value
                    fleet._validate_commander_proposal(self.proposal(item), self.task)

    def test_channel_has_metadata_cap(self):
        item = candidate()
        item["channel"] = "x" * (fleet.COMMANDER_METADATA_MAX_CHARS + 1)
        with self.assertRaisesRegex(ValueError, "at most"):
            fleet._validate_commander_proposal(self.proposal(item), self.task)

    def test_overlong_english_title_is_clipped_not_rejected(self):
        item = candidate()
        long_title = "x" * (fleet.COMMANDER_TITLE_MAX_CHARS + 31)
        item["title"] = long_title
        proposal = self.proposal(item)
        clips = fleet._validate_commander_proposal(proposal, self.task)
        clipped = proposal["proposed_tasks"][0]["title"]
        self.assertLessEqual(len(clipped), fleet.COMMANDER_TITLE_MAX_CHARS)
        self.assertTrue(clipped.endswith(fleet.COMMANDER_TITLE_TRUNCATION_MARKER))
        self.assertEqual(len(clips), 1)
        self.assertEqual(clips[0]["original_title"], long_title)
        self.assertEqual(clips[0]["clipped_title"], clipped)
        self.assertEqual(clips[0]["original_chars"], len(long_title))
        self.assertEqual(clips[0]["dedup_key"], item["dedup_key"])

    def test_overlong_chinese_title_is_clipped_by_python_len(self):
        # Python len(str), not display width: 45 CJK characters are 45 chars
        # even though they draw as 90 columns.
        item = candidate()
        item["title"] = "超长标题" * 9  # 36 chars, under the cap
        fleet._validate_commander_proposal(self.proposal(item), self.task)
        item["title"] = "超长标题" * 12  # 48 chars, over the cap
        proposal = self.proposal(item)
        clips = fleet._validate_commander_proposal(proposal, self.task)
        clipped = proposal["proposed_tasks"][0]["title"]
        self.assertEqual(len(clipped), fleet.COMMANDER_TITLE_MAX_CHARS)
        self.assertEqual(len(clips), 1)
        self.assertEqual(clips[0]["original_chars"], 48)
        self.assertTrue(clipped.endswith(fleet.COMMANDER_TITLE_TRUNCATION_MARKER))
        self.assertEqual(clipped[:5], "超长标题超")

    def test_title_at_and_under_cap_is_untouched(self):
        for length in (1, fleet.COMMANDER_TITLE_MAX_CHARS):
            item = candidate()
            item["title"] = "y" * length
            proposal = self.proposal(item)
            self.assertEqual(
                fleet._validate_commander_proposal(proposal, self.task), []
            )
            self.assertEqual(proposal["proposed_tasks"][0]["title"],
                             item["title"])

    def test_multiple_overlong_titles_each_leave_a_clip_record(self):
        first, second = candidate(), candidate()
        first["title"] = "a" * 41
        first["dedup_key"] = "first-key"
        second["title"] = "b" * 71
        second["dedup_key"] = "second-key"
        proposal = self.proposal(first)
        proposal["proposed_tasks"].append(second)
        clips = fleet._validate_commander_proposal(proposal, self.task)
        self.assertEqual([c["dedup_key"] for c in clips],
                         ["first-key", "second-key"])
        for task_item in proposal["proposed_tasks"]:
            self.assertLessEqual(
                len(task_item["title"]), fleet.COMMANDER_TITLE_MAX_CHARS
            )

    def test_other_invalid_fields_still_reject_the_whole_proposal(self):
        # The title relaxation must not relax any other rule: a blank problem
        # voids the proposal even when its title is the only overlong field.
        item = candidate()
        item["title"] = "z" * 50
        item["problem"] = "   "
        with self.assertRaisesRegex(ValueError, "invalid candidate fields"):
            fleet._validate_commander_proposal(self.proposal(item), self.task)
        item = candidate()
        item["title"] = "z" * 50
        item.pop("scope")
        with self.assertRaisesRegex(ValueError, "candidate fields do not match"):
            fleet._validate_commander_proposal(self.proposal(item), self.task)

    def test_candidate_refusal_exit_codes_match_cli_semantics(self):
        cases = (
            (fleet.CrossFamilyError("same family"), 2, "policy"),
            (fleet.NodeOfflineError("node offline"), 4, "channel_health"),
            (fleet.ModelNotOfferedError("not offered"), 5, "channel_health"),
            (fleet.ModelUnavailableError("probe failed"), 6, "channel_health"),
            (fleet.ModelUnverifiedError("unverified family"), 10, "channel_health"),
            (fleet.ContextMissingError("missing context"), 9, "policy"),
            (ValueError("bad value"), 1, "policy"),
        )
        for exc, expected, rejection_class in cases:
            with self.subTest(exc=type(exc).__name__):
                self.assertEqual(
                    fleet._commander_proposal_exit_code(exc), expected
                )
                self.assertIn(
                    expected, fleet.COMMANDER_PROPOSAL_EXIT_SEMANTICS
                )
                self.assertEqual(
                    fleet._commander_proposal_rejection_class(expected),
                    rejection_class,
                )


class CandidateExecutionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fleet-commander-py-")
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.repo = self.root / "repo"
        self.wt = self.root / "upstream-wt"
        make_repo(self.repo)
        self.base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "worktree", "add", "-q", "-b", "fleet/task-2",
            str(self.wt), self.base)
        os.environ["FLEET_HOME"] = str(self.home)
        subprocess.run(
            [str(FLEET_PATH), "init"], check=True, text=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env={**os.environ, "FLEET_HOME": str(self.home)},
        )
        self.conn = fleet.db_connect()
        self.conn.execute(
            "INSERT INTO goal(id,statement,status,created_at) VALUES(1,'g1','open',1)"
        )
        self.conn.execute(
            "INSERT INTO goal(id,statement,status,created_at) VALUES(2,'g2','open',1)"
        )
        self.conn.execute(
            "INSERT INTO task(id,goal_id,title,channel,family,status,cwd,created_at,"
            "role,commander_plan_revision,commander_through_event_id) "
            "VALUES(1,1,'commander','shell','none','running',?,1,'commander',0,0)",
            (str(self.repo.resolve()),),
        )
        self.conn.execute(
            "INSERT INTO task(id,goal_id,title,channel,family,status,cwd,created_at,"
            "role,worktree,worktree_branch) "
            "VALUES(2,1,'upstream','shell','none','done',?,1,'worker',?,"
            "'fleet/task-2')",
            (str(self.repo.resolve()), str(self.wt.resolve())),
        )
        self.conn.execute(
            "UPDATE task SET attempt=1,attempt_id='commander-attempt',"
            "lease='commander:goal-1',commander_lease_generation=1 WHERE id=1"
        )
        self.conn.execute(
            "INSERT INTO lease(resource,holder,acquired_at,expires_at,generation) "
            "VALUES('commander:goal-1','1',1,9999999999,1)"
        )
        self.conn.commit()
        self.live_processes = []

    def tearDown(self):
        for process in self.live_processes:
            process.terminate()
            process.wait(timeout=5)
        self.conn.close()
        self.tmp.cleanup()

    def commander(self):
        return self.conn.execute("SELECT * FROM task WHERE id=1").fetchone()

    def execution(self, base_task=2):
        return fleet._commander_candidate_execution(
            self.conn, self.commander(), {"base_task": base_task}
        )

    def apply_and_skipped(self, base_task=2):
        item = candidate(True)
        item["base_task"] = base_task
        proposal = {
            "goal_id": 1, "based_on_plan_revision": 0,
            "through_event_id": 0, "proposed_tasks": [item],
            "decisions": [], "next_wake": {"reason": "waiting_for_tasks"},
        }
        fleet._apply_commander_result(self.conn, self.commander(), proposal)
        row = self.conn.execute(
            "SELECT payload FROM event WHERE kind='commander.round'"
        ).fetchone()
        return json.loads(row["payload"])["skipped"]

    def test_valid_base_task_pins_declared_branch_tip_and_deliverable(self):
        (self.wt / "unique.txt").write_text("from upstream\n")
        git(self.wt, "add", "unique.txt")
        git(self.wt, "commit", "-qm", "upstream")
        branch_tip = git(self.repo, "rev-parse", "fleet/task-2")
        result = self.execution()
        self.assertTrue(result["worktree"])
        self.assertEqual(result["base_task"], 2)
        self.assertEqual(result["base_commit"], branch_tip)
        git(self.repo, "cat-file", "-e", f"{branch_tip}:unique.txt")

    def test_detached_worktree_is_rejected_instead_of_pinning_head(self):
        (self.wt / "unique.txt").write_text("from upstream\n")
        git(self.wt, "add", "unique.txt")
        git(self.wt, "commit", "-qm", "upstream")
        branch_tip = git(self.repo, "rev-parse", "fleet/task-2")
        git(self.wt, "checkout", "-q", "--detach", self.base)
        skipped = self.apply_and_skipped()
        self.assertEqual(len(skipped), 1)
        self.assertIn(f"fleet/task-2 tip {branch_tip}", skipped[0]["reason"])
        self.assertEqual(skipped[0]["environment"]["kind"], "worktree_identity")

    def test_terminal_worker_with_live_pid_is_rejected(self):
        process = subprocess.Popen(["sleep", "60"])
        self.live_processes.append(process)
        self.conn.execute("UPDATE task SET pid=? WHERE id=2", (process.pid,))
        self.conn.commit()
        skipped = self.apply_and_skipped()
        self.assertEqual(len(skipped), 1)
        self.assertIn("worker_alive", skipped[0]["reason"])
        self.assertEqual(skipped[0]["environment"]["kind"], "worker_alive")

    def test_worktree_must_be_checked_out_on_rows_declared_branch(self):
        other_wt = self.root / "other-wt"
        git(self.repo, "worktree", "add", "-q", "-b", "fleet/task-3",
            str(other_wt), self.base)
        self.conn.execute(
            "UPDATE task SET worktree=?,worktree_branch='fleet/task-3' WHERE id=2",
            (str(self.wt.resolve()),),
        )
        self.conn.commit()
        skipped = self.apply_and_skipped()
        self.assertEqual(len(skipped), 1)
        self.assertRegex(skipped[0]["reason"], "worktree_identity.*fleet/task-3")
        self.assertEqual(skipped[0]["environment"]["kind"], "worktree_identity")

    def test_worktree_branch_must_belong_to_its_task_id(self):
        git(self.wt, "branch", "-m", "fleet/task-99")
        self.conn.execute(
            "UPDATE task SET worktree_branch='fleet/task-99' WHERE id=2"
        )
        self.conn.commit()
        skipped = self.apply_and_skipped()
        self.assertEqual(len(skipped), 1)
        self.assertRegex(
            skipped[0]["reason"],
            r"worktree_identity.*fleet/task-99.*fleet/task-2",
        )
        self.assertEqual(
            skipped[0]["environment"]["kind"], "worktree_identity"
        )

    def test_dirty_target_and_dirty_upstream_are_rejected(self):
        (self.repo / "untracked.txt").write_text("dirty\n")
        with self.assertRaisesRegex(fleet.CommanderExecutionError, "uncommitted"):
            self.execution(None)
        (self.repo / "untracked.txt").unlink()
        (self.wt / "untracked.txt").write_text("dirty\n")
        with self.assertRaisesRegex(fleet.CommanderExecutionError, "base_task 2.*uncommitted"):
            self.execution()

    def test_missing_no_worktree_cross_goal_and_running_are_rejected(self):
        cases = (
            ("worktree=NULL,worktree_branch=NULL", "no Fleet worktree"),
            ("worktree='/definitely/missing/fleet-wt'", "worktree_missing"),
            ("goal_id=2", "different goal"),
            ("status='running'", "still running"),
            ("role='commander'", "not a worker"),
        )
        with self.assertRaisesRegex(fleet.CommanderExecutionError, "does not exist"):
            self.execution(999)
        for update, message in cases:
            with self.subTest(update=update):
                self.conn.execute(
                    "UPDATE task SET goal_id=1,status='done',role='worker',worktree=?,"
                    "worktree_branch='fleet/task-2' WHERE id=2",
                    (str(self.wt.resolve()),),
                )
                self.conn.execute(f"UPDATE task SET {update} WHERE id=2")
                self.conn.commit()
                with self.assertRaisesRegex(fleet.CommanderExecutionError, message):
                    self.execution()

    def test_review_target_must_be_terminal_worker_in_commanders_goal(self):
        commander = self.conn.execute(
            "SELECT * FROM task WHERE id=1"
        ).fetchone()
        item = candidate()
        item["review_of"] = 2
        self.assertEqual(
            fleet._commander_review_target(self.conn, commander, item), 2
        )
        cases = (
            ("goal_id=2", "different goal"),
            ("role='commander'", "not a worker"),
            ("status='running'", "not terminal"),
        )
        for update, message in cases:
            with self.subTest(update=update):
                self.conn.execute(
                    "UPDATE task SET goal_id=1,status='done',role='worker' WHERE id=2"
                )
                self.conn.execute(f"UPDATE task SET {update} WHERE id=2")
                self.conn.commit()
                with self.assertRaisesRegex(fleet.TaskRefError, message):
                    fleet._commander_review_target(self.conn, commander, item)

    def test_different_repository_is_rejected(self):
        other = self.root / "other"
        other_wt = self.root / "other-wt"
        make_repo(other, "other\n")
        git(other, "worktree", "add", "-q", "-b", "other/task-2",
            str(other_wt), "HEAD")
        self.conn.execute(
            "UPDATE task SET cwd=?,worktree=?,worktree_branch='other/task-2' "
            "WHERE id=2", (str(other.resolve()), str(other_wt.resolve()))
        )
        self.conn.commit()
        with self.assertRaisesRegex(fleet.CommanderExecutionError, "different repository"):
            self.execution()

    def test_non_git_targets_share_a_canonical_lease(self):
        plain = self.root / "plain"
        plain.mkdir()
        alias = plain / ".." / "plain"
        self.conn.execute("UPDATE task SET cwd=? WHERE id=1", (str(alias),))
        self.conn.commit()
        first = fleet._commander_candidate_execution(
            self.conn, self.commander(), {"base_task": None}
        )
        self.conn.execute("UPDATE task SET goal_id=2 WHERE id=1")
        self.conn.commit()
        second = fleet._commander_candidate_execution(
            self.conn, self.commander(), {}
        )
        self.assertFalse(first["worktree"])
        self.assertEqual(first["cwd"], str(plain.resolve()))
        self.assertEqual(first["lease"], second["lease"] )
        self.assertIn("commander-cwd:", first["lease"])

    def test_base_candidate_probe_is_limited_to_latest_32_rows(self):
        for task_id in range(3, 43):
            self.conn.execute(
                "INSERT INTO task(id,goal_id,title,channel,family,status,cwd,"
                "created_at,role,worktree,worktree_branch) VALUES(?,1,?,'shell',"
                "'none','done',?,1,'worker',?,?)",
                (task_id, f"worker {task_id}", str(self.repo.resolve()),
                 str(self.wt.resolve()), f"fleet/task-{task_id}"),
            )
        self.conn.commit()
        seen = []

        def baseline(row, **_kwargs):
            seen.append(row["id"])
            return {"branch_tip": f"commit-{row['id']}"}

        target = fleet._git_execution_target(str(self.repo.resolve()))
        with mock.patch.object(fleet, "_task_worktree_baseline", side_effect=baseline):
            candidates = fleet._commander_base_candidates(self.conn, 1, target)
        self.assertEqual(seen, list(range(42, 10, -1)))
        self.assertEqual([item["base_task"] for item in candidates], list(range(11, 43)))
        snapshot = fleet._commander_execution_snapshot(
            self.conn, 1, str(self.repo.resolve())
        )
        self.assertEqual(snapshot["base_candidates_omitted"], 9)

    def test_candidate_apply_probes_before_write_transaction(self):
        observed = []
        original = fleet._commander_candidate_execution

        def inspect(conn, commander, item):
            observed.append(conn.in_transaction)
            return original(conn, commander, item)

        with mock.patch.object(
            fleet, "_commander_candidate_execution", side_effect=inspect
        ):
            self.assertEqual(self.apply_and_skipped(), [])
        self.assertEqual(observed, [False])

    def test_autonomy_prompt_probes_before_write_transaction(self):
        state = fleet.autonomy_state(
            self.conn.execute("SELECT * FROM goal WHERE id=2").fetchone()
        )
        state.update({
            "enabled": True, "channel": "shell", "cwd": str(self.repo.resolve()),
            "cooldown_s": 0,
        })
        self.conn.execute(
            "UPDATE goal SET autonomy=? WHERE id=2", (json.dumps(state),)
        )
        self.conn.commit()
        driver = self.root / "driver.sh"
        driver.write_text("#!/usr/bin/env bash\necho '{}'\n")
        observed = []
        original = fleet._commander_execution_snapshot

        def inspect(conn, goal_id, cwd):
            observed.append(conn.in_transaction)
            return original(conn, goal_id, cwd)

        with mock.patch.dict(
            os.environ, {"FLEET_COMMANDER_SHELL_SCRIPT": str(driver)}
        ), mock.patch.object(
            fleet, "_commander_execution_snapshot", side_effect=inspect
        ):
            created = fleet.schedule_autonomy(self.conn, fleet.load_channels())
        self.assertEqual(len(created), 1)
        self.assertEqual(observed, [False])

    def test_environment_recovery_reports_each_cleared_candidate(self):
        self.conn.execute("UPDATE task SET status='done' WHERE id=1")
        state = fleet.autonomy_state(
            self.conn.execute("SELECT * FROM goal WHERE id=1").fetchone()
        )
        state["last_round_task"] = 1
        item1 = candidate(True)
        item1["dedup_key"] = "one"
        item1["base_task"] = None
        item2 = dict(item1, dedup_key="two")
        payload = {
            "proposed": [item1, item2],
            "skipped": [{
                "dedup_key": key,
                "reason": "dirty_target: blocked",
                "environment": {"kind": "dirty_target", "base_task": None},
            } for key in ("one", "two")],
        }
        fleet.log_event(
            self.conn, "commander.round", task_id=1, goal_id=1,
            payload=payload,
        )
        self.conn.commit()
        failure = fleet.CommanderExecutionError(
            "dirty_target: blocked", reason="dirty_target"
        )
        with mock.patch.object(
            fleet, "_commander_candidate_execution", side_effect=[{}, failure]
        ):
            recovery = fleet._commander_environment_recovery(self.conn, 1, state)
        self.assertEqual(recovery["round_task"], 1)
        self.assertEqual(recovery["resolved"], [{
            "dedup_key": "one", "kind": "dirty_target", "base_task": None,
        }])

    def test_only_fresh_policy_rejections_advance_the_wake_watermark(self):
        self.conn.execute("UPDATE task SET status='done' WHERE id=1")
        fleet.log_event(
            self.conn, "proposal.rejected", task_id=1, goal_id=1,
            payload={"reason": "dirty", "exit_code": 1,
                     "environment": {
                "kind": "dirty_target", "base_task": None,
            }},
        )
        self.assertEqual(fleet._goal_information_id(self.conn, 1), 0)
        for exit_code in (4, 5, 6, 10):
            fleet.log_event(
                self.conn, "proposal.rejected", task_id=1, goal_id=1,
                payload={"reason": "channel unavailable",
                         "exit_code": exit_code},
            )
            self.assertEqual(fleet._goal_information_id(self.conn, 1), 0)
        fleet.log_event(
            self.conn, "proposal.rejected", task_id=1, goal_id=1,
            payload={"reason": "same family", "exit_code": 2,
                     "rejection_class": "policy", "repeated": False},
        )
        policy_event = self.conn.execute(
            "SELECT MAX(id) FROM event"
        ).fetchone()[0]
        self.assertEqual(fleet._goal_information_id(self.conn, 1), policy_event)
        fleet.log_event(
            self.conn, "proposal.rejected", task_id=1, goal_id=1,
            payload={"reason": "same family again", "exit_code": 2,
                     "rejection_class": "policy", "repeated": True},
        )
        self.assertEqual(fleet._goal_information_id(self.conn, 1), policy_event)

    def test_repeated_rejection_uses_prior_round_candidate_fingerprint(self):
        item = candidate()
        first = fleet._commander_proposal_rejected(
            self.conn, self.commander(), item, "shell",
            fleet.CrossFamilyError("same family"),
        )
        self.assertEqual(first["rejection_class"], "policy")
        self.assertFalse(first["repeated"])
        fleet.log_event(
            self.conn, "commander.round", task_id=1, goal_id=1,
            payload={"proposed": [item], "skipped": [first]},
        )
        second = fleet._commander_proposal_rejected(
            self.conn, self.commander(), dict(item, title="renamed"), "shell",
            fleet.CrossFamilyError("same family"),
        )
        self.assertEqual(second["rejection_fingerprint"],
                         first["rejection_fingerprint"])
        self.assertTrue(second["repeated"])
        self.assertEqual(second["repeated_from_round"], 1)
        changed = fleet._commander_proposal_rejected(
            self.conn, self.commander(), dict(item, dedup_key="new-key"),
            "shell", fleet.CrossFamilyError("same family"),
        )
        self.assertFalse(changed["repeated"])
        fallback = {"title": "candidate", "channel": "shell",
                    "review_of": 2}
        same_fallback = dict(fallback, reason="a different refusal reason")
        changed_fallback = dict(fallback, channel="other")
        self.assertEqual(
            fleet._commander_proposal_rejection_fingerprint(fallback),
            fleet._commander_proposal_rejection_fingerprint(same_fallback),
        )
        self.assertNotEqual(
            fleet._commander_proposal_rejection_fingerprint(fallback),
            fleet._commander_proposal_rejection_fingerprint(changed_fallback),
        )
        self.assertFalse(fleet._commander_proposal_rejection_wakes({
            "exit_code": 6, "rejection_class": "channel_health",
        }))
        self.assertFalse(fleet._commander_proposal_rejection_wakes({
            "exit_code": 6, "rejection_class": "unexpected",
        }))

    def test_human_gate_precedes_large_execution_target_in_bounded_prompt(self):
        self.conn.execute(
            "INSERT INTO decision(goal_id,question,needs_user,ts) "
            "VALUES(1,'SHOULD WE SHIP?',1,1)"
        )
        self.conn.commit()
        huge = [{
            "base_task": i, "title": "T" * 40000, "status": "done",
            "commit": "a" * 40, "worktree_branch": f"fleet/task-{i}",
        } for i in range(2, 34)]
        snapshot = {
            "cwd": str(self.repo.resolve()),
            "git_target": fleet._git_execution_target(str(self.repo.resolve())),
            "dirty": False, "target_error": None,
            "base_candidates": huge, "base_candidates_omitted": 0,
        }
        goal = self.conn.execute("SELECT * FROM goal WHERE id=1").fetchone()
        # Force a low item-limit rung so the candidate-list omission pointer
        # is exercised independently of the rest of the ledger's current size.
        with mock.patch.object(
            fleet, "_commander_execution_snapshot", return_value=snapshot
        ), mock.patch.object(
            fleet, "COMMANDER_PROMPT_LADDER", ((100, 3), (0, 0))
        ):
            _cwd, body, _revision, _through = fleet.commander_construction(
                self.conn, goal, cwd=str(self.repo.resolve())
            )
        prompt = json.loads(body)
        self.assertLessEqual(len(body.encode()), fleet.COMMANDER_PROMPT_CAP)
        self.assertIn("SHOULD WE SHIP?", body)
        self.assertLess(body.index('"unresolved_needs_user"'),
                        body.index('"execution_target"'))
        self.assertEqual(
            prompt["execution_target"]["available_base_tasks"],
            prompt["base_candidates"],
        )
        omission = next(
            item for item in prompt["truncation"]["lists"]
            if item["field"] == "base_candidates"
        )
        self.assertEqual(omission["total"], 32)
        self.assertEqual(
            omission["included"] + omission["omitted"], omission["total"]
        )
        self.assertIn("SELECT id,title,status,worktree,worktree_branch",
                      omission["query"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
