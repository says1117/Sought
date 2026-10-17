# DriveLink (T-004)

Files: `DriveLinkProtocol.swift` (pure parsing/formatting, unit tested), `DriveLink.swift` (CoreBluetooth, 10 Hz heartbeat), `DriveView.swift` (hold-to-drive), `../App/RecallApp.swift` (entry point).

## Human steps (Xcode was not available to the agent: only Command Line Tools are installed)
1. Install Xcode and `brew install xcodegen`.
2. `cd ios/Recall && xcodegen generate && open Recall.xcodeproj`
3. Set your Team under Signing & Capabilities, select the iPhone, Run.
4. Cmd+U runs `DriveLinkProtocolTests`. (Or `swift test` in `ios/Recall` once Xcode's toolchain is selected.)
5. Device check with the ESP32 powered and wheels off the ground: status line shows "Linked to Navigator";
   hold Forward -> both wheels spin and `L 150 R 150` appears; release -> stops;
   force-quit the app while holding -> wheels stop within ~300 ms (ESP32 watchdog).
