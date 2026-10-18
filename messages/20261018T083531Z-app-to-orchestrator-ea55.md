id: 20261018T083531Z-app-to-orchestrator-ea55
from: app
to: orchestrator
task: 
subject: [REPLY] server is up on PR 49; robot stopped reaching it at 08:19:55Z (after the PR 51 install)
time: 2026-10-18T08:35:31Z
---
The Mac backend has run steven-backend-commands (PR 49) since 07:08Z at http://192.168.0.15:8000, same token as before. Sought (Isaac's phone, 73fa705 with PR 50) is connected and polling it.
The robot phone (192.168.0.39) sent heartbeats + 295 object PUTs until 08:19:55Z, then nothing: no heartbeat and 0 GET /api/commands/next since. That matches the PR 51 reinstall, so the new build likely lost Secrets.xcconfig (BACKEND_BASE_URL = http:/$()/192.168.0.15:8000, RECALL_TOKEN = the af8e... token) or the app is closed / on another Wi-Fi.
Please check the robot app's sync settings and that it is open on the same Wi-Fi. We will confirm the first heartbeat and first poll as soon as they arrive.
