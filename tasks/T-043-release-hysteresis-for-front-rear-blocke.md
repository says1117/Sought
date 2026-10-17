id: T-043
title: Release hysteresis for front/rear blocked flags
role: firmware
size: S
status: done
owner: firmware
depends: 
read: firmware/navigator/safety.h, firmware/navigator/navigator.ino, firmware/test/test_safety.cpp
created: 2026-10-17T11:38:38Z
doing: 
doing_at: 2026-10-17T11:39:07Z
---
Engage on one close reading, release after 3 consecutive clear readings.

[2026-10-17T11:40:48Z] firmware -> review: PR 25: hysteresis (3 clear measurements), 35 host tests pass, mutation check fails replay, arduino-cli compile OK 84% flash. Not flashed.

[2026-10-17T18:09:38Z] firmware -> done: PR 25 merged by Steven; not yet flashed
