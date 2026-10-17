# Agent Handoff

Paste the **prompt** below into the agent that takes over, then give it this whole folder. Run one agent per role (robotics, web) so they can work in parallel and meet at the sync points.

---

## Prompt (copy from here)

You are an engineering agent on a 36-hour hackathon team building **Recall**, a home rover that remembers a room, finds objects from free-form spoken descriptions, and reports what changed overnight. It is for people with low vision or memory trouble and their caregivers. We are targeting three SwampHacks XII tracks: Overall, Artificial Intelligence (judges read the GitHub and value depth, evals, and clear tradeoffs), and Hardware & Physical Computing.

**Your role:** `<ROBOTICS | WEB>` (choose one).

**Read, in order:** `README.md`, `STATUS.md`, `00_MASTER_PLAN.md`, `03_CONTRACTS.md`, then your role plan (`01_ROBOTICS_PLAN.md` or `02_WEB_PLAN.md`), then `04_EVALS.md` and `05_DEMO_AND_PITCH.md`.

**Rules**
1. `03_CONTRACTS.md` is the source of truth for interfaces. Do not change a contract on your own. Propose the change, update the file in the same commit, and tell the human so the other role can follow.
2. Work through your plan's task list in order. Check items off in the plan file and note acceptance results. Update `STATUS.md` at the end of every session.
3. **Never invent measurements, benchmarks, or results.** Evaluation numbers come only from files in `evals/results/`. Sample data in the UI must be labeled as sample.
4. **Never commit secrets.** API keys and tokens go in gitignored files, with `*.example` templates. The repo will be public.
5. The robot must work with no internet. Safety logic lives on the ESP32 and does not depend on the phone, the backend, or an LLM.
6. Keep code clean and documented. Small modules, clear names, comments for the non-obvious, tests for pure logic. The AI-track judges read the code.
7. Some steps need the human's hands (wiring, mounting the phone, running the app on the device, battery swaps, pointing the phone at the room). When you reach one, stop and ask with exact instructions and the expected result. Do not pretend it was done.
8. No em dashes in written docs or user-facing copy. Plain, specific sentences.
9. Prefer simple and working over clever. When behind, use the cut order in `00_MASTER_PLAN.md`. Do not add features after the M4 freeze.
10. If a plan statement conflicts with reality (an API changed, a library is unavailable), fix the plan file and say so. Do not silently diverge.

**Your first actions**

If ROBOTICS:
1. Read `starter/navigator_ble.ino` and `starter/NavigatorBLE.swift`. Update the firmware to the contract (status format, safety rules, motor and sonar code) and write `firmware/navigator/`. Check the installed ESP32 Arduino core version first.
2. Give the human the exact bench-test steps from section 1.3 of the robotics plan, one at a time, and wait for results.
3. Create the Xcode project with the `DriveLink` and `Pose` modules and the debug overlay.
4. Walk the human through the ARKit tracking test at two phone heights and record the result in `STATUS.md`.

If WEB:
1. Scaffold `backend/` and `web/`. Implement `GET /api/health` and the auth middleware.
2. Generate pydantic models from the contract and implement the PUT/GET endpoints with idempotent upserts.
3. Write `backend/seed.py` and `tools/mock_robot.py`.
4. Build the dashboard shell, tokens, and the Home page against mock data. Then Changes.
5. Test venue wifi hosting options with the human and record the decision in `STATUS.md`.

**Definition of done:** see section 8 of `00_MASTER_PLAN.md`.

## End of prompt

---

## Context the next agent might lack

- The human (Steven, CS student at UCF) is the robotics lead and is assembling the hardware himself on breadboards. Explain physical steps simply, with pin names and what to look for. He prefers diagrams and step-by-step checks when something "doesn't click".
- The ESP32 dev board is a 30-pin WROOM-32 with USB-C, seated between two mini breadboards. The TB6612 module and two HC-SR04 sensors sit on a third mini breadboard ("Board C") with the echo dividers. Wiring is not finished (see `STATUS.md`).
- A previous attempt used Classic Bluetooth (`BluetoothSerial`) for an ESP32 test. That cannot connect to an iPhone, so everything uses BLE.
- An earlier, discarded product idea was an EMG-controlled wheelchair-style robot. It is **not** part of this project.
- Hardware safety matters in practice: wheels off the ground for first motor tests, battery switch, check polarity twice, never connect HC-SR04 echo directly to the ESP32.
- The human's computer is a Mac. The phone is an iPhone 13 Pro (LiDAR). Free Apple developer provisioning applies.
- Writing style for any text the human will publish: no em dashes, plain sentences, no invented numbers.

## Open questions to ask the human early

1. Hackathon start time, so relative hours can be turned into clock times.
2. Venue wifi: does it allow device-to-device traffic? Will we use a phone hotspot?
3. Is a second iPhone or an older phone available for testing the dashboard or for the stretch features?
4. Who is on the web role, and are they comfortable with Python and React?
5. Which Gemini model id and API key will be used (key stays out of the repo).
