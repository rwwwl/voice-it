#!/bin/zsh
# Regenerate synthetic test audio from fixtures/expected/say-*.txt using macOS `say`.
# Output: 16 kHz mono 16-bit WAV in fixtures/audio/ (gitignored).
# Synthetic speech is for pipeline, load-time and speed checks ONLY, never for accuracy comparisons.
set -euo pipefail
cd "$(dirname "$0")/.."
for f in fixtures/expected/say-*.txt; do
  name=$(basename "$f" .txt)
  say -v Samantha -f "$f" -o "fixtures/audio/$name.wav" --data-format=LEI16@16000 --file-format=WAVE
  echo "$name: $(afinfo "fixtures/audio/$name.wav" | awk '/estimated duration/{print $3}') s"
done
