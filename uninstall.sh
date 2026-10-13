#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniel Pirela
# Removes the Notchcast Stop hook from ~/.claude/settings.json and, optionally, its files.
set -euo pipefail

DEST="$HOME/.claude/notchcast"
SETTINGS="$HOME/.claude/settings.json"

"$DEST/venv/bin/python" -I "$DEST/hook/speak.py" --cmd quit >/dev/null 2>&1 || true

if [[ -f "$SETTINGS" ]]; then
    cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
    python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    settings = json.load(f)
hooks = settings.get("hooks", {})
for event_name in list(hooks):
    groups = []
    for group in hooks[event_name]:
        kept = [h for h in group.get("hooks", []) if "notchcast/hook/" not in h.get("command", "")]
        if kept:
            groups.append({**group, "hooks": kept})
    if groups:
        hooks[event_name] = groups
    else:
        hooks.pop(event_name)
if not hooks:
    settings.pop("hooks", None)
with open(path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
    echo "Notchcast hooks removed from $SETTINGS (backup saved next to it)."
fi

read -r -p "Also delete $DEST (app, venv, voices)? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$DEST"
    echo "Deleted $DEST."
fi
