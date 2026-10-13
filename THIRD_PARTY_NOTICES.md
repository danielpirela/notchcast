# Third-party notices

Notchcast does not bundle any third-party code or model. The installer downloads the components below
from their official sources onto the user's machine. Their own licenses apply to them.

| Component | Used for | License | Source |
|---|---|---|---|
| Piper (`piper-tts`) | Text-to-speech engine | GPL-3.0-or-later | https://github.com/OHF-Voice/piper1-gpl |
| `es_MX-claude-high` voice | Default Piper voice | Apache-2.0 (dataset) | https://huggingface.co/rhasspy/piper-voices |
| Other Piper voices (optional) | Alternative voices | See each model card | https://huggingface.co/rhasspy/piper-voices |
| MLX, `mlx-lm` | Local summaries on Apple Silicon | MIT | https://github.com/ml-explore/mlx |
| Qwen3-4B-Instruct-2507 (MLX 4-bit) | Local summary model | Apache-2.0 | https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit |
| Ollama (optional) | Alternative summary engine | MIT | https://ollama.com |

The voice name `es_MX-claude-high` refers to the speaker of that community dataset and is unrelated to Anthropic.

## Trademarks

Notchcast is an independent open-source project. It is not affiliated with, endorsed by or sponsored by
Anthropic. Claude and Claude Code are trademarks of Anthropic. Apple, Mac, macOS and MacBook are
trademarks of Apple Inc.
