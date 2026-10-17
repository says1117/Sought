"""Measure ImagePreprocessing (Swift) against the PIL/torchvision reference used by PR 7's conversion.

Not part of the build; needs the ml venv (ml/conversion/README.md: ./setup.sh, source ../.venv/bin/activate).

  python preproc_reference.py make OUT_DIR [IMG ...]   writes OUT_DIR/<name>.png + <name>.ref.rgb
        (reference = torchvision Resize(256, BICUBIC) + CenterCrop(256) on a PIL image, exactly MobileCLIP's
        transform, as raw RGB bytes, 256*256*3). Uses deterministic synthetic images plus any IMG paths.
  (run the Swift test with RECALL_PREPROC_DIR=OUT_DIR; it writes <name>.swift_new.rgb / .swift_old.rgb)
  python preproc_reference.py compare OUT_DIR [--model-dir ml/conversion/build]
        prints mean abs pixel difference per image and, if the Core ML image model exists, the cosine
        between embeddings of the Swift-preprocessed and the PIL-preprocessed inputs.
"""
import glob, os, sys
import numpy as np
from PIL import Image
from torchvision import transforms as T


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
    t = T.Compose([T.Resize(256, interpolation=T.InterpolationMode.BICUBIC), T.CenterCrop(256)])
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


def compare(out, model_dir):
    import coremltools as ct
    model = None
    mp = f"{model_dir}/MobileCLIP_S0_Image.mlpackage"
    if os.path.exists(mp):
        model = ct.models.MLModel(mp, compute_units=ct.ComputeUnit.CPU_ONLY)
    else:
        print("NOTE: Core ML image model not found; embedding drift NOT measured")

    def emb(rgb):
        e = np.array(model.predict({"image": Image.fromarray(rgb)})["embedding"]).ravel().astype(np.float64)
        return e / np.linalg.norm(e)

    for ref_path in sorted(glob.glob(f"{out}/*.ref.rgb")):
        name = os.path.basename(ref_path)[: -len(".ref.rgb")]
        ref = np.fromfile(ref_path, np.uint8).reshape(256, 256, 3)
        line = f"{name:28s}"
        for tag in ("old", "new"):
            p = f"{out}/{name}.swift_{tag}.rgb"
            if not os.path.exists(p):
                continue
            sw = np.fromfile(p, np.uint8).reshape(256, 256, 3)
            mae = np.abs(sw.astype(float) - ref.astype(float)).mean()
            line += f"  {tag}: MAE={mae:7.3f}"
            if model is not None:
                line += f" cos={float(emb(sw) @ emb(ref)):.5f}"
        print(line)


if __name__ == "__main__":
    if sys.argv[1] == "make":
        make(sys.argv[2], sys.argv[3:])
    else:
        md = sys.argv[sys.argv.index("--model-dir") + 1] if "--model-dir" in sys.argv else "ml/conversion/build"
        compare(sys.argv[2], md)
