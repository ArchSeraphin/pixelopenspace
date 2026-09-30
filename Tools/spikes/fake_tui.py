#!/usr/bin/env python3
"""Stand-in for the `claude` TUI, used only by test_spikes.py to run the harness end to end without Claude.

It is not an emulation of Claude Code: it implements just what the harness drives (trust dialog and fullscreen
renderer offer laid out as in Claude Code 2.1.285, hooks from --settings and .claude/settings.local.json, typed
input with bracketed paste and Ctrl+U, a permission dialog for `touch`, an AskUserQuestion dialog, /clear,
/compact, /rename, /resume, /exit, --session-id, --resume, --fork-session, --worktree, positional prompt).
"""

import json
import os
import signal
import subprocess
import sys
import tty
import uuid

_WITH_VALUE = {"--settings", "--session-id", "--resume", "--model", "--permission-mode", "--name", "--worktree"}
SESSIONS_FILE = ".fake-sessions.json"


def parse(argv):
    options, positional, i = {}, None, 0
    while i < len(argv):
        arg = argv[i]
        if arg in _WITH_VALUE and i + 1 < len(argv):
            options[arg] = argv[i + 1]
            i += 2
        elif arg.startswith("--"):
            options[arg] = True
            i += 1
        else:
            positional = arg
            i += 1
    return options, positional


def keys(data):
    """Splits terminal input into keys: CSI sequences ("\x1b[B"), a lone Esc, or single characters."""
    i = 0
    while i < len(data):
        if data.startswith("\x1b[", i):
            j = i + 2
            while j < len(data) and not "\x40" <= data[j] <= "\x7e":
                j += 1
            yield data[i:j + 1]
            i = j + 1
        else:
            yield data[i]
            i += 1


def load_sessions():
    try:
        with open(SESSIONS_FILE, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def save_session(session_id, name):
    sessions = load_sessions()
    sessions[session_id] = name
    with open(SESSIONS_FILE, "w", encoding="utf-8") as handle:
        json.dump(sessions, handle)


def load_hooks(paths):
    commands = {}
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                hooks = json.load(handle).get("hooks", {})
        except (OSError, ValueError):
            continue
        for event, groups in hooks.items():
            for group in groups:
                for handler in group.get("hooks", []):
                    known = commands.setdefault(event, [])
                    if handler.get("command") not in known:
                        known.append(handler["command"])
    return commands


class Fake:
    def __init__(self, options):
        self.options = options
        self.hooks = {}
        self.session_id = options.get("--session-id") or str(uuid.uuid4())
        self.dialog = ""  # "", "permission" or "question"
        self.dialog_file = ""
        self.buffer = ""
        self.paste = None

    def out(self, text):
        os.write(1, text.encode("utf-8"))

    def fire(self, event, **fields):
        payload = {"session_id": self.session_id, "transcript_path": "/tmp/fake.jsonl", "cwd": os.getcwd(),
                   "permission_mode": "default", "hook_event_name": event}
        payload.update(fields)
        for command in self.hooks.get(event, []):
            subprocess.run(command, shell=True, input=json.dumps(payload).encode("utf-8"),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3, check=False)

    def prompt(self):
        self.out("\r\n> ")

    def trust(self):
        """As in Claude Code 2.1.285: "No, exit" first and focused, no numbers (digits do nothing), Enter picks the
        focused option, Esc cancels; refusing exits with status 1."""
        if os.path.exists(".fake-trusted"):
            return
        options = ["No, exit", "Yes, I trust this folder"]
        focus = 0
        while True:
            lines = "".join(" %s %s\r\n" % ("❯" if i == focus else " ", option) for i, option in enumerate(options))
            self.out("\x1b[2J\x1b[H Accessing workspace:\r\n\r\n %s\r\n\r\n Quick safety check: Is this a project "
                     "you created or one you trust?\r\n\r\n%s\r\n Enter to confirm · Esc to cancel\r\n"
                     % (os.getcwd(), lines))
            data = os.read(0, 64).decode("utf-8", "replace")
            if not data:
                sys.exit(1)
            for key in keys(data):
                if key in ("\x1b[A", "\x1b[B"):
                    focus = (focus + (1 if key == "\x1b[B" else -1)) % len(options)
                elif key == "\x1b" or (key == "\r" and focus == 0):
                    sys.exit(1)
                elif key == "\r":
                    open(".fake-trusted", "w").close()
                    self.out("\x1b[2J\x1b[H")
                    return

    def offer_fullscreen(self):
        """The fullscreen renderer offer, once per folder, with "Yes, try it" focused. Accepting would relaunch
        Claude Code and save a setting: here it exits with status 3, so a harness that accepts it fails."""
        if os.path.exists(".fake-offer-seen"):
            self.prompt()
            return
        self.dialog = "offer"
        self.out("\r\n  Try the new fullscreen renderer?\r\n\r\n  ❯ 1. Yes, try it\r\n    2. Not now\r\n\r\n"
                 "  Enter to confirm · Esc to cancel\r\n")

    def start(self, positional):
        signal.signal(signal.SIGTERM, self.terminate)
        signal.signal(signal.SIGHUP, self.terminate)
        tty.setraw(0)
        self.trust()
        self.hooks = load_hooks([self.options.get("--settings"), ".claude/settings.local.json"])
        source = "startup"
        if self.options.get("--resume"):
            source = "fork" if self.options.get("--fork-session") else "resume"
            self.session_id = str(uuid.uuid4()) if source == "fork" else self.options["--resume"]
        if isinstance(self.options.get("--worktree"), str):
            worktree = os.path.join(".claude", "worktrees", self.options["--worktree"])
            os.makedirs(worktree, exist_ok=True)
            os.chdir(worktree)
        name = self.options.get("--name")
        save_session(self.session_id, name if isinstance(name, str) else load_sessions().get(self.session_id))
        self.out("\x1b[?2004h\x1b]0;fake claude\x07 Fake TUI · %s\r\n  1. Tip one\r\n" % source)
        self.fire("SessionStart", source=source, model="fake")
        if positional:
            self.prompt()
            self.submit(positional)
        self.offer_fullscreen()
        while True:
            data = os.read(0, 65536)
            if not data:
                self.terminate()
            self.feed(data.decode("utf-8", "replace"))

    def terminate(self, *_):
        self.fire("SessionEnd", reason="other")
        os._exit(0)

    def feed(self, text):
        for key in keys(text):
            if key == "\x1b[200~":
                self.paste = ""
            elif key == "\x1b[201~":
                pasted, self.paste = self.paste or "", None
                self.buffer += pasted
                lines = pasted.count("\n") + 1
                self.out("[Pasted text #1 +%d lines]" % lines if len(pasted) > 800 else pasted)
            elif self.paste is not None:
                self.paste += key
            elif self.dialog:
                self.answer(key)
            elif key == "\r":
                line, self.buffer = self.buffer, ""
                self.submit(line)
            elif key == "\x7f":
                self.buffer = self.buffer[:-1]
            elif key == "\x15":
                self.buffer = ""
                self.out("\r\x1b[K> ")
            elif key.startswith("\x1b"):
                continue
            else:
                self.buffer += key
                self.out(key if key != "\n" else "\r\n")

    def submit(self, line):
        if line == "/exit":
            self.fire("SessionEnd", reason="prompt_input_exit")
            os._exit(0)
        if line == "/clear":
            self.fire("SessionEnd", reason="clear")
            self.session_id = str(uuid.uuid4())
            self.out("\x1b[2J\x1b[H")
            self.fire("SessionStart", source="clear")
            self.prompt()
            return
        if line == "/compact":
            self.fire("PreCompact", trigger="manual", custom_instructions="")
            self.fire("SessionStart", source="compact")
            self.fire("PostCompact", trigger="manual", compact_summary="résumé")
            self.prompt()
            return
        if line.startswith("/rename "):
            save_session(self.session_id, line[len("/rename "):].strip())
            self.prompt()
            return
        if line == "/resume":
            self.dialog = "picker"
            rows = "".join("\r\n %s %s" % ("❯" if i == 0 else " ", name or session_id)
                           for i, (session_id, name) in enumerate(load_sessions().items()))
            self.out("\r\n Resume Session%s\r\n\r\n Type to search · Esc to cancel\r\n" % rows)
            return
        if line.startswith("/resume "):
            wanted = line[len("/resume "):].strip()
            found = [session_id for session_id, name in load_sessions().items() if name == wanted]
            if len(found) != 1:
                self.out("\r\n No session named %s" % wanted)
            else:
                self.fire("SessionEnd", reason="resume")
                self.session_id = found[0]
                self.fire("SessionStart", source="resume")
            self.prompt()
            return
        self.fire("UserPromptSubmit", prompt=line)
        if "touch" in line:
            name = line.split("touch ")[1].split("`")[0]
            self.dialog, self.dialog_file = "permission", name
            self.fire("PreToolUse", tool_name="Bash", tool_input={"command": "touch " + name}, tool_use_id="t1")
            self.fire("PermissionRequest", tool_name="Bash", tool_input={"command": "touch " + name})
            self.out("\r\n Bash command\r\n   touch %s\r\n Do you want to proceed?\r\n ❯ 1. Yes\r\n"
                     "   2. Yes, and don't ask again for touch commands\r\n"
                     "   3. No, and tell Claude what to do differently (esc)\r\n" % name)
        elif "AskUserQuestion" in line:
            self.dialog = "question"
            questions = [{"question": "Quelle couleur ?", "header": "Couleur", "multiSelect": False,
                          "options": [{"label": "rouge"}, {"label": "bleu"}]}]
            self.fire("PreToolUse", tool_name="AskUserQuestion", tool_input={"questions": questions},
                      tool_use_id="t2")
            self.out("\r\n Quelle couleur ?\r\n ❯ 1. rouge\r\n   2. bleu\r\n   3. Type something.\r\n"
                     " Enter to select · Esc to cancel\r\n")
        else:
            self.reply()

    def answer(self, ch):
        name = self.dialog_file
        if self.dialog in ("offer", "picker"):
            if ch == "\x1b" or (self.dialog == "offer" and ch == "2"):
                if self.dialog == "offer":
                    open(".fake-offer-seen", "w").close()
                self.dialog = ""
                self.out("\x1b[2J\x1b[H")
                self.prompt()
            elif self.dialog == "offer" and not ch.startswith("\x1b"):
                self.out("\r\n Fullscreen renderer accepted: relaunching\r\n")
                self.fire("SessionEnd", reason="other")
                os._exit(3)
            return
        if ch == "1" and self.dialog == "permission":
            self.dialog = ""
            open(name, "w").close()
            self.fire("PostToolUse", tool_name="Bash", tool_input={"command": "touch " + name},
                      tool_response={"stdout": ""}, tool_use_id="t1")
            self.fire("PostToolBatch", tool_calls=[{"tool_name": "Bash", "tool_use_id": "t1"}])
            self.out("\x1b[2J\x1b[H")
            self.reply()
        elif ch == "\x1b":
            self.dialog = ""
            self.out("\x1b[2J\x1b[H  ⎿  Interrupted · What should Claude do instead?")
            self.prompt()

    def reply(self):
        self.out("\r\n⏺ OK\r\n")
        self.fire("Stop", stop_hook_active=False, last_assistant_message="OK", background_tasks=[],
                  session_crons=[])
        self.prompt()


def main():
    options, positional = parse(sys.argv[1:])
    if options.get("--version"):
        print("0.0.0 (fake TUI)")
        return
    Fake(options).start(positional)


if __name__ == "__main__":
    main()
