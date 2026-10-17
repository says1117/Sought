# Master Plan

## 1. Goal and how we are judged

Build a rover that (a) explores a home on its own and builds an object memory (embeddings, 3D positions, thumbnails) that the dashboard shows, with a quick manual Teach drive as the fallback, (b) is controlled through an LLM: you speak or type a request ("go to my keys") and it plans tool calls and drives there, (c) comes to you on request using UWB ranging from a second iPhone, (d) patrols and reports what changed with before and after photos, and (e) has measured, honest evaluations.

Plan v2 (2026-10-17): autonomous exploration, LLM-first control and "come to me" were added at the human lead's request. Manual Teach stays as a fallback.

| Track | What they said they want | How Recall answers it |
|---|---|---|
| Overall (Hack of the Year) | innovation, technical achievement, impact, execution | A clear human problem (low vision, memory), a working end-to-end demo, a physical robot, real measurements |
| AI (Most Creative Use of AI) | AI/ML central. Fine-tuning, RAG, agents, custom models, evals. **Depth over polish. They read the GitHub.** Public repo plus README. Clean code. Explain design choices and tradeoffs | Open-vocabulary retrieval over a spatial embedding memory (RAG-style), an agent loop (retrieve, act, observe, verify, re-rank), a custom selective-update memory algorithm, an LLM planner with tool calls, a full eval harness with ablations, optional robot-height adapter fine-tune |
| Hardware & Physical Computing | software that controls or enhances physical devices, embedded systems | Custom electronics (motor driver, level-shifted sensors), an ESP32 safety controller that is independent of the phone, closed-loop control from ARKit pose |

**Do not claim anything we did not measure.** Every number in the README, Devpost, and pitch must come from `evals/results/`.

## 2. Scope (MoSCoW)

**Must**
- Drive and stop safely (ESP32 watchdog, ultrasonic stops, depth-based slowdown on the phone)
- Explore mode: autonomous frontier exploration over a floor occupancy grid, scanning at stops, building object memory and the world map with no human driving
- Teach mode (fallback): drive the home once by joystick, mark named waypoints, save the world map. Used when exploration fails or for a fast demo setup
- LLM control: a speak or type bar in the app sends the request to the Gemini planner, which calls tools (`find_object`, `go_to_waypoint`, `explore`, `come_to_me`, `stop`, ...). The keyword grammar is the offline fallback. Manual drive is not the main interface
- Come to me: the robot drives to the person using Nearby Interaction (UWB distance and direction) from a companion app on a second iPhone, with Vision person detection plus LiDAR depth for the last meters
- Open-vocabulary object memory (crops, embeddings, 3D positions, tracks)
- Find by description: retrieve, drive, **arrival check**, fall back to next candidate
- Patrol and change report (appeared, disappeared, moved, new obstacle) with before and after thumbnails
- Eval harness, ablation tables, failure analysis
- Dashboard: status, changes timeline, objects, map
- Public repo with a README that explains the design choices and tradeoffs

**Should**
- Voice in (on-device speech) and voice out (spoken briefing)
- "Check the way to X" (drive a route, report clear or blocked)
- Floor occupancy diffing (class-agnostic hazard detection from LiDAR; the grid itself is a Must because exploration needs it)
- Persistence scores and "learn what is normal"
- Accessibility pass on the dashboard

**Could** (only after M4, hour 24)
- Remote tasking from the dashboard
- 3D map view
- Robot-height adapter fine-tune (an extra ablation row)
- Guide mode (rover leads a person to a waypoint, rear ultrasonic checks they follow)
- Sound source finding

**Won't**
- SLAM from scratch (ARKit is the map), global path planning beyond grid frontiers plus straight segments with detours, multi-room exploration through closed doors, cloud video streaming, multi-robot, an arm

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
| H10 to H18 | Occupancy grid and frontier Explore, Teach fallback and waypoints, world map persistence, retrieval and find executor with arrival check, keyword planner then Gemini planner, find bar (type, then speech), sync client | Map page, Briefing player, Patrols page, error and empty states, Accessibility baseline | **M3 (H18): full find loop on the robot, visible on the dashboard** |
| H18 to H24 | Come to me (companion app, UWB, Vision fallback), patrol, object change detection, before and after capture, spoken briefing | Live before and after change cards, severity design, Evals page skeleton, README visuals started | **M4 (H24): FEATURE FREEZE. Tag `v0.9`** |
| H24 to H32 | Run the eval protocol, fix only the top bugs, stretch work only if M4 was early | Evals page with real results, architecture diagram, pitch page, Devpost draft, record clips as things work | |
| H32 to H36 | Rehearse the demo 3 times, charge everything, pre-save the map and memory | Final video edit, Devpost submit by H34, repo public check, secrets check | **Submit before the deadline, not at it** |

## 5. Integration milestones (what "done" means at each)

- **M1 (H2):** `03_CONTRACTS.md` is v1. A fake robot script (`tools/mock_robot.py`) can post a heartbeat and the dashboard shows it.
- **M2 (H10):** the real phone posts a heartbeat, one object with a thumbnail, and one waypoint. The dashboard shows them.
- **M3 (H18):** after an autonomous Explore of one room (or the Teach fallback), say or type "find the blue backpack" in the app. The planner calls `find_object`, the robot drives there, runs the arrival check, speaks the result. The dashboard shows the objects found and the trace.
- **M4 (H24):** "come to me" brings the robot to a person holding the companion iPhone in the same room, and a patrol with one moved chair and one new box produces two change events with before and after photos and a spoken briefing. No new features after this point.

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
| Exploration gets stuck in clutter, loops, or loses tracking | High | Memory incomplete, demo stalls | Small demo room, frontier goals at least 0.5 m apart, a visited-cell penalty, a 5 min cap, stop and report on tracking loss. Teach drive is the fallback |
| UWB direction is unavailable or noisy (capabilities vary; initial demo keeps both apps in the foreground) | Medium | Come to me fails | Verify both devices' capabilities and mount-frame conversion. Hold translation without a trustworthy bearing; rotate only to reacquire direction or a confirmed visual target. Range-only rotation does not provide a bearing. Stop at the defined 1 m stand-off target and stop on ambiguity |
| LLM latency or no network | Medium | Commands feel slow or fail | 3 s timeout, keyword grammar fallback, all safety in code and on the ESP32 |
| Hardware mishap (short, dead ESP32, cable) | Medium | Lost hours | Spare ESP32 and known-good data cable on hand. Check polarity twice. Fuse or switch on the battery |
| Scope creep | High | Nothing finished | Cut order below. Freeze at H24 |

## 7. Cut order if behind

1. Sound source finding (never start before M4)
2. Remote tasking from the dashboard
3. 3D map view
4. Robot-height adapter fine-tune
5. "Check the way to X"
6. Floor occupancy diffing for change reports (keep the grid for exploration)
7. Voice input (typed find bar instead)
8. Come to me Vision fallback (UWB only)
9. Gemini planner (keyword grammar only)
10. Autonomous exploration (Teach drive only)

**Never cut:** drive safety, retrieval plus arrival check, the find bar, change report with photos, the eval harness, the README.

## 8. Definition of done

- [ ] Robot explores the demo room on its own and the dashboard shows the objects it stored
- [ ] Robot finds at least 3 objects by free-form description typed or spoken into the find bar, live
- [ ] Come to me reaches the person holding the companion iPhone (target within 1 m, measured, not assumed)
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
| Primary control | LLM planner from a speak or type bar; manual drive is fallback only | Human lead's direction (plan v2). Safety stays in code and on the ESP32 |
| Exploration | Frontier exploration on the 5 cm floor occupancy grid, ARKit pose, scan at stops | No SLAM to write; the grid is already needed for hazards |
| Come to me | Nearby Interaction (UWB) between two iPhones, MultipeerConnectivity for the token exchange, Vision + LiDAR for the last meters | Bluetooth RSSI gives distance only and is too noisy; UWB gives distance and direction. Second iPhone confirmed available |
