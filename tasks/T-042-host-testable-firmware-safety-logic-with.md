id: T-042
title: Host-testable firmware safety logic with plain C++ tests
role: firmware
size: M
status: claimed
owner: firmware
depends: 
read: firmware/navigator/navigator.ino, docs/03_CONTRACTS.md#1
created: 2026-10-17T11:14:03Z
doing: safety.h written; writing legacy oracle + tests
doing_at: 2026-10-17T11:15:11Z
---
Extract watchdog, sonar clamp, slew and PWM mapping into a header with no Arduino dependencies and test it on the Mac.
