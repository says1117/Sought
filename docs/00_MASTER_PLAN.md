# Master Plan

## 1. Goal and how we are judged

Build a rover that (a) learns a home by being driven through it once, (b) finds an object from a free-form spoken description and drives to it, (c) patrols on its own and reports what changed with before and after photos, and (d) has measured, honest evaluations.

| Track | What they said they want | How Recall answers it |
|---|---|---|
| Overall (Hack of the Year) | innovation, technical achievement, impact, execution | A clear human problem (low vision, memory), a working end-to-end demo, a physical robot, real measurements |
| AI (Most Creative Use of AI) | AI/ML central. Fine-tuning, RAG, agents, custom models, evals. **Depth over polish. They read the GitHub.** Public repo plus README. Clean code. Explain design choices and tradeoffs | Open-vocabulary retrieval over a spatial embedding memory (RAG-style), an agent loop (retrieve, act, observe, verify, re-rank), a custom selective-update memory algorithm, an LLM planner with tool calls, a full eval harness with ablations, optional robot-height adapter fine-tune |
| Hardware & Physical Computing | software that controls or enhances physical devices, embedded systems | Custom electronics (motor driver, level-shifted sensors), an ESP32 safety controller that is independent of the phone, closed-loop control from ARKit pose |

**Do not claim anything we did not measure.** Every number in the README, Devpost, and pitch must come from `evals/results/`.

## 2. Scope (MoSCoW)

**Must**
- Drive and stop safely (ESP32 watchdog, ultrasonic stops, depth-based slowdown on the phone)
- Teach mode: drive the home once, mark named waypoints, save the world map
- Open-vocabulary object memory (crops, embeddings, 3D positions, tracks)
- Find by description: retrieve, drive, **arrival check**, fall back to next candidate
- Patrol and change report (appeared, disappeared, moved, new obstacle) with before and after thumbnails
- Eval harness, ablation tables, failure analysis
- Dashboard: status, changes timeline, objects, map
- Public repo with a README that explains the design choices and tradeoffs

**Should**
- Voice in (on-device speech) and voice out (spoken briefing)
- Gemini planner with tool calls, keyword-grammar fallback
- "Check the way to X" (drive a route, report clear or blocked)
- Floor occupancy diffing (class-agnostic hazard detection from LiDAR)
- Persistence scores and "learn what is normal"
- Accessibility pass on the dashboard

**Could** (only after M4, hour 24)
- Remote tasking from the dashboard
- 3D map view
- Robot-height adapter fine-tune (an extra ablation row)
- Guide mode (rover leads a person to a waypoint, rear ultrasonic checks they follow)
- Sound source finding

**Won't**
- SLAM from scratch, full path planning around furniture, cloud video streaming, multi-robot, an arm

## 3. Architecture and ownership

| Component | Owner | Notes |
|---|---|---|
| Chassis, wiring, power | Robotics | `01_ROBOTICS_PLAN.md` section 1 |
| `firmware/navigator` | Robotics | BLE, motors, watchdog, ultrasonics |
| `ios/Recall` | Robotics | ARKit, Vision, Core ML, SQLite, speech, planner, drive, sync |
| `evals/` harness and runs | Robotics (Web helps with plots and the page) | `04_EVALS.md` |
| `backend/` | Web | FastAPI relay and media store |
| `web/` | Web | dashboard, design system, pitch page |
| Demo video, Devpost, README visuals | Web (Robotics reviews facts) | `05_DEMO_AND_PITCH.md` |
| `03_CONTRACTS.md` | Both | any change is made in one commit that both leads approve |

## 4. Timeline (relative hours; H0 = hacking starts)

Plan for at least one 4 to 5 hour sleep each, staggered, so someone is awake to babysit builds and tests.

| Hours | Robotics | Web | Sync point |
|---|---|---|---|
| H0 to H1 | Wire TB6612 per pin table, bench-test motors with wheels off the ground | Scaffold `backend/` and `web/`, copy contracts, pick backend hosting after a wifi test | |
| H1 to H3 | Firmware v1 (motors, watchdog, BLE, ultrasonics). iOS project, BLE drive from buttons. **ARKit tracking test at two phone heights** | Mock data generator and seed script. API endpoints with OpenAPI. Dashboard shell, routing, design tokens | **M1 (H2): contracts v1 frozen** |
| H3 to H10 | Pose publisher, go-to-pose controller, obstacle guard, keyframe capture, proposals and embeddings, SQLite memory, typed query highlights an object on screen | Changes timeline, Objects grid, status header, media upload, SSE stream, all against mock data | **M2 (H10): first live heartbeat and object upload from the phone to the dashboard** |
| H10 to H18 | Retrieval, find executor with arrival check, Teach mode and waypoints, world map persistence, speech in and out, keyword planner then Gemini planner, sync client | Map page, Briefing player, Patrols page, error and empty states, Accessibility baseline | **M3 (H18): full find loop on the robot, visible on the dashboard** |
| H18 to H24 | Patrol, object change detection, floor occupancy diff, before and after capture, spoken briefing, "check the way to X" | Live before and after change cards, severity design, Evals page skeleton, README visuals started | **M4 (H24): FEATURE FREEZE. Tag `v0.9`** |
| H24 to H32 | Run the eval protocol, fix only the top bugs, stretch work only if M4 was early | Evals page with real results, architecture diagram, pitch page, Devpost draft, record clips as things work | |
| H32 to H36 | Rehearse the demo 3 times, charge everything, pre-save the map and memory | Final video edit, Devpost submit by H34, repo public check, secrets check | **Submit before the deadline, not at it** |

## 5. Integration milestones (what "done" means at each)

- **M1 (H2):** `03_CONTRACTS.md` is v1. A fake robot script (`tools/mock_robot.py`) can post a heartbeat and the dashboard shows it.
- **M2 (H10):** the real phone posts a heartbeat, one object with a thumbnail, and one waypoint. The dashboard shows them.
- **M3 (H18):** say or type "find the blue backpack". The robot drives there, runs the arrival check, speaks the result. The dashboard shows the trace.
- **M4 (H24):** a patrol with one moved chair and one new box produces two change events with before and after photos and a spoken briefing. No new features after this point.

## 6. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| ARKit drifts or loses tracking at low height | High | Navigation fails | Test at H1 to H3. Use a rigid mast (about 40 cm). Tilt the phone slightly up so walls and furniture are in view. Demo in a room with posters or furniture and good light. If tracking is `.limited`, the rover stops and says so |
| Venue wifi blocks device-to-device traffic | Medium | No live dashboard | Robot works offline. Test at H2. Public host or phone hotspot. Dashboard also loads exported JSON |
| TT motors stall at low PWM, rover drifts | High | Jerky control | Deadband mapping, left and right trim constants, calibrate in the first floor test |
| Text-encoder tokenizer for MobileCLIP is awkward in Swift | Medium | Retrieval blocked | Options in `01_ROBOTICS_PLAN.md` section 4.4. Worst case a text-embedding endpoint on the Mac (documented as a fallback) |
| False "disappeared" events because the spot was out of view | High | Noisy report, loses trust | Only declare disappeared when the expected location was visible with a clear depth ray and the object was absent in two passes |
| Phone overheats or battery drains | Medium | Mid-demo failure | Cap ML to 2 Hz while moving, charge from a power bank, keep the screen awake, have a fan or pause plan |
| Motor noise breaks speech recognition | High | Voice fails | Push-to-talk, robot stationary while listening, typed fallback |
| Hardware mishap (short, dead ESP32, cable) | Medium | Lost hours | Spare ESP32 and known-good data cable on hand. Check polarity twice. Fuse or switch on the battery |
| Scope creep | High | Nothing finished | Cut order below. Freeze at H24 |

## 7. Cut order if behind

1. Sound source finding (never start before M4)
2. Remote tasking from the dashboard
3. 3D map view
4. Robot-height adapter fine-tune
5. Voice input (typed commands instead)
6. Gemini planner (keyword grammar only)
7. Floor occupancy diffing (object-level change detection only)

**Never cut:** drive safety, retrieval plus arrival check, change report with photos, the eval harness, the README.

## 8. Definition of done

- [ ] Robot finds at least 3 objects by free-form description in the demo room, live
- [ ] A patrol reports at least 2 injected changes with before and after photos
- [ ] ESP32 stops the rover when the phone app is killed, with the wheels moving (watchdog demo)
- [ ] `evals/results/` contains real runs, and every number in the README links to them
- [ ] Public repo, README with architecture diagram, design choices and tradeoffs, how to run, limitations
- [ ] No API keys in git history
- [ ] Backup video recorded
- [ ] Devpost submitted with the repo link, video, and the three track selections

## 9. Decisions log

| Decision | Choice | Why |
|---|---|---|
| Phone as brain | Yes | LiDAR, ARKit pose, ML accelerators. ESP32 stays a simple, safe body |
| BLE, not Classic Bluetooth | BLE | iPhone cannot use Classic SPP |
| Embeddings on device | Yes | Privacy story and offline operation |
| Open-vocabulary retrieval | MobileCLIP-style embeddings | Names for anything, not just 80 YOLO classes |
| Backend | FastAPI + SQLite | Fast to write, one file DB, easy to seed |
| Dashboard | Vite + React + TypeScript | Fast to build and deploy |
| LLM | Gemini Flash-class via REST, behind a `Planner` protocol | Cheap, fast, function calling. Replaceable |
