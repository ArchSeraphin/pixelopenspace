"""Minimal xterm screen model and ANSI stripper for the spikes harness (Python 3.9+, standard library only).

Just enough of xterm to turn Claude Code's TUI output into readable screen snapshots: cursor movement, erasing,
scroll regions, the alternate screen, and the replies a real terminal sends to common queries. The replies mirror
SwiftTerm, the terminal the app embeds, so `claude` behaves here as it will in the app. Colors and attributes are
ignored.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Dict, List, Optional, Tuple

# Complete sequences, tried in this order at each ESC.
_CSI_RE = re.compile(r"\x1b\[([<=>?]?)([0-9;:]*)([ -/]*)([@-~])")
_OSC_RE = re.compile(r"\x1b\](.*?)(?:\x07|\x1b\\)", re.S)
_STRING_RE = re.compile(r"\x1b[P^_X].*?\x1b\\", re.S)  # DCS, PM, APC, SOS
# ESC 7, ESC M, charset designations, ... (not the introducers of CSI, OSC and string sequences)
_ESC_RE = re.compile(r"\x1b(?:[ -/]+[0-~]|[0-OQ-WYZ\\`-~])")
# A sequence cut at the end of a chunk: kept until the next chunk arrives.
_INCOMPLETE_RE = re.compile(r"\x1b(?:\[[<=>?]?[0-9;:]*[ -/]*|\][^\x07]*|[P^_X].*|[ -/]*)?\Z", re.S)
_MAX_PENDING = 65536

_STRIP_RE = re.compile(
    r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\|\Z)"  # OSC
    r"|\x1b[P^_X].*?(?:\x1b\\|\Z)"  # DCS, PM, APC, SOS
    r"|\x1b\[[<=>?]?[0-9;:]*[ -/]*[@-~]?"  # CSI
    r"|\x1b[ -/]*[0-~]?",  # other escapes, or a lone ESC
    re.S,
)
_CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\x80-\x9f]")
_BLANK_LINES_RE = re.compile(r"\n{3,}")

# DEC private modes whose state we track, for DECRQM replies (1 = set, 2 = reset, 0 = unknown).
_KNOWN_PRIVATE_MODES = {1, 6, 7, 12, 25, 47, 1000, 1002, 1003, 1004, 1006, 1047, 1049, 2004, 2026}
_DEFAULT_PRIVATE_MODES = {7: True, 25: True}

# SwiftTerm's answers for TERM=xterm-256color (Terminal.swift: cmdSendDeviceAttributes, cmdDeviceStatus, ...).
_DA1_REPLY = "\x1b[?65;1;2;6;21;22;17;28c"
_DA2_REPLY = "\x1b[>65;20;1c"
_XTVERSION_REPLY = "\x1bP>|SwiftTerm\x1b\\"
_FOREGROUND = "rgb:e5e5/e5e5/e5e5"
_BACKGROUND = "rgb:1e1e/1e1e/1e1e"
_CELL_W, _CELL_H = 8, 16


def strip_ansi(text: str) -> str:
    """Plain text from terminal output: escape sequences removed, cursor moves turned into spaces or line breaks.

    Good enough to search a TUI's output with a regular expression; use `Screen` for what is actually visible.
    """

    def replace(match: "re.Match[str]") -> str:
        seq = match.group(0)
        if not seq.startswith("\x1b[") or len(seq) < 3:
            return ""
        final = seq[-1]
        if final == "C":  # cursor forward: renderers use it in place of spaces
            params = seq[2:-1]
            count = int(params) if params.isdigit() else 1
            return " " * min(max(count, 1), 400)
        if final in "HfABEFd":
            return "\n"
        if final == "G":
            return " "
        return ""

    text = _STRIP_RE.sub(replace, text)
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", "    ")
    text = _CONTROL_RE.sub("", text)
    text = "\n".join(line.rstrip() for line in text.split("\n"))
    return _BLANK_LINES_RE.sub("\n\n", text)


def char_width(ch: str) -> int:
    """Terminal cells taken by one code point: 0 (combining, zero-width), 1, or 2 (wide)."""
    code = ord(ch)
    if code in (0x200B, 0x200C, 0x200D, 0x2060, 0xFE0E, 0xFE0F) or unicodedata.combining(ch):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


class Screen:
    """A rows x cols character grid fed with terminal output.

    `replies` collects (label, text) answers to terminal queries; the harness writes them back to the PTY.
    `queries`, `private_modes_seen`, `titles` and `kitty_flags_history` describe what the program asked for.
    """

    def __init__(self, rows: int = 36, cols: int = 120, answer_queries: bool = True) -> None:
        self.rows = rows
        self.cols = cols
        self.answer_queries = answer_queries
        self.replies: List[Tuple[str, str]] = []
        self.queries: List[str] = []
        self.private_modes_seen: List[str] = []
        self.titles: List[str] = []
        self.osc_codes: List[str] = []
        self.kitty_flags_history: List[int] = []
        self._pending = ""
        self.reset()

    # Public state -------------------------------------------------------------------------------------------

    def reset(self) -> None:
        self._main = self._blank_grid()
        self._alt = self._blank_grid()
        self.grid = self._main
        self.alt_active = False
        self.cx = 0
        self.cy = 0
        self.top = 0
        self.bottom = self.rows - 1
        self.wrap_pending = False
        self.private_modes: Dict[int, bool] = dict(_DEFAULT_PRIVATE_MODES)
        self._saved_cursor = (0, 0)
        self._kitty_stack: List[int] = [0]

    def mode(self, number: int) -> bool:
        """Whether DEC private mode `number` is currently set (2004 = bracketed paste, 1049 = alternate screen)."""
        return self.private_modes.get(number, False)

    @property
    def kitty_flags(self) -> int:
        return self._kitty_stack[-1]

    def lines(self) -> List[str]:
        """Visible rows, right-trimmed, without trailing blank rows."""
        rows = ["".join(row).rstrip() for row in self.grid]
        while rows and not rows[-1]:
            rows.pop()
        return rows

    def text(self) -> str:
        return "\n".join(self.lines())

    def take_replies(self) -> List[Tuple[str, str]]:
        replies, self.replies = self.replies, []
        return replies

    # Parser ------------------------------------------------------------------------------------------------

    def feed(self, text: str) -> None:
        data = self._pending + text
        self._pending = ""
        i = 0
        n = len(data)
        while i < n:
            ch = data[i]
            if ch == "\x1b":
                match = (
                    _CSI_RE.match(data, i)
                    or _OSC_RE.match(data, i)
                    or _STRING_RE.match(data, i)
                    or _ESC_RE.match(data, i)
                )
                if match is None:
                    if _INCOMPLETE_RE.match(data, i) and n - i < _MAX_PENDING:
                        self._pending = data[i:]
                        return
                    i += 1  # malformed: drop the ESC and go on
                    continue
                self._escape(match)
                i = match.end()
                continue
            if ch < " " or ch == "\x7f":
                self._control(ch)
            elif "\x80" <= ch <= "\x9f":
                pass  # C1 controls: not used by modern programs in UTF-8
            else:
                self._print(ch)
            i += 1

    def _escape(self, match: "re.Match[str]") -> None:
        seq = match.group(0)
        if seq.startswith("\x1b["):
            self._csi(match.group(1), match.group(2), match.group(3), match.group(4))
        elif seq.startswith("\x1b]"):
            self._osc(match.group(1))
        elif seq[1] in "P^_X":
            pass
        else:
            self._esc(seq[1:])

    # Printing and controls ---------------------------------------------------------------------------------

    def _blank_row(self) -> List[str]:
        return [" "] * self.cols

    def _blank_grid(self) -> List[List[str]]:
        return [self._blank_row() for _ in range(self.rows)]

    def _print(self, ch: str) -> None:
        width = char_width(ch)
        if width == 0:
            col = self.cx - 1 if self.cx > 0 and not self.wrap_pending else self.cx
            if self.grid[self.cy][col] not in ("",):
                self.grid[self.cy][col] += ch
            return
        if self.wrap_pending:
            self.wrap_pending = False
            if self.mode(7):
                self.cx = 0
                self._linefeed()
        if width == 2 and self.cx == self.cols - 1:
            if self.mode(7):
                self.grid[self.cy][self.cx] = " "
                self.cx = 0
                self._linefeed()
            else:
                width = 1
        row = self.grid[self.cy]
        row[self.cx] = ch
        if width == 2:
            row[self.cx + 1] = ""
        self.cx += width
        if self.cx >= self.cols:
            self.cx = self.cols - 1
            self.wrap_pending = True

    def _control(self, ch: str) -> None:
        if ch == "\r":
            self.cx = 0
            self.wrap_pending = False
        elif ch in "\n\x0b\x0c":
            self._linefeed()
        elif ch == "\b":
            self.wrap_pending = False
            self.cx = max(0, self.cx - 1)
        elif ch == "\t":
            self.cx = min(self.cols - 1, (self.cx // 8 + 1) * 8)
        # BEL, SO, SI and the rest: nothing to draw.

    def _linefeed(self) -> None:
        self.wrap_pending = False
        if self.cy == self.bottom:
            self._scroll_up(1)
        elif self.cy < self.rows - 1:
            self.cy += 1

    def _scroll_up(self, count: int) -> None:
        for _ in range(min(count, self.bottom - self.top + 1)):
            del self.grid[self.top]
            self.grid.insert(self.bottom, self._blank_row())

    def _scroll_down(self, count: int) -> None:
        for _ in range(min(count, self.bottom - self.top + 1)):
            del self.grid[self.bottom]
            self.grid.insert(self.top, self._blank_row())

    def _esc(self, body: str) -> None:
        if body == "7":
            self._saved_cursor = (self.cy, self.cx)
        elif body == "8":
            self.cy, self.cx = self._saved_cursor
            self.wrap_pending = False
        elif body == "D":
            self._linefeed()
        elif body == "E":
            self.cx = 0
            self._linefeed()
        elif body == "M":
            self.wrap_pending = False
            if self.cy == self.top:
                self._scroll_down(1)
            elif self.cy > 0:
                self.cy -= 1
        elif body == "c":
            self.reset()
        # Charset designations and keypad modes (ESC ( B, ESC =, ESC >) change nothing we render.

    # CSI ---------------------------------------------------------------------------------------------------

    @staticmethod
    def _params(raw: str) -> List[int]:
        values = []
        for part in raw.split(";") if raw else []:
            head = part.split(":")[0]
            values.append(int(head) if head.isdigit() else 0)
        return values

    def _reply(self, label: str, text: str) -> None:
        self.queries.append(label)
        if self.answer_queries:
            self.replies.append((label, text))

    def _csi(self, prefix: str, raw: str, inter: str, final: str) -> None:
        params = self._params(raw)

        def arg(index: int = 0, default: int = 1) -> int:
            value = params[index] if index < len(params) else 0
            return value if value > 0 else default

        if prefix == "?" and final in "hl" and not inter:
            for number in params:
                self._set_private_mode(number, final == "h")
            return
        if inter == "$" and final == "p":  # DECRQM
            number = arg(0, 0)
            if prefix == "?":
                state = (1 if self.mode(number) else 2) if number in _KNOWN_PRIVATE_MODES else 0
                self._reply("DECRQM ?%d" % number, "\x1b[?%d;%d$y" % (number, state))
            else:
                self._reply("DECRQM %d" % number, "\x1b[%d;0$y" % number)
            return
        if final == "u" and prefix in "?><=" and prefix:
            self._kitty(prefix, params)
            return
        if final == "c" and not inter:
            if prefix == "" and arg(0, 0) == 0:
                self._reply("DA1", _DA1_REPLY)
            elif prefix == ">" and arg(0, 0) == 0:
                self._reply("DA2", _DA2_REPLY)
            return
        if final == "q" and prefix == ">" and not inter:
            self._reply("XTVERSION", _XTVERSION_REPLY)
            return
        if final == "n" and not inter:
            self._device_status(prefix, arg(0, 0))
            return
        if final == "t" and not prefix and not inter:
            self._window_report(arg(0, 0))
            return
        if prefix or inter:
            return  # cursor style, private SGR, and the like

        rows, cols = self.rows, self.cols
        if final in "A":
            self.cy = max(self.top if self.cy >= self.top else 0, self.cy - arg())
        elif final == "B" or final == "e":
            self.cy = min(self.bottom if self.cy <= self.bottom else rows - 1, self.cy + arg())
        elif final == "C" or final == "a":
            self.cx = min(cols - 1, self.cx + arg())
        elif final == "D":
            self.cx = max(0, self.cx - arg())
        elif final == "E":
            self.cy = min(rows - 1, self.cy + arg())
            self.cx = 0
        elif final == "F":
            self.cy = max(0, self.cy - arg())
            self.cx = 0
        elif final in "G`":
            self.cx = min(cols - 1, arg() - 1)
        elif final in "Hf":
            self.cy = min(rows - 1, arg(0) - 1)
            self.cx = min(cols - 1, arg(1) - 1)
        elif final == "d":
            self.cy = min(rows - 1, arg() - 1)
        elif final == "J":
            self._erase_display(arg(0, 0))
        elif final == "K":
            self._erase_line(arg(0, 0))
        elif final == "X":
            row = self.grid[self.cy]
            for col in range(self.cx, min(cols, self.cx + arg())):
                row[col] = " "
        elif final == "P":
            row = self.grid[self.cy]
            count = min(arg(), cols - self.cx)
            del row[self.cx:self.cx + count]
            row.extend([" "] * count)
        elif final == "@":
            row = self.grid[self.cy]
            count = min(arg(), cols - self.cx)
            row[self.cx:self.cx] = [" "] * count
            del row[cols:]
        elif final == "L":
            if self.top <= self.cy <= self.bottom:
                for _ in range(min(arg(), self.bottom - self.cy + 1)):
                    del self.grid[self.bottom]
                    self.grid.insert(self.cy, self._blank_row())
        elif final == "M":
            if self.top <= self.cy <= self.bottom:
                for _ in range(min(arg(), self.bottom - self.cy + 1)):
                    del self.grid[self.cy]
                    self.grid.insert(self.bottom, self._blank_row())
        elif final == "S":
            self._scroll_up(arg())
        elif final == "T" and len(params) <= 1:
            self._scroll_down(arg())
        elif final == "r":
            top = arg(0) - 1
            bottom = (params[1] if len(params) > 1 and params[1] > 0 else rows) - 1
            if 0 <= top < bottom < rows:
                self.top, self.bottom = top, bottom
                self.cy, self.cx = 0, 0
        elif final == "s":
            self._saved_cursor = (self.cy, self.cx)
        elif final == "u":
            self.cy, self.cx = self._saved_cursor
        # SGR (m) and everything else: no effect on the text.
        if final not in "m":
            self.wrap_pending = False

    def _set_private_mode(self, number: int, on: bool) -> None:
        self.private_modes_seen.append("?%d%s" % (number, "h" if on else "l"))
        was_alt = self.alt_active
        if number in (47, 1047, 1049):
            if on and not was_alt:
                if number == 1049:
                    self._saved_cursor = (self.cy, self.cx)
                self._alt = self._blank_grid()
                self.grid = self._alt
                self.alt_active = True
            elif not on and was_alt:
                self.grid = self._main
                self.alt_active = False
                if number == 1049:
                    self.cy, self.cx = self._saved_cursor
            self.top, self.bottom = 0, self.rows - 1
        self.private_modes[number] = on

    def _kitty(self, prefix: str, params: List[int]) -> None:
        if prefix == "?":
            self._reply("kitty keyboard ?", "\x1b[?%du" % self.kitty_flags)
            return
        if prefix == ">":
            self._kitty_stack.append(params[0] if params else 0)
        elif prefix == "<":
            count = params[0] if params and params[0] > 0 else 1
            for _ in range(count):
                if len(self._kitty_stack) > 1:
                    self._kitty_stack.pop()
        elif prefix == "=":
            flags = params[0] if params else 0
            how = params[1] if len(params) > 1 else 1
            if how == 1:
                self._kitty_stack[-1] = flags
            elif how == 2:
                self._kitty_stack[-1] |= flags
            elif how == 3:
                self._kitty_stack[-1] &= ~flags
        self.kitty_flags_history.append(self.kitty_flags)

    def _device_status(self, prefix: str, code: int) -> None:
        if prefix == "" and code == 5:
            self._reply("DSR 5", "\x1b[0n")
        elif prefix == "" and code == 6:
            self._reply("DSR 6 (position)", "\x1b[%d;%dR" % (self.cy + 1, self.cx + 1))
        elif prefix == "?" and code == 6:
            self._reply("DECXCPR", "\x1b[?%d;%d;1R" % (self.cy + 1, self.cx + 1))
        elif prefix == "?" and code == 996:
            self._reply("color scheme ?", "\x1b[?997;1n")

    def _window_report(self, code: int) -> None:
        if code == 14:
            self._reply("CSI 14 t", "\x1b[4;%d;%dt" % (self.rows * _CELL_H, self.cols * _CELL_W))
        elif code == 16:
            self._reply("CSI 16 t", "\x1b[6;%d;%dt" % (_CELL_H, _CELL_W))
        elif code == 18:
            self._reply("CSI 18 t", "\x1b[8;%d;%dt" % (self.rows, self.cols))

    def _erase_display(self, how: int) -> None:
        if how == 0:
            self._erase_line(0)
            for y in range(self.cy + 1, self.rows):
                self.grid[y] = self._blank_row()
        elif how == 1:
            self._erase_line(1)
            for y in range(0, self.cy):
                self.grid[y] = self._blank_row()
        elif how in (2, 3):
            for y in range(self.rows):
                self.grid[y] = self._blank_row()

    def _erase_line(self, how: int) -> None:
        row = self.grid[self.cy]
        if how == 0:
            start, end = self.cx, self.cols
        elif how == 1:
            start, end = 0, self.cx + 1
        else:
            start, end = 0, self.cols
        for col in range(start, min(end, self.cols)):
            row[col] = " "

    # OSC ---------------------------------------------------------------------------------------------------

    def _osc(self, body: str) -> None:
        code, _, rest = body.partition(";")
        self.osc_codes.append(code)
        if code in ("0", "2"):
            self.titles.append(rest)
        elif code in ("10", "11", "12") and rest == "?":
            color = _BACKGROUND if code == "11" else _FOREGROUND
            self._reply("OSC %s ?" % code, "\x1b]%s;%s\x1b\\" % (code, color))

    def summary(self) -> Dict[str, object]:
        """What the program asked of the terminal, for the notes."""
        return {
            "bracketed_paste_enabled": "?2004h" in self.private_modes_seen,
            "alternate_screen_used": any(m in self.private_modes_seen for m in ("?1049h", "?1047h", "?47h")),
            "private_modes_seen": sorted(set(self.private_modes_seen)),
            "queries": sorted(set(self.queries)),
            "osc_codes": sorted(set(self.osc_codes)),
            "titles": self.titles[-5:],
            "kitty_keyboard_flags_history": self.kitty_flags_history[-10:],
        }


def option_lines(lines: List[str], pattern: "Optional[re.Pattern[str]]" = None) -> List[Tuple[str, str]]:
    """(digit, label) for dialog lines like "❯ 1. Yes": the app's quick-answer heuristic (PROPOSITION 5.8)."""
    regex = pattern or re.compile(r"^\s*[❯>]?\s*([1-9])\.\s+(.+)$")
    found = []
    for line in lines:
        match = regex.match(line.replace("│", " ").replace("┃", " "))
        if match:
            found.append((match.group(1), match.group(2).strip()))
    return found
