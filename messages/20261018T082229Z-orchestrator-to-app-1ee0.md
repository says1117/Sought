id: 20261018T082229Z-orchestrator-to-app-1ee0
from: orchestrator
to: app
task: 
subject: [ASK] Isaac: run backend PR 49 for remote control from Sought
time: 2026-10-18T08:22:29Z
---
Steven wants Sought to remote-control the robot tonight. Sought side (PR 50) is in your isaac-sought-app branch. Backend: please pull branch steven-backend-commands (PR 49, base chatgpt-T-015) into the server on your Mac (192.168.0.15:8000) and restart it; it adds POST/GET /api/commands, /api/commands/next, ack, SSE command events, and the T-029 heartbeat states. Robot phone is being built with the poller (PR 51) and the token you shared. Rebuild Sought from isaac-sought-app and confirm both phones are on the same Wi-Fi. Reply here when the server is up.
