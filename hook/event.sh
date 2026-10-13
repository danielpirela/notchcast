#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniel Pirela
# Claude Code hook: forwards the hook event (JSON on stdin) to Notchcast so the island can show
# what Claude is doing. Never launches the app and never blocks: if Notchcast isn't running,
# the event is dropped.
SOCK="$HOME/.claude/notchcast/run/voice.sock"
[ -S "$SOCK" ] || exit 0
{ printf '{"cmd":"event","payload":'; cat; printf '}\n'; } | /usr/bin/nc -U -w 1 "$SOCK" >/dev/null 2>&1
exit 0
