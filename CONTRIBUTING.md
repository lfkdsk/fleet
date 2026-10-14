English | [中文](CONTRIBUTING.zh-CN.md)

# Contributing to Fleet

Fleet is a small executable repository rather than an installed Python package. Changes should preserve the clone-and-run path: `bin/fleet` must continue to find `schema.sql`, `channels.json`, adapters, and templates relative to the checkout.

## Development setup

Use Python 3.10 or newer, Bash, Git, and SQLite. Core Fleet uses the Python standard library; PyYAML is needed only to exercise YAML check specifications. The complete test matrix also requires `python3.14` on `PATH`.

```bash
git clone https://github.com/lfkdsk/fleet.git
cd fleet
export PATH="$PWD/bin:$PATH"
export FLEET_HOME=/var/tmp/fleet/dev-home
fleet init
```

Do not point development tests at a ledger you care about. The suites create isolated homes and fake model CLIs so they do not spend provider quota.

## Tests

Run the focused suite for the code you changed, then the public acceptance suites:

```bash
bash tests/smoke.sh
bash tests/contrib_smoke.sh
```

Before submitting a code change, run the complete smoke matrix and verify that every declared mutation still applies:

```bash
bash tests/run-all.sh
bash tests/mutate.sh --check-only
```

`tests/run-all.sh --jobs N` controls suite parallelism. It runs every `*smoke*.sh` suite once with the default `python3` and once with Python 3.14. `tests/mutate.sh --check-only` is the fast manifest integrity check: it proves that each mutation still changes its target. The full mutation run, `bash tests/mutate.sh --jobs N`, is much slower and checks that the named tests actually turn red.

Tests must not call a real provider. Put a stub executable first on `PATH`, or exercise an adapter with `FLEET_ADAPTER_DRYRUN=1`. Give each suite its own `FLEET_HOME` and temporary repository under `/var/tmp/fleet`; parallel suites must not share task scratch or worktrees.

## Project-agnostic guard

Fleet's scheduler, adapters, templates, tests, and public documentation must not encode a particular product, organization, checkout path, private endpoint, or user's machine. Several smoke suites scan for concrete project names because a hard-coded example can quietly become a scheduling rule or prompt assumption.

The names they look for come from `FLEET_FORBIDDEN_NAMES`, an extended regular expression; the default is a placeholder. If you run Fleet on your own projects, set it to their names when you run the suites, for example `FLEET_FORBIDDEN_NAMES='MyCompany|my-service' bash tests/run-all.sh`.

Keep fixtures self-contained:

- create repositories, channels, credentials, and model names inside the test;
- use temporary absolute paths instead of a developer's home directory;
- make a channel capability explicit in its fixture instead of relying on the shipped registry growing forever;
- keep example task text generic enough to run against an unrelated repository.

If a feature needs project policy, represent it as goal context, a task spec, checks, or runtime channel configuration rather than a source-code special case.

## Change discipline

Keep a commit focused on one behavior or documentation concern. Use a short imperative subject, explain the invariant or user-visible reason in the body when it is not obvious, and include the tests you ran in the pull request description.

Schema changes need an idempotent migration path in `fleet init`, tests from an older database shape, and review of all read-only consumers. Adapter changes need dry-run assertions, exit-code coverage, large-prompt transport, and concurrent task isolation. CLI changes should update `--help` first and keep the English and Chinese documentation in sync.

Do not commit generated ledgers, run directories, worktrees, provider credentials, or local service files. Do not weaken claim, attempt, review-family, or check-integrity guards merely to make a fixture pass; change the fixture so it states the capability it needs.

Architecture and adapter contracts are documented in [docs/architecture.md](docs/architecture.md) and [docs/adapters.md](docs/adapters.md).
