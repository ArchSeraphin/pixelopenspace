#!/usr/bin/env python3
"""Hook command used by the spikes harness: appends the hook's stdin to $PIXEL_SPIKE_LOG as one JSON line.

Usage (in a settings file): python3 hooklog.py --tag app

Each line: {"v", "ts_mono_ns", "ts_wall", "event", "tag", "spike_tag", "pid", "ppid_chain", "env", "stdin_len",
"hook"}. `hook` is the JSON Claude Code wrote on stdin, unchanged. Like pixel-hook, this program never writes to
stdout or stderr and always exits 0, so it has no effect on Claude (no decision, no added context).
Python 3.9+, standard library only.
"""

import os
import sys

# Documented variables Claude Code sets for hook commands (hooks.md, env-vars.md), recorded when present.
_ENV_KEYS = (
    "PIXEL_SPIKE_TAG",
    "CLAUDE_PROJECT_DIR",
    "CLAUDECODE",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_EFFORT",
    "CLAUDE_ENV_FILE",
)
_MAX_CHAIN = 12


def _read_stdin():
    chunks = []
    while True:
        chunk = os.read(0, 65536)
        if not chunk:
            break
        chunks.append(chunk)
    return b"".join(chunks)


def _parse_tag(argv):
    for i, arg in enumerate(argv):
        if arg == "--tag" and i + 1 < len(argv):
            return argv[i + 1]
        if arg.startswith("--tag="):
            return arg[len("--tag="):]
    return None


def _process_table():
    """{pid: (ppid, command)} from a single `ps` call (cheaper than one call per ancestor)."""
    import subprocess

    out = subprocess.run(
        ["ps", "-A", "-o", "pid=,ppid=,comm="],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=1.5,
        check=False,
    ).stdout.decode("utf-8", "replace")
    table = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) == 3 else "")
    return table


def _ppid_chain():
    """Ancestors of this process, nearest first: the shell running the hook command, then claude, and so on."""
    pid = os.getppid()
    try:
        table = _process_table()
    except Exception:
        return [{"pid": pid}]
    chain = []
    while pid > 1 and len(chain) < _MAX_CHAIN and pid in table:
        ppid, comm = table[pid]
        chain.append({"pid": pid, "comm": comm})
        pid = ppid
    return chain


def _append(path, line):
    import fcntl

    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        data = line.encode("utf-8")
        while data:
            written = os.write(fd, data)
            data = data[written:]
    finally:
        os.close(fd)


def main(argv):
    import json
    import time

    raw = _read_stdin()  # always to EOF: closing early would give Claude a broken pipe
    ts_mono_ns = time.monotonic_ns()
    ts_wall = time.time()
    path = os.environ.get("PIXEL_SPIKE_LOG")
    if not path:
        return
    try:
        hook = json.loads(raw.decode("utf-8"))
    except Exception:
        hook = {"_unparsed": True, "len": len(raw), "head": raw[:300].decode("utf-8", "replace")}
    record = {
        "v": 1,
        "ts_mono_ns": ts_mono_ns,
        "ts_wall": ts_wall,
        "event": hook.get("hook_event_name") if isinstance(hook, dict) else None,
        "tag": _parse_tag(argv),
        "spike_tag": os.environ.get("PIXEL_SPIKE_TAG"),
        "pid": os.getpid(),
        "ppid_chain": _ppid_chain(),
        "env": {key: os.environ[key] for key in _ENV_KEYS if key in os.environ},
        "stdin_len": len(raw),
        "hook": hook,
    }
    _append(path, json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    try:
        devnull = open(os.devnull, "w")
        sys.stdout = devnull
        sys.stderr = devnull
        main(sys.argv[1:])
    except BaseException:
        pass
    finally:
        os._exit(0)
