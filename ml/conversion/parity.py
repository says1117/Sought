"""Compare PyTorch vs Core ML embeddings (cosine) for a handful of images and phrases.

Usage: python parity.py [--ckpt ...] [--build build] [--data data]
Needs macOS (Core ML runtime). Prints per-item cosines, min cosine, and a zero-shot sanity
table when real images are present in data/. Synthetic images are always included.
"""
import argparse
import glob
import platform
import numpy as np
import torch
from PIL import Image
import coremltools as ct
import mobileclip
from convert import load

PHRASES = ["a cat", "a tiger", "a red mug", "a set of keys", "a laptop", "a photo of a cat",
           "the blue backpack by the door"]


def synth_images():
    rng = np.random.default_rng(0)
    out = []
    out.append(("noise", Image.fromarray(rng.integers(0, 256, (256, 256, 3), dtype=np.uint8))))
    g = np.tile(np.linspace(0, 255, 256, dtype=np.uint8), (256, 1))
    out.append(("gradient", Image.fromarray(np.stack([g, g.T, 255 - g], -1))))
    return out


def cos(a, b):
    a, b = a.ravel().astype(np.float64), b.ravel().astype(np.float64)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default="checkpoints/mobileclip_s0.pt")
    ap.add_argument("--build", default="build")
    ap.add_argument("--data", default="data")
    ap.add_argument("--compute", default="CPU_ONLY", choices=["ALL", "CPU_ONLY", "CPU_AND_GPU", "CPU_AND_NE"])
    a = ap.parse_args()
    model, preprocess = load(a.ckpt)
    cu = getattr(ct.ComputeUnit, a.compute)
    mi = ct.models.MLModel(f"{a.build}/MobileCLIP_S0_Image.mlpackage", compute_units=cu)
    mt = ct.models.MLModel(f"{a.build}/MobileCLIP_S0_Text.mlpackage", compute_units=cu)

    imgs = synth_images()
    for p in sorted(glob.glob(f"{a.data}/*.png") + glob.glob(f"{a.data}/*.jpg")):
        imgs.append((p.split("/")[-1], Image.open(p).convert("RGB")))

    print(f"machine={platform.platform()} {platform.machine()} coremltools={ct.__version__} "
          f"torch={torch.__version__} compute_units={a.compute}")
    ie_t, ie_c = [], []
    cs = []
    for name, im in imgs:
        x = preprocess(im).unsqueeze(0)           # Resize(256) + CenterCrop(256) + ToTensor
        with torch.no_grad():
            et = torch.nn.functional.normalize(model.encode_image(x), dim=-1).numpy()
        sq = im.convert("RGB")
        w, h = sq.size
        s = 256 / min(w, h)
        sq = sq.resize((max(256, round(w * s)), max(256, round(h * s))), Image.BICUBIC)
        l, t = (sq.width - 256) // 2, (sq.height - 256) // 2
        crop = sq.crop((l, t, l + 256, t + 256))   # same preprocessing, fed to Core ML as an image
        ec = np.array(mi.predict({"image": crop})["embedding"])
        c = cos(et, ec); cs.append(c); ie_t.append(et[0]); ie_c.append(ec[0])
        print(f"image {name:20s} cosine(torch, coreml) = {c:.6f}")
    import open_clip
    tk = open_clip.get_tokenizer("ViT-B-16")
    te_t, te_c = [], []
    for ph in PHRASES:
        tok = tk([ph])
        with torch.no_grad():
            et = torch.nn.functional.normalize(model.encode_text(tok), dim=-1).numpy()
        ec = np.array(mt.predict({"tokens": tok.numpy().astype(np.int32)})["embedding"])
        c = cos(et, ec); cs.append(c); te_t.append(et[0]); te_c.append(ec[0])
        print(f"text  {ph:36s} cosine(torch, coreml) = {c:.6f}")
    print(f"min cosine over {len(cs)} items = {min(cs):.6f}  mean = {np.mean(cs):.6f}")

    real = [i for i, (n, _) in enumerate(imgs) if n not in ("noise", "gradient")]
    if real:
        print("\nZero-shot sanity (Core ML image x Core ML text cosine; text = 'raw' phrase only):")
        print(" " * 22 + " ".join(f"{p[:12]:>12s}" for p in PHRASES[:5]))
        for i in real:
            print(f"{imgs[i][0][:20]:22s}" + " ".join(f"{float(ie_c[i] @ te_c[j]):12.3f}" for j in range(5)))
    return 0 if min(cs) > 0.99 else 1


if __name__ == "__main__":
    raise SystemExit(main())
