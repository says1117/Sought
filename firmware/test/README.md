# Firmware safety tests (host, no hardware)

Tests the Navigator's safety and motion logic (`firmware/navigator/safety.h`) on a Mac or Linux box with a plain C++ compiler. No Arduino, no BLE, no ESP32.

Run from the repo root (the source-scan tests read `firmware/navigator/` by relative path):

```bash
c++ -std=c++17 -Wall -Wextra -o /tmp/test_safety firmware/test/test_safety.cpp && /tmp/test_safety
```

Exit code 0 and `0 failed` means pass.

## What is covered

- Command parsing: `L,R`, `STOP`, `PING`, malformed, oversize (24+ chars), control bytes, CR/LF framing, split writes.
- Watchdog: 300 ms boundary, signed age (a `lastCmdMs` newer than `now` counts as fresh), 32-bit wraparound, resume on next command, disconnect brake, no valid command after connect.
- Front <20 cm and rear <15 cm clamp linear only (turning kept), 999 = no echo, clamp re-applied after slew, slew of 10 per tick.
- PWM mapping `PWM_MIN + mag*(MAX_PWM-PWM_MIN)/255`, trim, sign, cap at `MAX_PWM`, zero = short brake.
- Simulated-time scenarios (stream stops, obstacle appears mid-ramp).
- `legacy_reference.h` is the pre-extraction logic copied verbatim from `navigator.ino` (commit 1997c3c); one test compares it with `safety.h` over 400k random inputs.
- Source scan: `navigator.ino` raises STBY only after `setupBle()`, includes `safety.h`, and does not redefine its constants.

## What this does not cover

Pins, LEDC/PWM output, BLE stack, sonar interrupts and timing, motor wiring. Those need the board. `navigator.ino` itself is not compiled by these tests; build it with arduino-cli or Arduino IDE (ESP32 core 3.x).
