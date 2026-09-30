#!/usr/bin/env python3
"""Tests of the spikes harness (standard library unittest). Run: python3 Tools/spikes/test_spikes.py"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import base64  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import shlex  # noqa: E402
import stat  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import unittest  # noqa: E402
from contextlib import redirect_stdout  # noqa: E402
from pathlib import Path  # noqa: E402

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import spikes  # noqa: E402
import vtscreen  # noqa: E402

HOOKLOG = HERE / "hooklog.py"


class StripAnsiTests(unittest.TestCase):
    def test_removes_colors_and_modes(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("\x1b[1;31mrouge\x1b[0m \x1b[?2004hok"), "rouge ok")

    def test_cursor_forward_becomes_spaces(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("a\x1b[3Cb"), "a   b")

    def test_cursor_positioning_becomes_line_breaks(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("un\x1b[5;1Hdeux\x1b[Btrois"), "un\ndeux\ntrois")

    def test_osc_and_dcs_removed(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("\x1b]0;titre\x07a\x1b]8;;http://x\x1b\\b\x1bP>|x\x1b\\c"), "abc")

    def test_carriage_returns_and_controls(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("a\r\nb\rc\x07\x08d"), "a\nb\ncd")

    def test_unterminated_sequence_at_end(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("fin\x1b[3"), "fin")
        self.assertEqual(vtscreen.strip_ansi("fin\x1b]0;tit"), "fin")

    def test_collapses_blank_lines_and_trailing_spaces(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("a   \n\n\n\nb"), "a\n\nb")

    def test_keeps_unicode(self) -> None:
        self.assertEqual(vtscreen.strip_ansi("\x1b[2m❯ 1. Oui, café\x1b[22m"), "❯ 1. Oui, café")


class ScreenTests(unittest.TestCase):
    def test_print_and_cursor_position(self) -> None:
        screen = vtscreen.Screen(5, 20)
        screen.feed("bonjour\r\n\x1b[3;5Hici")
        self.assertEqual(screen.lines(), ["bonjour", "", "    ici"])

    def test_erase_line_and_display(self) -> None:
        screen = vtscreen.Screen(4, 10)
        screen.feed("abcdef\x1b[1;3H\x1b[K\r\nxyz\x1b[2J")
        self.assertEqual(screen.lines(), [])
        screen.feed("\x1b[Hab\x1b[1;1H\x1b[1K")
        self.assertEqual(screen.lines(), [" b"])

    def test_wrap_and_scroll(self) -> None:
        screen = vtscreen.Screen(2, 4)
        screen.feed("abcdefgh\r\nij")
        self.assertEqual(screen.lines(), ["efgh", "ij"])

    def test_sequence_split_across_feeds(self) -> None:
        screen = vtscreen.Screen(3, 10)
        screen.feed("a\x1b[")
        screen.feed("31mb\x1b]0;ti")
        screen.feed("tre\x07c")
        self.assertEqual(screen.text(), "abc")
        self.assertEqual(screen.titles, ["titre"])

    def test_alternate_screen(self) -> None:
        screen = vtscreen.Screen(3, 10)
        screen.feed("principal\x1b[?1049h\x1b[Halt")
        self.assertEqual(screen.text(), "alt")
        screen.feed("\x1b[?1049l")
        self.assertEqual(screen.text(), "principal")
        self.assertTrue(screen.summary()["alternate_screen_used"])

    def test_bracketed_paste_mode(self) -> None:
        screen = vtscreen.Screen()
        self.assertFalse(screen.mode(2004))
        screen.feed("\x1b[?2004h")
        self.assertTrue(screen.mode(2004))
        self.assertTrue(screen.summary()["bracketed_paste_enabled"])

    def test_query_replies_like_swiftterm(self) -> None:
        screen = vtscreen.Screen(10, 40)
        screen.feed("\x1b[3;7H\x1b[6n\x1b[c\x1b[>c\x1b[?u\x1b[?2026$p\x1b]11;?\x07")
        replies = dict(screen.take_replies())
        self.assertEqual(replies["DSR 6 (position)"], "\x1b[3;7R")
        self.assertEqual(replies["DA1"], "\x1b[?65;1;2;6;21;22;17;28c")
        self.assertEqual(replies["DA2"], "\x1b[>65;20;1c")
        self.assertEqual(replies["kitty keyboard ?"], "\x1b[?0u")
        self.assertEqual(replies["DECRQM ?2026"], "\x1b[?2026;2$y")
        self.assertTrue(replies["OSC 11 ?"].startswith("\x1b]11;rgb:"))
        self.assertEqual(screen.take_replies(), [])

    def test_kitty_keyboard_flags_stack(self) -> None:
        screen = vtscreen.Screen()
        screen.feed("\x1b[>1u")
        self.assertEqual(screen.kitty_flags, 1)
        screen.feed("\x1b[?u")
        self.assertEqual(screen.take_replies()[-1][1], "\x1b[?1u")
        screen.feed("\x1b[<u")
        self.assertEqual(screen.kitty_flags, 0)

    def test_no_replies_when_disabled(self) -> None:
        screen = vtscreen.Screen(answer_queries=False)
        screen.feed("\x1b[c")
        self.assertEqual(screen.take_replies(), [])
        self.assertEqual(screen.queries, ["DA1"])

    def test_wide_characters_and_scroll_region(self) -> None:
        screen = vtscreen.Screen(4, 10)
        screen.feed("日本\x1b[2;3r\x1b[2;1Hl2\r\nl3\r\nl4")
        self.assertEqual(screen.lines()[0], "日本")
        self.assertEqual(screen.lines()[1:3], ["l3", "l4"])

    def test_option_lines(self) -> None:
        lines = ["│ Do you want to proceed?", "│ ❯ 1. Yes", "│   2. Yes, and don't ask again", "  3. No (esc)", "x"]
        self.assertEqual(vtscreen.option_lines(lines),
                         [("1", "Yes"), ("2", "Yes, and don't ask again"), ("3", "No (esc)")])


class AnonymizerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.anon = spikes.Anonymizer(home="/Users/seraphin", user="seraphin", full_name="Séraphin Martin",
                                      host="Seraphins-MacBook-Pro.local",
                                      paths=[("/private/var/folders/ab/T/pos-spikes-1", "<tmp>"),
                                             ("/Users/seraphin/dev/pixelopenspace", "<repo>")])

    def test_paths(self) -> None:
        self.assertEqual(self.anon.text("cd /Users/seraphin/x && ls /Users/seraphin"), "cd ~/x && ls ~")
        self.assertEqual(self.anon.text("/Users/seraphin/dev/pixelopenspace/Core"), "<repo>/Core")
        self.assertEqual(self.anon.text("/private/var/folders/ab/T/pos-spikes-1/S1/projet"), "<tmp>/S1/projet")
        self.assertEqual(self.anon.text("/Users/seraphinette/x"), "/Users/seraphinette/x")

    def test_words_email_and_host(self) -> None:
        text = "Welcome back Séraphin! seraphin@example.fr's Organization on Seraphins-MacBook-Pro, SERAPHIN"
        self.assertEqual(self.anon.text(text),
                         "Welcome back <name>! <email>'s Organization on <host>, <user>")
        self.assertEqual(self.anon.text("-Users-seraphin-dev"), "-Users-<user>-dev")
        self.assertEqual(self.anon.text("seraphine"), "seraphine")

    def test_json_recursive(self) -> None:
        value = {"cwd": "/Users/seraphin/a", "list": ["seraphin", 3, None], "/Users/seraphin": True}
        self.assertEqual(self.anon.json(value), {"cwd": "~/a", "list": ["<user>", 3, None], "~": True})

    def test_bytes(self) -> None:
        self.assertEqual(self.anon.data("é /Users/seraphin/x".encode()), "é ~/x".encode())

    def test_chunks_merge_across_boundaries(self) -> None:
        chunks = [b"ok /Users/sera", b"phin/x ", b"fin"]
        merged = self.anon.chunks(chunks)
        self.assertEqual(merged, [(0, b"ok ~/x "), (2, b"fin")])
        self.assertEqual(self.anon.chunks([b"a", b"b"]), [(0, b"a"), (1, b"b")])
        self.assertEqual(self.anon.chunks([]), [])

    def test_short_user_name_is_not_replaced_as_a_word(self) -> None:
        anon = spikes.Anonymizer(home="/Users/al", user="al")
        self.assertEqual(anon.text("al va à /Users/al/x"), "al va à ~/x")

    def test_for_current_user(self) -> None:
        anon = spikes.Anonymizer.for_current_user()
        self.assertEqual(anon.text(os.path.expanduser("~") + "/x"), "~/x")


class HooklogTests(unittest.TestCase):
    def run_hooklog(self, stdin: bytes, log: str | None, tag: str = "app") -> subprocess.CompletedProcess:
        env = {key: value for key, value in os.environ.items() if key != "PIXEL_SPIKE_LOG"}
        if log is not None:
            env["PIXEL_SPIKE_LOG"] = log
        env["PIXEL_SPIKE_TAG"] = "S1/lancement-1"
        return subprocess.run([sys.executable, str(HOOKLOG), "--tag", tag], input=stdin, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env, timeout=20, check=False)

    def test_appends_one_line_and_prints_nothing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "events.jsonl")
            hook = {"session_id": "abc", "hook_event_name": "Stop", "cwd": tmp, "texte": "é"}
            for _ in range(2):
                done = self.run_hooklog(json.dumps(hook).encode(), log)
                self.assertEqual((done.returncode, done.stdout, done.stderr), (0, b"", b""))
            with open(log, encoding="utf-8") as handle:
                records = [json.loads(line) for line in handle]
            self.assertEqual(len(records), 2)
            record = records[0]
            self.assertEqual(record["event"], "Stop")
            self.assertEqual(record["tag"], "app")
            self.assertEqual(record["spike_tag"], "S1/lancement-1")
            self.assertEqual(record["hook"], hook)
            self.assertIsInstance(record["ts_mono_ns"], int)
            self.assertIsInstance(record["ppid_chain"], list)
            self.assertEqual(record["ppid_chain"][0]["pid"], os.getpid())
            self.assertEqual(stat.S_IMODE(os.stat(log).st_mode), 0o600)

    def test_garbage_stdin(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "events.jsonl")
            done = self.run_hooklog(b"\xff\xfenot json", log)
            self.assertEqual((done.returncode, done.stdout, done.stderr), (0, b"", b""))
            with open(log, encoding="utf-8") as handle:
                record = json.loads(handle.readline())
            self.assertTrue(record["hook"]["_unparsed"])
            self.assertEqual(record["hook"]["len"], 10)
            self.assertIsNone(record["event"])

    def test_json_that_is_not_an_object(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "events.jsonl")
            done = self.run_hooklog(b"[1, 2]", log)
            self.assertEqual(done.returncode, 0)
            with open(log, encoding="utf-8") as handle:
                self.assertEqual(json.loads(handle.readline())["hook"], [1, 2])

    def test_no_log_variable_or_unwritable_log(self) -> None:
        done = self.run_hooklog(b"{}", None)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, b"", b""))
        done = self.run_hooklog(b"{}", "/nonexistent-dir/events.jsonl")
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, b"", b""))

    def test_large_stdin_is_read_to_the_end(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "events.jsonl")
            big = json.dumps({"hook_event_name": "PostToolUse", "tool_response": "x" * 3_000_000}).encode()
            done = self.run_hooklog(big, log)
            self.assertEqual(done.returncode, 0)
            with open(log, encoding="utf-8") as handle:
                self.assertEqual(json.loads(handle.readline())["stdin_len"], len(big))

    def test_parallel_hooks_write_whole_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = os.path.join(tmp, "events.jsonl")
            env = dict(os.environ, PIXEL_SPIKE_LOG=log)
            payload = json.dumps({"hook_event_name": "PostToolUse", "tool_response": "y" * 50_000}).encode()
            procs = [subprocess.Popen([sys.executable, str(HOOKLOG), "--tag", "t%d" % i], stdin=subprocess.PIPE,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
                     for i in range(8)]
            for proc in procs:
                proc.communicate(payload, timeout=20)
            with open(log, encoding="utf-8") as handle:
                tags = sorted(json.loads(line)["tag"] for line in handle)
            self.assertEqual(tags, sorted("t%d" % i for i in range(8)))


class SettingsTests(unittest.TestCase):
    def test_app_hook_block(self) -> None:
        settings = spikes.build_hook_settings("cmd")
        self.assertEqual(list(settings["hooks"]), list(spikes.APP_HOOK_EVENTS))
        self.assertEqual(len(settings["hooks"]), 19)
        for groups in settings["hooks"].values():
            self.assertEqual(groups, [{"hooks": [{"type": "command", "command": "cmd", "timeout": 3}]}])
        json.dumps(settings)

    def test_subset_for_project_local(self) -> None:
        settings = spikes.build_hook_settings("c", events=("SessionStart", "UserPromptSubmit"))
        self.assertEqual(sorted(settings["hooks"]), ["SessionStart", "UserPromptSubmit"])

    def test_command_quoting_round_trips(self) -> None:
        python = "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"
        hooklog = "/Users/l'été/Mes projets/pixel open space/hooklog.py"
        command = spikes.hook_command(python, hooklog, "project-local")
        self.assertEqual(shlex.split(command), [python, hooklog, "--tag", "project-local"])

    def test_generated_command_runs_hooklog(self) -> None:
        with tempfile.TemporaryDirectory(prefix="dossier avec espace '") as tmp:
            copy = Path(tmp) / "hook log.py"
            copy.write_bytes(HOOKLOG.read_bytes())
            log = Path(tmp) / "events.jsonl"
            command = spikes.hook_command(sys.executable, str(copy), "app")
            done = subprocess.run(["/bin/sh", "-c", command], input=b'{"hook_event_name":"SessionStart"}',
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  env=dict(os.environ, PIXEL_SPIKE_LOG=str(log)), timeout=20, check=False)
            self.assertEqual((done.returncode, done.stdout, done.stderr), (0, b"", b""))
            self.assertEqual(json.loads(log.read_text(encoding="utf-8"))["event"], "SessionStart")


class HelperTests(unittest.TestCase):
    def test_percentiles(self) -> None:
        values = list(range(1, 101))
        self.assertEqual(spikes.percentiles(values), {"n": 100, "min": 1, "p50": 50, "p95": 95, "max": 100})
        self.assertEqual(spikes.percentiles([]), {"n": 0})
        self.assertEqual(spikes.percentiles([7.25])["p95"], 7.2)

    def test_paste_body(self) -> None:
        body = spikes.paste_body(1200)
        self.assertEqual(len(body), 1200)
        self.assertTrue(body.endswith("Réponds juste OK."))
        self.assertGreater(body.count("\n"), 5)
        self.assertNotIn("\x1b", body)

    def test_select_scenarios(self) -> None:
        ids = lambda only, opt=False: [s.id for s in spikes.select_scenarios(only, opt)]  # noqa: E731
        self.assertNotIn("S3b-background", ids(None))
        self.assertIn("S3b-background", ids(None, True))
        self.assertEqual(ids("S3.a"), ["S3.a-30ms", "S3.a-120ms", "S3.a-250ms"])
        self.assertEqual(len(ids("S3")), 7)
        self.assertEqual(ids("s1,S3b"), ["S1", "S3b-background"])
        self.assertEqual(ids("S10"), [])

    def test_visible(self) -> None:
        self.assertEqual(spikes.visible("é\r\n\x1b[200~"), "é\\r\\n\\x1b[200~")

    def test_event_log_tails_partial_lines(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "e.jsonl"
            log = spikes.EventLog(path)
            self.assertEqual(log.poll(), 0)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write('{"event":"A"}\n{"event":"B"')
            self.assertEqual(log.poll(), 1)
            with open(path, "a", encoding="utf-8") as handle:
                handle.write('}\nnot json\n')
            self.assertEqual(log.poll(), 2)
            self.assertEqual(log.find("B"), 1)
            self.assertEqual(log.find(["A", "B"], start=1), 1)
            self.assertIsNone(log.find("A", start=1))
            self.assertIn("_bad_line", log.events[2])

    def test_summary_tolerates_missing_results(self) -> None:
        results = [{"notes": {"id": "S1", "title": "t", "status": "erreur", "error": "x", "launches": []},
                    "events": [], "screens": []}]
        text = spikes.build_summary({"date": "d", "model": "haiku"}, results)
        self.assertIn("## S1", text)
        self.assertIn("## S10", text)


@unittest.skipUnless(sys.platform in ("darwin", "linux"), "needs a POSIX pty")
class EndToEndTests(unittest.TestCase):
    """Runs the real harness against fake_tui.py, a small stand-in for the claude TUI."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = tempfile.TemporaryDirectory()
        fake = HERE / "fake_tui.py"
        mode = os.stat(fake).st_mode
        if not mode & stat.S_IXUSR:
            os.chmod(fake, mode | stat.S_IXUSR)
        only = "S1,S2,S3.a-250ms,S3.b,S3.c,S3.d,S3.e,S4,S5,S7"
        args = spikes.parse_args(["--yes", "--claude", str(fake), "--only", only, "--results-dir", cls.tmp.name,
                                  "--timeout", "60"])
        cls.harness = spikes.Harness(args, str(fake))
        output = io.StringIO()
        with redirect_stdout(output):
            cls.code = cls.harness.run()
        cls.output = output.getvalue()
        cls.out = cls.harness.out_root

    @classmethod
    def tearDownClass(cls) -> None:
        cls.tmp.cleanup()

    def notes(self, sid: str) -> dict:
        return json.loads((self.out / sid / "notes.json").read_text(encoding="utf-8"))

    def test_all_scenarios_ok(self) -> None:
        self.assertEqual(self.code, 0, self.output)
        for sid in ("S1", "S2", "S3.a-250ms", "S3.b-lf", "S3.c-paste", "S3.d-positional", "S3.e-permission", "S4",
                    "S5", "S7"):
            self.assertEqual(self.notes(sid)["status"], "ok", "%s\n%s" % (sid, self.output))
        self.assertIn("git add Tools/spikes/results", self.output)
        self.assertFalse(self.harness.tmp_root.exists())

    def test_outputs_written(self) -> None:
        summary = (self.out / "summary.md").read_text(encoding="utf-8")
        self.assertIn("**OUI**, les deux sources", summary)
        env = json.loads((self.out / "environment.json").read_text(encoding="utf-8"))
        self.assertEqual(env["claude_version"], "0.0.0 (fake TUI)")
        folder = self.out / "S1"
        for name in ("events.jsonl", "pty.jsonl", "transcript.txt", "notes.json"):
            self.assertTrue((folder / name).exists(), name)
        self.assertTrue(list((folder / "screens").iterdir()))
        records = [json.loads(line) for line in (folder / "pty.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertTrue(any(r["dir"] == "in" and r.get("text") == "\r" for r in records))
        output = b"".join(base64.b64decode(r["b64"]) for r in records if r["dir"] == "out")
        self.assertIn(b"Accessing workspace", output)
        home = os.path.expanduser("~")
        for path in self.out.rglob("*"):
            if path.is_file() and len(home) > 1:
                self.assertNotIn(home + "/", path.read_text(encoding="utf-8", errors="replace"), str(path))

    def test_s1_s2_s10(self) -> None:
        s1 = self.notes("S1")
        self.assertTrue(s1["answer"]["merged"])
        launch = s1["launches"][0]
        self.assertTrue(launch["trust_dialog"])
        self.assertEqual(launch["hooks_before_trust_accept"], [])
        # "No, exit" comes first and focused (Claude Code 2.1.285): one Down before Enter.
        self.assertEqual(launch["trust_focus"], ["No, exit", "Yes, I trust this folder"])
        self.assertEqual(launch["trust_moves"], 1)
        s2 = self.notes("S2")["answer"]
        self.assertTrue(s2["equal"])
        self.assertEqual(s2["hangup"]["session_end_reason"], "other")

    def test_s3_input(self) -> None:
        a = self.notes("S3.a-250ms")["answer"]
        self.assertTrue(a["user_prompt_submit"] and a["exact"] and a["stop"])
        b = self.notes("S3.b-lf")["answer"]
        self.assertTrue(b["contains_newline"])
        c = self.notes("S3.c-paste")["answer"]
        self.assertTrue(c["esc_2004h_seen"] and c["paste_sent"] and c["pasted_placeholder_on_screen"])
        self.assertTrue(c["starts_with_lead"] and c["contains_body_exactly"])
        d = self.notes("S3.d-positional")["answer"]
        self.assertTrue(d["user_prompt_submit"] and d["exact"])

    def test_s3e_permission_and_chain(self) -> None:
        a = self.notes("S3.e-permission")["answer"]
        self.assertTrue(a["permission_request"])
        self.assertEqual(a["dialog_options"][0], ["1", "Yes"])
        self.assertTrue(a["digit_alone_answers"])
        self.assertTrue(a["file_created"])
        self.assertTrue(a["chain"]["user_prompt_submit"])
        self.assertEqual([e["event"] for e in a["events_after_key"]], ["PostToolUse", "PostToolBatch", "Stop"])

    def test_s4_session_ids(self) -> None:
        answer = self.notes("S4")["answer"]
        self.assertEqual(answer["derived"], {
            "startup_id_is_requested": True, "clear_changes_id": True, "clear_source": "clear",
            "compact_keeps_id": True, "compact_source": "compact", "resume_in_session_returns_to_first_id": True,
            "resume_in_session_source": "resume", "resume_keeps_id": True, "resume_source": "resume",
            "fork_new_id": True, "fork_source": "fork", "worktree_cwd_is_a_worktree": True})
        self.assertTrue(answer["worktree"]["session_start_cwd"].endswith("/S4/projet/.claude/worktrees/spike-s4"))
        self.assertEqual(answer["resume_picker"]["focused"], "pos-spike-s4")

    def test_startup_dialogs_are_dismissed_before_typing(self) -> None:
        # The fake exits with status 3 if its fullscreen offer is accepted: every scenario would fail.
        dialogs = [dialog for sid in ("S1", "S3.d-positional", "S4")
                   for launch in self.notes(sid)["launches"] for dialog in launch.get("startup_dialogs", [])]
        self.assertGreaterEqual(len(dialogs), 3)
        for dialog in dialogs:
            self.assertEqual(dialog["title"], "Try the new fullscreen renderer?")
            self.assertEqual(dialog["focused"], "Yes, try it")
        summary = (self.out / "summary.md").read_text(encoding="utf-8")
        self.assertIn("Try the new fullscreen renderer? (en surbrillance : Yes, try it)", summary)

    def test_spike_settings_force_the_permission_dialog(self) -> None:
        settings = self.harness.spike_settings()
        self.assertEqual(settings["permissions"], {"ask": ["Bash(touch *)"]})
        self.assertEqual(list(settings["hooks"]), list(spikes.APP_HOOK_EVENTS))
        env = json.loads((self.out / "environment.json").read_text(encoding="utf-8"))
        self.assertEqual(env["permission_request_missing"], [])

    def test_s5_and_s7_escape(self) -> None:
        s5 = self.notes("S5")["answer"]
        self.assertTrue(s5["permission_request"])
        self.assertFalse(s5["file_created"])
        self.assertFalse(s5["fired"]["Stop"])
        s7 = self.notes("S7")["answer"]
        self.assertTrue(s7["ask_user_question"])
        self.assertEqual([o[1] for o in s7["options"]][:2], ["rouge", "bleu"])


class DialogHelperTests(unittest.TestCase):
    def test_focused_option(self) -> None:
        lines = ["Accessing workspace:", " ❯ No, exit", "   Yes, I trust this folder"]
        self.assertEqual(spikes.focused_option(lines), "No, exit")
        self.assertEqual(spikes.focused_option(["│  ❯ 1. Yes, try it   │", "    2. Not now"]), "Yes, try it")
        self.assertIsNone(spikes.focused_option(["   1. Yes", "   2. No"]))

    def test_trust_confirm_option(self) -> None:
        for label in ("Yes, I trust this folder", "Yes, proceed", "yes i trust this folder"):
            self.assertTrue(spikes.TRUST_CONFIRM_RE.search(label), label)
        for label in ("No, exit", "No, continue without these permissions", "Yes, try it"):
            self.assertFalse(spikes.TRUST_CONFIRM_RE.search(label), label)

    def test_dialog_title(self) -> None:
        lines = ["─" * 40, "  Try the new fullscreen renderer?", "", "  · Flicker-free output", "  · Mouse support",
                 "", "  ❯ 1. Yes, try it", "    2. Not now", "", "  Enter to confirm · Esc to cancel"]
        self.assertEqual(spikes.dialog_title(lines), "Try the new fullscreen renderer?")
        self.assertIsNone(spikes.dialog_title(["❯ ", "Aide ?"]))
        # A numbered line above the dialog (a tip) is not its option.
        self.assertEqual(spikes.dialog_title(["1. Tip one", "Use this API key?", "❯ No (recommended)", "  Yes"]),
                         "Use this API key?")


class _StubSession:
    """The parts of PtySession that exit_session uses."""

    def __init__(self) -> None:
        self.label = "s"
        self.exited = False
        self.eof = False
        self.exit_status = None
        self.info: dict = {}
        self.sent: list = []
        self.closed = False
        self.screen = vtscreen.Screen(5, 40)

    def screen_has(self, pattern) -> bool:
        return bool(pattern.search(self.screen.text()))

    def send(self, data: bytes, label: str) -> int:
        self.sent.append(data)
        if data == b"\r" and self.sent[-2:-1] == [b"/exit"]:
            self.exited = True
        return spikes.mono_ns()

    def pump(self, timeout: float, until=None) -> bool:
        return bool(until and until())

    def close(self) -> None:
        self.closed = True


class ExitSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        harness = argparse.Namespace(tmp_root=Path(self.tmp.name),
                                     args=argparse.Namespace(timeout=30.0, verbose=False))
        self.ctx = spikes.ScenarioContext(harness, spikes.Scenario("SX", "test", lambda ctx: None))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_clears_the_line_before_exit(self) -> None:
        session = _StubSession()
        result = self.ctx.exit_session(session)
        self.assertEqual(session.sent, [b"\x15", b"/exit", b"\r"])
        self.assertEqual(result["method"], "/exit")
        self.assertTrue(session.closed)

    def test_text_left_in_the_input_box_is_never_sent(self) -> None:
        session = _StubSession()
        session.info["input_left"] = True
        result = self.ctx.exit_session(session)
        self.assertEqual(session.sent, [])
        self.assertTrue(result["method"].startswith("SIGTERM"))
        self.assertTrue(session.closed)

    def test_dialog_on_screen_is_never_answered(self) -> None:
        session = _StubSession()
        session.screen.feed("Do you want to proceed?\r\n ❯ 1. Yes")
        self.assertEqual(self.ctx.exit_session(session)["method"], "SIGTERM (dialogue à l'écran)")
        self.assertEqual(session.sent, [])


class SummaryVerdictTests(unittest.TestCase):
    @staticmethod
    def summary(launches: list) -> str:
        results = [{"notes": {"id": "S1", "title": "t", "status": "ok", "launches": launches}, "events": [],
                    "screens": []}]
        return spikes.build_summary({"date": "d", "model": "haiku"}, results)

    def test_s10_ignores_launches_that_never_started(self) -> None:
        failed = {"label": "l1", "trust_dialog": True, "hooks_before_trust_accept": [], "startup_failed": True}
        text = self.summary([failed])
        self.assertIn("**Non concluant**", text)
        self.assertNotIn("**NON**", text)
        started = {"label": "l2", "trust_dialog": True, "hooks_before_trust_accept": [], "session_start": {},
                   "trust_moves": 1}
        text = self.summary([failed, started])
        self.assertIn("**NON** : aucun hook avant l'acceptation, sur 1 lancement(s)", text)
        self.assertIn("Non concluant(s) (dialogue vu, pas de SessionStart ensuite) : S1 / l1.", text)

    def test_s10_early_hook_is_a_yes(self) -> None:
        early = {"label": "l1", "trust_dialog": True, "startup_failed": True,
                 "hooks_before_trust_accept": [{"event": "SessionStart"}]}
        self.assertIn("**OUI** dans 1 lancement(s) sur 1", self.summary([early]))

    def test_uncovered_questions_are_listed(self) -> None:
        text = self.summary([])
        for item in ("S8", "S11", "limite d'usage", "chaque option"):
            self.assertIn(item, text)


@unittest.skipUnless(sys.platform in ("darwin", "linux"), "needs a POSIX pty")
class FakeTuiTests(unittest.TestCase):
    """The fake's trust dialog behaves as Claude Code 2.1.285's: Enter alone refuses and quits."""

    def run_keys(self, keys: list) -> tuple:
        import pty
        import select
        import time
        with tempfile.TemporaryDirectory() as tmp:
            settings = Path(tmp) / "settings.json"
            settings.write_text("{}", encoding="utf-8")
            pid, fd = pty.fork()
            if pid == 0:  # pragma: no cover - child
                os.chdir(tmp)
                os.execv(sys.executable, [sys.executable, str(HERE / "fake_tui.py"), "--settings", str(settings)])
            output = b""

            def pump(seconds: float) -> None:
                nonlocal output
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    ready, _, _ = select.select([fd], [], [], 0.05)
                    if ready:
                        try:
                            output += os.read(fd, 65536)
                        except OSError:
                            return

            pump(1.5)
            for key in keys:
                os.write(fd, key)
                pump(0.5)
            finished, status = os.waitpid(pid, os.WNOHANG)
            if not finished:
                os.kill(pid, 9)
                os.waitpid(pid, 0)
            os.close(fd)
            trusted = (Path(tmp) / ".fake-trusted").exists()
            return (os.waitstatus_to_exitcode(status) if finished else None), trusted, output

    def test_enter_alone_refuses(self) -> None:
        code, trusted, output = self.run_keys([b"\r"])
        self.assertIn("❯ No, exit".encode(), output)
        self.assertEqual((code, trusted), (1, False))

    def test_down_then_enter_trusts(self) -> None:
        code, trusted, _ = self.run_keys([b"1", b"\x1b[B", b"\r"])
        self.assertEqual((code, trusted), (None, True))


class CommandLineTests(unittest.TestCase):
    def test_list(self) -> None:
        done = subprocess.run([sys.executable, str(HERE / "spikes.py"), "--list"], stdout=subprocess.PIPE,
                              timeout=30, check=False)
        self.assertEqual(done.returncode, 0)
        self.assertIn(b"S3.e-permission", done.stdout)

    def test_parse_args_defaults(self) -> None:
        args = spikes.parse_args([])
        self.assertIsInstance(args, argparse.Namespace)
        self.assertEqual((args.model, args.timeout, args.yes), ("haiku", 90.0, False))


if __name__ == "__main__":
    unittest.main(verbosity=2)
