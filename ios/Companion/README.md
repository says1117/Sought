# Companion app (T-028)

Second iPhone app for "come to me". Big **Come to me** button, connection status, distance readout, Cancel.
Uses the same three shared files as the robot app: `ios/Recall/Sources/ComeToMe/CompanionMessages.swift`, `CompanionLink.swift`, `NIRanging.swift`.
`NIRanging.swift` also needs `RangeSample.swift` (a tiny pure file).

**Not compiled and not run.** There is no Xcode on the machine that wrote it and it needs two physical iPhones (U1/U2 chip). See `docs/come-to-me-test.md`.

## Add the target

With XcodeGen (`ios/Recall/project.yml`, add under `targets:`; this PR does not edit that file):

```yaml
  Companion:
    type: application
    platform: iOS
    sources:
      - path: ../Companion/Sources
      - path: ../Recall/Sources/ComeToMe/CompanionMessages.swift
      - path: ../Recall/Sources/ComeToMe/CompanionLink.swift
      - path: ../Recall/Sources/ComeToMe/NIRanging.swift
      - path: ../Recall/Sources/ComeToMe/RangeSample.swift
    info:
      path: ../Companion/Resources/Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.recall.companion
        SWIFT_VERSION: "5.0"
        INFOPLIST_FILE: ../Companion/Resources/Info.plist
```
By hand in Xcode: File > New > Target > iOS App "Companion" (SwiftUI, bundle id `com.recall.companion`), delete the template files, drag in `ios/Companion/Sources/*` and the shared files above (tick the Companion target, keep "Reference files in place"), set the target's Info.plist file to `ios/Companion/Resources/Info.plist`, set your signing team. Needs a physical device: the simulator has no UWB.

## Info.plist keys (already in `Resources/Info.plist`)

| Key | Why |
|---|---|
| `NSNearbyInteractionUsageDescription` | Nearby Interaction permission prompt |
| `NSLocalNetworkUsageDescription` | MultipeerConnectivity uses the local network |
| `NSBonjourServices` = `_recall-ni._tcp`, `_recall-ni._udp` | MultipeerConnectivity advertises/browses both for service type `recall-ni` |

The **robot app** (`ios/Recall/Resources/Info.plist`, generated from `project.yml` `info.properties`) needs the same three keys. Add to `project.yml` under `Recall` > `info` > `properties`:

```yaml
        NSNearbyInteractionUsageDescription: Measures the distance to your phone so the robot can come to you
        NSLocalNetworkUsageDescription: Talks to the Recall companion app on your iPhone
        NSBonjourServices: ["_recall-ni._tcp", "_recall-ni._udp"]
```
It already has `NSCameraUsageDescription`, which the Vision person-confirm phase also needs.
