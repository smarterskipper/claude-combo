## 2026-10-08 — Initial combo marketplace
- model-router fork (band UI, per-prompt cost, redo step-up), combo-rules plugin, upstream plugins pinned by SHA
- Follow-up needed: merge dev → main PR so `/plugin marketplace add` picks it up

## 2026-10-08 — Subagent + workflow routing
- model-router 0.3.0: `agent.spawn` hook grades each subagent / workflow agent task; `turn.step` steps it down only (never up). `routeAgents` setting (default on). 14 tests pass.
- Follow-up needed: agent routing is keyword-only; no Haiku grading per agent (cost/latency)
