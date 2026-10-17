id: T-042
title: Host-testable firmware safety logic with plain C++ tests
role: firmware
size: M
status: review
owner: firmware
depends: 
read: firmware/navigator/navigator.ino, docs/03_CONTRACTS.md#1
created: 2026-10-17T11:14:03Z
doing: 
doing_at: 2026-10-17T11:17:17Z
---
Extract watchdog, sonar clamp, slew and PWM mapping into a header with no Arduino dependencies and test it on the Mac.

[2026-10-17T11:17:50Z] firmware -> review: PR 24. safety.h + 30 host tests pass (c++ command in firmware/test/README.md); differential vs old logic and 4 mutation checks done. navigator.ino refactored but NOT compiled with ESP32 core (only stub syntax check); build with arduino-cli/IDE before flashing.
