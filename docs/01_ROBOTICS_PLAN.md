# Robotics Plan (hardware, firmware, iPhone app, ML, evals tooling)

Owner: robotics/ML/iOS lead. Read `README.md`, `00_MASTER_PLAN.md`, and `03_CONTRACTS.md` first.

---

## 0. Where things stand

- ESP32 verified alive (blink works). Earlier dark board was a charge-only USB cable.
- TB6612 module and both HC-SR04 sensors have arrived but are not wired or tested.
- The 4WD plate, four TT motors, 4xAA holder, jumpers, mini breadboards, 1k and 2k resistors are on hand.
- `starter/` has a BLE sketch and a SwiftUI BLE client. Both are untested beyond compile intent.
- Parts on the phone side: iPhone 13 Pro (LiDAR, ARKit), a Mac with Xcode, free Apple developer provisioning (apps expire after 7 days, rebuild as needed).

---

## 1. Hardware bring-up

### 1.1 Power design (do not change without a reason)

- 4xAA holder (about 6 V) goes **only** to TB6612 `VM` and `GND`. Put a switch in the battery line if the holder has none.
- ESP32 runs from a separate USB power bank (or the Mac while on the bench).
- **Grounds are tied**: battery negative, TB6612 GND, ESP32 GND, sensor GND.
- TB6612 `VCC` (logic) is fed from ESP32 `3V3`.
- HC-SR04 `VCC` is 5 V from ESP32 `VIN`. HC-SR04 `ECHO` outputs 5 V, so each echo goes through a divider to 3.3 V logic: **1k in series from ECHO, 2k from the junction to GND, junction to the ESP32 pin**. Do not connect echo straight to the ESP32.
- iPhone charges from its own power bank while running.

### 1.2 Pin map (ESP32 30-pin devkit)

| Function | ESP32 pin | Goes to |
|---|---|---|
| Motor driver standby | D4 | TB6612 `STBY` (HIGH = enabled) |
| Left PWM (channel A) | D25 | `PWMA` |
| Left direction | D26 / D27 | `AIN1` / `AIN2` |
| Right PWM (channel B) | D14 | `PWMB` |
| Right direction | D13 / D33 | `BIN1` / `BIN2` |
| Front sonar trigger | D19 | HC-SR04 front `TRIG` |
| Front sonar echo | D21 | front `ECHO` through divider |
| Rear sonar trigger | D5 | rear `TRIG` |
| Rear sonar echo | D18 | rear `ECHO` through divider |
| Logic power | 3V3 | TB6612 `VCC` |
| Sensor power | VIN | both HC-SR04 `VCC` |
| Ground | GND | everything |
| Onboard LED | D2 | status LED (already on the board) |

Leave **D12 unused** (boot strapping pin). Avoid D0, D2-as-input, D12, D15 for anything that could be pulled at boot.

Motor outputs: left motors (two, in parallel) on `AO1`/`AO2`, right motors on `BO1`/`BO2`. Verify the printed pin labels on your TB6612 module, because breakouts differ.

### 1.3 Bench tests (wheels off the ground, in this order)

1. **Divider check:** feed 5 V into the top of an unconnected divider and measure the junction with a multimeter. Expect about 3.3 V. Do this for both before plugging them into the ESP32.
2. **TB6612 alone:** with firmware that sets `STBY` high and drives channel A at PWM 120, confirm both left motors spin. Repeat for B. If direction is wrong, swap the two motor wires or flip the sign in firmware (`LEFT_SIGN`, `RIGHT_SIGN`).
3. **Forward means forward:** `120,120` must drive the rover forward. Then `-120,120` (right side faster than left side) must spin the rover **left**, counter-clockwise when viewed from above, to match the contract's turn convention. Fix `LEFT_SIGN` and `RIGHT_SIGN` until both hold.
4. **Sonar read:** print front and rear cm at 5 Hz. Hand at 10, 20, 50 cm. Expect values within about 2 cm.
5. **Watchdog:** drive from the app, then kill the app. Motors must stop within about 300 ms.
6. **Stop rules:** with the wheels off the ground, hold a hand at 15 cm in front and command forward. Motors must not drive forward but must allow reverse and turning.
7. **Floor test:** on the floor, `150,150` for 2 s. Measure drift. Set `LEFT_TRIM` and `RIGHT_TRIM` constants (percent) so it goes straight.
8. **Deadband:** find the lowest PWM that moves the rover (typically 70 to 100 of 255 on carpet). Set `PWM_MIN`.

### 1.4 Chassis and mount

- Phone mount: rigid, no wobble (wobble breaks tracking). Mast about 40 cm tall made from PVC, a dowel, or stacked brackets, with a phone clamp. The camera looks forward, tilted slightly upward (about 10 to 20 degrees).
- Keep the battery pack low and centered. Tape or zip-tie wires so nothing hangs near the wheels.
- Keep the front sonar unobstructed, aimed straight ahead. Rear sonar aimed straight back.
- Add a hard physical kill: a switch on the battery line.

---

## 2. Firmware (`firmware/navigator/navigator.ino`)

Start from `starter/navigator_ble.ino`. Bring it up to the contract in `03_CONTRACTS.md`.

### 2.1 Required behavior

- BLE peripheral `Navigator` with the service and characteristics in the contract. Advertise on boot and after disconnect.
- Parse `L,R\n`, `STOP\n`, `PING\n` from RX. Ignore malformed lines.
- LEDC PWM at 20 kHz, 8-bit, on `PWMA` and `PWMB`.
- `STBY` HIGH only after BLE init succeeds. `STBY` LOW on any fatal error.
- Control loop every 10 ms:
  1. Apply watchdog (300 ms) and the safety rules from the contract.
  2. Apply slew limit (about 10 PWM per 10 ms) so starts and stops are not violent.
  3. Map magnitude to PWM: for `|v| > 0`, `pwm = PWM_MIN + |v| * (MAX_PWM - PWM_MIN) / 255`, else 0. Apply trims and sign constants.
  4. Direction pins: forward `IN1=H, IN2=L`; backward `IN1=L, IN2=H`; zero = short brake `H,H`.
- Sonar scheduler: alternate front and rear every 50 ms to avoid crosstalk. Trigger a 10 us pulse. Read with a timeout of 25 ms (about 4 m). Median of the last 3 readings. Treat timeout as 999.
- Status notify at 5 Hz in the contract format.
- LED: solid when commands are fresh, slow blink when connected and idle, fast blink when advertising.
- Serial debug at 115200, at most 2 Hz so it never blocks the loop.

### 2.2 Notes

- The starter uses `BLEDevice`/`BLEServer`. In ESP32 Arduino core 3.x the API changed in places (`ledcAttach` instead of `ledcSetup` and `ledcAttachPin`, `getValue()` returns `String`). Check the installed core version and write for it.
- Keep the file readable: constants at the top (`PWM_MIN`, `MAX_PWM`, trims, thresholds), then small functions. The AI-track judges read the repo.

---

## 3. iPhone app (`ios/Recall`)

SwiftUI, iOS 17+, runs on a real device only. Info.plist keys: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSBluetoothAlwaysUsageDescription`, `NSLocalNetworkUsageDescription` (only if talking to a LAN host). Prefer an HTTPS backend. Set `UIApplication.shared.isIdleTimerDisabled = true`. The app must stay in the foreground.

### 3.1 Modules

| Module | Responsibility | Acceptance test |
|---|---|---|
| `DriveLink` | CoreBluetooth client, 10 Hz heartbeat, parse status, expose flags and sonar values | Hold-to-drive works. Killing the app stops the rover |
| `Pose` | ARKit session (world tracking, scene depth), publishes `(x, z, yaw)` and tracking state at 30 Hz | Pose printed on screen. Walk the rover by hand 2 m and back, error is small |
| `Controller` | `goTo(x, z, stopDistance)` closed loop, `rotateBy(deg)`, `stop()` | Reaches a tapped floor point within 15 cm, 8 of 10 tries |
| `ObstacleGuard` | Reads LiDAR depth band ahead and sonar flags, outputs `clear / slow / stop` | Stops for a box placed in the path, does not stop for open floor |
| `Perception` | Keyframe selection, proposals, crops, embeddings, depth to 3D | Typed query highlights the right object on a recorded frame |
| `Memory` | SQLite per `03_CONTRACTS.md`, track association, persistence, selective update | Re-scanning an unchanged room adds no new rows except `last_seen` |
| `Retrieval` | Text embedding, cosine search, scoring | Top-3 contains the target for simple queries |
| `FindExecutor` | Retrieve, drive, arrival check, next candidate, speak result | "find the X" end to end |
| `Teach` | Joystick drive, waypoint marking, save and load world map | Relocalizes against a saved map after an app restart |
| `Patrol` | Route following, scan at waypoints, change detection, report | Detects a moved chair and a new box |
| `ChangeDetection` | Object-level and floor-occupancy diffs, severity rules | Meets the false alarm target in `04_EVALS.md` |
| `Speech` | On-device recognition (push to talk), `AVSpeechSynthesizer` | Command recognized with the robot stationary |
| `Planner` | `protocol Planner`, `KeywordPlanner`, `GeminiPlanner` | Same commands work offline via keywords |
| `Sync` | Queue and upload per REST contract | Airplane mode in, then out: data arrives, nothing lost |
| `EvalMode` | Annotate ground truth by tapping, run the query set, export JSON | Produces a valid `run_*.json` |
| `UI` | Teach, Find, Patrol, Report screens | Big buttons, VoiceOver labels |

### 3.2 ARKit configuration

```swift
let config = ARWorldTrackingConfiguration()
config.frameSemantics = [.sceneDepth, .smoothedSceneDepth]
config.planeDetection = [.horizontal]        // finds the floor
config.environmentTexturing = .none
config.initialWorldMap = loadedMapOrNil      // relocalize against the Teach map
// config.sceneReconstruction = .mesh        // only if building the optional 3D map, costs CPU
```

- Floor height: use a detected horizontal plane, or calibrate once by raycasting the floor under the rover. Store `floor_y`.
- World map: save with `getCurrentWorldMap` at the end of Teach and after each patrol. Persist with `NSKeyedArchiver`. On launch, load it and wait for `.normal` tracking and `worldMappingStatus == .mapped`. If it does not relocalize within 20 s, show "Rescan needed" and offer a fresh Teach.
- Waypoints are `ARAnchor`s (so they stay consistent when the map relocalizes) and rows in SQLite.

### 3.3 Controller (go-to-pose)

Run at 10 Hz. Heading is the camera forward vector projected onto the horizontal plane.

```
err   = signed horizontal angle from heading to the bearing of the target   // calibrate the sign in the first test
dist  = horizontal distance to target
if |err| > 20 deg:  linear = 0; angular = clamp(Kp * err, +-MIN_TURN..MAX_TURN)   // turn in place
else:               linear = clamp(Kv * (dist - stopDist), MIN_LIN..MAX_LIN); angular = Kh * err
send L = linear - angular, R = linear + angular   (contract convention)
done when dist < stopDist + 0.05 for 3 consecutive ticks; fail on 30 s timeout
stop and announce if tracking != normal for > 1 s
```

- Skid steer slips on carpet, so use a minimum turn command that actually rotates the rover (find it by test).
- Slow down inside 0.5 m of the goal. Cap speed during evals.
- First drive test: confirm that a positive `angular` reduces `err`. If not, flip `TURN_SIGN` once, in one place.

### 3.4 ObstacleGuard

- Depth map is about 256x192 at `ARFrame.sceneDepth`. Sample a corridor in front: width about the rover width plus margin, height range from just above the floor to about 40 cm.
- Min distance in the corridor: below 0.6 m means slow, below 0.35 m means stop, announce "blocked", try up to 3 small detours (rotate 30 degrees, retry), then give up and report.
- Sonar flags from the ESP32 are the last line of defense and always win.
- LiDAR has a minimum range, so rely on sonar for the very close range.

### 3.5 Phone power and heat

Run ML at no more than 2 Hz while moving. Keep the screen on and at low brightness. Plug the phone into a power bank. If it throttles, pause scanning, not driving.

---

## 4. Perception, memory, retrieval

### 4.1 Keyframe selection

Capture a keyframe when speed is below 0.15 m/s (or the robot is rotating at a scan stop), tracking is `.normal`, and at least 0.5 s have passed since the last keyframe. Store the pose, `capturedImage`, `sceneDepth`, camera intrinsics, and transform.

### 4.2 Proposals (open-vocabulary candidates)

Union of:
1. YOLO boxes with any class and confidence > 0.15 (export with `yolo export format=coreml nms=True`, use a nano or small model).
2. Vision objectness saliency boxes.
3. Overlapping grid crops (for example 2x3 and 3x4 at 25% overlap) as a backstop.

Run NMS, cap at 24 crops per keyframe. This keeps novel objects (a cane, a slipper, a charger) from being missed just because a detector has no class for them. The ablation `yolo_labels_only` vs full proposals shows why.

### 4.3 Embeddings and 3D position

- Image encoder: a MobileCLIP-class Core ML model (look for Apple's published Core ML conversions, and verify the license and input size before depending on it). Normalize embeddings to unit length and store as float16.
- For each crop: median depth over the central 30% of the box. Reject if invalid or above 5 m. Unproject with intrinsics scaled to the depth map resolution, then transform to world. Record `height_above_floor`.
- Save a 320 px JPEG thumbnail.

### 4.4 Text encoder (known risk, decide early)

Order of preference:
1. Core ML text encoder plus a CLIP BPE tokenizer in Swift (the `ml-stable-diffusion` Swift package includes a BPE tokenizer for the CLIP vocabulary. Verify before relying on it).
2. A small Swift port of the CLIP tokenizer with the vocab and merges files bundled.
3. **Fallback:** a `/embed_text` endpoint on the Mac using `open_clip` with the same weights. Works only with a network path to the Mac, so document it plainly as a fallback and keep the on-device path as the goal.

Use two prompts per query and average: the raw phrase and `"a photo of " + phrase`.

### 4.5 Track association and memory update

- New observation matches an existing track if cosine similarity of embeddings is at least 0.85 and the 3D distance is under 0.5 m. Otherwise it starts a new track (unconfirmed until seen 2 times).
- Update the position with an exponential moving average for matched tracks. Keep the best embedding (highest detection confidence or the running mean, test both).
- **Persistence score** `p` in [0, 1] per track: when the expected location is visible, `p = 0.7p + 0.3` if seen, `p = 0.7p` if absent.
- **Selective update:** a matched observation updates only `last_seen`, `sightings`, and `p`. Embeddings, position, and thumbnails are rewritten only if the track moved, its similarity dropped below 0.9, or `p` crossed a threshold. Keyframes are stored only when an event is created or a new track is confirmed. Old patrols are pruned to events plus one thumbnail each.
- This is the "update only what changed" mechanism and it gets its own eval (`04_EVALS.md`, memory conditions).

### 4.6 Retrieval and scoring

```
q = normalize(mean(textEncoder(phrase), textEncoder("a photo of " + phrase)))
score_i = cosine(q, e_i) * (0.8 + 0.2 * p_i)         // slight preference for reliably re-seen objects
rank tracks by score; ignore unconfirmed tracks unless nothing else qualifies
return top-k (k = 5) with scores
```

Keep a per-query log of the candidates and scores. It feeds the evals and the failure analysis.

### 4.7 Arrival check (the agent loop)

```
for candidate in top-k (max 3):
    drive to within 0.8 m of candidate.position, facing it
    capture 3 frames; crop around the projected 3D point (1.5x the stored box)
    s_img  = max cosine(embedding(crop), track.embedding)
    s_text = cosine(embedding(crop), q)
    accept if s_img >= TAU_IMG and s_text >= 0.9 * candidate.score   (start TAU_IMG = 0.80, calibrate on the eval set)
    else: mark "not here", log, next candidate
speak the result: found with location, or not found with the best guesses
```

Optional ablation row: when the top 3 are within a small margin, send their crops to Gemini for a pick (opt-in, default off, documented).

### 4.8 Optional: robot-height adapter (stretch, only after M4)

Train a small linear adapter on top of the frozen image embeddings using 300+ labeled crops captured from the rover's viewpoint, contrastive loss against the frozen text embeddings, weight decay toward identity. Export as a raw float matrix and apply with Accelerate. Add `clip_plus_adapter` to the ablation. It is the "fine-tuning" box for the AI track. Train in Python on the Mac using the same checkpoint the Core ML models were converted from.

---

## 5. Change detection

Two layers. Both run after a patrol against the Teach/last-patrol baseline.

### 5.1 Object-level

- **Appeared:** an unmatched track seen at least 3 times in this patrol, away from every existing track.
- **Moved:** a new track within 3 m of an old track with embedding similarity at least 0.85 while the old location is visible and empty. Report the old and new positions. Ignore moves under 0.15 m.
- **Disappeared:** the expected location was **visible** (inside the field of view, clear depth ray, close enough) and the object was absent in two passes (two different scan stops, or two patrols). Never declare it from a single missed view.
- Attach the nearest baseline keyframe and the current keyframe as `before_media_id` and `after_media_id`.

### 5.2 Floor occupancy (class-agnostic hazards)

- Build a 5 cm grid per patrol: count depth hits for points between 3 cm and 40 cm above `floor_y`. A cell is occupied if hits exceed a threshold.
- Diff against the baseline grid. A connected blob of at least 3 new occupied cells with no matching object-level event becomes `new_obstacle` with the label "new object, about N cm wide". If the YOLO or CLIP side can name it, use that label.
- Distance to the nearest taught route segment sets the severity (`hazard` within 0.5 m).

### 5.3 Learn what is normal (Should)

If an object toggles between two places across 3 patrols, lower its event severity to `info` and stop announcing it. Keep it in the report as "usual movement".

### 5.4 Spoken briefing

Generate `spoken` text per event with templates (no LLM needed) and a patrol `summary` like "Two changes since the last patrol. A box appeared in the hallway near your bathroom route. The blue backpack moved from the desk to the floor." Optionally let Gemini rewrite it, behind the Planner protocol, with the template as the fallback.

---

## 6. Planner and voice

### 6.1 `Planner` protocol

```swift
protocol Planner { func plan(_ utterance: String, context: PlannerContext) async throws -> [ToolCall] }
```

`PlannerContext` holds waypoint names, route names, and the last patrol summary. Text only.

### 6.2 Tools (also the Gemini function declarations)

| Tool | Args | Effect |
|---|---|---|
| `find_object` | `description` | Retrieval plus drive plus arrival check |
| `go_to_waypoint` | `name` | Drive to a taught waypoint |
| `mark_waypoint` | `name` | Save the current pose as a waypoint |
| `check_route` | `name` | Drive the route, report clear or blocked |
| `start_patrol` | none | Run the default patrol |
| `what_changed` | `since` (optional) | Read the latest report aloud |
| `stop` | none | Brake and cancel the task |
| `say` | `text` | Speak text |

Guardrails: the model can only call these tools. Speeds, distances, and safety are constants in code. Any `go_to` target must resolve to a known waypoint or track. Timeout 3 s, then fall back to the keyword planner.

### 6.3 Keyword grammar (offline fallback)

- `find|where is|where are|go to <phrase>` resolves a waypoint name first, else `find_object`
- `mark this as|this is the <name>` is `mark_waypoint`
- `check the way to <waypoint>` is `check_route`
- `patrol|start patrol` is `start_patrol`
- `what changed` is `what_changed`
- `stop|halt` is `stop`

### 6.4 Gemini

- REST call from Swift with `URLSession` (no SDK needed). API key in `Secrets.xcconfig`, gitignored, with a `.example` file.
- Look up the current Flash-class model id in the Google AI Studio docs. Use function calling with the tools above.
- Never put the key in the repo. The AI-track repo is public.

### 6.5 Speech

- `SFSpeechRecognizer` with on-device recognition if supported (`supportsOnDeviceRecognition`).
- Push to talk. Robot stationary while listening. Typed input always available.
- `AVSpeechSynthesizer` for responses and briefings.

---

## 7. Task list (check items off, add acceptance notes)

### Phase 0 (H0 to H3): drive and learn whether tracking works

- [ ] R0.1 Wire the TB6612, motors, sonars per section 1.2. Check dividers with a multimeter first
- [ ] R0.2 Bench tests 1.3 (items 1 to 8) pass
- [ ] R0.3 Firmware v1 per section 2, status format per the contract
- [ ] R0.4 Xcode project, BLE drive from buttons, kill-the-app test passes
- [ ] R0.5 Mount the phone (mast or low). **Tracking test:** drive a 2 m square and return by teleop. Record the pose error on return, at both heights. Rule: if error is above 15 cm, use the mast
- [ ] R0.6 Post findings to `STATUS.md`. Freeze contracts v1 with the web lead

### Phase 1 (H3 to H10): move to a point, see objects

- [ ] R1.1 `Pose` and the on-screen debug overlay
- [ ] R1.2 `Controller.goTo` meets the 15 cm target, 8 of 10 tries
- [ ] R1.3 `ObstacleGuard` with LiDAR band and sonar flags
- [ ] R1.4 Keyframe capture and storage
- [ ] R1.5 Proposals plus image embeddings plus depth to 3D
- [ ] R1.6 SQLite `Memory` and track association
- [ ] R1.7 Typed query highlights the best crop and shows its score
- [ ] R1.8 Heartbeat and the first object upload to the backend (**M2**)

### Phase 2 (H10 to H18): find loop

- [ ] R2.1 Text encoder route chosen and working (section 4.4)
- [ ] R2.2 Retrieval and scoring
- [ ] R2.3 `FindExecutor` with the arrival check
- [ ] R2.4 Teach mode, waypoints, world map save and relocalize
- [ ] R2.5 Speech in and out
- [ ] R2.6 `KeywordPlanner`, then `GeminiPlanner`
- [ ] R2.7 `Sync` queue. **M3 demo:** "find the blue backpack"

### Phase 3 (H18 to H24): patrol and change detection

- [ ] R3.1 Patrol with scan stops
- [ ] R3.2 Object-level change detection
- [ ] R3.3 Floor occupancy diff
- [ ] R3.4 Before and after keyframes, events, spoken briefing
- [ ] R3.5 `check_route`
- [ ] R3.6 **M4 freeze.** Tag `v0.9`

### Phase 4 (H24 to H32): measure

- [ ] R4.1 `EvalMode`: annotate GT, run `queries.yaml`, export JSON
- [ ] R4.2 Run `04_EVALS.md` end to end, commit the raw runs
- [ ] R4.3 `evals/make_tables.py` generates `results.json` and `results.md`
- [ ] R4.4 Failure analysis paragraph for the README (what broke, why)
- [ ] R4.5 Stretch only if there is time: adapter fine-tune (4.8), remote tasking

### Phase 5 (H32 to H36): ship

- [ ] R5.1 Pre-save the world map and memory for the demo room. Take a backup copy
- [ ] R5.2 Rehearse 3 times with the real script
- [ ] R5.3 Charge everything. Swap batteries. Spare ESP32 and cable in the bag

---

## 8. Debugging and logging

- A JSONL logger records pose, commands, flags, events, planner calls, and retrieval candidates. Export through the share sheet.
- Log every arrival check with scores. It makes failure analysis cheap.
- On-screen overlay: tracking state, mapping status, sonar values, current task, last command.

## 9. Gotchas

- Bluetooth needs a real device, and iOS may stop BLE and ARKit when backgrounded. Keep the app in front.
- ARKit relocalization wants a similar look and light to the Teach session. Do the demo in the same conditions you taught in.
- Do not rebuild the app during a demo window. Free provisioning expires in 7 days, so rebuild before the event.
- If the dashboard is down, nothing about the robot should break. Test with airplane mode.
