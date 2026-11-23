"""Clone the repositories named in REPOWISE_REPOS, register and index them
through the Repowise API, then run the MCP server (streamable HTTP) for the
first one. Bad repo URLs are logged and skipped, never fatal."""
import json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request
from pathlib import Path

API = "http://127.0.0.1:7337"
KEY = os.environ["REPOWISE_API_KEY"]
DATA = Path(os.environ.get("REPOWISE_DATA", "/data"))
REPOS = DATA / "repos"


def log(msg):
    print(f"repowise-bootstrap: {msg}", flush=True)


def api(method, path, body=None, timeout=60):
    req = urllib.request.Request(
        API + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def wait_api():
    for _ in range(600):
        try:
            if api("GET", "/health", timeout=5).get("status"):
                return
        except Exception:
            pass
        time.sleep(1)
    sys.exit("API did not come up")


def repo_urls():
    raw = os.environ.get("REPOWISE_REPOS", "")
    return [u for u in re.split(r"[\s,]+", raw.strip()) if u]


def safe_name(url):
    name = url.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]
    name = re.sub(r"\.git$", "", name)
    return re.sub(r"[^A-Za-z0-9._-]", "-", name) or "repo"


def git(*args, cwd=None, timeout=1800):
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    return subprocess.run(["git", *args], cwd=cwd, env=env, timeout=timeout,
                          capture_output=True, text=True)


def setup_credentials():
    token = os.environ.get("GIT_TOKEN")
    if not token:
        return
    store = Path(os.environ["HOME"]) / ".git-credentials"
    lines = []
    for host in ("github.com", "gitlab.com", "bitbucket.org"):
        user = {"gitlab.com": "oauth2", "bitbucket.org": "x-token-auth"}.get(host, "x-access-token")
        lines.append(f"https://{user}:{urllib.parse.quote(token, safe='')}@{host}")
    store.write_text("\n".join(lines) + "\n")
    store.chmod(0o600)
    git("config", "--global", "credential.helper", f"store --file={store}")


def clone(url):
    dest = REPOS / safe_name(url)
    if (dest / ".git").exists():
        return dest
    log(f"cloning {url} into {dest}")
    tmp = dest.with_name(dest.name + ".partial")
    if tmp.exists():
        subprocess.run(["rm", "-r", str(tmp)])
    r = git("clone", "--single-branch", "--no-tags", url, str(tmp))
    if r.returncode != 0:
        log(f"clone failed for {url}: {r.stderr.strip()[-400:]}")
        if tmp.exists():
            subprocess.run(["rm", "-r", str(tmp)])
        return None
    tmp.rename(dest)
    return dest


def wait_job(job_id):
    while True:
        try:
            job = api("GET", f"/api/jobs/{job_id}")
        except Exception as exc:
            log(f"job {job_id}: {exc}")
            time.sleep(10)
            continue
        if job["status"] not in ("pending", "running"):
            return job
        time.sleep(5)


def indexed(repo_id):
    jobs = api("GET", f"/api/jobs?repo_id={repo_id}&limit=50") or []
    return any(j.get("status") == "completed" for j in jobs)


def attempts_file(path):
    return Path(os.environ["HOME"]) / f".index-attempts-{path.name}"


def register(path):
    repos = api("GET", "/api/repos")
    for repo in repos:
        if Path(repo["local_path"]).resolve() == path.resolve():
            if indexed(repo["id"]) or os.environ.get("REPOWISE_SMALL") == "1":
                return repo, None
            # A first index that was interrupted (restart, out of memory):
            # retry it twice at most, so a repo too big for this service's
            # memory cannot put the service in a restart loop.
            f = attempts_file(path)
            n = int(f.read_text() or 0) if f.exists() else 0
            if n >= 2:
                log(f"{path.name}: first index failed twice; not retrying. Give the service "
                    "more memory, then start it from the dashboard (Index).")
                return repo, None
            f.write_text(str(n + 1))
            job = api("POST", f"/api/repos/{repo['id']}/index", timeout=120)
            return repo, job.get("job_id")
    url = git("remote", "get-url", "origin", cwd=path).stdout.strip()
    small = os.environ.get("REPOWISE_SMALL") == "1"
    if not small:
        attempts_file(path).write_text("1")
    created = api("POST", "/api/repos",
                  {"name": path.name, "local_path": str(path), "url": url, "index": not small},
                  timeout=120)
    if small:
        log(f"{path.name}: registered but not indexed, because this service has under 900 MB "
            "of memory and indexing a medium repository needs about 1 GB. Open it in the "
            "dashboard and press Index (small repositories fit), or give the service 1 GB.")
    return created, created.get("initial_job_id")


def main():
    wait_api()
    REPOS.mkdir(parents=True, exist_ok=True)
    setup_credentials()
    first = None
    for url in repo_urls():
        path = clone(url)
        if path is None:
            continue
        try:
            repo, job_id = register(path)
        except urllib.error.HTTPError as exc:
            log(f"register failed for {path}: {exc.code} {exc.read()[:300]!r}")
            continue
        if job_id:
            log(f"indexing {path.name} (job {job_id}); this can take a few minutes")
            job = wait_job(job_id)
            log(f"index of {path.name} finished: {job['status']} {job.get('error_message') or ''}")
        # The server owns this clone: fetch and fast-forward before each sync.
        subprocess.run(["repowise", "config", "set", "managed_checkout", "true",
                        "--path", str(path)], capture_output=True)
        first = first or path
    if first is None:
        log("no repository to serve over MCP yet. Set REPOWISE_REPOS and redeploy.")
        while True:
            time.sleep(3600)
    if os.environ.get("REPOWISE_SMALL") == "1":
        log("MCP server is off: this service has under 900 MB of memory (needs about 1 GB).")
        while True:
            time.sleep(3600)
    log(f"MCP server for {first.name} at /mcp")
    os.chdir(first)
    os.execvp("repowise", ["repowise", "mcp", str(first), "--transport", "streamable-http",
                           "--host", "127.0.0.1", "--port", "7338"])


if __name__ == "__main__":
    main()
