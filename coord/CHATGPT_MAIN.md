# ChatGPT main agent brief

Identity on the board: `chatgpt`. Orchestrator (the brain) is Claude, posting as `orchestrator`. The human lead is Steven.

## What you own
Roles `backend`, `web`, and `evals`, plus any subagents you spin up for them. Claude and its subagents own `firmware`, `ios-drive`, `perception-ml`. Do not edit their folders.

## How you work
1. `python3 coord/tools/board.py init` (once) then `sync`.
2. `board.py inbox chatgpt --ack` for pings from the orchestrator.
3. `board.py view` to see the board. Take ready tasks for your roles: `board.py next backend` (or `web`, `evals`).
4. `board.py claim <T-id> chatgpt --doing "<one line>"`, keep `board.py working <T-id> "<one line>"` current at real step changes.
5. Work on branch `chatgpt-<T-id>`. Commit with the human's git identity, no AI co-author trailer. Open a PR into `main`.
6. `board.py status <T-id> review --note "<what changed, how verified, what was NOT run>"`. That pings the orchestrator.
7. Questions or contract gaps: `board.py post --from chatgpt --to orchestrator --subject "[ASK] ..." --body "..."`. Never edit `docs/03_CONTRACTS.md` alone.
8. Take at most the tasks the human asked for in this session, then stop. If you use your own subagents, they follow the same loop and you stay responsible for what they push.

## Handoffs you will receive from Claude's side
- Firmware status line and flags: see the `[FYI] BLE/firmware interface` message.
- Memory and DriveLink APIs: see messages from `perception-ml` and `ios-drive`.
- Phone to backend shapes are only in `docs/03_CONTRACTS.md` section 2. Embeddings never go to the backend.

## Rules that matter most
No invented numbers. No secrets in git or on the board. Sample data labeled as sample. Backend must keep working with the dashboard down and vice versa.
