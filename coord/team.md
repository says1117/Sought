# Team

Fill in who runs which role. Each person can run their agents on Claude, ChatGPT, or both.

| Role | Person | Tool |
|---|---|---|
| orchestrator | Steven (robotics lead) | Claude chat |
| firmware | Steven | Claude Code, small model |
| ios-drive | Steven | Claude Code, mid model |
| perception-ml | Steven | Claude Code, mid/strong |
| evals | ChatGPT main agent (`chatgpt`) | ChatGPT/Codex |
| backend | ChatGPT main agent (`chatgpt`) | ChatGPT/Codex |
| web | ChatGPT main agent (`chatgpt`) | ChatGPT/Codex |
| app | Isaac | Claude/ChatGPT |
| reviewer | whoever is free | other vendor than the author, if possible |

A role can be run by any person. Use the role name (not the person) as the `to` and `from` in messages.

The orchestrator brain is Claude (`orchestrator`). The ChatGPT main agent (`chatgpt`) takes backend, web, and evals and reports through board pings. See `coord/CHATGPT_MAIN.md`.
