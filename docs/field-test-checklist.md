# Field test checklist: does the rover actually move correctly?

Run this with the **SelfTest** screen (button "Self-test" at the top left of the app) and `tools/motion_report.py`.
A human must be present for the whole run. Nothing here has been run on the rover yet: every limit is a **placeholder, to be calibrated by Steven, not measured** (`tools/motion_thresholds.json` for the report, `SelfTestConfig` in `ios/Recall/Sources/SelfTest/SelfTestTypes.swift` for the live verdict in the app).

## Before you start

1. Build and install the app on the iPhone (Xcode, real device). Xcode has not been used for this code yet, so the first build may need fixes. See "Known build risks" at the bottom.
2. **Wheels off the ground first.** Put the rover on a stand (box under the chassis) so every wheel spins free.
3. Battery switch ON. The ESP32 must show connected in the app (top status line says "Linked to Navigator").
4. Phone mounted at the height you are testing (low mount or mast). Write the height in your notes: R0.5 needs both.
5. Keep the power switch and the red **STOP** button in reach. STOP is always on screen. Killing the app also stops the rover within about 300 ms (firmware watchdog).
6. Open Self-test, tick every item in the checklist. START stays disabled until all are ticked.

## Run order and expected result

The app runs the steps in this order and does not skip ahead. Speeds are capped at a low constant (placeholder `test_pwm` 110, hard cap 130). Every motion segment has a 30 s timeout.

| Step | Where the rover is | What it does | Expected | If it fails |
|---|---|---|---|---|
| 0 Wheels-off | On the stand | Forward, back, spin left, spin right at low PWM, 1.6 s each | Each wheel spins the right way. Applied L and R in the status line track the commands (within 25 units). Status rate at least 4 Hz. BLE flag (8) always set | Run **halts**. Wrong direction: swap the motor wires or flip `LEFT_SIGN` / `RIGHT_SIGN` (plan 1.3 items 2 and 3). Low rate or no status: check the ESP32 firmware and BLE range. Applied far from commanded with front blocked flag: clear the area around the sonars |
| 1 Watchdog | On the stand | Drives, then sends nothing at all for 1.5 s, then resumes | Motors read 0 within 0.6 s (300 ms firmware watchdog plus the 200 ms status period plus margin), flag 1 set, motors run again on the next command with flag 1 cleared | Run **halts**. Fix the firmware watchdog before anything else. Do not put the rover on the floor |
| (prompt) | Move to floor | "Put the rover on the floor on its start mark..." | Mark the start with tape, 3 m x 3 m clear. Stay next to the rover, hand near STOP. Press Continue | |
| 2 Forward 1 m and back | Floor | Forward until the ARKit pose says 1.0 m, stop, back until it returns | Distance error, sideways drift and return error under the limits | Drift: set `LEFT_TRIM` / `RIGHT_TRIM` (plan 1.3 item 7), rerun. Distance error large: ARKit scale or slip, note it |
| 3 2 m square and return | Floor | 4 legs of 2 m with 90 degree left turns, ends back at the start | Final pose error under the limit. **This is plan task R0.5 at the current phone height.** Above 15 cm means use the mast | Repeat at the other mount height. Tape-measure the real distance from the start mark and type it in the "after step 3" box: the ARKit pose cannot tell you if it drifted |
| 4 360 degree spin | Floor | Left spin until the unwrapped yaw reaches 360 degrees | Yaw error and time reported. Overshoot counts against it | Wheel speed too high or low: change `testPwm`, minimum turn power is carpet dependent |
| 5 Front obstacle | Floor | You place a box about 1 m ahead. The rover drives toward it using ObstacleGuard (LiDAR + sonar). Then you slide the box to about 15 cm and it tests forward (must be clamped), turn (allowed) and reverse (allowed) | Slows, stops before contact (closest front sonar at least 10 cm). Flag 2 set when under 20 cm. Forward clamped, turning and reverse allowed | Did not stop: **press STOP**. Use a soft box. A failure here means the sonar/guard thresholds need tuning, or the sonar wiring is wrong (plan 1.3 items 4 and 6) |
| 6 Incidents | Whole run | Counts tracking != normal events and BLE disconnects | Both zero | Tracking != normal for more than 1 s on a floor step **aborts** the run and stops the rover. Improve lighting and texture, slow down, rerun. A BLE disconnect also aborts |

Between floor steps the app asks you to put the rover back on its start mark and press Continue.

## Safety behavior you can rely on (and should still test once)

- STOP button: stops the motors first, then ends the run. Test it once during step 0.
- Leaving the app or locking the phone stops the rover.
- Tracking not normal for over 1 s, a BLE disconnect, or no status line for 1 s: the run aborts, the rover gets STOP.
- If step 0 or step 1 fails the run halts before you are asked to put the rover on the floor.
- Step 5 will not drive toward a box unless an ObstacleGuard feed (LiDAR depth) exists. It also refuses to do the blocked-forward check unless the sonar reads under 20 cm.

## After the run

1. Tap **Export log (JSONL)** and send it to the laptop (AirDrop, Files).
2. Optional but recommended: tape-measure the rover from its start mark after steps 2 and 3 and enter it in the app (logged as `manual_measurement`, shown in the report as human-measured).
3. Run:

```bash
python3 tools/motion_report.py path/to/selftest_run_xxxx.jsonl --summary motion_summary.json
```

The report prints a PASS / FAIL / NO DATA / NOT RUN table. "NO DATA" means the log had no usable records for that check: it is never counted as a pass. A partial run is reported as INCOMPLETE.
4. Do not copy numbers into `STATUS.md` or the pitch from anywhere except a real log. Keep logs of real runs under a path that is not `evals/results/` unless the evals owner agrees. The summary JSON is the artifact to cite.
5. R0.5: record the step 3 final error at each mount height in `STATUS.md`. If it is above 15 cm, use the mast.

## Metric definitions (the app and the report use the same ones)

- Frame: ARKit world, meters, yaw degrees CCW positive, yaw 0 faces -z (`docs/03_CONTRACTS.md` section 0).
- Forward axis `u` = unit heading at the start of the step. Distance = pose displacement along `u`. Lateral drift = largest sideways offset from the start line over the step, positive left.
- Distance error (step 2) = forward distance at the end of the forward leg minus 1.0 m. Return error = straight-line distance between the pose at the start and the pose after coming back.
- Square final error = distance between the pose at the start of leg 1 and the pose after the 4th turn. Turn targets are cumulative (90, 180, 270, 360 degrees from the start) so one turn's overshoot is corrected in the next.
- Spin yaw error = unwrapped sum of consecutive yaw changes minus 360 degrees. Spin time = start to the first stop command.
- Watchdog latency = receive time of the first status showing L = R = 0 after the app stopped sending, minus the time it stopped. Resolution is the 200 ms status period.
- Status rate = (number of status lines minus 1) divided by the time span, over step 0.
- Obstacle: closest front sonar reading (cm) while approaching. Clamp check: the largest applied linear (L+R)/2 while the box is within 20 cm. Turn check: mean applied angular (R-L)/2. Reverse check: mean applied linear.
- The app shows its own live verdict (`app_verdict` in the summary). The report recomputes from the raw records with `motion_thresholds.json`. If the two disagree, trust the raw log and look at why.

## Known build risks (nothing here has been compiled in Xcode)

- `GuardState` is declared twice in the app module: `Controller/ControllerMath.swift` and `ObstacleGuard/ObstacleGuardLogic.swift` (PR 14 merge). The SwiftPM modules keep them apart, but the Xcode app target and `RecallTests` compile both sources into one module and will fail with a redeclaration error. SelfTest does not use either name (`SelfTestGuardLevel`).
- `SelfTestRunner.swift` and `SelfTestView.swift` need ARKit, CoreBluetooth and a device.
