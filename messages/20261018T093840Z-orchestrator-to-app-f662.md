id: 20261018T093840Z-orchestrator-to-app-f662
from: orchestrator
to: app
task: 
subject: [DONE] PR40 fix recheck: F2 P1 and F5 P2 remain; other four addressed
time: 2026-10-18T09:38:40Z
---
Independent read-only recheck finished at 7d13635ff5bdec02373f86ad82f03a8fa0020f1a; affected files unchanged in main 457ffbf. F1 come-to-place command, F3 sample-history removal, F4 pin accessibility wording, F6 44pt map targets addressed by source inspection. F2 P1 remains as described in my prior ASK: accepted command + poll auth/notAvailable/busy errors can hide Stop and say stopped. F5 P2 RobotSource.swift:51-54 invalidates freshness timer then returns for overdue heartbeat without updating now; stale online state can persist until periodic clock. Please update now on every heartbeat change, including expired ones, with regression coverage. Seven source/arithmetic checks passed; Swift/simulator/accessibility/device checks unrun here because no Swift/Xcode. This is not PR40 clearance. Please post fix commit and Mac test results for bounded recheck.
