#!/usr/bin/env python3
"""Assertions on a commander prompt.md, by really parsing it as JSON.

The bug this guards against was invisible to grep: the prompt was clipped at
48 KiB in the middle of a string, so it still *looked*
like a prompt and still contained the word 已截断, while the schema, the
watermark and the human gate had been cut off the end and the body no longer
parsed at all. Every check here therefore decodes the file strictly as UTF-8,
parses the body as JSON, and reads values out of the object -- a substring
match would have passed on the broken prompt.

Usage: commander_prompt_check.py MODE PROMPT_PATH [ARGS...]
Prints "ok" on success, or "FAIL: <reason>" and exits 1.
"""
import importlib.machinery
import importlib.util
import json
import os
import re
import sys

CAP = 48 * 1024
BEGIN = ": <<'FLEET_COMMANDER_PROMPT'\n"
END = "FLEET_COMMANDER_PROMPT\n"
# Fields the contract calls protocol: they must be present and intact at every
# size, so they are checked by value, not by presence alone.
CORE_TOP = (
    "protocol_version", "goal", "plan", "through_event_id", "allowed_actions",
    "channel_options", "response_example", "response_constraints", "instruction",
    "unresolved_needs_user", "execution_target", "base_candidates",
    "previous_proposal_rejections", "since", "truncation",
)
EXAMPLE_TASK_FIELDS = (
    "channel", "title", "problem", "evidence", "expected_artifact",
    "verification", "dedup_key", "scope", "base_task", "review_of", "model",
    "effort",
)


class Bad(Exception):
    pass


def read(path):
    """(parsed body, total prompt bytes, wrapped?) -- or Bad."""
    raw = open(path, "rb").read()
    if len(raw) > CAP + 1024:
        raise Bad(f"prompt is {len(raw)} bytes, over the 49152-byte contract")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        # A byte-slice truncation splits multi-byte characters; strict decoding
        # is how that shows up rather than being silently replaced.
        raise Bad(f"prompt is not valid UTF-8: {e}")
    wrapped = BEGIN in text
    body = text
    if wrapped:
        body = text.split(BEGIN, 1)[1]
        if not body.endswith(END):
            raise Bad("wrapped prompt does not end with the heredoc terminator")
        body = body[: -len(END)]
    try:
        parsed = json.loads(body)
    except ValueError as e:
        raise Bad(f"prompt body is not parseable JSON: {e}")
    if not isinstance(parsed, dict):
        raise Bad(f"prompt body is {type(parsed).__name__}, not an object")
    return parsed, len(raw), wrapped


def check_core(p, total, goal_id, revision, through):
    """The protocol core, by value. Nothing here may depend on ledger size."""
    if total > CAP + 1024:
        raise Bad(f"{total} bytes exceeds the 49152-byte contract")
    missing = [k for k in CORE_TOP if k not in p]
    if missing:
        raise Bad(f"protocol fields missing from the prompt: {missing}")
    if p["protocol_version"] != 1:
        raise Bad(f"protocol_version is {p['protocol_version']!r}, want 1")
    if p["goal"].get("id") != goal_id:
        raise Bad(f"goal.id is {p['goal'].get('id')!r}, want {goal_id}")
    if p["plan"].get("revision") != revision:
        raise Bad(f"plan.revision is {p['plan'].get('revision')!r}, want {revision}")
    if p["through_event_id"] != through:
        raise Bad(f"through_event_id is {p['through_event_id']!r}, want {through}")
    if p["allowed_actions"] != ["propose_tasks", "propose_decisions", "wait"]:
        raise Bad(f"allowed_actions is {p['allowed_actions']!r}")
    options = p["channel_options"]
    if not isinstance(options, list) or not options:
        raise Bad("channel_options is empty or not a list")
    for option in options:
        if set(option) != {
            "channel", "models", "model_max_parallel", "model_effort"
        }:
            raise Bad(f"channel_options entry has wrong fields: {option!r}")
        if (not isinstance(option["models"], list)
                or not isinstance(option["model_max_parallel"], dict)
                or not isinstance(option["model_effort"], dict)):
            raise Bad(f"channel_options entry has wrong value types: {option!r}")
    ex = p["response_example"]
    for key in ("goal_id", "based_on_plan_revision", "through_event_id",
                "proposed_tasks", "decisions", "next_wake"):
        if key not in ex:
            raise Bad(f"response_example lost {key}")
    if ex["through_event_id"] != through:
        raise Bad("response_example.through_event_id disagrees with the watermark")
    task = ex["proposed_tasks"][0]
    lost = [k for k in EXAMPLE_TASK_FIELDS if k not in task]
    if lost:
        raise Bad(f"response_example task schema lost {lost}")
    if ex["next_wake"].get("reason") not in (
        "waiting_for_tasks", "waiting_for_checks", "needs_user",
        "review_ready", "budget_exhausted",
    ):
        raise Bad("response_example.next_wake.reason is not a legal wake reason")
    for key in ("response_constraints", "instruction"):
        if not isinstance(p[key], str) or len(p[key]) < 100:
            raise Bad(f"{key} is missing or was shortened: {p[key]!r:.60}")
    if "next_wake.reason must be" not in p["response_constraints"]:
        raise Bad("response_constraints was clipped before the wake-reason rule")
    nu = p["unresolved_needs_user"]
    for key in ("present", "total", "ids", "items", "query", "ledger"):
        if key not in nu:
            raise Bad(f"unresolved_needs_user lost {key}")
    since = p["since"]
    for key in ("after_event_id", "folded", "folded_total", "folded_omitted",
                "query", "ledger"):
        if key not in since:
            raise Bad(f"since lost {key}")
    rejected = p["previous_proposal_rejections"]
    for key in ("round_task", "total", "items", "instruction"):
        if key not in rejected:
            raise Bad(f"previous_proposal_rejections lost {key}")
    if rejected["total"] != len(rejected["items"]):
        raise Bad("previous proposal rejection total disagrees with items")
    tr = p["truncation"]
    for key in ("omitted", "note", "ledger", "fields", "lists"):
        if key not in tr:
            raise Bad(f"truncation lost {key}")
    if not tr["ledger"].endswith("fleet.db"):
        raise Bad(f"truncation.ledger is not a ledger path: {tr['ledger']!r}")


def truncated_fields(p):
    return {entry["field"] for entry in p["truncation"]["fields"]}


def truncated_lists(p):
    return {entry["field"] for entry in p["truncation"]["lists"]}


def walk(value, path="goal.autonomy"):
    """Every (path, value) pair in a decoded JSON tree, so a nested dict
    cannot hide from the cardinality check by sitting one level down."""
    yield path, value
    if isinstance(value, dict):
        for key, val in value.items():
            yield from walk(val, f"{path}.{key}")
    elif isinstance(value, list):
        for index, val in enumerate(value):
            yield from walk(val, f"{path}[{index}]")


def load_fleet():
    """Import bin/fleet as a module so the constraints text can be checked
    against the constants the daemon validates on, not against numbers copied
    into this file -- copying them here would just move the drift."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "fleet")
    loader = importlib.machinery.SourceFileLoader("fleet_under_test", path)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def main(argv):
    mode, path = argv[1], argv[2]
    rest = argv[3:]
    p, total, wrapped = read(path)

    if mode == "core":
        goal_id, revision, through = (int(x) for x in rest[:3])
        check_core(p, total, goal_id, revision, through)

    elif mode == "giant":
        # Giant UTF-8 goal/acceptance/plan. The core survives, the big fields
        # are recorded as shortened with real character counts, and what is
        # kept is a prefix of the original -- not a mangled tail.
        goal_id, revision, through = (int(x) for x in rest[:3])
        marker = rest[3]
        check_core(p, total, goal_id, revision, through)
        want = {"goal.statement", "goal.acceptance", "plan.rationale",
                "plan.dag", "plan.rules"}
        got = truncated_fields(p)
        if not want <= got:
            raise Bad(f"these giant fields were shortened silently: {want - got}")
        for entry in p["truncation"]["fields"]:
            if entry["field"] in want:
                if entry["omitted_chars"] <= 0 or entry["original_chars"] < 60000:
                    raise Bad(f"{entry['field']} omission record is wrong: {entry}")
        if not p["truncation"]["omitted"]:
            raise Bad("truncation.omitted is false although fields were shortened")
        if "已截断" not in p["truncation"]["note"]:
            raise Bad("truncation.note does not say the prompt was shortened")
        if not p["goal"]["acceptance"].startswith(marker):
            raise Bad("goal.acceptance does not start with the original text")
        # A prefix, not a mangled middle: the kept part must be the beginning
        # of the ledger value, which is what makes it usable at all.
        if not p["plan"]["dag"].startswith("DAG"):
            raise Bad(f"plan.dag is not a prefix of the original: {p['plan']['dag'][:20]!r}")
        if not p["plan"]["rationale"].startswith("RAT"):
            raise Bad("plan.rationale is not a prefix of the original")
        if not p["goal"]["statement"].startswith("STMT"):
            raise Bad("goal.statement is not a prefix of the original")

    elif mode == "needsuser":
        # Many unresolved decisions: existence, exact total, bounded ids and
        # the ledger query all survive; ids are the real decision ids.
        goal_id, revision, through, expect = (int(x) for x in rest[:4])
        check_core(p, total, goal_id, revision, through)
        nu = p["unresolved_needs_user"]
        if nu["present"] is not True:
            raise Bad("unresolved_needs_user.present is not True")
        if nu["total"] != expect:
            raise Bad(f"needs_user total is {nu['total']}, want {expect}")
        if not nu["ids"]:
            raise Bad("needs_user carries no ids at all")
        if nu["ids"] != sorted(nu["ids"]) or nu["ids"][0] < 1:
            raise Bad(f"needs_user ids are not ledger ids: {nu['ids'][:5]}")
        if len(nu["ids"]) + nu["ids_omitted"] != expect:
            raise Bad("needs_user ids + ids_omitted does not add up to total")
        if len(nu["items"]) + nu["items_omitted"] != expect:
            raise Bad("needs_user items + items_omitted does not add up to total")
        if "FROM decision" not in nu["query"]:
            raise Bad(f"needs_user query is not a ledger query: {nu['query']!r}")
        if not nu["ledger"].endswith("fleet.db"):
            raise Bad("needs_user does not point at the ledger")

    elif mode == "folded":
        # A big increment: after_event_id, coverage and the omitted count are
        # exact, and a pointer reproduces the whole fold.
        goal_id, revision, through, after, events = (int(x) for x in rest[:5])
        check_core(p, total, goal_id, revision, through)
        since = p["since"]
        if since["after_event_id"] != after:
            raise Bad(f"since.after_event_id is {since['after_event_id']}, want {after}")
        if since["through_event_id"] != through:
            raise Bad("since.through_event_id disagrees with the watermark")
        if since["event_count"] != events:
            raise Bad(f"since.event_count is {since['event_count']}, want {events}")
        if len(since["folded"]) + since["folded_omitted"] != since["folded_total"]:
            raise Bad("since folded + folded_omitted does not add up to folded_total")
        if since["folded_omitted"] > 0 and "since.folded" not in truncated_lists(p):
            raise Bad("folded lines were dropped without a truncation record")
        if f"fleet since {after}" not in since["query"]:
            raise Bad(f"since.query is not a usable pointer: {since['query']!r}")

    elif mode == "artifacts":
        # Many artifacts with oversized summaries: the ledger query for the
        # full set is present whenever any were dropped, and no summary is
        # carried at full length.
        goal_id, revision, through, biggest = (int(x) for x in rest[:4])
        check_core(p, total, goal_id, revision, through)
        for task in p["tasks"]:
            for artifact in task["artifacts"]:
                if len(artifact["summary"]) >= biggest:
                    raise Bad("an oversized artifact summary was carried in full")
        entries = {e["field"]: e for e in p["truncation"]["lists"]}
        entry = entries.get("tasks[].artifacts")
        if entry is None and not truncated_fields(p):
            raise Bad("oversized artifacts left no truncation record at all")
        if entry is not None:
            if entry["omitted"] <= 0 or "FROM artifact" not in entry["query"]:
                raise Bad(f"artifact omission record is unusable: {entry}")

    elif mode == "clean":
        # A small ledger must NOT claim truncation: the report is evidence,
        # so an always-on "已截断" would make it worthless.
        goal_id, revision, through = (int(x) for x in rest[:3])
        check_core(p, total, goal_id, revision, through)
        if p["truncation"]["omitted"]:
            raise Bad(f"small ledger reports truncation: {p['truncation']}")
        if p["truncation"]["fields"] or p["truncation"]["lists"]:
            raise Bad("small ledger records omissions that did not happen")
        if "已截断" in p["truncation"]["note"]:
            raise Bad("small ledger claims 已截断 with nothing omitted")

    elif mode == "wrapped":
        # Shell driver: the JSON body is complete (already proved by parsing),
        # the driver text is intact above it, and the total is still bounded.
        goal_id, revision, through = (int(x) for x in rest[:3])
        needle = rest[3]
        check_core(p, total, goal_id, revision, through)
        if not wrapped:
            raise Bad("prompt is not wrapped in a shell driver")
        head = open(path, encoding="utf-8").read().split(BEGIN, 1)[0]
        if not head.startswith("#!/usr/bin/env bash\n"):
            raise Bad("driver lost its shebang")
        if needle not in head:
            raise Bad(f"driver body lost {needle!r}")
        if 'exit "$rc"' not in head:
            raise Bad("driver lost its exit trailer, so the script is truncated")

    elif mode == "dict":
        # A hand-edited goal.autonomy whose value is a huge dict. Bounding
        # only the VALUES left the key count and key length unbounded, and a
        # 1000-key dict rendered ~570 KB at every rung including the
        # tightest -- construction raised and the goal got no prompt at all.
        goal_id, revision, through, keys = (int(x) for x in rest[:4])
        check_core(p, total, goal_id, revision, through)
        limit = p["truncation"]["list_item_limit"]
        text_limit = p["truncation"]["text_limit_chars"]
        found = [
            (path, value) for path, value in walk(p["goal"]["autonomy"])
            if isinstance(value, dict)
        ]
        if not found:
            raise Bad("goal.autonomy carries no dict at all; fixture did not land")
        for path, value in found:
            real = {k: v for k, v in value.items() if not k.startswith("_omitted")}
            if len(real) > max(limit, 1):
                raise Bad(
                    f"{path} carries {len(real)} keys at item limit {limit}")
            for key in real:
                if len(key) > max(text_limit, 1) + 40:
                    raise Bad(f"{path} carries a {len(key)}-char key unbounded")
            if len(real) < len(value):
                # Keys were dropped, so the count must say how many.
                omitted = next(v for k, v in value.items() if k.startswith("_omitted"))
                if not isinstance(omitted, int) or omitted <= 0:
                    raise Bad(f"{path} reports _omitted={omitted!r}")
                if len(real) + omitted != keys:
                    raise Bad(
                        f"{path}: {len(real)} kept + {omitted} omitted != {keys}")
        if not p["truncation"]["omitted"]:
            raise Bad("a bounded dict left truncation.omitted false")

    elif mode == "constraints":
        # response_constraints must state every rule the daemon rejects on,
        # with the same numbers. A rule the model is never told about is a
        # rejection it had no way to avoid.
        goal_id, revision, through = (int(x) for x in rest[:3])
        check_core(p, total, goal_id, revision, through)
        fleet = load_fleet()
        text = p["response_constraints"]
        if text != fleet.commander_response_constraints():
            raise Bad("the prompt's constraints are not the generated text")
        field_max = fleet.COMMANDER_FIELD_MAX_CHARS
        # The two rules 386 found missing, by their numbers -- so bumping the
        # constant without regenerating the text is caught rather than styled
        # around.
        if not re.search(rf"nonempty strings of at most {field_max} characters", text):
            raise Bad(f"constraints do not state the {field_max}-char task field cap")
        if not re.search(
            rf"[Ee]very decision is a nonempty string of at most {field_max} characters",
            text,
        ):
            raise Bad(
                f"constraints do not state that decisions are nonempty and "
                f"<= {field_max} characters")
        for number, label in (
            (fleet.COMMANDER_MAX_TASKS, "task cap"),
            (fleet.COMMANDER_MAX_DECISIONS, "decision cap"),
            (fleet.COMMANDER_TITLE_MAX_CHARS, "title cap"),
        ):
            if str(number) not in text:
                raise Bad(f"constraints do not carry the {label} ({number})")
        for wake in fleet.COMMANDER_WAKES:
            if wake not in text:
                raise Bad(f"constraints omit the legal wake reason {wake!r}")
        if "Reviewer candidate must set review_of" not in p["instruction"]:
            raise Bad("instruction does not require review_of for Reviewer candidates")
        if "must set review_of" not in text:
            raise Bad("constraints do not require review_of for review candidates")
        # And the numbers must be the ones the validator really enforces: a
        # proposal one character over the stated cap has to be rejected.
        task = {"id": 1, "goal_id": goal_id, "commander_plan_revision": revision,
                "commander_through_event_id": through}
        base = {
            "goal_id": goal_id, "based_on_plan_revision": revision,
            "through_event_id": through, "decisions": [],
            "next_wake": {"reason": "needs_user"}, "proposed_tasks": [],
        }
        over = dict(base, decisions=["d" * (field_max + 1)])
        try:
            fleet._validate_commander_proposal(over, task)
        except ValueError:
            pass
        else:
            raise Bad(
                f"the validator accepts a {field_max + 1}-char decision the "
                "constraints say is too long")
        try:
            fleet._validate_commander_proposal(dict(base, decisions=[" "]), task)
        except ValueError:
            pass
        else:
            raise Bad("the validator accepts a blank decision")
        try:
            fleet._validate_commander_proposal(
                dict(base, decisions=["d" * field_max]), task)
        except ValueError as exc:
            raise Bad(
                f"the validator rejects a decision at the stated cap: {exc}")

    elif mode == "sincecmd":
        # since.query must be a command the reader can run, not prose. The
        # suite runs the string this returns and checks rc=0.
        goal_id, revision, through, after = (int(x) for x in rest[:4])
        check_core(p, total, goal_id, revision, through)
        query = p["since"]["query"]
        want = f"fleet since {after} --goal {goal_id} --all"
        if query != want:
            raise Bad(f"since.query is {query!r}, want {want!r}")
        for entry in p["truncation"]["lists"]:
            if entry["field"] == "since.folded" and want not in entry["query"]:
                raise Bad(
                    f"the folded-omission pointer is not runnable: {entry['query']!r}")

    elif mode == "artifacttotal":
        # The artifact total is the one number telling the commander how much
        # evidence it is NOT seeing. Summing over the tasks a rung kept made
        # it shrink together with the evidence: 2500 artifacts behind 500
        # tasks were reported as the ~200 under the 40 surviving tasks.
        goal_id, revision, through, expect = (int(x) for x in rest[:4])
        check_core(p, total, goal_id, revision, through)
        entries = {e["field"]: e for e in p["truncation"]["lists"]}
        entry = entries.get("tasks[].artifacts")
        if entry is None:
            raise Bad(
                f"{expect} artifacts across dropped tasks left no omission record")
        if entry["total"] != expect:
            raise Bad(f"artifact total is {entry['total']}, want {expect}")
        carried = sum(len(t["artifacts"]) for t in p["tasks"])
        if entry["included"] != carried:
            raise Bad(
                f"artifacts included={entry['included']} but the prompt "
                f"carries {carried}")
        if entry["included"] + entry["omitted"] != entry["total"]:
            raise Bad(f"artifact included + omitted != total: {entry}")
        if "tasks" not in truncated_lists(p):
            raise Bad("tasks were not dropped; the fixture does not test the gap")
        if "FROM artifact" not in entry["query"]:
            raise Bad(f"artifact omission record is unusable: {entry}")

    elif mode == "integrated":
        # A p19-shaped Git target plus a terminal worktree candidate and the
        # p19 K-sized ledger must retain both the bounded-prompt protocol and
        # the execution-layer protocol after the two branches are combined.
        goal_id, revision, through, base_task = (int(x) for x in rest[:4])
        target_cwd = rest[4]
        check_core(p, total, goal_id, revision, through)
        if total > CAP:
            raise Bad(f"integrated prompt is {total} bytes, over {CAP}")
        target = p["execution_target"]
        if target.get("cwd") != target_cwd or target.get("kind") != "git":
            raise Bad(f"execution_target lost its persistent Git cwd: {target}")
        candidates = p["base_candidates"]
        if not candidates or candidates[0].get("base_task") != base_task:
            raise Bad(f"base_candidates lost terminal worker {base_task}: {candidates}")
        if target.get("available_base_tasks") != candidates:
            raise Bad("execution_target and base_candidates disagree")
        if list(p).index("unresolved_needs_user") > list(p).index("execution_target"):
            raise Bad("unresolved_needs_user follows execution_target")
        if not p["unresolved_needs_user"].get("present"):
            raise Bad("unresolved_needs_user gate disappeared")
        example = p["response_example"]["proposed_tasks"][0]
        for key in ("base_task", "review_of"):
            if key not in example:
                raise Bad(f"response_example lost {key}")
        constraints = p["response_constraints"]
        if "base_task is optional" not in constraints:
            raise Bad("response_constraints lost the base_task rule")
        if "review_of is optional" not in constraints:
            raise Bad("response_constraints lost the review_of rule")
        field_max = load_fleet().COMMANDER_FIELD_MAX_CHARS
        if constraints.count(str(field_max)) < 2:
            raise Bad(
                f"response_constraints does not state both {field_max}-char rules")

    else:
        raise Bad(f"unknown mode {mode!r}")

    print("ok")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Bad as exc:
        print(f"FAIL: {exc}")
        sys.exit(1)
