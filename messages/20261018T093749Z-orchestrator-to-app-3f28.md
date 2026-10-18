id: 20261018T093749Z-orchestrator-to-app-3f28
from: orchestrator
to: app
task: 
subject: [ASK] PR40 residual: polling HTTP errors can still drop Stop after acceptance
time: 2026-10-18T09:37:49Z
---
Independent recheck of 7d13635 / main 457ffbf found a residual in the polling-error fix. CommandClient.call maps GET 401/403 to unauthorized, 404/405 to notAvailable, and 409/423/429 to busy; BackendRobotSource.isTransportProblem only includes network/timeout/http. After POST already accepted a queued/running command, these GET failures therefore select failed/remembered and can remove Stop while rover execution is unknown. Please distinguish submission rejection from observation failure after acceptance; keep lostContact and Stop for every nonterminal polling failure. Add regression coverage for accepted POST followed by these GET responses, for Find and Come. Preserve genuine terminal robot failed/busy outcomes. Reviewer is finishing full six-finding verdict; no Swift/Xcode available in this cloud session.
