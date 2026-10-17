# Robot-side facts for the frontend (advisory)

**Status: advisory.** The web lead's own plan wins on pages, design, hosting, tooling and timeline. This file does not override it. It only records facts about the robot side, so his plan matches what the phone really sends and what can truthfully be shown. Sections marked "Suggestion" are ideas he can ignore. `03_CONTRACTS.md` still wins for interfaces and `00_MASTER_PLAN.md` section 7 wins for scope.

Written 2026-10-17 evening, after the scope cut.

Deadline is 8 am Sunday (EDT). Aim to be submitted by 6 am. Robot feature freeze is 8 pm Saturday, but the web side can keep working until about 2 am.

## 1. What the frontend is for

A caregiver or family member of someone with low vision opens a website and sees three things fast: is the robot OK, what has it stored (objects it found, where they are), and a map. The same site is also what judges open to see the project work, so it must be honest, readable, and accessible.

The frontend does not need Xcode or the robot. It can be built against the seed data and mock robot first, then switched to the real phone when Steven says the phone is posting.

## 2. What changed since the original plan

| Original | Now |
|---|---|
| Patrol and change report with before and after photos | **Cut.** The phone will not produce patrol, event, or before/after data |
| Come to me | **Frozen.** Code exists, not part of the demo |
| Autonomous Explore | **Off by default.** The main way the home gets mapped is a manual Teach pass |
| `/changes`, `/patrols` pages | Optional. If you keep them, show the empty state "Patrol is not part of this build". Do not spend time on the before/after slider |
| Gemini planner, find bar, objects in memory | Real, on the phone. The dashboard shows their results |

Priority pages, in order: **Home (status)**, **Objects**, **Map**, **Evals**, **About**. Everything else only if time remains.

## 3. What the robot actually sends, today

Be strict about this. Do not show anything as live that is not.

| Data | Endpoint | State on the phone |
|---|---|---|
| Heartbeat (state, task, pose, tracking, sonar values, phone battery) | `POST /api/robot/heartbeat` every 2 s | **Wired** in PR 33 when a backend URL and token are configured. Without them, sync is off and the robot still works |
| Waypoints | `PUT /api/waypoints/{id}` | Payload implemented, **not wired** into the running app yet |
| Object tracks and thumbnails | `PUT /api/objects/{id}`, `POST /api/media` | Payload implemented, **not wired** yet |
| Map snapshot | `PUT /api/map` | Payload implemented, **not wired** yet |
| Patrols, events | `PUT /api/patrols`, `PUT /api/events` | Not produced (cut) |

Until Steven confirms "objects are posting", treat Objects, Map and Waypoints as seed data and label them with the mock banner. Heartbeat is the only live signal you can count on first.

Heartbeat `state` values: `idle`, `teaching`, `finding`, `blocked`, `error`, plus `exploring` and `coming_to_user`. The last two come from the plan v2 contract addition (board task T-029): make sure the backend accepts them and the status pill has plain-language copy for each. The robot says `online` only if a heartbeat arrived in the last 10 seconds. Never claim online without one.

Embeddings and video never leave the phone. Only thumbnails, positions, labels and status are sent. Say this on the About page.

## 4. Backend and dashboard status (all PRs are open, nothing merged)

ChatGPT built these. Merge order, one at a time, by Steven only:

1. PR 5: FastAPI skeleton, bearer auth, health.
2. PR 10: endpoints per contract, idempotent PUT upserts, media upload.
3. PR 12: SSE stream (`/api/stream`), `/api/evals`, seed data and mock robot.
4. PR 11: Vite + React + TypeScript dashboard scaffold with placeholder routes.
5. PR 9: eval table scripts (reads `evals/results/`).

Known problems: PR 10 and PR 11 conflict with `main` in `coord/tools/board.py`. When you bring `main` in, keep `main`'s version of that file. Every other conflict in this area has been a manifest merge where you keep both sides.

Run it:

```bash
cd backend && python3 -m pytest
```

```bash
RECALL_TOKEN=change-me uvicorn backend.app:app --reload
```

Auth is a bearer token from the `RECALL_TOKEN` environment variable. `GET /media/{id}.jpg` is public so image tags work. Use `.env.example`. **Never commit a real token.**

## 5. Pages and acceptance (Suggestion: the web lead's plan overrides this)

| Route | Purpose | Done when |
|---|---|---|
| `/` Home | Is it OK? | Status pill (online or "last seen N min ago", state in plain words, tracking quality), current task, counts, live over SSE |
| `/objects` | What did it store | Searchable grid. Thumbnail, label or description, last seen, position in words, a plain word for how reliable it is ("usually here"). Mock banner when seeded |
| `/map` | Where things are | SVG top-down map: occupancy grid, waypoints with labels, object pins, click a pin for a drawer. Pan and zoom. Coordinates per the contract (x right, z down) |
| `/evals` | Proof | Tables and charts from `/api/evals`, `n` on every one. **Empty state "No results yet"** until a real run exists. Link to `04_EVALS.md` |
| `/about` | Pitch | The problem, the one-line pitch, the architecture, what is measured, honest limits, repo link |
| `/changes`, `/patrols` | Optional | Only an empty state |

Every page needs loading, empty and error states. Never show invented numbers. Sample data must be labeled SAMPLE DATA in the UI and must never appear in public screenshots.

## 6. Design direction (Suggestion: the web lead's design overrides this)

Calm, trustworthy, spatial. A floor plan on paper: warm off-white, ink text, one signal color kept for hazards. One humane sans plus a monospace for ids and coordinates. Body text at least 17 px. Tokens as CSS variables with a full dark theme (respect `prefers-color-scheme`, plus a toggle). Severity is never color alone. Subtle motion, and respect `prefers-reduced-motion`. Copy is plain and specific ("The robot is exploring", not "Active"). No em dashes in any copy.

Accessibility is part of the pitch: WCAG AA contrast, visible focus rings, full keyboard use, landmarks, alt text from labels, live-region announcements for status changes, and a VoiceOver pass on Home and Objects.

## 7. The Evals page, and the rule that matters most

The AI-track judges read this. Numbers come only from files in `evals/results/` that a human produced by running the EvalMode tool on the real robot. Right now that folder is empty, so the page must show the empty state. Report small samples as counts like "7/10", include failures, and state the limits (one room, one operator, small n). If a variant loses, show it. Never fill a chart with placeholders.

## 8. What you may and may not claim on the About page

Proven on real hardware: the Bluetooth link, forward and turn directions, the 300 ms watchdog stop (about 0.28 s measured on the status stream), the front stop, and the safety logic with 35 host tests.

Built and unit-tested but not yet run on the robot: pose tracking, driving to a point, obstacle slowdown, object memory, retrieval and the arrival check, the planner and coordinator, Teach waypoints.

Do not claim: that the robot finds objects (until a real find is logged), any accuracy, latency or success rate, patrol or change detection, come to me, autonomous exploration, or anything about the dashboard being fed by live objects before Steven says so.

## 9. Hosting (Suggestion: the web lead decides)

Decide quickly. Preferred: a public host so the phone reaches it from anywhere (Fly, Render, or Railway). Fallback: run on a Mac and use a phone hotspot. The API contract is identical either way. The backend can serve the built dashboard from `/`. The phone needs an HTTPS URL and the token in its gitignored `Secrets.xcconfig`. Test from the phone, not only from your laptop.

## 10. Timeline (Suggestion only; the web lead sets his own)

| When | Work |
|---|---|
| Now to 9 pm | Bring `main` into your branches, resolve conflicts, get PRs 5, 10, 12 green. T-029 (new states). Seed data and mock robot running |
| 9 pm to 11 pm | Home on live SSE, Objects grid, Map page, all against seed data with the mock banner |
| 11 pm to 1 am | Evals page with the empty state and real wiring. About page. Accessibility pass |
| 1 am to 3 am | Deploy. Smoke test from the phone and from a second laptop. Switch to the real phone for heartbeat |
| 3 am to 5 am | Real screenshots and a short screen recording once the robot is posting. Fix issues |
| 5 am to 6 am | Final checks: repo public, README top section, no secrets in history, dashboard loads cold |

## 11. Rules

1. Contracts are the source of truth. Do not change `03_CONTRACTS.md` alone. Propose it on the board and tell Steven.
2. Commit with Steven's git identity. No AI co-author trailers.
3. Never merge. Open a PR and tell Steven. He merges in dependency order.
4. No secrets in the repo or on the board (the repo is public).
5. The robot must work with the dashboard down, and the dashboard must work with the robot offline.
6. Use the board for questions: `python3 coord/tools/board.py inbox <role>` and `board.py post --from web --to orchestrator --subject "[ASK] ..." --body "..."`. Issue 6 on GitHub mirrors the board.
7. Say plainly what you did not run. Never invent measurements.

## 12. Open items for Steven

- Wire object, waypoint, thumbnail and map uploads into the running app, so the Objects and Map pages can go live.
- Confirm the hosting choice and give the phone the URL and token.
- Run the real finds so the Evals page has something honest to show.
