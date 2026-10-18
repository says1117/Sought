"""Convert the open-licence OpenCLIP ViT-B/32 (laion2b_s34b_b79k, MIT) image and text encoders to Core ML.

Usage (from ml/conversion, with ../.venv active):
    python convert_openclip.py [--ckpt checkpoints/open_clip_model.safetensors] [--out build/clip-vit-b32]

Same Core ML contract as convert.py (MobileCLIP): input "image" / "tokens", output "embedding" [1,512],
L2-normalised in-graph, tokens int32 [1,77]. Differences: image is 224x224 and CLIP's mean/std
normalisation is baked into the graph (the ImageType only applies scale 1/255), so the app still passes raw
RGB bytes 0...255. Also writes model_config.json next to the packages (read by the Swift ModelLocator).
"""
import argparse
import json
import os
import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct
import open_clip

# nn.MultiheadAttention's eval fast path traces to _native_multi_head_attention, which coremltools lacks.
torch.backends.mha.set_fastpath_enabled(False)

MODEL = "ViT-B-32"
PRETRAINED = "laion2b_s34b_b79k"
SIZE = 224
MEAN = (0.48145466, 0.4578275, 0.40821073)   # OpenAI CLIP / open_clip default for this model
STD = (0.26862954, 0.26130258, 0.27577711)


class ImageWrap(torch.nn.Module):
    """Input: RGB in 0...1 (Core ML applies scale 1/255 to the 0...255 pixels). Normalises, encodes, unit-norms."""
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image):
        return F.normalize(self.m.encode_image((image - self.mean) / self.std), dim=-1)


class TextWrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, tokens):
        return F.normalize(self.m.encode_text(tokens.long()), dim=-1)


def load(ckpt):
    model, _, preprocess = open_clip.create_model_and_transforms(MODEL, pretrained=ckpt)
    return model.eval(), preprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default="checkpoints/open_clip_model.safetensors")
    ap.add_argument("--out", default="build/clip-vit-b32")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    prec = ct.precision.FLOAT16 if a.precision == "fp16" else ct.precision.FLOAT32
    model, _ = load(a.ckpt)

    with torch.no_grad():
        traced = torch.jit.trace(ImageWrap(model).eval(), torch.rand(1, 3, SIZE, SIZE))
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17, compute_precision=prec,
    )
    ml.short_description = "OpenCLIP ViT-B/32 laion2b_s34b_b79k image encoder (MIT), mean/std baked in, see ml/conversion/README.md"
    ml.save(f"{a.out}/CLIP_ViT_B32_Image.mlpackage")

    tok = torch.zeros(1, 77, dtype=torch.int32)
    tok[0, 0], tok[0, 1] = 49406, 49407
    with torch.no_grad():
        traced = torch.jit.trace(TextWrap(model).eval(), tok)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=(1, 77), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17, compute_precision=prec,
    )
    ml.short_description = "OpenCLIP ViT-B/32 laion2b_s34b_b79k text encoder (MIT), CLIP BPE tokens in, unit-norm embedding out"
    ml.save(f"{a.out}/CLIP_ViT_B32_Text.mlpackage")

    cfg = {"name": "clip-vit-b32-laion2b", "image_size": SIZE, "embedding_dim": 512, "context_length": 77,
           "normalization_baked": True, "image_model": "CLIP_ViT_B32_Image", "text_model": "CLIP_ViT_B32_Text"}
    with open(f"{a.out}/model_config.json", "w") as f:
        json.dump(cfg, f, indent=2); f.write("\n")
    print("saved to", a.out)


if __name__ == "__main__":
    main()
