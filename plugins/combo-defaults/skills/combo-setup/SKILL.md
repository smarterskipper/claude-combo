---
name: combo-setup
description: Set the claude-combo defaults (Opus 5.5, high effort, Proactive output style, ultracode) in ~/.claude/settings.json. Run once per machine when the user asks for combo setup or /combo-setup.
disable-model-invocation: true
allowed-tools:
  - Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/combo-setup.py" *)
  - Bash(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/combo-setup.py")
---

# combo-setup

Plugins can't set the model, effort, output style or ultracode, so this skill writes them into the user's own settings file (`~/.claude/settings.json`, or `$CLAUDE_CONFIG_DIR/settings.json` when that is set).

Merge exactly these keys, and nothing else:

| Key | Value |
|---|---|
| `model` | `"claude-opus-5-5"` |
| `modelSettings.claude-opus-5-5.effortLevel` | `"high"` (merged into any existing `modelSettings`; other models and other keys under `claude-opus-5-5` stay) |
| `outputStyle` | `"Proactive"` |
| `ultracode` | `true` |

Never remove or reorder any other key. Create the file if it is missing.

## Steps

1. Preview: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/combo-setup.py" --dry-run`
2. Apply: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/combo-setup.py"`. It backs the old file up as `settings.json.bak-<timestamp>` first, and writes nothing when every key is already set.
3. Show the user the change lines the script printed (`+` added, `~` changed) and the backup path. Don't print the settings file itself: it can hold tokens.
4. Tell them the new model, effort and output style apply from the next session, and that `ultracode` needs workflows enabled.

If the script exits with an error (invalid JSON, `modelSettings` not an object), report it and stop. Don't edit the file by hand. If the Bash call is refused, give the user the step 2 command to run themselves.
