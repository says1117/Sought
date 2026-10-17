id: T-043
title: Release hysteresis for front/rear blocked flags
role: firmware
size: S
status: claimed
owner: firmware
depends: 
read: firmware/navigator/safety.h, firmware/navigator/navigator.ino, firmware/test/test_safety.cpp
created: 2026-10-17T11:38:38Z
doing: Release hysteresis in safety.h + tests
doing_at: 2026-10-17T11:39:07Z
---
Engage on one close reading, release after 3 consecutive clear readings.
