PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);

-- Per-consumer watermarks (P3). The old global meta.commander_watermark was a
-- correctness bug: one consumer advancing it silently hid events from every
-- other consumer. scope is 'all' or 'goal:<id>'.
CREATE TABLE IF NOT EXISTS watermark(
  consumer TEXT NOT NULL, scope TEXT NOT NULL DEFAULT 'all',
  value INTEGER NOT NULL, PRIMARY KEY(consumer, scope));

CREATE TABLE IF NOT EXISTS goal(
  id INTEGER PRIMARY KEY, statement TEXT NOT NULL, acceptance TEXT,
  approval_gates TEXT, budget_cap INTEGER,
  status TEXT NOT NULL DEFAULT 'open',        -- open|done|abandoned
  created_by TEXT DEFAULT 'user', created_at INTEGER NOT NULL,
  -- P8: newline-separated --context file paths, spliced into every task's
  -- prompt (after the preamble, before the spec); merged with the task's own
  -- --context, goal's first.
  context TEXT,
  -- P19: opt-in cold-start commander state. JSON is used so policy knobs
  -- can evolve without a migration per knob; the daemon is the sole writer.
  autonomy TEXT,
  -- P22: opt-in closure/commander gate for mechanical acceptance evidence.
  verify_required INTEGER NOT NULL DEFAULT 0);

CREATE TABLE IF NOT EXISTS plan(
  id INTEGER PRIMARY KEY, goal_id INTEGER NOT NULL REFERENCES goal(id),
  revision INTEGER NOT NULL, dag TEXT, rules TEXT,
  rationale TEXT NOT NULL, created_at INTEGER NOT NULL,
  UNIQUE(goal_id, revision));

CREATE TABLE IF NOT EXISTS task(
  id INTEGER PRIMARY KEY,
  goal_id INTEGER REFERENCES goal(id), parent_id INTEGER REFERENCES task(id),
  title TEXT NOT NULL, spec_path TEXT,
  role TEXT NOT NULL DEFAULT 'worker',       -- worker|commander
  channel TEXT NOT NULL, family TEXT NOT NULL, model TEXT, effort TEXT,
  status TEXT NOT NULL DEFAULT 'queued',      -- queued|running|done|failed|cancelled
  cwd TEXT NOT NULL, deps TEXT NOT NULL DEFAULT '', lease TEXT,
  priority INTEGER NOT NULL DEFAULT 0,
  attempt INTEGER NOT NULL DEFAULT 0, max_attempts INTEGER NOT NULL DEFAULT 1,
  -- C0: opaque identity of the most recently launched attempt. `attempt` is
  -- still the human-facing retry count; callbacks authenticate with this id.
  attempt_id TEXT,
  pid INTEGER, pid_starttime INTEGER, session_id TEXT, exit_code INTEGER,
  run_dir TEXT, out_path TEXT, log_path TEXT,
  review_of INTEGER REFERENCES task(id), lens TEXT, timeout_s INTEGER,
  created_at INTEGER NOT NULL, started_at INTEGER, ended_at INTEGER,
  verdict TEXT, verdict_by TEXT,
  -- P7: a --worktree task runs in a private worktree. worktree_branch is the
  -- planned task-owned branch name, recorded at enqueue as the marker that
  -- launch() turns into a real worktree. Commander workers include a ledger
  -- hash because their target repo may be shared across FLEET_HOMEs; worktree
  -- stays NULL until the worktree actually exists.
  worktree TEXT, worktree_branch TEXT,
  -- P9: the model/agent that ACTUALLY ran, stamped at launch from the same
  -- variables the adapter received (FLEET_MODEL/FLEET_AGENT). Display must
  -- never read channels.json's current default for a historical task -- that
  -- file changes, and "what the config would run now" is not "what ran then".
  -- NULL until first launch; displayed as '-'.
  resolved_model TEXT, resolved_agent TEXT,
  -- P13: when set, the worktree's base is this task's worktree branch tip,
  -- not the repo HEAD. --dep alone orders execution; --dep-base makes the
  -- dep's code the baseline, so a fix task does not silently start from a
  -- base that predates the fix it builds on.
  base_task INTEGER REFERENCES task(id),
  -- P17: the exact 40-char commit this task's worktree must branch from,
  -- captured when the handoff was built. base_task and base_commit answer
  -- different questions: a dep only ORDERS execution and names a branch that
  -- keeps moving, while base_commit PINS the content -- the upstream branch
  -- advancing after the fix was enqueued must not change what the fix reads.
  -- Priority in ensure_worktree: base_commit > base_task > repo HEAD.
  base_commit TEXT,
  -- Immutable input fence for a commander task. The proposal must echo both.
  commander_plan_revision INTEGER, commander_through_event_id INTEGER,
  -- C control fence: explicit/manual commanders are independent of the
  -- autonomy switch; daemon-created commanders freeze the policy generation.
  commander_origin TEXT, commander_policy_generation INTEGER,
  commander_lease_generation INTEGER);

CREATE TABLE IF NOT EXISTS attempt(
  id INTEGER PRIMARY KEY, attempt_id TEXT NOT NULL UNIQUE,
  task_id INTEGER NOT NULL REFERENCES task(id),
  generation INTEGER NOT NULL, status TEXT NOT NULL,
  pid INTEGER, pid_starttime INTEGER,
  run_dir TEXT NOT NULL, out_path TEXT NOT NULL, log_path TEXT NOT NULL,
  started_at INTEGER NOT NULL, ended_at INTEGER, exit_code INTEGER,
  unsigned_ok INTEGER NOT NULL DEFAULT 0,
  UNIQUE(task_id, generation));

CREATE TABLE IF NOT EXISTS event(
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL,
  task_id INTEGER, goal_id INTEGER, kind TEXT NOT NULL, payload TEXT);

CREATE TABLE IF NOT EXISTS message(
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL,
  from_agent TEXT NOT NULL, to_agent TEXT NOT NULL,
  topic TEXT, body TEXT, reply_to INTEGER, read_at INTEGER, attempt_id TEXT);

CREATE TABLE IF NOT EXISTS claim(
  id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
  claim TEXT NOT NULL, evidence TEXT,
  status TEXT NOT NULL DEFAULT 'unverified',  -- unverified|confirmed|refuted
  resolution TEXT,                            -- fixed|rebutted|deadlock|user
  verified_by INTEGER, verified_at INTEGER, ts INTEGER NOT NULL, attempt_id TEXT);

CREATE TABLE IF NOT EXISTS review(
  id INTEGER PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
  reviewer_task_id INTEGER REFERENCES task(id),
  lens TEXT NOT NULL, channel TEXT, family TEXT, verdict TEXT, evidence TEXT,
  round INTEGER NOT NULL DEFAULT 1, ts INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS artifact(
  id INTEGER PRIMARY KEY, task_id INTEGER REFERENCES task(id),
  kind TEXT, path TEXT, sha256 TEXT, bytes INTEGER, summary TEXT, ts INTEGER NOT NULL,
  attempt_id TEXT);

CREATE TABLE IF NOT EXISTS lease(
  resource TEXT PRIMARY KEY, holder TEXT, acquired_at INTEGER, expires_at INTEGER,
  generation INTEGER NOT NULL DEFAULT 0);

CREATE TABLE IF NOT EXISTS budget(
  channel TEXT NOT NULL, period TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0, quota INTEGER,
  PRIMARY KEY(channel, period));

CREATE TABLE IF NOT EXISTS decision(
  id INTEGER PRIMARY KEY, goal_id INTEGER REFERENCES goal(id),
  task_id INTEGER REFERENCES task(id), question TEXT NOT NULL,
  verdict TEXT, evidence TEXT, needs_user INTEGER NOT NULL DEFAULT 0,
  resolved_at INTEGER, ts INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS model_probe(
  channel TEXT NOT NULL, model TEXT NOT NULL,
  ok INTEGER NOT NULL, checked_at INTEGER NOT NULL, note TEXT,
  PRIMARY KEY(channel, model));

CREATE INDEX IF NOT EXISTS idx_task_status ON task(status);
CREATE INDEX IF NOT EXISTS idx_event_task ON event(task_id);
CREATE INDEX IF NOT EXISTS idx_event_kind_task ON event(kind, task_id);
CREATE INDEX IF NOT EXISTS idx_claim_task ON claim(task_id);
CREATE INDEX IF NOT EXISTS idx_attempt_task ON attempt(task_id, generation);

-- P22: goal-owned version history and commit-bound execution evidence.
CREATE TABLE IF NOT EXISTS check_spec(
  id INTEGER PRIMARY KEY, goal_id INTEGER NOT NULL REFERENCES goal(id),
  version INTEGER NOT NULL, spec_hash TEXT NOT NULL UNIQUE, body TEXT NOT NULL,
  created_at REAL NOT NULL, UNIQUE(goal_id, version));

CREATE TABLE IF NOT EXISTS check_run(
  id TEXT PRIMARY KEY, task_id INTEGER NOT NULL REFERENCES task(id),
  attempt INTEGER NOT NULL, commit_sha TEXT NOT NULL, spec_hash TEXT NOT NULL,
  check_id TEXT NOT NULL, argv TEXT NOT NULL, cwd TEXT NOT NULL,
  started_at REAL NOT NULL, ended_at REAL, exit_code INTEGER,
  stdout_path TEXT NOT NULL, stderr_path TEXT NOT NULL,
  stdout_hash TEXT, stderr_hash TEXT, timed_out INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL, pgid INTEGER, pgid_starttime INTEGER,
  runner_pid INTEGER, runner_starttime INTEGER,
  -- B3: runner_token_hash stores a key id plus an HMAC of this row identity
  -- and the nonce. runner_token is NULL until the trusted runner finishes.
  runner_token_hash TEXT, runner_token TEXT,
  delivery_clean INTEGER NOT NULL DEFAULT 0, detail TEXT,
  UNIQUE(task_id, attempt, commit_sha, spec_hash, check_id));
-- Ephemeral capability consumed by event_checks_resealed_guard in the same
-- transaction. Keeping its UDF guard off the event table lets independent
-- SQLite writers append ordinary events without defining Fleet's UDF.
CREATE TABLE IF NOT EXISTS check_reseal_permit(
  id INTEGER PRIMARY KEY CHECK(id=1), nonce TEXT NOT NULL);

CREATE INDEX IF NOT EXISTS idx_check_spec_goal
  ON check_spec(goal_id, version);
CREATE INDEX IF NOT EXISTS idx_check_run_task
  ON check_run(task_id, started_at);
-- B4: trigger-integrity latch and passed-run witnesses live in event. These
-- audit rows are append-only; checks.resealed supersedes a latch without
-- erasing history. The guards are themselves in the protected trigger set.
CREATE TRIGGER IF NOT EXISTS event_check_audit_no_update
BEFORE UPDATE ON event
WHEN OLD.kind IN ('check.passed','check.passed_witness','check.tampered','checks.sealed',
                  'checks.resealed','goal.verify_changed')
  OR NEW.kind IN ('check.passed','check.passed_witness','check.tampered','checks.sealed',
                  'checks.resealed','goal.verify_changed')
BEGIN SELECT RAISE(ABORT, 'check audit events are append-only'); END;
CREATE TRIGGER IF NOT EXISTS event_check_audit_no_delete
BEFORE DELETE ON event
WHEN OLD.kind IN ('check.passed','check.passed_witness','check.tampered','checks.sealed',
                  'checks.resealed','goal.verify_changed')
BEGIN SELECT RAISE(ABORT, 'check audit events are append-only'); END;
CREATE TRIGGER IF NOT EXISTS event_checks_resealed_guard
BEFORE INSERT ON event
WHEN NEW.kind='checks.resealed'
BEGIN
  SELECT RAISE(ABORT, 'checks.resealed requires fleet checks reseal')
  WHERE NOT EXISTS (
    SELECT 1 FROM check_reseal_permit
    WHERE id=1 AND nonce=json_extract(NEW.payload,'$.reseal_nonce')
  );
  DELETE FROM check_reseal_permit WHERE id=1;
END;
CREATE TRIGGER IF NOT EXISTS check_reseal_permit_insert_guard
BEFORE INSERT ON check_reseal_permit
WHEN fleet_verify_authorized() != 2
BEGIN SELECT RAISE(ABORT, 'reseal permit requires fleet checks reseal'); END;
CREATE TRIGGER IF NOT EXISTS goal_verify_required_guard
BEFORE UPDATE OF verify_required ON goal
WHEN NEW.verify_required IS NOT OLD.verify_required
 AND fleet_verify_authorized() != 1
BEGIN SELECT RAISE(ABORT, 'verify_required changes require fleet goal verify-required'); END;
CREATE TRIGGER IF NOT EXISTS goal_verify_required_audit
AFTER UPDATE OF verify_required ON goal
WHEN NEW.verify_required IS NOT OLD.verify_required
BEGIN
  INSERT INTO event(ts,goal_id,kind,payload) VALUES(
    unixepoch(), NEW.id, 'goal.verify_changed',
    json_object(
      'from', json(CASE WHEN OLD.verify_required != 0 THEN 'true' ELSE 'false' END),
      'to', json(CASE WHEN NEW.verify_required != 0 THEN 'true' ELSE 'false' END)));
END;
CREATE TRIGGER IF NOT EXISTS check_spec_no_update BEFORE UPDATE ON check_spec
BEGIN SELECT RAISE(ABORT, 'check_spec is immutable'); END;
CREATE TRIGGER IF NOT EXISTS check_spec_no_delete BEFORE DELETE ON check_spec
BEGIN SELECT RAISE(ABORT, 'check_spec is immutable'); END;
CREATE TRIGGER IF NOT EXISTS check_run_terminal_no_update BEFORE UPDATE ON check_run
WHEN OLD.status IN ('passed','failed','infrastructure','tampered')
 AND NOT (OLD.status != 'tampered' AND NEW.status = 'tampered')
BEGIN SELECT RAISE(ABORT, 'terminal check_run is immutable'); END;
CREATE TRIGGER IF NOT EXISTS check_run_token_hash_no_update
BEFORE UPDATE OF runner_token_hash ON check_run
WHEN NEW.runner_token_hash IS NOT OLD.runner_token_hash
 AND NOT (OLD.status IN ('pending','running')
          AND NEW.status IN ('infrastructure','tampered'))
BEGIN SELECT RAISE(ABORT, 'check_run token identity is immutable'); END;
CREATE TRIGGER IF NOT EXISTS check_run_identity_no_update BEFORE UPDATE OF
  task_id,attempt,commit_sha,spec_hash,check_id,argv,cwd,started_at,
  stdout_path,stderr_path,delivery_clean ON check_run
BEGIN SELECT RAISE(ABORT, 'check_run execution identity is immutable'); END;
CREATE TRIGGER IF NOT EXISTS check_run_process_no_rewrite BEFORE UPDATE ON check_run
WHEN (OLD.runner_pid IS NOT NULL AND
      (NEW.runner_pid IS NOT OLD.runner_pid OR
       NEW.runner_starttime IS NOT OLD.runner_starttime))
  OR (OLD.pgid IS NOT NULL AND
      (NEW.pgid IS NOT OLD.pgid OR NEW.pgid_starttime IS NOT OLD.pgid_starttime))
BEGIN SELECT RAISE(ABORT, 'check_run process identity is immutable'); END;
CREATE TRIGGER IF NOT EXISTS check_run_status_transition BEFORE UPDATE OF status ON check_run
WHEN NOT (
  (OLD.status='pending' AND NEW.status IN ('running','infrastructure','tampered'))
  OR (OLD.status='running' AND NEW.status IN ('passed','failed','infrastructure','tampered'))
  OR (OLD.status IN ('passed','failed','infrastructure') AND NEW.status='tampered')
)
BEGIN SELECT RAISE(ABORT, 'invalid check_run status transition'); END;
CREATE TRIGGER IF NOT EXISTS check_run_no_delete BEFORE DELETE ON check_run
BEGIN SELECT RAISE(ABORT, 'check_run is immutable'); END;
