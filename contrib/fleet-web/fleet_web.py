#!/usr/bin/env python3
"""fleet-web: read-only web view of `fleet top`, with per-goal pages and GitHub login.

Pages: /  (overview)   /goals  (every goal)   /goal/<id>  (one goal)   /task/<id>  (one task)   /login
API:   /api/top        /api/goals              /api/goal/<id>           /api/task/<id>[/log]           POST /auth/session   POST /auth/logout

Who may look:
  * Optional GitHub login, off unless configured: owners of FLEET_WEB_ORG, through a
    GitHub OAuth app (FLEET_WEB_GH_CLIENT_ID) whose code exchange runs at
    FLEET_WEB_AUTH_WORKER (a small service holding the client secret that bounces the
    token to PUBLIC_ORIGIN/#oauth_token=...). The GitHub token is used once to learn
    who the visitor is and then dropped; the browser keeps only an HMAC-signed
    session cookie. Org owners are listed with this machine's own `gh` login.
  * Off-tunnel requests (LAN / ssh -L, no Cf-Connecting-Ip header) may use the
    break-glass token in ~/.config/fleet-web/token as ?t=<token>.
  * It listens on 127.0.0.1 by default (FLEET_WEB_HOST to change).
"""
import re
import base64, gzip, hashlib, hmac, http.server, json, os, secrets, sqlite3, subprocess, threading, time
import urllib.error, urllib.parse, urllib.request
from pathlib import Path

HOME = Path.home()
HERE = Path(__file__).parent
DB = HOME / ".fleet/fleet.db"
FLEET = os.environ.get("FLEET_BIN", str(HOME / ".local/bin/fleet"))
CONF = HOME / ".config/fleet-web"
TOKEN = (CONF / "token").read_text().strip()
KEY_FILE = CONF / "session-key"
if not KEY_FILE.exists():
    KEY_FILE.write_text(secrets.token_hex(32)); KEY_FILE.chmod(0o600)
SESSION_KEY = KEY_FILE.read_text().strip().encode()

HOST = os.environ.get("FLEET_WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("FLEET_WEB_PORT", "8790"))
GH_CLIENT_ID = os.environ.get("FLEET_WEB_GH_CLIENT_ID", "")
AUTH_WORKER = os.environ.get("FLEET_WEB_AUTH_WORKER", "")
ORG = os.environ.get("FLEET_WEB_ORG", "")
GH_LOGIN = bool(GH_CLIENT_ID and AUTH_WORKER and ORG)
SESSION_S = 24 * 3600
CACHE_S = 3

_lock = threading.Lock()
_cache = {"at": 0, "body": b"{}"}


# ---------------------------------------------------------------- data
def ro():
    c = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)
    c.row_factory = sqlite3.Row
    return c


def rows(c, sql, *a):
    return [dict(r) for r in c.execute(sql, a)]


def autonomy_of(raw):
    try:
        return json.loads(raw or "null") or {}
    except ValueError:
        return {}


def extras():
    c = ro()
    try:
        now = int(time.time())
        out = {}
        out["goals"] = {r["id"]: r["statement"] for r in rows(c,
            "SELECT id, statement FROM goal WHERE id IN (SELECT DISTINCT goal_id FROM task "
            "WHERE status IN ('running','queued') OR ended_at > ?)", now - 86400)}
        out["active_goals"] = rows(c,
            "SELECT g.id, g.statement, g.created_at, "
            "(SELECT COUNT(*) FROM task t WHERE t.goal_id=g.id) total, "
            "(SELECT COUNT(*) FROM task t WHERE t.goal_id=g.id AND t.status IN ('running','queued')) live, "
            "(SELECT MAX(COALESCE(t.ended_at,t.started_at,t.created_at)) FROM task t WHERE t.goal_id=g.id) last_at "
            "FROM goal g WHERE g.status='open' AND (g.created_at > ? OR EXISTS (SELECT 1 FROM task t WHERE t.goal_id=g.id "
            "AND (t.status IN ('running','queued') OR t.created_at > ?))) ORDER BY g.id DESC", now - 172800, now - 172800)
        out["recent"] = rows(c,
            "SELECT id, goal_id, title, channel, resolved_model AS model, status, verdict, exit_code, "
            "started_at, ended_at FROM task WHERE ended_at IS NOT NULL ORDER BY ended_at DESC LIMIT 25")
        out["needs_user"] = rows(c,
            "SELECT id, goal_id, task_id, question, ts FROM decision "
            "WHERE needs_user=1 AND resolved_at IS NULL ORDER BY id DESC LIMIT 20")
        out["autonomy"] = []
        for r in rows(c, "SELECT id, statement, autonomy FROM goal WHERE status='open' AND autonomy IS NOT NULL"):
            a = autonomy_of(r["autonomy"])
            if a.get("enabled"):
                out["autonomy"].append({
                    "goal_id": r["id"], "statement": r["statement"], "channel": a.get("channel"),
                    "model": a.get("model"), "rounds_used": a.get("rounds_used"),
                    "max_rounds": a.get("max_rounds"), "reason": a.get("last_reason"),
                    "finished_at": a.get("last_finished_at")})
        out["last24h"] = rows(c,
            "SELECT channel, SUM(status='done') done, SUM(status='failed') failed, "
            "SUM(status='cancelled') cancelled, SUM(status IN ('running','queued')) live, COUNT(*) total "
            "FROM task WHERE created_at > ? GROUP BY channel ORDER BY total DESC", now - 86400)
        return out
    finally:
        c.close()


def snapshot():
    with _lock:
        if time.time() - _cache["at"] < CACHE_S:
            return _cache["body"]
        try:
            top = json.loads(subprocess.run([FLEET, "top", "--once", "--json"], capture_output=True,
                                            text=True, timeout=30).stdout or "{}")
        except Exception as e:
            top = {"error": f"fleet top failed: {type(e).__name__}"}
        try:
            top["extras"] = extras()
        except Exception as e:
            top["extras_error"] = f"{type(e).__name__}: {e}"
        top["served_at"] = int(time.time())
        _cache["body"] = json.dumps(top, ensure_ascii=False).encode()
        _cache["at"] = time.time()
        return _cache["body"]


_WT_RE = re.compile(r"/worktrees/task-(\d+)/?$")


def task_rows(c, gid):
    """Goal tasks plus the relations the timeline draws: deps, review_of, parent,
    base_task, and 'continues' (a task whose cwd is another task's worktree)."""
    out = []
    for r in rows(c,
            "SELECT id, title, status, channel, resolved_model AS model, family, verdict, exit_code, review_of, "
            "deps, parent_id, base_task, cwd, out_path, created_at, started_at, ended_at "
            "FROM task WHERE goal_id IS ? ORDER BY id DESC LIMIT 400", gid):
        deps = []
        for x in str(r.pop("deps") or "").replace("[", "").replace("]", "").replace(",", " ").split():
            x = x.split(":")[0]
            if x.isdigit():
                deps.append(int(x))
        r["deps"] = deps
        m = _WT_RE.search(r.pop("cwd") or "")
        r["continues"] = int(m.group(1)) if m else None
        op = r.pop("out_path")
        try:
            r["out_bytes"] = os.path.getsize(op) if op else None
        except OSError:
            r["out_bytes"] = None
        out.append(r)
    return out


def goal_detail(gid):
    """One goal; gid None is the tasks that belong to no goal (/goal/none)."""
    c = ro()
    try:
        if gid is None:
            g = {"id": None, "statement": "没挂 goal 的任务", "acceptance": None, "status": "无 goal",
                 "created_at": None, "context": None, "autonomy": None, "approval_gates": None}
        else:
            g = c.execute("SELECT id, statement, acceptance, status, created_at, context, autonomy, approval_gates "
                          "FROM goal WHERE id=?", (gid,)).fetchone()
            if not g:
                return None
        g = dict(g)
        g["autonomy"] = autonomy_of(g["autonomy"]) or None
        plan = c.execute("SELECT revision, rationale, created_at FROM plan WHERE goal_id IS ? ORDER BY revision DESC "
                         "LIMIT 1", (gid,)).fetchone()
        return {
            "served_at": int(time.time()), "goal": g, "plan": dict(plan) if plan else None,
            "by_status": rows(c, "SELECT status, COUNT(*) n FROM task WHERE goal_id IS ? GROUP BY status ORDER BY n DESC", gid),
            "by_channel": rows(c,
                "SELECT channel, COUNT(*) total, SUM(status='done') done, SUM(status='failed') failed, "
                "SUM(status='cancelled') cancelled, SUM(status IN ('running','queued')) live "
                "FROM task WHERE goal_id IS ? GROUP BY channel ORDER BY total DESC", gid),
            "tasks": task_rows(c, gid),
            "task_total": c.execute("SELECT COUNT(*) FROM task WHERE goal_id IS ?", (gid,)).fetchone()[0],
            "decisions": rows(c,
                "SELECT id, task_id, question, verdict, needs_user, resolved_at, ts FROM decision WHERE goal_id IS ? "
                "ORDER BY id DESC LIMIT 40", gid),
            "claims": rows(c,
                "SELECT cl.status, COUNT(*) n FROM claim cl JOIN task t ON t.id=cl.task_id WHERE t.goal_id IS ? "
                "GROUP BY cl.status", gid),
        }
    finally:
        c.close()


def goals_all():
    """Every goal ever made, newest first, with task counts and the last activity time."""
    c = ro()
    try:
        out = []
        for r in rows(c,
                "SELECT g.id, g.statement, g.status, g.created_at, g.autonomy, "
                "COUNT(t.id) total, SUM(t.status='done') done, SUM(t.status='failed') failed, "
                "SUM(t.status='cancelled') cancelled, SUM(t.status IN ('running','queued')) live, "
                "MAX(COALESCE(t.ended_at, t.started_at, t.created_at)) last_at "
                "FROM goal g LEFT JOIN task t ON t.goal_id=g.id GROUP BY g.id ORDER BY g.id DESC"):
            r["auto"] = bool(autonomy_of(r.pop("autonomy")).get("enabled"))
            out.append(r)
        needs = {r["goal_id"]: r["n"] for r in rows(c,
            "SELECT goal_id, COUNT(*) n FROM decision WHERE needs_user=1 AND resolved_at IS NULL GROUP BY goal_id")}
        for r in out:
            r["needs_user"] = needs.get(r["id"], 0)
        return {"served_at": int(time.time()), "goals": out}
    finally:
        c.close()


TEXT_CAP = 256 * 1024
_trace_cache = {}


def _read_capped(path, cap=TEXT_CAP, tail=False):
    """(text, total_bytes) of a file, at most `cap` bytes from the head (or tail)."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if tail and size > cap:
                f.seek(size - cap)
            data = f.read(cap)
        return data.decode("utf-8", "replace"), size
    except (OSError, TypeError):
        return None, 0


def _attempt_dirs(run_dir):
    base = Path(run_dir).parent if run_dir else None
    if not base or not base.is_dir():
        return []
    num = lambda p: int(p.name.rsplit("-", 1)[-1]) if p.name.rsplit("-", 1)[-1].isdigit() else 0
    return sorted((p for p in base.glob("attempt-*") if p.is_dir()), key=num)


def task_trace(tid, attempt_no, adir, live):
    """`fleet trace --json`, cached by trace.json mtime (finished) or 5 s (live)."""
    tj = next((adir / n for n in ("trace.json.gz", "trace.json") if (adir / n).is_file()), adir / "trace.json.gz")
    try:
        stamp = tj.stat().st_mtime
    except OSError:
        stamp = None
    key = (tid, attempt_no)
    hit = _trace_cache.get(key)
    if hit and ((not live and stamp is not None and hit[0] == stamp) or (live and time.time() - hit[1] < 5)):
        return hit[2], hit[3]
    if stamp is not None and not live:
        try:
            with (gzip.open(tj, "rt") if tj.suffix == ".gz" else open(tj)) as f:
                tr = json.load(f)
            _trace_cache[key] = (stamp, time.time(), tr, None)
            return tr, None
        except (OSError, ValueError):
            pass
    try:
        r = subprocess.run([FLEET, "trace", str(tid), "--attempt", str(attempt_no), "--json"],
                           capture_output=True, text=True, timeout=90)
        if r.returncode != 0:
            err = (r.stderr.strip().splitlines() or ["fleet trace failed"])[-1]
            return None, err
        tr = json.loads(r.stdout or "null")
    except subprocess.TimeoutExpired:
        return None, "fleet trace timed out"
    except ValueError:
        return None, "fleet trace returned no JSON"
    tj = next((adir / n for n in ("trace.json.gz", "trace.json") if (adir / n).is_file()), tj)
    try:
        stamp = tj.stat().st_mtime
    except OSError:
        stamp = None
    _trace_cache[key] = (stamp, time.time(), tr, None)
    return tr, None


def task_detail(tid, attempt_no=None):
    c = ro()
    try:
        t = c.execute(
            "SELECT id, goal_id, parent_id, title, spec_path, channel, family, model, resolved_model, "
            "resolved_agent, effort, role, status, verdict, verdict_by, exit_code, attempt, max_attempts, "
            "cwd, worktree, worktree_branch, base_task, base_commit, deps, review_of, lens, timeout_s, "
            "run_dir, out_path, log_path, created_at, started_at, ended_at FROM task WHERE id=?", (tid,)).fetchone()
        if not t:
            return None
        t = dict(t)
        g = c.execute("SELECT statement FROM goal WHERE id=?", (t["goal_id"],)).fetchone() if t["goal_id"] else None
        events = rows(c, "SELECT ts, kind, payload FROM event WHERE task_id=? AND kind != 'task.blocked' "
                         "ORDER BY id DESC LIMIT 200", tid)
        blocked = c.execute("SELECT COUNT(*), MIN(ts), MAX(ts) FROM event WHERE task_id=? AND kind='task.blocked'",
                            (tid,)).fetchone()
        claims = rows(c, "SELECT id, claim, evidence, status, resolution, ts FROM claim WHERE task_id=? ORDER BY id", tid)
        artifacts = rows(c, "SELECT id, kind, path, bytes, summary, ts FROM artifact WHERE task_id=? ORDER BY id", tid)
        reviews = rows(c, "SELECT id, title, status, verdict FROM task WHERE review_of=? ORDER BY id", tid)
        children = rows(c, "SELECT id, title, status FROM task WHERE parent_id=? OR base_task=? ORDER BY id", tid, tid)
    finally:
        c.close()
    dirs = _attempt_dirs(t["run_dir"])
    attempts = []
    for n, d in enumerate(dirs, 1):
        size = lambda name: (d / name).stat().st_size if (d / name).exists() else None
        attempts.append({"n": n, "dir": d.name, "log_bytes": size("log.txt"), "out_bytes": size("out.md"),
                         "trace": (d / "trace.json.gz").exists() or (d / "trace.json").exists(),
                         "kept": sorted(p.name for p in d.glob("transcript.*"))})
    if attempt_no is None or not 1 <= attempt_no <= len(dirs):
        attempt_no = len(dirs) or None
    adir = dirs[attempt_no - 1] if attempt_no else None
    prompt, prompt_bytes = _read_capped(t["spec_path"])
    out, out_bytes = _read_capped(adir / "out.md") if adir else (None, 0)
    live = t["status"] in ("running", "queued")
    trace, trace_error = task_trace(tid, attempt_no, adir, live) if adir else (None, "no run directory yet")
    for k in ("spec_path", "run_dir", "out_path", "log_path"):
        t.pop(k, None)
    return {"served_at": int(time.time()), "task": t, "goal": g["statement"] if g else None,
            "attempt": attempt_no, "attempts": attempts, "prompt": prompt, "prompt_bytes": prompt_bytes,
            "out": out, "out_bytes": out_bytes, "trace": trace, "trace_error": trace_error,
            "events": events, "blocked": {"n": blocked[0], "first": blocked[1], "last": blocked[2]},
            "claims": claims, "artifacts": artifacts, "reviews": reviews, "children": children}


def task_log(tid, attempt_no=None, whole=False):
    c = ro()
    try:
        r = c.execute("SELECT run_dir FROM task WHERE id=?", (tid,)).fetchone()
    finally:
        c.close()
    if not r:
        return None
    dirs = _attempt_dirs(r["run_dir"])
    if not dirs:
        return ""
    d = dirs[(attempt_no or len(dirs)) - 1] if (attempt_no or len(dirs)) <= len(dirs) else dirs[-1]
    text, size = _read_capped(d / "log.txt", 16 * 1024 * 1024 if whole else TEXT_CAP, tail=True)
    if text is None:
        return ""
    if size > len(text.encode()) and not whole:
        text = f"[只显示最后 {TEXT_CAP // 1024} KB，共 {size // 1024} KB]\n" + text
    return text


# ---------------------------------------------------------------- auth
def sign(payload: dict) -> str:
    raw = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")
    mac = hmac.new(SESSION_KEY, raw.encode(), hashlib.sha256).hexdigest()
    return f"{raw}.{mac}"


def unsign(value: str):
    raw, _, mac = (value or "").partition(".")
    if not raw or not hmac.compare_digest(mac, hmac.new(SESSION_KEY, raw.encode(), hashlib.sha256).hexdigest()):
        return None
    try:
        d = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except Exception:
        return None
    return d if d.get("exp", 0) > time.time() else None


def gh(path, token):
    req = urllib.request.Request("https://api.github.com" + path, headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "fleet-web"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, None
    except Exception:
        return 0, None


_owners = {"at": 0, "set": frozenset()}


def org_owners():
    """Owners (role=admin) of ORG, looked up with this machine's own `gh` login (an org owner), cached 10 min.
    The visitor's OAuth token is only used to learn who they are: OAuth app access to the org is restricted,
    so their token cannot read org membership itself."""
    if time.time() - _owners["at"] > 600:
        try:
            out = subprocess.run([os.environ.get("GH_BIN", "gh"), "api", "--paginate", f"orgs/{ORG}/members?role=admin", "--jq", ".[].login"],
                                 capture_output=True, text=True, timeout=30)
            if out.returncode == 0:
                _owners["set"] = frozenset(x.strip().lower() for x in out.stdout.split() if x.strip())
                _owners["at"] = time.time()
        except Exception:
            pass
    return _owners["set"]


def org_owner(token):
    """(login, None) if the token's user is an owner of ORG, else (None, reason)."""
    if not GH_LOGIN:
        return None, "这台机器没有配置 GitHub 登录"
    if not token:
        return None, "没有拿到 GitHub 授权"
    st, user = gh("/user", token)
    if st != 200 or not user:
        return None, "GitHub 没认出这个登录"
    owners = org_owners()
    if not owners:
        return None, f"暂时查不到 {ORG} 的 owner 名单，请稍后再试"
    if user["login"].lower() not in owners:
        return None, f"{user['login']} 不是 {ORG} 的 owner"
    return user["login"], None


# ---------------------------------------------------------------- http
class H(http.server.BaseHTTPRequestHandler):
    def cookies(self):
        out = {}
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k:
                out[k] = v
        return out

    def via_tunnel(self):
        return bool(self.headers.get("Cf-Connecting-Ip"))

    def cookie(self, name, value, max_age):
        flags = "; Secure" if self.via_tunnel() else ""
        return ("Set-Cookie", f"{name}={value}; Path=/; HttpOnly; SameSite=Lax; Max-Age={max_age}{flags}")

    def who(self, qs):
        """(identity, extra headers) or (None, ())."""
        s = unsign(self.cookies().get("fw_session", ""))
        if s:
            return s["login"], ()
        if not self.via_tunnel():
            t = qs.get("t", [""])[0]
            if t and hmac.compare_digest(t, TOKEN):
                sess = sign({"login": "token", "exp": int(time.time()) + 30 * 86400})
                return "token", (self.cookie("fw_session", sess, 30 * 86400),)
        return None, ()

    def send(self, code, body, ctype, extra=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body if isinstance(body, bytes) else body.encode())

    def page(self, name, extra=()):
        self.send(200, (HERE / name).read_text(), "text/html; charset=utf-8", extra)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        if u.path == "/style.css":
            return self.send(200, (HERE / "style.css").read_text(), "text/css; charset=utf-8")
        if u.path == "/login/start":
            if not GH_LOGIN:
                return self.send(404, "没有配置 GitHub 登录（FLEET_WEB_GH_CLIENT_ID / FLEET_WEB_AUTH_WORKER / FLEET_WEB_ORG）".encode(),
                                 "text/plain; charset=utf-8")
            state = secrets.token_urlsafe(16)
            q = urllib.parse.urlencode({"client_id": GH_CLIENT_ID, "redirect_uri": AUTH_WORKER + "/callback",
                                        "state": state, "allow_signup": "false"})
            return self.send(302, b"", "text/plain", (("Location", "https://github.com/login/oauth/authorize?" + q),
                                                     self.cookie("fw_state", state, 600)))
        me, extra = self.who(qs)
        if u.path.startswith("/api/"):
            if not me:
                return self.send(401, b'{"error":"login required"}', "application/json")
            if u.path == "/api/top":
                return self.send(200, snapshot(), "application/json; charset=utf-8", extra)
            if u.path == "/api/me":
                return self.send(200, json.dumps({"login": me, "org": ORG}), "application/json", extra)
            if u.path == "/api/goals":
                return self.send(200, json.dumps(goals_all(), ensure_ascii=False), "application/json; charset=utf-8", extra)
            m = re.match(r"^/api/task/(\d+)(/log)?$", u.path)
            if m:
                att = qs.get("attempt", [""])[0]
                att = int(att) if att.isdigit() else None
                if m.group(2):
                    text = task_log(int(m.group(1)), att, qs.get("all", [""])[0] == "1")
                    if text is None:
                        return self.send(404, b"no such task\n", "text/plain")
                    return self.send(200, text, "text/plain; charset=utf-8", extra)
                d = task_detail(int(m.group(1)), att)
                if d is None:
                    return self.send(404, b'{"error":"no such task"}', "application/json")
                return self.send(200, json.dumps(d, ensure_ascii=False), "application/json; charset=utf-8", extra)
            if u.path.startswith("/api/goal/") and (u.path[10:].isdigit() or u.path[10:] == "none"):
                d = goal_detail(int(u.path[10:]) if u.path[10:].isdigit() else None)
                if d is None:
                    return self.send(404, b'{"error":"no such goal"}', "application/json")
                return self.send(200, json.dumps(d, ensure_ascii=False), "application/json; charset=utf-8", extra)
            return self.send(404, b'{"error":"not found"}', "application/json")
        if not me:
            # login.html also finishes the OAuth round trip (#oauth_token=... lands on whatever page)
            return self.page("login.html")
        if u.path == "/":
            return self.page("index.html", extra)
        if u.path in ("/goals", "/goals/"):
            return self.page("goals.html", extra)
        if u.path.startswith("/task/") and u.path[6:].isdigit():
            return self.page("task.html", extra)
        if u.path.startswith("/goal/") and (u.path[6:].isdigit() or u.path[6:] == "none"):
            return self.page("goal.html", extra)
        self.send(404, b"not found\n", "text/plain")

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        n = min(int(self.headers.get("Content-Length") or 0), 8192)
        body = self.rfile.read(n)
        if u.path == "/auth/logout":
            return self.send(204, b"", "text/plain", (self.cookie("fw_session", "", 0),))
        if u.path != "/auth/session":
            return self.send(404, b"", "text/plain")
        try:
            d = json.loads(body or b"{}")
        except ValueError:
            d = {}
        state = self.cookies().get("fw_state", "")
        if not state or not hmac.compare_digest(str(d.get("state", "")), state):
            print(f"auth: state mismatch (cookie={'yes' if state else 'no'})", flush=True)
            return self.send(400, json.dumps({"error": "登录状态过期或不匹配，请重新登录"}, ensure_ascii=False),
                             "application/json; charset=utf-8", (self.cookie("fw_state", "", 0),))
        login, why = org_owner(str(d.get("token", "")))
        print(f"auth: {'ok ' + login if login else 'denied: ' + str(why)}", flush=True)
        if not login:
            return self.send(403, json.dumps({"error": why}, ensure_ascii=False), "application/json; charset=utf-8",
                             (self.cookie("fw_state", "", 0),))
        sess = sign({"login": login, "exp": int(time.time()) + SESSION_S})
        return self.send(200, json.dumps({"login": login}), "application/json",
                         (self.cookie("fw_session", sess, SESSION_S), self.cookie("fw_state", "", 0)))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    http.server.ThreadingHTTPServer((HOST, PORT), H).serve_forever()
