#!/bin/bash
# One-time setup for the local cleanup LLM:
#   1. install llama.cpp (brew) if missing
#   2. download Qwen3-4B-Instruct-2507 Q4_K_M (~2.4 GB) — good Czech + English
#   3. point Utter at both via defaults
set -euo pipefail

MODELS_DIR="$HOME/Library/Application Support/Utter/Models"
MODEL_NAME="Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
MODEL_FILE="$MODELS_DIR/$MODEL_NAME"
MODEL_URL="https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/$MODEL_NAME"

mkdir -p "$MODELS_DIR"

if ! command -v llama-server >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        echo "==> Installing llama.cpp via Homebrew"
        brew install llama.cpp
    else
        echo "ERROR: llama-server not found and Homebrew is not installed."
        echo "Install Homebrew (https://brew.sh) or llama.cpp manually, then re-run."
        exit 1
    fi
else
    echo "==> llama-server already installed: $(command -v llama-server)"
fi

if [[ -f "$MODEL_FILE" ]]; then
    echo "==> Model already downloaded: $MODEL_FILE"
else
    echo "==> Downloading $MODEL_NAME (~2.4 GB, resumable)"
    curl -L --fail -C - -o "$MODEL_FILE.part" "$MODEL_URL"
    mv "$MODEL_FILE.part" "$MODEL_FILE"
fi

defaults write com.jancuhel.utter llamaServerPath "$(command -v llama-server)"
defaults write com.jancuhel.utter llmModelPath "$MODEL_FILE"

echo "==> LLM setup complete."
echo "    Server: $(command -v llama-server)"
echo "    Model:  $MODEL_FILE"
