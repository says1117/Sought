# MLEncoders (T-032, model-agnostic since T-074)

Swift side of the CLIP retrieval encoders (default OpenCLIP ViT-B/32, 224 px; MobileCLIP-S0, 256 px, as fallback). **No model files, vocab or merges are committed.**

- `Retrieval/CLIPTokenizer.swift`: CLIP BPE tokenizer (77 ids, start 49406, end 49407, pad 0). File loaders VALIDATE
  the vocabulary (49,408 entries, special ids, 48,894 merges, byte symbols, merge closure) and throw a typed error.
  `init(vocab:merges:)` is the unvalidated test initializer.
- `Retrieval/CLIPTextCleaning.swift`: stand-in for `ftfy.fix_text` + `html.unescape` x2 (NFC, ligatures, HTML entities,
  mojibake, NUL/control chars, curly quotes, full-width ASCII). Not ported: ftfy's cp1252 mojibake variants and the full
  HTML5 entity table.
- `CoreMLTextEncoder` (Retrieval `TextEncoder`), `CoreMLImageEmbedder` (Perception `CropEmbedder`),
  `CoreMLLookEmbedder` (FindExecutor `ImageEmbedder`, needs an app `LookCropProviding` adapter that
  projects the world point into the ARKit frame and crops).
- `ModelConfig`: name, `image_size`, `embedding_dim`, `context_length` (must be 77), `normalization_baked` (must be true),
  model base names. Read from `model_config.json` next to the models by `ModelLocator.loadConfig()`; absent = MobileCLIP-S0
  (256, 512, 77); present but invalid = a `ModelConfigError` (never a silent fallback). Image size, output dimension and
  the arrival-crop path (`CoreMLLookEmbedder`) all follow the config.
- `ImagePreprocessing`: a port of PIL's bicubic antialiased resize + torchvision CenterCrop to `size` x `size` RGB bytes
  (0...255; size from the config). Scale and mean/std are inside the Core ML graph. Matches the PIL reference byte for byte on the test images.
- `ModelLocator`: app bundle root, bundle subfolders (recursive), then `Application Support/Recall/Models/`
  (which may hold a raw `.mlpackage`; it is compiled once and cached in `Compiled/`).

## Producing and bundling the files (Steven)

```bash
cd ml/conversion && ./setup.sh && source ../.venv/bin/activate
python convert_openclip.py && python export_tokenizer.py
./install_models.sh          # clip-vit-b32 into ios/Recall/Resources/Models and Resources/Tokenizer (gitignored)
cd ../../ios/Recall && xcodegen generate
```

Fallback: `./setup.sh mobileclip-s0`, `python convert.py`, `./install_models.sh mobileclip-s0` (research-only licence).

Then build to the phone from Xcode. `project.yml` lists both Resources folders as optional sources, so the app also
builds when they are empty. Alternative with no rebuild: copy the `.mlpackage` files plus `model_config.json`, `vocab.json` and `merges.txt`
into the app container's `Application Support/Recall/Models/`. Read the model licence first (ml/conversion/README.md).

Real-vocab golden test: `RECALL_TOKENIZER_DIR=<dir with vocab.json+merges.txt> swift test --filter MLEncodersTests`
(put an `extra_golden.json` of the same shape as the fixture in that dir for a wider comparison).
Preprocessing parity: `Tests/MLEncodersTests/Tools/preproc_reference.py` (see its docstring; `--size 224` and
`RECALL_PREPROC_SIZE=224` for the default model). Real-model test: `RECALL_MODELS_DIR=<folder with the packages, model_config.json,
vocab.json, merges.txt> RECALL_PREPROC_DIR=<dir with dog.png> swift test --filter MLEncodersTests`.
