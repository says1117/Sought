# Recall (working name)

A home robot that remembers a room, finds things you describe in your own words, and reports what changed overnight.

Event: SwampHacks XII (36 hours, team of 2).
Prize targets: **Overall (Hack of the Year)**, **Artificial Intelligence (Most Creative Use of AI)**, **Hardware & Physical Computing (Get Physical With It)**.

**Pitch:** "Describe anything in your own words and it drives there. Every night it tells you what changed."

**User:** a person with low vision or memory trouble who lives at home, and a family member or caregiver who wants to know the home is safe. Trip hazards are floor-level, which is exactly what a low rover sees.

---

## Read in this order

| # | File | Who reads it | What it is |
|---|------|--------------|------------|
| 1 | `README.md` | everyone | this index, system picture, glossary |
| 2 | `STATUS.md` | everyone | live checklist of what exists and what is blocked. Update it every session |
| 3 | `00_MASTER_PLAN.md` | everyone | goals, scope, timeline, sync points, risks, cut order |
| 4 | `03_CONTRACTS.md` | everyone | **source of truth** for BLE, REST API, schemas, coordinate frames |
| 5 | `01_ROBOTICS_PLAN.md` | robotics/ML/iOS lead | hardware bring-up, firmware, iOS app, perception, memory, evals tooling |
| 6 | `02_WEB_PLAN.md` | web/design lead | backend relay, dashboard, design direction, pitch assets |
| 7 | `04_EVALS.md` | both | evaluation protocol that earns the AI track |
| 8 | `05_DEMO_AND_PITCH.md` | both | demo script, pitch, Devpost and README checklists, backup plan |
| 9 | `AGENT_HANDOFF.md` | the next AI agent | paste-ready prompt and operating rules |
| | `starter/` | robotics | existing ESP32 BLE sketch and SwiftUI BLE client (written, untested) |

If two documents disagree: `03_CONTRACTS.md` wins for interfaces, the role plan wins for how to build, `00_MASTER_PLAN.md` wins for scope and priorities.

## Roles

- **Robotics lead** (Steven): chassis, electronics, ESP32 firmware, iPhone app (ARKit, perception, memory, planner, drive control), evals.
- **Web lead**: backend relay, caregiver dashboard, design system, pitch and Devpost assets, README polish, demo video. Does not need Xcode or the robot to make progress, everything is built against mock data first.

## System in one picture

```
 iPhone 13 Pro (mounted on rover, always)                ESP32 (motors + safety)
 ARKit pose + LiDAR depth                                       |
 Perception -> Memory -> Planner -> Drive ---- BLE ----> navigator firmware
      |          (SQLite)  (Gemini or          (L,R cmds,        |
      |                     keywords)            status)         +--> TB6612 --> 4 TT motors
      |                                                          +--> HC-SR04 front + rear
      | HTTPS (queued, optional, robot works offline)
      v
 Backend relay (FastAPI + SQLite + media) <----> Web dashboard (React)
                                                  changes, map, objects, patrols, evals
```

Key design rules:

1. **The phone is the brain, the ESP32 is the body.** ARKit pose is the odometry. No wheel encoders.
2. **Safety never depends on the phone, the network, or the LLM.** The ESP32 stops on 300 ms of silence or a close obstacle on its own.
3. **The robot works with no internet.** The backend and Gemini are optional layers with fallbacks.
4. **Embeddings and video stay on the phone.** Only small thumbnails, events, and positions are synced. Say this in the pitch and README.

## Glossary

- **Waypoint**: a named pose the user taught ("kitchen", "front door"), stored as an ARKit anchor plus a row in SQLite.
- **Route**: an ordered list of waypoints (for patrol or "check the way to the bathroom").
- **Track**: one remembered physical object, merged from many sightings. Has a position, a best embedding, a persistence score, and thumbnails.
- **Teach**: driving the rover through the home once to build the baseline map and object memory.
- **Patrol**: driving a route, scanning at each waypoint, and comparing to memory.
- **Arrival check**: after driving to a retrieved location, the robot looks again and verifies it is the right thing before claiming success.
- **Persistence score**: how reliably a track is re-seen where it was last put. Drives the selective memory update and the "learn what is normal" behavior.
- **Hazard**: a new object on or near a taught route at floor level.

## Repo layout (target)

```
recall/
  README.md                 public README (see 05_DEMO_AND_PITCH.md, AI-track checklist)
  docs/                     this folder
  firmware/navigator/       ESP32 sketch
  ios/Recall/               Xcode project (Sources/Perception, Memory, Planner, Drive, Speech, Patrol, Sync, UI)
  backend/                  FastAPI relay
  web/                      Vite + React dashboard
  evals/                    queries, ground truth, results, make_tables.py
  tools/                    mock_robot.py, seed scripts
  assets/                   diagrams, screenshots, logo
```
