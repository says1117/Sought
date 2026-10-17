# STATUS (update at the end of every work session)

Hardware/software checklist snapshot: 2026-10-16 evening, before the hackathon starts. Plan-v2 decisions and review clarifications below are dated 2026-10-17; the historical checklist is not a current implementation or validation report.

## Hardware

- [x] ESP32 WROOM-32 (30-pin, USB-C) clamped between two mini breadboards (Board L and Board R). Power and upload verified. The earlier "no light" problem was a charge-only USB cable.
- [x] Blink sketch uploaded and running (onboard LED on D2 blinks).
- [x] TB6612FNG motor driver, 2x HC-SR04 sensors, wifi: **arrived** (as of 2026-10-16 evening).
- [ ] TB6612 seated on Board C and wired per the pin table in `01_ROBOTICS_PLAN.md`
- [ ] Echo voltage dividers (1k + 2k) built on Board C. Resistors are seated, per the builder.
- [ ] Motors wired: 4 TT motors, two per side in parallel (left reds to AO1, left blacks to AO2, right reds to BO1, right blacks to BO2)
- [ ] 4xAA holder wired to VM and GND on the TB6612, ground tied to the ESP32 ground
- [ ] Phone mount built (target: rigid mast, about 40 cm, test both heights)
- [ ] Bench test passed (wheels off ground)
- [ ] Floor test passed

Power design: 4xAA (about 6 V) feeds only VM and GND of the TB6612. ESP32 runs from a separate USB power bank. Grounds are tied. 3V3 feeds TB6612 VCC. VIN gives 5 V to the sensors. iPhone should be charged from its own bank while running.

## Software

- [x] `starter/navigator_ble.ino`: BLE peripheral "Navigator", `L,R\n` drive command, 300 ms watchdog, LED states, 1 Hz notify. **Written, not yet compiled on hardware beyond the blink test. Motors and sensors are stubbed.** Uses the older BLE Arduino API. Check the installed ESP32 core version (2.x vs 3.x) if the compile fails.
- [x] `starter/NavigatorBLE.swift`: SwiftUI + CoreBluetooth client, hold-to-drive buttons, 10 Hz heartbeat. **Written, not yet built in Xcode.**
- [ ] iOS Xcode project created
- [ ] Backend scaffold
- [ ] Web scaffold
- [ ] Contracts frozen at v1 (target: hour 2)

## Known corrections

- Classic Bluetooth (`BluetoothSerial`) does not work with iPhone. BLE only. The earlier test sketch that used `BluetoothSerial` should be ignored.
- The starter status notify format (`up=..s L=.. R=..`) is a placeholder. Replace it with the format in `03_CONTRACTS.md`.

## Open decisions

- [ ] Phone height: mast or low mount (decide after the tracking test, hour 1 to 3)
- [ ] Backend location: public host vs Mac on a hotspot (decide after testing venue wifi, hour 2)
- [ ] Hackathon start time (this plan uses relative hours H0 to H36)
- [ ] Which Gemini model id to use (look up the current Flash-class id in Google AI Studio docs)
- [ ] Text encoder tokenizer route for MobileCLIP (see `01_ROBOTICS_PLAN.md`, section 4.4)

## Plan v2 decisions (2026-10-17)

Checked items in this section record product decisions, not completed implementations or measured results. Nearby Interaction capability on both phones, mount-frame alignment, pairing, target identity, safe exploration reachability and local STOP priority still require implementation and device verification. Distance-only in-place rotation is not an approach-direction estimator. These review clarifications do not change the contract schema.

- [x] Primary control is the LLM planner from a speak or type bar. Manual drive is fallback only.
- [x] Autonomous Explore replaces Teach as the main way to build memory. Teach stays as a quick fallback.
- [x] Come to me uses UWB (Nearby Interaction). A second, newer iPhone is available for the companion app.
- [x] Contract additions (additive only): heartbeat states `exploring` and `coming_to_user`, and the companion link in section 1.1.

## Scope cut (2026-10-17, 07:50 EDT)

- [x] Patrol and change detection cut first, then come to me (code from T-028 stays, no more work), then autonomous Explore (Teach is the fallback and the main map path if Explore is not working by the feature freeze). Details in `00_MASTER_PLAN.md` section 7.
- [x] Priority: find loop on the real robot, then phone to dashboard sync, then evals, README and video.
- Verified so far: firmware flashed; forward, turn, watchdog and front stop bench-tested over BLE with wheels off the ground. Not yet verified: anything on the iPhone, ARKit tracking, floor driving, rear stop, find loop.

