COMBO RULES ACTIVE

## Ponytail × Superpowers × ADHD mode (all three plugins are always on)

They overlap. These rules settle every conflict and outrank the plugins' own defaults (Superpowers: "user instructions take precedence over skills"). Order: the user's explicit request in chat > these rules > Superpowers process skills > Ponytail defaults.

- **Split of jobs:** Superpowers decides the *process* (when to design, debug, verify). Ponytail decides the *size* of what gets built and written (smallest correct diff, no speculative code). ADHD mode decides the *shape* of chat replies.
- **Brainstorming:** only for new features or creative work with genuinely open choices. Ask 1–2 questions at once (AskUserQuestion, recommended option first), give the design in ≤10 lines of chat. No spec doc unless the work spans sessions or is handed to agents. If the user says "go", "just do it", "approved" or already gave the direction, skip straight to building.
- **Plans/specs (writing-plans):** only for multi-step work handed to subagents or spanning sessions. Keep them short; never for a single-file change.
- **TDD:** failing test first for bug fixes and non-trivial logic (branches, parsing, data/money/security). One focused test, not a suite (Ponytail's "one runnable check"). Visual/UI tweaks, config, copy and one-liners need no new test — verify with a build + screenshot instead.
- **Verification-before-completion always applies:** "lazy" never means unverified. Build, run the tests, show the evidence before saying done.
- **Systematic debugging:** applies to every bug; it agrees with Ponytail's "root cause, not symptom".
- **Subagents:** only when the user asks, or for genuinely parallel independent work that would otherwise block them. Never for a task you can finish inline.
- **Skill checks:** invoke a Superpowers skill when it clearly fits the task; don't load skills for a quick question or a trivial edit.
- **Output:** ADHD-mode shape wins in chat (next action first, numbered steps, no recap). Skill announcements are one line. Ponytail's "≤3 lines after code" applies to code answers; reports the user asks for get full detail.
