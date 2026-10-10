# claude-combo

A Claude Code setup in one marketplace.

| Plugin | What it does | Source |
|---|---|---|
| **blue-questions** | Draws Claude's closing question with a glowing blue bar and action items for you (lines like "Next action:", lists under "Needs you:", "ready for you to merge") with an amber bar, and finished work ("Merged #3.", "Both are done:", "The fix is now live.") with a green bar, so none of them gets lost in a long reply. | This repo |
| **superpowers** | Process skills: brainstorming, TDD, debugging, verification. | [obra/superpowers](https://github.com/obra/superpowers) @ `5bf4e78`, MIT |

superpowers is pinned to a tested commit; nothing of it is copied here.

## Install (new machine)

```
/plugin marketplace add smarterskipper/claude-combo
/plugin install blue-questions@claude-combo
/plugin install superpowers@claude-combo
```

Pick the **user** scope for each so they're on in every session. If you already have superpowers installed from its own marketplace, skip it here so its hooks don't run twice.

## Dropped (2026-10-10)

This marketplace used to ship four more plugins. They're gone, and here's why:

| Plugin | Why it was dropped |
|---|---|
| **model-router** | Routing turns to cheaper models backfired: the lower models pushed back on doing the work instead of doing it. |
| **ponytail** | No real change in how Claude worked with it on vs. off. |
| **i-have-adhd** | Its reply shaping ended up making Claude's communication worse, not clearer. |
| **combo-rules** | Only existed to settle conflicts between superpowers, ponytail and i-have-adhd. With two of those gone, there's nothing to settle. |

They're still in the git history if you ever want one back.

## Limits

- blue-questions adds a short section to Claude's instructions asking it to start those lines with ❓ (question), 👉 (action item for you) or ✅ (finished work). A marked line is always highlighted, wherever it sits, and the mark is hidden. Unmarked lines fall back to phrase guesses (`LABEL` / `ASK` for amber, `DONE_START` / `DONE_IS` for green in `plugins/blue-questions/hooks/register.tsx`), which can miss.
- The instruction isn't added under `claude -p` or where nothing draws the reply, so marks never show raw there.
- Green skips progress notes between tool calls (a block ending in `:`, or "Merged. Running the tests"), promises ("I'll…", "once…") and negations ("not done yet").
- A newly drawn highlighted line sweeps its glow across itself 3 times (0.5 s each), then holds still. Only sweeping lines redraw, and the frame timer stops once nothing is sweeping. After a restart or resume, highlighted lines already on screen sweep once more.
- The mod API is early access and may break on a Claude Code update.

## Tests

```
claude plugin test plugins/blue-questions
claude plugin validate plugins/blue-questions
```
