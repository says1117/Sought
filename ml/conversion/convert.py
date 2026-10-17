"""Convert MobileCLIP-S0 image and text encoders to Core ML (.mlpackage, gitignored).

Usage (from ml/conversion, with ../.venv active):
    python convert.py [--ckpt checkpoints/mobileclip_s0.pt] [--out build]

Image model: input "image" 256x256 RGB (ImageType, scale 1/255, no mean/std, which is what
MobileCLIP's own preprocessing does), output "embedding" float [1,512], L2-normalised in-graph.
Text model: input "tokens" int32 [1,77] (CLIP BPE ids padded with 0), output "embedding"
[1,512], L2-normalised in-graph.
"""
import argparse
import os
import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct
import mobileclip

MODEL = "mobileclip_s0"


class ImageWrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, image):
        return F.normalize(self.m.encode_image(image), dim=-1)


class TextWrap(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, tokens):
        return F.normalize(self.m.encode_text(tokens.long()), dim=-1)


def load(ckpt):
    model, _, preprocess = mobileclip.create_model_and_transforms(MODEL, pretrained=ckpt, reparameterize=True)
    return model.eval(), preprocess


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", default="checkpoints/mobileclip_s0.pt")
    ap.add_argument("--out", default="build")
    ap.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    prec = ct.precision.FLOAT16 if a.precision == "fp16" else ct.precision.FLOAT32
    model, _ = load(a.ckpt)

    img = ImageWrap(model).eval()
    ex = torch.rand(1, 3, 256, 256)
    with torch.no_grad():
        traced = torch.jit.trace(img, ex)
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 256, 256), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        compute_precision=prec,
    )
    ml.short_description = "MobileCLIP-S0 image encoder (Apple, see ml/conversion/README.md for license)"
    ml.save(f"{a.out}/MobileCLIP_S0_Image.mlpackage")

    txt = TextWrap(model).eval()
    tok = torch.zeros(1, 77, dtype=torch.int32)
    tok[0, 0], tok[0, 1] = 49406, 49407
    with torch.no_grad():
        traced = torch.jit.trace(txt, tok)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=(1, 77), dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
        compute_precision=prec,
    )
    ml.short_description = "MobileCLIP-S0 text encoder (Apple), CLIP BPE tokens in, unit-norm embedding out"
    ml.save(f"{a.out}/MobileCLIP_S0_Text.mlpackage")
    print("saved to", a.out)


if __name__ == "__main__":
    main()
