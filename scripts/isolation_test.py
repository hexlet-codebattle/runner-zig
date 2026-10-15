#!/usr/bin/env python3
"""Black-box isolation checks for a running runner container (Linux sandbox).

Each check submits a python solution that probes the sandbox from the inside
and asserts what it may and may not do. Usage:

    isolation_test.py http://localhost:4040

Requires a runner image with python3 (the runner-zig images have it).
"""

import json
import sys
import textwrap
import threading
import urllib.request

BASE = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "http://localhost:4040"
failures = []


def run(code, timeout="10s"):
    body = json.dumps({"lang_slug": "python", "solution_text": textwrap.dedent(code), "timeout": timeout}).encode()
    req = urllib.request.Request(BASE + "/run", body, {"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def probe(code, **kw):
    """Runs `code`, which must print one JSON object as its last stdout line."""
    res = run(code, **kw)
    lines = res["stdout"].strip().splitlines()
    if res["exit_code"] != 0 or not lines:
        raise AssertionError(f"probe failed: {res}")
    return json.loads(lines[-1])


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  -- {detail}"))
    if not cond:
        failures.append(name)


def healthy():
    with urllib.request.urlopen(BASE + "/health", timeout=10) as resp:
        return resp.status == 200


# --- credentials -------------------------------------------------------------
r = probe("""
import os, json
print(json.dumps({"uid": os.getresuid(), "gid": os.getresgid(), "groups": os.getgroups()}))
""")
check("runs as non-root uid", 0 not in r["uid"], r)
check("runs as non-root gid", 0 not in r["gid"], r)
check("no supplementary groups", r["groups"] in ([], [r["gid"][0]]), r)

# --- filesystem --------------------------------------------------------------
r = probe("""
import os, json, errno
def w(p):
    try:
        with open(p, "w") as f: f.write("x")
        return "ok"
    except OSError as e:
        return errno.errorcode.get(e.errno, str(e.errno))
paths = ["/etc/x", "/usr/x", "/var/tmp/x", "/run/x", "/opt/x", "/root/x", "/x", "/runner/x", "/usr/src/app/x", "/app/x",
         "/sandbox/x", "/sandbox/check/x", "/tmp/x", "/dev/shm/x", os.path.expanduser("~/x"), "/dev/null"]
print(json.dumps({p: w(p) for p in paths}))
""")
for p in ["/etc/x", "/usr/x", "/var/tmp/x", "/run/x", "/opt/x", "/root/x", "/x", "/runner/x", "/usr/src/app/x", "/app/x"]:
    check(f"cannot write {p}", r[p] != "ok", r[p])
for p in ["/sandbox/x", "/sandbox/check/x", "/tmp/x", "/dev/shm/x", "/sandbox/x".replace("x", "x"), "/dev/null"]:
    check(f"can write {p}", r[p] == "ok", r[p])

# Nothing written by one run is visible to the next.
run("""
import os
for p in ["/tmp/marker", "/dev/shm/marker", "/sandbox/marker", "/sandbox/check/marker"]:
    open(p, "w").write("x")
""")
r = probe("""
import os, json
print(json.dumps({p: os.path.exists(p) for p in ["/tmp/marker", "/dev/shm/marker", "/sandbox/marker", "/sandbox/check/marker"]}))
""")
for p, seen in r.items():
    check(f"no persistence via {p}", not seen)

r = probe("""
import os, json
print(json.dumps({"dev": sorted(os.listdir("/dev")), "app": os.listdir("/app") if os.path.isdir("/app") else []}))
""")
check("minimal /dev", set(r["dev"]) <= {"null", "zero", "full", "random", "urandom", "fd", "stdin", "stdout", "stderr", "shm"}, r["dev"])
check("/app masked", r["app"] == [], r["app"])

r = probe("""
import os, json, shutil
written = 0
try:
    with open("/sandbox/fill", "wb") as f:
        chunk = b"x" * (1 << 20)
        while written < (8 << 30):
            f.write(chunk); f.flush(); written += len(chunk)
    err = None
except OSError as e:
    err = e.errno
print(json.dumps({"written_mb": written >> 20, "errno": err}))
""", timeout="20s")
check("workspace writes are size-capped", r["errno"] is not None and r["written_mb"] < 4096, r)

# --- processes, ipc, network -------------------------------------------------
r = probe("""
import os, json
print(json.dumps({"pids": [p for p in os.listdir("/proc") if p.isdigit()]}))
""")
check("only own processes visible", len(r["pids"]) <= 4, r)

r = probe("""
import socket, json
res = {}
for host in [("1.1.1.1", 53), ("8.8.8.8", 443)]:
    s = socket.socket(); s.settimeout(2)
    try:
        s.connect(host); res[str(host)] = "connected"
    except OSError as e:
        res[str(host)] = str(e.errno)
print(json.dumps(res))
""")
check("no network", all(v != "connected" for v in r.values()), r)

r = probe("""
import os, json
print(json.dumps({"fds": sorted(int(f) for f in os.listdir("/proc/self/fd"))}))
""")
check("no inherited fds", r["fds"] == [0, 1, 2, 3], r)

r = probe("""
import os, json
print(json.dumps(sorted(os.environ)))
""")
# PWD/SHLVL/OLDPWD/_ come from /bin/sh; LC_CTYPE from Python's own C-locale coercion.
check("env is allowlisted", set(r) <= {"PATH", "LANG", "LC_ALL", "TZ", "HOME", "PWD", "SHLVL", "OLDPWD", "_", "LC_CTYPE"}, r)

# --- syscalls ----------------------------------------------------------------
r = probe("""
import ctypes, os, json, platform
libc = ctypes.CDLL(None, use_errno=True)
nr = {"x86_64": {"clone": 56, "clone3": 435}, "aarch64": {"clone": 220, "clone3": 435}}[platform.machine()]
res = {}
for name, flag in [("newuser", 0x10000000), ("newns", 0x00020000), ("newnet", 0x40000000)]:
    rc = libc.syscall(nr["clone"], flag | 17, 0, 0, 0, 0)
    if rc == 0: os._exit(0)
    res[name] = ctypes.get_errno() if rc < 0 else "created"
    if rc > 0: os.waitpid(rc, 0)
rc = libc.syscall(nr["clone3"], 0, 0)
res["clone3"] = ctypes.get_errno() if rc < 0 else "ok"
pid = os.fork()
if pid == 0: os._exit(0)
os.waitpid(pid, 0); res["fork"] = "ok"
print(json.dumps(res))
""")
check("clone(CLONE_NEWUSER) refused", r["newuser"] == 1, r)
check("clone(CLONE_NEWNS) refused", r["newns"] == 1, r)
check("clone(CLONE_NEWNET) refused", r["newnet"] == 1, r)
check("clone3 returns ENOSYS", r["clone3"] == 38, r)
check("plain fork still works", r["fork"] == "ok", r)

res = run("""
import ctypes
ctypes.CDLL(None).unshare(0x10000000)
print("survived")
""")
check("unshare kills the process", "survived" not in res["stdout"] and res["exit_code"] == 159, res)
res = run("""
import ctypes
ctypes.CDLL(None).mount(b"none", b"/tmp", b"tmpfs", 0, None)
print("survived")
""")
check("mount kills the process", "survived" not in res["stdout"], res)

# --- resources ---------------------------------------------------------------
r = probe("""
import json
print(json.dumps({"memory.max": open("/sys/fs/cgroup/memory.max").read().strip(),
                  "pids.max": open("/sys/fs/cgroup/pids.max").read().strip()}))
""")
check("cgroup view shows the request's own limits", r["memory.max"] not in ("max", "") and r["pids.max"] != "max", r)

res = run("""
blocks = []
while True:
    blocks.append(bytearray(64 << 20))
""", timeout="30s")
check("memory bomb is killed", res["exit_code"] not in (0, None) and "memory limit" in res["stderr"], res)
check("server healthy after memory bomb", healthy())

res = run("""
import os
for _ in range(10000):
    try:
        if os.fork() == 0:
            import time; time.sleep(30)
    except OSError:
        break
print("bounded")
""", timeout="5s")
check("fork bomb is bounded", "bounded" in res["stdout"] or res["exit_code"] is None, res)
check("server healthy after fork bomb", healthy())

# Concurrent runs cannot see each other's writes.
results = {}
def writer(i):
    results[i] = probe(f"""
import os, json, time
open("/tmp/mine", "w").write("{i}")
open("/sandbox/mine", "w").write("{i}")
time.sleep(1)
print(json.dumps({{"tmp": open("/tmp/mine").read(), "ws": open("/sandbox/mine").read(),
                   "others": sorted(os.listdir("/tmp"))}}))
""")
threads = [threading.Thread(target=writer, args=(i,)) for i in range(4)]
for t in threads: t.start()
for t in threads: t.join()
check("concurrent runs are isolated", all(results[i]["tmp"] == str(i) and results[i]["ws"] == str(i) for i in range(4)), results)

r = run("print(2 + 3)")
check("normal run still works", r == {"exit_code": 0, "stdout": "5\n", "stderr": ""}, r)

print()
if failures:
    print(f"{len(failures)} isolation check(s) FAILED: {failures}")
    sys.exit(1)
print("all isolation checks passed")
