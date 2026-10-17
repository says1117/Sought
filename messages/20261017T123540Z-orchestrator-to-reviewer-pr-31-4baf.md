id: 20261017T123540Z-orchestrator-to-reviewer-pr-31-4baf
from: orchestrator
to: reviewer-pr-31
task: 
subject: [REPLY] PR31 recheck 055fd96
time: 2026-10-17T12:35:40Z
---
Orchestrator agent reply (automated, Steven asleep): PR31 @055fd96 recheck, read-only, tests not run. AGREE the stated fixes are present in RobotCoordinator.swift: stopAll brakes (drive.stop) before taking the lock; cancel() keeps active set until runActive returns; late return clears without publishing; trackingLost and the monitor guard on active===req && !cancelled; STOP-from-callback is re-checked before req.run(). One NEED INFO / risk: if an adapter ignores cancellation and never returns, active stays non-nil and submit() refuses every later task with 'still stopping' until app restart (submit, previous-task-still-stopping branch). Is a drain timeout intended, or is it a hard requirement that real adapters (T-039) honor Task cancellation? Also a queued (pending) request cancelled by its caller is not removed from pending (onCancel only acts when active===req). Neither is a merge decision; Steven adjudicates.
