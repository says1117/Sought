#!/usr/bin/env bash
# Creates ml/.venv (gitignored), installs pinned deps, downloads the checkpoint + sample images.
set -euo pipefail
cd "$(dirname "$0")"
PY=${PYTHON:-python3.11}
$PY -m venv ../.venv
../.venv/bin/pip install -q -r requirements.txt
../.venv/bin/pip install -q --no-deps -r requirements-mobileclip.txt
mkdir -p checkpoints data
[ -f checkpoints/mobileclip_s0.pt ] || curl -fL -o checkpoints/mobileclip_s0.pt \
  https://huggingface.co/apple/MobileCLIP-S0/resolve/main/mobileclip_s0.pt
echo "expected sha256 809b408eff74f8058843e86a1f92967097d42ba782450e85b8f4867b7f0ca0b7"
shasum -a 256 checkpoints/mobileclip_s0.pt
# Optional sample images for the parity check (any images in data/ are used; synthetic ones are always added).
base=https://huggingface.co/datasets
[ -f data/cats.png ] || curl -fL -o data/cats.png $base/huggingface/documentation-images/resolve/main/coco_sample.png || true
[ -f data/cat_dog_music.png ] || curl -fL -o data/cat_dog_music.png $base/mishig/sample_images/resolve/main/cat-dog-music.png || true
[ -f data/tiger.jpg ] || curl -fL -o data/tiger.jpg $base/mishig/sample_images/resolve/main/tiger.jpg || true
