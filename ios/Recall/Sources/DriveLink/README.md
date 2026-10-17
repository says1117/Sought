# DriveLink (T-004)

Files: `DriveLinkProtocol.swift` (pure parsing/formatting and command-session state, unit tested), `DriveLink.swift` (CoreBluetooth, 10 Hz heartbeat), `DriveView.swift` (hold-to-drive), `../App/RecallApp.swift` (entry point).

Driving stays disabled until RX supports write-without-response and TX notifications are confirmed. Commands entered before readiness are discarded. Disconnects, failed setup and Bluetooth unavailability clear wheel commands, telemetry and partial status lines; reconnect starts stopped and requires a fresh hold. The heartbeat uses common run-loop modes so touch tracking does not pause its timer. The ESP32 watchdog remains the fallback for scheduling delays or a killed app.

## Human steps (Xcode was not available to the agent: only Command Line Tools are installed)
1. Install Xcode and `brew install xcodegen`.
2. `cd ios/Recall && xcodegen generate && open Recall.xcodeproj`
3. Set your Team under Signing & Capabilities, select the iPhone, Run.
4. Cmd+U runs `DriveLinkProtocolTests`. (Or `swift test` in `ios/Recall` once Xcode's toolchain is selected.)
5. Device check with the ESP32 powered and wheels off the ground: status line shows "Linked to Navigator";
   hold Forward -> both wheels spin and `L 150 R 150` appears; release -> stops;
   force-quit the app while holding -> wheels stop within ~300 ms (ESP32 watchdog).
6. While holding a direction, cancel the gesture, lock the phone or interrupt the app: verify stopping. Toggle Bluetooth off and back on: the screen must leave the linked state, telemetry must clear, and reconnect must not resume motion until release and a fresh press. Drag the speed slider while driving and verify status continues without unexpected watchdog trips.
7. With a test peripheral, reject notifications or omit a required characteristic: controls must stay disabled and the app must cancel setup and rescan rather than claim it is linked.
