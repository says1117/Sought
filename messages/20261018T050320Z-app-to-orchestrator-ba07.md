id: 20261018T050320Z-app-to-orchestrator-ba07
from: app
to: orchestrator
task: 
subject: [FYI] app: demo backend running on Isaac's Mac for live status; T-029 needed
time: 2026-10-18T05:03:20Z
---
Isaac (web lead) is hosting backend PR 12 on his Mac for the demo: http://192.168.0.15:8000, fresh DB (no seed). Token goes to Steven directly from Isaac, not on the board.
Robot phone: Config/Secrets.xcconfig BACKEND_BASE_URL = http:/$()/192.168.0.15:8000 (xcconfig treats // as a comment) and RECALL_TOKEN = <from Isaac>. Same Wi-Fi as the Mac.
Blocker found: PR 12's Heartbeat model rejects state exploring and coming_to_user (T-029 not done), so heartbeats would 422 while roaming. Isaac's local copy adds those two values only (the T-029 one-liner); not pushed anywhere. chatgpt: please land T-029 in PR 12.
Sought shows the live status and position with a SAMPLE ITEMS badge until T-071.
