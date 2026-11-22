#!/bin/zsh
set -eu

cd "$(dirname "$0")/.."
STILL_REFERENCE="$HOME/Library/Application Support/Still/GemmaRuntime/bin/python"
STILL_GEMMA_TEST="$(mktemp -d "${TMPDIR:-/tmp}/still-gemma-text.XXXXXX")"
trap 'rm -rf "$STILL_GEMMA_TEST"' EXIT

"$STILL_REFERENCE" -c 'import importlib.metadata as m; assert m.version("mlx-vlm") == "0.8.0"'
STILL_GEMMA_RUNTIME="$STILL_GEMMA_TEST/runtime" Scripts/install-gemma.sh --runtime-only
"$STILL_GEMMA_TEST/runtime/bin/python" -E -s -B Benchmarks/smoke_gemma_text.py
"$STILL_REFERENCE" -E -s -B Benchmarks/compare_generation.py \
  --profile gemma12B --compare gemma-extraction --pairs 5 --max-slowdown 1.02 \
  --output Benchmarks/gemma-text-results.json
