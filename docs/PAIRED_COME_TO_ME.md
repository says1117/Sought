# Come to my phone: same-room test build

This implementation targets the user's iPhone 13 Pro mounted on the rover and iPhone 14 carried by the caller. Actual feature support is checked through Nearby Interaction at runtime. The phones exchange discovery tokens through an encrypted, explicitly paired Multipeer connection, then the rover approaches the paired phone in short, guarded segments.

This is a same-room, foreground feature. Both apps must stay open and the mounted phone must provide usable range and direction. Knowing a phone's bearing does not establish a drivable route through walls or around furniture. The ordinary obstacle guard can stop an approach; this feature does not solve the separate obstacle-detour/navigation work.

## Pairing and use

1. Install matching Recall and Companion builds containing this change. Open Robot tools on the mounted phone and the phone-approach screen from Companion's Come screen.
2. Enter the same six-digit pairing code on both phones and explicitly start pairing. The code is not advertised in discovery metadata. One peer is admitted per connection.
3. With the robot stationary and wheels raised, hold the caller's phone ahead, to the left, and to the right. Check the robot's displayed bearing and distance. Verify the phone mount faces in the assumed direction. Ranging on the Simulator does not establish this calibration.
4. Only after the bearing check, enable approach on the robot's pairing screen for that session. If direction is missing, keep movement disabled and investigate device support, permissions, phone orientation and field of view.
5. From the carried phone, request Come to me. The robot moves in short segments toward that phone and stops approximately one metre away. Keep Stop available during the first floor test.

Changing a peer or backgrounding/disconnecting requires re-pairing/re-enabling approach. Unsupported capabilities, absent or stale range/direction, loss of tracking, blocked motion and expired run budgets produce a stopped/refused result rather than movement based on a guess.

## Motion ownership

Requests use RobotCoordinator's atomic remote admission, existing drive lease, serialized drive sink, tracking monitor and manual-control exclusions. Global STOP retains its normal authority. Matching peer cancellation is scoped to that peer's request so a late cancel cannot stop an unrelated successor.

The dedicated approach runner requires a finite fresh range and bearing for every motion decision and while motion is in progress. It re-reads measurements between segments. It does not use the legacy range-only probing or generic-person steering code. Speed, segment, age, deadline and stand-off values are conservative tuning placeholders, not measured performance claims.

## Verification

Run the full Recall Swift package tests, including the new paired-approach and coordinator regressions. Generate the existing Xcode project, build Recall and Companion for the iOS Simulator, and run Companion unit tests. Check token parsing, authorization, reconnect/old callbacks, request IDs, cancellation, missing/stale/nonfinite measurements, controller failures, lease revocation and stand-off behavior.

Two physical phones are required to validate discovery, permissions, direction capability, pairing, mounted bearing conversion, real sensor age and braking. Follow the stationary/wheels-raised checks before floor motion. No physical validation is implied by passing fake-ranging tests or simulator builds.

Apple references: [Nearby Interaction](https://developer.apple.com/documentation/nearbyinteraction) and [device capabilities](https://developer.apple.com/documentation/nearbyinteraction/nidevicecapability).
