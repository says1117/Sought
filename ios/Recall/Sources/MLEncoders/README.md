# MLEncoders (T-032)

Swift side of the MobileCLIP-S0 retrieval encoders. **No model files, vocab or merges are committed.**

- `Retrieval/CLIPTokenizer.swift`: CLIP BPE tokenizer (77 ids, start 49406, end 49407, pad 0). File loaders VALIDATE
  the vocabulary (49,408 entries, special ids, 48,894 merges, byte symbols, merge closure) and throw a typed error.
  `init(vocab:merges:)` is the unvalidated test initializer.
- `Retrieval/CLIPTextCleaning.swift`: stand-in for `ftfy.fix_text` + `html.unescape` x2 (NFC, ligatures, HTML entities,
  mojibake, NUL/control chars, curly quotes, full-width ASCII). Not ported: ftfy's cp1252 mojibake variants and the full
  HTML5 entity table.
- `CoreMLTextEncoder` (Retrieval `TextEncoder`), `CoreMLImageEmbedder` (Perception `CropEmbedder`),
  `CoreMLLookEmbedder` (FindExecutor `ImageEmbedder`, needs an app `LookCropProviding` adapter that
  projects the world point into the ARKit frame and crops).
- `ImagePreprocessing`: a port of PIL's bicubic antialiased resize + torchvision CenterCrop, 256x256 RGB bytes
  (0...255). The 1/255 scale is inside the Core ML graph. Matches the PIL reference byte for byte on the test images.
- `ModelLocator`: app bundle root, bundle subfolders (recursive), then `Application Support/Recall/Models/`
  (which may hold a raw `.mlpackage`; it is compiled once and cached in `Compiled/`).

## Producing and bundling the files (Steven)

```bash
cd ml/conversion && ./setup.sh && source ../.venv/bin/activate
python convert.py            # build/MobileCLIP_S0_{Image,Text}.mlpackage
python export_tokenizer.py   # build/tokenizer/{vocab.json,merges.txt}
./install_models.sh          # copies into ios/Recall/Resources/Models and Resources/Tokenizer (gitignored)
cd ../../ios/Recall && xcodegen generate
```

Then build to the phone from Xcode. `project.yml` lists both Resources folders as optional sources, so the app also
builds when they are empty. Alternative with no rebuild: copy the `.mlpackage` files plus `vocab.json` and `merges.txt`
into the app container's `Application Support/Recall/Models/`. Read the model licence first (ml/conversion/README.md).

Real-vocab golden test: `RECALL_TOKENIZER_DIR=<dir with vocab.json+merges.txt> swift test --filter MLEncodersTests`
(put an `extra_golden.json` of the same shape as the fixture in that dir for a wider comparison).
Preprocessing parity: `Tests/MLEncodersTests/Tools/preproc_reference.py` (see its docstring).
