#!/usr/bin/env bash
# Shared Claude Code user-home setup for Fleet's claude-based adapters.
#
# CLAUDE_CONFIG_DIR relocates writable session state (notably projects/) out
# of the operator's ~/.claude session list.  The small symlink farm keeps the
# user configuration that changes how an invocation runs, while deliberately
# leaving history/session/cache directories private to Fleet.

# Preflight happens before the Claude process installs its normal redirections.
# Keep diagnostics in the attempt files as well as stderr so a detached task
# never fails with only wrapper.pid left behind.
fleet_claude_adapter_note() {
    local message="$1"
    printf '%s\n' "$message" >&2
    # The Fleet launcher redirects the adapter's whole stderr stream to LOG.
    # Direct adapter calls do not, so retain the explicit write for them.
    if [ "${FLEET_ADAPTER_STDERR_LOGGED:-}" != 1 ] && [ -n "${LOG:-}" ]; then
        if ! mkdir -p -- "$(dirname -- "$LOG")" \
           || ! printf '%s\n' "$message" >> "$LOG"; then
            printf 'claude adapter: cannot write diagnostic log %s\n' "$LOG" >&2
        fi
    fi
}

fleet_claude_adapter_fail() {
    local message="$1"
    fleet_claude_adapter_note "$message"
    if [ -n "${OUT:-}" ]; then
        if ! mkdir -p -- "$(dirname -- "$OUT")"; then
            printf 'claude adapter: cannot create failure output dir for %s\n' "$OUT" >&2
        elif [ -s "$OUT" ]; then
            if ! {
                printf '# Adapter startup failed\n\n%s\n\n' "$message"
                cat "$OUT"
            } > "$OUT.fleet-preflight.$$" \
              || ! mv -- "$OUT.fleet-preflight.$$" "$OUT"; then
                rm -f -- "$OUT.fleet-preflight.$$"
                printf 'claude adapter: cannot write failure output %s\n' "$OUT" >&2
            fi
        elif ! printf '# Adapter startup failed\n\n%s\n' "$message" > "$OUT"; then
            printf 'claude adapter: cannot write failure output %s\n' "$OUT" >&2
        fi
    fi
    return 1
}

# Claude Code's `-p` mode has exactly one assistant turn.  Keep this execution
# constraint at the adapter boundary so every Fleet prompt sent through either
# Claude adapter carries it, including hand-authored specs and generated review
# prompts.  Appending keeps the warning close to the point where the model
# decides whether to end its response, without rewriting the durable prompt.md.
fleet_claude_one_shot_prompt() {
    cat -- "$1" || return 1
    cat <<'EOF'


<claude-p-single-turn>
This worker is running through `claude -p`, which is a single-turn process.
Ending this response exits the process, so a later background-task completion
notification cannot reach you. Do not end the turn while waiting for one.
Run long commands in the foreground with a bounded timeout, or poll them until
they finish and inspect their results before continuing. Before your final
response, finish and verify every required deliverable, including reports and
verdict lines.
</claude-p-single-turn>
EOF
}

# Exit 0 means "Claude produced a response", not necessarily "the task is
# complete".  Detect only an explicit unresolved wait at the very end of that
# response.  The end anchor and first-person/standalone wording are deliberate:
# prose that mentions an earlier wait, quotes the adapter guidance, or reports
# that a command eventually completed must remain a valid successful answer.
fleet_claude_output_is_waiting() {
    local output_path="$1"
    [ -f "$output_path" ] || return 1
    python3 - "$output_path" <<'PY'
import re
import sys

try:
    with open(sys.argv[1], "rb") as handle:
        handle.seek(0, 2)
        size = handle.tell()
        handle.seek(max(0, size - 8192))
        tail = handle.read().decode("utf-8", "replace").strip()
except OSError:
    sys.exit(1)

markdown_tail = r'''[.!?。！？…]*["'”’`*_\])]*\s*$'''
wait_target = (
    r'''(?:the\s+|this\s+|that\s+|its\s+|our\s+|a\s+)?'''
    r'''(?:background\s+)?'''
    r'''(?:task|job|process|command|tests?|test\s+suite|build|demo|run|'''
    r'''completion(?:\s+notification)?|notification)\b'''
    r'''|(?:it|them)\s+to\s+(?:finish|complete|end)\b'''
)
english = re.compile(
    r'''(?:\b(?:i(?:['’]m|\s+am)|we(?:['’]re|\s+are))\s+'''
    r'''(?:still\s+)?waiting\s+(?:on|for)\s+(?:''' + wait_target + r''')'''
    r'''|\b(?:i|we)(?:['’]ll|\s+will)\s+'''
    r'''(?:(?:continue|keep)\s+(?:to\s+)?)?wait(?:ing)?\s+(?:on|for)\s+'''
    r'''(?:''' + wait_target + r''')'''
    r'''|(?:^|[\n.!?。！？]\s*)(?:still\s+)?waiting\s+(?:on|for)\s+'''
    r'''(?:''' + wait_target + r'''))'''
    r'''[^.!?。！？\n]{0,320}''' + markdown_tail,
    re.IGNORECASE,
)
chinese = re.compile(
    r'''(?:我(?:们)?(?:还在|仍在|正在|会继续|将继续)等待'''
    r'''|(?:还在|仍在|正在|继续)等待'''
    r'''|等待(?:这个|该|此)?(?:后台)?(?:任务|作业|进程|命令))'''
    r'''[^.!?。！？\n]{0,320}(?:完成|结束|通知)''' + markdown_tail,
)
sys.exit(0 if tail and (english.search(tail) or chinese.search(tail)) else 1)
PY
}

fleet_claude_reject_waiting_output() {
    local output_path="$1"
    local message tmp
    fleet_claude_output_is_waiting "$output_path" || return 1
    message="claude -p adapter: refusing successful exit because the final response says it is still waiting for background work; the one-shot process ended before its deliverables were complete"
    fleet_claude_adapter_note "$message"

    # Put the reason where both `fleet digest` and the original response show
    # it.  Failure to annotate the file does not undo the guard: stderr still
    # carries the reason and the adapter still exits nonzero.
    if [ -n "${OUT:-}" ] && [ -f "$output_path" ]; then
        tmp="$output_path.fleet-incomplete.$$"
        if {
            printf '# Incomplete Claude response\n\n%s\n\n' "$message"
            cat -- "$output_path"
        } > "$tmp" && mv -- "$tmp" "$output_path"; then
            :
        else
            rm -f -- "$tmp"
            fleet_claude_adapter_note \
                "claude -p adapter: could not annotate incomplete output $output_path"
        fi
    fi
    return 0
}

_fleet_claude_report_repair() {
    local entry_name="$1" backup="$2" link_source="$3"
    fleet_claude_adapter_note \
        "claude adapter: detected managed entry $entry_name replaced; backed up and rebuilt symlink (检测到托管项被覆盖，已备份并重建软链; backup=$backup; source=$link_source)"
}

_fleet_claude_refuse_non_symlink() {
    fleet_claude_adapter_fail \
        "claude adapter: refusing to replace non-symlink $1"
}

_fleet_claude_backup_dir() {
    local task_home="$1" backup_dir="$1/backups"
    if [ -L "$backup_dir" ] \
       || { [ -e "$backup_dir" ] && [ ! -d "$backup_dir" ]; } \
       || ! mkdir -p -m 700 "$backup_dir" \
       || [ -L "$backup_dir" ] || [ ! -d "$backup_dir" ] \
       || ! chmod 700 "$backup_dir"; then
        fleet_claude_adapter_fail \
            "claude adapter: cannot create managed-entry backup dir $backup_dir"
        return 1
    fi
    printf '%s\n' "$backup_dir"
}

_fleet_claude_next_backup() {
    local backup_dir="$1" entry_name="$2" epoch backup n=0
    epoch="$(date +%s)" || return 1
    backup="$backup_dir/$entry_name-$epoch"
    # Fleet adapters serialize on task_home, but leave existing evidence intact
    # even if the clock repeats or Claude replaces the link twice in one second.
    while [ "$n" -lt 1000 ] \
          && { [ -e "$backup" ] || [ -L "$backup" ]; }; do
        n=$((n + 1))
        epoch=$((epoch + 1))
        backup="$backup_dir/$entry_name-$epoch"
    done
    [ "$n" -lt 1000 ] || return 1
    printf '%s\n' "$backup"
}

_fleet_claude_archive_displaced() {
    local task_home="$1" entry_name="$2" displaced="$3"
    local recovery_kind="$4" backup_dir backup
    local secure_failure choose_failure move_failure

    if [ "$recovery_kind" = previous ]; then
        secure_failure="cannot secure previously displaced $entry_name; preserved at $displaced"
        choose_failure="cannot choose backup path for previously displaced $entry_name"
        move_failure="cannot archive previously displaced $entry_name"
    else
        secure_failure="cannot secure replaced $entry_name; preserved at $displaced"
        choose_failure="cannot choose backup path for $entry_name"
        move_failure="cannot move replaced $entry_name"
    fi

    if ! chmod 600 "$displaced"; then
        fleet_claude_adapter_fail "claude adapter: $secure_failure"
        return 1
    fi
    backup_dir="$(_fleet_claude_backup_dir "$task_home")" || return 1
    backup="$(_fleet_claude_next_backup \
        "$backup_dir" "$entry_name")" || {
        fleet_claude_adapter_fail \
            "claude adapter: $choose_failure in $backup_dir"
        return 1
    }
    if ! mv -T -- "$displaced" "$backup"; then
        fleet_claude_adapter_fail \
            "claude adapter: $move_failure to $backup; preserved at $displaced"
        return 1
    fi
    printf '%s\n' "$backup"
}

_fleet_claude_collect_displaced() {
    local task_home="$1" entry_name="$2"
    local orphan orphan_name suffix backup

    # A failed move into backups/ deliberately leaves the secured rename in
    # task_home. Once a later invocation has rebuilt the managed link, archive
    # only recovery names Fleet itself can have generated for this entry.
    for orphan in "$task_home"/.fleet-displaced-"$entry_name".*.*; do
        [ -e "$orphan" ] || [ -L "$orphan" ] || continue
        orphan_name="${orphan##*/}"
        suffix="${orphan_name#".fleet-displaced-$entry_name."}"
        [[ "$suffix" =~ ^[0-9]+\.[0-9]+$ ]] || continue
        if [ -L "$orphan" ] \
           || { [ ! -f "$orphan" ] && [ ! -d "$orphan" ]; }; then
            continue
        fi
        backup="$(_fleet_claude_archive_displaced \
            "$task_home" "$entry_name" "$orphan" previous)" || return 1
        fleet_claude_adapter_note \
            "claude adapter: archived previously displaced $entry_name (backup=$backup)"
    done
}

_fleet_claude_credentials_supersede() {
    # Exit 0 when $1 -- the file Claude wrote INSIDE the managed dir, replacing
    # our symlink -- has a newer, structurally complete claudeAiOauth block than
    # the user's source $2. With $3, atomically create (O_EXCL) a mode-0600
    # staging file containing $2 with only claudeAiOauth replaced from $1.
    #
    # File mtime is deliberately irrelevant. mcpOAuth and other independent
    # state share this JSON document and can rewrite it without changing login.
    python3 - "$@" <<'PY'
import json, math, os, sys

fresh_path, current_path = sys.argv[1], sys.argv[2]
output_path = sys.argv[3] if len(sys.argv) == 4 else None
if len(sys.argv) not in (3, 4):
    sys.exit(1)
try:
    with open(fresh_path, encoding="utf-8") as handle:
        fresh = json.load(handle)
    with open(current_path, encoding="utf-8") as handle:
        current = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(fresh, dict) or not isinstance(current, dict):
    sys.exit(1)

fresh_oauth = fresh.get("claudeAiOauth")
current_oauth = current.get("claudeAiOauth")
if not isinstance(fresh_oauth, dict) or not isinstance(current_oauth, dict):
    sys.exit(1)

# A logged-out or half-written file can have the normal top-level shape with a
# null token inside. Keep the existing completeness guard on both OAuth blocks:
# uncertainty is a refusal, never permission to overwrite the user's login.
for oauth in (fresh_oauth, current_oauth):
    for field in ("accessToken", "refreshToken"):
        value = oauth.get(field)
        if not isinstance(value, str) or not value:
            sys.exit(1)
    expires_at = oauth.get("expiresAt")
    if (isinstance(expires_at, bool)
            or not isinstance(expires_at, (int, float))
            or not math.isfinite(expires_at)):
        sys.exit(1)

# A later access-token expiry is the ordering carried by claudeAiOauth itself.
# At equal expiry, a changed refresh token is still a rotation worth returning;
# an identical token means only unrelated document state changed.
fresh_expiry = fresh_oauth["expiresAt"]
current_expiry = current_oauth["expiresAt"]
if fresh_expiry < current_expiry:
    sys.exit(1)
if (fresh_expiry == current_expiry
        and fresh_oauth["refreshToken"] == current_oauth["refreshToken"]):
    sys.exit(1)

if output_path is None:
    sys.exit(0)
if (os.path.dirname(os.path.abspath(output_path))
        != os.path.dirname(os.path.abspath(current_path))):
    sys.exit(1)

# Preserve mcpOAuth and every other user-side top-level key. The old
# whole-document completeness test protected a whole-file copy; this field-only
# merge makes unrelated candidate keys intentionally irrelevant.
merged = dict(current)
merged["claudeAiOauth"] = fresh_oauth
fd = None
try:
    fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        fd = None
        json.dump(merged, handle, ensure_ascii=False, separators=(",", ":"))
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
except (OSError, TypeError, ValueError):
    if fd is not None:
        os.close(fd)
    try:
        os.unlink(output_path)
    except OSError:
        pass
    sys.exit(1)
PY
}

_fleet_claude_stage_credentials() {
    # Kept separate from the predicate so a mutation can prove that the install
    # is a field merge, not a whole-document copy that discards mcpOAuth.
    _fleet_claude_credentials_supersede "$@"
}

_fleet_claude_promote_credentials() {
    # Give the user's source the credentials Claude refreshed inside the
    # managed dir, when those are the newer ones.
    #
    # Why this exists: CLAUDE_CONFIG_DIR isolation links .credentials.json back
    # to the user's Claude home, but Claude refreshes the token by RENAMING a
    # new file over that path -- which replaces the symlink itself, so the
    # refreshed token lands only inside Fleet's directory. Archiving it (the
    # behaviour for every other managed entry) strands it: the operator's own
    # session keeps a refresh token the server has already rotated away, and
    # the next interactive use asks them to log in again.
    #
    # Only .credentials.json. settings/agents/hooks/plugins are operator
    # configuration -- Claude replacing one of those is not a fact Fleet should
    # push back into the user's home.
    local task_home="$1" entry_name="$2" displaced="$3" link_source="$4"
    local backup_dir backup tmp
    [ "$entry_name" = .credentials.json ] || return 1
    [ "${FLEET_CLAUDE_CREDENTIAL_PROMOTE:-1}" = 1 ] || return 1
    [ -f "$displaced" ] && [ ! -L "$displaced" ] || return 1
    [ -f "$link_source" ] && [ ! -L "$link_source" ] || return 1
    cmp -s -- "$displaced" "$link_source" && return 1
    _fleet_claude_credentials_supersede "$displaced" "$link_source" || return 1

    # The operator's current file is evidence too: keep it before replacing it,
    # under a name that cannot collide with the replaced-entry backups.
    backup_dir="$(_fleet_claude_backup_dir "$task_home")" || return 1
    backup="$(_fleet_claude_next_backup \
        "$backup_dir" "$entry_name.user-source")" || return 1
    if ! cp -- "$link_source" "$backup" || ! chmod 600 "$backup"; then
        rm -f -- "$backup"
        fleet_claude_adapter_note \
            "claude adapter: cannot back up $link_source before promoting refreshed credentials; left unchanged"
        return 1
    fi

    # Merge from the live user document, not from the Fleet document: mcpOAuth
    # and all unrelated top-level state remain user-owned. The helper re-runs
    # the OAuth ordering check here, after the backup, so a concurrent newer
    # login is refused before staging.
    # Same directory, so the eventual rename is atomic -- the operator's Claude
    # never observes a partial credential file.
    tmp="$link_source.fleet-promote.$$"
    if [ -e "$tmp" ] || [ -L "$tmp" ]; then
        # Every other failure path here leaves a note; this one used to return
        # silently, so a skipped promotion looked like no promotion was due.
        fleet_claude_adapter_note \
            "claude adapter: cannot promote refreshed credentials; staging path $tmp already exists (previous copy=$backup)"
        return 1
    fi
    if ! _fleet_claude_stage_credentials \
        "$displaced" "$link_source" "$tmp"; then
        rm -f -- "$tmp"
        fleet_claude_adapter_note \
            "claude adapter: cannot stage refreshed credentials for $link_source; previous copy kept at $backup"
        return 1
    fi

    # The task-home flock serializes Fleet adapters. The user's own Claude does
    # not take it, so also refuse the rename if that source changed after our
    # backup (for example, because the user completed a fresh login).
    if [ ! -f "$link_source" ] || [ -L "$link_source" ] \
       || ! cmp -s -- "$link_source" "$backup"; then
        rm -f -- "$tmp"
        fleet_claude_adapter_note \
            "claude adapter: user credentials changed while promotion was staged; left unchanged (previous copy=$backup)"
        return 1
    fi
    if ! mv -fT -- "$tmp" "$link_source"; then
        rm -f -- "$tmp"
        fleet_claude_adapter_note \
            "claude adapter: cannot promote refreshed credentials to $link_source; previous copy kept at $backup"
        return 1
    fi
    fleet_claude_adapter_note \
        "claude adapter: promoted refreshed credentials to $link_source (已把刷新后的凭证回写用户目录; previous copy=$backup)"
}

_fleet_claude_link_managed_entry() {
    local link_source="$1" link_target="$2" task_home="$3"
    local entry_name="$4" attempt=0 displaced backup="" current rc

    # Do not use `ln -f` here. Claude can replace a managed link between a
    # check and the link operation. Move whatever is actually present aside,
    # inspect it, and preserve every regular file or directory before trying
    # the link.
    while [ "$attempt" -lt 8 ]; do
        attempt=$((attempt + 1))
        current=""
        if [ -L "$link_target" ]; then
            current="$(readlink "$link_target")" || continue
        elif [ -e "$link_target" ] \
             && [ ! -f "$link_target" ] && [ ! -d "$link_target" ]; then
            _fleet_claude_refuse_non_symlink "$link_target"
            return $?
        fi

        if [ "$current" != "$link_source" ] \
           && { [ -e "$link_target" ] || [ -L "$link_target" ]; }; then
            displaced="$task_home/.fleet-displaced-$entry_name.$$.$attempt"
            # A stale recovery file is evidence too. Never overwrite one if a
            # PID was reused; advance to another candidate instead.
            if [ -e "$displaced" ] || [ -L "$displaced" ]; then
                continue
            fi
            if ! mv -T -- "$link_target" "$displaced"; then
                continue
            fi
            if [ -L "$displaced" ]; then
                if ! rm -- "$displaced"; then
                    fleet_claude_adapter_fail \
                        "claude adapter: cannot remove stale managed symlink $displaced"
                    return 1
                fi
            elif [ -f "$displaced" ] || [ -d "$displaced" ]; then
                # A refreshed credential set is promoted to the user's source
                # first; failure there is never fatal (the source still holds
                # working credentials), and the file is archived either way.
                _fleet_claude_promote_credentials \
                    "$task_home" "$entry_name" "$displaced" "$link_source" \
                    || true
                backup="$(_fleet_claude_archive_displaced \
                    "$task_home" "$entry_name" "$displaced" current)" \
                    || return 1
            else
                # Put sockets/FIFOs/devices back and retain the original guard
                # rather than guessing that an unexpected entry is disposable.
                rc=0
                mv -T -- "$displaced" "$link_target" || rc=$?
                fleet_claude_adapter_fail \
                    "claude adapter: refusing to replace non-symlink $link_target"
                [ "$rc" = 0 ] || fleet_claude_adapter_note \
                    "claude adapter: could not restore unexpected entry; preserved at $displaced"
                return 1
            fi
        fi

        # No force: if a live Claude process wins the rename race, the next
        # loop backs that entry up too instead of unlinking a fresh update.
        if [ "$current" != "$link_source" ] \
           && ! ln -s "$link_source" "$link_target" 2>/dev/null; then
            continue
        fi
        _fleet_claude_collect_displaced \
            "$task_home" "$entry_name" || return 1
        if [ -n "$backup" ]; then
            _fleet_claude_report_repair \
                "$entry_name" "$backup" "$link_source"
        fi
        return 0
    done

    fleet_claude_adapter_fail \
        "claude adapter: cannot link $link_target to $link_source after concurrent managed-entry updates"
}

_fleet_claude_is_managed_entry() {
    case "$1" in
        .credentials.json|settings.json|agents|hooks|plugins) return 0 ;;
        *) return 1 ;;
    esac
}

_fleet_claude_config_kind() {
    case "$1" in
        oauth)
            printf '%s\t%s\n' \
                "${FLEET_HOME:-$HOME/.fleet}/claude-home" 1
            ;;
        api)
            printf '%s\t%s\n' \
                "${FLEET_HOME:-$HOME/.fleet}/claude-api-home" 0
            ;;
        token)
            printf '%s\t%s\n' \
                "${FLEET_HOME:-$HOME/.fleet}/claude-token-home" 0
            ;;
        *)
            fleet_claude_adapter_fail \
                "claude adapter: unknown isolated config kind $1"
            return 1
            ;;
    esac
}

# Kept as a top-level helper so the safety boundary can be unit-tested with a
# target outside FLEET_HOME. Only Fleet's five managed entries get the
# backup-and-repair treatment; every other non-symlink retains the old guard.
fleet_claude_link_config_entry() {
    local link_source="$1" link_target="$2" config_kind="${3:-oauth}"
    local task_home
    local entry_name relative lexical_ok=0
    local target_parent managed_parent lock_fd rc

    local config_spec
    config_spec="$(_fleet_claude_config_kind "$config_kind")" || return 1
    IFS=$'\t' read -r task_home _ <<<"$config_spec"

    entry_name="$(basename -- "$link_target")"
    case "$link_target" in
        "$task_home"/*)
            relative="${link_target#"$task_home"/}"
            case "$relative" in
                ""|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*) ;;
                *) lexical_ok=1 ;;
            esac
            ;;
    esac

    # Lexical containment rejects dot-segment spellings. Canonical containment
    # independently rejects a nested symlink that points outside task_home.
    target_parent="$(cd -P "$(dirname -- "$link_target")" 2>/dev/null && pwd)"
    managed_parent="$(cd -P "$task_home" 2>/dev/null && pwd)"
    if _fleet_claude_is_managed_entry "$entry_name" \
       && [ "$lexical_ok" = 1 ] \
       && [ ! -L "$task_home" ] && [ -d "$task_home" ] \
       && [ -n "$managed_parent" ] && [ "$target_parent" = "$managed_parent" ]; then
        if ! exec {lock_fd}<"$task_home"; then
            fleet_claude_adapter_fail \
                "claude adapter: cannot open isolated config dir $task_home for locking"
            return 1
        fi
        if ! flock -x "$lock_fd"; then
            exec {lock_fd}<&-
            fleet_claude_adapter_fail \
                "claude adapter: cannot lock isolated config dir $task_home"
            return 1
        fi
        _fleet_claude_link_managed_entry \
            "$link_source" "$link_target" "$task_home" "$entry_name"
        rc=$?
        flock -u "$lock_fd" || true
        exec {lock_fd}<&-
        return "$rc"
    fi

    if [ -e "$link_target" ] && [ ! -L "$link_target" ]; then
        _fleet_claude_refuse_non_symlink "$link_target"
        rc=$?
        return "$rc"
    fi
    if ! ln -sfn "$link_source" "$link_target"; then
        fleet_claude_adapter_fail \
            "claude adapter: cannot link $link_target to $link_source"
        return 1
    fi
}

# --- dedicated subscription token ----------------------------------------
# Sharing the operator's refreshable OAuth login with Fleet cannot be made
# safe. Claude refreshes by renaming a new .credentials.json over Fleet's
# managed symlink, the server rotates the refresh token, and the operator's
# own Claude (`claude rc`, a terminal session) keeps the rotated-away one.
# The promotion below copies the fresh login back, but only when the next
# Fleet invocation happens to run, and not at all once the operator's side
# has already failed its own refresh -- which is when the operator is told to
# log in again. A long-lived token from `claude setup-token`, kept in its own
# file, gives Fleet a credential that nothing refreshes: with it, the
# subscription channels run in a separate config home that has no credential
# file, so no Fleet process can rotate or rewrite the operator's login.
fleet_claude_oauth_token_file() {
    printf '%s\n' "${FLEET_CLAUDE_OAUTH_TOKEN_FILE:-${FLEET_HOME:-$HOME/.fleet}/claude-oauth-token}"
}

# Print the token in $1, or fail with a diagnostic. A present but unusable
# file is an error, never a reason to fall back to the shared login: falling
# back silently is exactly what the file exists to prevent.
_fleet_claude_read_oauth_token() {
    local token_file="$1"
    python3 - "$token_file" <<'PY'
import os, re, stat, sys

path = sys.argv[1]
try:
    info = os.lstat(path)
except OSError as error:
    print(f"cannot stat {path}: {error.strerror}", file=sys.stderr)
    sys.exit(1)
if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
    print(f"{path} is not a regular file", file=sys.stderr)
    sys.exit(1)
if info.st_uid != os.getuid():
    print(f"{path} is not owned by the current user", file=sys.stderr)
    sys.exit(1)
if info.st_mode & 0o077:
    print(f"{path} is readable by other users; run chmod 600 on it", file=sys.stderr)
    sys.exit(1)
try:
    with open(path, encoding="utf-8") as handle:
        lines = [line.strip() for line in handle.read().splitlines()]
except (OSError, UnicodeDecodeError) as error:
    print(f"cannot read {path}: {error}", file=sys.stderr)
    sys.exit(1)
lines = [line for line in lines if line]
if len(lines) != 1 or not re.fullmatch(r"[A-Za-z0-9._~+/=-]{20,4096}", lines[0]):
    print(f"{path} must hold exactly one token line", file=sys.stderr)
    sys.exit(1)
print(lines[0])
PY
}

# The token home must never hold a credential file: a link to the operator's
# login would hand Fleet the refreshable login again, and a regular file is
# whatever some earlier process wrote there. Links are removed; files are
# kept as evidence under backups/.
_fleet_claude_clear_token_home_credentials() {
    local task_home="$1" target="$1/.credentials.json" backup
    if [ -L "$target" ]; then
        rm -f -- "$target" || {
            fleet_claude_adapter_fail \
                "claude adapter: cannot remove credential link $target from the token home"
            return 1
        }
    elif [ -e "$target" ]; then
        if [ ! -f "$target" ]; then
            fleet_claude_adapter_fail \
                "claude adapter: refusing non-file credential entry $target in the token home"
            return 1
        fi
        backup="$(_fleet_claude_archive_displaced \
            "$task_home" .credentials.json "$target" current)" || return 1
        fleet_claude_adapter_note \
            "claude adapter: moved a credential file out of the token home (backup=$backup)"
    fi
}

fleet_claude_config_init() {
    local config_kind="${1:-oauth}"
    local source_home="$HOME/.claude"
    local task_home link_credentials
    local entry source target token_file token=""

    # Subscription channels prefer the dedicated token whenever its file
    # exists; see fleet_claude_oauth_token_file above.
    if [ "$config_kind" = oauth ]; then
        token_file="$(fleet_claude_oauth_token_file)"
        if [ -e "$token_file" ] || [ -L "$token_file" ]; then
            if ! token="$(_fleet_claude_read_oauth_token "$token_file" 2>&1)"; then
                fleet_claude_adapter_fail \
                    "claude adapter: unusable subscription token file: $token"
                return 1
            fi
            config_kind=token
        fi
    fi

    local config_spec
    config_spec="$(_fleet_claude_config_kind "$config_kind")" || return 1
    IFS=$'\t' read -r task_home link_credentials <<<"$config_spec"

    if [ -L "$task_home" ] \
       || { [ -e "$task_home" ] && [ ! -d "$task_home" ]; }; then
        fleet_claude_adapter_fail \
            "claude adapter: refusing non-directory isolated config path $task_home"
        return 1
    fi
    if ! mkdir -p -m 700 "$task_home" || ! chmod 700 "$task_home"; then
        fleet_claude_adapter_fail \
            "claude adapter: cannot create isolated config dir $task_home"
        return 1
    fi

    # Only the subscription-backed adapter may see the user's OAuth file.
    # API adapters authenticate with environment tokens and get a separate
    # config root, so they cannot rotate the user's refresh token.
    if [ "$link_credentials" = 1 ]; then
        target="$task_home/.credentials.json"
        fleet_claude_link_config_entry \
            "$source_home/.credentials.json" "$target" "$config_kind" \
            || return 1
    fi

    # settings preserves the operator's permissions/env/hooks; agents keeps
    # channels.json's --agent feature; hooks and plugins keep user-installed
    # behavior referenced by those settings. Missing optional entries simply
    # stay absent. projects/history/session-env/cache and ~/.claude.json are
    # not linked: those carry project/session state (and the user's unrelated
    # global MCP registry), which this Fleet-owned directory must isolate.
    for entry in settings.json agents hooks plugins; do
        source="$source_home/$entry"
        target="$task_home/$entry"
        [ -e "$source" ] || [ -L "$source" ] || continue
        fleet_claude_link_config_entry \
            "$source" "$target" "$config_kind" || return 1
    done

    if [ "$config_kind" = token ]; then
        _fleet_claude_clear_token_home_credentials "$task_home" || return 1
        export CLAUDE_CODE_OAUTH_TOKEN="$token"
    fi
    # claude_p.sh reads this to decide whether a refreshed login can exist
    # inside the config home at all (only the shared-login mode).
    export FLEET_CLAUDE_AUTH="$config_kind"
    export CLAUDE_CONFIG_DIR="$task_home"
}
