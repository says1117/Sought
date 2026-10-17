# Agent Coordination Protocol

Works the same for Claude, ChatGPT/Codex, or any agent that can run shell commands and read files. The human leads are the orchestrators. Agents never run on their own: a human starts one session per task.

## How it fits together

```
 Orchestrator (a human lead, in a normal chat)
      |  creates tasks, answers questions, merges PRs
      v
 coord/tools/board.py  <-->  "board" git branch (tasks + messages, shared by everyone)
      ^                              ^
      |                              |
 agent sessions (one role, one task each, started by a human)
```

- The board is plain files on a separate git branch called `board`, checked out at `.board/` (gitignored). Code branches and PRs never carry board traffic.
- A "ping" is a message file addressed to a role or person. The recipient sees it the next time a session runs `inbox`. Nothing polls, so idle cost is zero.
- One message per file and one acks file per reader, so two people writing at once never conflict.
- Commands sharing a checkout use `.board.lock` to prevent overlapping writes and Git operations. If the board is busy, retry after the other command finishes. The CLI requires macOS or Linux for its standard-library file lock.
- Failed commits and pushes exit with an error. A failed push leaves a local commit: resolve any rebase conflicts and run `board.py sync` to pull and publish pending commits. `sync --no-push` only pulls.

## Roles

See `coord/team.md` for who runs which role. Role prompts are in `coord/roles/`.

| Role | Owns |
|---|---|
| orchestrator | creating tasks, decisions, merging. Human only |
| firmware | `firmware/navigator/` |
| ios-drive | `ios/Recall/Sources/{DriveLink,Pose,Controller,ObstacleGuard}` |
| perception-ml | `Perception, Memory, Retrieval, FindExecutor, ChangeDetection, Patrol`, `ml/` |
| evals | `evals/` |
| backend | `backend/` |
| web | `web/`, `assets/` |
| reviewer | read-only review of a finished task |

## The session loop (every agent, every time)

1. `python3 coord/tools/board.py init` (first time only), then `python3 coord/tools/board.py sync`
2. `python3 coord/tools/board.py inbox <role> --ack`
3. `python3 coord/tools/board.py next <role>` shows the first ready task. Claim it: `board.py claim <T-id> <role>`
   Claim with a one-line plan: `board.py claim <T-id> <role> --doing "wiring motor driver pins"`.
4. Read only what the task lists under `Read:`. Do the work on branch `<person>-<T-id>`, commit as the human's git identity, no AI co-author trailers.
   Keep your "working on" line current at each real step change (3 to 5 times per task, not every command): `board.py working <T-id> "writing sonar median filter"`.
5. `board.py status <T-id> review --note "what changed, how verified"` (or `blocked --note "why"`). This pings the orchestrator.
6. **Stop.** One session, one task. Do not loop and do not start the next task unless the human says so.

## Stacked work

A task becomes ready when its dependencies are in `review` or `done`. If a dependency is only in `review`, branch from the dependency's branch (not `main`) and open your PR against that branch, saying so in the PR body. If review changes the dependency, rebase. Humans merge in dependency order.

## Review requests (standing rule)

Every time a PR is opened, request an independent review from the ChatGPT reviewer right away: `python3 coord/tools/board.py review <PR number> --note "what to focus on"`. It posts a standard `[REVIEW-REQUEST]` ping with the exact head commit. Reviewers are read-only: they run the tests, report findings as a PR comment plus a board message, and never merge, push, or approve. Do this again after material fix pushes, naming the new head.

## The work board

`board.py view` prints a kanban: **To do** (ready to claim), **Claimed** (who, and their current "working on" line), **In review**, **Blocked**, **Waiting on dependencies**, **Done**, plus the latest messages. The same page is saved as `BOARD.md` on the `board` branch, so anyone can read it on GitHub without running anything. It regenerates on every board write.

## Talking to people: the pinned issue

Issue #6 on the repo mirrors the board so people can read and ping from GitHub (with notifications). Every `board.py post` and status ping is posted there as a comment, and the issue body holds the live kanban. A human comment that starts with `@<role>` (for example `@firmware` or `@chatgpt`) becomes a board message to that role, otherwise it goes to ALL; agents receive it on their next `sync`. The repo is public, so never put secrets or personal data in a comment. Config lives in `.board/config.json`.

## Rules

1. `docs/03_CONTRACTS.md` is the interface source of truth. Never change it alone: post `[DECISION]` to orchestrator.
2. Never invent measurements. Eval numbers come from `evals/results/` only.
3. Never commit secrets. Never post secrets to the board (it is a git branch in a public repo).
4. Hardware, device, and Xcode steps need a human. Post `[BLOCKED] needs human: <exact steps and expected result>` and stop.
5. Stay inside your role's folders. If you need a change elsewhere, post `[ASK]` to that role.
6. Message subjects start with a tag: `[ASK]`, `[DONE]`, `[BLOCKED]`, `[FYI]`, `[DECISION]`. Keep bodies under 10 lines.
7. Prefer simple and working. Obey the cut order in `docs/00_MASTER_PLAN.md`.

## Keeping cost low (read this, it is the point)

- **Session = one task.** Fresh context each time. No long-running agents, no polling, no autonomous loops.
- **Tight reading list.** Agents read `AGENTS.md`, their role file, their task, and the files the task names. Not the whole `docs/` folder. Tasks carry the few contract lines they need.
- **Right-size the model.** Cheap model for mechanical work, strong model only for design and hard debugging:

| Work | Tier | Claude | ChatGPT |
|---|---|---|---|
| scaffolding, boilerplate, tests, docs, seed data | small | Haiku | mini model |
| normal feature code | mid | Sonnet | default model |
| algorithm design, tracking/controller debugging, review of risky code | strong | Opus (sparingly) | strongest model (sparingly) |

- **Task sizes:** S under 30 min, M under 90 min, L must be split before it is started.
- **The orchestrator's own chat is the expensive one.** Keep it for decisions. Let `board.py tasks` and `inbox orchestrator` replace "what is everyone doing" questions.
- **Batch pings.** Check `inbox orchestrator` a few times a day, not after every message.
- **Spend cap per session:** if a task is not done after 2 failed attempts at the same fix, post `[BLOCKED]` instead of retrying.

## Moving between Claude and ChatGPT

The protocol is just files and one Python script, so it is vendor neutral.

- Claude Code reads `CLAUDE.md`. Codex/ChatGPT agents read `AGENTS.md`. Both point here.
- ChatGPT in the browser has no repo access: paste `coord/PASTE_PROMPT.md`, then you (the human) run the board commands and paste results. Use this only for design and review work.
- Role files in `coord/roles/` are the single source. `.claude/agents/*.md` are thin wrappers around them.
