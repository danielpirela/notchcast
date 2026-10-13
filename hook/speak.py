# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniel Pirela
"""Claude Code `Stop` hook for Notchcast.

Reads the hook JSON on stdin, cleans the final assistant message for speech and sends it
to Notchcast.app over a Unix socket, launching the app in the background if needed.

Extra CLI modes (for testing):
  speak.py --clean          read markdown on stdin, print the speakable text
  speak.py --cmd NAME [k=v] send one IPC command and print the reply
"""
import json
import re
import socket
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

HOME = Path(__file__).resolve().parent.parent
SOCKET = HOME / "run" / "voice.sock"
MUTE_FLAG = HOME / "muted"
APP = HOME / "Notchcast.app"
LAUNCH_TIMEOUT = 8.0

# --- Markdown -> speakable text -------------------------------------------------------

FENCE = re.compile(r"^\s*(`{3,}|~{3,})")
TABLE_SEP = re.compile(r"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$")
RULE = re.compile(r"^([-*_]\s*){3,}$")
HEADING = re.compile(r"^#{1,6}\s+")
QUOTE = re.compile(r"^(>\s?)+")
BULLET = re.compile(r"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?")
IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
AUTOLINK = re.compile(r"<(https?://|mailto:)[^>]+>")
URL = re.compile(r"\b(?:https?://|www\.)\S+", re.IGNORECASE)
INLINE_CODE = re.compile(r"`+([^`]+?)`+")
HTML_TAG = re.compile(r"</?[A-Za-z][^>]*>")
# Rooted paths (~/x/y, /x/y, ./x/y) or relative ones with two or more separators (src/app/foo.ts:42)
LONG_PATH = re.compile(
    r"(?<![\w/~.])(?:(?:~|\.{1,2})?/(?:[\w.@+-]+/)+|(?:[\w.@+-]+/){2,})([\w.@+-]*)(?::\d+(?::\d+)?)?")
EMPHASIS = [
    re.compile(r"\*\*(.+?)\*\*"),
    re.compile(r"__(.+?)__"),
    re.compile(r"~~(.+?)~~"),
    re.compile(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"),
    re.compile(r"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"),
]
SYMBOL_WORDS = {"→": ", ", "←": ", ", "⇒": ", ", "—": ", ", "–": ", ", "•": ", ", "…": "..."}
END_PUNCT = ".!?:;…,"


def _shorten_path(match: re.Match) -> str:
    name = match.group(1)
    if not name:  # trailing slash: use the last directory name
        parts = [p for p in match.group(0).split("/") if p and p not in ("~", ".", "..")]
        name = parts[-1] if parts else ""
    return name


def _inline(text: str) -> str:
    text = IMAGE.sub("", text)
    text = AUTOLINK.sub("", text)
    text = LINK.sub(r"\1", text)
    text = URL.sub("", text)
    text = INLINE_CODE.sub(r"\1", text)
    text = HTML_TAG.sub("", text)
    text = LONG_PATH.sub(_shorten_path, text)
    for pattern in EMPHASIS:
        text = pattern.sub(r"\1", text)
    for symbol, spoken in SYMBOL_WORDS.items():
        text = text.replace(symbol, spoken)
    text = "".join(
        ch for ch in text
        if unicodedata.category(ch) not in ("So", "Cs", "Co") and ch not in "️‍"
    )
    text = re.sub(r"[*#`|<>]", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+([.,;:!?)])(?=\s|$)", r"\1", text)
    text = re.sub(r"\(\s*\)", "", text)
    text = re.sub(r"([,;:])(\s*[,;:])+", r"\1", text)
    return text.strip(" ,;")


def clean(markdown: str) -> str:
    out: list[str] = []
    fence: str | None = None
    previous_raw = ""
    for raw in markdown.replace("\r\n", "\n").split("\n"):
        fence_match = FENCE.match(raw)
        if fence_match:
            marker = fence_match.group(1)
            if fence is None:
                fence = marker
            elif raw.strip().startswith(fence[0] * len(fence)):
                fence = None
            continue
        if fence is not None:
            continue

        line = raw.strip()
        if TABLE_SEP.match(line):
            if out and "|" in previous_raw:
                out.pop()  # drop the table header row
            previous_raw = raw
            continue
        previous_raw = raw
        if line.startswith("|") or RULE.match(line):
            continue

        is_heading = bool(HEADING.match(line))
        line = HEADING.sub("", line)
        line = QUOTE.sub("", line)
        is_item = bool(BULLET.match(line))
        line = BULLET.sub("", line)
        line = _inline(line)

        if not line:
            if out and out[-1] != "":
                out.append("")
            continue
        if (is_heading or is_item) and line[-1] not in END_PUNCT:
            line += "."
        out.append(line)

    return "\n".join(out).strip()


# --- Transcript fallback ---------------------------------------------------------------

def last_message_from_transcript(path: str | None) -> str:
    """Collects the text blocks of the trailing assistant turn in a JSONL transcript."""
    if not path:
        return ""
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError:
        return ""
    parts: list[str] = []
    for line in reversed(lines):
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        message = entry.get("message") or {}
        role = message.get("role") or entry.get("type")
        content = message.get("content")
        if role == "user":
            is_tool_result = isinstance(content, list) and any(
                isinstance(block, dict) and block.get("type") == "tool_result" for block in content
            )
            if not is_tool_result:
                break
            continue
        if role != "assistant":
            continue
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            texts = [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"]
            if texts:
                parts.append("\n".join(texts))
        if parts and isinstance(content, list) and any(
            isinstance(b, dict) and b.get("type") == "tool_use" for b in content
        ):
            break
    return "\n\n".join(reversed(parts))


# --- IPC -------------------------------------------------------------------------------

def send(message: dict, timeout: float = 2.0) -> dict | None:
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(str(SOCKET))
            sock.sendall(json.dumps(message).encode() + b"\n")
            sock.shutdown(socket.SHUT_WR)
            reply = b""
            while chunk := sock.recv(65536):
                reply += chunk
        return json.loads(reply or b"{}")
    except (OSError, ValueError):
        return None


def deliver(text: str, session: str = "", project: str = "") -> bool:
    muted = MUTE_FLAG.exists()
    message = {"cmd": "store" if muted else "speak", "text": text, "session": session, "project": project}
    if send(message) is not None:
        return True
    if muted:
        return False  # don't wake the app just to stay silent
    subprocess.Popen(["/usr/bin/open", "-g", str(APP)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + LAUNCH_TIMEOUT
    while time.monotonic() < deadline:
        time.sleep(0.2)
        if send(message) is not None:
            return True
    return False


def main() -> int:
    args = sys.argv[1:]
    if args[:1] == ["--clean"]:
        print(clean(sys.stdin.read()))
        return 0
    if args[:1] == ["--cmd"] and len(args) >= 2:
        message: dict = {"cmd": args[1]}
        for pair in args[2:]:
            key, _, value = pair.partition("=")
            message[key] = {"true": True, "false": False}.get(value, value)
        print(json.dumps(send(message), ensure_ascii=False, indent=1))
        return 0

    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    text = payload.get("last_assistant_message") or last_message_from_transcript(payload.get("transcript_path"))
    spoken = clean(text or "")
    if spoken:
        cwd = payload.get("cwd") or ""
        deliver(spoken, session=payload.get("session_id") or "", project=Path(cwd).name if cwd else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
