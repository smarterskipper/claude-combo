## 2026-10-08 — Initial combo marketplace
- model-router fork (band UI, per-prompt cost, redo step-up), combo-rules plugin, upstream plugins pinned by SHA
- Follow-up needed: merge dev → main PR so `/plugin marketplace add` picks it up

## 2026-10-08 — Subagent + workflow routing
- model-router 0.3.0: `agent.spawn` hook grades each subagent / workflow agent task; `turn.step` steps it down only (never up). `routeAgents` setting (default on). 14 tests pass.
- Follow-up needed: agent routing is keyword-only; no Haiku grading per agent (cost/latency)

## 2026-10-10 — blue-questions plugin
- New plugin `blue-questions` 0.2.0: blue glowing bar on Claude's trailing questions, amber bar on action items for the user ("Next action:", "Needs you:" lists, "you need to…", "ready for you to merge"). 2 tests pass.
- Installed user-wide as `blue-questions@claude-combo`
- Dropped model-router, combo-rules, ponytail, i-have-adhd (none were installed anymore); reasons in README "Dropped"
- Follow-up needed: tune the action-item phrase list if it misses or over-highlights lines

## 2026-10-10 — blue-questions 0.3.0: green for finished work
- Green bar on lines reporting finished work ("Merged #3.", "Both are done:", "is now live"); skips progress notes, promises and negations. ~2.5% of prose lines in recent transcripts. 3 tests pass.
- Follow-up needed: tune DONE_START / DONE_IS if green shows up where it shouldn't

## 2026-10-10 — blue-questions 0.4.0: Claude marks the lines
- Highlights were inconsistent because they guessed from phrasing. A `prompt.compose` section now asks Claude to start questions with ❓, action items with 👉 and finished work with ✅; marked lines always get their bar (anywhere in the reply) and the mark is hidden. Phrase guesses stay as fallback. 5 tests pass.
- Follow-up needed: watch for lines Claude forgets to mark; tighten the MARKS wording if it happens

## 2026-10-10 — blue-questions 0.5.0: glow sweep on new lines
- A new highlighted line sweeps its gradient across itself 6× (300 ms each, 40 ms frames), then settles to the still gradient. Only sweeping lines redraw; the timer stops when idle; no clock → still gradient, never a lost highlight. 6 tests pass.
- Follow-up needed: tune SWEEP_MS / SWEEPS from how it looks live
- 2026-10-10 tune: the 0.3 s sweep was too fast and the streaming re-spread looked like a slowdown after it. Colors now sit by character position (48-char repeating gradient) so streaming lines don't slide; one steady sweep, 800 ms per pass × 3. 7 tests pass.
- 2026-10-10 tune: owner wanted the motion always on and 2× faster, not just on new lines. Glow now slides continuously on every on-screen highlighted line, 400 ms per pass; off-screen lines hold still; timer stops when none are visible. 7 tests pass.
- 2026-10-10 tune: finished-work (green) slowed to 800 ms per pass; questions and action items stay at 400 ms. 8 tests pass.
