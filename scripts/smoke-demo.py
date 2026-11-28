#!/usr/bin/env python3
"""Boot the demo tier from its real compose file and prove what it refuses.

    python3 scripts/smoke-demo.py            # boot, probe, stop
    python3 scripts/smoke-demo.py --keep     # leave it running on :18080

Caddy passes each /api/<service>/* namespace through, so a service's own gating
is the public boundary, and moving an image pin can widen it with no diff here.
This is the check for that: same compose file, same Caddyfile, same read-only
mounts and pins as the host, with three local substitutions (data paths, the
published port, plain HTTP instead of ACME). Each refusal is probed at the edge
and, where a service has its own switch, again behind the edge, so one lock
failing is visible even while the other holds.

Routes that remove things are not called, because a regression would make the
probe itself destructive. scripts/check-cloud-init.sh asserts their edge refusal
statically instead.

Needs docker (with compose) and python3 + pyyaml.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent
HOST = "argus.example.test"
EDGE = 18080
DIRECT = {"lens": 8100, "curator": 8101, "quarry": 8102, "forge": 8103, "proof": 8104, "atlas": 8105}
ENV = {
    "DOMAIN": HOST,
    "ARGUS_BACKEND": "openai-compat",
    "ARGUS_OPENAI_COMPAT_BASE_URL": "http://127.0.0.1:9/v1",
    "ARGUS_OPENAI_COMPAT_MODEL": "placeholder",
    "ARGUS_OPENAI_COMPAT_API_KEY": "smoke-caption-key",
    "ARGUS_CURATOR_SCAN_ROOT": "/srv/argus/samples",
    "ARGUS_CURATOR_EXPORT_ROOT": "",
    "QUARRY_HOME": "/srv/argus/quarry",
    "ARGUS_FORGE_EXPORT_ROOT": "/srv/argus/exports",
    "PROOF_HOME": "/srv/argus/proof",
    "ARGUS_PROOF_REPORTS_DIR": "/srv/argus/proof/reports",
    "ARGUS_PROOF_EXPORTS_DIR": "/srv/argus/proof/exports",
    "ARGUS_PROOF_RUNS_DIR": "/srv/argus/proof/runs",
}
failures = []


def build(work: Path) -> Path:
    doc = yaml.safe_load((REPO / "stack/demo/compose.yaml").read_text())
    del doc["name"]
    services = doc["services"]
    del services["node-exporter"]  # host networking; nothing to prove here
    for name, svc in services.items():
        svc["restart"] = "no"
        svc["volumes"] = [
            v.replace("/srv/argus/", f"{work}/srv/", 1) if v.startswith("/srv/argus/")
            else v.replace("/opt/argus/", f"{work}/", 1)
            for v in svc.get("volumes", [])
        ]
        if name in DIRECT:
            svc["ports"] = [f"127.0.0.1:1{DIRECT[name]}:{DIRECT[name]}"]
    services["caddy"]["ports"] = [f"127.0.0.1:{EDGE}:80"]
    caddyfile = (REPO / "stack/demo/Caddyfile").read_text()
    assert "\n{$DOMAIN} {" in caddyfile
    (work / "Caddyfile").write_text(caddyfile.replace("\n{$DOMAIN} {", "\nhttp://{$DOMAIN} {"))
    for d in ("samples", "quarry", "exports", "proof/reports", "proof/exports", "proof/runs", "atlas", "dem"):
        (work / "srv" / d).mkdir(parents=True)
    for p in (work, *work.rglob("*")):
        p.chmod(0o755 if p.is_dir() else 0o644)
    (work / "compose.yaml").write_text(yaml.safe_dump(doc))
    env = work / "smoke.env"  # compose reads it; no container mounts it, so only we need to
    env.touch(mode=0o600)
    env.write_text("".join(f"{k}={v}\n" for k, v in ENV.items()))
    return work / "compose.yaml"


def call(method, path, body=None, direct=None, origin=f"http://{HOST}"):
    base = f"http://127.0.0.1:1{DIRECT[direct]}" if direct else f"http://127.0.0.1:{EDGE}"
    headers = {"Host": HOST, "Content-Type": "application/json"}
    if origin:
        headers["Origin"] = origin
    req = urllib.request.Request(
        base + path, method=method, headers=headers,
        data=None if method == "GET" else json.dumps(body or {}).encode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode(errors="replace"), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace"), e.headers
    except OSError as e:
        return 0, str(e), {}


def expect(label, got, want, detail=""):
    ok = got in want if isinstance(want, tuple) else got == want
    print(f"  {'ok  ' if ok else 'FAIL'} {label}" + ("" if ok else f": got {got!r}, want {want!r} {detail[:200]}"))
    if not ok:
        failures.append(label)


def refused(method, path, want, body=None, direct=None, contains=None):
    code, text, _ = call(method, path, body, direct)
    label = f"{method} {path}" + (f" (behind the edge, {direct})" if direct else "")
    expect(f"{label} -> {want}", code, want, text)
    if contains and code == want:
        expect(f"{label} says {contains!r}", contains in text, True, text)


def health(svc):
    code, text, _ = call("GET", f"/api/{svc}/health")
    try:
        return code, json.loads(text)
    except ValueError:
        return code, {}


def probe():
    print("routing")
    code, page, headers = call("GET", "/")
    expect("frontend serves through Caddy", code, 200)
    expect("frontend sends its CSP", "script-src" in (headers.get("Content-Security-Policy") or ""), True)
    for svc in DIRECT:
        # The browser's config is rendered into the page; a stale variable name
        # would silently leave it on the localhost default.
        expect(f"page points {svc} at /api/{svc}", f"/api/{svc}" in page, True)
        expect(f"/api/{svc}/health answers", health(svc)[0], 200)

    print("declared posture")
    expect("proof read_only", health("proof")[1].get("read_only"), True)
    expect("forge training disabled", health("forge")[1].get("training"), "disabled")
    expect("quarry fetch off", health("quarry")[1].get("fetch_allowed"), False)
    expect("lens read_only", health("lens")[1].get("read_only"), True)
    expect("lens backends pinned", health("lens")[1].get("allowed_backends"), ["openai-compat"])
    expect("curator export root unset", health("curator")[1].get("export_root", "missing"), None)
    expect("curator move off", health("curator")[1].get("allow_move"), False)
    expect("curator delete off", health("curator")[1].get("delete_any"), False)
    expect("atlas read_only", health("atlas")[1].get("read_only"), True)
    expect("atlas delete off", health("atlas")[1].get("delete_allowed"), False)

    print("refused at the edge")
    for path in ("/api/lens/v1/chat/completions", "/api/lens/immich/pull", "/api/lens/caption/folder",
                 "/api/lens/caption/url", "/api/LENS/v1/chat/completions", "/api/lens//v1/chat/completions",
                 "/api/lens/x/../v1/chat/completions", "/api/lens/%761/chat/completions",
                 "/api/quarry/archives/pd12m/fetch", "/api/forge/run",
                 "/api/proof/run/stream", "/api/proof/score", "/api/atlas/osm", "/api/atlas/bake/stream",
                 "/api/atlas/controls", "/api/atlas/tiles"):
        refused("POST", path, 403, contains="not available on the public demo")
    refused("POST", "/api/lens/admin/unload", 404, contains="admin endpoints are not exposed")

    print("refused by the service itself")
    refused("POST", "/run", 403, direct="forge")
    for method, path in (("POST", "/run/stream"), ("POST", "/score"), ("PUT", "/report/x"),
                         ("POST", "/report/x/hitl"), ("POST", "/report/x/refine")):
        refused(method, path, 403, direct="proof")
    refused("POST", "/osm", 403, direct="atlas")
    refused("POST", "/bake/stream", 403, direct="atlas")
    refused("POST", "/archives/pd12m/fetch", 403, {"archive": "pd12m", "subject": "x"}, direct="quarry")

    print("curator containment")
    for d in ("/etc", "/", "../../etc", "/srv/argus/samples/../../etc"):
        refused("POST", "/api/curator/scan/folder", 400, {"folder": d}, contains="escapes the mount root")
        for route in (f"folders?path={d}", f"thumb?path={d}/hostname", f"image?path={d}/hostname"):
            refused("GET", f"/api/curator/{route}", 400, contains="escapes the mount root")
    code, text, _ = call("POST", "/api/curator/scan/folder", {"folder": "/srv/argus/samples"})
    expect("a scan inside the root works", code, 200, text)
    if code == 200:
        scan = json.loads(text)["scan_id"]
        for dest in ("/tmp/out", "out", "../../tmp/out"):  # noqa: S108 -- a dest curator must refuse, never written
            refused("POST", "/api/curator/export", 400, {"scan_id": scan, "dest": dest})
        refused("POST", "/api/curator/export", (400, 403), {"scan_id": scan, "dest": "out", "mode": "move"})

    print("cross-site writes")
    for svc, path, body in (("curator", "/api/curator/scan/folder", {"folder": "/srv/argus/samples"}),
                            ("lens", "/api/lens/caption", {})):
        code, text, _ = call("POST", path, body, origin="https://evil.example")
        expect(f"{svc} refuses a foreign Origin", code, 403, text)


def secrets(compose):
    print("secrets")
    for svc in ("frontend", "caddy", "curator", "quarry", "forge", "proof", "atlas"):
        ps = compose("ps", "-q", svc, capture_output=True, text=True, check=False)
        ids = ps.stdout.split() if ps.returncode == 0 else []
        # `docker inspect` with no ids is an error, and one missing service must
        # not stop the others being checked.
        expect(f"{svc} has a container to inspect", bool(ids), True, ps.stderr or "")
        if not ids:
            continue
        env = subprocess.run(["docker", "inspect", "-f", "{{json .Config.Env}}", *ids],
                             capture_output=True, text=True, check=False)
        expect(f"{svc} can be inspected", env.returncode, 0, env.stderr or "")
        if env.returncode == 0:
            expect(f"{svc} does not hold the caption key", "smoke-caption-key" in env.stdout, False)


def main():
    keep = "--keep" in sys.argv
    work = Path(tempfile.mkdtemp(prefix="halo-smoke-"))
    try:
        file = build(work)

        def compose(*args, **kw):
            kw.setdefault("check", True)
            return subprocess.run(["docker", "compose", "-p", "halo-smoke", "--env-file", str(work / "smoke.env"),
                                   "-f", str(file), *args], **kw)

        try:
            # Inside the try: an `up` that fails partway has still started some of it.
            compose("up", "-d", "--quiet-pull")
            deadline = time.time() + 180
            while time.time() < deadline:
                if call("GET", "/")[0] == 200 and all(health(s)[0] == 200 for s in DIRECT):
                    break
                time.sleep(3)
            probe()
            secrets(compose)
            if failures:
                compose("ps", "-a")
                compose("logs", "--tail", "30")
        finally:
            if keep:
                print(f"left running on http://127.0.0.1:{EDGE} (Host: {HOST}); project halo-smoke; files in {work}")
            else:
                # down, not stop: the project name is fixed, so anything left
                # (containers, networks, volumes) would be the next run's state.
                # Unchecked, so a failing teardown can't hide why the run failed.
                down = compose("down", "-v", "--remove-orphans", "-t", "3", check=False)
                if down.returncode:
                    print(f"teardown failed ({down.returncode}); run: docker compose -p halo-smoke down -v")
    finally:
        if not keep:
            shutil.rmtree(work, ignore_errors=True)  # smoke.env holds the generated key
    print(f"\n{len(failures)} failure(s)" if failures else "\nall probes passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
