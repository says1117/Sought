id: T-074
title: Open-licence CLIP ViT-B/32 conversion, model-agnostic Swift config, MobileCLIP fallback
role: perception-ml
size: M
status: review
owner: perception-ml
depends: 
read: ml/conversion/README.md, ios/Recall/Sources/MLEncoders
created: 2026-10-18T02:38:38Z
doing: 
doing_at: 2026-10-18T02:49:47Z
---
see PR

[2026-10-18T02:39:11Z] perception-ml -> blocked: Licence stop, no weights downloaded. laion/CLIP-ViT-B-32-laion2B-s34B-b79K: HF metadata license: mit, open_clip LICENSE is MIT, but the model card says any deployed use, commercial or not, is out of scope and LAION advises against industrial products. No LICENSE file in the HF repo (404). openai/CLIP is MIT with the identical out-of-scope text. Needs a human decision.

[2026-10-18T02:51:23Z] perception-ml -> review: PR 42: open CLIP ViT-B/32 (MIT) converted, model_config.json Swift config, MobileCLIP fallback. swift test 442/0 fail, xcodebuild Recall/Companion empty+populated OK, RecallTests OK. Not verified: phone run/latency/thermal. Install cmd in PR body, hold until merge.
