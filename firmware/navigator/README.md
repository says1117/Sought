# Navigator firmware

ESP32 Arduino core **3.x** is required (`ledcAttach` and the core's BLE library). The reviewed sketch was compiled to an object with the installed **3.3.12** Xtensa compiler and SDK. The current review did not link a new firmware image, flash a board or run hardware.

The iPhone writes newline-terminated wheel commands, STOP and PING to Nordic UART RX. The 10 ms loop applies the 300 ms command watchdog, sonar direction clamps, command slew and motor PWM mapping. TX reports applied logical wheel values and sonar/flags at 5 Hz. Notifications are split into at most 20-byte chunks; clients must reassemble lines, as DriveLink does.

BLE callbacks update command and parser state under a critical section. The control loop snapshots matching command values, validity, connection state and timestamp under the same lock. Each connection starts with an empty parser and no valid motion command. Binary/control bytes invalidate their entire command line.

Obstacle direction restrictions are enforced after slew as well as on the target command. A blocked front must never leave positive applied linear output during a ramp transition; a blocked rear must never leave negative applied linear output. Turning and motion away from the obstacle remain possible.

## Required human checks

Follow `docs/01_ROBOTICS_PLAN.md` section 1.3, with wheels off the ground first. Confirm wiring, motor signs, PWM deadband and trims before floor tests. These tuning constants remain placeholders.

- Build/link with `arduino-cli compile --fqbn esp32:esp32:esp32 firmware/navigator`, then flash only as part of supervised bring-up.
- Verify STOP, disconnect and missing-command braking; measure the physical stopping response rather than treating the configured 300 ms watchdog as a measured stop time.
- While running forward, introduce a front obstacle and request reverse or zero: residual forward output must stop immediately at the control-loop level. Repeat the mirrored rear-obstacle case and test turns while blocked.
- Send a partial command, reconnect, and send only its suffix: no motion may be armed. Reject oversized and embedded-NUL lines; verify a subsequent complete valid command recovers normally.
- Verify complete telemetry at default ATT MTU 23 and at a larger negotiated MTU. Check the iPhone reconstructs every newline-terminated status and PONG across notifications.

## Limits

Sonar `999` still means no echo/out of range and does not set a blocked flag. This preserves the existing contract; it is not proof of a clear path. Median filtering and alternating sensors add detection latency. Physical contact avoidance, timing under BLE load, electrical braking and wheel response require hardware validation. The firmware watchdog also depends on the control loop continuing to execute; this sketch does not add an independent hardware watchdog.
