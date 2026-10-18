# Sought (user phone app)

SwiftUI app the person carries to talk to Soughtbot. Grows the T-028 Companion target; code names stay `Companion` / `Recall`, the display name is **Sought**. Owner: role `app` (Isaac). Design source: Figma "Sought / SoughtBot" (Home hi-fi, Item Log).

## Run

```bash
brew install xcodegen
cd ios/Recall && xcodegen generate
open Recall.xcodeproj   # scheme: Companion, any iOS 17+ simulator
```

Screenshot hooks (launch arguments): `-tab items|map|settings`, `-search "red umbrella"`, `-detail obj_sample0007`, `-find obj_sample0007`.

## Tests

```bash
cd ios/Recall && xcodebuild test -project Recall.xcodeproj -scheme Companion -destination 'platform=iOS Simulator,name=<iPhone>'
```

`Tests/SoughtLogicTests.swift` (13 unit tests): status copy and offline rule, activity events, search matching, pins
never counting as finds, pin place names, backend date and config parsing. `Tests/CommandClientTests.swift` (7): the
remote command client against a fake transport (request shape, poll to done, failed, busy, timeout, error copy). `UITests/` runs the accessibility audit.

## Accessibility audit

```bash
cd ios/Recall && xcodebuild test -project Recall.xcodeproj -scheme Companion -destination 'platform=iOS Simulator,name=<iPhone>'
```

`UITests/AccessibilityAuditTests.swift` runs Apple's audit on 8 screens. Hit regions, element descriptions and traits
fail the test; contrast, clipping and Dynamic Type are printed as `A11Y-INFO` because they gave false positives on
glass and custom fonts (the file says how each was checked by hand). Large text: screenshot with
`xcrun simctl ui <udid> content_size accessibility-extra-large`.

## Layout

| Folder | What |
|---|---|
| `Sources/Design/Tokens.swift` | Colors (standard + high contrast), Geist / JetBrains Mono type, spacing |
| `Sources/Model` | `RobotSource` (one class every screen reads), `MockRobotSource` (SAMPLE DATA), status copy, activity derivation |
| `Sources/Components` | Status line, search + mic, item card and row, map canvas, tab bar, sample banner, glass |
| `Sources/Screens` | Home, Item Log + detail, Find flow, Map, Settings |
| `Sources/Services` | Speech input, spoken updates, haptics, settings |
| `Resources` | Fonts (OFL, licenses alongside), Figma icons, SAMPLE photos |

## Data

Two sources behind one `RobotSource`:

- `MockRobotSource`: sample data from the Figma, always labeled SAMPLE DATA. Used when no server is configured or when Settings > Use sample data is on.
- `BackendRobotSource`: reads `GET /api/robot/status` (2 s), `/api/objects`, `/api/waypoints`, `/api/map`, `/api/metadata` (10 s) and `/media/{id}.jpg`. Keeps the SAMPLE DATA badge on when the server reports `mock: true`. Find and Come to me send commands (contract 2.9, `CommandClient`): `POST /api/commands {"text": "find red umbrella"}` or `"go to kitchen table"` (a taught spot name), then `GET /api/commands/{id}` every 1 s until done or failed (90 s timeout). The Find flow shows queued, running, then the robot's `result` words; cancel sends `"stop"`. A server without the command route (404) falls back to showing where Soughtbot last saw the item.

Configure with the same keys as the robot app (`BACKEND_BASE_URL`, `RECALL_TOKEN` in the gitignored `Config/Secrets.xcconfig`), or type the address and token in Settings > Connection (token goes to the Keychain).

Test locally against backend PR 12: run it with `RECALL_TOKEN=dev-local-token`, `python -m backend.seed`, `tools/mock_robot.py`, then launch the app with `-backendURL http://127.0.0.1:8765 -backendToken dev-local-token`.

Peer-link messages (`robot_status`, `objects_digest`, `find`) are a documented future option, not built, per the orchestrator.

## Not done or not verified

- Not run on a physical iPhone. Speech input and haptics are untested on device.
- Come to me (T-068) is the waypoint version: pick where you are, and with a server it sends `go to <spot>`. Commands were run in the simulator against a local stub server only, not yet against the real backend and robot.
- `ComeToMeTestView` (Settings > For testing) is the original T-028 UWB screen, unchanged in behavior.
