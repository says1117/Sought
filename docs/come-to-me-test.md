# Come to me: two-iPhone test (T-028)

Status: **nothing here has been run.** The logic has unit tests against fakes (`ios/Recall/Tests/ComeToMeTests`). Nearby Interaction, MultipeerConnectivity, Vision, the Companion app UI and the real rover are untested. This feature cannot be verified without two physical iPhones with U1/U2 chips (iPhone 11 or later; the robot's iPhone 13 Pro and the user's newer iPhone qualify).

## Before you start
- Build and install **Recall** on the robot iPhone and **Companion** on the user's iPhone (see `ios/Companion/README.md`). Both need Info.plist keys: `NSNearbyInteractionUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` (`_recall-ni._tcp`, `_recall-ni._udp`).
- Open space of at least 5 x 5 m, nothing on the floor, rover wheels up on a box for steps 1 to 6 where noted. Keep a hand on the power switch. The ESP32 watchdog and sonar stops stay active.
- Both phones: Bluetooth and Wi-Fi on (not necessarily joined to a network), Airplane mode off.

## Steps and expected results
1. **Permissions.** Launch each app. Accept the Nearby Interaction and Local Network prompts. *Expect:* no crash; Companion shows "Looking for the robot…". If a prompt was dismissed: Settings > app > re-enable and relaunch.
2. **Link.** Start the coordinator on the robot (wiring is a follow-up, see PR). *Expect within ~10 s:* Companion shows "Connected to Recall robot". Kill the robot app: Companion returns to "Looking…". *Fails if:* `NSBonjourServices` missing (no peers ever appear).
3. **Ranging.** With both apps connected, hold the Companion 2 m from the robot. *Expect:* distance readout within roughly 0.3 m of a tape measure and updating at around 1 Hz or better. Record the actual error at 1, 2, 4 m in the table below. No accuracy is promised.
4. **Direction.** Walk in a semicircle at 2 m while the robot phone faces forward in its mount. *Expect:* bearing sign flips when you cross the robot's forward axis. If driving later turns away from you, flip `BEARING_SIGN` in `NIRanging.swift` (one value). If the phone is mounted rotated, set `BEARING_MOUNT_OFFSET_DEG`. Note when direction goes missing (behind the robot, phone flat).
5. **Cancel before moving.** Tap Come to me, then Cancel at once (robot on a box). *Expect:* wheels never spin or stop immediately; Companion goes back to Connected.
6. **Come, wheels up.** Tap Come to me with the robot on a box, standing 3 m away. *Expect:* wheels spin to turn toward you (left wheel vs right wheel direction matches where you stand); Companion shows "Robot is coming". Move closer than 1 m: *expect* wheels stop and status "arrived".
7. **Come, floor, with direction.** Rover on the floor, you 3 m ahead, ±30 degrees. *Expect:* rotate toward you, drive in short segments, stop at about 1.0 m (record stop distance), Companion shows "Robot has arrived". Slower than normal driving (cap 120 vs 160).
8. **UWB loss.** While it drives, cover the Companion phone fully with your body/bag or turn it off. *Expect:* rover stops within about 2 s, Companion (if reachable) shows "Stopped: uwb_lost".
9. **Obstacle.** Place a box in the path. *Expect:* ObstacleGuard / sonar stops or detours; rover never hits the box. If it does, stop the test and report.
10. **No direction.** Hold the Companion flat on the floor so direction drops. *Expect:* rover drives short probes and turns; may take several tries; fails with "no_direction" after 15 probes. Record whether it ever reaches you.
11. **Vision.** Stand in view, rover within 2.5 m. *Expect:* status continues to arrived; the person detection should center the approach. Stand out of view: *expect* it stops at 1.0 m and arrives after ~8 s with reason `vision_unconfirmed`.
12. **Cancel while driving.** Press Cancel mid-approach. *Expect:* rover stops immediately.

## Results table (fill in)
| Step | Pass/fail | Notes (distance error at 1/2/4 m, stop distance, turn sign, etc.) |
|---|---|---|
| 1 |  |  |
| 2 |  |  |
| 3 |  |  |
| 4 |  |  |
| 5 |  |  |
| 6 |  |  |
| 7 |  |  |
| 8 |  |  |
| 9 |  |  |
| 10 |  |  |
| 11 |  |  |
| 12 |  |  |

## Known unknowns
- The `direction` axis convention and the phone mount orientation (see `NIRanging.swift` comments).
- Camera assistance (`isCameraAssistanceEnabled`) is off by default; it needs the robot's ARSession handed to NI, untested.
- Vision bearing sign and image orientation (`VisionPersonDetector.swift`).
- MultipeerConnectivity auto-accepts any invitation on service `recall-ni`; fine for a demo, not for a shared room.
