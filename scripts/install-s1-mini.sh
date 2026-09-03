#!/bin/sh
set -eu

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'HELP'
Usage: ./scripts/install-s1-mini.sh

Register "S1-mini" by "Superwhisper" with the local Ollama so the Mac companion
can clean up push-to-talk transcripts. Uses the GGUF already in the Hugging Face
hub cache, preferring the Q4_K_M build over F16.

Download one first if neither is there:
  huggingface-cli download superwhisper/s1-mini-GGUF s1-mini-q4_k_m.gguf

Set PHONE_REMOTE_S1_MODEL to change the Ollama model name (default s1-mini).
HELP
    exit 0
fi

MODEL="${PHONE_REMOTE_S1_MODEL:-s1-mini}"
HUB="$HOME/.cache/huggingface/hub/models--superwhisper--s1-mini-GGUF/snapshots"

command -v ollama >/dev/null 2>&1 || { echo "error: ollama is not installed" >&2; exit 1; }
[ -d "$HUB" ] || { echo "error: no s1-mini GGUF in $HUB; see --help" >&2; exit 1; }

GGUF=$(find "$HUB" -name 's1-mini-q4_k_m.gguf' | head -1)
[ -n "$GGUF" ] || GGUF=$(find "$HUB" -name 's1-mini-*.gguf' | head -1)
[ -n "$GGUF" ] || { echo "error: no s1-mini GGUF in $HUB; see --help" >&2; exit 1; }

# The app sends the trained prompt itself through Ollama's raw endpoint, so the
# Modelfile only has to name the weights.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/Modelfile" <<EOF
FROM $GGUF

PARAMETER temperature 0
PARAMETER num_ctx 4096
EOF

echo "Registering $MODEL from $(basename "$GGUF")"
ollama create "$MODEL" -f "$WORK/Modelfile"
