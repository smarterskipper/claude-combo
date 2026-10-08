# claude-combo

My Claude Code setup in one marketplace: four plugins that work together, plus the rules that stop them fighting.

| Plugin | What it does | Source |
|---|---|---|
| **model-router** | Routes each turn to the cheapest model + effort that fits (Haiku → Sonnet → Opus → Fable). Draws a 2-row colored band above the prompt: the latest prompt's arrow to its model, plus recent prompts with per-prompt cost. | Fork of [mod-squad/model-router](https://github.com/TroyJLorents-GH/mod-squad) (this repo, private: upstream has no license) |
| **combo-rules** | Injects the conflict rules at session start (superpowers = process, ponytail = size, ADHD = reply shape). | This repo |
| **superpowers** | Process skills: brainstorming, TDD, debugging, verification. | [obra/superpowers](https://github.com/obra/superpowers) @ `5bf4e78`, MIT |
| **ponytail** | Smallest correct diff, no speculative code. | [DietrichGebert/ponytail](https://github.com/DietrichGebert/ponytail) @ `e3ba2aa`, MIT |
| **i-have-adhd** | Replies shaped for ADHD: next action first, numbered steps. | [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) @ `839872f`, MIT |

The three upstream plugins are pinned to the commits tested together; nothing of theirs is copied here.

## Install (new machine)

The repo is private, so git on that machine must be able to read it (`gh auth login` or a credential helper).

```
/plugin marketplace add smarterskipper/claude-combo
/plugin install model-router@claude-combo
/plugin install combo-rules@claude-combo
/plugin install superpowers@claude-combo
/plugin install ponytail@claude-combo
/plugin install i-have-adhd@claude-combo
```

Pick the **user** scope for each so they're on in every session.

If you already have superpowers / ponytail / i-have-adhd installed from their own marketplaces, uninstall those first so the hooks don't run twice. If your `~/.claude/CLAUDE.md` already has the "Ponytail × Superpowers × ADHD" section, skip `combo-rules` or delete that section.

## Fixes over the upstream model-router

- **Band instead of a side pane.** Two short colored rows above the prompt; closes any leftover pane from the old version.
- **Per-prompt cost + routing arrow.** Arrow length and color scale with price; dashed while the turn runs.
- **Redo step-up.** A prompt starting like "that's wrong" / "still broken" / "try again" sends that turn to the next model up and marks the previous prompt ✗. A free quality check: no extra model calls.
- **Manifest settings restored** (classifier, ceiling, stickiness show in `/config`).

`/route` shows why the current model was picked; `/route off`, `/route auto`, `/route pin opus high`.

Costs shown are API list prices. On a Max plan they're what the turn would have cost, not what you pay.

## Limits

- Subagents and workflow agents **are** routed (setting `routeAgents`, on by default): each task is graded from its spawn prompt by keyword rules (no model call) and the agent steps *down* to the cheapest model that fits. It is never raised above the model it would have used, so an explicit `model:` in an agent definition or workflow call is respected, and forks and teammates are left alone.
- Agent steps don't appear in the band, only the main conversation's prompts.
- The mod API is early access and may break on a Claude Code update.

## Tests

```
claude plugin test plugins/model-router
claude plugin validate plugins/model-router
```
