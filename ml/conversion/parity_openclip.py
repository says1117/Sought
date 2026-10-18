"""Core ML vs original open_clip (ViT-B-32 laion2b_s34b_b79k): cosine per image/phrase, zero-shot sanity, timing.

Usage: python parity_openclip.py [--ckpt ...] [--build build/clip-vit-b32] [--data data] [--compute CPU_ONLY]
Images: 2 synthetic + for each real photo in data/ the full frame plus 3 derived crops (centre half,
top-left half, bottom-right third), so >= 12 images from only 3 photos. Derived crops are NOT independent photos.
Core ML is fed the open_clip preprocessing minus normalisation (PIL bicubic Resize(224) + CenterCrop(224)), as raw bytes.
"""
import argparse
import glob
import platform
import time
import numpy as np
import torch
import open_clip
import coremltools as ct
from PIL import Image
from convert_openclip import load, SIZE

PHRASES = ["a cat", "a tiger", "a dog", "a red mug", "a set of keys", "a laptop", "a photo of a cat",
           "a car engine", "the blue backpack by the door", "a person playing music", "a remote control",
           "a wooden chair", "an empty room", "a banana"]


def cos(a, b):
    a, b = a.ravel().astype(np.float64), b.ravel().astype(np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def images(data):
    rng = np.random.default_rng(0)
    out = [("synthetic-noise", Image.fromarray(rng.integers(0, 256, (256, 256, 3), dtype=np.uint8)))]
    g = np.tile(np.linspace(0, 255, 256, dtype=np.uint8), (256, 1))
    out.append(("synthetic-gradient", Image.fromarray(np.stack([g, g.T, 255 - g], -1))))
    for p in sorted(glob.glob(f"{data}/*.png") + glob.glob(f"{data}/*.jpg")):
        im, n = Image.open(p).convert("RGB"), p.split("/")[-1]
        w, h = im.size
        out += [(n, im), (n + ":centre-half", im.crop((w // 4, h // 4, w * 3 // 4, h * 3 // 4))),
                (n + ":top-left-half", im.crop((0, 0, w // 2, h // 2))),
                (n + ":bottom-right-third", im.crop((w * 2 // 3, h * 2 // 3, w, h)))]
    return out


def prep(im):  # open_clip Resize(224, BICUBIC) + CenterCrop(224), bytes kept 0..255
    w, h = im.size
    s = SIZE / min(w, h)
    r = im.resize((max(SIZE, int(SIZE * w / min(w, h))), max(SIZE, int(SIZE * h / min(w, h)))), Image.BICUBIC)
    l, t = int(round((r.width - SIZE) / 2)), int(round((r.height - SIZE) / 2))
    return r.crop((l, t, l + SIZE, t + SIZE))


def timeit(f, n=30):
    f(); f()
    ts = []
    for _ in range(n):
        t = time.perf_counter(); f(); ts.append((time.perf_counter() - t) * 1000)
    return np.median(ts), np.percentile(ts, 95)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default="checkpoints/open_clip_model.safetensors")
    ap.add_argument("--build", default="build/clip-vit-b32")
    ap.add_argument("--data", default="data")
    ap.add_argument("--compute", default="CPU_ONLY", choices=["ALL", "CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE"])
    ap.add_argument("--precision-label", default="fp16")
    a = ap.parse_args()
    model, pre = load(a.ckpt)
    cu = getattr(ct.ComputeUnit, a.compute)
    mi = ct.models.MLModel(f"{a.build}/CLIP_ViT_B32_Image.mlpackage", compute_units=cu)
    mt = ct.models.MLModel(f"{a.build}/CLIP_ViT_B32_Text.mlpackage", compute_units=cu)
    print(f"machine={platform.platform()} {platform.machine()} coremltools={ct.__version__} torch={torch.__version__} "
          f"compute_units={a.compute} model_precision={a.precision_label}")
    imgs = images(a.data)
    cs_i, cs_t, ie_c, te_c = [], [], [], []
    for name, im in imgs:
        with torch.no_grad():
            et = torch.nn.functional.normalize(model.encode_image(pre(im).unsqueeze(0)), dim=-1).numpy()
        ec = np.array(mi.predict({"image": prep(im)})["embedding"])
        cs_i.append(cos(et, ec)); ie_c.append(ec[0])
        print(f"image {name:36s} cosine(open_clip, coreml) = {cs_i[-1]:.6f}")
    tk = open_clip.get_tokenizer("ViT-B-32")
    for ph in PHRASES:
        tok = tk([ph])
        with torch.no_grad():
            et = torch.nn.functional.normalize(model.encode_text(tok), dim=-1).numpy()
        ec = np.array(mt.predict({"tokens": tok.numpy().astype(np.int32)})["embedding"])
        cs_t.append(cos(et, ec)); te_c.append(ec[0])
        print(f"text  {ph:36s} cosine(open_clip, coreml) = {cs_t[-1]:.6f}")
    for label, cs in (("image", cs_i), ("text", cs_t)):
        print(f"{label}: n={len(cs)} min cosine = {min(cs):.6f} mean = {np.mean(cs):.6f}")
    print("\nZero-shot sanity (Core ML image x Core ML text cosine), full-frame photos only:")
    cols = [0, 1, 2, 7]
    print(" " * 22 + " ".join(f"{PHRASES[j][:12]:>12s}" for j in cols))
    for i, (n, _) in enumerate(imgs):
        if n.startswith("synthetic") or ":" in n:
            continue
        print(f"{n[:20]:22s}" + " ".join(f"{float(ie_c[i] @ te_c[j]):12.3f}" for j in cols))
    im0 = prep(imgs[2][1]); tok = tk(["a tiger"]).numpy().astype(np.int32)
    mi_med, mi_p95 = timeit(lambda: mi.predict({"image": im0}))
    mt_med, mt_p95 = timeit(lambda: mt.predict({"tokens": tok}))
    print(f"\nTiming ({platform.machine()} Mac, {platform.platform()}, compute_units={a.compute}, {a.precision_label}, "
          f"coremltools predict() incl. Python marshalling, 30 warm runs after 2 warm-ups; NOT phone numbers):")
    print(f"image encoder median {mi_med:.1f} ms p95 {mi_p95:.1f} ms; text encoder median {mt_med:.1f} ms p95 {mt_p95:.1f} ms")
    return 0 if min(cs_i + cs_t) > 0.99 else 1


if __name__ == "__main__":
    raise SystemExit(main())
