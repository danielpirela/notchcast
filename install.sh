#!/usr/bin/env bash
# Notchcast installer: builds the app, installs Piper + a voice, and registers the
# Claude Code `Stop` hook in ~/.claude/settings.json (with a backup and a diff first).
#
# Usage: ./install.sh [--voice NAME] [--no-summary] [--yes]
#   --voice NAME   Piper voice to download (default: es_MX-claude-high)
#   --no-summary   skip the local summarizer (MLX + model) and turn summaries off
#   --yes          don't ask for confirmation (downloads + settings change)
set -euo pipefail

VOICE="es_MX-claude-high"
ASSUME_YES=0
SUMMARY=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --voice) VOICE="$2"; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --no-summary) SUMMARY=0; shift ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

SRC="$(cd "$(dirname "$0")" >/dev/null && pwd -P)"
DEST="$HOME/.claude/notchcast"
SETTINGS="$HOME/.claude/settings.json"
PIPER_VERSION="1.8.0"
MLX_LM_VERSION="0.32.0"
SUMMARY_MODEL="Qwen3-4B-Instruct-2507-4bit"
SUMMARY_REPO="mlx-community/$SUMMARY_MODEL"
VOICES_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
confirm() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    read -r -p "$1 [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# --- Requirements ------------------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || fail "macOS only."
[[ "$(uname -m)" == "arm64" ]] || fail "Apple Silicon (arm64) only."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 14 )) || fail "macOS 14 or newer required."
command -v swift >/dev/null || fail "Swift not found. Run: xcode-select --install"
PYTHON="$(command -v python3 || true)"
[[ -n "$PYTHON" ]] || fail "python3 not found (3.11+ required)."
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
    || fail "Python 3.11+ required (found $("$PYTHON" --version))."

# --- Voice download plan -----------------------------------------------------------------
lang="${VOICE%%-*}"                      # es_MX
rest="${VOICE#*-}"; speaker="${rest%-*}" # claude
quality="${VOICE##*-}"                   # high
family="${lang%%_*}"                     # es
VOICE_BASE="$VOICES_URL/$family/$lang/$speaker/$quality/$VOICE"

size_of() {
    # Prints the final content length, or 0 if the URL doesn't resolve to a 200.
    local out code
    out="$(curl -sIL -w '\n%{http_code}' "$1" 2>/dev/null || true)"
    code="$(tail -n1 <<< "$out")"
    [[ "$code" == "200" ]] || { echo 0; return; }
    awk 'tolower($1)=="content-length:" {v=$2} END {gsub("\r","",v); print v+0}' <<< "$out"
}

need_voice=1
[[ -f "$DEST/voices/$VOICE.onnx" && -f "$DEST/voices/$VOICE.onnx.json" ]] && need_voice=0
need_piper=1
[[ -x "$DEST/venv/bin/python" ]] && "$DEST/venv/bin/python" -c "import piper" 2>/dev/null && need_piper=0
need_mlx=0
need_model=0
if (( SUMMARY )); then
    need_mlx=1
    [[ -x "$DEST/venv/bin/python" ]] && "$DEST/venv/bin/python" -c "import mlx_lm" 2>/dev/null && need_mlx=0
    [[ -f "$DEST/models/$SUMMARY_MODEL/config.json" ]] || need_model=1
fi

repo_size() {
    curl -s "https://huggingface.co/api/models/$1/tree/main" | "$PYTHON" -c \
        'import json,sys; print(sum((f.get("lfs") or {}).get("size", f.get("size", 0)) for f in json.load(sys.stdin)))' \
        2>/dev/null || echo 0
}

if (( need_voice || need_piper || need_mlx || need_model )); then
    say "Downloads required:"
    if (( need_voice )); then
        model_size="$(size_of "$VOICE_BASE.onnx" || true)"
        (( model_size > 0 )) || fail "Voice '$VOICE' not found at $VOICE_BASE.onnx"
        printf '  %-34s %8.1f MB  huggingface.co/rhasspy/piper-voices\n' "$VOICE.onnx" "$(bc -l <<< "$model_size/1000000")"
        printf '  %-34s %8s     huggingface.co/rhasspy/piper-voices\n' "$VOICE.onnx.json" "<10 KB"
    fi
    if (( need_piper )); then
        printf '  %-34s %8s     pypi.org (into %s/venv)\n' "piper-tts==$PIPER_VERSION + deps" "~75 MB" "$DEST"
    fi
    if (( need_mlx )); then
        printf '  %-34s %8s     pypi.org (into %s/venv)\n' "mlx-lm==$MLX_LM_VERSION + deps" "~100 MB" "$DEST"
    fi
    if (( need_model )); then
        model_bytes="$(repo_size "$SUMMARY_REPO")"
        printf '  %-34s %8.1f GB  huggingface.co/%s\n' "$SUMMARY_MODEL" \
            "$(bc -l <<< "$model_bytes/1000000000")" "$SUMMARY_REPO"
    fi
    confirm "Download these files?" || fail "Cancelled."
fi

# --- Copy sources ------------------------------------------------------------------------
say "Installing into $DEST"
mkdir -p "$DEST/voices" "$DEST/models" "$DEST/run" "$DEST/logs" "$DEST/hook" "$DEST/Sources"
if [[ "$SRC" != "$DEST" ]]; then
    rsync -a --delete "$SRC/Sources/" "$DEST/Sources/"
    rsync -a "$SRC/hook/" "$DEST/hook/"
    cp "$SRC/Package.swift" "$SRC/tts_worker.py" "$SRC/summarize.py" "$SRC/build.sh" "$SRC/uninstall.sh" "$DEST/"
fi
chmod +x "$DEST/build.sh" "$DEST/uninstall.sh"

# --- Piper + voice -----------------------------------------------------------------------
if (( need_piper )); then
    say "Creating Python venv and installing piper-tts $PIPER_VERSION"
    "$PYTHON" -m venv "$DEST/venv"
    "$DEST/venv/bin/pip" install --quiet --disable-pip-version-check "piper-tts==$PIPER_VERSION"
fi
if (( need_voice )); then
    say "Downloading voice $VOICE"
    curl -fSL --progress-bar -o "$DEST/voices/$VOICE.onnx.part" "$VOICE_BASE.onnx"
    curl -fsSL -o "$DEST/voices/$VOICE.onnx.json" "$VOICE_BASE.onnx.json"
    mv "$DEST/voices/$VOICE.onnx.part" "$DEST/voices/$VOICE.onnx"
fi
echo "$VOICE" > "$DEST/voice"

# --- Local summarizer --------------------------------------------------------------------
if (( need_mlx )); then
    say "Installing mlx-lm $MLX_LM_VERSION"
    "$DEST/venv/bin/pip" install --quiet --disable-pip-version-check "mlx-lm==$MLX_LM_VERSION"
fi
if (( need_model )); then
    say "Downloading $SUMMARY_REPO"
    "$DEST/venv/bin/python" -I -c \
        "import sys; from huggingface_hub import snapshot_download; snapshot_download(sys.argv[1], local_dir=sys.argv[2])" \
        "$SUMMARY_REPO" "$DEST/models/$SUMMARY_MODEL"
fi
if (( ! SUMMARY )); then
    "$PYTHON" -c '
import json, os, sys
path = sys.argv[1]
config = json.load(open(path)) if os.path.exists(path) else {}
config["summarize"] = False
json.dump(config, open(path, "w"), indent=2)
' "$DEST/config.json"
fi

# --- Build -------------------------------------------------------------------------------
say "Building Notchcast.app"
"$DEST/venv/bin/python" -I "$DEST/hook/speak.py" --cmd quit >/dev/null 2>&1 || true
"$DEST/build.sh" >/dev/null
xattr -dr com.apple.quarantine "$DEST/Notchcast.app" 2>/dev/null || true

# --- Claude Code hook --------------------------------------------------------------------
say "Registering the Stop hook in $SETTINGS"
mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"
NEW_SETTINGS="$(mktemp)"
"$PYTHON" - "$SETTINGS" "$NEW_SETTINGS" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    settings = json.load(f)
command = '"$HOME/.claude/notchcast/venv/bin/python" -I "$HOME/.claude/notchcast/hook/speak.py"'
stop = settings.setdefault("hooks", {}).setdefault("Stop", [])
already = any("notchcast/hook/speak.py" in h.get("command", "")
              for group in stop for h in group.get("hooks", []))
if not already:
    stop.append({"hooks": [{"type": "command", "command": command, "async": True, "timeout": 15}]})
with open(dst, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

if diff -q <("$PYTHON" -m json.tool "$SETTINGS") <("$PYTHON" -m json.tool "$NEW_SETTINGS") >/dev/null; then
    echo "  Hook already present, nothing to change."
    rm -f "$NEW_SETTINGS"
else
    diff -u "$SETTINGS" "$NEW_SETTINGS" || true
    if confirm "Apply this change to $SETTINGS?"; then
        backup="$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"
        cp "$SETTINGS" "$backup"
        mv "$NEW_SETTINGS" "$SETTINGS"
        echo "  Saved. Backup: $backup"
    else
        rm -f "$NEW_SETTINGS"
        echo "  Skipped. Add the hook manually (see README.md)."
    fi
fi

# --- Launch ------------------------------------------------------------------------------
open -g "$DEST/Notchcast.app"
say "Done. Look for the waveform icon in the menu bar."
echo "  Test it:  $DEST/venv/bin/python -I $DEST/hook/speak.py --cmd speak text='Hola, ya funcionó.'"
