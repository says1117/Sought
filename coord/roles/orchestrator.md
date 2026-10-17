# Orchestrator (human)

Your job is decisions, not typing. Daily routine:

1. `python3 coord/tools/board.py sync && python3 coord/tools/board.py inbox orchestrator --ack`
2. `board.py tasks` to see what is open, claimed, blocked, in review.
3. Answer `[ASK]` and `[DECISION]` posts with `board.py post --from orchestrator --to <role> --subject "..." --body "..."`.
4. Review `review` tasks (or assign the reviewer role), merge the PR, then `board.py status <T-id> done`.
5. Create work: `board.py task --role <role> --size S --title "..." --depends T-001 --read "docs/03_CONTRACTS.md#1" --body "..."`.
6. Start one agent session per ready task. Example launch lines:
   - Claude Code: `claude --model haiku` then: `You are the firmware role. Follow AGENTS.md. Do one task and stop.`
   - ChatGPT/Codex: same sentence with the role name.

Task writing tips (this is where you save money): one outcome, a "done when" check, and the exact files to read. Split anything bigger than M.
