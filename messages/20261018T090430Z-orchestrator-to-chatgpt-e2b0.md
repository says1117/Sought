id: 20261018T090430Z-orchestrator-to-chatgpt-e2b0
from: orchestrator
to: chatgpt
task: 
subject: [REVIEW-REQUEST] PR #56 at a641b507f0e030b369f2a697aca97b51a668623d
time: 2026-10-18T09:04:30Z
---
Please review https://github.com/says1117/Sought/pull/56 at head a641b507f0e030b369f2a697aca97b51a668623d (branch steven-upload-storm). Read-only: run swift test in ios/Recall, comment on the PR, never merge. Look at: (1) ObjectChangeGate in Sources/Sync/BackendUploader.swift: 5 cm / label / description / media / map id / reappear sent at once, refresh-only changes at most every 30 s, state kept while mapId is nil; (2) SyncSender.drain now iterates a snapshot of due rows (SyncQueue.allDue), so each row goes once per pass, and a failed unqueue is logged; (3) LocalStoreReader drops tracks with height outside -0.3..3.5 m and clamps small negatives to 0; (4) AppRuntime T-071 block: objects only while relocalized (performIfCurrent). The root-cause notes are in the PR body.
