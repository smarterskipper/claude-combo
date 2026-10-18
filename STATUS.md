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
- 2026-10-10 tune: questions and action items 800 ms per pass, finished work 1600 ms. 8 tests pass.

## 2026-10-17 — blue-questions 0.5.1: no cut-off lines in the desktop app, marks reach desktop sessions
- Cut-off text: highlighted lines were drawn as 2-character colored runs. The desktop app draws a short run with no space as `white-space: pre`, so the line had nowhere to wrap and ran past the reply's edge. Runs are now whole words with the spaces between them bare (`words` in `hooks/classify.ts`); checked against the desktop's own CSS rules in headless Chrome.
- Text lost from bars: `plain()` dropped every `__`, `**` and backtick, so `__init__.py` showed as `init.py` and `**/*.swift` as `/*.swift`. Code spans now keep every character; only real bold pairs lose their stars.
- Missed classifications: the marks section was skipped whenever the engine reported `print`, which every desktop-app session does (SDK host), so Claude never marked lines there (0 marked replies in 397 desktop replies). Now skipped only for `/context` and for a session nothing has ever drawn (plain `-p`).
- Phrase guesses: "None are merged" / "Neither ... is deployed" no longer green; "Nothing needs you" and quoted text ("You must be 18 or older") no longer amber.
- Classifier moved to `hooks/classify.ts`; `tests/corpus.ts` holds 32 labeled lines. 49 tests pass; tsc clean.
- Follow-up needed: `/reload-plugins` (or a new session) to load it. The desktop paces transcript redraws to 1 per second, so the sweep animation is ~1 fps there.

## 2026-10-17 — combo-defaults 0.1.0; combo trimmed to three plugins
- blue-questions 0.5.0 sweep + 0.5.1 desktop fixes merged to main (PR #7)
- New plugin `combo-defaults`: `/combo-setup` skill runs `scripts/combo-setup.py`, which merges `model: claude-opus-5-5`, `modelSettings.claude-opus-5-5.effortLevel: high`, `outputStyle: Proactive`, `ultracode: true` into `~/.claude/settings.json` (other keys untouched, timestamped backup, `--dry-run`, no-op when already set). 6 tests pass.
- It's a setup step because a plugin's settings.json only honors `agent` and `subagentStatusLine`.
- Stale branches `dev` and `readme-public` (old model-router / ponytail / i-have-adhd / combo-rules code) tagged `archive/dev-2026-10-10` and `archive/readme-public-2026-10-10`; README "Dropped" table points there.
- Follow-up needed: delete remote branches `dev`, `readme-public`, `sweep`, `fix/blue-questions-wrap-and-marks` if not already gone (tags hold the old code)

## 2026-10-17 — process/agent-lanes: the default way of working, as reference files
- Boston's call: agent lanes are the default for every session (written into ~/.claude/CLAUDE.md "Default way of working"), so they're reference files, not a plugin, skill or command
- `process/agent-lanes/README.md`: what the process is, how a session uses it (ask the few real questions up front, then autonomous lanes; research and build what's missing when stuck), and stack notes for iOS/Xcode on the remote Mac through `~/bin/xq` (`-derivedDataPath "$CI_DD"` per lane) and .NET memory hygiene (one `dotnet test` at a time, `DOTNET_GCHeapHardLimit`)
- `agent-lanes-bootstrap.md`: an exact copy of the guide
- `templates/`: 15 files extracted verbatim from the guide's code blocks, at their target paths, with the STACK blocks left as placeholders. `bash -n` + `dash -n` pass on all 4 .sh; `node --check` passes on build-gallery.mjs; lane.js and review.js are Workflow scripts (top-level `return`/`await`, injected `args`/`agent`), so plain `node --check` rejects them ("Illegal return statement"), but both parse when wrapped in an async function; the JSON files parse
- No earlier feat/agent-lanes branch or plugins/agent-lanes folder existed, so there was nothing to clean up
- Follow-up needed: integration-gate.ps1 not syntax-checked (no pwsh on this box); the board page (tools/board/board.html) isn't given in full by the guide and gets written per repo
