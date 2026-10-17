# Agent instructions (Codex / ChatGPT / any agent)

Project: Recall, a home rover. Overview in `README.md`, plans in `docs/`.

You are a coordinated worker, not an autonomous agent. Follow `coord/PROTOCOL.md` exactly.

1. Your role comes from the human's prompt. Read `coord/roles/<role>.md`.
2. Run the session loop in the protocol: sync, inbox, claim one task, do it, set status, stop.
3. Read only the files your task lists. Do not read all of `docs/`.
4. Never commit secrets or invented numbers. No AI co-author trailers in commits.
