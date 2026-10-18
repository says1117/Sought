#!/usr/bin/env bash
# Copy a converted model set into the iOS app's (gitignored) resource folders.
#
# Usage: ./install_models.sh [--memory-cleared] [MODEL] [DEST] [SRC]
#   MODEL  clip-vit-b32 (default, open licence) | mobileclip-s0 (fallback, research-only licence)
#   DEST   resource root; gets Models/ and Tokenizer/   (default: ../../ios/Recall/Resources)
#   SRC    folder holding the converter output.
#          clip-vit-b32 default:  ./build/clip-vit-b32  (+ ./build/tokenizer)
#          mobileclip-s0 default: ./build               (+ ./build/tokenizer)
#          A flat folder (models, model_config.json, vocab.json, merges.txt side by side, e.g.
#          ~/Desktop/Projects/Recall-models/clip-vit-b32) works too: tokenizer files are taken from SRC/tokenizer/
#          or from SRC itself.
#
# ENCODER FAMILY SWITCH: both families emit 512-d unit vectors, but the vectors are NOT comparable, and stored tracks carry no
# encoder identity. Switching family (including to or from the fallback) makes old object memory silently wrong, so the
# phone's saved object memory and world maps must be cleared first (delete the Recall app from the phone, which removes
# its container). If DEST/Models already holds the OTHER family, this script refuses unless you pass --memory-cleared.
# See "Switching encoder family" in README.md.
#
# Writes DEST/Models/{<image>.mlpackage,<text>.mlpackage,model_config.json (clip only)} and DEST/Tokenizer/{vocab.json,merges.txt}.
# Removes the OTHER model's packages and a stale model_config.json from DEST/Models so only one model set ships.
# Never commit what this writes (.gitignore covers both folders). Xcode compiles the .mlpackage files to .mlmodelc.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ACK=0
args=()
for a in "$@"; do [ "$a" = "--memory-cleared" ] && ACK=1 || args+=("$a"); done
set -- ${args[@]+"${args[@]}"}
MODEL="${1:-clip-vit-b32}"
DEST="${2:-$HERE/../../ios/Recall/Resources}"
case "$MODEL" in
  clip-vit-b32)  IMG=CLIP_ViT_B32_Image;  TXT=CLIP_ViT_B32_Text;  OTHER="MobileCLIP_S0_Image MobileCLIP_S0_Text"; DEFSRC="$HERE/build/clip-vit-b32"; NEEDCFG=1 ;;
  mobileclip-s0) IMG=MobileCLIP_S0_Image; TXT=MobileCLIP_S0_Text; OTHER="CLIP_ViT_B32_Image CLIP_ViT_B32_Text";  DEFSRC="$HERE/build";           NEEDCFG=0 ;;
  *) echo "unknown model '$MODEL' (use clip-vit-b32 or mobileclip-s0)" >&2; exit 2 ;;
esac
SRC="${3:-$DEFSRC}"
MODELS="$DEST/Models"
TOK="$DEST/Tokenizer"

if   [ -f "$SRC/tokenizer/vocab.json" ]; then TSRC="$SRC/tokenizer"
elif [ -f "$SRC/vocab.json" ];           then TSRC="$SRC"
else TSRC="$HERE/build/tokenizer"; fi

missing=0
need=("$SRC/$IMG.mlpackage" "$SRC/$TXT.mlpackage" "$TSRC/vocab.json" "$TSRC/merges.txt")
[ "$NEEDCFG" = 1 ] && need+=("$SRC/model_config.json")
for p in "${need[@]}"; do
  [ -e "$p" ] || { echo "MISSING: $p" >&2; missing=1; }
done
[ "$missing" = 0 ] || { echo "Run the converter and export_tokenizer.py first (see README.md)." >&2; exit 1; }

# sanity: the real vocabulary has 48,894 merge lines
lines=$(wc -l < "$TSRC/merges.txt" | tr -d ' ')
[ "$lines" = 48894 ] || { echo "merges.txt has $lines lines, expected 48894" >&2; exit 1; }

for m in $OTHER; do
  if [ -e "$MODELS/$m.mlpackage" ] && [ "$ACK" != 1 ]; then
    echo "REFUSING: $MODELS already holds the other encoder family ($m)." >&2
    echo "Embeddings from the two families are not comparable and saved tracks carry no encoder identity." >&2
    echo "Clear the phone's object memory first (delete the Recall app from the phone), then re-run with --memory-cleared." >&2
    exit 3
  fi
done

mkdir -p "$MODELS" "$TOK"
for m in $OTHER; do rm -rf "$MODELS/$m.mlpackage"; done
rm -f "$MODELS/model_config.json"
for m in "$IMG" "$TXT"; do
  rm -rf "$MODELS/$m.mlpackage"
  cp -R "$SRC/$m.mlpackage" "$MODELS/$m.mlpackage"
  echo "copied $m.mlpackage -> $MODELS/"
done
if [ "$NEEDCFG" = 1 ]; then cp "$SRC/model_config.json" "$MODELS/model_config.json"; echo "copied model_config.json -> $MODELS/"; fi
cp "$TSRC/vocab.json" "$TSRC/merges.txt" "$TOK/"
echo "copied vocab.json, merges.txt ($lines merges) -> $TOK/"
echo
echo "REMINDER: if the phone ever ran the other encoder family, delete the Recall app from the phone before the first run (see README 'Switching encoder family')."
echo "Installed $MODEL. Next: cd ios/Recall && xcodegen generate, then build to the phone. These files are gitignored; do not commit them."
git -C "$HERE" status --short -- "$DEST" 2>/dev/null | grep -v '^??' || true
