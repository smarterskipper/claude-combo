# Notes for agents

## Scripts and output
- Every script goes under tools/ with a one-line header comment saying what it does and how to run it.
- Script output goes in an out/ folder next to the script (gitignored), never /tmp or a scratchpad.
- Don't delete scripts in tools/ without asking.
- Never copy src/ or tools/ into out/ folders. To compare with old code use `git show <rev>:<path>`.

## Git
- Never use `git stash` (the stash stack is shared by every worktree). Use a WIP commit.
- Run state-changing git commands (rebase, merge, cherry-pick, add, commit, push) one at a time.
  Never chain them with `;` or pipe them in a way that hides the exit code. Check the exit code before the next command.
- Before `git add` during a conflict: the file has no conflict markers and still compiles.
- Never push to main. Never tag, release, publish or dispatch CI/deploy workflows.
- Commit messages describe only what is in the diff, written after reading `git diff --cached`.
  <your commit message rules, e.g. "no Co-Authored-By lines">

## Lanes
- Lanes work only inside their own worktree under .worktrees/. The orchestrator alone writes to the integration branch.
- Each lane has its own port in LANE_PORT (from .lane.env). Never use another lane's port or the human's dev port (<port>).
- Never install, add, upgrade or remove dependencies in a lane.
- The baseline in tools/lanes/baseline/ must diff empty. A difference in existing behaviour is a regression even when it looks like a fix.
  Only the orchestrator accepts a baseline change, in its own commit, after a decision card.

## Build, test, release
The runbook is docs/runbook.md. Update it in the same change when a build, test or check command changes.
