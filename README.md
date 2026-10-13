# Notchcast

Hear Claude Code's final answers read aloud, with a Dynamic Island–style indicator on your Mac's notch.

Notchcast is a tiny native macOS menu-bar app. A global Claude Code `Stop` hook sends each final
answer to the app, which speaks it with a **local** [Piper](https://github.com/OHF-Voice/piper1-gpl)
voice. Nothing leaves your machine, and no audio is written to disk.

- Reads the **exact** answer: markdown is stripped, code blocks, tables, URLs and long file paths are skipped. No summarizing, no rewriting.
- Notch island with live audio-level bars and a timer. Click to see the full text with the current sentence highlighted, plus Pause/Resume, Stop and Repeat. Long-press to stop instantly.
- Menu bar: **Repetir último**, **Leer último** (show the text without speaking), **Silenciar** (persistent mute), **Salir**.
- On Macs without a notch it shows as a pill at the top center.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon, macOS 14 or newer |
| Toolchain | Swift (Xcode or Command Line Tools: `xcode-select --install`) |
| Python | 3.10+ (`python3`) |
| Claude Code | A local session (CLI, desktop app or IDE extension) on that Mac |
| Disk | ~250 MB (Piper + one voice) |

> Hooks run on the machine where Claude Code runs. Cloud/remote sessions (claude.ai/code, SSH) can't reach the app on your Mac.

## Install

```bash
git clone https://github.com/danielpirela/notchcast.git
cd notchcast
./install.sh
```

The installer:

1. Checks the requirements.
2. Lists every download with its source and size, and asks before downloading:
   - `piper-tts` 1.8.0 + dependencies from PyPI, into an isolated venv (~75 MB)
   - the voice model + config from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) on Hugging Face (default `es_MX-claude-high`, 63 MB)
3. Copies everything into `~/.claude/notchcast/` and builds `Notchcast.app` (no Xcode GUI).
4. Shows the diff it wants to apply to `~/.claude/settings.json`, asks, then saves it with a timestamped backup.
5. Launches the app in the background.

Options:

```bash
./install.sh --voice es_ES-sharvard-medium   # any voice from rhasspy/piper-voices
./install.sh --yes                           # no prompts
```

Re-running `install.sh` is safe: it skips what's already there and never adds the hook twice.

## Claude Code configuration

This is the only change made to `~/.claude/settings.json` (merged with your existing hooks):

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$HOME/.claude/notchcast/venv/bin/python\" -I \"$HOME/.claude/notchcast/hook/speak.py\"",
            "async": true,
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

- `async: true` runs the hook in the background, so Claude Code is never delayed.
- The hook reads `last_assistant_message` from the `Stop` hook input (falling back to `transcript_path`), as the [hooks reference](https://code.claude.com/docs/en/hooks) recommends.
- If the app isn't running, the hook opens it with `open -g` and retries for a few seconds.
- If Claude Code doesn't pick up the new hook in an open session, restart the session.

## Files

Everything lives in `~/.claude/notchcast/`:

| Path | What it is |
|---|---|
| `Sources/Notchcast/` | Swift app (AppKit + SwiftUI + AVAudioEngine) |
| `tts_worker.py` | Long-lived Piper process: keeps the model loaded, streams raw PCM per sentence |
| `hook/speak.py` | The `Stop` hook: cleans markdown and sends the text over a Unix socket |
| `build.sh` | Builds `Notchcast.app` with SwiftPM |
| `install.sh` / `uninstall.sh` | Setup and removal |
| `voice` | Name of the active voice (one line) |
| `voices/` | Downloaded Piper models |
| `venv/` | Python venv with `piper-tts` |
| `run/voice.sock` | IPC socket (user-only permissions) |
| `muted` | Present while muted |
| `logs/worker.log` | Piper worker errors |

## How it works

```
Claude Code ──Stop hook (async)──▶ speak.py ──JSON over Unix socket──▶ Notchcast.app
                                    clean markdown                      split sentences (NaturalLanguage)
                                                                        ▼
                                                     tts_worker.py (Piper, model in memory)
                                                                        ▼ raw PCM per sentence
                                                     AVAudioEngine ──▶ speakers
                                                         └─ tap ──▶ level bars
```

"Repeat" re-synthesizes from the last text kept in memory; audio is never saved.

## Changing the voice

```bash
./install.sh --voice es_AR-daniela-high
```

Or download the `.onnx` and `.onnx.json` into `~/.claude/notchcast/voices/`, write the voice name into
`~/.claude/notchcast/voice`, and restart the app from the menu bar (**Salir**, then send any message).

Spanish voices worth trying: `es_MX-claude-high` (neutral Latin American), `es_AR-daniela-high` (Rioplatense),
`es_ES-sharvard-medium` (Spain). The full list is at [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices/tree/main).

## Testing and controlling it

```bash
VI="$HOME/.claude/notchcast/venv/bin/python -I $HOME/.claude/notchcast/hook/speak.py"
$VI --cmd speak text="Hola, esto es una prueba."
$VI --cmd status          # phase, island mode, audio level, ...
$VI --cmd pause | resume | stop | repeat | showLast
$VI --cmd mute on=true    # or on=false
echo '**Some** markdown' | $VI --clean   # preview what will be spoken
```

## Uninstall

```bash
~/.claude/notchcast/uninstall.sh
```

Removes the hook from `settings.json` (with a backup), quits the app and optionally deletes `~/.claude/notchcast/`.

## Licenses

Piper (`piper-tts`) is GPL-3.0 and is installed from PyPI, not bundled here. Each voice has its own license,
listed in its model card on Hugging Face.
