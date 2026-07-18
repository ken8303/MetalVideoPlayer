#!/bin/bash
# One-time setup for the "Max" image-enhancer engine (Real-ESRGAN via
# Core ML). Downloads the model weights, converts them, and installs the
# result where the app looks for it. Needs python3 and ~2 GB of disk for
# the temporary Python environment (removable afterwards).
#
# Usage: bash convert-model.sh
set -euo pipefail
cd "$(dirname "$0")"

VENV=.model-venv
WEIGHTS_URL="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth"
DEST="$HOME/Library/Application Support/SuperResVideoPlayer"

echo "==> Setting up Python environment (first run only)…"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
# shellcheck disable=SC1091
source "$VENV/bin/activate"
pip -q install --upgrade pip
pip -q install torch coremltools numpy

if [ ! -f realesr-animevideov3.pth ]; then
  echo "==> Downloading model weights (~2.4 MB)…"
  curl -L -o realesr-animevideov3.pth "$WEIGHTS_URL"
fi

echo "==> Converting to Core ML…"
rm -rf RealESRGAN.mlpackage
python3 convert_model.py

echo "==> Installing…"
mkdir -p "$DEST"
rm -rf "$DEST/RealESRGAN.mlpackage"
mv RealESRGAN.mlpackage "$DEST/"

echo ""
echo "Done: $DEST/RealESRGAN.mlpackage"
echo "The 'Max' engine is now available in the app (used during export)."
echo "You can delete $VENV and realesr-animevideov3.pth to reclaim space."
