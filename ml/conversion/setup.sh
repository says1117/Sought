#!/usr/bin/env bash
# Creates ml/.venv (gitignored), installs pinned deps, downloads the checkpoint + sample images.
# Usage: ./setup.sh [clip-vit-b32 | mobileclip-s0]    (default clip-vit-b32, MIT; mobileclip-s0 is the research-only fallback)
set -euo pipefail
MODEL="${1:-clip-vit-b32}"
cd "$(dirname "$0")"
PY=${PYTHON:-python3.11}
$PY -m venv ../.venv
../.venv/bin/pip install -q -r requirements.txt
[ "$MODEL" = mobileclip-s0 ] && ../.venv/bin/pip install -q --no-deps -r requirements-mobileclip.txt
mkdir -p checkpoints data
verify_sha256() { # path expected_sha256
  local path="$1" expected="$2" got
  got=$(shasum -a 256 "$path" | cut -d' ' -f1)
  if [ "$got" != "$expected" ]; then
    rm -f "$path"
    echo "sha256 mismatch for $path (got $got)" >&2
    exit 1
  fi
}
case "$MODEL" in
  clip-vit-b32)
    checkpoint=checkpoints/open_clip_model.safetensors
    [ -f "$checkpoint" ] || curl -fL -o "$checkpoint" \
      https://huggingface.co/laion/CLIP-ViT-B-32-laion2B-s34B-b79K/resolve/main/open_clip_model.safetensors
    verify_sha256 "$checkpoint" ac4f8c4b88af6d963118cbf40ad93176d092abbedfcb752601ae1866352656e6 ;;
  mobileclip-s0)
    checkpoint=checkpoints/mobileclip_s0.pt
    [ -f "$checkpoint" ] || curl -fL -o "$checkpoint" \
      https://huggingface.co/apple/MobileCLIP-S0/resolve/main/mobileclip_s0.pt
    verify_sha256 "$checkpoint" 809b408eff74f8058843e86a1f92967097d42ba782450e85b8f4867b7f0ca0b7 ;;
  *) echo "unknown model '$MODEL'" >&2; exit 2 ;;
esac
# Sample images for the parity check (any images in data/ are used; synthetic ones are always added).
# Each download is verified against a pinned sha256; a mismatch deletes the file and fails the script.
fetch() { # name url sha256
  [ -f "data/$1" ] || curl -fL -o "data/$1" "$2"
  verify_sha256 "data/$1" "$3"
}
base=https://huggingface.co/datasets
fetch cats.png $base/huggingface/documentation-images/resolve/main/coco_sample.png cf6f3c4befa148732c7453e0de5afab00f682427435fead2d88b07a9615cdac2
fetch cat_dog_music.png $base/mishig/sample_images/resolve/main/cat-dog-music.png 993e1c54879db58881c115dc9e69da2d43071ae4ad11f60de9de604c831d508b
# Despite the name dog.jpg this is the Siberian tiger photo (the original parity run saved it under that name).
fetch dog.jpg $base/mishig/sample_images/resolve/main/tiger.jpg 2ae007fbc16880208ba5fb699e52806cb0eadf41b12fc115cfd92b995b275fd8
