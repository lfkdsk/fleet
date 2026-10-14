#!/usr/bin/env python3
"""Test eligible_channel, the one "where can this run now" resolver.

auto_review_channel used to BE this logic; a degrade after a channel-side
failure has to ask the same question with different constraints (exclude the
channel that just died, and -- for a plain worker -- no family rule at all).
These cases pin the generalization: the review caller's behaviour is unchanged
(daemon_smoke 20-30 own that end), and the new knobs do what they say.
"""

import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
FLEET = Path(os.environ.get("FLEET_UNDER_TEST", ROOT / "bin" / "fleet"))

CHANS = {
    "model_families": {"claude-*": "claude", "GPT-*": "gpt"},
    "channels": {
        "alpha": {"adapter": "shell.sh", "model": "claude-a",
                  "models": ["claude-a"]},
        "gamma": {"adapter": "shell.sh", "model": "claude-g",
                  "models": ["claude-g"]},
        "beta": {"adapter": "shell.sh", "model": "GPT-b",
                 "models": ["GPT-b"]},
        "remote": {"adapter": "ssh.sh", "model": "GPT-r",
                   "models": ["GPT-r"], "ssh_host": "somewhere"},
        "plain": {"adapter": "shell.sh", "family": "none"},
    },
}


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fleet-p24-", dir="/var/tmp")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        subprocess.run([str(FLEET), "init"], check=True,
                       env=dict(os.environ, FLEET_HOME=str(self.home)),
                       capture_output=True)
        loader = importlib.machinery.SourceFileLoader(
            f"fleet_p24_{time.time_ns()}", str(FLEET))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.mod = importlib.util.module_from_spec(spec)
        loader.exec_module(self.mod)
        old = os.environ.get("FLEET_HOME")
        os.environ["FLEET_HOME"] = str(self.home)
        self.addCleanup(lambda: os.environ.__setitem__("FLEET_HOME", old)
                        if old is not None
                        else os.environ.pop("FLEET_HOME", None))
        self.conn = self.mod.db_connect()
        self.addCleanup(self.conn.close)
        # Fresh successful probes: without them every candidate is refused as
        # never-probed, and the cases below would all pass for the wrong reason.
        now = int(time.time())
        for name in ("alpha", "gamma", "beta", "remote"):
            model = CHANS["channels"][name]["model"]
            self.conn.execute(
                "INSERT INTO model_probe(channel,model,ok,checked_at) "
                "VALUES(?,?,1,?)", (name, model, now))
        self.conn.commit()

    def pick(self, **kw):
        return self.mod.eligible_channel(self.conn, CHANS, **kw)

    def reasons(self, rejections):
        return {name: reason for name, reason in rejections}

    def test_exclude_is_honoured_and_recorded(self):
        # Candidates are evaluated in order and the first eligible one wins,
        # so rejections covers exactly what was considered before it -- not
        # every channel on the registry.
        name, rejections = self.pick(exclude=["alpha"])
        self.assertEqual(name, "beta")
        self.assertIn("excluded", self.reasons(rejections)["alpha"])

    def test_no_family_rule_allows_the_same_family(self):
        # A plain worker degrading off alpha may land on gamma: same family,
        # which only a REVIEW is forbidden from doing.
        name, _ = self.pick(exclude=["alpha", "beta"])
        self.assertEqual(name, "gamma")

    def test_forbid_family_still_refuses_that_family(self):
        name, rejections = self.pick(forbid_family="claude")
        self.assertEqual(name, "beta")
        self.assertIn("same family", self.reasons(rejections)["alpha"])
        # With the only other family excluded, every claude channel is refused
        # for the family reason and nothing is left.
        name, rejections = self.pick(forbid_family="claude", exclude=["beta"])
        self.assertIsNone(name)
        reasons = self.reasons(rejections)
        self.assertIn("same family", reasons["alpha"])
        self.assertIn("same family", reasons["gamma"])
        self.assertIn("excluded", reasons["beta"])

    def test_remote_and_familyless_are_never_candidates(self):
        name, rejections = self.pick(exclude=["alpha", "gamma", "beta"])
        self.assertIsNone(name)
        reasons = self.reasons(rejections)
        self.assertIn("remotely", reasons["remote"])
        self.assertIn("family=none", reasons["plain"])

    def test_nothing_eligible_returns_a_reason_per_channel(self):
        name, rejections = self.pick(
            exclude=list(CHANS["channels"]))
        self.assertIsNone(name)
        self.assertEqual(set(self.reasons(rejections)),
                         set(CHANS["channels"]))

    def test_review_wrapper_is_the_same_resolver(self):
        wrapped = self.mod.auto_review_channel(self.conn, CHANS, "claude")
        direct = self.pick(forbid_family="claude")
        self.assertEqual(wrapped[0], direct[0])
        self.assertEqual(self.reasons(wrapped[1]), self.reasons(direct[1]))


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
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ResolverTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=TapResult).run(suite)
    print("---")
    print(f"passed {result.testsRun - len(result.failures) - len(result.errors)} "
          f"/ {result.testsRun}")
    raise SystemExit(not result.wasSuccessful())
