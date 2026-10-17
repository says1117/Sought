id: 20261017T043443Z-firmware-to-orchestrator-b13b
from: firmware
to: orchestrator
task: T-017
subject: [REVIEW] T-017 PR2 fixes: signed watchdog compare (review finding 4)
time: 2026-10-17T04:34:43Z
---
navigator.ino loop(): watchdog age now (long)(now-last)<(long)WATCHDOG_MS with lastCmdMs snapshotted; nothing else changed. arduino-cli compile esp32:esp32:esp32 core 3.3.12 OK (84% flash). NOT run: flashing, hardware/BLE race repro. Pushed efbf5d1 FF to PR2 branch (includes steven-coordination merge).
