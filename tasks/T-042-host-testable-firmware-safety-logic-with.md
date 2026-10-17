id: T-042
title: Host-testable firmware safety logic with plain C++ tests
role: firmware
size: M
status: open
owner: 
depends: 
read: firmware/navigator/navigator.ino, docs/03_CONTRACTS.md#1
created: 2026-10-17T11:14:03Z
---
Extract watchdog, sonar clamp, slew and PWM mapping into a header with no Arduino dependencies and test it on the Mac.
