# Role: app

Owner: Isaac. Created 2026-10-17 with Steven's confirmation (freeze exception for this role only).

Owns the user-phone app (Sought): `ios/Companion/**` and the Companion target entries in `ios/Recall/project.yml`. This is the phone the person carries: status, objects, and the Come to me button (board task T-068).

Rules:
- Stay inside `ios/Companion/**`. Do not edit `ios/Recall/Sources/**` (the robot app) and do not touch any drive or safety code.
- Edits to `ios/Recall/project.yml` are limited to the Companion target and kept minimal. That file conflicts often: bring `main` in first and keep everyone else's targets (union).
- Build on mock data now. Anything labelled SAMPLE DATA stays labelled. Wire real data only after the first real find works on the robot.
- Status and objects come from a `RobotSource` abstraction with a Mock source and a Backend source first. Peer-link messages for status or objects are a documented future option, not robot code during the freeze.
- Come to me uses `docs/COME_TO_ME_PLAN.md` (branch `steven-plan-v2`) and the existing Companion link `come_to_me` message in `03_CONTRACTS.md` section 1.1.
- Never merge. Open a PR and tell Steven. No secrets. Say plainly what was not run.
- Read the board with `python3 coord/tools/board.py inbox app`.
