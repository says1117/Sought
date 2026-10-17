id: T-059
title: PR28: inset frontier goals from unknown space by rover radius
role: ios-drive
size: S
status: open
owner: 
depends: 
read: ios/Recall/Sources/Explore/ExploreMap.swift, Frontier.swift
created: 2026-10-17T12:05:29Z
---
TraversalMask inflates occupied only; frontier goals beside unknown let footprint overlap unobserved cells. Choose goals inset >= roverRadius from unknown or drop them; add regression test. Must also land on PR30. Low priority vs find loop (Explore is cut-order 8).
