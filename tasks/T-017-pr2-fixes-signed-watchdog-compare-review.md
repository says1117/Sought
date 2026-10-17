id: T-017
title: PR2 fixes: signed watchdog compare (review finding 4)
role: firmware
size: S
status: claimed
owner: firmware
depends: 
read: firmware/navigator/navigator.ino, PR 2
created: 2026-10-17T04:31:37Z
doing: fix unsigned now-lastCmdMs race
doing_at: 2026-10-17T04:32:42Z
---
Reviewer found now-lastCmdMs unsigned race can wrap and cause spurious brake blips plus watchdog flag. Fix with a signed comparison, keep behavior otherwise identical. Do NOT change the BLE status flags or contract (sonar fail-open is a separate decision for Steven). Push to the existing branch claude/steven-t-002-4b73e8 as a fast-forward.
