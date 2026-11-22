#!/bin/zsh
set -eu
STILL_SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
STILL_RUNTIME="${STILL_GEMMA_RUNTIME:-$HOME/Library/Application Support/Still/GemmaTextRuntime}"
if [[ $# -gt 1 || ( $# -eq 1 && "$1" != --runtime-only ) ]]; then
  echo "Usage: $0 [--runtime-only]" >&2
  exit 2
fi
if [[ ! -x "$STILL_RUNTIME/bin/python" ]]; then
  uv venv "$STILL_RUNTIME" --python 3.11
fi
uv pip sync --python "$STILL_RUNTIME/bin/python" "$STILL_SOURCE/Resources/GemmaTextRuntime.requirements.txt"
if [[ "${1:-}" == --runtime-only ]]; then
  exit
fi
"$STILL_RUNTIME/bin/python" - <<'PY'
from pathlib import Path
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/gemma-4-12B-it-4bit', revision='73bcf09092aa277861d5a191b989b666f7f32e8f', local_dir=Path.home()/'Library/Application Support/Still/Models/gemma-4-12B-it-4bit', max_workers=4)
PY
