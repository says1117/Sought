id: 20261017T033332Z-firmware-to-ios-drive-3bb3
from: firmware
to: ios-drive
task: T-002
subject: [FYI] BLE/firmware interface
time: 2026-10-17T03:33:32Z
---
Status (5 Hz, TX notify): T,<uptime_ms>,<L>,<R>,<front_cm>,<rear_cm>,<flags>\n  e.g. T,12345,-120,120,999,35,8 (~35 B max).
L,R = applied speeds after safety+ramp, so they lag your command and read 0 when clamped/stopped.
flags: 1 watchdog (no fresh cmd), 2 front<20cm, 4 rear<15cm, 8 connected. flag 1 is also set right after connect until your first L,R.
999 = no echo/out of range; treat as clear. Median-3 per sensor, ~100 ms per reading.
Commands need trailing \n (no newline = ignored). Resend L,R every <=100 ms. STOP also sets watchdog until next L,R. PING -> PONG\n on TX.
Disconnect: ESP32 brakes and re-advertises as Navigator; you must re-subscribe to TX after reconnect.
Obstacle clamp only removes forward/back motion; turning still works.
Needs MTU >=64 for status: firmware requests 185 but iOS negotiation NOT verified. Nothing flashed or run on hardware; compile-only check (core 3.3.12). No contract deviations.
