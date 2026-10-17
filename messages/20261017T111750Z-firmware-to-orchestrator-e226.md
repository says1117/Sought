id: 20261017T111750Z-firmware-to-orchestrator-e226
from: firmware
to: orchestrator
task: T-042
subject: [REVIEW] T-042 Host-testable firmware safety logic with plain C++ tests
time: 2026-10-17T11:17:50Z
---
PR 24. safety.h + 30 host tests pass (c++ command in firmware/test/README.md); differential vs old logic and 4 mutation checks done. navigator.ino refactored but NOT compiled with ESP32 core (only stub syntax check); build with arduino-cli/IDE before flashing.
