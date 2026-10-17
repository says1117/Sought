# Web Plan (backend relay, caregiver dashboard, design, pitch assets)

Owner: web/design lead. Read `README.md`, `00_MASTER_PLAN.md`, and `03_CONTRACTS.md` first. You do not need Xcode or the robot. Build everything against mock data, then switch to the live phone at the M2 sync point.

## 1. What you are building and why it matters

The dashboard is for the **caregiver or family member** of someone with low vision. It answers three questions fast: *Is the robot OK? What changed while I was away? Where are things?* It is also the judge-facing proof that the system works: live status, before and after photos, a map, and measured results.

Deliverables:

1. `backend/` FastAPI relay with SQLite and media storage, matching `03_CONTRACTS.md` section 2.
2. `web/` React dashboard (pages in section 4).
3. `tools/mock_robot.py` and `backend/seed.py` so the dashboard works with no hardware.
4. The design system (tokens, components) and an accessibility pass.
5. Pitch and submission assets: architecture diagram, screenshots, `/about` page, Devpost text, demo video, README visuals.

## 2. Stack (defaults, change only with a reason)

- Backend: Python 3.11+, FastAPI, uvicorn, SQLModel or SQLAlchemy with SQLite, pydantic v2, pytest. OpenAPI docs at `/docs`.
- Frontend: Vite, React 18, TypeScript, React Router, TanStack Query, plain CSS variables (or Tailwind if you prefer), a small chart library (recharts or visx), `three` only for the optional 3D view.
- Hosting: decide at H2 after testing venue wifi from the phone. Preferred: public host (Fly, Render, Railway, or similar) so the phone reaches it from anywhere. Fallback: run on a Mac and use a phone hotspot. The API contract is identical either way. The backend can serve the built dashboard from `/` so there is one deployable.

## 3. Backend (`backend/`)

### 3.1 Requirements

- Implement every endpoint in `03_CONTRACTS.md` section 2 with pydantic models generated from the contract JSON.
- PUT endpoints are **idempotent upserts by id**. The phone retries.
- Bearer token from env `RECALL_TOKEN`. Reject missing or wrong tokens with 401. `GET /media/{id}.jpg` may be unauthenticated so `<img>` tags work, but ids must be unguessable.
- Media: accept multipart JPEG, store on disk under `backend/media/`, cap size at 500 KB, reject non-JPEG.
- `GET /api/stream`: server-sent events with one event per change (`heartbeat`, `event`, `object`, `patrol`, `command`). Keep-alive comments every 15 s.
- `GET /api/robot/status` includes `online` (heartbeat within 10 s).
- `GET /api/evals` serves `evals/results.json` if present, else `{}`.
- CORS open in dev, restricted to the dashboard origin in prod.
- `python -m backend.seed` loads realistic mock data (section 5).
- Tests: at least one test per endpoint family, plus an idempotency test.

### 3.2 Files

```
backend/
  app.py          FastAPI app, routers
  models.py       pydantic + DB models
  db.py           SQLite setup
  routes/         robot.py, objects.py, events.py, patrols.py, waypoints.py, media.py, map.py, stream.py, evals.py
  seed.py         mock data
  tests/
  Dockerfile
  .env.example    RECALL_TOKEN=change-me
```

## 4. Dashboard pages

All pages need loading, empty, and error states. Never show invented numbers.

| Route | Purpose | Content and acceptance |
|---|---|---|
| `/` Home | Is it OK? | Status pill (online or last seen, state, tracking quality), current task, latest briefing card with a **Play** button (browser `SpeechSynthesis`) and the text, counts of new changes by severity, links to the other pages. Updates live over SSE |
| `/changes` | What changed | Reverse-chronological list grouped by patrol. Filters for severity, type, route. `ChangeCard`: label, plain-language `spoken` text, severity (icon plus word, not color alone), location in words ("near the hallway, 30 cm from your bathroom route"), confidence, and a **before and after** viewer (slider plus a side-by-side toggle). Keyboard operable |
| `/map` | Where things are | SVG top-down view per the coordinate rules in the contract: occupancy grid image, waypoints with labels, routes as polylines, object pins, last patrol path, event markers. Pan and zoom. Click a pin to open a drawer with the thumbnail, last seen, history of positions |
| `/objects` | Inventory | Searchable grid of object tracks. Card: thumbnail, label or description, last seen, location, persistence as a plain word ("usually here", "moves a lot") |
| `/patrols` | History | List of patrols with duration, distance, event count, and a path preview |
| `/evals` | Proof | Charts and tables from `/api/evals`: retrieval top-1 and top-3 by variant, position error, find success, change detection precision and recall, memory size vs patrols. Show `n` on every chart. Empty state: "No results yet". Link to the method (`04_EVALS.md`) |
| `/about` | Pitch | The problem, the one-line pitch, the architecture diagram, what is measured, honest limitations, team, repo link |

Stretch: `/ask` (type a request that becomes a remote command), `/map3d`.

## 5. Mock data and tools

- `backend/seed.py` creates: 6 waypoints, 2 routes, 15 objects with thumbnails (generate simple labeled placeholder JPEGs with Pillow so the UI is not empty, clearly marked as mock), 4 patrols, 10 events including `hazard` ones with before and after images, one occupancy map, one `results.json` with **obviously fake sample values marked "SAMPLE DATA" in the UI**. Never let sample data reach the real Devpost screenshots.
- `tools/mock_robot.py` posts a heartbeat every 2 s and plays a scripted patrol that creates events live, so SSE and live cards can be tested.
- Add a dev-only banner "Using mock data" when the backend reports a seeded database.

## 6. Design direction

The look should feel **calm, trustworthy, and spatial**, not a generic admin template and not a sci-fi dashboard. A home is a quiet place, and the audience is a worried family member.

- Metaphor: a floor plan on paper. Warm off-white ground, ink-dark text, one signal color reserved for hazards. A drafting-style line weight on the map.
- Type: one humane sans for UI and a monospace for coordinates and ids. Large body text (at least 17 px). Generous spacing.
- Tokens as CSS variables: background, surface, ink, muted, line, accent, hazard, warning, info. Define a full dark theme too (respect `prefers-color-scheme`, plus a toggle).
- Severity is never color alone: icon plus word plus position in the list.
- Motion: subtle. Respect `prefers-reduced-motion`.
- Copy: plain, reassuring, specific. "A box is now in the hallway" beats "Anomaly detected".
- Accessibility (this is part of the pitch): WCAG AA contrast, visible focus rings, full keyboard operation, semantic landmarks, `alt` on every image from the label, the before and after slider also usable with arrow keys, live region announcements for new hazard events, tested with VoiceOver on a Mac.

## 7. Deliverables for submission

- `assets/architecture.svg` (clean, readable, matches the diagram in `README.md`)
- 3 to 5 dashboard screenshots using real data (after M3), plus a short GIF of the before and after viewer
- `/about` page copy and the Devpost text (problem, solution, how it works, what we measured, challenges, what is next)
- Demo video: 90 seconds, script in `05_DEMO_AND_PITCH.md`
- The top section of the public repo README (the robotics lead fills in the technical depth)

## 8. Task list

### Phase 0 (H0 to H3)
- [ ] W0.1 Create `backend/` and `web/` scaffolds, lint and format config, `.env.example`, `.gitignore` (secrets)
- [ ] W0.2 Backend skeleton with health, auth, and one real endpoint end to end
- [ ] W0.3 Test venue wifi from a phone to a candidate host. Decide hosting. Record it in `STATUS.md`
- [ ] W0.4 Review `03_CONTRACTS.md` with the robotics lead. Raise gaps now. **Freeze v1 at H2**
- [ ] W0.5 `seed.py` and `mock_robot.py`
- [ ] W0.6 Design tokens, layout, navigation shell

### Phase 1 (H3 to H10)
- [ ] W1.1 All GET and PUT endpoints, media upload, SSE
- [ ] W1.2 Home page with live status
- [ ] W1.3 Changes page with `ChangeCard` and the before and after viewer
- [ ] W1.4 Objects page
- [ ] W1.5 Backend tests, API docs checked against the contract
- [ ] W1.6 **M2 with the robotics lead:** point the real phone at the backend and confirm a heartbeat, an object, and a waypoint show up

### Phase 2 (H10 to H18)
- [ ] W2.1 Map page (SVG, pan and zoom, pins, routes, path)
- [ ] W2.2 Briefing player (speech synthesis, pause and stop)
- [ ] W2.3 Patrols page
- [ ] W2.4 Error and empty states everywhere, reconnect logic for SSE
- [ ] W2.5 Accessibility baseline (keyboard, focus, contrast)
- [ ] W2.6 Start recording screen clips as features work (cheap now, painful later)

### Phase 3 (H18 to H24)
- [ ] W3.1 Live cards for new events during a patrol, live-region announcements for hazards
- [ ] W3.2 Evals page skeleton against the sample `results.json`
- [ ] W3.3 `/about` page and architecture diagram draft
- [ ] W3.4 Stretch if time: remote command (`/ask`), `/map3d`

### Phase 4 (H24 to H32)
- [ ] W4.1 Wire the Evals page to real results once the robotics lead commits them
- [ ] W4.2 README top section, screenshots, GIFs
- [ ] W4.3 Devpost draft
- [ ] W4.4 Accessibility pass with VoiceOver, fix issues
- [ ] W4.5 Deploy and smoke-test the production URL from the phone

### Phase 5 (H32 to H36)
- [ ] W5.1 Final video edit (backup video must exist even if the live demo works)
- [ ] W5.2 Submit Devpost by H34 with all three track entries selected
- [ ] W5.3 Check the repo is public, README renders, no secrets in history (`git log -p` search for the token and API key)

## 9. Definition of done (web side)

- [ ] Dashboard works with mock data and with the live robot
- [ ] Reload during a patrol recovers state with no errors
- [ ] Keyboard-only and VoiceOver pass on Home and Changes
- [ ] Evals page shows only real numbers, with `n` on every chart
- [ ] Deployed URL works from the phone and from a judge's laptop
