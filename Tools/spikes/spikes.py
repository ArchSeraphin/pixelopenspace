#!/usr/bin/env python3
"""Pixel Open Space: spikes harness for step 2 (docs/PROPOSITION.md, section 5.11).

Drives the real `claude` CLI in a pseudo-terminal, in throwaway folders under $TMPDIR, with the app's hook list
pointed at hooklog.py through `--settings`, and records hook events, terminal output and screen snapshots.
Anonymized results go to Tools/spikes/results/<YYYYMMDD-HHMMSS>/. Start it with run-spikes.sh.

Python 3.9+, standard library only. Single-threaded (select on the PTY), so nothing can hang: every wait has a
timeout, and every scenario has a hard deadline after which its process group is killed.
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True  # never leave __pycache__ next to the results the user commits

import argparse  # noqa: E402
import base64  # noqa: E402
import codecs  # noqa: E402
import datetime  # noqa: E402
import fcntl  # noqa: E402
import getpass  # noqa: E402
import json  # noqa: E402
import math  # noqa: E402
import os  # noqa: E402
import platform  # noqa: E402
import pty  # noqa: E402
import re  # noqa: E402
import select  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import socket  # noqa: E402
import struct  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import termios  # noqa: E402
import threading  # noqa: E402
import time  # noqa: E402
import traceback  # noqa: E402
import uuid  # noqa: E402
from pathlib import Path  # noqa: E402
from typing import Any, Callable, Dict, Iterable, List, NoReturn, Optional, Sequence, Tuple  # noqa: E402

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import vtscreen  # noqa: E402

HARNESS_VERSION = 2

# The app's hook list (PROPOSITION 5.2), in the same order.
APP_HOOK_EVENTS = (
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PostToolBatch",
    "PermissionRequest",
    "PermissionDenied",
    "Notification",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
    "Elicitation",
    "ElicitationResult",
    "PreCompact",
    "PostCompact",
    "CwdChanged",
)
HOOK_TIMEOUT_S = 3
ROWS, COLS = 36, 120
DEFAULT_TIMEOUT_S = 90.0
DEFAULT_MODEL = "haiku"

SHORT_PROMPT = "Réponds juste OK."
# S4: two conversations of one session told apart by their first prompt.
FIRST_TOPIC_PROMPT = "Premier sujet : réponds juste OK."
SECOND_TOPIC_PROMPT = "Second sujet : réponds juste OK."
NEWLINE_PROMPT = "Ligne 1 : réponds juste OK.\nLigne 2 : rien d'autre."
PASTE_LEAD = "Réalise la tâche décrite dans le texte collé ci-dessous."
# Not `ls`: it is one of the built-in read-only commands that never prompt (permissions.md, "Read-only commands").
# `touch` in the throwaway folder does prompt in the default mode, and is harmless.
PERMISSION_PROMPT = "Exécute la commande `touch %s` avec l'outil Bash, puis réponds juste OK."
ASK_PROMPT = (
    "Utilise l'outil AskUserQuestion pour me demander de choisir entre rouge et bleu, puis attends ma réponse."
)
BACKGROUND_PROMPT = (
    "Lance en arrière-plan la commande `sleep 8` (outil Bash avec run_in_background), puis réponds juste OK."
)

# Screen texts (English: Claude Code's TUI is not localized). Kept loose on purpose: wording changes between versions.
TRUST_RE = re.compile(
    r"(?i)project you created or one you trust|yes, i trust this folder|accessing workspace"
    r"|do you trust the files in this folder"
)
# The option of the trust dialog that accepts. Claude Code 2.1.285 lists "No, exit" first, focused and unnumbered:
# a bare Enter (or "1") refuses and quits.
TRUST_CONFIRM_RE = re.compile(r"(?i)^yes,?\s+(?:i trust this folder|proceed)\b")
DIALOG_HINT_RE = re.compile(r"(?i)esc to cancel|enter to (?:confirm|select)|do you want to")
# Startup offer whose focused answer is "Yes, try it": accepting relaunches claude and saves a `tui` setting in
# ~/.claude/settings.json (fullscreen.md). Esc means "Not now" and writes no setting.
FULLSCREEN_OFFER_RE = re.compile(r"(?i)try the new fullscreen renderer")
PASTED_RE = re.compile(r"\[Pasted text")
KEY_DOWN = b"\x1b[B"
KEY_ESCAPE = b"\x1b"
CTRL_U = b"\x15"
# Forces a permission dialog for the `touch` of the permission scenarios, whatever the user's own settings allow
# (an allow rule, or sandboxed Bash auto-allowed): ask rules win over allow rules, and content-scoped ask rules
# still prompt under the sandbox (permissions.md). Passed with --settings, so no file of the user is touched.
SPIKE_ASK_RULES = ("Bash(touch *)",)
# Scenarios that need a permission dialog.
PERMISSION_SCENARIOS = ("S3.e-permission", "S5")

# Variables removed from the environment of `claude`, as the app does (PROPOSITION 5.1), plus terminal
# multiplexer markers and forced sizes that would not exist in the app's embedded terminal.
_DROPPED_ENV = {"CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT", "PWD", "OLDPWD", "SHLVL", "_",
                "COLUMNS", "LINES", "TMUX", "TMUX_PANE", "STY"}
_DROPPED_ENV_PREFIXES = ("TERM_PROGRAM", "ITERM_", "KITTY_", "GHOSTTY_", "DYLD_", "PIXEL_")


def inside_claude_session() -> bool:
    """True when the harness itself runs under Claude Code (its Bash tool sets these, env-vars.md)."""
    return "CLAUDECODE" in os.environ or "CLAUDE_CODE_CHILD_SESSION" in os.environ


class StartupFailure(Exception):
    """`claude` did not reach SessionStart."""


class ScenarioTimeout(Exception):
    """The scenario's hard deadline passed."""


class ScenarioSkipped(Exception):
    """A precondition is missing (for example no Swift toolchain for S9)."""


# ------------------------------------------------------------------------------------------------------------
# Hook settings


def shell_quote(value: str) -> str:
    """POSIX single quoting, the same as the app's HookSettingsBuilder (PROPOSITION 5.2)."""
    return "'" + value.replace("'", "'\\''") + "'"


def hook_command(python: str, hooklog: str, tag: str) -> str:
    return "%s %s --tag %s" % (shell_quote(python), shell_quote(hooklog), shell_quote(tag))


def build_hook_settings(command: str, events: Sequence[str] = APP_HOOK_EVENTS,
                        timeout: int = HOOK_TIMEOUT_S) -> Dict[str, Any]:
    """The app's hook block: every event, matcher omitted (= all), one synchronous `command` hook each."""
    return {
        "hooks": {
            event: [{"hooks": [{"type": "command", "command": command, "timeout": timeout}]}] for event in events
        }
    }


# ------------------------------------------------------------------------------------------------------------
# Anonymization

_EMAIL_PATTERN = r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"
_WORD_BEFORE = r"(?<![A-Za-z0-9_])"
_WORD_AFTER = r"(?![A-Za-z0-9_])"
_PATH_AFTER = r"(?![A-Za-z0-9._-])"


class Anonymizer:
    """Replaces what identifies the user: paths (home, repository, temp folder), e-mail addresses, user name,
    full name and host name. Works on text, bytes (including a stream split in chunks) and decoded JSON."""

    def __init__(self, home: Optional[str] = None, user: Optional[str] = None, full_name: Optional[str] = None,
                 host: Optional[str] = None, paths: Sequence[Tuple[str, str]] = ()) -> None:
        path_rules: List[Tuple[str, str]] = [(p, r) for p, r in paths if p and len(p) > 1]
        if home and len(home) > 1:
            path_rules.append((home, "~"))
        path_rules.sort(key=lambda rule: len(rule[0]), reverse=True)

        rules: List[Tuple[str, str, int]] = []
        for path, replacement in path_rules:
            rules.append((re.escape(path) + _PATH_AFTER, replacement, 0))
        rules.append((_EMAIL_PATTERN, "<email>", 0))
        words: List[Tuple[str, str]] = []
        if full_name and len(full_name.strip()) >= 3:
            words.append((full_name.strip(), "<name>"))
            # Parts of 4+ letters only: shorter ones ("de", "Van") are ordinary words too often.
            words.extend((part, "<name>") for part in re.split(r"[\s,]+", full_name) if len(part) >= 4)
        if user and len(user) >= 3:
            words.append((user, "<user>"))
        if host:
            short = host.split(".")[0]
            words.extend((name, "<host>") for name in {host, short} if len(name) >= 3)
        words.sort(key=lambda rule: len(rule[0]), reverse=True)
        for word, replacement in words:
            rules.append((_WORD_BEFORE + re.escape(word) + _WORD_AFTER, replacement, re.IGNORECASE))

        self._text_rules = [(re.compile(p, f), r) for p, r, f in rules]
        self._byte_rules = [(re.compile(p.encode("utf-8"), f), r.encode("utf-8")) for p, r, f in rules]

    @classmethod
    def for_current_user(cls, paths: Sequence[Tuple[str, str]] = ()) -> "Anonymizer":
        home = os.path.expanduser("~")
        user = None
        full_name = None
        try:
            import pwd

            entry = pwd.getpwuid(os.getuid())
            user = entry.pw_name
            full_name = entry.pw_gecos.split(",")[0] if entry.pw_gecos else None
        except (ImportError, KeyError):
            pass
        user = user or getpass.getuser()
        extra = list(paths)
        real_home = os.path.realpath(home)
        if real_home != home:
            extra.append((real_home, "~"))
        return cls(home=home, user=user, full_name=full_name, host=socket.gethostname(), paths=extra)

    def text(self, value: str) -> str:
        for pattern, replacement in self._text_rules:
            value = pattern.sub(replacement.replace("\\", "\\\\"), value)
        return value

    def data(self, value: bytes) -> bytes:
        for pattern, replacement in self._byte_rules:
            value = pattern.sub(replacement.replace(b"\\", b"\\\\"), value)
        return value

    def json(self, value: Any) -> Any:
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.json(item) for item in value]
        if isinstance(value, tuple):
            return [self.json(item) for item in value]
        if isinstance(value, dict):
            return {self.text(str(key)): self.json(item) for key, item in value.items()}
        return value

    def chunks(self, chunks: Sequence[bytes]) -> List[Tuple[int, bytes]]:
        """Anonymizes a stream cut in chunks. A match that spans a chunk boundary merges those chunks, so no
        fragment of a name survives in either; returns (index of the first original chunk, anonymized bytes)."""
        if not chunks:
            return []
        data = b"".join(chunks)
        boundaries = []
        offset = 0
        for chunk in chunks[:-1]:
            offset += len(chunk)
            boundaries.append(offset)
        spans = [m.span() for pattern, _ in self._byte_rules for m in pattern.finditer(data)]
        removed = {b for b in boundaries for start, end in spans if start < b < end}
        merged: List[Tuple[int, bytes]] = []
        start = 0
        first_index = 0
        for index, boundary in enumerate(boundaries):
            if boundary in removed:
                continue
            merged.append((first_index, data[start:boundary]))
            start = boundary
            first_index = index + 1
        merged.append((first_index, data[start:]))
        return [(index, self.data(chunk)) for index, chunk in merged]


# ------------------------------------------------------------------------------------------------------------
# Small helpers


def mono_ns() -> int:
    return time.monotonic_ns()


def percentiles(values: Sequence[float]) -> Dict[str, Any]:
    """Nearest-rank percentiles, in the unit of `values`, rounded to 0.1."""
    if not values:
        return {"n": 0}
    ordered = sorted(values)

    def rank(q: float) -> float:
        return ordered[max(0, math.ceil(q * len(ordered)) - 1)]

    return {
        "n": len(ordered),
        "min": round(ordered[0], 1),
        "p50": round(rank(0.50), 1),
        "p95": round(rank(0.95), 1),
        "max": round(ordered[-1], 1),
    }


def truncate(value: Any, limit: int) -> str:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def visible(text: str) -> str:
    """Control characters made visible (\\r, \\n, \\x1b, ...); everything else unchanged."""
    out = []
    for ch in text:
        if ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    return "".join(out)


def safe_name(label: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "-", label).strip("-")[:80] or "sans-nom"


def paste_body(size: int = 1200) -> str:
    """A harmless multi-line text of exactly `size` characters, ending with the instruction."""
    ending = "\nFin du texte collé. Réponds juste OK."
    lines = []
    number = 1
    while sum(len(line) + 1 for line in lines) < size:
        lines.append("Ligne %02d du texte collé : contenu de test sans consigne, pour mesurer le collage entre "
                     "crochets." % number)
        number += 1
    body = "\n".join(lines)[: size - len(ending)].rstrip()
    body = body + "." * (size - len(ending) - len(body))
    return body + ending


def run_quiet(argv: Sequence[str], timeout: float = 20.0, cwd: Optional[str] = None,
              env: Optional[Dict[str, str]] = None) -> Tuple[Optional[int], str]:
    """(exit code, stdout + stderr) or (None, reason); never raises."""
    try:
        done = subprocess.run(list(argv), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout, cwd=cwd, env=env, check=False)
        return done.returncode, done.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as error:
        return None, str(error)


def focused_option(lines: Sequence[str]) -> Optional[str]:
    """Text of the dialog line marked with ❯ (borders and a "1." number removed), or None when none is."""
    for line in lines:
        text = line.replace("│", " ").replace("┃", " ").strip()
        if text.startswith("❯"):
            return re.sub(r"^[1-9]\.\s+", "", text[1:].strip())
    return None


def dialog_title(lines: Sequence[str]) -> Optional[str]:
    """The question a dialog asks: the nearest line ending with "?" above its focused option (❯), or above its
    first numbered option when none is focused."""
    cleaned = [line.replace("│", " ").replace("┃", " ").strip() for line in lines]
    anchor = next((i for i, text in enumerate(cleaned) if text.startswith("❯")), None)
    if anchor is None:
        anchor = next((i for i, text in enumerate(cleaned) if re.match(r"^[1-9]\.\s", text)), None)
    for text in reversed(cleaned[:anchor]):
        if text.endswith("?"):
            return text
    return None


def hook_of(event: Dict[str, Any]) -> Dict[str, Any]:
    hook = event.get("hook")
    return hook if isinstance(hook, dict) else {}


def brief(event: Dict[str, Any], t0_ns: int) -> Dict[str, Any]:
    """The fields of an event worth reading in a summary."""
    hook = hook_of(event)
    out: Dict[str, Any] = {
        "event": event.get("event"),
        "t_ms": round((event.get("ts_mono_ns", t0_ns) - t0_ns) / 1e6, 1),
    }
    if event.get("tag") not in (None, "app"):
        out["tag"] = event.get("tag")
    for key in ("source", "reason", "tool_name", "notification_type", "error", "session_id", "agent_type"):
        if key in hook:
            out[key] = hook[key]
    for key in ("prompt", "message", "last_assistant_message"):
        if key in hook:
            out[key] = truncate(hook[key], 120)
    if isinstance(hook.get("tool_input"), dict):
        out["tool_input"] = truncate(hook["tool_input"], 160)
    if "background_tasks" in hook:
        out["background_tasks"] = hook["background_tasks"]
    if "is_interrupt" in hook:
        out["is_interrupt"] = hook["is_interrupt"]
    return out


# ------------------------------------------------------------------------------------------------------------
# Hook event log (written by hooklog.py, read here)


class EventLog:
    """Tails the JSON-lines file hooklog.py appends to."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.events: List[Dict[str, Any]] = []
        self._offset = 0
        self._partial = b""

    def poll(self) -> int:
        try:
            with open(self.path, "rb") as handle:
                handle.seek(self._offset)
                data = handle.read()
        except FileNotFoundError:
            return 0
        self._offset += len(data)
        lines = (self._partial + data).split(b"\n")
        self._partial = lines.pop()
        added = 0
        for line in lines:
            if not line.strip():
                continue
            try:
                record = json.loads(line.decode("utf-8"))
                if not isinstance(record, dict):
                    raise ValueError("not an object")
            except (ValueError, UnicodeDecodeError):
                record = {"event": None, "_bad_line": line[:300].decode("utf-8", "replace")}
            record["_seen_ns"] = mono_ns()
            self.events.append(record)
            added += 1
        return added

    def find(self, names: Iterable[str], start: int = 0,
             predicate: Optional[Callable[[Dict[str, Any]], bool]] = None) -> Optional[int]:
        wanted = {names} if isinstance(names, str) else set(names)
        for index in range(start, len(self.events)):
            event = self.events[index]
            if event.get("event") in wanted and (predicate is None or predicate(event)):
                return index
        return None

    def between(self, start: int, end: Optional[int] = None) -> List[Dict[str, Any]]:
        return self.events[start:end]


# ------------------------------------------------------------------------------------------------------------
# PTY session


class Recorder:
    """Everything that crossed the PTY, with monotonic timestamps."""

    def __init__(self) -> None:
        self.entries: List[Dict[str, Any]] = []

    def add(self, session: str, direction: str, data: bytes, label: Optional[str] = None) -> int:
        stamp = mono_ns()
        self.entries.append({"mono_ns": stamp, "session": session, "dir": direction, "data": data, "label": label})
        return stamp


class PtySession:
    """One child process on a pseudo-terminal, pumped from the harness thread with select (no blocking I/O)."""

    def __init__(self, ctx: "ScenarioContext", label: str, argv: List[str], cwd: Path,
                 env: Dict[str, str]) -> None:
        self.ctx = ctx
        self.label = label
        self.argv = argv
        self.cwd = cwd
        self.env = env
        self.screen = vtscreen.Screen(ROWS, COLS)
        self.pid: Optional[int] = None
        self.fd: Optional[int] = None
        self.eof = False
        self.exited = False
        self.exit_status: Optional[int] = None
        self.started_ns = 0
        self.last_output_ns = 0
        self.launch_index = 0
        self.info: Dict[str, Any] = {}
        self._pending = bytearray()
        self._decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self._tail = bytearray()

    # Lifecycle ---------------------------------------------------------------------------------------------

    def start(self) -> None:
        winsize = struct.pack("HHHH", ROWS, COLS, 0, 0)
        pid, fd = pty.fork()
        if pid == 0:  # child: no Python-level cleanup, exec or die
            try:
                fcntl.ioctl(0, termios.TIOCSWINSZ, winsize)
                os.chdir(str(self.cwd))
                os.execve(self.argv[0], self.argv, self.env)
            except BaseException as error:  # noqa: BLE001
                try:
                    os.write(2, ("exec impossible : %s\r\n" % error).encode("utf-8", "replace"))
                finally:
                    os._exit(127)
        self.pid, self.fd = pid, fd
        try:
            fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)
        except OSError:
            pass
        flags = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        self.started_ns = mono_ns()
        self.last_output_ns = self.started_ns

    def close(self) -> None:
        """Terminates the whole process group (SIGTERM, then SIGKILL), reaps the child, closes the PTY."""
        if self.pid is None:
            return
        if not self.exited:
            self._signal_group(signal.SIGTERM)
            self._wait_exit(3.0)
        if not self.exited:
            self._signal_group(signal.SIGKILL)
            self._wait_exit(3.0)
        self._signal_group(signal.SIGKILL)  # stragglers left in the group
        self._close_fd()

    def hangup(self, timeout: float) -> None:
        """Closes our side of the PTY, as a crashing terminal would: the child gets SIGHUP."""
        self._close_fd()
        self._wait_exit(timeout)

    def _close_fd(self) -> None:
        if self.fd is not None:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None
            self.eof = True

    def _signal_group(self, sig: int) -> None:
        if self.pid is None:
            return
        try:
            os.killpg(self.pid, sig)
        except (ProcessLookupError, PermissionError, OSError):
            pass

    def _check_exit(self) -> None:
        if self.exited or self.pid is None:
            return
        try:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
        except ChildProcessError:
            self.exited = True
            return
        if pid != 0:
            self.exited = True
            self.exit_status = os.waitstatus_to_exitcode(status)

    def _wait_exit(self, timeout: float) -> None:
        end = time.monotonic() + timeout
        while not self.exited and time.monotonic() < end:
            self._step(0.05)

    # I/O ---------------------------------------------------------------------------------------------------

    def _step(self, timeout: float) -> None:
        readers = [self.fd] if self.fd is not None and not self.eof else []
        writers = [self.fd] if self.fd is not None and not self.eof and self._pending else []
        if readers or writers:
            try:
                ready_r, ready_w, _ = select.select(readers, writers, [], max(0.0, timeout))
            except InterruptedError:
                ready_r, ready_w = [], []
            if ready_r:
                self._read_available()
            if ready_w or self._pending:
                self._flush()
        else:
            time.sleep(max(0.0, timeout))
        self.ctx.events.poll()
        self._check_exit()

    def _read_available(self) -> None:
        for _ in range(64):  # bounded, so a chatty child cannot starve the event log
            if self.fd is None:
                return
            try:
                chunk = os.read(self.fd, 65536)
            except BlockingIOError:
                return
            except OSError:  # EIO once the child side is closed (Linux)
                self.eof = True
                return
            if not chunk:
                self.eof = True
                return
            self.ctx.recorder.add(self.label, "out", chunk)
            self.last_output_ns = mono_ns()
            self._tail.extend(chunk)
            del self._tail[:-32768]
            self.screen.feed(self._decoder.decode(chunk))
            for label, reply in self.screen.take_replies():
                self._queue(reply.encode("utf-8"), "réponse du terminal : " + label)

    def _queue(self, data: bytes, label: str) -> None:
        self.ctx.recorder.add(self.label, "in", data, label)
        self._pending.extend(data)

    def _flush(self) -> None:
        if self.fd is None or not self._pending:
            return
        try:
            written = os.write(self.fd, bytes(self._pending))
            del self._pending[:written]
        except BlockingIOError:
            pass
        except OSError:
            self._pending.clear()
            self.eof = True

    # API used by scenarios -------------------------------------------------------------------------------

    def pump(self, timeout: float, until: Optional[Callable[[], bool]] = None) -> bool:
        """Runs I/O for up to `timeout` seconds or until `until()` is true (returned). Enforces the deadline."""
        end = time.monotonic() + max(0.0, timeout)
        while True:
            if until is not None and until():
                return True
            now = time.monotonic()
            if now >= self.ctx.deadline:
                raise ScenarioTimeout()
            if now >= end:
                return False
            self._step(min(0.05, end - now, self.ctx.deadline - now))

    def send(self, data: bytes, label: str) -> int:
        """Writes `data` (fully, without blocking the pump) and returns the monotonic time it was queued."""
        stamp = self.ctx.recorder.add(self.label, "in", data, label)
        self._pending.extend(data)
        self.pump(5.0, until=lambda: not self._pending or self.eof)
        return stamp

    def quiet_for(self) -> float:
        return (mono_ns() - self.last_output_ns) / 1e9

    def wait_quiet(self, quiet: float, limit: float) -> bool:
        """Waits until no output arrived for `quiet` seconds (a TUI that keeps redrawing never gets there)."""
        return self.pump(limit, until=lambda: self.quiet_for() >= quiet or self.exited)

    def wait_redraw(self, since_ns: int, quiet: float = 0.3, limit: float = 1.5) -> bool:
        """After a key sent at `since_ns`: waits for output that follows it, then for `quiet` seconds of silence,
        `limit` seconds at most in all. Without the first wait, an already quiet screen would be read unchanged."""
        end = time.monotonic() + limit
        self.pump(limit, until=lambda: self.last_output_ns > since_ns or self.exited)
        return self.pump(max(0.0, end - time.monotonic()), until=lambda: self.quiet_for() >= quiet or self.exited)

    def recent_text(self) -> str:
        return vtscreen.strip_ansi(bytes(self._tail).decode("utf-8", "replace"))

    def screen_has(self, pattern: "re.Pattern[str]") -> bool:
        return bool(pattern.search(self.screen.text()))

    def wait_for_text(self, pattern: "re.Pattern[str]", timeout: float) -> bool:
        """Waits until `pattern` matches the visible screen or the ANSI-stripped recent output."""
        return self.pump(timeout, until=lambda: self.screen_has(pattern) or bool(pattern.search(self.recent_text())))

    def options(self) -> List[Tuple[str, str]]:
        return vtscreen.option_lines(self.screen.lines())


# ------------------------------------------------------------------------------------------------------------
# Scenarios


class Scenario:
    def __init__(self, sid: str, title: str, func: Callable[["ScenarioContext"], None],
                 timeout: Optional[float] = None, needs_claude: bool = True, optional: bool = False) -> None:
        self.id = sid
        self.title = title
        self.func = func
        self.timeout = timeout
        self.needs_claude = needs_claude
        self.optional = optional


class ScenarioContext:
    """State and helpers of one scenario run: temp folder, event log, PTY sessions, notes."""

    def __init__(self, harness: "Harness", scenario: Scenario) -> None:
        self.h = harness
        self.sc = scenario
        self.tmp = harness.tmp_root / scenario.id
        self.tmp.mkdir(parents=True, exist_ok=True)
        self.events = EventLog(self.tmp / "events.jsonl")
        self.recorder = Recorder()
        self.sessions: List[PtySession] = []
        self.screens: List[Dict[str, Any]] = []
        self.extra_files: Dict[str, str] = {}
        self.t0_ns = mono_ns()
        timeout = scenario.timeout if scenario.timeout is not None else harness.args.timeout
        self.deadline = time.monotonic() + timeout
        self.notes: Dict[str, Any] = {
            "id": scenario.id,
            "title": scenario.title,
            "status": "en cours",
            "timeout_s": timeout,
            "launches": [],
            "timeline": [],
            "answer": {},
        }

    # Notes -------------------------------------------------------------------------------------------------

    def t_ms(self, stamp: Optional[int] = None) -> float:
        return round(((stamp if stamp is not None else mono_ns()) - self.t0_ns) / 1e6, 1)

    def log(self, message: str) -> None:
        self.notes["timeline"].append({"t_ms": self.t_ms(), "msg": message})
        if self.h.args.verbose:
            print("    [%7.1f s] %s" % (self.t_ms() / 1000, message), flush=True)

    def briefs(self, start: int, end: Optional[int] = None) -> List[Dict[str, Any]]:
        return [brief(event, self.t0_ns) for event in self.events.between(start, end)]

    def snapshot(self, session: PtySession, label: str) -> str:
        text = session.screen.text()
        self.screens.append({
            "label": label,
            "session": session.label,
            "t_ms": self.t_ms(),
            "alt_screen": session.screen.alt_active,
            "cursor": [session.screen.cy + 1, session.screen.cx + 1],
            "text": text,
        })
        return text

    # Workspaces and launches ----------------------------------------------------------------------------

    def workspace(self, name: str = "projet") -> Path:
        """A fresh throwaway project: git repository with a.txt ("bonjour") and b.txt, committed (`--worktree` needs
        a commit). The commit uses its own identity and skips hooks and signing: the user's git config is only read."""
        path = self.tmp / name
        path.mkdir(parents=True)
        (path / "a.txt").write_text("bonjour\n", encoding="utf-8")
        (path / "b.txt").write_text("Fichier de test des spikes Pixel Open Space.\n", encoding="utf-8")
        if shutil.which("git"):
            env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
            commit = ["git", "-c", "user.name=spike", "-c", "user.email=spike@example.invalid",
                      "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
                      "commit", "--no-verify", "-qm", "Dossier jetable des spikes"]
            steps = (("git init", ["git", "init", "-q"]), ("git add", ["git", "add", "a.txt", "b.txt"]),
                     ("git commit", commit))
            for step, argv in steps:
                code, output = run_quiet(argv, timeout=15, cwd=str(path), env=env)
                if code != 0:
                    self.log("%s a échoué : %s" % (step, output.strip()))
                    break
        return path

    def launch(self, workspace: Path, args: Sequence[str] = (), positional: Optional[str] = None,
               label: Optional[str] = None, name: bool = True, wait_ready: bool = True) -> PtySession:
        """Starts `claude`, accepts the trust dialog of the throwaway folder if it shows, waits for SessionStart.

        Records for S10 which hooks ran before the dialog appeared and before it was accepted.
        """
        label = label or "lancement-%d" % (len(self.sessions) + 1)
        argv = [self.h.claude, "--settings", str(self.h.settings_path), "--model", self.h.args.model,
                "--permission-mode", "default"]
        if name:
            argv += ["--name", "pos-spike-%s" % safe_name(self.sc.id).lower()]
        argv += list(args)
        if positional is not None:
            argv.append(positional)
        env = self.h.child_env(self.events.path, "%s/%s" % (self.sc.id, label))
        session = PtySession(self, label, argv, workspace, env)
        info: Dict[str, Any] = {"label": label, "argv": argv[1:], "cwd": str(workspace), "trust_dialog": False}
        session.info = info
        self.notes["launches"].append(info)
        self.sessions.append(session)
        session.launch_index = start = len(self.events.events)
        session.start()
        info["t_start_ms"] = self.t_ms(session.started_ns)
        self.log("%s : claude %s" % (label, " ".join(argv[1:])))

        def session_start() -> Optional[int]:
            return self.events.find("SessionStart", start)

        # Phase 1: the trust dialog, or SessionStart followed by a quiet screen without the dialog.
        end = time.monotonic() + 30.0
        trust_seen_ns = None
        while not session.exited and time.monotonic() < end:
            if session.screen_has(TRUST_RE):
                trust_seen_ns = mono_ns()
                break
            if session_start() is not None and session.quiet_for() >= 1.0:
                break
            session.pump(0.1)
        if trust_seen_ns is not None:
            info["trust_dialog"] = True
            info["trust_seen_ms"] = self.t_ms(trust_seen_ns)
            session.wait_quiet(0.3, 2.0)
            self.snapshot(session, "%s-confiance" % label)
            accepted_ns = self.accept_trust(session, label)
            info["trust_accepted_ms"] = self.t_ms(accepted_ns)
            session.pump(6.0, until=lambda: not session.screen_has(TRUST_RE) or session.exited)
            info["trust_dialog_closed"] = not session.screen_has(TRUST_RE)
            self.log("%s : dialogue de confiance accepté" % label)
        else:
            accepted_ns = None

        # Phase 2: SessionStart.
        session.pump(25.0, until=lambda: session_start() is not None or session.exited)
        index = session_start()
        before_dialog = [e for e in self.events.between(start)
                         if trust_seen_ns is not None and e.get("ts_mono_ns", 0) < trust_seen_ns]
        before_accept = [e for e in self.events.between(start)
                         if accepted_ns is not None and e.get("ts_mono_ns", 0) < accepted_ns]
        info["hooks_before_trust_dialog"] = [brief(e, self.t0_ns) for e in before_dialog]
        info["hooks_before_trust_accept"] = [brief(e, self.t0_ns) for e in before_accept]
        if index is None:
            self.startup_failure(session, "echec-demarrage", "pas de SessionStart après le lancement (%s)" % label)
        event = self.events.events[index]
        hook = hook_of(event)
        info["session_start"] = {
            "source": hook.get("source"),
            "session_id": hook.get("session_id"),
            "cwd": hook.get("cwd"),
            "model": hook.get("model"),
            "session_title": hook.get("session_title"),
            "t_ms": self.t_ms(event.get("ts_mono_ns")),
            "keys": sorted(hook.keys()),
        }
        # Phase 3: dialogs shown once the session runs, before anything is typed.
        session.wait_quiet(0.5, 3.0)
        self.dismiss_startup_dialogs(session)
        if wait_ready:
            session.wait_quiet(0.8, 8.0)
            info["ready_ms"] = self.t_ms()
            self.snapshot(session, "%s-pret" % label)
        return session

    def startup_failure(self, session: PtySession, snapshot: str, message: str) -> NoReturn:
        """Records why `session` did not start, then raises StartupFailure."""
        self.snapshot(session, "%s-%s" % (session.label, snapshot))
        session.info.update(startup_failed=True, exit_status=session.exit_status,
                            recent_output=truncate(session.recent_text()[-1500:], 1500))
        raise StartupFailure(message)

    def accept_trust(self, session: PtySession, label: str) -> int:
        """Moves the focus to "Yes, I trust this folder", then presses Enter; returns when Enter was sent.

        Claude Code 2.1.285 lists "No, exit" first, focused, and without numbers, so neither Enter nor "1" accept.
        Enter is only ever pressed on the accepting option: otherwise the launch fails without an answer.
        """
        info = session.info
        focus: List[Optional[str]] = []
        info["trust_focus"] = focus
        moves = 0
        while True:
            focused = focused_option(session.screen.lines())
            focus.append(focused)
            if focused is not None and TRUST_CONFIRM_RE.search(focused):
                break
            if moves >= 3 or session.exited:
                self.startup_failure(session, "confiance-sans-option-oui",
                                     "dialogue de confiance : option « Yes, I trust this folder » introuvable (%s)"
                                     % label)
            sent = session.send(KEY_DOWN, "Flèche bas : option suivante du dialogue de confiance")
            moves += 1
            session.wait_redraw(sent)
        info["trust_moves"] = moves
        return session.send(b"\r", "Entrée : accepter la confiance du dossier jetable")

    def startup_dialog_on_screen(self, session: PtySession) -> bool:
        """A dialog with options: a hint line ("Enter to confirm · Esc to cancel") and a focused or numbered option."""
        if session.screen_has(FULLSCREEN_OFFER_RE):
            return True
        if not session.screen_has(DIALOG_HINT_RE):
            return False
        return bool(session.options()) or bool(focused_option(session.screen.lines()))

    def dismiss_startup_dialogs(self, session: PtySession) -> None:
        """Closes with Esc the dialogs Claude Code opens at startup, before anything is typed: the fullscreen
        renderer offer has "Yes, try it" focused, so the first space or Enter of a prompt would accept it, relaunch
        claude and write a `tui` setting to ~/.claude/settings.json. Esc means "Not now" (or cancel) and writes no
        setting. A dialog that Esc does not close fails the launch: the harness never types into a dialog."""
        dialogs: List[Dict[str, Any]] = session.info.setdefault("startup_dialogs", [])
        for number in range(1, 4):
            if session.exited or not self.startup_dialog_on_screen(session):
                return
            text = self.snapshot(session, "%s-dialogue-demarrage-%d" % (session.label, number))
            lines = session.screen.lines()
            dialogs.append({"t_ms": self.t_ms(), "title": dialog_title(lines), "focused": focused_option(lines),
                            "options": session.options(),
                            "lines": [line.strip() for line in text.split("\n") if line.strip()][-12:]})
            self.log("%s : dialogue au démarrage, fermé par Échap" % session.label)
            session.send(KEY_ESCAPE, "Échap : fermer le dialogue de démarrage")
            session.pump(3.0, until=lambda: not self.startup_dialog_on_screen(session) or session.exited)
            session.wait_quiet(0.5, 3.0)
        if not session.exited and self.startup_dialog_on_screen(session):
            self.startup_failure(session, "dialogue-demarrage-persistant",
                                 "un dialogue de démarrage ne se ferme pas par Échap (%s)" % session.label)

    # Turns -------------------------------------------------------------------------------------------------

    def wait_event(self, session: PtySession, names: Iterable[str], after: int, timeout: float,
                   predicate: Optional[Callable[[Dict[str, Any]], bool]] = None) -> Optional[int]:
        names = list(names)
        session.pump(timeout, until=lambda: self.events.find(names, after, predicate) is not None
                     or session.exited)
        return self.events.find(names, after, predicate)

    def submit(self, session: PtySession, text: str, delay_ms: int = 250, label: str = "prompt",
               snapshots: bool = False, expected: Optional[str] = None) -> Dict[str, Any]:
        """Types `text` in one write, waits `delay_ms`, sends Enter alone, then waits for UserPromptSubmit."""
        result: Dict[str, Any] = {"label": label, "delay_ms": delay_ms, "text_len": len(text)}
        start = len(self.events.events)
        result["event_index"] = start
        if snapshots:
            self.snapshot(session, "%s-avant-saisie" % label)
        session.send(text.encode("utf-8"), "saisie : " + label)
        session.pump(delay_ms / 1000.0)
        if snapshots:
            self.snapshot(session, "%s-brouillon" % label)
        enter_ns = session.send(b"\r", "Entrée")
        index = self.wait_event(session, ["UserPromptSubmit"], start, 10.0)
        result["user_prompt_submit"] = index is not None
        # Without UserPromptSubmit the text may still be in the input box: exit_session must not append to it.
        session.info["input_left"] = index is None
        if index is None:
            self.snapshot(session, "%s-sans-envoi" % label)
            self.log("%s : pas de UserPromptSubmit" % label)
            return result
        event = self.events.events[index]
        prompt = hook_of(event).get("prompt")
        result["prompt"] = prompt
        result["exact"] = prompt == (expected if expected is not None else text)
        result["enter_to_hook_ms"] = round((event.get("ts_mono_ns", enter_ns) - enter_ns) / 1e6, 1)
        self.log("%s : UserPromptSubmit après %.0f ms" % (label, result["enter_to_hook_ms"]))
        if snapshots:
            session.pump(1.0, until=lambda: self.events.find(["Stop", "StopFailure"], start) is not None)
            self.snapshot(session, "%s-en-cours" % label)
        return result

    def wait_turn_end(self, session: PtySession, after: int, timeout: float = 60.0) -> Optional[Dict[str, Any]]:
        index = self.wait_event(session, ["Stop", "StopFailure"], after, timeout)
        if index is None:
            self.log("pas de Stop après %.0f s" % timeout)
            return None
        return self.events.events[index]

    def wait_dialog(self, session: PtySession, baseline: Sequence[Tuple[str, str]],
                    timeout: float = 8.0) -> List[Tuple[str, str]]:
        """Waits for numbered option lines that were not on the screen before (a permission or question dialog)."""
        known = set(baseline)

        def new_options() -> List[Tuple[str, str]]:
            return [option for option in session.options() if option not in known]

        session.pump(timeout, until=lambda: bool(new_options()) or session.exited)
        session.wait_quiet(0.3, 2.0)
        return new_options()

    def exit_session(self, session: PtySession) -> Dict[str, Any]:
        """Leaves with /exit when the input box is showing and empty; otherwise (dialog on screen, or text of a
        prompt that was not submitted: "/exit" would be appended to it and sent as a paid prompt) terminates the
        process."""
        result: Dict[str, Any] = {}
        start = len(self.events.events)
        if not session.exited and not session.eof:
            if session.screen_has(DIALOG_HINT_RE):
                result["method"] = "SIGTERM (dialogue à l'écran)"
            elif session.info.get("input_left"):
                result["method"] = "SIGTERM (texte laissé dans la zone de saisie)"
            else:
                result["method"] = "/exit"
                # Ctrl+U empties the line whatever is left in it (a no-op on an empty prompt).
                session.send(CTRL_U, "Ctrl+U : vider la zone de saisie")
                session.pump(0.2)
                session.send(b"/exit", "saisie : /exit")
                session.pump(0.5)
                session.send(b"\r", "Entrée")
                session.pump(10.0, until=lambda: session.exited)
                if not session.exited:
                    result["method"] = "/exit, puis SIGTERM"
                    self.snapshot(session, "%s-sans-sortie" % session.label)
        session.close()
        end = time.monotonic() + 1.5
        while time.monotonic() < end and self.events.find("SessionEnd", start) is None:
            time.sleep(0.05)
            self.events.poll()
        index = self.events.find("SessionEnd", start)
        result["exit_status"] = session.exit_status
        result["session_end"] = hook_of(self.events.events[index]).get("reason") if index is not None else None
        session.info["exit"] = result
        self.log("%s : fin (%s, SessionEnd=%s)" % (session.label, result.get("method", "déjà terminé"),
                                                   result["session_end"]))
        return result

    def close_all(self) -> None:
        for session in self.sessions:
            try:
                session.close()
            except Exception:  # noqa: BLE001 - cleanup must go on
                pass
            session.info["terminal"] = session.screen.summary()
        self.events.poll()

    # Output ------------------------------------------------------------------------------------------------

    def write_results(self) -> None:
        """Writes events.jsonl, pty.jsonl, transcript.txt, screens/ and notes.json, all anonymized."""
        anon = self.h.anonymizer
        out = self.h.out_root / self.sc.id
        out.mkdir(parents=True, exist_ok=True)

        with open(out / "events.jsonl", "w", encoding="utf-8") as handle:
            for event in self.events.events:
                record = {key: value for key, value in event.items() if key != "_seen_ns"}
                record["t_ms"] = self.t_ms(event.get("ts_mono_ns", self.t0_ns))
                handle.write(json.dumps(anon.json(record), ensure_ascii=False) + "\n")

        self._write_pty(out / "pty.jsonl", out / "transcript.txt")

        if self.screens:
            (out / "screens").mkdir(exist_ok=True)
            for number, screen in enumerate(self.screens, 1):
                header = "# %s · session %s · t=%.1f s · curseur ligne %d col %d%s\n" % (
                    screen["label"], screen["session"], screen["t_ms"] / 1000, screen["cursor"][0],
                    screen["cursor"][1], " · écran alternatif" if screen["alt_screen"] else "")
                name = "%02d-%s.txt" % (number, safe_name(screen["label"]))
                (out / "screens" / name).write_text(anon.text(header + screen["text"] + "\n"), encoding="utf-8")
                screen["file"] = "screens/" + name

        for name, content in self.extra_files.items():
            (out / name).write_text(anon.text(content), encoding="utf-8")

        notes = dict(self.notes)
        notes["screens"] = [{k: v for k, v in s.items() if k != "text"} for s in self.screens]
        (out / "notes.json").write_text(json.dumps(anon.json(notes), ensure_ascii=False, indent=2) + "\n",
                                        encoding="utf-8")

    def _write_pty(self, jsonl_path: Path, transcript_path: Path) -> None:
        anon = self.h.anonymizer
        entries = self.recorder.entries
        # Output is anonymized per session as one stream (names may be cut between two reads).
        replaced: Dict[int, bytes] = {}
        dropped: set = set()
        for session in {entry["session"] for entry in entries}:
            indexes = [i for i, e in enumerate(entries) if e["session"] == session and e["dir"] == "out"]
            merged = anon.chunks([entries[i]["data"] for i in indexes])
            kept = {indexes[first] for first, _ in merged}
            for first, data in merged:
                replaced[indexes[first]] = data
            dropped.update(i for i in indexes if i not in kept)
        with open(jsonl_path, "w", encoding="utf-8") as handle:
            for index, entry in enumerate(entries):
                if index in dropped:
                    continue
                data = replaced.get(index, anon.data(entry["data"]))
                record: Dict[str, Any] = {
                    "t_ms": self.t_ms(entry["mono_ns"]),
                    "mono_ns": entry["mono_ns"],
                    "session": entry["session"],
                    "dir": entry["dir"],
                    "b64": base64.b64encode(data).decode("ascii"),
                }
                if entry["label"]:
                    record["label"] = anon.text(entry["label"])
                if entry["dir"] == "in":
                    record["text"] = data.decode("utf-8", "replace")
                handle.write(json.dumps(record, ensure_ascii=False) + "\n")

        def plain(output: bytearray) -> str:
            return vtscreen.strip_ansi(bytes(output).decode("utf-8", "replace"))

        parts: List[str] = []
        for session in self.sessions:
            parts.append("\n===== %s : claude %s\n" % (session.label, " ".join(session.argv[1:])))
            output = bytearray()
            for index, entry in enumerate(entries):
                if entry["session"] != session.label or index in dropped:
                    continue
                data = replaced[index] if index in replaced else entry["data"]
                if entry["dir"] == "out":
                    output.extend(data)
                elif not (entry["label"] or "").startswith("réponse du terminal"):
                    parts.append(plain(output))
                    output = bytearray()
                    parts.append("\n⟦%+.3f s · envoi · %s : %s⟧\n" % (
                        self.t_ms(entry["mono_ns"]) / 1000, entry["label"],
                        visible(truncate(data.decode("utf-8", "replace"), 100))))
            parts.append(plain(output))
        transcript_path.write_text(anon.text("".join(parts)), encoding="utf-8")


def _answer(ctx: ScenarioContext) -> Dict[str, Any]:
    return ctx.notes["answer"]


def scenario_s1(ctx: ScenarioContext) -> None:
    """S1: do hooks passed with --settings add to the project's .claude/settings.local.json hooks?"""
    workspace = ctx.workspace()
    local = build_hook_settings(ctx.h.hook_command("project-local"), events=("SessionStart", "UserPromptSubmit"))
    (workspace / ".claude").mkdir()
    (workspace / ".claude" / "settings.local.json").write_text(json.dumps(local, indent=2) + "\n",
                                                                encoding="utf-8")
    session = ctx.launch(workspace)
    turn = ctx.submit(session, SHORT_PROMPT)
    _answer(ctx)["turn"] = turn
    if turn["user_prompt_submit"]:
        ctx.wait_turn_end(session, turn["event_index"])
    ctx.exit_session(session)
    tags = {}
    for name in ("SessionStart", "UserPromptSubmit"):
        tags[name] = sorted({str(e.get("tag")) for e in ctx.events.events if e.get("event") == name})
    both = all({"app", "project-local"} <= set(found) for found in tags.values())
    _answer(ctx).update({"tags": tags, "merged": both})


def scenario_s2(ctx: ScenarioContext) -> None:
    """S2: is SessionStart.session_id the id passed with --session-id? Bonus: SessionEnd when the PTY closes."""
    workspace = ctx.workspace()
    wanted = str(uuid.uuid4())
    session = ctx.launch(workspace, args=["--session-id", wanted])
    received = session.info["session_start"]["session_id"]
    _answer(ctx).update({"requested": wanted, "received": received, "equal": received == wanted,
                         "source": session.info["session_start"]["source"]})
    start = len(ctx.events.events)
    ctx.log("fermeture du PTY (SIGHUP)")
    session.hangup(6.0)
    end = time.monotonic() + 1.5
    while time.monotonic() < end:
        time.sleep(0.05)
        ctx.events.poll()
    index = ctx.events.find("SessionEnd", start)
    _answer(ctx)["hangup"] = {
        "exited": session.exited,
        "exit_status": session.exit_status,
        "session_end_reason": hook_of(ctx.events.events[index]).get("reason") if index is not None else None,
    }


def make_delay_scenario(delay_ms: int) -> Callable[[ScenarioContext], None]:
    def run(ctx: ScenarioContext) -> None:
        """S3 (a): typed text, then Enter alone after `delay_ms`: is the prompt submitted, and intact?"""
        workspace = ctx.workspace()
        session = ctx.launch(workspace)
        turn = ctx.submit(session, SHORT_PROMPT, delay_ms=delay_ms, snapshots=delay_ms >= 250)
        _answer(ctx).update(turn)
        if turn["user_prompt_submit"]:
            _answer(ctx)["stop"] = ctx.wait_turn_end(session, turn["event_index"]) is not None
        ctx.exit_session(session)

    return run


def scenario_s3_newline(ctx: ScenarioContext) -> None:
    """S3 (b): does a raw LF inside typed text become a line break of the prompt?"""
    workspace = ctx.workspace()
    session = ctx.launch(workspace)
    turn = ctx.submit(session, NEWLINE_PROMPT, snapshots=True, label="deux-lignes")
    prompt = turn.get("prompt")
    turn["contains_newline"] = isinstance(prompt, str) and "\n" in prompt
    _answer(ctx).update(turn)
    if turn["user_prompt_submit"]:
        ctx.wait_turn_end(session, turn["event_index"])
    ctx.exit_session(session)


def scenario_s3_paste(ctx: ScenarioContext) -> None:
    """S3 (c): typed lead sentence + bracketed paste of a long text, then Enter after 250 ms."""
    workspace = ctx.workspace()
    session = ctx.launch(workspace)
    body = paste_body(1200)
    answer = _answer(ctx)
    answer["body_len"] = len(body)
    answer["bracketed_paste_on_before_paste"] = session.screen.mode(2004)
    answer["esc_2004h_seen"] = "?2004h" in session.screen.private_modes_seen
    start = len(ctx.events.events)
    ctx.snapshot(session, "avant-saisie")
    session.send(PASTE_LEAD.encode("utf-8"), "saisie : amorce")
    session.pump(0.15)
    if not session.screen.mode(2004):
        answer["paste_sent"] = False
        ctx.log("collage entre crochets inactif : collage non tenté (comme le ferait l'app)")
        session.info["input_left"] = True  # the lead sentence
        ctx.exit_session(session)
        return
    session.send(b"\x1b[200~" + body.encode("utf-8") + b"\x1b[201~", "collage entre crochets (%d car.)" % len(body))
    answer["paste_sent"] = True
    pasted_at = time.monotonic()
    answer["pasted_placeholder_on_screen"] = session.wait_for_text(PASTED_RE, 0.25)
    session.pump(max(0.0, 0.25 - (time.monotonic() - pasted_at)))
    ctx.snapshot(session, "apres-collage")
    enter_ns = session.send(b"\r", "Entrée")
    index = ctx.wait_event(session, ["UserPromptSubmit"], start, 10.0)
    answer["user_prompt_submit"] = index is not None
    session.info["input_left"] = index is None
    if index is not None:
        event = ctx.events.events[index]
        prompt = hook_of(event).get("prompt") or ""
        squash = lambda value: re.sub(r"\s+", " ", value).strip()  # noqa: E731
        answer.update({
            "enter_to_hook_ms": round((event.get("ts_mono_ns", enter_ns) - enter_ns) / 1e6, 1),
            "prompt_len": len(prompt),
            "prompt_head": truncate(prompt, 160),
            "prompt_tail": prompt[-120:],
            "prompt_lines": prompt.count("\n") + 1,
            "starts_with_lead": prompt.startswith(PASTE_LEAD),
            "contains_body_exactly": body in prompt,
            "contains_body_whitespace_insensitive": squash(body) in squash(prompt),
            "contains_placeholder": bool(PASTED_RE.search(prompt)),
        })
        ctx.wait_turn_end(session, start)
    else:
        ctx.snapshot(session, "sans-envoi")
    ctx.exit_session(session)


def scenario_s3_positional(ctx: ScenarioContext) -> None:
    """S3 (d): does UserPromptSubmit fire for the positional prompt of `claude … "prompt"`?"""
    workspace = ctx.workspace()
    session = ctx.launch(workspace, positional=SHORT_PROMPT, wait_ready=False)
    start = session.launch_index
    index = ctx.wait_event(session, ["UserPromptSubmit"], start, 20.0)
    answer = _answer(ctx)
    answer["user_prompt_submit"] = index is not None
    if index is not None:
        event = ctx.events.events[index]
        answer["prompt"] = hook_of(event).get("prompt")
        answer["exact"] = answer["prompt"] == SHORT_PROMPT
        answer["after_session_start_ms"] = round(ctx.t_ms(event.get("ts_mono_ns"))
                                                 - session.info["session_start"]["t_ms"], 1)
    answer["stop"] = ctx.wait_turn_end(session, start) is not None
    session.wait_quiet(0.8, 5.0)
    ctx.exit_session(session)


def _answer_permission(ctx: ScenarioContext, session: PtySession, key: bytes, key_label: str,
                       baseline: Sequence[Tuple[str, str]]) -> Dict[str, Any]:
    """Waits for the dialog of a PermissionRequest already received, captures it, presses `key`."""
    result: Dict[str, Any] = {}
    options = ctx.wait_dialog(session, baseline)
    result["options"] = options
    result["screen"] = ctx.snapshot(session, "dialogue-permission")
    after = len(ctx.events.events)
    result["event_index_after_key"] = after
    result["kitty_flags"] = session.screen.kitty_flags
    result["key_ns"] = session.send(key, key_label)
    return result


def scenario_s3_permission(ctx: ScenarioContext) -> None:
    """S3 (e): answer a permission dialog with "1", then check that a next prompt goes through after Stop."""
    workspace = ctx.workspace()
    session = ctx.launch(workspace)
    answer = _answer(ctx)
    baseline = session.options()
    turn = ctx.submit(session, PERMISSION_PROMPT % "spike-permission.txt", label="permission")
    answer["turn"] = turn
    index = ctx.wait_event(session, ["PermissionRequest", "Stop", "StopFailure"], turn["event_index"], 45.0)
    event = ctx.events.events[index] if index is not None else None
    answer["permission_request"] = bool(event and event.get("event") == "PermissionRequest")
    if not answer["permission_request"]:
        answer["events"] = ctx.briefs(turn["event_index"])
        ctx.snapshot(session, "sans-permission")
        ctx.exit_session(session)
        return
    assert event is not None
    answer["permission_payload_keys"] = sorted(hook_of(event).keys())
    answer["permission_tool"] = hook_of(event).get("tool_name")
    answer["permission_tool_input"] = hook_of(event).get("tool_input")
    step = _answer_permission(ctx, session, b"1", "touche 1", baseline)
    answer["dialog_options"] = step["options"]
    answer["kitty_flags_at_key"] = step["kitty_flags"]
    after = step["event_index_after_key"]
    done = ctx.wait_event(session, ["PostToolUse", "PostToolUseFailure"], after, 6.0)
    answer["digit_alone_answers"] = done is not None
    if done is None and session.options() and set(session.options()) & set(step["options"]):
        ctx.log("« 1 » seul n'a pas suffi : envoi de Entrée")
        session.send(b"\r", "Entrée (confirmation de l'option 1)")
        done = ctx.wait_event(session, ["PostToolUse", "PostToolUseFailure"], after, 6.0)
        answer["digit_then_enter_answers"] = done is not None
    stop = ctx.wait_turn_end(session, after)
    answer["events_after_key"] = ctx.briefs(after)
    answer["file_created"] = (workspace / "spike-permission.txt").exists()
    answer["stop"] = stop is not None
    if stop is None:
        ctx.exit_session(session)
        return
    stop_ns = stop.get("ts_mono_ns", mono_ns())
    session.wait_quiet(0.5, 5.0)
    answer["stop_to_quiet_ms"] = round((session.last_output_ns - stop_ns) / 1e6, 1)
    ctx.snapshot(session, "saisie-apres-stop")
    chain = ctx.submit(session, SHORT_PROMPT, label="enchainement")
    answer["chain"] = chain
    if chain["user_prompt_submit"]:
        answer["chain_stop"] = ctx.wait_turn_end(session, chain["event_index"]) is not None
    ctx.exit_session(session)


def _slash(ctx: ScenarioContext, session: PtySession, command: str) -> int:
    start = len(ctx.events.events)
    session.send(command.encode("utf-8"), "saisie : " + command)
    session.pump(0.5)
    session.send(b"\r", "Entrée")
    return start


def scenario_s4(ctx: ScenarioContext) -> None:
    """S4: session ids across /clear, /compact, /resume inside the session, --resume and --resume --fork-session;
    SessionStart.cwd with --worktree (PROPOSITION 5.11)."""
    workspace = ctx.workspace()
    answer = _answer(ctx)
    steps: List[Dict[str, Any]] = []
    answer["steps"] = steps

    def record(step: str, start: int) -> None:
        for event in ctx.events.between(start):
            if event.get("event") in ("SessionStart", "SessionEnd", "PreCompact", "PostCompact", "CwdChanged"):
                hook = hook_of(event)
                steps.append({"step": step, "event": event.get("event"),
                              "detail": hook.get("source") or hook.get("reason") or hook.get("trigger")
                              or hook.get("new_cwd"),
                              "session_id": hook.get("session_id"), "cwd": hook.get("cwd")})

    def settle(start: int, names: Sequence[str], timeout: float, what: str) -> None:
        if ctx.wait_event(session, names, start, timeout) is None:
            ctx.log("%s : aucun %s en %.0f s" % (what, "/".join(names), timeout))
        session.wait_quiet(0.8, 6.0)

    first_id = str(uuid.uuid4())
    answer["requested_id"] = first_id
    session = ctx.launch(workspace, args=["--session-id", first_id], label="nouvelle-session")
    # launch() names the session: /resume <name> finds this first conversation again.
    first_name = "pos-spike-%s" % safe_name(ctx.sc.id).lower()
    record("lancement --session-id", session.launch_index)
    turn = ctx.submit(session, FIRST_TOPIC_PROMPT, label="tour-1")
    if turn["user_prompt_submit"]:
        ctx.wait_turn_end(session, turn["event_index"])
    session.wait_quiet(0.5, 4.0)

    start = _slash(ctx, session, "/clear")
    settle(start, ["SessionStart"], 15.0, "/clear")
    record("/clear", start)
    # Whether or not /clear carries the name over, only the first conversation keeps it afterwards.
    start = _slash(ctx, session, "/rename %s-apres-clear" % first_name)
    session.wait_quiet(0.8, 5.0)
    record("/rename", start)

    turn = ctx.submit(session, SECOND_TOPIC_PROMPT, label="tour-2")
    if turn["user_prompt_submit"]:
        ctx.wait_turn_end(session, turn["event_index"])
    session.wait_quiet(0.5, 4.0)

    start = _slash(ctx, session, "/compact")
    if ctx.wait_event(session, ["PreCompact", "SessionStart"], start, 20.0) is not None:
        ctx.wait_event(session, ["SessionStart"], start, 90.0)
        ctx.wait_event(session, ["PostCompact"], start, 5.0)
    else:
        ctx.log("/compact : aucun PreCompact en 20 s")
    session.wait_quiet(1.0, 8.0)
    ctx.snapshot(session, "apres-compact")
    record("/compact", start)

    # /resume inside the session: the picker is captured and closed, then the first conversation is resumed by
    # its name (a row of the picker cannot be told apart reliably: names, titles and prompts all look alike).
    start = _slash(ctx, session, "/resume")
    session.wait_quiet(0.8, 6.0)
    answer["resume_picker"] = {"focused": focused_option(session.screen.lines()), "options": session.options()}
    ctx.snapshot(session, "selecteur-resume")
    session.send(KEY_ESCAPE, "Échap : fermer le sélecteur de sessions")
    session.wait_quiet(0.8, 4.0)
    record("/resume (sélecteur, fermé)", start)
    start = _slash(ctx, session, "/resume %s" % first_name)
    settle(start, ["SessionStart"], 20.0, "/resume %s" % first_name)
    ctx.snapshot(session, "apres-resume")
    record("/resume <nom>", start)

    start = len(ctx.events.events)
    ctx.exit_session(session)
    record("/exit", start)

    ids = [s["session_id"] for s in steps if s["event"] == "SessionStart" and s["session_id"]]
    last_id = ids[-1] if ids else first_id
    answer["resume_id"] = last_id

    resumed = ctx.launch(workspace, args=["--resume", last_id], label="reprise", name=False)
    record("--resume", resumed.launch_index)
    start = len(ctx.events.events)
    ctx.exit_session(resumed)
    record("/exit (reprise)", start)

    forked = ctx.launch(workspace, args=["--resume", last_id, "--fork-session"], label="fork", name=False)
    record("--resume --fork-session", forked.launch_index)
    start = len(ctx.events.events)
    ctx.exit_session(forked)
    record("/exit (fork)", start)

    # --worktree: in which folder do the hooks run, and does CwdChanged fire? (The folder of --resume, 5.1.)
    isolated = ctx.launch(workspace, args=["--worktree", "spike-s4"], label="worktree", name=False)
    record("--worktree", isolated.launch_index)
    start = len(ctx.events.events)
    ctx.exit_session(isolated)
    record("/exit (worktree)", start)

    def starts(step: str) -> List[Dict[str, Any]]:
        return [s for s in steps if s["step"] == step and s["event"] == "SessionStart"]

    first = starts("lancement --session-id")
    clear = starts("/clear")
    compact = starts("/compact")
    in_session = starts("/resume <nom>")
    resume = starts("--resume")
    fork = starts("--resume --fork-session")
    worktree = starts("--worktree")
    before_clear = first[-1]["session_id"] if first else None
    before_compact = clear[-1]["session_id"] if clear else before_clear
    worktree_cwd = worktree[-1]["cwd"] if worktree else None
    answer["worktree"] = {
        "workspace": str(workspace),
        "session_start_cwd": worktree_cwd,
        "cwd_changed": [s["detail"] for s in steps if s["step"] in ("--worktree", "/exit (worktree)")
                        and s["event"] == "CwdChanged"],
    }
    answer["derived"] = {
        "startup_id_is_requested": bool(first) and first[0]["session_id"] == first_id,
        "clear_changes_id": bool(clear) and clear[-1]["session_id"] != before_clear,
        "clear_source": clear[-1]["detail"] if clear else None,
        "compact_keeps_id": bool(compact) and compact[-1]["session_id"] == before_compact,
        "compact_source": compact[-1]["detail"] if compact else None,
        "resume_in_session_returns_to_first_id": bool(in_session) and in_session[-1]["session_id"] == first_id,
        "resume_in_session_source": in_session[-1]["detail"] if in_session else None,
        "resume_keeps_id": bool(resume) and resume[-1]["session_id"] == last_id,
        "resume_source": resume[-1]["detail"] if resume else None,
        "fork_new_id": bool(fork) and fork[-1]["session_id"] != last_id,
        "fork_source": fork[-1]["detail"] if fork else None,
        "worktree_cwd_is_a_worktree": isinstance(worktree_cwd, str) and "/.claude/worktrees/" in worktree_cwd,
    }


def scenario_s5(ctx: ScenarioContext) -> None:
    """S5: refuse a permission with Esc; which events follow?"""
    workspace = ctx.workspace()
    session = ctx.launch(workspace)
    answer = _answer(ctx)
    baseline = session.options()
    turn = ctx.submit(session, PERMISSION_PROMPT % "spike-refus.txt", label="permission")
    index = ctx.wait_event(session, ["PermissionRequest", "Stop", "StopFailure"], turn["event_index"], 45.0)
    event = ctx.events.events[index] if index is not None else None
    answer["permission_request"] = bool(event and event.get("event") == "PermissionRequest")
    if not answer["permission_request"]:
        answer["events"] = ctx.briefs(turn["event_index"])
        ctx.exit_session(session)
        return
    assert event is not None
    answer["permission_payload"] = hook_of(event)
    step = _answer_permission(ctx, session, b"\x1b", "Échap", baseline)
    answer["dialog_options"] = step["options"]
    answer["kitty_flags_at_escape"] = step["kitty_flags"]
    after = step["event_index_after_key"]
    stop_seen: Dict[str, float] = {}

    def settled() -> bool:
        if "t" not in stop_seen and ctx.events.find(["Stop", "StopFailure"], after) is not None:
            stop_seen["t"] = time.monotonic()
        return "t" in stop_seen and time.monotonic() - stop_seen["t"] > 2.0

    session.pump(10.0, until=settled)
    ctx.snapshot(session, "apres-echap")
    events = ctx.events.between(after)
    answer["events_after_escape"] = [brief(e, step["key_ns"]) for e in events]
    names = [e.get("event") for e in events]
    answer["fired"] = {name: name in names for name in
                       ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch", "PermissionDenied",
                        "Stop", "StopFailure", "Notification", "UserPromptSubmit")}
    failure = ctx.events.find("PostToolUseFailure", after)
    if failure is not None:
        answer["post_tool_use_failure"] = hook_of(ctx.events.events[failure])
    answer["dialog_still_visible"] = bool(set(session.options()) & set(step["options"]))
    answer["file_created"] = (workspace / "spike-refus.txt").exists()
    ctx.exit_session(session)


def scenario_s7(ctx: ScenarioContext) -> None:
    """S7: capture the AskUserQuestion dialog, then Esc (the permission dialog is captured by S3 (e) and S5)."""
    workspace = ctx.workspace()
    session = ctx.launch(workspace)
    answer = _answer(ctx)
    baseline = session.options()
    turn = ctx.submit(session, ASK_PROMPT, label="question")
    start = turn["event_index"]

    def is_question(event: Dict[str, Any]) -> bool:
        return event.get("event") == "Stop" or hook_of(event).get("tool_name") == "AskUserQuestion"

    index = ctx.wait_event(session, ["PreToolUse", "PermissionRequest", "Stop", "StopFailure"], start, 60.0,
                           predicate=is_question)
    event = ctx.events.events[index] if index is not None else None
    answer["ask_user_question"] = bool(event and hook_of(event).get("tool_name") == "AskUserQuestion")
    if not answer["ask_user_question"]:
        answer["events"] = ctx.briefs(start)
        ctx.snapshot(session, "sans-question")
        ctx.exit_session(session)
        return
    assert event is not None
    answer["tool_input"] = hook_of(event).get("tool_input")
    answer["first_event"] = event.get("event")
    options = ctx.wait_dialog(session, baseline, timeout=10.0)
    session.wait_quiet(0.4, 3.0)
    answer["options"] = options
    answer["screen_lines"] = ctx.snapshot(session, "dialogue-question").split("\n")
    answer["events_until_dialog"] = ctx.briefs(start)
    after = len(ctx.events.events)
    answer["kitty_flags_at_escape"] = session.screen.kitty_flags
    key_ns = session.send(b"\x1b", "Échap")
    session.pump(8.0, until=lambda: ctx.events.find(["Stop", "StopFailure"], after) is not None)
    session.pump(1.0)
    ctx.snapshot(session, "apres-echap")
    answer["events_after_escape"] = [brief(e, key_ns) for e in ctx.events.between(after)]
    ctx.exit_session(session)


def scenario_s3b(ctx: ScenarioContext) -> None:
    """S3b (minimal): a background shell task; what does Stop carry, and what happens when the task ends?"""
    workspace = ctx.workspace()
    session = ctx.launch(workspace)
    answer = _answer(ctx)
    baseline = session.options()
    turn = ctx.submit(session, BACKGROUND_PROMPT, label="tache-de-fond")
    start = turn["event_index"]
    permissions = 0
    cursor = start
    stop_index: Optional[int] = None
    while stop_index is None and permissions < 3:
        index = ctx.wait_event(session, ["PermissionRequest", "Stop", "StopFailure"], cursor, 60.0)
        if index is None:
            break
        if ctx.events.events[index].get("event") == "PermissionRequest":
            permissions += 1
            step = _answer_permission(ctx, session, b"1", "touche 1", baseline)
            done = ctx.wait_event(session, ["PostToolUse", "PostToolUseFailure"], step["event_index_after_key"], 6.0)
            if done is None and set(session.options()) & set(step["options"]):
                session.send(b"\r", "Entrée (confirmation de l'option 1)")
            cursor = index + 1
        else:
            stop_index = index
    answer["permissions_answered"] = permissions
    if stop_index is None:
        answer["events"] = ctx.briefs(start)
        ctx.exit_session(session)
        return
    stop = hook_of(ctx.events.events[stop_index])
    answer["stop_background_tasks"] = stop.get("background_tasks")
    answer["stop_session_crons"] = stop.get("session_crons")
    answer["stop_keys"] = sorted(stop.keys())
    after = stop_index + 1
    stop_ns = ctx.events.events[stop_index].get("ts_mono_ns", mono_ns())
    second: Dict[str, float] = {}

    def settled() -> bool:
        if ctx.events.find(["Stop", "StopFailure"], after) is not None:
            second.setdefault("t", time.monotonic())
        return "t" in second and time.monotonic() - second["t"] > 2.0

    session.pump(25.0, until=settled)
    ctx.snapshot(session, "fin-observation")
    events = ctx.events.between(after)
    answer["events_after_first_stop"] = [brief(e, stop_ns) for e in events]
    answer["second_turn_user_prompt_submit"] = any(e.get("event") == "UserPromptSubmit" for e in events)
    answer["second_stop"] = any(e.get("event") in ("Stop", "StopFailure") for e in events)
    ctx.exit_session(session)


# S9 -----------------------------------------------------------------------------------------------------


class _LineListener:
    """Unix-socket server that timestamps each line it receives (one connection per message, like the app)."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(64)
        self.server.settimeout(0.2)
        self.received: List[Tuple[int, bytes]] = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with conn:
                conn.settimeout(2.0)
                data = b""
                try:
                    while not data.endswith(b"\n"):
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        data += chunk
                except OSError:
                    pass
                with self._lock:
                    self.received.append((mono_ns(), data))

    def count(self) -> int:
        with self._lock:
            return len(self.received)

    def get(self, index: int) -> Tuple[int, bytes]:
        with self._lock:
            return self.received[index]

    def close(self) -> None:
        self._stop.set()
        try:
            self.server.close()
        except OSError:
            pass
        self._thread.join(2.0)


def _spawn_ms(argv: Sequence[str], payload: bytes, env: Dict[str, str]) -> Tuple[float, int, bytes]:
    """(wall time until exit in ms, exit code, stdout + stderr) of one run."""
    start = mono_ns()
    done = subprocess.run(list(argv), input=payload, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          env=env, timeout=10, check=False)
    return (mono_ns() - start) / 1e6, done.returncode, done.stdout


def scenario_s9(ctx: ScenarioContext) -> None:
    """S9: latency of pixel-hook (release build) delivering to a Unix socket, p50/p95 over 50 runs."""
    answer = _answer(ctx)
    binary = ctx.h.args.pixel_hook
    if binary:
        answer["build"] = "binaire fourni (--pixel-hook)"
    else:
        swift = shutil.which("swift")
        if swift is None:
            raise ScenarioSkipped("swift introuvable : S9 ignoré (ou passe --pixel-hook CHEMIN)")
        package = REPO_ROOT / "Core"
        scratch = ctx.tmp / "build"
        ctx.log("swift build -c release --product pixel-hook (1 à 3 minutes)")
        base = [swift, "build", "-c", "release", "--product", "pixel-hook", "--package-path", str(package),
                "--scratch-path", str(scratch)]
        code, output = run_quiet(base, timeout=max(60.0, ctx.deadline - time.monotonic() - 60.0))
        ctx.extra_files["build.log"] = output
        answer["swift_version"] = run_quiet([swift, "--version"], timeout=30)[1].strip().splitlines()[:1]
        if code != 0:
            answer["build"] = "échec (voir build.log)"
            raise RuntimeError("la compilation de pixel-hook a échoué (code %s)" % code)
        code, bin_path = run_quiet(base + ["--show-bin-path"], timeout=60)
        binary = os.path.join(bin_path.strip().splitlines()[-1], "pixel-hook") if code == 0 else ""
        answer["build"] = "ok"
    if not binary or not os.access(binary, os.X_OK):
        raise RuntimeError("binaire pixel-hook introuvable : %s" % binary)
    answer["binary"] = binary

    sock_dir = ctx.tmp / "sock"
    sock_dir.mkdir(mode=0o700)
    sock_path = str(sock_dir / "hook.sock")
    if len(sock_path.encode("utf-8")) > 103:
        sock_dir = Path(tempfile.mkdtemp(prefix="pos-s9-", dir="/tmp"))
        sock_path = str(sock_dir / "hook.sock")
    listener = _LineListener(sock_path)
    payload = json.dumps({
        "session_id": str(uuid.uuid4()), "transcript_path": "/tmp/t.jsonl", "cwd": "/tmp/projet",
        "permission_mode": "default", "hook_event_name": "PreToolUse", "tool_name": "Bash",
        "tool_input": {"command": "npm test", "description": "Run test suite " + "x" * 600},
        "tool_use_id": "toolu_01ABC",
    }).encode("utf-8")
    env = {key: value for key, value in os.environ.items() if not key.startswith("PIXEL_")}
    env.update({"PIXEL_HOOK_SOCKET": sock_path, "PIXEL_AGENT_ID": str(uuid.uuid4()),
                "PIXEL_HOOK_TOKEN": os.urandom(32).hex()})
    delivery: List[float] = []
    exits: List[float] = []
    failures: List[str] = []
    try:
        for run in range(ctx.h.args.s9_runs):
            before = listener.count()
            start = mono_ns()
            elapsed, code, output = _spawn_ms([binary], payload, env)
            exits.append(elapsed)
            if code != 0 or output:
                failures.append("run %d : code %s, sortie %r" % (run, code, output[:80]))
            end = time.monotonic() + 2.0
            while listener.count() == before and time.monotonic() < end:
                time.sleep(0.002)
            if listener.count() > before:
                received_ns, line = listener.get(before)
                delivery.append((received_ns - start) / 1e6)
                if run == 0:
                    try:
                        sample = json.loads(line.decode("utf-8"))
                        if isinstance(sample, dict) and "token" in sample:
                            sample["token"] = "<jeton de test>"
                        answer["sample_message"] = sample
                    except ValueError:
                        answer["sample_message"] = truncate(line.decode("utf-8", "replace"), 400)
            else:
                failures.append("run %d : aucun message reçu" % run)
    finally:
        listener.close()
    no_socket_env = dict(env, PIXEL_HOOK_SOCKET=str(sock_dir / "absent.sock"))
    no_socket: List[float] = []
    for run in range(10):
        elapsed, code, output = _spawn_ms([binary], payload, no_socket_env)
        no_socket.append(elapsed)
        if code != 0 or output:
            failures.append("sans socket %d : code %s, sortie %r" % (run, code, output[:80]))
    true_path = shutil.which("true") or "/usr/bin/true"
    baseline = [_spawn_ms([true_path], b"", env)[0] for _ in range(20)]
    answer.update({
        "runs": ctx.h.args.s9_runs,
        "delivery_ms": percentiles(delivery),
        "exit_ms": percentiles(exits),
        "no_socket_exit_ms": percentiles(no_socket),
        "baseline_true_ms": percentiles(baseline),
        "failures": failures[:20],
        "failure_count": len(failures),
    })


SCENARIOS: List[Scenario] = [
    Scenario("S1", "Fusion des hooks : --settings + .claude/settings.local.json", scenario_s1),
    Scenario("S2", "--session-id, puis fermeture du PTY", scenario_s2),
    Scenario("S3.a-30ms", "Saisie puis Entrée après 30 ms", make_delay_scenario(30)),
    Scenario("S3.a-120ms", "Saisie puis Entrée après 120 ms", make_delay_scenario(120)),
    Scenario("S3.a-250ms", "Saisie puis Entrée après 250 ms (+ captures d'écran)", make_delay_scenario(250)),
    Scenario("S3.b-lf", "Saut de ligne LF dans le texte saisi", scenario_s3_newline),
    Scenario("S3.c-paste", "Amorce + collage entre crochets de 1200 caractères", scenario_s3_paste),
    Scenario("S3.d-positional", "Prompt positionnel", scenario_s3_positional),
    Scenario("S3.e-permission", "Permission : « 1 », puis enchaînement", scenario_s3_permission, timeout=150),
    Scenario("S4", "Identifiants : /clear, /compact, /resume, --resume, --fork-session ; --worktree", scenario_s4,
             timeout=420),
    Scenario("S5", "Refus d'une permission par Échap", scenario_s5, timeout=120),
    Scenario("S7", "Dialogue AskUserQuestion", scenario_s7, timeout=120),
    Scenario("S3b-background", "Tâche de fond (optionnel, --with-perturbation)", scenario_s3b, timeout=150,
             optional=True),
    Scenario("S9", "Latence de pixel-hook", scenario_s9, timeout=900, needs_claude=False),
]


def select_scenarios(only: Optional[str], with_optional: bool) -> List[Scenario]:
    """`only` is a comma-separated list; "S3" selects S3.a…S3.e, "S3.a" the three delays, "S3b" the optional one."""
    if not only:
        return [s for s in SCENARIOS if with_optional or not s.optional]
    tokens = [t.strip() for t in only.split(",") if t.strip()]
    chosen = []
    for scenario in SCENARIOS:
        for token in tokens:
            lowered = token.lower()
            sid = scenario.id.lower()
            if sid == lowered or sid.startswith(lowered + ".") or sid.startswith(lowered + "-"):
                chosen.append(scenario)
                break
    return chosen


# ------------------------------------------------------------------------------------------------------------
# Summary (French, for the human reading the results)


def _yes_no(value: Any) -> str:
    if value is True:
        return "oui"
    if value is False:
        return "non"
    return "?"


def _code(value: Any, limit: int = 200) -> str:
    text = truncate(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False), limit)
    return "`%s`" % text.replace("`", "'").replace("\n", "\\n")


def _screen_block(lines: List[str], text: Optional[str]) -> None:
    if not text:
        lines.append("_(pas de capture)_")
        return
    lines.append("```text")
    lines.extend(text.split("\n")[-30:])
    lines.append("```")


def _find_screen(result: Dict[str, Any], contains: str) -> Optional[Dict[str, Any]]:
    for screen in result.get("screens", []):
        if contains in screen["label"]:
            return screen
    return None


def build_summary(env: Dict[str, Any], results: List[Dict[str, Any]]) -> str:
    """summary.md: one section per spike, answers computed from the notes."""
    by_id = {r["notes"]["id"]: r for r in results}
    notes = {sid: r["notes"] for sid, r in by_id.items()}

    def ans(sid: str) -> Dict[str, Any]:
        return notes.get(sid, {}).get("answer", {})

    def status(sid: str) -> str:
        if sid not in notes:
            return "non lancé"
        return notes[sid].get("status", "?")

    lines: List[str] = []
    add = lines.append
    add("# Résultats des spikes de l'étape 2")
    add("")
    add("Date : %s · Claude Code : %s · %s · Python %s · harnais v%s" % (
        env.get("date"), env.get("claude_version"), env.get("os_version"), env.get("python", {}).get("version"),
        HARNESS_VERSION))
    add("Modèle : `%s` · mode de permission : `default` · terminal simulé %dx%d, `TERM=xterm-256color` "
        "(réponses aux requêtes du terminal : comme SwiftTerm)" % (env.get("model"), COLS, ROWS))
    add("")
    add("Les réponses ci-dessous sont calculées automatiquement ; les détails sont dans chaque dossier "
        "(`notes.json`, `events.jsonl`, `screens/`, `transcript.txt`, `pty.jsonl`).")
    add("")
    add("## Déroulé")
    add("")
    add("| Scénario | Statut | Durée | Détail |")
    add("|---|---|---|---|")
    for result in results:
        n = result["notes"]
        add("| %s — %s | %s | %.0f s | %s |" % (n["id"], n["title"], n.get("status"), n.get("duration_s", 0),
                                               truncate(n.get("error") or "", 120).replace("|", "/")))
    add("")

    # S1
    add("## S1 — Les hooks de `--settings` s'ajoutent-ils aux autres ?")
    a = ans("S1")
    if a.get("tags"):
        verdict = "**OUI**, les deux sources ont reçu les événements" if a.get("merged") else \
            "**NON**, une source n'a pas reçu tous les événements"
        add("%s (hooks « app » passés par `--settings`, hooks « project-local » dans "
            "`.claude/settings.local.json` du dossier jetable)." % verdict)
        for name, tags in a["tags"].items():
            add("- %s : %s" % (name, ", ".join(tags) or "aucun"))
        add("- Note : les hooks « déjà là » sont simulés dans les settings locaux du projet (le harnais ne touche "
            "jamais `~/.claude/settings.json`). La doc de `--settings` dit que ses valeurs remplacent les mêmes clés "
            "des fichiers, d'où la question pour la clé `hooks`.")
    else:
        add("_Pas de réponse (%s)._" % status("S1"))
    add("")

    # S2
    add("## S2 — `SessionStart.session_id` = `--session-id` ?")
    a = ans("S2")
    if "equal" in a:
        add("**%s** (demandé %s, reçu %s, source `%s`)." % (
            _yes_no(a["equal"]).upper(), _code(a.get("requested")), _code(a.get("received")), a.get("source")))
        hang = a.get("hangup", {})
        add("- Fermeture du PTY (SIGHUP, comme un crash de l'app) : processus terminé = %s, code %s, "
            "SessionEnd = %s." % (_yes_no(hang.get("exited")), hang.get("exit_status"),
                                  _code(hang.get("session_end_reason")) if hang.get("session_end_reason")
                                  else "aucun"))
    else:
        add("_Pas de réponse (%s)._" % status("S2"))
    add("")

    # S3
    add("## S3 — Saisie dans le PTY")
    add("")
    add("### (a) Texte saisi d'un bloc, puis Entrée seule après un délai")
    add("")
    add("| Délai | UserPromptSubmit | Prompt identique | Entrée → hook | Stop |")
    add("|---|---|---|---|---|")
    for sid in ("S3.a-30ms", "S3.a-120ms", "S3.a-250ms"):
        a = ans(sid)
        if "user_prompt_submit" in a:
            add("| %s ms | %s | %s | %s | %s |" % (
                a.get("delay_ms"), _yes_no(a.get("user_prompt_submit")), _yes_no(a.get("exact")),
                "%s ms" % a["enter_to_hook_ms"] if "enter_to_hook_ms" in a else "—", _yes_no(a.get("stop"))))
        else:
            add("| %s | %s | | | |" % (sid, status(sid)))
    for sid in ("S3.a-30ms", "S3.a-120ms", "S3.a-250ms"):
        a = ans(sid)
        if a.get("user_prompt_submit") and not a.get("exact"):
            add("- %s : prompt reçu %s" % (sid, _code(a.get("prompt"))))
    add("")
    add("### (b) `LF` dans le texte saisi")
    a = ans("S3.b-lf")
    if "user_prompt_submit" in a:
        add("UserPromptSubmit : %s · le prompt contient un saut de ligne : **%s** · prompt reçu : %s" % (
            _yes_no(a.get("user_prompt_submit")), _yes_no(a.get("contains_newline")), _code(a.get("prompt"))))
    else:
        add("_Pas de réponse (%s)._" % status("S3.b-lf"))
    add("")
    add("### (c) Amorce saisie + collage entre crochets (1200 caractères), Entrée après 250 ms")
    a = ans("S3.c-paste")
    if a:
        add("- `ESC[?2004h` émis par claude : **%s** (actif au moment du collage : %s)" % (
            _yes_no(a.get("esc_2004h_seen")), _yes_no(a.get("bracketed_paste_on_before_paste"))))
        if a.get("paste_sent"):
            add("- « [Pasted text » affiché : %s" % _yes_no(a.get("pasted_placeholder_on_screen")))
            add("- UserPromptSubmit : **%s**%s" % (
                _yes_no(a.get("user_prompt_submit")),
                " (après %s ms)" % a["enter_to_hook_ms"] if "enter_to_hook_ms" in a else ""))
            if a.get("user_prompt_submit"):
                add("- Prompt reçu : %s caractères, %s lignes ; commence par l'amorce : %s ; contient le texte collé "
                    "exact : %s (aux espaces près : %s) ; contient « [Pasted text » : %s" % (
                        a.get("prompt_len"), a.get("prompt_lines"), _yes_no(a.get("starts_with_lead")),
                        _yes_no(a.get("contains_body_exactly")),
                        _yes_no(a.get("contains_body_whitespace_insensitive")),
                        _yes_no(a.get("contains_placeholder"))))
                add("- Début : %s" % _code(a.get("prompt_head")))
        else:
            add("- Collage non tenté : le mode collage entre crochets n'était pas actif.")
    else:
        add("_Pas de réponse (%s)._" % status("S3.c-paste"))
    add("")
    add("### (d) Prompt positionnel (`claude … \"Réponds juste OK.\"`)")
    a = ans("S3.d-positional")
    if "user_prompt_submit" in a:
        add("UserPromptSubmit : **%s** · prompt : %s · %s ms après SessionStart · Stop : %s" % (
            _yes_no(a.get("user_prompt_submit")), _code(a.get("prompt")), a.get("after_session_start_ms", "—"),
            _yes_no(a.get("stop"))))
    else:
        add("_Pas de réponse (%s)._" % status("S3.d-positional"))
    add("")
    add("### (e) Permission : « 1 », puis enchaînement d'un nouveau prompt")
    a = ans("S3.e-permission")
    if "permission_request" in a:
        if not a["permission_request"]:
            add("Aucune demande de permission malgré la règle `ask` %s passée par `--settings` (réglage "
                "d'entreprise ?). Événements : %s" % (_code(list(SPIKE_ASK_RULES)),
                                                      _code([e.get("event") for e in a.get("events", [])], 300)))
        else:
            add("- PermissionRequest : outil `%s`, entrée %s ; champs : %s" % (
                a.get("permission_tool"), _code(a.get("permission_tool_input"), 160),
                ", ".join(a.get("permission_payload_keys", []))))
            add("- « 1 » seul répond : **%s**%s" % (
                _yes_no(a.get("digit_alone_answers")),
                "" if a.get("digit_alone_answers") else " ; « 1 » puis Entrée : %s" % _yes_no(
                    a.get("digit_then_enter_answers"))))
            add("- Événements après la touche : %s" % (" → ".join(
                str(e.get("event")) for e in a.get("events_after_key", [])) or "aucun"))
            add("- Fichier créé : %s · Stop : %s · écran calme %s ms après Stop" % (
                _yes_no(a.get("file_created")), _yes_no(a.get("stop")), a.get("stop_to_quiet_ms", "—")))
            chain = a.get("chain", {})
            add("- Enchaînement après Stop (nouveau prompt, Entrée à 250 ms) : UserPromptSubmit **%s**, prompt "
                "identique %s, Stop %s" % (_yes_no(chain.get("user_prompt_submit")), _yes_no(chain.get("exact")),
                                           _yes_no(a.get("chain_stop"))))
    else:
        add("_Pas de réponse (%s)._" % status("S3.e-permission"))
    add("")
    add("Captures utiles aux motifs d'écran (`ScreenPatterns`) : `S3.a-250ms/screens/` (prêt, brouillon, en cours), "
        "`S3.e-permission/screens/` (dialogue, saisie après Stop).")
    add("")

    # S3b
    add("## S3b — Tâche de fond (minimal)")
    a = ans("S3b-background")
    if "S3b-background" not in notes:
        add("_Non lancé (option `--with-perturbation`)._")
    elif "stop_keys" in a:
        add("- Stop.background_tasks : %s" % _code(a.get("stop_background_tasks"), 400))
        add("- Stop.session_crons : %s" % _code(a.get("stop_session_crons"), 200))
        add("- À la fin de la tâche : nouveau UserPromptSubmit %s, second Stop %s" % (
            _yes_no(a.get("second_turn_user_prompt_submit")), _yes_no(a.get("second_stop"))))
        add("- Événements après le premier Stop : %s" % (" → ".join(
            "%s(+%.1f s)" % (e.get("event"), e.get("t_ms", 0) / 1000) for e in a.get("events_after_first_stop", []))
            or "aucun"))
    else:
        add("_Pas de réponse (%s)._" % status("S3b-background"))
    add("")

    # S4
    add("## S4 — `session_id` après /clear, /compact, /resume, --resume, --fork-session ; `cwd` avec --worktree")
    a = ans("S4")
    if a.get("steps"):
        add("")
        add("| Étape | Événement | source / reason / new_cwd | session_id | cwd |")
        add("|---|---|---|---|---|")
        for step in a["steps"]:
            add("| %s | %s | %s | `%s` | %s |" % (step["step"], step["event"], step.get("detail") or "",
                                                 step.get("session_id") or "", _code(step.get("cwd"))
                                                 if step.get("cwd") else ""))
        d = a.get("derived", {})
        add("")
        add("- `--session-id` respecté : %s" % _yes_no(d.get("startup_id_is_requested")))
        add("- /clear change l'id : **%s** (source `%s`)" % (_yes_no(d.get("clear_changes_id")), d.get("clear_source")))
        add("- /compact garde l'id : **%s** (source `%s`)" % (_yes_no(d.get("compact_keeps_id")),
                                                              d.get("compact_source")))
        add("- /resume dans la session revient à l'id du premier sujet : **%s** (source `%s`)" % (
            _yes_no(d.get("resume_in_session_returns_to_first_id")), d.get("resume_in_session_source")))
        picker = a.get("resume_picker", {})
        add("- Sélecteur de /resume : ligne en surbrillance %s, options numérotées %s (capture `S4/screens/`)" % (
            _code(picker.get("focused")), _code(picker.get("options", []), 200)))
        add("- --resume garde l'id : **%s** (source `%s`)" % (_yes_no(d.get("resume_keeps_id")),
                                                              d.get("resume_source")))
        add("- --fork-session donne un nouvel id : **%s** (source `%s`)" % (_yes_no(d.get("fork_new_id")),
                                                                            d.get("fork_source")))
        worktree = a.get("worktree", {})
        add("- --worktree : `cwd` de SessionStart = %s (dans `.claude/worktrees/` : **%s** ; dossier lancé : %s) ; "
            "CwdChanged : %s" % (_code(worktree.get("session_start_cwd")),
                                 _yes_no(d.get("worktree_cwd_is_a_worktree")), _code(worktree.get("workspace")),
                                 _code(worktree.get("cwd_changed", []), 200)))
    else:
        add("_Pas de réponse (%s)._" % status("S4"))
    add("")

    # S5
    add("## S5 — Refus manuel d'une permission par Échap")
    a = ans("S5")
    if "permission_request" in a:
        if not a["permission_request"]:
            add("Aucune demande de permission. Événements : %s" % _code(
                [e.get("event") for e in a.get("events", [])], 300))
        else:
            fired = a.get("fired", {})
            add("- Après Échap : %s" % (" → ".join(
                "%s(+%.0f ms)" % (e.get("event"), e.get("t_ms", 0)) for e in a.get("events_after_escape", []))
                or "aucun événement"))
            add("- " + " · ".join("%s %s" % (name, _yes_no(value)) for name, value in fired.items()))
            add("- Dialogue encore affiché : %s · fichier créé : %s · octet Échap brut (0x1B) envoyé avec les "
                "drapeaux clavier kitty = %s" % (_yes_no(a.get("dialog_still_visible")), _yes_no(a.get("file_created")),
                                                 a.get("kitty_flags_at_escape")))
            if a.get("post_tool_use_failure"):
                add("- PostToolUseFailure : %s" % _code(a["post_tool_use_failure"], 400))
            add("- Champs de PermissionRequest : %s" % ", ".join(sorted(a.get("permission_payload", {}).keys())))
    else:
        add("_Pas de réponse (%s)._" % status("S5"))
    add("")

    # S7
    add("## S7 — Dialogues à l'écran")
    add("")
    add("Options détectées par le motif de l'app `^\\s*[❯>]?\\s*([1-9])\\.\\s+(.+)$` (bordures `│` retirées).")
    add("")
    for sid, label in (("S3.e-permission", "Permission (S3 e)"), ("S5", "Permission (S5)")):
        result = by_id.get(sid)
        screen = _find_screen(result, "dialogue-permission") if result else None
        add("### %s" % label)
        add("Options : %s" % _code(ans(sid).get("dialog_options", []), 300))
        _screen_block(lines, screen["text"] if screen else None)
        add("")
    add("### AskUserQuestion (S7)")
    a = ans("S7")
    if "ask_user_question" in a:
        if a["ask_user_question"]:
            add("- Premier événement : %s · `tool_input` : %s" % (a.get("first_event"),
                                                                 _code(a.get("tool_input"), 400)))
            add("- Événements jusqu'au dialogue : %s" % (" → ".join(
                str(e.get("event")) for e in a.get("events_until_dialog", [])) or "aucun"))
            add("- Options : %s" % _code(a.get("options", []), 300))
            add("- Après Échap : %s" % (" → ".join(
                "%s(+%.0f ms)" % (e.get("event"), e.get("t_ms", 0)) for e in a.get("events_after_escape", []))
                or "aucun événement"))
            result = by_id.get("S7")
            screen = _find_screen(result, "dialogue-question") if result else None
            _screen_block(lines, screen["text"] if screen else None)
        else:
            add("L'outil AskUserQuestion n'a pas été appelé. Événements : %s" % _code(
                [e.get("event") for e in a.get("events", [])], 300))
    else:
        add("_Pas de réponse (%s)._" % status("S7"))
    add("")

    # S9
    add("## S9 — Latence de `pixel-hook`")
    a = ans("S9")
    if "delivery_ms" in a:
        add("| Mesure | n | p50 | p95 | max |")
        add("|---|---|---|---|---|")
        for key, label in (("delivery_ms", "Lancement → message reçu sur le socket"),
                           ("exit_ms", "Lancement → fin du processus"),
                           ("no_socket_exit_ms", "Sans socket (app fermée) → fin"),
                           ("baseline_true_ms", "Référence : `/usr/bin/true`")):
            p = a.get(key, {})
            add("| %s | %s | %s ms | %s ms | %s ms |" % (label, p.get("n", 0), p.get("p50", "—"), p.get("p95", "—"),
                                                         p.get("max", "—")))
        add("")
        add("Échecs : %s%s" % (a.get("failure_count", 0), (" — " + "; ".join(a.get("failures", [])[:5]))
                              if a.get("failures") else ""))
    else:
        add("_Pas de mesure (%s%s)._" % (status("S9"), " : " + notes["S9"].get("error", "")
                                         if "S9" in notes and notes["S9"].get("error") else ""))
    add("")

    # S10
    add("## S10 — Des hooks tournent-ils avant l'acceptation de la confiance du dossier ?")
    launches = [(r["notes"]["id"], launch) for r in results for launch in r["notes"].get("launches", [])]
    with_dialog = [(sid, launch) for sid, launch in launches if launch.get("trust_dialog")]
    early = [(sid, launch) for sid, launch in with_dialog if launch.get("hooks_before_trust_accept")]
    # A NO only holds for launches where the dialog was accepted and the session then started.
    conclusive = [(sid, launch) for sid, launch in with_dialog
                  if "session_start" in launch and not launch.get("startup_failed")]
    inconclusive = [(sid, launch) for sid, launch in with_dialog if (sid, launch) not in conclusive]
    if with_dialog:
        if early:
            add("**OUI** dans %d lancement(s) sur %d :" % (len(early), len(with_dialog)))
            for sid, launch in early:
                add("- %s / %s : %s" % (sid, launch.get("label"), ", ".join(
                    str(e.get("event")) for e in launch["hooks_before_trust_accept"])))
        elif conclusive:
            add("**NON** : aucun hook avant l'acceptation, sur %d lancement(s) avec le dialogue puis SessionStart."
                % len(conclusive))
        else:
            add("**Non concluant** : le dialogue est apparu, mais la session n'a démarré dans aucun de ces "
                "lancements.")
        if inconclusive:
            add("- Non concluant(s) (dialogue vu, pas de SessionStart ensuite) : %s." % ", ".join(
                "%s / %s" % (sid, launch.get("label")) for sid, launch in inconclusive))
        without = [sid for sid, launch in launches if not launch.get("trust_dialog") and "session_start" in launch]
        if without:
            add("- Lancements sans dialogue de confiance (dossier déjà approuvé, ex. reprise) : %d." % len(without))
        moves = sorted({launch.get("trust_moves") for _, launch in with_dialog if "trust_moves" in launch})
        if moves:
            add("- Flèches bas avant « Yes, I trust this folder » : %s." % ", ".join(str(m) for m in moves))
    elif launches:
        add("Le dialogue de confiance n'a été détecté dans aucun lancement (dossier temporaire déjà approuvé, ou "
            "texte du dialogue différent : voir les captures `*-pret`).")
    else:
        add("_Aucun lancement._")
    add("")

    # Startup dialogs
    add("## Dialogues au démarrage (fermés par Échap avant toute saisie)")
    seen: Dict[str, List[str]] = {}
    for sid, launch in launches:
        for dialog in launch.get("startup_dialogs", []):
            key = "%s (en surbrillance : %s)" % (dialog.get("title") or "?", dialog.get("focused") or "?")
            seen.setdefault(key, []).append("%s / %s" % (sid, launch.get("label")))
    if seen:
        for key, where in seen.items():
            add("- %s — %d lancement(s) : %s" % (_code(key, 240), len(where), ", ".join(where[:6])))
        add("- L'app doit les attendre elle aussi : ils s'ouvrent après SessionStart, avant la zone de saisie.")
    else:
        add("Aucun.")
    add("")

    # What this run cannot answer
    add("## Non couvert par ce script (à vérifier à la main)")
    add("- S5 : la ligne « limite d'usage » à l'écran (il faudrait épuiser le quota).")
    add("- S7 : les touches qui choisissent chaque option ; seules « 1 » (S3.e) et Échap (S5, S7) sont testées.")
    add("- S8 : glisser-déposer SwiftUI → AppKit, à tester dans l'app.")
    add("- S11 : 20 sessions au repos pendant 10 min, à mesurer dans Instruments avec l'app.")
    add("")

    # Observed fields
    add("## Champs observés par événement")
    add("")
    add("| Événement | Nb | Champs du JSON de hook |")
    add("|---|---|---|")
    fields: Dict[str, set] = {}
    counts: Dict[str, int] = {}
    for result in results:
        for event in result.get("events", []):
            name = str(event.get("event"))
            counts[name] = counts.get(name, 0) + 1
            fields.setdefault(name, set()).update(hook_of(event).keys())
    for name in sorted(counts):
        add("| %s | %d | %s |" % (name, counts[name], ", ".join(sorted(fields[name]))))
    add("")

    # Terminal
    add("## Terminal : modes et requêtes de claude")
    terminal: Dict[str, set] = {"modes": set(), "queries": set(), "osc": set(), "kitty": set()}
    for result in results:
        for launch in result["notes"].get("launches", []):
            t = launch.get("terminal", {})
            terminal["modes"].update(t.get("private_modes_seen", []))
            terminal["queries"].update(t.get("queries", []))
            terminal["osc"].update(t.get("osc_codes", []))
            terminal["kitty"].update(str(f) for f in t.get("kitty_keyboard_flags_history", []))
    add("- Modes privés : %s" % (", ".join(sorted(terminal["modes"])) or "aucun"))
    add("- Requêtes auxquelles le terminal a répondu : %s" % (", ".join(sorted(terminal["queries"])) or "aucune"))
    add("- Codes OSC : %s" % (", ".join(sorted(terminal["osc"])) or "aucun"))
    add("- Drapeaux du protocole clavier kitty demandés : %s" % (", ".join(sorted(terminal["kitty"])) or "aucun"))
    add("")
    add("## Partage")
    add("")
    add("`git add Tools/spikes/results && git commit -m \"Résultats des spikes\" && git push`")
    add("")
    return "\n".join(lines)


# ------------------------------------------------------------------------------------------------------------
# Harness


def collect_environment(claude: str, model: str) -> Dict[str, Any]:
    env: Dict[str, Any] = {
        "harness_version": HARNESS_VERSION,
        "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "claude_path": claude,
        "model": model,
        "pty": {"rows": ROWS, "cols": COLS, "TERM": "xterm-256color", "COLORTERM": "truecolor"},
        "shell": os.environ.get("SHELL"),
        "term_program": os.environ.get("TERM_PROGRAM"),
        "lang": os.environ.get("LANG"),
        "machine": platform.machine(),
        "cpu_count": os.cpu_count(),
        "python": {"version": platform.python_version(), "executable": sys.executable},
    }
    code, output = run_quiet([claude, "--version"], timeout=30)
    env["claude_version"] = output.strip().splitlines()[0] if code == 0 and output.strip() else "inconnue"
    if shutil.which("sw_vers"):
        info = {}
        for line in run_quiet(["sw_vers"], timeout=10)[1].splitlines():
            key, _, value = line.partition(":")
            if value.strip():
                info[key.strip()] = value.strip()
        env["sw_vers"] = info
        env["os_version"] = "%s %s (%s)" % (info.get("ProductName", "macOS"), info.get("ProductVersion", "?"),
                                            info.get("BuildVersion", "?"))
    else:
        env["os_version"] = platform.platform()
    if shutil.which("xcodebuild"):
        code, output = run_quiet(["xcodebuild", "-version"], timeout=20)
        if code == 0:
            env["xcode"] = " ".join(output.split())
    return env


class Harness:
    def __init__(self, args: argparse.Namespace, claude: str) -> None:
        self.args = args
        self.claude = claude
        self.stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        results_root = Path(args.results_dir).resolve() if args.results_dir else HERE / "results"
        self.out_root = results_root / self.stamp
        base_tmp = Path(tempfile.gettempdir())
        self.tmp_root = base_tmp.resolve() / ("pos-spikes-" + self.stamp)
        self.tmp_root.mkdir(mode=0o700, parents=True)
        self.hooklog = self.tmp_root / "hooklog.py"
        shutil.copyfile(HERE / "hooklog.py", self.hooklog)
        self.python = os.path.realpath(sys.executable)
        self.settings_path = self.tmp_root / "spike-settings.json"
        self.settings_path.write_text(json.dumps(self.spike_settings(), indent=2) + "\n", encoding="utf-8")
        paths = [(str(self.tmp_root), "<tmp>"), (str(base_tmp / ("pos-spikes-" + self.stamp)), "<tmp>"),
                 (str(REPO_ROOT), "<repo>")]
        self.anonymizer = Anonymizer.for_current_user(paths=paths)
        self.scenarios = select_scenarios(args.only, args.with_perturbation)

    def hook_command(self, tag: str) -> str:
        return hook_command(self.python, str(self.hooklog), tag)

    def spike_settings(self) -> Dict[str, Any]:
        """The file passed with --settings: the app's hook block, plus the ask rules of SPIKE_ASK_RULES."""
        settings = build_hook_settings(self.hook_command("app"))
        settings["permissions"] = {"ask": list(SPIKE_ASK_RULES)}
        return settings

    def child_env(self, log_path: Path, tag: str) -> Dict[str, str]:
        # Under a parent Claude Code session, its CLAUDE_* variables (session id, sockets, tokens) must not reach
        # the child: the app never runs claude with them either.
        parent = inside_claude_session()
        env = {key: value for key, value in os.environ.items()
               if key not in _DROPPED_ENV and not key.startswith(_DROPPED_ENV_PREFIXES)
               and not (parent and key.startswith("CLAUDE"))}
        env.update({
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "PIXEL_SPIKE_LOG": str(log_path),
            "PIXEL_SPIKE_TAG": tag,
            "CLAUDE_CODE_DISABLE_AGENT_VIEW": "1",  # as the app (PROPOSITION 5.1, decision 11)
            "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",  # a survey would catch our digit keys
        })
        env.setdefault("LANG", "fr_FR.UTF-8")
        return env

    def run(self) -> int:
        print("Pixel Open Space · spikes · claude : %s" % self.claude)
        print("Dossier jetable : %s" % self.tmp_root)
        env_info = collect_environment(self.claude, self.args.model)
        print("Claude Code %s · %s" % (env_info.get("claude_version"), env_info.get("os_version")))
        if inside_claude_session():
            env_info["run_inside_claude_session"] = True
            print("Attention : lancé depuis une session Claude Code ; ses variables CLAUDE_* ne sont pas transmises.")
        print("")
        results: List[Dict[str, Any]] = []
        startup_failures = 0
        interrupted = False
        for scenario in self.scenarios:
            if scenario.needs_claude and startup_failures >= 2:
                results.append({"notes": {"id": scenario.id, "title": scenario.title, "status": "ignoré",
                                          "error": "claude n'a pas démarré deux fois de suite", "launches": []},
                                "events": [], "screens": []})
                print("- %s — %s : ignoré (claude ne démarre pas)" % (scenario.id, scenario.title))
                continue
            print("▶ %s — %s…" % (scenario.id, scenario.title), flush=True)
            ctx = ScenarioContext(self, scenario)
            started = time.monotonic()
            try:
                scenario.func(ctx)
                ctx.notes["status"] = "ok"
                if scenario.needs_claude:
                    startup_failures = 0
            except ScenarioSkipped as error:
                ctx.notes.update(status="ignoré", error=str(error))
            except StartupFailure as error:
                startup_failures += 1
                ctx.notes.update(status="échec au démarrage", error=str(error))
            except ScenarioTimeout:
                ctx.notes.update(status="délai dépassé", error="délai de %.0f s dépassé" % ctx.notes["timeout_s"])
            except KeyboardInterrupt:
                ctx.notes.update(status="interrompu", error="Ctrl+C")
                interrupted = True
            except Exception as error:  # noqa: BLE001 - one scenario must not stop the others
                ctx.notes.update(status="erreur", error="%s: %s" % (type(error).__name__, error),
                                 traceback=traceback.format_exc())
            finally:
                ctx.close_all()
                ctx.notes["duration_s"] = round(time.monotonic() - started, 1)
                try:
                    ctx.write_results()
                except Exception as error:  # noqa: BLE001
                    ctx.notes["write_error"] = str(error)
                    print("  (écriture des résultats incomplète : %s)" % error)
            mark = "✔" if ctx.notes["status"] == "ok" else "✘"
            print("  %s %s (%.0f s)%s" % (mark, ctx.notes["status"], ctx.notes["duration_s"],
                                          " — " + ctx.notes["error"] if ctx.notes.get("error") else ""), flush=True)
            results.append({"notes": ctx.notes, "events": ctx.events.events, "screens": ctx.screens})
            if interrupted:
                break

        self.out_root.mkdir(parents=True, exist_ok=True)
        # Permission scenarios that got no dialog: their answers are missing (see summary.md).
        env_info["permission_request_missing"] = [
            r["notes"]["id"] for r in results if r["notes"]["id"] in PERMISSION_SCENARIOS
            and r["notes"].get("answer", {}).get("permission_request") is False]
        (self.out_root / "environment.json").write_text(
            json.dumps(self.anonymizer.json(env_info), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        summary = build_summary(env_info, results)
        (self.out_root / "summary.md").write_text(self.anonymizer.text(summary), encoding="utf-8")
        if self.args.keep_temp:
            print("\nDossier jetable conservé : %s" % self.tmp_root)
        else:
            shutil.rmtree(self.tmp_root, ignore_errors=True)

        relative = self.out_root
        try:
            relative = self.out_root.relative_to(REPO_ROOT)
        except ValueError:
            pass
        print("")
        print("Terminé%s. Résultats (anonymisés) : %s" % (" (interrompu)" if interrupted else "", relative))
        print("Résumé : %s" % (relative / "summary.md"))
        print("")
        print("Pour me transmettre les résultats, lance :")
        print("")
        print("  cd %s" % shell_quote(str(REPO_ROOT)))
        print("  git add Tools/spikes/results && git commit -m \"Résultats des spikes\" && git push")
        print("")
        return 130 if interrupted else 0


def parse_args(argv: Optional[Sequence[str]]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="spikes.py",
        description="Spikes de l'étape 2 (docs/PROPOSITION.md, 5.11) : lance le vrai claude dans des dossiers "
                    "jetables et enregistre hooks, sorties du terminal et captures d'écran.")
    parser.add_argument("-y", "--yes", action="store_true", help="ne pas demander de confirmation")
    parser.add_argument("--only", metavar="LISTE",
                        help="scénarios à lancer, séparés par des virgules (ex. S1,S3,S4 ; S3.a = les trois délais)")
    parser.add_argument("--with-perturbation", action="store_true",
                        help="ajoute S3b (tâche de fond pendant une session)")
    parser.add_argument("--list", action="store_true", help="liste les scénarios et quitte")
    parser.add_argument("--claude", metavar="CHEMIN", help="exécutable claude (défaut : celui du PATH)")
    parser.add_argument("--model", default=DEFAULT_MODEL, help="modèle (défaut : haiku)")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S,
                        help="délai maximal par scénario, en secondes (défaut : 90 ; S3.e, S4, S5, S7, S9 ont plus)")
    parser.add_argument("--pixel-hook", metavar="CHEMIN", help="S9 : binaire pixel-hook déjà compilé")
    parser.add_argument("--s9-runs", type=int, default=50, help=argparse.SUPPRESS)
    parser.add_argument("--results-dir", metavar="DOSSIER",
                        help="dossier des résultats (défaut : Tools/spikes/results)")
    parser.add_argument("--keep-temp", action="store_true", help="garder le dossier jetable à la fin")
    parser.add_argument("-v", "--verbose", action="store_true", help="afficher chaque étape")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    if args.list:
        for scenario in SCENARIOS:
            print("%-16s %s" % (scenario.id, scenario.title))
        print("%-16s %s" % ("S10", "Hooks avant la confiance du dossier (déduit de chaque premier lancement)"))
        return 0
    if os.geteuid() == 0 and os.environ.get("POS_SPIKES_ALLOW_ROOT") != "1":
        print("Erreur : ne lance pas les spikes en root (sudo).", file=sys.stderr)
        return 2
    claude = args.claude or shutil.which("claude")
    if not claude:
        print("Erreur : claude introuvable dans le PATH (ou passe --claude CHEMIN).", file=sys.stderr)
        return 2
    claude = os.path.abspath(claude)
    if not os.access(claude, os.X_OK):
        print("Erreur : %s n'est pas exécutable." % claude, file=sys.stderr)
        return 2
    if not select_scenarios(args.only, args.with_perturbation):
        print("Erreur : aucun scénario ne correspond à --only %s (voir --list)." % args.only, file=sys.stderr)
        return 2
    if not args.yes:
        print("Ce script lance le vrai claude (modèle %s, mode default) dans des dossiers jetables sous %s ;\n"
              "il n'écrit ni dans ~/.claude ni dans tes dépôts. Préfère Tools/spikes/run-spikes.sh, qui détaille "
              "tout." % (args.model, tempfile.gettempdir()))
        try:
            reply = input("Continuer ? [o/N] ").strip().lower()
        except EOFError:
            reply = ""
        if reply not in ("o", "oui", "y", "yes"):
            print("Annulé.")
            return 1
    return Harness(args, claude).run()


if __name__ == "__main__":
    sys.exit(main())
