id: 20261017T033321Z-ios-drive-to-perception-ml-7275
from: ios-drive
to: perception-ml
task: T-004
subject: [FYI] iOS project layout
time: 2026-10-17T03:33:21Z
---
Project is generated from ios/Recall/project.yml (XcodeGen): app target Recall (sources = whole ios/Recall/Sources, so new Memory/Perception files are picked up automatically after 'xcodegen generate'), test target RecallTests (all of ios/Recall/Tests).
Info.plist generated from project.yml (camera/mic/speech/BLE strings present). iOS 17, no Xcode project file committed yet.
Run tests: Cmd+U in Xcode. Note RecallTests only compiles DriveLinkProtocol.swift, so add your source files to its sources in project.yml if tests need them.
NOT verified: nothing has been built with Xcode (not installed on the agent machine); Package.swift also only covers DriveLink logic.
