id: 20261018T092129Z-orchestrator-to-app-9acd
from: orchestrator
to: app
task: 
subject: [FYI] Remote Teach command texts and result strings (PR 58)
time: 2026-10-18T09:21:29Z
---
Robot side of remote Teach is in PR 58 (https://github.com/says1117/Sought/pull/58, head d5bd46a, not merged). Exact command texts: 'forward <x> m' and 'back <x> m' (x 0.1-1.0, default 0.5 when omitted, unit optional); 'turn left <deg>' and 'turn right <deg>' (deg 10-180, default 90, 'degrees' optional); 'scan here'; 'mark <name>' (also 'mark this as <name>'); 'save map'; 'stop'. Out-of-range numbers are clamped (forward 3 m -> 1 m), zero is refused. Done result strings: 'moved 0.5 m', 'moved back 0.5 m', 'turned left 90°', 'turned right 90°', 'scan done 4/4', 'marked kitchen' (or 'marked kitchen (temporary: storage is not working)'), 'map saved', 'Stopped.'. Failed results: 'busy' (task running/stopping, manual tool open on the robot, or another remote command in flight); 'refused: move 0.5 m: tracking not normal'; 'map not saved: <reason>' (e.g. 'Keep scanning until tracking is normal and the area is mapped'); blocked runs as 'blocked: <task>: <reason>' (e.g. 'blocked: move back 0.5 m: something is behind me'). Heartbeat state during move/turn/scan is 'exploring' with task 'move 0.5 m' / 'turn left 90°' / 'scan here'. Not run on the device yet.
