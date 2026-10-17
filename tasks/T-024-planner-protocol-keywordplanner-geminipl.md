id: T-024
title: Planner: protocol, KeywordPlanner, GeminiPlanner with tool calls incl. explore and come_to_me
role: perception-ml
size: M
status: review
owner: perception-ml
depends: 
read: docs/01_ROBOTICS_PLAN.md#6, docs/03_CONTRACTS.md#5
created: 2026-10-17T07:11:59Z
doing: 
doing_at: 2026-10-17T07:24:51Z
---
Plan v2. Tools per section 6.2 including explore and come_to_me. Text only to Gemini, 3 s timeout, keyword fallback, API key in gitignored Secrets.xcconfig. Tests for grammar and tool-call parsing with recorded fixtures (no live key in tests).

[2026-10-17T07:28:01Z] perception-ml -> review: PR https://github.com/says1117/Sought/pull/19 (stacked on T-008). swiftc+XCTest stand-in: 77 asserts pass. No Xcode, no real XCTest, no live Gemini. Needs Package.swift/project.yml/Info.plist entries (see PR body).
