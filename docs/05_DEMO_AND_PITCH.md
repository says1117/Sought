# Demo, Pitch, and Submission

## 1. The story (30 seconds, memorize)

For someone with low vision, home is a map in their head. When a chair moves or a box lands in the hallway, they find out by tripping. Recall is a small rover that learns your home once. Describe anything in your own words and it drives there. Every night it patrols and tells you what changed, with before and after photos, and flags anything on the paths you walk.

Safe by design: the motor controller stops the robot on its own if the phone goes silent, and everything runs on the phone, so no video leaves the home.

## 2. Live demo script (3:00)

Prepare the room beforehand: world map and memory pre-saved, battery fresh, 4 objects placed, one chair and one box ready to inject.

| Time | What happens | What we say |
|---|---|---|
| 0:00 to 0:20 | Show the room and the rover | The problem, the user |
| 0:20 to 0:45 | Open the dashboard map: waypoints, object pins from the Teach run | "We drove it through the room once. It built this memory." |
| 0:45 to 1:35 | A judge names an object in their own words (one that is not a standard class). Robot drives, arrival check, speaks the result | "It has never been told this word. It found it by meaning." Show the candidate scores on the phone |
| 1:35 to 2:25 | Move the chair, drop the box near the route. Start patrol. Robot reports with before and after photos on the dashboard and out loud | "Hazard: a box is 30 centimeters from your bathroom route." |
| 2:25 to 2:40 | Pull the phone cable or kill the app while moving. The rover stops | "Safety does not depend on the phone." |
| 2:40 to 3:00 | Evals page and the repo | "We measured it. Here is where it fails." Close |

Rules: one scripted path, one fallback path. If the live find fails, narrate the candidate list and show the arrival check rejecting it, which is the point of the design. Never hide a failure.

## 3. 90 second video (script)

1. 0:00 to 0:10 The problem, one sentence, hallway shot.
2. 0:10 to 0:30 Teach: the rover driven through the room, the map appearing.
3. 0:30 to 0:55 Find by description, with on-screen candidate scores.
4. 0:55 to 1:15 Overnight patrol and the morning briefing on the dashboard.
5. 1:15 to 1:25 Watchdog stop.
6. 1:25 to 1:30 Title card with repo and team.

Record clips whenever something works during the build. Keep raw clips in `assets/clips/` (gitignored if large).

## 4. Q and A preparation

| Likely question | Answer, in short |
|---|---|
| Why not just use YOLO? | A fixed class list cannot name a slipper or a charger. We use embeddings for open-vocabulary retrieval. The ablation shows the gap |
| What stops it from finding the wrong thing? | The arrival check: it drives there, looks again, compares to the stored embedding and the query, and tries the next candidate if it does not match |
| How does it know it moved vs disappeared? | Visibility check. We only call it missing if the spot was in view with a clear depth ray, in two passes |
| Why on the phone? | LiDAR, ARKit pose, and the neural engine. It gives odometry without encoders, and keeps video private |
| Where is the LLM and what does it control? | Gemini turns speech into tool calls only. It cannot set speeds or bypass safety. The robot works without it using a keyword grammar |
| What fails? | Tracking at low height in plain rooms, motor noise for voice, similar-looking objects. Have the failure analysis ready |
| Is it safe? | The ESP32 enforces a 300 ms watchdog and ultrasonic stops independent of the phone |
| What would you do next? | Multi-room maps, a better low-light mode, learning each household's normal patterns, a caregiver mobile app |

## 5. Devpost checklist

- [ ] Title, tagline (the one-line pitch)
- [ ] Inspiration (the low-vision home problem, stated respectfully, no invented statistics)
- [ ] What it does
- [ ] How we built it (architecture diagram, hardware list, models, planner, backend)
- [ ] Challenges (tracking at low height, open-vocabulary retrieval, false disappeared events)
- [ ] What we measured (tables linked to `evals/results.md`)
- [ ] Limitations and what is next
- [ ] Built with: Swift, ARKit, Core ML, Vision, SQLite, Arduino/ESP32, FastAPI, React, Gemini API
- [ ] Public GitHub repo link
- [ ] Demo video link
- [ ] Select all three tracks: Overall, Artificial Intelligence, Hardware & Physical Computing
- [ ] Submit by H34

## 6. README checklist for the AI track (they will read it and the code)

- [ ] One-paragraph summary and a demo GIF
- [ ] Architecture diagram and a short description of each module
- [ ] **AI/ML components table:** what model, what it does, why it was chosen, what the alternative was
- [ ] **Design choices and tradeoffs** (embeddings vs detector labels, on-device vs server, selective update vs full remap, LLM scope, why BLE and not Wi-Fi for control)
- [ ] **Evaluation:** setup, metrics, ablation table, failure analysis, limits of the study
- [ ] How to build and run each part (firmware, iOS, backend, web, evals), with versions
- [ ] Safety and privacy section
- [ ] Repo structure
- [ ] Clean code: consistent naming, comments for the non-obvious, small functions, no dead code, no secrets, tests for the backend and for pure-logic Swift (association, scoring, change rules)
- [ ] License file

## 7. Backup plan

- Spare ESP32 flashed and labeled, two known-good USB-C data cables, spare AA set, power strip, zip ties, tape, small screwdriver, multimeter
- A pre-recorded video of every demo step
- Pre-saved world map, memory database, and mock-to-real seed so the dashboard is never empty
- A "tracking lost" script: the robot says it needs a rescan, and we show the saved video while recovering
- Demo with the best two variants only. Do not experiment on stage
