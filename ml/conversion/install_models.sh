#!/usr/bin/env bash
# Copy the converter outputs into the iOS app's (gitignored) resource folders.
#   ml/conversion/build/MobileCLIP_S0_{Image,Text}.mlpackage -> ios/Recall/Resources/Models/
#   ml/conversion/build/tokenizer/{vocab.json,merges.txt}    -> ios/Recall/Resources/Tokenizer/
# Run after `python convert.py` and `python export_tokenizer.py`. Never commit what this writes
# (.gitignore covers both folders). Xcode compiles the .mlpackage files to .mlmodelc at the bundle root.
# Usage: ./install_models.sh [BUILD_DIR]      (default: ./build next to this script)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:-$HERE/build}"
RES="$HERE/../../ios/Recall/Resources"
MODELS="$RES/Models"
TOK="$RES/Tokenizer"

missing=0
for p in "$BUILD/MobileCLIP_S0_Image.mlpackage" "$BUILD/MobileCLIP_S0_Text.mlpackage" \
         "$BUILD/tokenizer/vocab.json" "$BUILD/tokenizer/merges.txt"; do
  [ -e "$p" ] || { echo "MISSING: $p" >&2; missing=1; }
done
[ "$missing" = 0 ] || { echo "Run convert.py and export_tokenizer.py first (see README.md)." >&2; exit 1; }

# sanity: the real vocabulary has 49,408 entries and 48,894 merge lines
lines=$(wc -l < "$BUILD/tokenizer/merges.txt" | tr -d ' ')
[ "$lines" = 48894 ] || { echo "merges.txt has $lines lines, expected 48894" >&2; exit 1; }

mkdir -p "$MODELS" "$TOK"
for m in MobileCLIP_S0_Image MobileCLIP_S0_Text; do
  rm -rf "$MODELS/$m.mlpackage"
  cp -R "$BUILD/$m.mlpackage" "$MODELS/$m.mlpackage"
  echo "copied $m.mlpackage -> ${MODELS#"$HERE"/../../}/"
done
cp "$BUILD/tokenizer/vocab.json" "$BUILD/tokenizer/merges.txt" "$TOK/"
echo "copied vocab.json, merges.txt ($lines merges) -> ${TOK#"$HERE"/../../}/"
echo
echo "Next: cd ios/Recall && xcodegen generate, then build to the phone. These files are gitignored; do not commit them."
git -C "$HERE" status --short -- "$RES" | grep -v '^??' || true
