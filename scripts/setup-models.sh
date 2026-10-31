#!/bin/zsh
# One-time setup, and the ONLY step that uses the network: downloads the two models the app runs.
#   scripts/setup-models.sh            both models
#   scripts/setup-models.sh parakeet   speech model only (443 MB)
#   scripts/setup-models.sh qwen       cleanup model only (2.1 GB)
# Revisions are pinned, so you get exactly the files the app was tested with. Needs `uv` (brew install uv).
# VOICEIT_MODELS_ROOT overrides the destination (default: Application Support/Voice It/models).
set -euo pipefail
ROOT="${VOICEIT_MODELS_ROOT:-$HOME/Library/Application Support/Voice It/models}"
WHAT="${1:-all}"
command -v uvx >/dev/null || { echo "uv not found: brew install uv" >&2; exit 1 }

fetch() { uvx --from huggingface_hub hf download "$@" 2>&1 | grep -v "unauthenticated requests" || true }

if [[ $WHAT == all || $WHAT == parakeet ]]; then
  DST="$ROOT/parakeet-tdt-0.6b-v2"
  # Only the five pieces FluidAudio loads for Parakeet v2; the repository also holds other variants we don't use.
  fetch FluidInference/parakeet-tdt-0.6b-v2-coreml --revision ee09c569f73759e6d44c9bd16766f477b2b36d39 \
    --include "Preprocessor.mlmodelc/*" --include "Encoder.mlmodelc/*" --include "Decoder.mlmodelc/*" --include "JointDecision.mlmodelc/*" \
    --include "parakeet_vocab.json" --include "config.json" \
    --local-dir "$DST"
  du -sh "$DST"
fi
if [[ $WHAT == all || $WHAT == qwen ]]; then
  DST="$ROOT/cleanup/Qwen3-4B-Instruct-2507-4bit"
  fetch mlx-community/Qwen3-4B-Instruct-2507-4bit --revision 50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b --local-dir "$DST"
  du -sh "$DST"
fi
