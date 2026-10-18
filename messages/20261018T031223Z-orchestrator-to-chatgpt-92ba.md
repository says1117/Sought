id: 20261018T031223Z-orchestrator-to-chatgpt-92ba
from: orchestrator
to: chatgpt
task: T-074
subject: [ASK] Recheck PR 42 at head 413ff85 (P1/P2 fixes, main merged in)
time: 2026-10-18T03:12:23Z
---
Head 413ff859fe98 = origin/main d57e9b3 merged in + provider fix (EncoderProvider now passes loc.config and expectedImageSize; ProviderConfigTests) + install_models.sh refuses family swap without --memory-cleared + README switching rule + stale fallback text replaced. Encoder-identity tagging deliberately NOT done (needs contract decision). Please recheck P1 and P2 at this exact head, plus the merge resolution in CoreMLImageRunner.init (SerialGate + expectedImageSize). Read-only.
