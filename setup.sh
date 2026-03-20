#!/bin/bash
set -e

echo "==> Installing whisper.cpp via Homebrew..."
if ! command -v whisper-cli &> /dev/null; then
    brew install whisper-cpp
else
    echo "    whisper-cli already installed"
fi

echo "==> Downloading base.en model..."
MODEL_DIR="$(dirname "$0")/models"
MODEL_PATH="$MODEL_DIR/ggml-base.en.bin"

mkdir -p "$MODEL_DIR"

if [ ! -f "$MODEL_PATH" ]; then
    curl -L -o "$MODEL_PATH" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
    echo "    Model downloaded to $MODEL_PATH"
else
    echo "    Model already exists at $MODEL_PATH"
fi

echo "==> Building app..."
cd "$(dirname "$0")/TalkText"
swift build -c release

echo ""
echo "==> Done! Run with:"
echo "   .build/release/TalkText"
echo ""
echo "NOTE: You'll need to grant Accessibility permissions in"
echo "System Settings > Privacy & Security > Accessibility"
echo "for the auto-paste feature to work."
