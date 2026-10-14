#!/usr/bin/env python3
"""Report worktrees that are unsafe to remove with `fleet worktree prune`."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def run(command):
    return subprocess.run(command, text=True, capture_output=True)


def git(path, *args):
    return run(["git", "-C", str(path), *args])


def size_of(path):
    human = run(["du", "-sh", "--", str(path)])
    blocks = run(["du", "-sk", "--", str(path)])
    if human.returncode or blocks.returncode:
        return "unknown", 0
    try:
        return human.stdout.split()[0], int(blocks.stdout.split()[0]) * 1024
    except (LookupError, ValueError):
        return "unknown", 0


def audit(row):
    item = {
        "id": row.get("id"),
        "path": row.get("worktree"),
        "branch": row.get("worktree_branch"),
        "repo": None,
        "default_branch": None,
        "ahead": None,
        "dirty": None,
        "size": "0",
        "size_bytes": 0,
        "reason": None,
    }
    path = item["path"]
    if not isinstance(path, str) or not os.path.isdir(path):
        item["reason"] = "directory missing"
        return "stale", item

    item["size"], item["size_bytes"] = size_of(path)
    common = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if common.returncode:
        item["reason"] = "git metadata unavailable"
        return "risky", item
    common_path = Path(common.stdout.strip())
    repo_path = common_path.parent if common_path.name == ".git" else common_path
    item["repo"] = repo_path.name or str(repo_path)

    branch = git(path, "symbolic-ref", "--quiet", "--short", "HEAD")
    if branch.returncode:
        item["reason"] = "current branch unknown"
        return "risky", item
    item["branch"] = branch.stdout.strip()

    default = git(repo_path, "symbolic-ref", "--quiet", "--short", "HEAD")
    if default.returncode or not default.stdout.strip():
        item["reason"] = "default branch unknown"
        return "risky", item
    item["default_branch"] = default.stdout.strip()

    ahead = git(path, "rev-list", "--count", f"{item['default_branch']}..{item['branch']}")
    status = git(path, "status", "--porcelain")
    try:
        item["ahead"] = int(ahead.stdout.strip()) if ahead.returncode == 0 else None
    except ValueError:
        item["ahead"] = None
    if status.returncode == 0:
        item["dirty"] = len(status.stdout.splitlines())
    if item["ahead"] is None or item["dirty"] is None:
        item["reason"] = "git inspection failed"
        return "risky", item
    if item["ahead"] > 0 or item["dirty"] > 0:
        return "risky", item
    return "clean", item


def human_size(total):
    value = float(total)
    for unit in ("B", "K", "M", "G", "T"):
        if value < 1024 or unit == "T":
            return f"{int(value)}{unit}" if unit == "B" else f"{value:.1f}{unit}"
        value /= 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        listed = run(["fleet", "worktree", "list", "--json"])
    except OSError as exc:
        print(f"worktree-audit: cannot run fleet: {exc}", file=sys.stderr)
        return 2
    if listed.returncode:
        print(f"worktree-audit: fleet worktree list failed: {listed.stderr.strip()}", file=sys.stderr)
        return 2
    try:
        rows = json.loads(listed.stdout)
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise ValueError("expected a JSON array of objects")
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"worktree-audit: cannot parse fleet output: {exc}", file=sys.stderr)
        return 2

    result = {"risky": [], "clean": [], "stale": []}
    for row in rows:
        section, item = audit(row)
        result[section].append(item)
    total = sum(x["size_bytes"] for section in result.values() for x in section)
    result["summary"] = {
        "risky": len(result["risky"]),
        "clean": len(result["clean"]),
        "stale": len(result["stale"]),
        "size": human_size(total),
        "size_bytes": total,
    }
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        for section in ("risky", "clean", "stale"):
            print(section)
            for item in result[section]:
                def shown(value):
                    return "unknown" if value is None else str(value)
                print(
                    f"  task {item['id']}  repo={shown(item['repo'])}  "
                    f"ahead={shown(item['ahead'])}  dirty={shown(item['dirty'])}  "
                    f"size={item['size']}"
                    + (f"  ({item['reason']})" if item["reason"] else "")
                )
        s = result["summary"]
        print(f"total size={s['size']}  risky={s['risky']} clean={s['clean']} stale={s['stale']}")
    return 1 if result["risky"] else 0


if __name__ == "__main__":
    sys.exit(main())
