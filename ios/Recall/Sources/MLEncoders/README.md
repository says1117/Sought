# MLEncoders (T-032)

Swift side of the MobileCLIP-S0 retrieval encoders. **No model files, vocab or merges are committed.**

- `Retrieval/CLIPTokenizer.swift`: CLIP BPE tokenizer (77 ids, start 49406, end 49407, pad 0).
- `CoreMLTextEncoder` (Retrieval `TextEncoder`), `CoreMLImageEmbedder` (Perception `CropEmbedder`),
  `CoreMLLookEmbedder` (FindExecutor `ImageEmbedder`, needs an app `LookCropProviding` adapter that
  projects the world point into the ARKit frame and crops).
- `ImagePreprocessing`: 256x256 RGB bytes (0...255). The 1/255 scale is inside the Core ML graph.
- `ModelLocator`: app bundle, then `Application Support/Recall/Models/`.

## Producing the files (from ml/conversion, PR 7)

```bash
cd ml/conversion && ./setup.sh && source ../.venv/bin/activate
python convert.py            # build/MobileCLIP_S0_{Image,Text}.mlpackage
python export_tokenizer.py   # build/tokenizer/{vocab.json,merges.txt}
xcrun coremlcompiler compile build/MobileCLIP_S0_Image.mlpackage build/compiled
xcrun coremlcompiler compile build/MobileCLIP_S0_Text.mlpackage  build/compiled
```

Either add `build/*.mlpackage`, `vocab.json`, `merges.txt` to the Recall target's resources (Xcode compiles
the packages to `MobileCLIP_S0_*.mlmodelc`), or copy `build/compiled/*.mlmodelc`, `vocab.json` and
`merges.txt` into the app's `Application Support/Recall/Models/`. Read the model licence first (PR 7 README).

Real-vocab golden test: `RECALL_TOKENIZER_DIR=<dir with vocab.json+merges.txt> swift test --filter MLEncodersTests`.
