"""Measure ImagePreprocessing (Swift) against the PIL/torchvision reference used by PR 7's conversion.

Not part of the build; needs the ml venv (ml/conversion/README.md: ./setup.sh, source ../.venv/bin/activate).

  python preproc_reference.py make OUT_DIR [IMG ...] [--size 224]   writes OUT_DIR/<name>.png + <name>.ref.rgb
        (reference = torchvision Resize(SIZE, BICUBIC) + CenterCrop(SIZE) on a PIL image, which is the CLIP /
        MobileCLIP transform, as raw RGB bytes, SIZE*SIZE*3; SIZE defaults to 256 = MobileCLIP-S0, use 224 for
        CLIP ViT-B/32). Uses deterministic synthetic images plus any IMG paths.
  (run the Swift test with RECALL_PREPROC_DIR=OUT_DIR RECALL_PREPROC_SIZE=SIZE; it writes <name>.swift_new.rgb /
   .swift_old.rgb)
  python preproc_reference.py compare OUT_DIR [--size 224] [--image-model path/to/Image.mlpackage]
        prints mean abs pixel difference per image and, if the Core ML image model is given, the cosine
        between embeddings of the Swift-preprocessed and the PIL-preprocessed inputs.
"""
import glob, os, sys
import numpy as np
from PIL import Image
from torchvision import transforms as T

SIZE = 256


def synth():
    rng = np.random.default_rng(7)
    out = []
    y, x = np.mgrid[0:768, 0:1024]
    a = np.stack([(x / 1024 * 255), (y / 768 * 255), ((x + y) % 256)], -1)
    a[(x // 4 + y // 4) % 2 == 0] *= 0.6                      # fine checker: exposes aliasing
    a[300:340, :, :] = 250; a[:, 500:506, :] = 5               # hard edges
    out.append(("synth_checker_1024x768", a))
    y, x = np.mgrid[0:480, 0:640]
    b = 127 + 100 * (np.sin(x / 3.0) * np.cos(y / 5.0))[..., None] * np.ones(3) + rng.normal(0, 12, (480, 640, 3))
    out.append(("synth_sines_640x480", b))
    c = rng.integers(0, 256, (300, 300, 3)).astype(float)       # white noise, mild downscale
    out.append(("synth_noise_300x300", c))
    d = np.zeros((150, 200, 3)); d[::10] = 255; d[:, ::7, 1] = 255   # upscale case
    out.append(("synth_lines_200x150", d))
    return [(n, Image.fromarray(np.clip(v, 0, 255).astype(np.uint8))) for n, v in out]


def reference(im):
    t = T.Compose([T.Resize(SIZE, interpolation=T.InterpolationMode.BICUBIC), T.CenterCrop(SIZE)])
    return np.asarray(t(im.convert("RGB")), dtype=np.uint8)


def make(out, paths):
    os.makedirs(out, exist_ok=True)
    imgs = synth()
    for p in paths:
        imgs.append((os.path.splitext(os.path.basename(p))[0], Image.open(p).convert("RGB")))
        w, h = imgs[-1][1].size   # also a small detector-style crop of the middle
        imgs.append((imgs[-1][0] + "_crop", imgs[-1][1].crop((w // 4, h // 4, w // 4 + w // 2, h // 4 + h // 2))))
    for name, im in imgs:
        im.save(f"{out}/{name}.png")
        reference(im).tofile(f"{out}/{name}.ref.rgb")
        print("wrote", name, im.size)


def compare(out, mp):
    import coremltools as ct
    model = None
    if mp and os.path.exists(mp):
        model = ct.models.MLModel(mp, compute_units=ct.ComputeUnit.CPU_ONLY)
    else:
        print("NOTE: Core ML image model not found; embedding drift NOT measured")

    def emb(rgb):
        e = np.array(model.predict({"image": Image.fromarray(rgb)})["embedding"]).ravel().astype(np.float64)
        return e / np.linalg.norm(e)

    for ref_path in sorted(glob.glob(f"{out}/*.ref.rgb")):
        name = os.path.basename(ref_path)[: -len(".ref.rgb")]
        ref = np.fromfile(ref_path, np.uint8).reshape(SIZE, SIZE, 3)
        line = f"{name:28s}"
        for tag in ("old", "new"):
            p = f"{out}/{name}.swift_{tag}.rgb"
            if not os.path.exists(p):
                continue
            sw = np.fromfile(p, np.uint8).reshape(SIZE, SIZE, 3)
            mae = np.abs(sw.astype(float) - ref.astype(float)).mean()
            line += f"  {tag}: MAE={mae:7.3f}"
            if model is not None:
                line += f" cos={float(emb(sw) @ emb(ref)):.5f}"
        print(line)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--size" in args:
        i = args.index("--size"); SIZE = int(args[i + 1]); del args[i:i + 2]
    if args[0] == "make":
        make(args[1], args[2:])
    else:
        mp = None
        if "--image-model" in args:
            i = args.index("--image-model"); mp = args[i + 1]; del args[i:i + 2]
        compare(args[1], mp)
