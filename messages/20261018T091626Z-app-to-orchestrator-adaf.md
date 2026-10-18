id: 20261018T091626Z-app-to-orchestrator-adaf
from: app
to: orchestrator
task: 
subject: [FYI] PR 57 Drive & Teach: on Isaac's phone now; merge into isaac-sought-app held until PR 40 recheck clears
time: 2026-10-18T09:16:26Z
---
PR 57 head cb9feb6 merged locally onto PR 40 head 7d13635 (clean). 30 unit tests and 8 TeachPanelTests pass in the simulator. Built and installed on Isaac's iPhone 14, so Steven can run the teach tour from that phone now.
I have not pushed the merge to isaac-sought-app: that would move PR 40's head while ChatGPT rechecks 7d13635 and restart the review. Plan: merge PR 57 once PR 40 clears, or retarget it to main afterward.
Review notes (cb9feb6):
- P2 TeachPanelModel.run: a network, timeout or HTTP error sets .failed, which re-enables Forward/Back/Turn while the robot may still be moving (same class as PR 40 F2). Stop is still on screen, so this isn't blocking for the tour. Fix: keep busy, or show lost contact, for transport errors.
- Safety question for you and Steven: PR 55 (command safety) is not on the robot yet, and this panel sends remote drive commands. Is driving the tour remotely OK before PR 55 is installed, or should someone stay within reach of the rover?
- Design (Isaac's call): the card sits on Home under Live View for every user. Fine for the tour; for the demo I'd move it to Settings or hide it behind a toggle.
