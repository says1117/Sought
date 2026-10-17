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
# Sample images for the parity check (any images in data/ are used; synthetic ones are always added).
# Each download is verified against a pinned sha256; a mismatch deletes the file and fails the script.
fetch() { # name url sha256
  [ -f "data/$1" ] || curl -fL -o "data/$1" "$2"
  got=$(shasum -a 256 "data/$1" | cut -d' ' -f1)
  if [ "$got" != "$3" ]; then rm -f "data/$1"; echo "sha256 mismatch for $1 (got $got)" >&2; exit 1; fi
}
base=https://huggingface.co/datasets
fetch cats.png $base/huggingface/documentation-images/resolve/main/coco_sample.png cf6f3c4befa148732c7453e0de5afab00f682427435fead2d88b07a9615cdac2
fetch cat_dog_music.png $base/mishig/sample_images/resolve/main/cat-dog-music.png 993e1c54879db58881c115dc9e69da2d43071ae4ad11f60de9de604c831d508b
# Despite the name dog.jpg this is the Siberian tiger photo (the original parity run saved it under that name).
fetch dog.jpg $base/mishig/sample_images/resolve/main/tiger.jpg 2ae007fbc16880208ba5fb699e52806cb0eadf41b12fc115cfd92b995b275fd8
