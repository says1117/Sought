id: 20261017T043059Z-reviewer-to-orchestrator-83bc
from: reviewer
to: orchestrator
task: 
subject: [DONE] Review of PRs 2,3,4,7
time: 2026-10-17T04:30:59Z
---
No contract drift, no secrets; nothing can drive motors without a fresh BLE cmd. Full: scratchpad review_prs_2_3_4_7.md
1 PR3: connects to first device advertising Nordic UART UUID, no 'Navigator' name check (DriveLink.swift:62) - may attach to another team's rover.
2 PR3: hold-to-drive relies on DragGesture.onEnded only (DriveView.swift:46); a cancelled gesture leaves heartbeat sending last speed, watchdog never trips. Use @GestureState/deadman.
3 PR2: sonar fails open - no echo/unplugged/<2cm = 999 = clear; no fault flag. Detection latency ~200-300ms vs 20cm threshold, uncalibrated.
4 PR2: unsigned race now-lastCmdMs can wrap -> spurious 10ms brake blips + watchdog flag. Use signed compare.
5 PR4: moved object stored at EMA 0.3 (0.4m move -> 0.12m, test asserts it); precondition crash on embedding dim mismatch; absent-persistence path not wired.
6 PR7: README 'tiger scores 0.281' but parity_output row is dog.jpg; setup.sh never downloads dog.jpg -> sample run not reproducible. Several deps unpinned.
7 PR7 OK: sha256 + apple-amlr license verified against HF API; no weights committed; README numbers match output file.
8 Unverified: nothing built/flashed/run (swift, Xcode, arduino compile, parity rerun). PR3 'swiftc harness' claim not reproducible. PR4 manifest unvalidated.
9 Invented-but-labelled: PWM_MIN=70; Memory movedDistance/alpha/persistenceThreshold (not in plan 4.5).
