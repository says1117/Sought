id: T-018
title: PR3 fixes: match 'Navigator' name; deadman for hold-to-drive (review findings 1, 2)
role: ios-drive
size: S
status: claimed
owner: ios-drive
depends: 
read: ios/Recall/Sources/DriveLink/DriveLink.swift:62, DriveView.swift:46, PR 3
created: 2026-10-17T04:31:38Z
doing: DriveLink name filter + cancel-safe drag
doing_at: 2026-10-17T04:32:46Z
---
1) Connect only to a peripheral advertising the Nordic UART service AND named Navigator. 2) Hold-to-drive must send STOP if the gesture is cancelled: use @GestureState (resets on cancel) or a deadman, so a cancelled touch can never leave the last speed in the 10 Hz heartbeat. Add a pure-logic test for the deadman where possible. Push to claude/steven-t-004-f7c5c9 as a fast-forward.
