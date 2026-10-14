"""Opt-in, commit-bound mechanical acceptance checks for Fleet.

The daemon only prepares identities and launches trusted detached runners.
Project commands receive a small environment and never receive the ledger path
or runner HMAC key. This is a protocol boundary, not an OS sandbox: same-uid
code can still read or rewrite Fleet files, including matching audit evidence.
The checks below detect ordinary trigger-drop/row-forgery paths; prevention
requires another uid or a container.
"""

import fcntl
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time
import uuid


TERMINAL_RUNS = ("passed", "failed", "infrastructure", "tampered")
MISSING_DEPENDENCY_MARKERS = (
    "ModuleNotFoundError:",
    "No module named ",
    "Cannot find module",
    "error while loading shared libraries",
    "FileNotFoundError:",
    "PermissionError:",
)
CHECK_ENV_ALLOW = frozenset({
    "PATH", "HOME", "LANG", "LANGUAGE", "LC_ALL", "LC_CTYPE",
    "TZ", "TMPDIR", "TMP", "TEMP", "SYSTEMROOT",
})
CHECK_ENV_DENY_PREFIXES = ("FLEET_", "ANTHROPIC_", "CLAUDE_")
DEFAULT_TIMEOUT_MAX = 3600
ABSOLUTE_TIMEOUT_MAX = 86400
TRIGGER_SEAL_KEY = "checks.trigger_schema_hash"
TRIGGER_TAMPER_KEY = "checks.trigger_tampered"
TRIGGER_TAMPER_QUESTION = (
    "mechanical checks tampered: required schema triggers changed; "
    "inspect the ledger, then run `fleet checks reseal`"
)
LEGACY_CHECK_TRIGGER_NAMES = frozenset({
    "check_spec_no_update",
    "check_spec_no_delete",
    "check_run_terminal_no_update",
    "check_run_token_hash_no_update",
    "check_run_identity_no_update",
    "check_run_process_no_rewrite",
    "check_run_status_transition",
    "check_run_no_delete",
})
P22_CHECK_TRIGGER_NAMES = frozenset({
    "check_spec_no_update",
    "check_spec_no_delete",
    "check_run_terminal_no_update",
    "check_run_no_delete",
})
B3_CHECK_TRIGGER_NAMES = LEGACY_CHECK_TRIGGER_NAMES | frozenset({
    "goal_verify_required_guard",
    "goal_verify_required_audit",
})
RUNNER_PROOF_PREFIX = "hmac-sha256"
TRIGGER_SCHEMA_PATH = Path(__file__).resolve().parents[1] / "schema.sql"
_EXPECTED_TRIGGER_CACHE = None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def _canonical_trigger_sql(sql):
    sql = re.sub(
        r"^CREATE\s+TRIGGER\s+IF\s+NOT\s+EXISTS\s+",
        "CREATE TRIGGER ", sql.strip(), flags=re.I,
    )
    sql = sql.rstrip(";")
    compact = []
    quote = None
    index = 0
    while index < len(sql):
        char = sql[index]
        if quote is not None:
            compact.append(char)
            if char == quote:
                if index + 1 < len(sql) and sql[index + 1] == quote:
                    compact.append(sql[index + 1])
                    index += 1
                else:
                    quote = None
        elif char in ("'", '"'):
            quote = char
            compact.append(char)
        elif not char.isspace():
            compact.append(char)
        index += 1
    return "".join(compact)


def _expected_triggers(schema_path=None):
    """Return every schema trigger's name and SQL, cached by file stamp.

    schema.sql is deliberately the single source of truth used by both fresh
    ledgers and reseal. sqlite_master removes IF NOT EXISTS and the trailing
    semicolon, so canonicalization removes exactly those representation
    differences before hashing. The optional path exists for cache regression
    coverage; production callers always use the repository schema.sql.
    """
    global _EXPECTED_TRIGGER_CACHE
    path = Path(schema_path) if schema_path is not None else TRIGGER_SCHEMA_PATH
    stat = path.stat()
    cache_key = (str(path), stat.st_mtime_ns, stat.st_size)
    if (_EXPECTED_TRIGGER_CACHE is not None
            and _EXPECTED_TRIGGER_CACHE[0] == cache_key):
        return _EXPECTED_TRIGGER_CACHE[1]
    schema = path.read_text()
    triggers = {}
    for match in re.finditer(
            r"CREATE\s+TRIGGER\s+IF\s+NOT\s+EXISTS\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)\b.*?\bON\s+"
            r"(?P<table>[A-Za-z_][A-Za-z0-9_]*)\b.*?\bEND\s*;",
            schema, flags=re.I | re.S):
        name = match.group(1)
        triggers[name] = match.group(0)
    if not triggers:
        raise RuntimeError("schema.sql contains no triggers")
    _EXPECTED_TRIGGER_CACHE = (cache_key, triggers)
    return triggers


def _actual_triggers(conn):
    return {
        row["name"]: row["sql"] or ""
        for row in conn.execute(
            "SELECT name,sql FROM sqlite_master WHERE type='trigger'"
        ).fetchall()
    }


def _trigger_hash(triggers):
    body = "\n".join(
        f"{name}\0{_canonical_trigger_sql(sql)}"
        for name, sql in sorted(triggers.items())
    )
    return digest(body.encode())


def _trigger_diff(conn):
    expected_raw = _expected_triggers()
    expected = {name: _canonical_trigger_sql(sql)
                for name, sql in expected_raw.items()}
    actual_raw = _actual_triggers(conn)
    actual = {name: _canonical_trigger_sql(sql)
              for name, sql in actual_raw.items()}
    missing = sorted(set(expected) - set(actual))
    unexpected = sorted(set(actual) - set(expected))
    changed = sorted(
        name for name in set(expected) & set(actual)
        if expected[name] != actual[name]
    )
    return expected_raw, expected, actual, missing, changed, unexpected


def _meta_value(conn, key):
    row = conn.execute("SELECT v FROM meta WHERE k=?", (key,)).fetchone()
    return row["v"] if row else None


def _trigger_latch_event(conn):
    """Whether a trigger-tamper event has not been superseded by reseal."""
    for row in conn.execute(
            "SELECT id,task_id,kind,payload FROM event "
            "WHERE kind IN ('check.tampered','checks.resealed') "
            "ORDER BY id DESC"
    ).fetchall():
        if row["kind"] == "checks.resealed":
            return None
        if row["task_id"] is None:
            return row
        try:
            payload = json.loads(row["payload"] or "{}")
        except (TypeError, ValueError):
            continue
        if payload.get("reason") == "triggers":
            return row
    return None


def _trigger_latched(conn):
    return _trigger_latch_event(conn) is not None


def _seal_history_present(conn):
    return bool(conn.execute(
        "SELECT 1 FROM event "
        "WHERE kind IN ('checks.sealed','check.tampered') LIMIT 1"
    ).fetchone())


def _unaudited_passed_runs(conn):
    """Return passed run ids without the atomic check.passed side record."""
    first_b4_seal = conn.execute(
        "SELECT id FROM event WHERE kind='checks.sealed' "
        "AND json_valid(payload) AND json_extract(payload,'$.witness')=1 "
        "ORDER BY id LIMIT 1"
    ).fetchone()
    if not first_b4_seal:
        return []
    witnessed = set()
    for event in conn.execute(
            "SELECT task_id,payload FROM event "
            "WHERE kind='check.passed_witness'"
    ).fetchall():
        try:
            payload = json.loads(event["payload"] or "{}")
        except (TypeError, ValueError):
            continue
        witnessed.add((
            event["task_id"], payload.get("run"), payload.get("check_id"),
            payload.get("commit"), payload.get("spec_hash"),
            payload.get("exit_code"), bool(payload.get("timed_out")),
            payload.get("runner_nonce"), payload.get("runner_proof"),
        ))
    missing = []
    for row in conn.execute(
            "SELECT id,task_id,check_id,commit_sha,spec_hash,exit_code,timed_out,"
            "runner_token,runner_token_hash "
            "FROM check_run WHERE status='passed' "
            "AND runner_token_hash LIKE ?",
            (RUNNER_PROOF_PREFIX + ":%",),
    ).fetchall():
        identity = (
            row["task_id"], row["id"], row["check_id"],
            row["commit_sha"], row["spec_hash"], row["exit_code"],
            bool(row["timed_out"]),
            row["runner_token"], row["runner_token_hash"],
        )
        if identity not in witnessed:
            missing.append(row["id"])
    return sorted(missing)


def _backfill_passed_witnesses(conn, api):
    """Upgrade authenticated B3 green rows without trusting rows alone."""
    legacy = set()
    for event in conn.execute(
            "SELECT task_id,payload FROM event WHERE kind='check.passed'"
    ).fetchall():
        try:
            payload = json.loads(event["payload"] or "{}")
        except (TypeError, ValueError):
            continue
        legacy.add((
            event["task_id"], payload.get("run"), payload.get("check_id"),
            payload.get("commit"), payload.get("spec_hash"),
            payload.get("exit_code"), bool(payload.get("timed_out")),
        ))
    for row in conn.execute(
            "SELECT * FROM check_run WHERE status='passed'"
    ).fetchall():
        identity = (
            row["task_id"], row["id"], row["check_id"], row["commit_sha"],
            row["spec_hash"], row["exit_code"], bool(row["timed_out"]),
        )
        if (identity not in legacy or not runner_proof_valid(
                api.fleet_home(), row["runner_token"], row["task_id"],
                row["attempt"], row["commit_sha"], row["check_id"],
                row["runner_token_hash"])):
            continue
        api.log_event(
            conn, "check.passed_witness", task_id=row["task_id"],
            payload={
                "run": row["id"], "check_id": row["check_id"],
                "commit": row["commit_sha"], "spec_hash": row["spec_hash"],
                "exit_code": row["exit_code"],
                "timed_out": bool(row["timed_out"]),
                "runner_nonce": row["runner_token"],
                "runner_proof": row["runner_token_hash"], "migrated": True,
            },
        )


def trigger_set_intact(conn):
    """Cheap fail-closed predicate used by every passed() call."""
    if (_trigger_latched(conn)
            or _meta_value(conn, TRIGGER_TAMPER_KEY) is not None):
        return False
    _, _, _, missing, changed, unexpected = _trigger_diff(conn)
    return not (missing or changed or unexpected
                or _unaudited_passed_runs(conn))


def _record_trigger_tamper(conn, api, missing, changed, unexpected,
                           unaudited_passed=None):
    if _trigger_latched(conn):
        return False
    payload = {
        "reason": "triggers", "missing": missing,
        "changed": changed, "unexpected": unexpected,
        "unaudited_passed": sorted(unaudited_passed or []),
    }
    conn.execute(
        "INSERT INTO meta(k,v) VALUES(?,?) "
        "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
        (TRIGGER_TAMPER_KEY, json.dumps(payload, sort_keys=True)),
    )
    api.log_event(conn, "check.tampered", payload=payload)
    if not conn.execute(
        "SELECT 1 FROM decision WHERE question=? AND needs_user=1 "
        "AND resolved_at IS NULL", (TRIGGER_TAMPER_QUESTION,),
    ).fetchone():
        cur = conn.execute(
            "INSERT INTO decision(goal_id,task_id,question,verdict,evidence,"
            "needs_user,ts) VALUES(NULL,NULL,?,'conflict',NULL,1,?)",
            (TRIGGER_TAMPER_QUESTION, api.now()),
        )
        api.log_event(
            conn, "decision.add",
            payload={"decision_id": cur.lastrowid,
                     "question": TRIGGER_TAMPER_QUESTION},
        )
    conn.commit()
    return True


def check_trigger_integrity(conn, api, during_init=False, triggers_before=None):
    """Validate the complete trigger set and latch any discrepancy.

    Known legacy sets are accepted as upgrade sources only before any seal
    history, or when their exact aggregate hash still matches a B3 seal.
    """
    tables = {row[0] for row in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    ).fetchall()}
    if not {"goal", "check_spec", "check_run"}.issubset(tables):
        return True
    expected_raw, expected, actual, missing, changed, unexpected = _trigger_diff(conn)
    unaudited_passed = _unaudited_passed_runs(conn)
    observed_missing = list(missing)
    observed_changed = list(changed)
    observed_unexpected = list(unexpected)
    if during_init and triggers_before is not None:
        before = {name: _canonical_trigger_sql(sql)
                  for name, sql in triggers_before.items()}
        before_missing = sorted(set(expected) - set(before))
        before_changed = sorted(
            name for name in set(expected) & set(before)
            if expected[name] != before[name]
        )
        before_unexpected = sorted(set(before) - set(expected))
        known_upgrade_source = set(before) in (
            P22_CHECK_TRIGGER_NAMES, LEGACY_CHECK_TRIGGER_NAMES,
            B3_CHECK_TRIGGER_NAMES,
        )
        ignored_upgrade_changes = (
            {"check_run_terminal_no_update"}
            if set(before) in (P22_CHECK_TRIGGER_NAMES,
                               LEGACY_CHECK_TRIGGER_NAMES)
            else set()
        )
        source_unchanged = (
            not before_unexpected
            and not any(name in before_changed
                        for name in (set(before) - ignored_upgrade_changes))
        )
        sealed_upgrade = (
            known_upgrade_source and source_unchanged
            and _meta_value(conn, TRIGGER_SEAL_KEY)
            == _trigger_hash(triggers_before)
        )
        unsealed_upgrade = (
            known_upgrade_source and source_unchanged
            and _meta_value(conn, TRIGGER_SEAL_KEY) is None
            and not _seal_history_present(conn)
        )
        if (not (sealed_upgrade or unsealed_upgrade)
                and (before_missing or before_changed or before_unexpected)):
            observed_missing = sorted(set(observed_missing) | set(before_missing))
            observed_changed = sorted(set(observed_changed) | set(before_changed))
            observed_unexpected = sorted(
                set(observed_unexpected) | set(before_unexpected)
            )
    integrity_issue = bool(
        observed_missing or observed_changed or observed_unexpected
        or unaudited_passed
    )
    if integrity_issue:
        _record_trigger_tamper(
            conn, api, observed_missing, observed_changed, observed_unexpected,
            unaudited_passed,
        )
    if not integrity_issue and not (missing or changed or unexpected):
        seal = _trigger_hash(expected_raw)
        if _meta_value(conn, TRIGGER_SEAL_KEY) != seal:
            conn.execute(
                "INSERT INTO meta(k,v) VALUES(?,?) "
                "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                (TRIGGER_SEAL_KEY, seal),
            )
        b4_seal = conn.execute(
            "SELECT 1 FROM event WHERE kind='checks.sealed' "
            "AND json_valid(payload) "
            "AND json_extract(payload,'$.witness')=1 LIMIT 1"
        ).fetchone()
        if not b4_seal:
            _backfill_passed_witnesses(conn, api)
            api.log_event(conn, "checks.sealed", payload={
                "trigger_hash": seal, "witness": 1,
            })
        if conn.in_transaction:
            conn.commit()
        return not (_trigger_latched(conn)
                    or _meta_value(conn, TRIGGER_TAMPER_KEY) is not None)
    return False


def reseal(conn, api):
    allowed, caller = operator_allowed(api.fleet_home())
    if not allowed:
        raise ValueError(
            "checks reseal is an operator operation; Fleet tasks and "
            "adapter descendants cannot reseal check triggers"
        )
    expected_raw = _expected_triggers()
    conn.execute("BEGIN IMMEDIATE")
    try:
        for name in sorted(set(_actual_triggers(conn)) | set(expected_raw)):
            conn.execute(f'DROP TRIGGER IF EXISTS "{name}"')
        for sql in expected_raw.values():
            conn.execute(sql)
        _, _, _, missing, changed, unexpected = _trigger_diff(conn)
        if missing or changed or unexpected:
            raise RuntimeError("rebuilt check trigger set did not match schema.sql")
        seal = _trigger_hash(expected_raw)
        conn.execute("DELETE FROM meta WHERE k=?", (TRIGGER_TAMPER_KEY,))
        conn.execute(
            "INSERT INTO meta(k,v) VALUES(?,?) "
            "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
            (TRIGGER_SEAL_KEY, seal),
        )
        conn.execute(
            "UPDATE decision SET resolved_at=? WHERE question=? "
            "AND needs_user=1 AND resolved_at IS NULL",
            (api.now(), TRIGGER_TAMPER_QUESTION),
        )
        reseal_nonce = secrets.token_urlsafe(32)
        conn.create_function("fleet_verify_authorized", 0, lambda: 2)
        try:
            conn.execute(
                "INSERT INTO check_reseal_permit(id,nonce) VALUES(1,?)",
                (reseal_nonce,),
            )
        finally:
            conn.create_function("fleet_verify_authorized", 0, lambda: 0)
        api.log_event(
            conn, "checks.resealed",
            payload={
                "trigger_hash": seal, "caller": caller,
                "reseal_nonce": reseal_nonce,
            },
        )
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    return seal


def _token_path(fleet_home):
    return Path(fleet_home) / ".runner-token"


def _read_keyring(fleet_home):
    path = _token_path(fleet_home)
    try:
        if path.stat().st_mode & 0o077:
            return None
        value = json.loads(path.read_text())
    except (OSError, ValueError, TypeError):
        return None
    if (not isinstance(value, dict) or value.get("version") != 1
            or not isinstance(value.get("current"), str)
            or not isinstance(value.get("keys"), dict)
            or value["current"] not in value["keys"]
            or any(not isinstance(k, str) or not isinstance(v, str)
                   for k, v in value["keys"].items())):
        return None
    return value


def _write_keyring(fleet_home, keyring):
    home = Path(fleet_home)
    home.mkdir(parents=True, exist_ok=True)
    path = _token_path(home)
    temporary = home / f".runner-token.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        data = (json.dumps(keyring, sort_keys=True, separators=(",", ":"))
                + "\n").encode()
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def _with_token_lock(fleet_home, rotate):
    home = Path(fleet_home)
    home.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(str(home / ".runner-token.lock"),
                      os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        keyring = _read_keyring(home) or {
            "version": 1, "current": "", "keys": {},
        }
        if rotate or not keyring["current"]:
            key_id = uuid.uuid4().hex
            keyring["keys"][key_id] = secrets.token_urlsafe(48)
            keyring["current"] = key_id
        _write_keyring(home, keyring)
        return keyring["current"], keyring["keys"][keyring["current"]]
    finally:
        os.close(lock_fd)


def ensure_runner_token(fleet_home):
    return _with_token_lock(fleet_home, rotate=False)


def rotate_runner_token(fleet_home):
    """Install a fresh current key at each daemon process start."""
    return _with_token_lock(fleet_home, rotate=True)


def _runner_message(nonce, task_id, attempt, commit_sha, check_id):
    return json.dumps(
        [nonce, int(task_id), int(attempt), commit_sha, check_id],
        ensure_ascii=False, separators=(",", ":"),
    ).encode()


def _runner_proof(key_id, token, nonce, task_id, attempt, commit_sha, check_id):
    mac = hmac.new(
        token.encode(),
        _runner_message(nonce, task_id, attempt, commit_sha, check_id),
        hashlib.sha256,
    ).hexdigest()
    return f"{RUNNER_PROOF_PREFIX}:{key_id}:{mac}"


def runner_proof_valid(fleet_home, nonce, task_id, attempt, commit_sha,
                       check_id, proof):
    if not nonce or not proof:
        return False
    try:
        prefix, key_id, _ = proof.split(":", 2)
    except ValueError:
        return False
    if prefix != RUNNER_PROOF_PREFIX:
        return False
    keyring = _read_keyring(fleet_home)
    if not keyring or key_id not in keyring["keys"]:
        return False
    expected = _runner_proof(
        key_id, keyring["keys"][key_id], nonce, task_id, attempt,
        commit_sha, check_id,
    )
    return hmac.compare_digest(expected, proof)


def _proof_for_nonce(fleet_home, row, nonce):
    return (runner_proof_valid(
        fleet_home, nonce, row["task_id"], row["attempt"],
        row["commit_sha"], row["check_id"], row["runner_token_hash"],
    ) and row["runner_token_hash"])


def current(conn, goal_id):
    return conn.execute(
        "SELECT * FROM check_spec WHERE goal_id=? ORDER BY version DESC LIMIT 1",
        (goal_id,),
    ).fetchone()


def _decode_file(path):
    raw = Path(path).read_text()
    try:
        return json.loads(raw)
    except ValueError:
        try:
            import yaml
        except ImportError as exc:
            raise ValueError(
                "checks set: YAML requires PyYAML; JSON is also accepted"
            ) from exc
        return yaml.safe_load(raw)


def _canonical_checks(value, allow_long=False):
    if isinstance(value, dict) and set(value) == {"checks"}:
        value = value["checks"]
    if not isinstance(value, list) or not value:
        raise ValueError("checks set: checks must be a nonempty array")
    clean = []
    seen = set()
    required_fields = {"id", "argv", "timeout_s", "expected_exit", "required"}
    timeout_max = ABSOLUTE_TIMEOUT_MAX if allow_long else DEFAULT_TIMEOUT_MAX
    for item in value:
        if not isinstance(item, dict) or set(item) != required_fields:
            raise ValueError(
                "checks set: each check needs exactly id, argv, timeout_s, "
                "expected_exit, required"
            )
        check_id = item["id"]
        argv = item["argv"]
        timeout_s = item["timeout_s"]
        expected_exit = item["expected_exit"]
        required = item["required"]
        if (not isinstance(check_id, str) or not check_id.strip()
                or check_id in seen):
            raise ValueError(
                "checks set: check ids must be unique nonempty strings"
            )
        if (not isinstance(argv, list) or not argv or not argv[0]
                or any(not isinstance(arg, str) or "\0" in arg for arg in argv)):
            raise ValueError(
                "checks set: argv must be a nonempty array of strings"
            )
        if (type(timeout_s) not in (int, float)
                or not math.isfinite(timeout_s) or not 0 < timeout_s <= timeout_max):
            suffix = "; pass --allow-long for up to 86400" if not allow_long else ""
            raise ValueError(
                f"checks set: timeout_s must be finite and in (0, {timeout_max}]{suffix}"
            )
        if (type(expected_exit) is not int or not 0 <= expected_exit <= 255
                or type(required) is not bool):
            raise ValueError(
                "checks set: expected_exit must be 0..255 and required boolean"
            )
        seen.add(check_id)
        clean.append({
            "id": check_id, "argv": list(argv), "timeout_s": timeout_s,
            "expected_exit": expected_exit, "required": required,
        })
    if not any(item["required"] for item in clean):
        raise ValueError("checks set: at least one check must be required")
    return json.dumps(clean, sort_keys=True, separators=(",", ":"))


def _is_under(path, root):
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError):
        return False


def _parent_chain(limit=16):
    """Return a bounded, auditable Linux parent command chain."""
    chain = []
    pid = os.getppid()
    for _ in range(limit):
        if pid <= 1:
            break
        try:
            raw = Path(f"/proc/{pid}/cmdline").read_bytes()
            command = raw.replace(b"\0", b" ").decode(errors="replace").strip()
            stat = Path(f"/proc/{pid}/stat").read_text()
            parent = int(stat[stat.rfind(")") + 2:].split()[1])
        except (OSError, ValueError, LookupError):
            break
        executable = raw.split(b"\0", 1)[0].decode(errors="replace")
        chain.append({
            "pid": pid, "command": command[:1000],
            "executable": executable[:256],
        })
        if parent == pid:
            break
        pid = parent
    return chain


def _adapter_parent(chain):
    return any(
        "/adapters/" in entry["command"]
        or " fleet _finish " in f" {entry['command']} "
        or "/bin/fleet _finish " in entry["command"]
        or " fleet _check-runner " in f" {entry['command']} "
        or "/bin/fleet _check-runner " in entry["command"]
        for entry in chain
    )


def _caller_context(fleet_home):
    cwd = Path.cwd()
    chain = _parent_chain()
    return {
        "cwd": str(cwd),
        "ppid_chain": [
            {"pid": entry["pid"], "executable": entry["executable"]}
            for entry in chain
        ],
        "task_environment": bool(os.environ.get("FLEET_TASK_ID")),
        "fleet_managed_cwd": any(
            _is_under(cwd, Path(fleet_home) / name)
            for name in ("worktrees", "runs", "checks")
        ),
        "adapter_parent": _adapter_parent(chain),
    }


def operator_allowed(fleet_home):
    context = _caller_context(fleet_home)
    return not any((context["task_environment"], context["fleet_managed_cwd"],
                    context["adapter_parent"])), context


def set_spec(conn, goal_id, path, fleet_home=None, allow_long=False):
    """Validate, audit, and append a goal check specification."""
    home = Path(fleet_home or os.environ.get("FLEET_HOME") or Path.home() / ".fleet")
    allowed, caller = operator_allowed(home)
    if not allowed:
        raise ValueError(
            "checks set is an operator operation; Fleet tasks and adapter "
            "descendants cannot change required checks"
        )
    if not conn.execute("SELECT 1 FROM goal WHERE id=?", (goal_id,)).fetchone():
        raise ValueError(f"checks set: goal {goal_id} not found")
    body = _canonical_checks(_decode_file(path), allow_long=allow_long)
    conn.execute("BEGIN IMMEDIATE")
    old = current(conn, goal_id)
    idempotent = bool(old and old["body"] == body)
    if idempotent:
        spec_hash = old["spec_hash"]
        version = old["version"]
    else:
        version = old["version"] + 1 if old else 1
        spec_hash = digest(f"{goal_id}:{version}\n{body}".encode())
        conn.execute(
            "INSERT INTO check_spec(goal_id,version,spec_hash,body,created_at) "
            "VALUES(?,?,?,?,?)", (goal_id, version, spec_hash, body, time.time()),
        )
    conn.execute(
        "INSERT INTO event(ts,goal_id,kind,payload) VALUES(?,?,?,?)",
        (int(time.time()), goal_id, "checks.set", json.dumps({
            "goal_id": goal_id, "version": version, "spec_hash": spec_hash,
            "idempotent": idempotent, "allow_long": bool(allow_long),
            "caller": caller,
        }, ensure_ascii=False)),
    )
    conn.commit()
    return spec_hash


def _git(cwd, *args):
    return subprocess.check_output(
        ["git", "-C", str(cwd), *args], stderr=subprocess.PIPE,
        text=True, timeout=60,
    ).strip()


def delivery(task):
    """Sample one clean terminal delivery before creating check rows."""
    if (task["status"] != "done" or task["role"] != "worker"
            or task["review_of"] is not None or not task["worktree"]
            or not task["worktree_branch"]):
        raise ValueError(
            "delivery needs a done non-review worker with a private worktree"
        )
    worktree = Path(task["worktree"])
    if not worktree.is_dir():
        raise ValueError("delivery worktree is missing; restore it to start checks")
    if _git(worktree, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("delivery worktree is dirty; clean it to start checks")
    commit = _git(
        worktree, "rev-parse", "--verify",
        "refs/heads/" + task["worktree_branch"] + "^{commit}",
    )
    if _git(worktree, "rev-parse", "HEAD^{commit}") != commit:
        raise ValueError("delivery worktree HEAD differs from its branch tip")
    return commit


def _run_for(conn, task, commit, spec_hash, check_id):
    return conn.execute(
        "SELECT * FROM check_run WHERE task_id=? AND attempt=? "
        "AND commit_sha=? AND spec_hash=? AND check_id=?",
        (task["id"], task["attempt"], commit, spec_hash, check_id),
    ).fetchone()


def _delivery_tip(task):
    """Resolve the declared delivery branch without touching its worktree."""
    if not task["cwd"] or not task["worktree_branch"]:
        return None
    try:
        return _git(
            task["cwd"], "rev-parse", "--verify",
            "refs/heads/" + task["worktree_branch"] + "^{commit}",
        )
    except (OSError, subprocess.SubprocessError):
        return None


def _authenticated(row, fleet_home=None):
    if fleet_home is None:
        fleet_home = os.environ.get("FLEET_HOME") or Path.home() / ".fleet"
    return runner_proof_valid(
        fleet_home, row["runner_token"], row["task_id"], row["attempt"],
        row["commit_sha"], row["check_id"], row["runner_token_hash"],
    )


def passed(conn, task):
    """Whether the newest recorded delivery identity is authenticated green.

    Delivery cleanliness is sampled once, when pending rows are created.  This
    predicate deliberately performs no worktree or Git I/O, so pruning a
    worktree cannot invalidate already-recorded evidence.
    """
    if not trigger_set_intact(conn):
        return False
    spec = current(conn, task["goal_id"])
    if not spec:
        return False
    required = [item for item in json.loads(spec["body"]) if item["required"]]
    commit = _delivery_tip(task)
    if not commit:
        return False
    for check in required:
        row = _run_for(
            conn, task, commit, spec["spec_hash"], check["id"]
        )
        if (not row or row["status"] != "passed"
                or not row["delivery_clean"] or not _authenticated(row)):
            return False
    return True


def goal_passed(conn, goal_id):
    """Whether every current independent delivery for a goal is green."""
    if not current(conn, goal_id):
        return False
    tasks = conn.execute(
        "SELECT * FROM task WHERE goal_id=? AND role='worker' "
        "AND review_of IS NULL AND status!='cancelled' ORDER BY id", (goal_id,),
    ).fetchall()
    replaced = {
        task["parent_id"] for task in tasks if task["parent_id"] is not None
        and (task["base_task"] is not None or task["base_commit"] is not None)
    }
    leaves = [task for task in tasks if task["id"] not in replaced]
    return bool(leaves) and all(passed(conn, task) for task in leaves)


def gate_reason(conn, goal_id, reason):
    row = conn.execute(
        "SELECT verify_required FROM goal WHERE id=?", (goal_id,)
    ).fetchone()
    if (reason == "review_ready" and row and row["verify_required"]
            and not goal_passed(conn, goal_id)):
        return "waiting_for_checks"
    return reason


def _proc_stat(pid):
    if not pid:
        return None, None
    try:
        stat = Path(f"/proc/{int(pid)}/stat").read_text()
        # Fields after the final ')' begin at field 3 (state); starttime is 22.
        fields = stat[stat.rfind(")") + 2:].split()
        return int(fields[19]), fields[0]
    except (OSError, ValueError, LookupError):
        return None, None


def _proc_starttime(pid):
    return _proc_stat(pid)[0]


def _process_matches(pid, starttime, live=False):
    actual, state = _proc_stat(pid)
    return bool(pid and starttime is not None and actual == int(starttime)
                and (not live or state != "Z"))


def _kill_group(pgid, starttime):
    if not _process_matches(pgid, starttime):
        return False
    try:
        os.killpg(int(pgid), signal.SIGKILL)
        return True
    except ProcessLookupError:
        return False


def _kill_owned_group(pgid):
    """Kill a group just spawned by this still-running trusted wrapper."""
    if not pgid:
        return False
    try:
        os.killpg(int(pgid), signal.SIGKILL)
        return True
    except ProcessLookupError:
        return False


def _decision(conn, api, task, detail, reason="checks_infrastructure"):
    question = f"mechanical checks blocked: {detail}"
    if not conn.execute(
        "SELECT 1 FROM decision WHERE task_id=? AND question=? "
        "AND needs_user=1 AND resolved_at IS NULL", (task["id"], question),
    ).fetchone():
        cur = conn.execute(
            "INSERT INTO decision(goal_id,task_id,question,verdict,evidence,"
            "needs_user,ts) VALUES(?,?,?,?,?,1,?)",
            (task["goal_id"], task["id"], question, "conflict", None, api.now()),
        )
        api.log_event(
            conn, "decision.add", task_id=task["id"], goal_id=task["goal_id"],
            payload={"decision_id": cur.lastrowid, "question": question},
        )
    api.log_blocked(conn, task["id"], {"reason": reason, "detail": detail})


def _emit_terminal(conn, api, row, status, code, timed_out, detail):
    task = conn.execute(
        "SELECT * FROM task WHERE id=?", (row["task_id"],)
    ).fetchone()
    payload = {
        "run": row["id"], "check_id": row["check_id"],
        "commit": row["commit_sha"], "spec_hash": row["spec_hash"],
        "exit_code": code, "timed_out": bool(timed_out), "detail": detail,
    }
    if status == "passed":
        payload.update({
            "runner_nonce": row["runner_token"],
            "runner_proof": row["runner_token_hash"],
        })
    api.log_event(
        conn, "check." + status, task_id=task["id"], goal_id=task["goal_id"],
        payload=payload,
    )
    if status == "passed":
        api.log_event(
            conn, "check.passed_witness", task_id=task["id"],
            goal_id=task["goal_id"], payload=payload,
        )
    if status == "failed":
        evidence = (
            f"check_run {row['id']}: stdout {row['stdout_path']} ; "
            f"stderr {row['stderr_path']}"
        )
        # C0 attempt fencing: enqueue_fix only reads refuted claims whose
        # attempt_id matches the task's current attempt, so a mechanical
        # verdict must be stamped with an attempt -- otherwise the
        # check_failed rule silently never fires (p22 case A). It is stamped
        # with the attempt the run judged (check_run.attempt), not whatever
        # the task's current attempt is at recording time: a verdict on
        # generation N that lands after a retry to N+1 must not be consumed as
        # a refutation of N+1. Rows without attempt history
        # (pre-C0 ledgers) fall back to the task's literal attempt_id.
        judged = conn.execute(
            "SELECT attempt_id FROM attempt WHERE task_id=? AND generation=?",
            (task["id"], row["attempt"]),
        ).fetchone()
        attempt_id = judged[0] if judged else task["attempt_id"]
        claim_id = conn.execute(
            "INSERT INTO claim(task_id,claim,evidence,status,ts,attempt_id) "
            "VALUES(?,?,?,'refuted',?,?)",
            (task["id"], "Mechanical check failed: " + row["check_id"],
             evidence, api.now(), attempt_id),
        ).lastrowid
        api.log_event(
            conn, "claim.verify", task_id=task["id"],
            payload={"claim_id": claim_id, "status": "refuted",
                     "by": "checks", "note": evidence},
        )
    elif status == "infrastructure":
        _decision(conn, api, task, detail or "check runner infrastructure failure")
    elif status == "tampered":
        _decision(conn, api, task, detail or "check evidence authentication failed",
                  reason="checks_tampered")


def _output_hash(path):
    path = Path(path)
    return digest(path.read_bytes()) if path.exists() else None


def _finish(conn, api, row, nonce, status, code=None, timed_out=False, detail=None):
    if status not in TERMINAL_RUNS or status == "tampered":
        raise ValueError(f"invalid runner terminal check status: {status}")
    proof = _proof_for_nonce(api.fleet_home(), row, nonce)
    if not proof:
        _mark_tampered(conn, api, row, "runner HMAC/status mismatch")
        return False
    source_status = "IN ('pending','running')" if status == "infrastructure" else "='running'"
    changed = conn.execute(
        "UPDATE check_run SET status=?,ended_at=?,exit_code=?,timed_out=?,"
        "stdout_hash=?,stderr_hash=?,runner_token=?,detail=? WHERE id=? "
        f"AND status {source_status} AND runner_token_hash=?",
        (status, time.time(), code, int(timed_out), _output_hash(row["stdout_path"]),
         _output_hash(row["stderr_path"]), nonce, detail, row["id"], proof),
    ).rowcount
    if not changed:
        fresh = conn.execute("SELECT * FROM check_run WHERE id=?", (row["id"],)).fetchone()
        if (fresh and fresh["status"] in TERMINAL_RUNS
                and fresh["runner_token"]
                and hmac.compare_digest(fresh["runner_token"], nonce)
                and hmac.compare_digest(fresh["runner_token_hash"], proof)):
            return False
        _mark_tampered(conn, api, fresh or row, "runner HMAC/status mismatch")
        return False
    fresh = conn.execute("SELECT * FROM check_run WHERE id=?", (row["id"],)).fetchone()
    _emit_terminal(conn, api, fresh, status, code, timed_out, detail)
    conn.commit()
    return True


def _mark_tampered(conn, api, row, detail):
    if not row:
        return False
    changed = 0
    if row["status"] != "tampered":
        changed = conn.execute(
            "UPDATE check_run SET status='tampered',ended_at=?,detail=? "
            "WHERE id=? AND status!='tampered'",
            (time.time(), detail, row["id"]),
        ).rowcount
    recorded = conn.execute(
        "SELECT 1 FROM event WHERE kind='check.tampered' AND task_id=? "
        "AND json_extract(payload,'$.run')=?", (row["task_id"], row["id"]),
    ).fetchone()
    if changed or not recorded:
        fresh = conn.execute("SELECT * FROM check_run WHERE id=?", (row["id"],)).fetchone()
        _emit_terminal(conn, api, fresh, "tampered", fresh["exit_code"],
                       fresh["timed_out"], detail)
        conn.commit()
    return bool(changed or not recorded)


def _recover_terminal(conn, api):
    for row in conn.execute(
        "SELECT * FROM check_run WHERE status IN "
        "('passed','failed','infrastructure','tampered')"
    ).fetchall():
        if row["status"] == "tampered" or not _authenticated(
                row, api.fleet_home()):
            _mark_tampered(conn, api, row, "terminal row has no matching runner HMAC")


def _recover_running(conn, api):
    """Reap dead runners, checking both runner and project birth identity."""
    for row in conn.execute(
        "SELECT * FROM check_run WHERE status IN ('pending','running') ORDER BY started_at"
    ).fetchall():
        if row["status"] == "running" and _process_matches(
                row["runner_pid"], row["runner_starttime"], live=True):
            continue
        pgid_matches = _process_matches(row["pgid"], row["pgid_starttime"])
        if pgid_matches:
            _kill_group(row["pgid"], row["pgid_starttime"])
            suffix = "; verified orphan process group killed"
        elif row["pgid"]:
            suffix = "; recorded process group identity no longer matches (not killed)"
        else:
            suffix = ""
        recovery_nonce = secrets.token_urlsafe(32)
        key_id, token = ensure_runner_token(api.fleet_home())
        proof = _runner_proof(
            key_id, token, recovery_nonce, row["task_id"], row["attempt"],
            row["commit_sha"], row["check_id"],
        )
        changed = conn.execute(
            "UPDATE check_run SET status='infrastructure',ended_at=?,"
            "runner_token_hash=?,runner_token=?,detail=? WHERE id=? "
            "AND status IN ('pending','running')",
            (time.time(), proof, recovery_nonce,
             "runner interrupted before result commit" + suffix, row["id"]),
        ).rowcount
        if changed:
            fresh = conn.execute("SELECT * FROM check_run WHERE id=?", (row["id"],)).fetchone()
            _emit_terminal(conn, api, fresh, "infrastructure", None, False,
                           fresh["detail"])
            conn.commit()


def _blocked_delivery(conn, api, task, detail):
    _decision(conn, api, task, detail)
    conn.commit()


def _minimal_check_env():
    env = {key: value for key, value in os.environ.items()
           if key in CHECK_ENV_ALLOW
           and not key.startswith(CHECK_ENV_DENY_PREFIXES)}
    env.setdefault("PATH", os.defpath)
    return env


def _check_from_row(conn, row):
    spec = conn.execute(
        "SELECT body FROM check_spec WHERE spec_hash=?", (row["spec_hash"],)
    ).fetchone()
    if not spec:
        raise ValueError("check specification disappeared")
    for check in json.loads(spec["body"]):
        if check["id"] == row["check_id"]:
            return check
    raise ValueError("check id disappeared from its immutable specification")


def _read_token(fd):
    chunks = []
    while True:
        part = os.read(fd, 4096)
        if not part:
            break
        chunks.append(part)
    os.close(fd)
    return b"".join(chunks).decode()


def _all_project_children_ready(conn, row, timeout=60):
    """Barrier: no project code runs until every sibling child exists.

    Rows were pre-created as one transaction.  This barrier is what prevents
    an early malicious check from changing a sibling row before that sibling's
    real command has already been spawned behind its trusted launch gate.
    """
    deadline = time.monotonic() + timeout
    params = (row["task_id"], row["attempt"], row["commit_sha"],
              row["spec_hash"])
    while time.monotonic() < deadline:
        total, ready = conn.execute(
            "SELECT COUNT(*),COALESCE(SUM(pgid IS NOT NULL "
            "AND pgid_starttime IS NOT NULL),0) "
            "FROM check_run WHERE task_id=? AND attempt=? AND commit_sha=? "
            "AND spec_hash=?", params,
        ).fetchone()
        if total and ready == total:
            return True
        time.sleep(0.01)
    return False


def detached_runner(api, run_id, token_fd):
    """Trusted detached wrapper entry point; project code is its child."""
    nonce = _read_token(token_fd)
    if not nonce:
        return 2
    conn = api.db_connect()
    row = conn.execute("SELECT * FROM check_run WHERE id=?", (run_id,)).fetchone()
    if not row or row["status"] != "running" or not runner_proof_valid(
            api.fleet_home(), nonce, row["task_id"], row["attempt"],
            row["commit_sha"], row["check_id"], row["runner_token_hash"]):
        if row:
            _mark_tampered(conn, api, row, "runner could not authenticate pending row")
        conn.close()
        return 3
    task = conn.execute("SELECT * FROM task WHERE id=?", (row["task_id"],)).fetchone()
    proc = None
    code = None
    timed_out = False
    detail = None
    status = "infrastructure"
    added = False
    worktree = Path(row["cwd"])
    try:
        check = _check_from_row(conn, row)
        _git(task["worktree"], "worktree", "add", "--detach",
             str(worktree), row["commit_sha"])
        added = True
        with Path(row["stdout_path"]).open("wb") as stdout, \
                Path(row["stderr_path"]).open("wb") as stderr:
            read_fd, write_fd = os.pipe()
            launcher = (
                "import os,sys; fd=int(sys.argv[1]); go=os.read(fd,1); "
                "os.close(fd); sys.exit(127) if go!=b'x' else None; argv=sys.argv[2:]; "
                "\ntry: os.execvp(argv[0],argv)"
                "\nexcept FileNotFoundError as e: print(e,file=sys.stderr); os._exit(127)"
                "\nexcept PermissionError as e: print(e,file=sys.stderr); os._exit(126)"
            )
            try:
                proc = subprocess.Popen(
                    [sys.executable, "-I", "-S", "-c", launcher,
                     str(read_fd), *check["argv"]], cwd=worktree,
                    stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                    start_new_session=True, pass_fds=(read_fd,), close_fds=True,
                    env=_minimal_check_env(),
                )
                starttime = _proc_starttime(proc.pid)
                if starttime is None:
                    raise OSError("could not record check process birth identity")
                changed = conn.execute(
                    "UPDATE check_run SET pgid=?,pgid_starttime=? WHERE id=? "
                    "AND status='running' AND runner_token_hash=?",
                    (proc.pid, starttime, run_id, row["runner_token_hash"]),
                ).rowcount
                conn.commit()
                if not changed:
                    raise OSError("check row changed before process launch")
                if not _all_project_children_ready(conn, row):
                    raise OSError("not every pre-created check reached its launch gate")
                os.write(write_fd, b"x")
            finally:
                os.close(read_fd)
                os.close(write_fd)
            try:
                code = proc.wait(timeout=check["timeout_s"])
            except subprocess.TimeoutExpired:
                timed_out = True
                _kill_owned_group(proc.pid)
                code = proc.wait()
        stderr_text = Path(row["stderr_path"]).read_text(errors="replace")
        if (code in (126, 127) or (code != check["expected_exit"]
                and any(marker in stderr_text for marker in MISSING_DEPENDENCY_MARKERS))):
            detail = "missing command or dependency"
        else:
            status = ("passed" if code == check["expected_exit"]
                      and not timed_out else "failed")
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        detail = str(exc)
        with Path(row["stderr_path"]).open("ab") as stderr:
            stderr.write((detail + "\n").encode(errors="replace"))
    finally:
        if proc is not None:
            # The live trusted wrapper created this group and cleans it up
            # immediately; unlike crash recovery this is not a bare stale pgid.
            _kill_owned_group(proc.pid)
            if proc.poll() is None:
                proc.wait()
        _finish(conn, api, row, nonce, status, code, timed_out, detail)
        if added and worktree.exists():
            try:
                _git(task["worktree"], "worktree", "remove", "--force",
                     str(worktree))
            except (OSError, subprocess.SubprocessError):
                pass
        conn.close()
    return 0


def _prepare_rows(conn, api, task, spec, commit):
    """Pre-create every identity before any project process can start."""
    prepared = []
    started_at = time.time()
    key_id, token = ensure_runner_token(api.fleet_home())
    conn.execute("BEGIN IMMEDIATE")
    try:
        for check in json.loads(spec["body"]):
            existing = _run_for(conn, task, commit, spec["spec_hash"], check["id"])
            if existing:
                continue
            run_id = uuid.uuid4().hex
            nonce = secrets.token_urlsafe(32)
            proof = _runner_proof(
                key_id, token, nonce, task["id"], task["attempt"],
                commit, check["id"],
            )
            folder = api.fleet_home() / "checks" / run_id
            folder.mkdir(parents=True, exist_ok=False)
            stdout_path = folder / "stdout"
            stderr_path = folder / "stderr"
            stdout_path.touch()
            stderr_path.touch()
            conn.execute(
                "INSERT INTO check_run(id,task_id,attempt,commit_sha,spec_hash,"
                "check_id,argv,cwd,started_at,status,stdout_path,stderr_path,"
                "runner_token_hash,delivery_clean) "
                "VALUES(?,?,?,?,?,?,?,?,?,'pending',?,?,?,1)",
                (run_id, task["id"], task["attempt"], commit, spec["spec_hash"],
                 check["id"], json.dumps(check["argv"], separators=(",", ":")),
                 str(folder / "worktree"), started_at, str(stdout_path),
                 str(stderr_path), proof),
            )
            prepared.append((run_id, nonce))
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    return prepared


def _launch_prepared(conn, api, prepared):
    """Spawn all wrappers behind gates, record identities, then release all."""
    gated = []
    fleet_bin = str(Path(api.__file__).resolve())
    for run_id, nonce in prepared:
        row = conn.execute(
            "SELECT * FROM check_run WHERE id=?", (run_id,)
        ).fetchone()
        read_fd, write_fd = os.pipe()
        try:
            proc = subprocess.Popen(
                [sys.executable, fleet_bin, "_check-runner", run_id, str(read_fd)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
                pass_fds=(read_fd,), close_fds=True, env=dict(os.environ),
                cwd=str(api.fleet_home()),
            )
        except Exception as exc:
            os.close(read_fd)
            os.close(write_fd)
            _finish(conn, api, row, nonce, "infrastructure", detail=str(exc))
            continue
        os.close(read_fd)
        starttime = _proc_starttime(proc.pid)
        if starttime is None:
            os.close(write_fd)
            _finish(conn, api, row, nonce, "infrastructure",
                    detail="could not record detached runner birth identity")
            continue
        changed = conn.execute(
            "UPDATE check_run SET status='running',runner_pid=?,runner_starttime=? "
            "WHERE id=? AND status='pending' AND runner_token_hash=?",
            (proc.pid, starttime, run_id, row["runner_token_hash"]),
        ).rowcount
        conn.commit()
        if not changed:
            os.close(write_fd)
            row = conn.execute("SELECT * FROM check_run WHERE id=?", (run_id,)).fetchone()
            _mark_tampered(conn, api, row, "pending row changed before runner launch")
            continue
        gated.append((write_fd, nonce, proc))
    # No project code can pass its launch gate until every identity is running.
    for write_fd, nonce, proc in gated:
        try:
            os.write(write_fd, nonce.encode())
        finally:
            os.close(write_fd)
    return len(gated)


def run_pending(conn, api, only_task=None):
    """Harvest dead wrappers and asynchronously start missing identities."""
    if not conn.execute("SELECT 1 FROM check_spec LIMIT 1").fetchone():
        return 0
    root = api.fleet_home() / "checks"
    root.mkdir(parents=True, exist_ok=True)
    with (root / "runner.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        _recover_terminal(conn, api)
        _recover_running(conn, api)
        if only_task is not None and not conn.execute(
                "SELECT 1 FROM task WHERE id=?", (only_task,)).fetchone():
            raise ValueError(f"checks run: task {only_task} not found")
        sql = (
            "SELECT t.* FROM task t WHERE t.status='done' AND t.role='worker' "
            "AND t.review_of IS NULL AND EXISTS(SELECT 1 FROM check_spec s "
            "WHERE s.goal_id=t.goal_id)"
        )
        params = ()
        if only_task is not None:
            sql += " AND t.id=?"
            params = (only_task,)
        prepared = []
        for task in conn.execute(sql + " ORDER BY t.id", params).fetchall():
            spec = current(conn, task["goal_id"])
            try:
                commit = delivery(task)
            except (ValueError, OSError, subprocess.SubprocessError) as exc:
                # Existing authenticated evidence is intentionally durable; a
                # missing worktree only blocks identities that have never run.
                if not passed(conn, task):
                    _blocked_delivery(conn, api, task, str(exc))
                continue
            prepared.extend(_prepare_rows(conn, api, task, spec, commit))
        return _launch_prepared(conn, api, prepared)
