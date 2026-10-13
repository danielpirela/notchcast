# Notchcast

Hear Claude Code's final answers read aloud, with a Dynamic Island–style indicator on your Mac's notch.

Notchcast is a tiny native macOS menu-bar app. A global Claude Code `Stop` hook sends each final
answer to the app. A **local** model can shorten it into a spoken summary, and a **local**
[Piper](https://github.com/OHF-Voice/piper1-gpl) voice reads it. Nothing leaves your machine, nothing
costs API credits, and no audio is written to disk.

- **Local summaries (on by default):** long answers are condensed into 2–4 spoken sentences by a small model running on your Mac ([MLX](https://github.com/ml-explore/mlx) by default, or [Ollama](https://ollama.com)). Turn it off to hear the exact answer.
- **Clean reading:** markdown is stripped; code blocks, tables, URLs and long file paths are skipped.
- **Drift, the mascot:** a pixel jellyfish living in the notch. It thinks while the summary is made, talks with the audio level, sleeps when paused and waves goodbye.
- **Notch island:** Drift, live audio-level bars, a timer and a quick stop button. Click to see the text with the current sentence highlighted, the engine in use (MLX / Ollama) and Pause/Resume, Stop, Repeat, Next. Long-press to stop instantly.
- **Live Claude Code status:** while Claude works, Drift shows it: thinking, typing on a laptop while tools run, splitting into mini copies for each subagent, a question face when Claude asks you something, an alert when it needs permission. Several sessions are listed when expanded.
- **Answer queue:** answers from several sessions are read one after another (with "En notchcast-site…" when you juggle projects), never on top of each other. If you're away from the Mac they wait and play when you're back.
- **Menu bar:** Repetir último, Leer último (show the full answer without speaking), Resumir con IA local (on/off), Motor de resumen (MLX / Ollama), Mostrar estado de Claude (on/off), Silenciar, Salir.
- On Macs without a notch it shows as a pill at the top center.

## Requirements

| | |
|---|---|
| Mac | Apple Silicon, macOS 14 or newer (16 GB RAM recommended for summaries) |
| Toolchain | Swift (Xcode or Command Line Tools: `xcode-select --install`) |
| Python | 3.11+ (`python3`) |
| Claude Code | A local session (CLI, desktop app or IDE extension) on that Mac |
| Disk | ~2.6 GB with summaries (model 2.3 GB), ~250 MB without |

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
   - the voice model + config from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) (default `es_MX-claude-high`, 63 MB)
   - `mlx-lm` 0.32.0 + dependencies from PyPI (~100 MB)
   - the summary model [`mlx-community/Qwen3-4B-Instruct-2507-4bit`](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit) (2.3 GB)
3. Copies everything into `~/.claude/notchcast/` and builds `Notchcast.app` (no Xcode GUI).
4. Shows the diff it wants to apply to `~/.claude/settings.json`, asks, then saves it with a timestamped backup.
5. Launches the app in the background.

Options:

```bash
./install.sh --voice es_ES-sharvard-medium   # any voice from rhasspy/piper-voices
./install.sh --no-summary                    # skip MLX + the 2.3 GB model, summaries off
./install.sh --yes                           # no prompts
./install.sh --skip-settings                 # redeploy the app without touching settings.json
```

Re-running `install.sh` is safe: it skips what's already there and never adds the hook twice. It's
also how you deploy changes after editing the code.

## Local summaries

Claude's answers can be long. With summaries on, Notchcast speaks a short version instead:

```
answer ──▶ summarize.py (local model, one shot) ──▶ 2–4 sentences ──▶ Piper voice
```

- **Switch:** menu bar → **Resumir con IA local**. On by default. When off, the exact answer is read.
- **Engine:** menu bar → **Motor de resumen** → **MLX (nativo)** (default) or **Ollama**. The expanded island shows which one was used (a check-engine light labelled MLX, Ollama, or "Respuesta completa").
- **No idle memory:** the model is loaded only to summarize and is freed *before* the voice starts. MLX runs in a short-lived process that exits after each summary; Ollama is called with `keep_alive: 0`, so it unloads right away.
- **Fast path:** answers shorter than 300 characters are read as-is (summarizing them would only add delay).
- **Always speaks:** if the summary fails (engine missing, error or 60 s timeout), the full answer is read instead. Details go to `~/.claude/notchcast/logs/summarizer.log`.
- **Faithful:** the prompt forbids adding facts or offers, and a code check removes any question the model invents when the original answer didn't ask one.

Measured on a MacBook Air M5 (16 GB) with MLX and a typical answer: **~3 s** from the hook to the first word, ~3 GB peak RAM during those seconds, 0 MB afterwards.

### Using Ollama instead of MLX

```bash
brew install ollama
ollama serve &                                   # or open the Ollama app
ollama pull qwen3:4b-instruct-2507-q4_K_M
```

Then pick **Motor de resumen → Ollama** in the menu bar. MLX is usually faster on Apple Silicon and
needs no background service; Ollama is handy if you already use it or want other models.

### Settings file

The menu bar writes `~/.claude/notchcast/config.json`. You can also edit it by hand (missing keys use
these defaults):

```json
{
  "summarize": true,
  "backend": "mlx",
  "mlxModel": "Qwen3-4B-Instruct-2507-4bit",
  "ollamaModel": "qwen3:4b-instruct-2507-q4_K_M",
  "ollamaURL": "http://127.0.0.1:11434",
  "minChars": 300,
  "showAgentStatus": true,
  "awayAfterSeconds": 120
}
```

`mlxModel` is a folder name inside `~/.claude/notchcast/models/`. Any MLX chat model from
[mlx-community](https://huggingface.co/mlx-community) works; smaller ones are faster but summarize worse.

## Several sessions and the queue

- Each answer carries its session and project. When more than one session is active, the voice starts with the project ("En notchcast-site. …"); old answers say how long ago ("Hace 5 minutos, en notchcast. …").
- A new answer never interrupts the one playing: it waits in the queue (the island shows **+N**). If the same session sends a newer answer before the old one is read, only the newest is kept.
- **Siguiente** skips to the next answer; in the expanded island you can play any queued answer or discard it.
- After you stop an answer by hand, the queue waits for **Siguiente** or the next new answer instead of carrying on.
- **Away mode:** with no keyboard or mouse input for 2 minutes (`awayAfterSeconds` in `config.json`), answers are held and the island shows how many are waiting. They play as soon as you touch the Mac.
- Summaries are made only when an answer's turn comes, so no model sits in memory while answers wait. The queue lives in memory only.

## Claude Code configuration

The installer merges these hooks into `~/.claude/settings.json` (your existing hooks are kept). The `Stop`
hook that speaks the answer:

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

- `async: true` runs the hook in the background, so Claude Code is never delayed. The hook itself only hands the text to the app and exits (~30 ms); summarizing and speaking happen in the app.
- The hook reads `last_assistant_message` from the `Stop` hook input (falling back to `transcript_path`), as the [hooks reference](https://code.claude.com/docs/en/hooks) recommends.
- If the app isn't running, the hook opens it with `open -g` and retries for a few seconds.
- If Claude Code doesn't pick up the new hook in an open session, restart the session.

For the live status, the same small script is added, async with a 5 s timeout, to `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `SubagentStart`, `SubagentStop`, `PermissionRequest`,
`Notification`, `Stop`, `StopFailure` and `SessionEnd`:

```json
{ "type": "command", "command": "\"$HOME/.claude/notchcast/hook/event.sh\"", "async": true, "timeout": 5 }
```

`event.sh` forwards the event to the app over the local socket with `nc` and exits in a few milliseconds.
It never launches the app; if Notchcast isn't running the event is dropped. Turn the status off from the
menu bar (**Mostrar estado de Claude**) or with `showAgentStatus` in `config.json`.

## Files

Everything lives in `~/.claude/notchcast/`:

| Path | What it is |
|---|---|
| `Sources/Notchcast/` | Swift app (AppKit + SwiftUI + AVAudioEngine) |
| `tts_worker.py` | Long-lived Piper process: keeps the voice loaded (~300 MB), streams raw PCM per sentence |
| `summarize.py` | One-shot summarizer (MLX or Ollama); exits after each summary |
| `hook/speak.py` | The `Stop` hook: cleans markdown and sends the answer (with its session) over a Unix socket |
| `hook/event.sh` | Status hook: forwards Claude Code events (thinking, tools, subagents…) to the app |
| `build.sh` | Builds `Notchcast.app` with SwiftPM |
| `install.sh` / `uninstall.sh` | Setup and removal |
| `config.json` | Summary settings (see above) |
| `voice` | Name of the active voice (one line) |
| `voices/` | Downloaded Piper models |
| `models/` | Downloaded MLX summary models |
| `venv/` | Python venv with `piper-tts` and `mlx-lm` |
| `run/voice.sock` | IPC socket (user-only permissions) |
| `muted` | Present while muted |
| `logs/` | `worker.log` (Piper) and `summarizer.log` |

## How it works

```
Claude Code ──Stop hook (async)──▶ speak.py ──JSON over Unix socket──▶ Notchcast.app
                                    clean markdown                       │
                                                        summaries on? ──▶ summarize.py (MLX/Ollama, then exits)
                                                                         ▼
                                                         split sentences (NaturalLanguage)
                                                                         ▼
                                                     tts_worker.py (Piper, voice in memory)
                                                                         ▼ raw PCM per sentence
                                                     AVAudioEngine ──▶ speakers
                                                         └─ tap ──▶ level bars
```

"Repeat" re-synthesizes the last spoken text from memory; audio is never saved.

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
nc() { "$HOME/.claude/notchcast/venv/bin/python" -I "$HOME/.claude/notchcast/hook/speak.py" "$@"; }
nc --cmd speak text="Hola, esto es una prueba."
nc --cmd status                 # phase, island mode, engine, audio level, spoken text...
nc --cmd pause                  # also: resume, stop, next, repeat, showLast
nc --cmd mute on=true           # or on=false
nc --cmd summarize on=false     # summaries on/off
nc --cmd backend name=ollama    # or name=mlx
echo '**Some** markdown' | nc --clean   # preview what will be spoken
```

## Uninstall

```bash
~/.claude/notchcast/uninstall.sh
```

Removes the hook from `settings.json` (with a backup), quits the app and optionally deletes `~/.claude/notchcast/`.

## License

Notchcast is free software, released under the [GNU General Public License v3.0 or later](LICENSE).
Copyright (C) 2026 [Daniel Pirela](https://github.com/danielpirela).

You can use, study, share and modify it. If you distribute a modified version, it must stay open
source under the same license.

Third-party components (Piper, the voices, MLX, the Qwen3 model, Ollama) are downloaded at install
time, not bundled here; their licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Notchcast is an independent project, not affiliated with or endorsed by Anthropic. Claude and Claude
Code are trademarks of Anthropic.
