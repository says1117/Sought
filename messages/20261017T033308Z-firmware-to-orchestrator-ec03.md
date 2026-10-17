id: 20261017T033308Z-firmware-to-orchestrator-ec03
from: firmware
to: orchestrator
task: T-002
subject: [REVIEW] T-002 Firmware v1 to contract (motors, watchdog, BLE, sonar, status)
time: 2026-10-17T03:33:08Z
---
Branch claude/steven-t-002-4b73e8 (pushed). Rewrote navigator.ino to contract: BLE cmds L,R/STOP/PING, 300ms watchdog (also on disconnect/STOP, boot-safe), front<20/rear<15 linear clamp (immediate, not ramped), slew 10/tick, LEDC 20kHz, interrupt-based sonar alternating 50ms w/ median-3, T, status at 5Hz, STBY high only after BLE init. VERIFIED: compiles with arduino-cli, esp32 core 3.3.12 (installed; code is 3.x-only, wont build on 2.x), board esp32:esp32:esp32, 84% flash. NOT verified: nothing flashed or run. Human needs: flash; bench tests 2-6; set LEFT/RIGHT_SIGN, PWM_MIN (placeholder 70), trims (placeholder 100); check iOS negotiates MTU>=64 (status line ~35B; default 20B truncates; firmware requests 185).
