id: T-013
title: Backend skeleton: FastAPI, GET /api/health, bearer auth, CORS, pytest
role: backend
size: S
status: claimed
owner: chatgpt
depends: 
read: docs/02_WEB_PLAN.md#3, docs/03_CONTRACTS.md#2
created: 2026-10-17T03:40:49Z
doing: Tests and live Uvicorn health smoke passed; preparing review PR
doing_at: 2026-10-17T03:57:53Z
---
Done when: uvicorn serves /api/health -> {ok:true, schema_version:1}; every other /api route returns 401 without 'Authorization: Bearer $RECALL_TOKEN'; /media/{id}.jpg stays unauthenticated; pytest covers health and auth. Layout per docs/02_WEB_PLAN.md section 3.2. Python 3.11, pydantic v2, SQLite.
