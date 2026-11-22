#!/bin/zsh
set -eu
STILL_SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
STILL_RUNTIME="$HOME/Library/Application Support/Still/Runtime"
if [[ ! -x "$STILL_RUNTIME/bin/python" ]]; then
  uv venv "$STILL_RUNTIME" --python 3.11
fi
uv pip install --python "$STILL_RUNTIME/bin/python" -r "$STILL_SOURCE/Resources/Runtime.requirements.txt"
echo "Runtime ready. Inkling's model files are expected in ~/.lmstudio/models/mlx-community/Inkling-2-Mini-4bit."
