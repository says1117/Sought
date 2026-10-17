# ComeToMe (T-028)

| File | What | Compiled/tested here |
|---|---|---|
| `CompanionMessages.swift` | Codable messages for contract 1.1 (`type` field + the contract's field names) | yes, unit tested |
| `ApproachPlanner.swift` | Pure state machine: turn toward bearing, drive in 0.4 m segments, stop at 1.0 m, probe-based gradient search without direction, Vision person-confirm, 2 s UWB-loss abort, speed caps; `PersonDetector` protocol | yes, unit tested with fakes |
| `ComeToMeRunner.swift` | Async loop executing planner actions through the existing `Controller`; `CappedDriveSink` (lower speed cap without editing Controller); `ControllerMotion` | runner + sink yes (fake motion); `ControllerMotion` typechecked only |
| `RangeSample.swift` | Latest UWB reading + `RangingSource` protocol | yes |
| `NIRanging.swift` | `NISession` wrapper: token archive/unarchive, `distance` and horizontal bearing from `direction` | NOT compiled (SDK/toolchain mismatch on the dev Mac) |
| `CompanionLink.swift` | MultipeerConnectivity transport, robot browses / companion advertises | NOT compiled |
| `VisionPersonDetector.swift` | `VNDetectHumanRectanglesRequest` + depth-at-box, behind `PersonDetector` | NOT compiled |
| `ComeToMeCoordinator.swift` | Robot-side glue (link + NI + runner); to be created by the app | NOT compiled |

Everything numeric (caps, thresholds, `BEARING_SIGN`) is a placeholder. Why gradient search probes by driving: turning in place does not change the UWB range, so the planner drives a short probe and estimates the bearing from the range change (law of cosines).
