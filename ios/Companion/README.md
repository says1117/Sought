# Sought (user phone app)

SwiftUI app the person carries to talk to Soughtbot. Grows the T-028 Companion target; code names stay `Companion` / `Recall`, the display name is **Sought**. Owner: role `app` (Isaac). Design source: Figma "Sought / SoughtBot" (Home hi-fi, Item Log).

## Run

```bash
brew install xcodegen
cd ios/Recall && xcodegen generate
open Recall.xcodeproj   # scheme: Companion, any iOS 17+ simulator
```

Screenshot hooks (launch arguments): `-tab items|map|settings`, `-search "red umbrella"`, `-detail obj_sample0007`, `-find obj_sample0007`.

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
- `BackendRobotSource`: reads `GET /api/robot/status` (2 s), `/api/objects`, `/api/waypoints`, `/api/map`, `/api/metadata` (10 s) and `/media/{id}.jpg`. Keeps the SAMPLE DATA badge on when the server reports `mock: true`. Read-only: a find shows where Soughtbot last saw the item, since there is no command route yet (T-070).

Configure with the same keys as the robot app (`BACKEND_BASE_URL`, `RECALL_TOKEN` in the gitignored `Config/Secrets.xcconfig`), or type the address and token in Settings > Connection (token goes to the Keychain).

Test locally against backend PR 12: run it with `RECALL_TOKEN=dev-local-token`, `python -m backend.seed`, `tools/mock_robot.py`, then launch the app with `-backendURL http://127.0.0.1:8765 -backendToken dev-local-token`.

Peer-link messages (`robot_status`, `objects_digest`, `find`) are a documented future option, not built, per the orchestrator.

## Not done or not verified

- Not run on a physical iPhone. Speech input and haptics are untested on device.
- Come to me v2 (T-068) button is mocked; real wiring waits for the first real find.
- `ComeToMeTestView` (Settings > For testing) is the original T-028 UWB screen, unchanged in behavior.
