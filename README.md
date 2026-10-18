# claude-combo

A Claude Code setup in one marketplace: reply highlights, superpowers, and the defaults they run with.

| Plugin | What it does | Source |
|---|---|---|
| **blue-questions** | Reply highlights. Draws Claude's closing question with a glowing blue bar and action items for you (lines like "Next action:", lists under "Needs you:", "ready for you to merge") with an amber bar, and finished work ("Merged #3.", "Both are done:", "The fix is now live.") with a green bar, so none of them gets lost in a long reply. | This repo |
| **superpowers** | Process skills: brainstorming, TDD, debugging, verification. | [obra/superpowers](https://github.com/obra/superpowers) @ `5bf4e78`, MIT |
| **combo-defaults** | One-time `/combo-setup`: Opus 5.5 (`claude-opus-5-5`) at high effort, the Proactive output style, and ultracode on by default. | This repo |

superpowers is pinned to a tested commit; nothing of it is copied here.

## Install (new machine)

```
/plugin marketplace add smarterskipper/claude-combo
/plugin install blue-questions@claude-combo
/plugin install superpowers@claude-combo
/plugin install combo-defaults@claude-combo
```

Pick the **user** scope for each so they're on in every session. If you already have superpowers installed from its own marketplace, skip it here so its hooks don't run twice.

Then run `/combo-setup` once (it shows as `/combo-defaults:combo-setup`), or from a clone of this repo:

```
python3 plugins/combo-defaults/scripts/combo-setup.py --dry-run   # show what would change
python3 plugins/combo-defaults/scripts/combo-setup.py             # apply
```

It merges these keys into `~/.claude/settings.json` and leaves every other key where it is, after backing the file up as `settings.json.bak-<timestamp>`:

```json
{
  "model": "claude-opus-5-5",
  "modelSettings": { "claude-opus-5-5": { "effortLevel": "high" } },
  "outputStyle": "Proactive",
  "ultracode": true
}
```

**Why a setup step:** a plugin's own `settings.json` only honors `agent` and `subagentStatusLine`, so no plugin can set the model, effort, output style or ultracode. They have to live in your user settings. Effort is set per model because a top-level `effortLevel` is ignored for Opus 5.5. `ultracode` only takes effect when workflows are enabled.

## Dropped (2026-10-10)

This marketplace used to ship four more plugins. They're gone, and here's why:

| Plugin | Why it was dropped |
|---|---|
| **model-router** | Routing turns to cheaper models backfired: the lower models pushed back on doing the work instead of doing it. |
| **ponytail** | No real change in how Claude worked with it on vs. off. |
| **i-have-adhd** | Its reply shaping ended up making Claude's communication worse, not clearer. |
| **combo-rules** | Only existed to settle conflicts between superpowers, ponytail and i-have-adhd. With two of those gone, there's nothing to settle. |

Their code is kept under the `archive/dev-2026-10-10` and `archive/readme-public-2026-10-10` tags (and in the git history) if you ever want one back.

## Limits

- blue-questions adds a short section to Claude's instructions asking it to start those lines with ❓ (question), 👉 (action item for you) or ✅ (finished work). A marked line is always highlighted, wherever it sits, and the mark is hidden. This works in the terminal and the desktop app. Unmarked lines fall back to phrase guesses (`LABEL` / `ASK` for amber, `DONE_START` / `DONE_IS` for green in `plugins/blue-questions/hooks/classify.ts`), which can miss; `plugins/blue-questions/tests/corpus.ts` holds labeled real lines.
- Each highlighted word is its own colored run with the spaces between left bare. The desktop app draws a short run with no space as `white-space: pre`, so splitting lines into fixed-size runs stopped them wrapping and cut them off at the edge.
- The instruction isn't added under `claude -p` or where nothing draws the reply, so marks never show raw there.
- Green skips progress notes between tool calls (a block ending in `:`, or "Merged. Running the tests"), promises ("I'll…", "once…") and negations ("not done yet").
- Highlighted lines on screen keep their glow sliding along all the time: questions and action items one pass every 0.8 s, finished work every 1.6 s. Lines scrolled out of view hold still, and the frame timer stops when no highlighted line is on screen. Colors sit by character position, so a line still streaming in doesn't jump.
- The mod API is early access and may break on a Claude Code update.

## Tests

```
claude plugin test plugins/blue-questions
claude plugin validate plugins/blue-questions
claude plugin validate plugins/combo-defaults
python3 -m unittest plugins/combo-defaults/tests/test_combo_setup.py
```
