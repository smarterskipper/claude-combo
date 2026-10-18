# Agent lanes: bootstrap guide

This guide sets up parallel agent lanes on any repo: a Unity game, a .NET service or a React web app. Each lane has its own worktree and runs a gated, reviewed, committed step loop. Lanes integrate into a shared branch through one integration gate, and a live board and a screenshot gallery track the work.

It is written for a developer and their coding agent. The agent is Claude Code with the Workflow and Agent tools, and it uses claude.ai Artifacts for the board and the gallery. An agent should be able to bootstrap a new repo from this file alone. Follow section 2 in order.

Where an example comes from the project this process was built on, it is labelled "in the project this came from". Everything else is generic.

---

## 1. What you get

You split the work into lanes. A lane is one branch, one git worktree, one dev port and an ordered list of steps. A Workflow script (the lane runner) takes each step through the same loop: an agent implements it, a gate agent runs the full integration gate, two reviewer agents look for defects through different lenses, fix agents address what failed, and finally a commit agent commits the step with a compact evidence record. A step that cannot pass stops its lane, so nothing is stacked on broken work. The orchestrator is the Claude Code session you talk to. When a lane finishes, it rebases the lane onto the integration branch, reruns the full gate on the rebased tree, reads the screenshots, fast-forwards the integration branch and pushes. In the same turn it updates the board, the gallery and the log. You review the board and the gallery, often from a phone, and you merge the integration branch into `main` yourself.

```
                     you (human): decisions, review, merge to main
                         ^                  ^
                         | board            | gallery
                         |                  |
  +----------------------+------------------+---------------------+
  |                  ORCHESTRATOR (Claude Code session)            |
  |  creates lanes, launches lane.js, integrates, keeps board,     |
  |  gallery and log current, files decision cards                 |
  +------+-------------------+-------------------+-----------------+
         | Workflow           | Workflow          | Workflow
         v                    v                   v
   +-----------+        +-----------+       +-----------+
   | lane A    |        | lane B    |       | lane C    |   one worktree,
   | port 5301 |        | port 5302 |       | port 5303 |   branch, port each
   | per step: |        |           |       |           |
   | implement |        |   ...     |       |   ...     |
   | gate      |        |           |       |           |
   | 2 reviews |        |           |       |           |
   | fix x3    |        |           |       |           |
   | commit    |        |           |       |           |
   +-----+-----+        +-----+-----+       +-----+-----+
         |  lane done         |                   |
         v                    v                   v
   +-----------------------------------------------------------+
   | INTEGRATION (one lane at a time, under a lock)            |
   | rebase onto integration -> integration gate on the        |
   | rebased tree -> read screenshots -> merge --ff-only       |
   +----------------------------+------------------------------+
                                v
                  integration branch (long-lived, pushed)
                                |
                                v  (you, by PR)
                              main
```

### Roles

| Role | Who | Owns | Never does |
|---|---|---|---|
| Human | you | product decisions, final review, merging to `main`, releases | gets blocked on by the agents while away |
| Orchestrator | the Claude Code session you talk to | creating lanes (worktree, branch, port), writing step specs, launching lane workflows, integrating, the board, the gallery and the log | implements lane steps itself; merges to `main`; releases, tags or deploys |
| Lane agents | subagents started by `lane.js` (implement, gate, review, fix, commit) | one step in one worktree | touch another worktree, the integration branch or `main`; install dependencies; use another lane's port |
| Review agents | subagents started by `review.js` | read-only review of a merge range | edit anything |

### Branch model

- `main`: the default branch. Only the human merges into it, normally by PR from the integration branch.
- `integration` (any name, e.g. `release-0.3`, `campaign-v0.2`): the long-lived shared branch. It lives in its own worktree, `.worktrees/integration`, so the main checkout stays on `main` for the human. Only the orchestrator writes to it, and only by `merge --ff-only` or a gated `cherry-pick`.
- `lane/<name>`: one per lane, cut from `integration`, in worktree `.worktrees/<name>`. Lanes push their own branch only.

```
main         o-------------------------------------------o  (human PR)
              \                                         /
integration    o---A1---A2---B1---B2---C1--------------o
                \      /     \       /
lane/a           A1---A2      \     /
lane/b                         B1--B2   (rebased onto A2 before ff)
```

---

## 2. Bootstrap checklist

The agent runs these steps in order. Each step names the files it creates. Fill the STACK blocks from section 8.

### 2.0 Prerequisites

- Git 2.38 or later, with Git LFS if the repo uses it.
- Claude Code with the Workflow tool, and access to claude.ai Artifacts with the database capability (for the board).
- Node 18 or later, for the gallery builder only. A Unity or .NET repo needs Node just for `tools/gallery/`.
- The stack's own tools (Unity Hub editor, .NET SDK, Node/pnpm). See section 8.

### 2.1 Repo layout to create

```
CLAUDE.md (or AGENTS.md)            agent rules, section 2.2
docs/runbook.md                     build/test/release commands and the lane rules, section 2.3
tools/lanes/lane.js                 lane runner Workflow script, section 3
tools/lanes/review.js               read-only integration review Workflow script, section 3.6
tools/lanes/integration-gate.sh     integration gate, POSIX sh, section 4
tools/lanes/integration-gate.ps1    integration gate, PowerShell 7, section 4 (Windows)
tools/lanes/capture-baseline.sh     deterministic baseline capture, section 4.3
tools/lanes/check-staged.sh         commit budget check, section 3.5
tools/lanes/new-lane.sh             creates a lane worktree, branch and .lane.env, section 2.5
tools/lanes/args/<lane>.json        each lane's Workflow args (kept for resume)
tools/lanes/baseline/               the committed baseline (text fingerprints)
tools/lanes/evidence/<lane>/<step>/ committed compact gate records
tools/lanes/log/overnight-<date>.md the run log, section 9
tools/lanes/out/                    gitignored: gate logs, captures, reports
tools/board/board.html              board Artifact page, section 6
tools/board/seed/{cards,epics,slices}/*.json   seed documents
tools/gallery/gallery.json          gallery source of truth, section 7
tools/gallery/build-gallery.mjs     gallery builder
tools/gallery/package.json          {"private":true,"type":"module","dependencies":{"sharp":"^0.33.0"}}
tools/gallery/out/                  gitignored: built page and images
.worktrees/                         gitignored: lane worktrees
```

Add to `.gitignore` in the same commit:

```
.worktrees/
.lane.env
tools/lanes/out/
tools/gallery/out/
tools/gallery/node_modules/
```

Add the stack's own ignores too (section 8). Every new output folder goes into `.gitignore` in the same commit as the script that creates it.

### 2.2 Agent rules file (`CLAUDE.md` or `AGENTS.md`)

Subagents read this file automatically, so put project-wide rules here. The lane runner repeats only the lane-specific rules (root, port, branch). Paste this and edit the names.

```markdown
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
```

### 2.3 Runbook (`docs/runbook.md`)

Create it with these sections. Fill the commands from section 8.

- **Setup**: clone, LFS, dependencies, editor or SDK versions.
- **Build / test / checks**: the exact commands, and what the gate runs.
- **Baseline**: what `capture-baseline.sh` fingerprints, how to prove it is deterministic, and who may accept a change.
- **Parallel lanes**: the integration branch name, worktree paths, the port range (e.g. 5300 to 5399, with 5197 left to the human), `new-lane.sh`, the dependency rule, and the integration recipe from section 5.
- **Board and gallery**: their Artifact URLs, and how to rebuild and republish the gallery.
- **Release**: the human's steps only.

### 2.4 Integration branch and worktree

```sh
git switch main && git pull
git branch integration main
git push -u origin integration
git worktree add .worktrees/integration integration
# install dependencies in .worktrees/integration (section 8)
```

The orchestrator works in `.worktrees/integration` from now on. Use short worktree paths on Windows (e.g. `C:\w\integration`).

### 2.5 `tools/lanes/new-lane.sh`

```sh
#!/bin/sh
# Creates a lane: branch lane/<name> from the integration branch, worktree .worktrees/<name>, and a .lane.env with its port. Run: sh tools/lanes/new-lane.sh <name> <port>
set -eu
name=${1:?usage: new-lane.sh <name> <port>}; port=${2:?usage: new-lane.sh <name> <port>}
INT=${INT_BRANCH:-integration}
common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
main=$(dirname "$common")
wt="$main/.worktrees/$name"
if grep -qx "LANE_PORT=$port" "$main"/.worktrees/*/.lane.env 2>/dev/null; then
  echo "port $port is already used by another lane"; exit 1
fi
git worktree add -b "lane/$name" "$wt" "$INT"
cat > "$wt/.lane.env" <<EOF
LANE=$name
LANE_PORT=$port
COMPOSE_PROJECT_NAME=lane_$name
DB_NAME=app_lane_$name
SHOTS_DIR=tools/lanes/out/shots
EOF
# ===== STACK: dependency setup for the new worktree (section 8) =====
# React (pnpm): (cd "$wt" && pnpm install --frozen-lockfile)
# .NET:         (cd "$wt" && dotnet restore --locked-mode)
# Unity:        cp -cR "$main/.worktrees/integration/<UnityProject>/Library" "$wt/<UnityProject>/Library"   # macOS clonefile
echo "$wt"
```

### 2.6 Baseline

1. Write `tools/lanes/capture-baseline.sh` (section 4.3) with the stack's fingerprints.
2. Capture it twice and prove it is deterministic:
   ```sh
   BASELINE_OUT=tools/lanes/out/b1 sh tools/lanes/capture-baseline.sh
   BASELINE_OUT=tools/lanes/out/b2 sh tools/lanes/capture-baseline.sh
   git diff --no-index --exit-code tools/lanes/out/b1 tools/lanes/out/b2   # must be empty
   ```
3. Commit it: `BASELINE_OUT=tools/lanes/baseline sh tools/lanes/capture-baseline.sh`.

### 2.7 Gate, lane runner, review workflow

- Write `tools/lanes/integration-gate.sh` (and `.ps1` on Windows) from section 4. Fill in its STACK block.
- Run it once on the integration worktree. It must print `GATE PASS` and leave `git status` unchanged:
  `LANE_PORT=5399 sh tools/lanes/integration-gate.sh "$PWD"`
- Write `tools/lanes/lane.js` and `tools/lanes/review.js` from section 3. Fill in the STACK block.
- Write `tools/lanes/check-staged.sh` from section 3.5.

### 2.8 Board Artifact

Section 6 has the details.

1. Load the `artifact-capabilities` and `artifact-design` skills.
2. Write `tools/board/board.html`.
3. Publish it with the `db` capability.
4. Seed it with one `ArtifactData` batch per 50 to 100 documents, from the JSON files in `tools/board/seed/`.
5. Put the URL in the runbook.

### 2.9 Gallery Artifact

Section 7 has the details.

1. Write `tools/gallery/gallery.json` with one section, holding a shot of the current app taken by the gate.
2. Install the builder's dependency: `npm install --prefix tools/gallery`.
3. Build it: `node tools/gallery/build-gallery.mjs`.
4. Read every image in `tools/gallery/out/img/`.
5. Publish `tools/gallery/out/index.html`, with `files` from `out/publish-files.json` and an `icon`.
6. Put the URL in the runbook.

### 2.10 Log

Create `tools/lanes/log/overnight-<YYYY-MM-DD>.md` from the template in section 9.

### 2.11 Commit the bootstrap

Commit everything on `integration` and push. Then do a dry run: one lane with one trivial step (e.g. "add a health line to the README and a check that asserts it"). Integrate it with the section 5 recipe before you start real lanes.

### Kickoff prompt for a new session

> Read docs/process/agent-lanes-bootstrap.md and docs/runbook.md. You are the orchestrator. The integration branch is `<name>`, the board is `<url>`, the gallery is `<url>`. Plan lanes for `<cards or slices>`, create them with new-lane.sh, write their args files and launch them with tools/lanes/lane.js. Integrate each lane when it finishes.

---

## 3. The lane runner (`tools/lanes/lane.js`)

### 3.1 Workflow script facts

- **Language.** Workflow scripts are plain JavaScript, never TypeScript, whatever the project's language is. A Unity, .NET or React team writes the same JS file.
- **What it can do.** The script runs no project code and has no filesystem or Node API. Agents do all project work through their own tools. `dotnet test`, a Unity batchmode run or `npm run build` belong in agent prompts or in the gate script, never in the JS.
- **Header.** The script must start with `export const meta = { name, description, phases }` as a pure literal. Phase titles must match the `phase` names used in `agent()` calls.
- **`agent(prompt, { label, phase, schema, effort })`.** With a JSON Schema `schema`, it returns a validated object. That is how the gate and the reviews return machine-readable verdicts. It returns `null` if the agent is skipped or dies, so always guard against it.
- **`parallel(thunks)`.** A barrier that never rejects.
- **`pipeline(items, ...stages)`.** Has no barrier. Each item flows through the stages on its own, and stages get `(prev, item, index)`.
- **`log(text)`.** Writes narrator lines.
- **Banned calls.** `Date.now()`, `Math.random()` and `new Date()` with no argument all throw, because they would break resume. Pass timestamps in through `args`.
- **Limits.** About min(16, CPUs - 2) agents run at once. A run can start at most 1000 agents.
- **Resume.** Every run has a `runId`. Relaunch with `Workflow({ scriptPath, args, resumeFromRunId })`. The longest unchanged prefix of `agent()` calls replays from the cache, and everything from the first changed call onwards runs live. So you can append steps to `args.steps`, or edit a later step's spec, and resume without redoing finished steps. To diagnose a run, read `<transcriptDir>/journal.jsonl`.
- **Isolation.** Do not use `isolation: 'worktree'`. The implement, gate, review, fix and commit agents must all see the same uncommitted tree, so each lane runs in a long-lived worktree the orchestrator created.

### 3.2 Args

Each lane's args are written to `tools/lanes/args/<lane>.json` and committed on the integration branch. They are needed for resume.

```json
{
  "lane": "auth",
  "root": "/abs/path/repo/.worktrees/auth",
  "branch": "lane/auth",
  "port": 5301,
  "steps": [
    { "key": "auth-1-session-model", "msg": "Add the session model and its store", "spec": "..." },
    { "key": "auth-2-login-ui", "msg": "Login screen with session restore", "spec": "..." }
  ]
}
```

A step `spec` is plain prose. Use this template:

```
Card(s): AUTH.1 (board). Slice: VS2.
Goal: <one paragraph: what and why>.
Scope: <files/modules you expect to touch>. Out of scope: <what must not change>.
Acceptance: <observable outcomes, numbered>.
Decisions already made: <link to doc or card; "provisional" if not confirmed>.
Gate extras: <commands beyond the integration gate, e.g. a specific test filter>.
Screenshots: <which states, which viewports, file names under SHOTS_DIR>.
```

### 3.3 The script

```js
// Workflow script: runs one lane. Each step is implemented, gated, reviewed by two lenses, fixed (up to 3 rounds) and committed with a compact evidence record, in the lane's own worktree and branch.
// Run: Workflow({ scriptPath: 'tools/lanes/lane.js', args: <contents of tools/lanes/args/<lane>.json> })
// args: { lane, root, branch, port, steps: [{ key, msg, spec }] }   root = absolute path of the lane worktree
export const meta = {
  name: 'lane',
  description: 'Run one lane: each step implemented, gated, reviewed, fixed and committed on the lane branch in its own worktree',
  phases: [{ title: 'Lane' }],
}

const { lane, root, branch, port, steps } = args

// ===== STACK: the only project-specific block. Fill it in while bootstrapping (section 8 has values per stack). =====
const STACK = {
  integrationBranch: 'integration',
  defaultBranch: 'main',
  worktreesDir: '/ABS/PATH/TO/REPO/.worktrees',
  humanPort: 5197,                                   // the human's own dev server; lanes never use it
  BUILD: 'npm run build',                            // what "it builds" means
  TEST: 'npm test',                                  // the fast unit tests
  CHECKS: 'every npm script named lint, typecheck, test:* or check:* (the gate finds them)',
  BASELINE: 'BASELINE_OUT=<dir> sh tools/lanes/capture-baseline.sh, then git diff --no-index --exit-code tools/lanes/baseline <dir> must be empty',
  BASELINE_SCOPE: 'existing routes, API responses and saved-data formats',  // what "existing behaviour" covers
  SCREENSHOTS: `LANE_PORT=${port} SHOTS_DIR=<dir> npx playwright test e2e/shots.spec.ts (desktop 1440x900 and phone 390x844)`,
  PORT: `export LANE_PORT=${port}. Any server you start binds 127.0.0.1:${port} and must fail if the port is taken (e.g. vite --port ${port} --strictPort).`,
  DEPS: 'Dependencies were installed for this worktree by the orchestrator. Never install, add, upgrade or remove packages, and never edit lock files.',
  GATE: `sh tools/lanes/integration-gate.sh ${root}`,  // Windows: pwsh tools/lanes/integration-gate.ps1 ${root}
  READ_FIRST: ['docs/runbook.md', 'docs/architecture.md'],
  RUNBOOK: 'docs/runbook.md',
  COMMIT_RULES: 'Follow the commit message rules in CLAUDE.md / AGENTS.md.',
  LENSES: [
    'behaviour and regressions: anything that changes at runtime for existing features that the spec did not allow; missed call sites; persisted data and formats; error paths and edge cases (empty state, first run, retry, cancel, concurrent use); resources not released; tests that pin behaviour this change moved.',
    'design fit, code quality and hygiene: follows the design docs and recorded decisions; matches surrounding style; no dead code or speculative abstraction; public signatures and contracts kept; no copied source, symlinks or unreproducible output staged; runbook updated where commands changed; comments and docs state only true things.',
  ],
}
// ===== end STACK =====

const OUT = `${root}/tools/lanes/out`               // gitignored scratch for gates and reviewers
const EVIDENCE = `${root}/tools/lanes/evidence/${lane}`  // committed compact records
const MAX_ROUNDS = 4                                 // gate+review rounds per step; fixes run after rounds 1-3

const RULES = `
Working rules (all mandatory):
- You work in lane "${lane}": git worktree ${root}, branch ${branch}. Work ONLY inside ${root}. Other lanes run in parallel in other worktrees under ${STACK.worktreesDir}: never edit, commit, checkout, rebase or run state-changing git commands in any of them. Never touch ${STACK.integrationBranch} or ${STACK.defaultBranch}; never push them. Never push tags, run or dispatch CI or deploy workflows, or publish builds.
- Port: ${STACK.PORT} Never use port ${STACK.humanPort} or another lane's port. Stop every server or process you start.
- Dependencies: ${STACK.DEPS}
- Read first: ${STACK.READ_FIRST.map((p) => `${root}/${p}`).join(', ')}. Line numbers in docs drift; verify against the code.
- Write code that reads like the surrounding code: match naming, comment density and idioms. No dead code or speculative abstraction. Keep existing public signatures working.
- Scripts go under tools/ with a one-line header comment; their output goes in a gitignored out/ folder next to them. Never write to /tmp or a scratchpad. Never copy source folders; compare with old code via git show <rev>:<path>.
- If you change or add a build, test or check command, update ${STACK.RUNBOOK} in the same change.
- Existing behaviour must stay identical (${STACK.BASELINE_SCOPE}): ${STACK.BASELINE}. New behaviour is gated so it only applies where the spec says. A difference in existing behaviour is a regression even when it looks like a fix. Never update baselines, snapshots or golden files.
- Product questions the spec does not settle: take the option the spec or design docs recommend, keep it easy to reverse, and report it as "PROVISIONAL: <question> -> <choice>". If there is no reasonable default, stop and report "DECISION NEEDED: <question, options>".
- Do NOT commit unless the prompt says to. Never use git stash. Run state-changing git commands one at a time and check each exit code.`

const GATE_SCHEMA = {
  type: 'object',
  properties: {
    pass: { type: 'boolean' },
    checks: { type: 'array', items: { type: 'object', properties: {
      name: { type: 'string' }, command: { type: 'string' },
      result: { type: 'string', enum: ['pass', 'fail', 'flake-rerun-pass'] }, evidence: { type: 'string' },
    }, required: ['name', 'command', 'result', 'evidence'] } },
    regressions: { type: 'array', items: { type: 'string' } },
    shots: { type: 'array', items: { type: 'string' } },
  },
  required: ['pass', 'checks', 'regressions', 'shots'],
}
const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    blocking: { type: 'array', items: { type: 'object', properties: {
      file: { type: 'string' }, line: { type: 'number' }, issue: { type: 'string' }, why: { type: 'string' },
    }, required: ['file', 'issue', 'why'] } },
    nonBlocking: { type: 'array', items: { type: 'string' } },
  },
  required: ['blocking', 'nonBlocking'],
}
const COMMIT_SCHEMA = {
  type: 'object',
  properties: { hash: { type: 'string' }, files: { type: 'array', items: { type: 'string' } }, pushed: { type: 'boolean' }, notes: { type: 'string' } },
  required: ['hash', 'files', 'pushed'],
}

const gatePrompt = (step, extra) => `${RULES}

You are the GATE for this step. Do not edit source files; reports and captures go under ${OUT}/gates/${step.key}/ only. Step spec:
${step.spec}

1. Run: \`LANE_PORT=${port} ${STACK.GATE}\`. It compiles, runs every check, captures and diffs the baseline, builds, and fails if it changed the tree. Logs: ${OUT}/integration/. A FAIL there fails the gate unless you show it is a load flake: rerun that one check alone on the same tree; if it passes, record result "flake-rerun-pass" with both outputs.
2. Run everything the spec lists under "Gate extras".
3. Capture the screenshots the spec asks for: ${STACK.SCREENSHOTS}, with SHOTS_DIR=${OUT}/gates/${step.key}/shots. Open every image and check it shows what the spec claims. A blank, black, loading, wrong-state, debug-overlay or clipped shot is a fail. List the shot paths in "shots".
${extra}
Be skeptical; actually run things. pass=true only if every check passes.`

const fixPrompt = (step, gate, blocking) => `${RULES}

Fix the problems below in the uncommitted work for this step, without widening scope. Step spec:
${step.spec}
${gate ? `\nGate: ${JSON.stringify(gate)}` : ''}
Blocking review issues: ${JSON.stringify(blocking)}

If an issue is wrong, say so with evidence instead of changing code. If an issue needs a product decision only the human can make, don't guess: stop and say exactly what needs deciding.`

phase('Lane')
const results = []
for (const step of steps) {
  const P = `${lane}/${step.key}`

  await agent(`${RULES}\n\n${step.spec}\n\nWhen done, report files changed, what you verified and how (command output excerpts), any PROVISIONAL choices, and anything deferred.`,
    { label: `${step.key}:implement`, phase: 'Lane', effort: 'high' })

  let ok = false, gate = null, blocking = [], nonBlocking = [], rounds = 0
  for (let attempt = 0; attempt < MAX_ROUNDS; attempt++) {
    rounds = attempt + 1
    // The gate runs alone first: reviewers then read a tree the gate has proven builds.
    gate = await agent(gatePrompt(step, ''), { label: `${step.key}:gate${attempt}`, phase: 'Lane', schema: GATE_SCHEMA, effort: 'high' })
    if (!gate) log(`${P}: gate agent returned nothing; counting it as a fail`)

    const reviews = (await parallel(STACK.LENSES.map((lens, i) => () => agent(`${RULES}

You are a skeptical REVIEWER of the uncommitted work in ${root} (git status, git diff, new untracked files; read the touched code in context). Lens: ${lens}
Step spec:
${step.spec}
Report only real, specific issues. Blocking means: a bug, a regression, a spec violation, a rule violation, or a comment/doc/commit text that states something FALSE about behaviour. Wording, style and nice-to-have tests are nonBlocking. Settled decisions in the design docs are not issues. Verify before calling something blocking. Read only: do not edit files.`,
      { label: `${step.key}:review${attempt}.${i}`, phase: 'Lane', schema: REVIEW_SCHEMA, effort: 'high' })))).filter(Boolean)
    if (reviews.length < STACK.LENSES.length) log(`${P}: ${STACK.LENSES.length - reviews.length} reviewer(s) returned nothing; the round cannot pass`)

    blocking = reviews.flatMap((r) => r.blocking)
    nonBlocking = reviews.flatMap((r) => r.nonBlocking)
    if (gate && gate.pass && blocking.length === 0 && reviews.length === STACK.LENSES.length) { ok = true; break }
    if (attempt === MAX_ROUNDS - 1) break
    log(`${P}: gate ${gate && gate.pass ? 'passed' : 'failed'}, ${blocking.length} blocking; fixing (round ${attempt + 1})`)
    await agent(fixPrompt(step, gate, blocking), { label: `${step.key}:fix${attempt}`, phase: 'Lane', effort: 'high' })
  }

  // Final fix-and-gate rule: the last gate passed and only a few review issues are left.
  // One more fix, then a gate that also confirms each issue is resolved (no new review round).
  if (!ok && gate && gate.pass && blocking.length > 0 && blocking.length <= 3) {
    log(`${P}: ${blocking.length} review issue(s) left after the last round; one final fix and gate`)
    await agent(fixPrompt(step, null, blocking), { label: `${step.key}:fix-final`, phase: 'Lane', effort: 'high' })
    const last = await agent(gatePrompt(step, `4. Confirm each of these review issues is fixed or shown wrong, with evidence: ${JSON.stringify(blocking)}. pass=true only if every check passes AND every issue is resolved.`),
      { label: `${step.key}:gate-final`, phase: 'Lane', schema: GATE_SCHEMA, effort: 'high' })
    if (last && last.pass) { ok = true; gate = last; rounds += 1 }
  }

  // Stop on blocked: later steps never stack on a step that failed.
  if (!ok) {
    results.push({ step: step.key, status: 'blocked', gate, blocking })
    log(`${P} blocked after ${rounds} round(s); stopping the lane`)
    break
  }

  const record = { lane, step: step.key, branch, rounds, gate, nonBlocking }
  const commit = await agent(`${RULES}

This step passed its gate and review. Commit it on branch ${branch} in ${root}:
1. git status. Stage exactly this step's files.
2. Write the compact evidence record to ${EVIDENCE}/${step.key}/ and stage it:
   - evidence.json containing exactly this JSON: ${JSON.stringify(record)}
   - gate-summary.txt: the pass/FAIL lines the gate script printed
   - baseline-diff.txt: the baseline diff output (empty file if empty)
   - shots/: the screenshots listed in the gate's "shots" (PNG or JPEG)
   Do not commit full logs, full baseline captures, test-result folders, copies of report folders, or the gate's own scratch files (start patches, tree hashes). Keep the record under about 60 files and 2 MB. Delete from ${OUT}/gates/${step.key}/ what you don't commit.
3. Run \`sh tools/lanes/check-staged.sh\`; fix what it reports. Check git diff --cached --stat: nothing out of scope.
4. Run git diff --cached and read it. Then write the message: first line "${step.msg}", then a short body on what changed and how it was verified. Every behaviour, file or symbol you name must be in that diff. List PROVISIONAL choices in the body. ${STACK.COMMIT_RULES}
5. Commit, then \`git push -u origin ${branch}\` (run each alone, check exit codes).
Return the hash, the committed files and whether the push succeeded.`,
    { label: `${step.key}:commit`, phase: 'Lane', schema: COMMIT_SCHEMA, effort: 'medium' })
  results.push({ step: step.key, status: commit && commit.hash ? 'committed' : 'commit-failed', commit })
  if (!commit || !commit.hash) { log(`${P}: commit agent returned no hash; stopping the lane`); break }
}
return { lane, branch, results }
```

### 3.4 Order inside one step

1. One implement agent.
2. Up to 4 rounds. In each round, the gate runs first on its own, then the two reviewers run in parallel.
3. The step is accepted when the gate passes, both reviewers returned, and neither reports a blocking issue.
4. A fix agent runs after rounds 1, 2 and 3 and gets the whole gate JSON plus the blocking list. Round 4 gets no fix. That makes at most 4 gates, 8 reviews and 3 fixes per step.
5. **Final fix-and-gate.** If the last gate passed and only 1 to 3 blocking issues are left, one more fix runs and then a gate that also confirms each issue is resolved. No new review round runs.
6. **Stop on blocked.** A step that still fails is recorded as `blocked` with its gate and blocking list, and the lane stops.
7. The commit agent runs only on success, and returns `{hash, files, pushed}`.

### 3.5 `tools/lanes/check-staged.sh`

```sh
#!/bin/sh
# Fails if the staged change breaks the commit budget: symlinks, dependency/build folders, unaccepted snapshot output, or an evidence record over 60 files / 2 MB. Run before every lane commit: sh tools/lanes/check-staged.sh
fail=0
links=$(git diff --cached --raw --no-abbrev --diff-filter=AM | awk '$2 == "120000" {print $NF}')
[ -n "$links" ] && { echo "symlinks staged:"; echo "$links"; fail=1; }
bad=$(git diff --cached --name-only --diff-filter=AM | grep -E '(^|/)(node_modules|bin|obj|Library|Temp|Logs|UserSettings|\.next|tools/lanes/out|tools/gallery/out)/|\.received\.|-actual\.png$|-diff\.png$')
[ -n "$bad" ] && { echo "forbidden paths staged:"; echo "$bad" | head -20; fail=1; }
n=$(git diff --cached --name-only --diff-filter=AM -- tools/lanes/evidence | wc -l | tr -d ' ')
bytes=$(git diff --cached --raw --no-abbrev --diff-filter=AM -- tools/lanes/evidence | awk '{print $4}' | git cat-file --batch-check='%(objectsize)' | awk '{s+=$1} END {print s+0}')
[ "$n" -gt 60 ] && { echo "evidence has $n files (limit 60)"; fail=1; }
[ "$bytes" -gt 2097152 ] && { echo "evidence is $bytes bytes (limit 2 MB)"; fail=1; }
git diff --cached --stat | tail -1
[ $fail = 0 ] && echo "staged OK" || echo "staged FAIL"; exit $fail
```

### 3.6 Read-only integration review (`tools/lanes/review.js`)

Run it after a batch of merges, for example every few lanes or each morning. Lanes are reviewed alone. Bugs hide where two lanes' changes meet.

```js
// Workflow script: read-only review of a merge range on the integration branch; one reviewer per area finds defects where lanes meet, each finding adversarially verified. Run: Workflow({ scriptPath: 'tools/lanes/review.js', args: { root, range, areas: [{ key, focus }] } })
export const meta = {
  name: 'lane-review',
  description: 'Read-only integration review of a merge range: find defects per area, then try to refute each one',
  phases: [{ title: 'Review' }, { title: 'Verify' }],
}

const { root, range, areas, maxPerArea = 3 } = args

const COMMON = `You review ${root} READ ONLY: do not edit, stage or commit anything. You may run checks that write only to gitignored out/ folders; restore any tracked output they change (git checkout -- <path>) before you finish.
Commit range under review: ${range} (git log --stat ${range}).
These commits came from parallel lanes that were each reviewed alone, then rebased onto each other. Bugs hide where two lanes' changes meet: one lane's new resource, hook, field, setting or routing rule that another lane's code doesn't handle; two lanes each counting or pricing the same thing; a lifecycle (create/dispose, subscribe/unsubscribe) split across lanes; tests pinning behaviour another lane changed.
Report only real, specific defects you have evidence for (file:line, the inputs that trigger it, what goes wrong). Style, naming and missing tests are not findings. Return at most 6 findings; an empty list is a fine answer.`

const FINDINGS = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
  title: { type: 'string' }, file: { type: 'string' }, line: { type: 'number' },
  severity: { type: 'string', enum: ['high', 'medium', 'low'] }, scenario: { type: 'string' }, evidence: { type: 'string' },
}, required: ['title', 'file', 'severity', 'scenario', 'evidence'] } } }, required: ['findings'] }
const VERDICT = { type: 'object', properties: { real: { type: 'boolean' }, reason: { type: 'string' }, fix: { type: 'string' } }, required: ['real', 'reason', 'fix'] }

const dropped = []
const results = await pipeline(areas,
  (a) => agent(`${COMMON}\n\nYour area: ${a.focus}`, { label: `review:${a.key}`, phase: 'Review', schema: FINDINGS, effort: 'high' }),
  (r, a) => {
    const all = (r && r.findings) || []
    const kept = all.filter((f) => f.severity !== 'low').slice(0, maxPerArea)
    for (const f of all) if (!kept.includes(f)) dropped.push({ area: a.key, severity: f.severity, title: f.title, file: f.file })
    if (kept.length < all.length) log(`${a.key}: verifying ${kept.length} of ${all.length} findings; the rest are returned as "dropped"`)
    return parallel(kept.map((f) => () => agent(`${COMMON}

Adversarially verify this finding. Try to REFUTE it: read the code in context, trace the real call paths, and where you can, reproduce it with a read-only run. Default to real=false if you cannot show it happens. If it depends on work not merged yet, say so in reason. If real, give the smallest correct fix.

Finding: ${JSON.stringify(f)}`, { label: `verify:${a.key}`, phase: 'Verify', schema: VERDICT, effort: 'high' })
      .then((v) => ({ area: a.key, ...f, verdict: v }))))
  })
const all = results.flat().filter(Boolean)
return {
  confirmed: all.filter((f) => f.verdict && f.verdict.real),
  refuted: all.filter((f) => !(f.verdict && f.verdict.real)).map((f) => ({ area: f.area, title: f.title, reason: f.verdict ? f.verdict.reason : 'verifier returned nothing' })),
  dropped,
}
```

`areas` is the only project-specific input. Write one entry per subsystem, and name its files plus "Look for: ..." failure modes, e.g. `{ key: 'auth', focus: 'src/auth/**, src/api/session.ts. Look for: sessions not invalidated on logout, tokens refreshed twice, routes added by other lanes that skip the guard.' }`.

Each confirmed finding becomes a board card and usually a new lane. If a refuted finding's reason says it depends on unmerged work, it goes on a watchlist note on that work's card, to be checked again when that work merges.

---

## 4. The integration gate

The gate is the only stack-specific entry point. Lanes run it on their uncommitted tree, and the orchestrator runs it on the rebased tree before every fast-forward. If CI is added later, CI calls the same script.

What the gate does, in order:

1. It refuses (exit 2) if a rebase, merge or cherry-pick is in progress, if unmerged paths remain, or if any file contains conflict markers.
2. It refuses if `LANE_PORT` is unset. There is no shared default port.
3. With `REQUIRE_BASE=<branch>` set, it refuses unless HEAD contains that branch's tip. The orchestrator uses this after a rebase.
4. It snapshots the tree: `git status` plus a hash of `git diff`, the untracked file list, and a patch of the tracked output folders the checks regenerate.
5. It runs every check and keeps going after a failure, so you see all failures at once:
   - compile and typecheck
   - every discovered check, plus checks the branch added that no script runs yet
   - the baseline capture and diff
   - the build
   - a check for leftover snapshot output
6. It restores the tracked output and compares the tree. It fails if the tree changed or if it left new untracked files behind.

### 4.1 POSIX sh (`tools/lanes/integration-gate.sh`)

```sh
#!/bin/sh
# Integration gate: refuses mid-rebase/merge, runs every discovered check, the baseline capture + diff and the build on a worktree, and leaves the tree as it found it. Run: LANE_PORT=<port> [REQUIRE_BASE=integration] sh tools/lanes/integration-gate.sh <worktree>   (logs in <worktree>/tools/lanes/out/integration/; exit 0 pass, 1 fail, 2 refused)
set -u
root=${1:?usage: integration-gate.sh <worktree>}
cd "$root" || exit 2

# ===== STACK: fill in once (section 8) =====
BASE_BRANCH=${BASE_BRANCH:-integration}
COMPILE='npx tsc --noEmit'
BUILD='npm run build'
BASELINE_DIR=tools/lanes/baseline
TRACKED_OUTPUT=''          # tracked folders the checks regenerate, restored after the run (space-separated)
LEFTOVERS='\.received\.|-actual\.png$|-diff\.png$'   # snapshot output that means "not accepted"
discover_checks() {        # print one "name command..." line per check
  node -e 'const s=require("./package.json").scripts||{};for(const k of Object.keys(s))if(/^(lint|typecheck|test|test:.+|check:.+)$/.test(k)&&!/watch|dev|ui/.test(k))console.log(k.replace(/:/g,"-")+" npm run "+k)'
  # checks the branch added that no script runs yet
  git diff --name-only --diff-filter=A "$BASE_BRANCH"...HEAD -- 'tools/qa/*-check.*' | while read -r f; do
    grep -q "$f" package.json || echo "$(basename "$f" | sed 's/\..*//') npx tsx $f"
  done
}
check_deps() { :; }        # e.g. fail if the dependency install doesn't match the lock file
teardown() { :; }          # e.g. dotnet build-server shutdown; docker compose -p "$COMPOSE_PROJECT_NAME" down -v
# ===== end STACK =====

# 1. Refuse a half-finished rebase, merge or cherry-pick.
gp() { [ -e "$(git rev-parse --git-path "$1")" ]; }
if gp rebase-merge || gp rebase-apply || gp MERGE_HEAD || gp CHERRY_PICK_HEAD || git diff --name-only --diff-filter=U | grep -q .; then
  echo "GATE REFUSED: a rebase, merge or cherry-pick is in progress in $root"; exit 2
fi
if git grep --untracked -qE '^(<<<<<<<|>>>>>>>)( |$)' -- . 2>/dev/null; then
  echo "GATE REFUSED: conflict markers in:"; git grep --untracked -lE '^(<<<<<<<|>>>>>>>)( |$)' -- . | head -5; exit 2
fi
if [ -n "${REQUIRE_BASE:-}" ] && ! git merge-base --is-ancestor "$REQUIRE_BASE" HEAD; then
  echo "GATE REFUSED: HEAD does not contain $REQUIRE_BASE; rebase first"; exit 2
fi

# 2. Per-gate port and environment. An explicit LANE_PORT wins over .lane.env; nothing falls back to a shared default.
port_override=${LANE_PORT:-}
[ -f .lane.env ] && . ./.lane.env
[ -n "$port_override" ] && LANE_PORT=$port_override
[ -n "${LANE_PORT:-}" ] || { echo "GATE REFUSED: LANE_PORT is not set"; exit 2; }
export LANE_PORT CI=1
trap teardown EXIT

OUT="$root/tools/lanes/out/integration"     # must be gitignored
rm -rf "$OUT" && mkdir -p "$OUT"
fail=0
run() { name=$1; shift
  if "$@" > "$OUT/$name.log" 2>&1 < /dev/null; then echo "pass  $name" | tee -a "$OUT/summary.txt"
  else echo "FAIL  $name" | tee -a "$OUT/summary.txt"; tail -15 "$OUT/$name.log" | sed 's/^/      /'; fail=1; fi; }

# 3. Snapshot the tree. Lanes gate uncommitted work, so the tree must end as it started (not clean).
state() { git status --porcelain --untracked-files=no; git diff | git hash-object --stdin; }
before=$(state)
git status --porcelain --untracked-files=all | grep '^??' | sort > "$OUT/untracked-before.txt"
[ -n "$TRACKED_OUTPUT" ] && git diff --binary --output="$OUT/tracked-output-start.patch" -- $TRACKED_OUTPUT

# 4. Every check.
run deps check_deps
run compile sh -c "$COMPILE"
discover_checks > "$OUT/checks.txt"
while read -r name cmd; do [ -n "$name" ] && run "$name" sh -c "$cmd"; done < "$OUT/checks.txt"
run baseline env BASELINE_OUT="$OUT/baseline" sh tools/lanes/capture-baseline.sh
run baseline-diff git diff --no-index --exit-code -- "$BASELINE_DIR" "$OUT/baseline"
run build sh -c "$BUILD"
run no-leftovers sh -c "! git status --porcelain --untracked-files=all | grep -E '$LEFTOVERS'"

# 5. Restore tracked output the checks regenerated, then compare.
if [ -n "$TRACKED_OUTPUT" ]; then
  git checkout -- $TRACKED_OUTPUT 2>/dev/null
  [ -s "$OUT/tracked-output-start.patch" ] && git apply --binary "$OUT/tracked-output-start.patch"
fi
after=$(state)
[ "$before" = "$after" ] || { git status --short > "$OUT/tree-after.txt"; echo "FAIL  tree changed by the gate (see tree-after.txt)"; fail=1; }
git status --porcelain --untracked-files=all | grep '^??' | sort > "$OUT/untracked-after.txt"
comm -13 "$OUT/untracked-before.txt" "$OUT/untracked-after.txt" > "$OUT/untracked-new.txt"
[ -s "$OUT/untracked-new.txt" ] && { echo "FAIL  the gate left untracked files (gitignore their folder):"; sed 's/^/      /' "$OUT/untracked-new.txt"; fail=1; }

[ $fail = 0 ] && echo "GATE PASS" || echo "GATE FAIL"; exit $fail
```

Notes:
- `run` reads stdin from `/dev/null`, so a check cannot consume the check list.
- `git diff --no-index` works the same on every OS. Plain `diff -r` is fine on macOS and Linux.
- The gate runs checks serially. That keeps the load predictable when several lanes gate at once. If the gate is too slow, run the slow and independent captures in the background inside `capture-baseline.sh`, not here.

### 4.2 PowerShell 7 (`tools/lanes/integration-gate.ps1`)

```powershell
# Integration gate (PowerShell 7+): same contract as integration-gate.sh. Run: $env:LANE_PORT=5301; pwsh tools/lanes/integration-gate.ps1 <worktree>   (exit 0 pass, 1 fail, 2 refused)
param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false   # native exit codes are checked explicitly below
Set-Location $Root

# ===== STACK: fill in once (section 8) =====
$BaseBranch    = if ($env:BASE_BRANCH) { $env:BASE_BRANCH } else { 'integration' }
$Compile       = { dotnet build -c Release -warnaserror -nodeReuse:false }
$Build         = { dotnet publish src/Api/Api.csproj -c Release -o tools/lanes/out/publish --no-restore }
$BaselineDir   = 'tools/lanes/baseline'
$TrackedOutput = @()        # tracked folders the checks regenerate
$Leftovers     = '\.received\.|-actual\.png$|-diff\.png$'
function Get-Checks {       # returns @{ Name; Cmd } entries
  Get-ChildItem -Recurse -Filter '*Tests.csproj' | Where-Object { $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | ForEach-Object {
    $p = $_.FullName; $n = $_.BaseName
    @{ Name = "test-$n"; Cmd = [scriptblock]::Create("dotnet test `"$p`" -c Release --no-build --logger `"trx;LogFileName=$n.trx`" --results-directory `"$Out/tests`"") }
  }
}
function Invoke-Teardown { dotnet build-server shutdown | Out-Null }
# ===== end STACK =====

function Test-GitPath($p) { Test-Path (git rev-parse --git-path $p) }
if ((Test-GitPath 'rebase-merge') -or (Test-GitPath 'rebase-apply') -or (Test-GitPath 'MERGE_HEAD') -or (Test-GitPath 'CHERRY_PICK_HEAD') -or (git diff --name-only --diff-filter=U)) {
  Write-Host "GATE REFUSED: a rebase, merge or cherry-pick is in progress in $Root"; exit 2
}
$markers = git grep --untracked -lE '^(<<<<<<<|>>>>>>>)( |$)' -- .
if ($markers) { Write-Host "GATE REFUSED: conflict markers in: $($markers | Select-Object -First 5)"; exit 2 }
if ($env:REQUIRE_BASE) { git merge-base --is-ancestor $env:REQUIRE_BASE HEAD; if ($LASTEXITCODE -ne 0) { Write-Host "GATE REFUSED: HEAD does not contain $($env:REQUIRE_BASE)"; exit 2 } }

$portOverride = $env:LANE_PORT
if (Test-Path .lane.env) { foreach ($line in Get-Content .lane.env) { if ($line -match '^\s*([A-Za-z_]+)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } } }
if ($portOverride) { $env:LANE_PORT = $portOverride }
if (-not $env:LANE_PORT) { Write-Host 'GATE REFUSED: LANE_PORT is not set'; exit 2 }
$env:CI = '1'; $env:DiffEngine_Disabled = 'true'

$Out = Join-Path $Root 'tools/lanes/out/integration'
Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $Out | Out-Null
$script:fail = 0
function Invoke-Check([string]$Name, [scriptblock]$Cmd) {
  $log = Join-Path $Out "$Name.log"
  $global:LASTEXITCODE = 0
  try { & $Cmd *> $log; $ok = ($LASTEXITCODE -eq 0) } catch { "$_" | Out-File -Append $log; $ok = $false }
  if ($ok) { "pass  $Name" | Tee-Object -Append (Join-Path $Out 'summary.txt') }
  else { "FAIL  $Name" | Tee-Object -Append (Join-Path $Out 'summary.txt'); Get-Content $log -Tail 15 | ForEach-Object { "      $_" }; $script:fail = 1 }
}
function Get-TreeState { ((git status --porcelain --untracked-files=no) -join "`n") + "`n" + (git diff | git hash-object --stdin) }
function Get-Untracked { @(git status --porcelain --untracked-files=all | Where-Object { $_ -like '`?`?*' }) }

try {
  $before = Get-TreeState; $untrackedBefore = Get-Untracked
  $patch = Join-Path $Out 'tracked-output-start.patch'
  if ($TrackedOutput) { git diff --binary --output=$patch -- @TrackedOutput }

  Invoke-Check compile $Compile
  foreach ($c in Get-Checks) { Invoke-Check $c.Name $c.Cmd }
  Invoke-Check baseline { $env:BASELINE_OUT = "$Out/baseline"; pwsh tools/lanes/capture-baseline.ps1 }
  Invoke-Check baseline-diff { git diff --no-index --exit-code -- $BaselineDir "$Out/baseline" }
  Invoke-Check build $Build
  Invoke-Check no-leftovers { $l = git status --porcelain --untracked-files=all | Select-String $Leftovers; if ($l) { $l; $global:LASTEXITCODE = 1 } }

  if ($TrackedOutput) {
    git checkout -- @TrackedOutput 2>$null
    if ((Test-Path $patch) -and (Get-Item $patch).Length -gt 0) { git apply --binary $patch }
  }
  if ((Get-TreeState) -ne $before) { git status --short > (Join-Path $Out 'tree-after.txt'); 'FAIL  tree changed by the gate'; $script:fail = 1 }
  $new = Get-Untracked | Where-Object { $_ -notin $untrackedBefore }
  if ($new) { 'FAIL  the gate left untracked files (gitignore their folder):'; $new | ForEach-Object { "      $_" }; $script:fail = 1 }
} finally { Invoke-Teardown }

if ($script:fail -eq 0) { 'GATE PASS' } else { 'GATE FAIL' }
exit $script:fail
```

Run native GUI-subsystem tools such as `Unity.exe` through `Start-Process -Wait -PassThru` (section 8.1). Otherwise PowerShell returns before they finish.

### 4.3 Baseline capture (`tools/lanes/capture-baseline.sh`)

The baseline is a frozen picture of existing behaviour. New work must leave it unchanged. Every output must be deterministic text: seeded, sorted, rounded, with no timestamps, absolute paths, ports or GUIDs.

```sh
#!/bin/sh
# Captures deterministic text fingerprints of existing behaviour, one file per command, for the gate to diff against tools/lanes/baseline. Run: BASELINE_OUT=<dir> sh tools/lanes/capture-baseline.sh
set -u
OUT=${BASELINE_OUT:?set BASELINE_OUT}
rm -rf "$OUT" && mkdir -p "$OUT"
cap() { name=$1; shift; { "$@"; echo "exit=$?"; } > "$OUT/$name.txt" 2>&1 < /dev/null; }
# ===== STACK: one cap line per fingerprint (section 8). Slow ones in the background, then wait. =====
cap api-contract  sh -c 'cat tools/lanes/out/openapi.json'          # example: generated by the build
cap seeded-sim-42 sh -c 'dotnet run --project tools/Sim -- --seed 42 --ticks 10000' &
cap scene-dump    sh -c 'echo replace me'
wait
```

The `exit=` line is part of the record, so a command that starts failing shows up in the diff.

Pick fingerprints that cover what reviewers cannot see: modes nobody tests by hand, generated data, serialized assets, API shapes. In the project this came from, they were seeded headless runs of the old campaign and the tower mode, level fingerprints, boss fights, traversal margins and a terrain check.

**Accepting a baseline change.** Only the orchestrator does this, after a decision card or a spec that explicitly changes existing behaviour. It goes in its own commit, `Accept baseline: <why>`, and the diff is quoted in the commit body.

---

## 5. The orchestrator's integration recipe

Integrate one lane at a time. Take a lock so that two integrations never interleave:

```sh
LOCK="$(git rev-parse --git-common-dir)/lane-integrate.lock"
mkdir "$LOCK" || { echo "another integration is running"; exit 1; }
# ... recipe ...
rmdir "$LOCK"
```

Set the variables once: `L=<lane>; WT=.worktrees/$L; INT=.worktrees/integration`.

1. **Read the lane's commits before anything else.**
   ```sh
   git -C $WT log --stat integration..HEAD
   git -C $WT show <hash>          # for each commit
   ```
   - Check each commit body against its diff. Correct any claim the diff doesn't support before the commit lands on `integration`:
     - On the tip: `git -C $WT commit --amend -F /abs/msg.txt`.
     - On an older commit, during the step 2 rebase: `git -C $WT rebase integration --exec 'git log -1 --format=%s | grep -qxF "<subject>" && git commit --amend -F /abs/msg.txt || true'`.
   - Check `--stat` for evidence bloat, gate scratch files, copies of source and symlinks.
2. **Rebase the lane onto `integration`**, as a command on its own:
   ```sh
   git -C $WT rebase integration
   echo "exit=$?"
   ```
   **On conflict:**
   - List the conflicted files: `git -C $WT diff --name-only --diff-filter=U`.
   - Resolve each file. Then confirm it has no markers: `grep -nE '^(<<<<<<<|=======|>>>>>>>)( |$)' <file>` must print nothing.
   - Confirm it compiles: run the stack's compile command.
   - Only then run `git -C $WT add <file>`, one file at a time.
   - Continue as its own command: `GIT_EDITOR=true git -C $WT rebase --continue`, then check its exit code.
   - Never write `git add -A; git rebase --continue; sh gate.sh`. A `;` chain hides a paused rebase, and the gate then runs on a half-rebased tree.
   - **Shared table docs** (runbook rows, changelogs, registries): merge row by row against the base. A row only the lane added gets appended. A row the integration branch removed stays removed unless the lane changed it, and then you merge it by hand. If both sides changed the same row, merge it by hand. Afterwards, check for duplicate rows. Better still, design these docs as one file per entry, or as a generated index.
   - **A failing test after the rebase:** decide whether the code or the expectation is stale, citing the spec or the routing table. Don't just make it pass.
   - **Alternative to rebasing:** cherry-pick the lane's commits onto `integration`. Use it when you want only some commits, or when the lane is still running (see "pull ahead" below). `git -C $INT cherry-pick <hash>`, one at a time, with the same conflict rules.
3. **Run the integration gate on the rebased tree**, with a port no running lane uses:
   ```sh
   LANE_PORT=5399 REQUIRE_BASE=integration sh tools/lanes/integration-gate.sh "$PWD/$WT"
   ```
   - A lane's gate proves the lane works alone. Only this run proves it works with everything else.
   - **Reusing an earlier gate result:** allowed only if the commits between the gated base and the current tip touch nothing but allow-listed docs and logs. Check with `git diff --name-only <gated-base>..integration` before you skip a rerun.
4. **Read the screenshots.** Open every shot in the lane's evidence folders, and the gate's shots from the rebased tree, and compare each one with its caption and the spec. A missing, blank or wrong shot blocks the merge. Visual defects that don't block become board cards.
5. **Fast-forward** the integration branch:
   ```sh
   git -C $INT merge --ff-only lane/$L
   ```
   If this fails, the integration branch moved during the gate. Go back to step 2.
6. **Push**: `git -C $INT push origin integration`.
7. **Board, gallery and log, in this same turn:**
   - Board: move the cards to `done`, and put the hashes, the gate result and any known issues in `note`.
   - Gallery: edit the section (`status: "merged"`, `commit`, shot paths repointed to `integration/...`), rebuild it and republish it to the same URL.
   - Log: write a timestamped entry.
   - Commit `gallery.json` and the log on `integration` and push them.
8. **Clean up the worktree:**
   - Stop the lane's processes: dev servers, Unity, MSBuild nodes, containers (`docker compose -p lane_$L down -v`).
   - Check that `git -C $WT status --porcelain` is empty. If it isn't, find out what the leftovers are before deleting anything.
   - Remove the worktree and branch:
     ```sh
     git worktree remove $WT
     git -C $INT branch -d lane/$L
     git push origin --delete lane/$L
     ```
     Delete the remote branch only after the gallery no longer points into the worktree.
   - Release the lock.

### Standing habits

- **Keep the board current in the same turn.** Move a card when its work starts, is queued, is committed (with the hash), is merged or is decided. Do it before you report progress.
- **Verify lane commit messages against the diff** before merging. Every named behaviour, file or symbol must be in `git show`.
- **One port per lane and per gate.** Assign ports from a reserved range, record them in `.lane.env`, the args file and the log, and never reuse a port while its owner is alive. The integration gate uses its own port.
- **Pull dependent commits ahead by cherry-pick** when it unblocks other work.
  - Gate the picked commits like any merge.
  - Log `picked ahead: <hashes>` on the card and in the log.
  - Tell the lane to rebase onto the new base promptly.
  - Afterwards, `git cherry integration lane/<name>` should show the picked commits as `-`, meaning equivalent.
  - Never edit the picked copies differently from the lane's commits.
- **Assume a conflict when two lanes touch the same concept**, such as a resource lifecycle, a pricing or scoring term, a shared asset's owner or a routing table. Plan lanes so they own disjoint files: scenes and prefabs on Unity, migrations on .NET, route and registry files on React.
- **Cap parallel lanes** at the stack's budget (section 8). If a check flakes under load more than once, lower the cap or fix the check.
- **Run `review.js`** over the merge range after every few merges. Confirmed findings become cards and lanes.

---

## 6. The board

The board is a claude.ai Artifact page that keeps its data in the Artifact database, so everyone who opens it sees the same live state. The orchestrator writes to it with the `ArtifactData` tool, and never by republishing the page.

### 6.1 Collections and schema

**`cards`**: doc_id = card id.

```json
{
  "id": "AUTH.1", "title": "Session model", "kind": "eng", "phase": 1, "order": 10,
  "epic": "AUTH", "slice": "VS1", "priority": "P0", "effort": "M", "status": "backlog",
  "summary": "what and why", "acceptance": "how we know it is done",
  "deps": ["D01"], "refs": ["docs/design/auth.md"], "area": null,
  "note": "", "decision": "", "source": "roadmap.csv"
}
```

| Field | Values |
|---|---|
| `kind` | `decision`, `eng`, `content`, `design`, `art`, `qa`, `ops` (adapt per project) |
| `status` | `decide`, `backlog`, `ready`, `doing`, `review`, `done` |
| `priority` | `P0` to `P3` |
| `effort` | `S`, `M`, `L` |
| `deps` | card ids that must be `done` first |
| `refs` | other card ids, doc paths or file paths |
| `note` | a running, dated log (6.4) |
| `decision` | for decision cards: provisional or final text |
| `source` | where the card came from: a CSV, a doc, "chat", "review" |

**`epics`**: work packages grouped by system or owner, e.g. `{"id":"AUTH","title":"...","phase":"1","priority":"P0","owner":"...","deps":[],"scope":"...","acceptance":"..."}`.

**`slices`**: vertical, demoable increments. `{"id":"VS1","name":"Sign in and see your dashboard","goal":"one-sentence demoable outcome","order":1,"cards":["AUTH.1","AUTH.2","DASH.1"]}`. Each card points back with `slice`.

People refer to work by card id ("AUTH.1") or slice ("VS1").

### 6.2 Statuses

| Status | Meaning | Who moves it |
|---|---|---|
| `decide` | an open question for the human (decision cards only) | orchestrator files it; human decides |
| `backlog` | known, not ready (deps open or not specced) | |
| `ready` | deps done, spec written, queued for a lane | orchestrator |
| `doing` | a lane's workflow is running it | orchestrator, at launch |
| `review` | committed on a lane and being gated or integrated | orchestrator, when the lane commits |
| `done` | merged to the integration branch; `note` has the hash | orchestrator, in the merge turn |

### 6.3 The page (`tools/board/board.html`)

Load the `artifact-capabilities` skill for the exact runtime API, and `artifact-design` for the page contract. The page needs:

- **Data:** the `db` capability, with live listeners on `cards`, `epics` and `slices`, so every viewer sees each write at once. In the project this came from, that was `window.claude.use("db")` with `onSnapshot` per collection.
- **Columns:** six, in status order. Cards are sorted by `phase`, then `order`.
- **Editing:**
  - Drag a card between columns, or use a status menu in a side drawer. Either one writes `update({status})`.
  - The drawer also edits `note` and `decision`.
- **Permissions:** a viewer without write permission gets a read-only board. A rejected write also switches the page to read-only.
- **Derived views:**
  - Totals: Decisions open (`decide`), Unblocked (all `deps` done), In flight (`doing` + `review`), and Done/total.
  - A phase strip.
  - Per card, "Waiting on N" or "Deps clear", and an "Unblocks" list (the reverse of `deps`).
- **Filters:** phase, slice, kind, epic, text search and "unblocked only", kept in `localStorage` wrapped in try/catch. The page must also work without storage.
- **Missing database:** a banner when no database is available, e.g. when the page is opened outside claude.ai.
- **Mobile:** columns stack, and the drawer is full width.

### 6.4 Creating and seeding

1. Write the seed documents as JSON files: `tools/board/seed/cards/<id>.json`, and the same for `epics` and `slices`. Generate them with a small script from your roadmap CSV or doc, e.g. `tools/board/build-seed.mjs`.
2. Publish the page with the `db` capability and an `icon`, then put the URL in the runbook.
3. Seed it with `ArtifactData` batches of `set` operations that point at the files. Split the seed across several batches, because the person approves each batch once.
   ```json
   [{"op":"set","collection":"cards","doc_id":"AUTH.1","file_path":"/abs/repo/tools/board/seed/cards/AUTH.1.json"},
    {"op":"set","collection":"slices","doc_id":"VS1","file_path":"/abs/repo/tools/board/seed/slices/VS1.json"}]
   ```
4. **Updates:** `get` or `query` the card first, then `update` with `if_version`, so a write fails instead of overwriting a change someone made in the page:
   ```json
   {"op":"update","collection":"cards","doc_id":"AUTH.1","if_version":3,"data":{"status":"done","note":"..."}}
   ```
   On a version conflict, re-read, merge and write again. Use one `batch` for more than two writes.

### 6.5 Notes with hashes

`note` is a running log, newest last, one line per event:

```
2026-10-08 01:12 doing: lane auth (lane/auth, port 5301), steps auth-1..auth-3
2026-10-08 03:40 review: auth-1 3f2a9c1, auth-2 8d0e441 committed on lane/auth
2026-10-08 04:05 done: merged 3f2a9c1..b71c0de into integration; integration gate PASS (14 checks, baseline empty); shots read
2026-10-08 04:05 known: phone login button overlaps footer at 320px (card UI07)
```

### 6.6 Decision cards with provisional defaults

Every open question for the human becomes a card:

```json
{"id":"D12","kind":"decision","status":"decide","title":"Session length for remember-me",
 "summary":"Options: (a) 7 days (b) 30 days (c) until logout. Recommended: (b), matches the web app.",
 "decision":"Provisional default 2026-10-08: (b) 30 days (<human> to confirm)",
 "refs":["AUTH.2"],"deps":[],"phase":1,"order":5,"priority":"P1","effort":"S","note":""}
```

- Work goes ahead on the provisional default, and it is noted in the dependent cards and commit bodies.
- If the human overrules a default, the affected work is redone, and the card links it.
- When the human decides, the `decision` field gets the final text: what was decided, who decided and when. The card then moves to `done`.
- Lane reports containing `PROVISIONAL:` or `DECISION NEEDED:` lines become decision cards in the same turn.

### 6.7 Audit pass

Run an audit at the start of each session and every few hours when unattended:

- A card in `doing` or `review` with no running workflow and no lane branch: reconcile it against `git log` and the running tasks, then move it.
- A card in `done` with no hash in `note`: find the commit (`git log --grep '<id>' integration`) and add it.
- A card whose `deps` are all done but which is still in `backlog`: move it to `ready`, or note why not.
- Decisions recorded only in chat: file them as cards.
- Refuted-for-now review findings: re-check them when their blocking work merges.

---

## 7. The gallery

The gallery is a static Artifact page of screenshots, one section per lane or feature. It is the human's main way to see progress, often from a phone. A shot nobody looked at is a false claim of progress, so the orchestrator reads every image before listing it.

### 7.1 What to capture per stack

| Stack | Shots |
|---|---|
| React web app | Playwright `page.screenshot` per route and state at desktop 1440x900 and phone 390x844; Storybook stories for components; on failure the `*-actual.png` / `*-diff.png` pair |
| Unity | Camera rendered to a fixed-size RenderTexture from a PlayMode test or editor script (batchmode without `-nographics`); key scenes and states; editor captures for tools and inspectors |
| .NET service | No UI, so render evidence to PNG with Playwright: the OpenAPI diff (oasdiff HTML), the Scalar/Swagger UI page, the test and coverage reports (TRX to HTML, ReportGenerator), a generated `out/report.html` of endpoints, status codes and timings, benchmark charts, any admin or health page |

Fixed viewports, seeded data, animations off and a fixed timezone and locale make shots comparable between runs.

### 7.2 `tools/gallery/gallery.json`

```json
{
  "title": "Project screenshots",
  "intro": "Captured by each lane's gate at fixed viewports (desktop 1440x900, phone 390x844) unless noted. Merged: on the integration branch. On a lane: committed and reviewed on a lane branch, not merged yet.",
  "shotRoot": "../../..",
  "integration": "integration",
  "sections": [
    {
      "id": "login",
      "chip": "Login",
      "title": "Login and session restore (AUTH.1, AUTH.2, VS1)",
      "status": "merged",
      "commit": "3f2a9c1..b71c0de",
      "cards": ["AUTH.1", "AUTH.2"],
      "about": "What it shows, what is placeholder, known issues with card ids (e.g. 'phone footer overlap, board UI07').",
      "shots": [
        ["integration/tools/lanes/evidence/auth/auth-2-login-ui/shots/login-desktop.png", "Login, desktop", "wide"],
        ["integration/tools/lanes/evidence/auth/auth-2-login-ui/shots/login-phone.png", "Login, phone", "phone"]
      ]
    }
  ]
}
```

- **`shotRoot`:** relative to `tools/gallery/`, and resolves to the `.worktrees/` folder. Shot paths start with a worktree name, so a section can list a lane's shots before the lane merges.
- **Shot kinds:** `shot` (the default), `wide`, `map`, `phone`, `diff` and `report`. Render `diff` and `report` sources to PNG before listing them.
- **`status`:**
  - `lane`: shots may point into the lane's worktree.
  - `merged`: shots must point at committed paths under the integration worktree. The builder enforces this, because lane worktrees are deleted after a merge.

### 7.3 `tools/gallery/build-gallery.mjs`

```js
// Builds the screenshot gallery from gallery.json: resized JPEGs in out/img/, out/index.html, and out/publish-files.json (the Artifact files map). Run: node tools/gallery/build-gallery.mjs   (once: npm install --prefix tools/gallery)
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import sharp from 'sharp'

const here = dirname(fileURLToPath(import.meta.url))
const g = JSON.parse(readFileSync(join(here, 'gallery.json'), 'utf8'))
const shotRoot = resolve(here, g.shotRoot ?? '../../..')
const out = join(here, 'out')
rmSync(join(out, 'img'), { recursive: true, force: true })
mkdirSync(join(out, 'img'), { recursive: true })

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c])
const missing = [], errors = [], files = {}, chips = [], sections = []
let count = 0

for (const s of g.sections) {
  const figs = []
  for (const [i, [src, caption, kind = 'shot']] of s.shots.entries()) {
    if (s.status === 'merged' && !src.startsWith(`${g.integration}/`)) errors.push(`${s.id}: merged section points into a lane worktree: ${src}`)
    const abs = join(shotRoot, src)
    if (!existsSync(abs)) { missing.push(`${s.id}: ${src}`); continue }
    const name = `img/${s.id}-${i + 1}.jpg`
    const long = kind === 'wide' || kind === 'map' ? 2000 : 1600
    const info = await sharp(abs).resize(long, long, { fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 72 }).toFile(join(out, name))
    files[name] = join(out, name)
    // width/height stop lazy images from shifting the page, so section links land in the right place
    figs.push(`<figure class="${esc(kind)}"><img src="${name}" width="${info.width}" height="${info.height}" loading="lazy" alt="${esc(caption)}"><figcaption>${esc(caption)}</figcaption></figure>`)
    count++
  }
  const lane = s.status !== 'merged'
  chips.push(`<a href="#${esc(s.id)}"${lane ? ' class="lane"' : ''}>${esc(s.chip ?? s.id)}</a>`)
  sections.push(`<section id="${esc(s.id)}"><h2>${esc(s.title)}</h2>
<p class="meta"><span class="pill${lane ? ' lane' : ''}">${lane ? 'On a lane' : 'Merged'}</span> <code>${esc(s.commit)}</code>${s.cards?.length ? ` · cards ${esc(s.cards.join(', '))}` : ''}</p>
<p>${esc(s.about)}</p><div class="grid">${figs.join('')}</div></section>`)
}

if (errors.length) { console.error(errors.join('\n')); process.exit(1) }

const page = `<title>${esc(g.title)}</title>
<style>
:root{--bg:#fafaf9;--fg:#1c1917;--muted:#57534e;--card:#fff;--line:#e7e5e4;--ok:#15803d;--lane:#b45309}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0c0a09;--fg:#f5f5f4;--muted:#a8a29e;--card:#1c1917;--line:#292524;--ok:#4ade80;--lane:#fbbf24}}
:root[data-theme="dark"]{--bg:#0c0a09;--fg:#f5f5f4;--muted:#a8a29e;--card:#1c1917;--line:#292524;--ok:#4ade80;--lane:#fbbf24}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}
nav{position:sticky;top:0;z-index:2;background:var(--bg);border-bottom:1px solid var(--line);padding:8px 16px}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chips a{border:1px solid var(--line);border-radius:999px;padding:2px 10px;color:var(--fg);text-decoration:none;font-size:13px}
.chips a.lane{border-style:dashed}
nav button{display:none;width:100%;justify-content:space-between;gap:8px;background:none;border:0;color:var(--fg);font:inherit;padding:6px 0}
#here{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
main{max-width:1200px;margin:0 auto;padding:0 16px 48px}
section{scroll-margin-top:72px;border-top:1px solid var(--line);padding-top:8px}
.meta{color:var(--muted);font-size:13px}
.pill{border:1px solid var(--ok);color:var(--ok);border-radius:999px;padding:0 8px}
.pill.lane{border:1px dashed var(--lane);color:var(--lane)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,360px),1fr));gap:12px}
figure{margin:0;background:var(--card);border:1px solid var(--line);border-radius:8px;overflow:hidden}
figure.wide,figure.map{grid-column:1/-1}
figure img{display:block;width:100%;height:auto;cursor:zoom-in}
figure.phone img{width:auto;max-width:100%;max-height:420px;margin:0 auto}
figcaption{padding:8px 10px;font-size:13px;color:var(--muted)}
dialog{padding:0;border:0;background:transparent;max-width:96vw;max-height:96vh}
dialog img{display:block;max-width:96vw;max-height:92vh;width:auto;height:auto}
dialog::backdrop{background:rgb(0 0 0/.8)}
@media (max-width:700px){nav button{display:flex}.chips{display:none}nav.open .chips{display:flex;max-height:60vh;overflow:auto;padding-top:8px}}
</style>
<nav id="nav"><button type="button" aria-expanded="false" aria-controls="chips"><span>Sections</span><span id="here"></span></button><div class="chips" id="chips">${chips.join('')}</div></nav>
<main><h1>${esc(g.title)}</h1><p>${esc(g.intro)}</p>
${sections.join('\n')}
<footer class="meta">${count} shots</footer></main>
<dialog id="zoom"><img alt=""></dialog>
<script>
const nav = document.getElementById('nav'), btn = nav.querySelector('button'), here = document.getElementById('here')
const setOpen = (o) => { nav.classList.toggle('open', o); btn.setAttribute('aria-expanded', String(o)) }
btn.onclick = () => setOpen(!nav.classList.contains('open'))
nav.querySelectorAll('.chips a').forEach((a) => { a.onclick = () => setOpen(false) })
const io = new IntersectionObserver((es) => { for (const e of es) if (e.isIntersecting) here.textContent = e.target.querySelector('h2').textContent }, { rootMargin: '-20% 0px -70% 0px' })
document.querySelectorAll('section').forEach((s) => io.observe(s))
const dlg = document.getElementById('zoom'), big = dlg.querySelector('img')
document.querySelectorAll('figure img').forEach((i) => { i.onclick = () => { big.src = i.src; big.alt = i.alt; dlg.showModal() } })
dlg.onclick = () => dlg.close()
</script>`

writeFileSync(join(out, 'index.html'), page)
writeFileSync(join(out, 'publish-files.json'), JSON.stringify(files, null, 2))
if (missing.length) console.log(`missing (skipped):\n  ${missing.join('\n  ')}`)
console.log(`${count} shots in ${g.sections.length} sections -> ${join(out, 'index.html')}`)
```

- `sharp` works on macOS, Linux and Windows. If the project has no Node, port the builder to Python with Pillow (`Image.thumbnail((1600,1600))`, then `save(quality=72)`), or shell out to ImageMagick:
  ```sh
  magick in.png -resize '1600x1600>' -quality 72 out.jpg
  magick identify -format '%w %h' out.jpg
  ```
  On macOS, `sips -s format jpeg -s formatOptions 72 -Z 1600` also works.
- A missing shot never breaks the build. It is listed at the end.
- A `merged` section that points into a lane worktree does break the build.

### 7.4 Build and publish

After each merge, in the same turn:

1. Edit `gallery.json`. Add the section, or set its `status` to `merged`, set `commit` to the merged hashes, and repoint its shots to the `integration/` evidence paths.
2. Run `node tools/gallery/build-gallery.mjs`.
3. **Read every new or changed image** in `tools/gallery/out/img/`, and check each one against its caption. Reject:
   - blank or black frames
   - loading or title screens caught too early
   - the wrong state, user, room or route
   - debug overlays
   - text clipped or overlapping at phone width
4. Write the captions and `about` to say what is actually visible, including placeholders. Defects become board cards and are cited in `about`.
5. Publish with the Artifact tool:
   - `file_path` is `tools/gallery/out/index.html`.
   - `files` is the map in `out/publish-files.json`. The page references relative `img/...` paths.
   - Pass `icon` on the first publish only.
   - Republish from the same file path, so the URL stays the same.
   - Files left out of `files` stay on the server. When you remove a section, pass `null` for each of its old image paths.
6. Commit `gallery.json` on `integration`, e.g. `Gallery: auth lane merged`.

### 7.5 Checking the page itself

After you change the builder, screenshot the built page:

- at phone size (390x844, device scale factor 2) in three states: at the top, scrolled to a section, and with the nav open
- at desktop size (1440x900)

Use Playwright with `page.setViewportSize` and `page.screenshot`, and `page.evaluate` to return numbers: the nav height, whether the bar is shown, and whether the chips are expanded. Then read the images. The page has to work one-handed on a phone.

---

## 8. Stack adapters

Each adapter fills the STACK blocks in `lane.js`, `integration-gate.*`, `capture-baseline.*` and `new-lane.sh`.

### Concurrency budget

| Stack | Parallel lanes per workstation |
|---|---|
| Unity | 2 to 3 |
| .NET service with containers | about 4 |
| React web app | 4 to 6 |

Check free RAM before starting another lane.

### 8.1 Unity (2022.3 LTS, Unity 6)

| Slot | Command |
|---|---|
| Editor path | read the version from `ProjectSettings/ProjectVersion.txt` (`m_EditorVersion`). macOS: `/Applications/Unity/Hub/Editor/<ver>/Unity.app/Contents/MacOS/Unity`. Windows: `C:\Program Files\Unity\Hub\Editor\<ver>\Editor\Unity.exe` |
| COMPILE | `"$UNITY" -batchmode -nographics -quit -projectPath "$P" -logFile tools/lanes/out/compile.log`, then fail on `grep -E 'error CS[0-9]+\|Scripts have compiler errors' tools/lanes/out/compile.log` |
| TEST (EditMode) | `"$UNITY" -batchmode -nographics -projectPath "$P" -runTests -testPlatform EditMode -testResults tools/lanes/out/editmode.xml -logFile tools/lanes/out/editmode.log`. **No `-quit`** with `-runTests`, because it can end the run early. Exit codes: 0 passed, 2 tests failed, 3 run failed. Treat the XML as the source of truth: `grep -q '<test-run[^>]*result="Passed"' tools/lanes/out/editmode.xml` |
| CHECKS | one entry each for EditMode and PlayMode, per assembly or category (`-assemblyNames`, `-testCategory "Gate"`), so the logs stay separate |
| BASELINE | (1) **sim baseline:** N seeded ticks headless, final state dumped as sorted text with floats as `ToString("F4", CultureInfo.InvariantCulture)`; (2) **scene and prefab dump:** an EditMode method that walks each gate scene and prefab and writes the GameObject path, component types and key serialized fields (rounded transforms) to text |
| BUILD | `-executeMethod GateBuild.BuildPlayer -quit -buildTarget StandaloneOSX\|StandaloneWindows64\|StandaloneLinux64` |
| SCREENSHOTS | a PlayMode test category `Shots`, run with `-batchmode` but **without `-nographics`**, writing PNGs to `$SHOTS_DIR` |
| PORT | usually none. If you run a netcode or dedicated server, take its port from `LANE_PORT` |

**Determinism**

- Seed every RNG: `UnityEngine.Random.InitState`, `Unity.Mathematics.Random` and `System.Random`.
- Fix time with `Time.captureDeltaTime`.
- Set `Physics.simulationMode = SimulationMode.Script`, then step with `Physics.Simulate(fixedDelta)`.

**Build method**

```csharp
// Assets/Editor/GateBuild.cs: gate build entry point; exits 1 unless the player build succeeds.
using System.Linq; using UnityEditor; using UnityEditor.Build.Reporting; using UnityEngine;
public static class GateBuild {
  public static void BuildPlayer() {
    var scenes = EditorBuildSettings.scenes.Where(s => s.enabled).Select(s => s.path).ToArray();
    var ext = EditorUserBuildSettings.activeBuildTarget == BuildTarget.StandaloneWindows64 ? ".exe" : EditorUserBuildSettings.activeBuildTarget == BuildTarget.StandaloneOSX ? ".app" : "";
    var report = BuildPipeline.BuildPlayer(new BuildPlayerOptions { scenes = scenes, locationPathName = "Build/Gate/Game" + ext, target = EditorUserBuildSettings.activeBuildTarget });
    Debug.Log($"GATE BUILD {report.summary.result} size={report.summary.totalSize} time={report.summary.totalTime}");
    EditorApplication.Exit(report.summary.result == BuildResult.Succeeded ? 0 : 1);
  }
}
```

**Screenshot helper.** Don't rely on `ScreenCapture.CaptureScreenshot` in batchmode. There may be no swapchain, and it writes at the end of the frame.

```csharp
// Renders a camera to a fixed-size texture and saves a PNG; used by the Shots PlayMode tests.
static void Capture(Camera cam, string name, int w = 1280, int h = 720) {
  var rt = new RenderTexture(w, h, 24); var prev = cam.targetTexture;
  cam.targetTexture = rt; cam.Render(); RenderTexture.active = rt;
  var tex = new Texture2D(w, h, TextureFormat.RGB24, false);
  tex.ReadPixels(new Rect(0, 0, w, h), 0, 0); tex.Apply();
  cam.targetTexture = prev; RenderTexture.active = null;
  var dir = System.Environment.GetEnvironmentVariable("SHOTS_DIR") ?? "tools/lanes/out/shots";
  System.IO.Directory.CreateDirectory(dir);
  System.IO.File.WriteAllBytes(System.IO.Path.Combine(dir, name + ".png"), tex.EncodeToPNG());
  Object.Destroy(tex); rt.Release();
}
```

- Overlay UI won't appear in the shot. Use Screen Space - Camera canvases in shot scenes.
- In gate scenes, turn off temporal effects: TAA, motion blur, film grain, auto-exposure and unseeded particles.
- For golden-image tests, `com.unity.testframework.graphics` `ImageAssert.AreEqual` keeps references per platform, graphics API and colour space. Pin one reference platform and keep a tolerance.

**Worktree setup**

- `Library/` is per project folder and several GB.
  - Never symlink or share it. Concurrent imports corrupt it.
  - Warm a new lane by copying the integration worktree's Library before the first open, if the editor version and `Packages/packages-lock.json` match. On macOS use `cp -cR` (APFS clone, nearly free). On Windows use `robocopy <src> <dst> /MIR /NFL /NDL`.
  - Or run a local Unity Accelerator so lanes share import results safely.
- LFS objects are shared through `.git/lfs`. Each `git worktree add` still smudges the files, so don't use `GIT_LFS_SKIP_SMUDGE` on Unity, because the assets are needed.
- Use Force Text serialization and visible meta files. Register UnityYAMLMerge (Smart Merge) as the merge tool for `.unity` and `.prefab` files.
- `.gitignore`: `Library/ Temp/ Logs/ obj/ UserSettings/ Build/ tools/lanes/out/`.

**Isolation**

- Only one editor or batchmode instance can run per project folder. Each lane is its own folder, so lanes run in parallel, and your open editor on the main checkout doesn't block them.
- Never gate a folder that has an editor open.
- Budget 2 to 6 GB of RAM per batchmode instance.

**Pitfalls**

- `-nographics` in a screenshot pass gives black frames.
- Text baselines break on a Windows locale unless floats use `InvariantCulture`.
- Two lanes creating the same asset path collide on `.meta` GUIDs. Plan lanes to own disjoint scenes, prefabs and folders.
- After a rebase that touched assets, rerun the full gate. A clean text merge is not enough.
- Licensing: named-user Personal or Pro seats generally allow several batchmode instances on your own machine. Check your plan before you run many unattended lanes. Build machines need a Build Server floating license.
- Windows: `Unity.exe` is a GUI-subsystem app, so in PowerShell use:
  ```powershell
  $p = Start-Process $unity -ArgumentList $args -Wait -PassThru
  $p.ExitCode
  ```
  `-logFile -` does not stream reliably. Log to a file.

### 8.2 .NET service

| Slot | Command |
|---|---|
| COMPILE | `dotnet build -c Release -warnaserror -nodeReuse:false` |
| TEST | `dotnet test --no-build -c Release --logger "trx;LogFileName=tests.trx" --results-directory tools/lanes/out/tests`; optionally add `--collect "XPlat Code Coverage"` plus ReportGenerator for HTML |
| CHECKS | one entry per `*Tests.csproj` (discovered, excluding `bin/` and `obj/`); `dotnet format --verify-no-changes`; `dotnet ef migrations has-pending-model-changes` (EF Core 8+) |
| BASELINE | (1) Verify snapshots: `*.verified.*` committed, with `DiffEngine_Disabled=true`, no auto-verify, `UseStrictJson`, and GUIDs, dates and ports scrubbed; the gate fails on any `*.received.*`; (2) OpenAPI contract: build-time generation or `/openapi/v1.json` from the test host, committed as `tools/lanes/baseline/openapi.json`, gated with `oasdiff breaking tools/lanes/baseline/openapi.json tools/lanes/out/openapi.json --fail-on ERR` plus a plain diff; gRPC uses `buf breaking`; (3) `dotnet ef migrations script --idempotent -o tools/lanes/out/migrate.sql` as evidence |
| BUILD | `dotnet publish src/<Api>/<Api>.csproj -c Release -o tools/lanes/out/publish --no-restore` |
| SCREENSHOTS | Playwright (`Microsoft.Playwright` or Node) captures the rendered OpenAPI diff, the Scalar or Swagger UI, the TRX and coverage HTML, and a generated `tools/lanes/out/report.html` (endpoints, status codes, timings, diff summary) |
| PORT | `ASPNETCORE_URLS=http://127.0.0.1:$LANE_PORT` for dev runs. `WebApplicationFactory` tests need no port. docker compose ports come from `.lane.env` |
| teardown | `dotnet build-server shutdown`; `docker compose -p "$COMPOSE_PROJECT_NAME" down -v` |

**Worktree setup**

- `bin/` and `obj/` are per worktree.
- The NuGet global packages folder is safe to share.
- In `new-lane.sh`, run `dotnet restore --locked-mode` with `packages.lock.json` committed. Lanes may restore, but must never change a package.

**Isolation**

- Testcontainers maps random host ports, and Ryuk cleans up, so lanes don't collide. Never use `WithReuse` across lanes.
- docker compose always runs with `-p <lane>` and `down -v` at the end. Without a project name, lanes share and kill each other's containers.
- Each lane uses its own database name (`DB_NAME` from `.lane.env`).

**Pitfalls**

- **Two lanes each adding an EF migration.** After the rebase, the `ModelSnapshot` conflicts or the order is wrong. Let one lane at a time own schema changes. If it happens anyway, delete and re-scaffold the later lane's migration after the rebase, then rerun the gate.
- MSBuild and Roslyn server processes hold file locks across worktrees, especially on Windows. Use `-nodeReuse:false` and `build-server shutdown`.
- Line endings: set `*.verified.* text eol=lf` and `tools/lanes/baseline/** text eol=lf` in `.gitattributes`, or CRLF breaks every baseline diff.

### 8.3 React web app

| Slot | Command |
|---|---|
| COMPILE | `tsc -b` or `tsc --noEmit`; `eslint . --max-warnings 0` |
| TEST | `vitest run --reporter=junit --outputFile=tools/lanes/out/vitest.xml` or `jest --ci`. With `CI=1` set by the gate, new snapshots are not written silently |
| CHECKS | every `package.json` script named `lint`, `typecheck`, `test`, `test:*` or `check:*`, excluding watch, dev and ui scripts (the gate's `discover_checks`); `playwright test` |
| BASELINE | Playwright `toHaveScreenshot` baselines (generated and compared on one pinned OS or the `mcr.microsoft.com/playwright:<version>` image); component snapshots; mocked API fixtures; a text dump of the route table and the public bundle entry names |
| BUILD | `vite build` or `next build`; record the bundle size in evidence |
| SCREENSHOTS | `e2e/shots.spec.ts` saving `page.screenshot({ path: \`${process.env.SHOTS_DIR}/<name>-<project>.png\`, fullPage: true })` for the desktop and phone projects |
| PORT | `vite --port $LANE_PORT --strictPort --host 127.0.0.1` or `next dev -p $LANE_PORT` |

**Playwright config**

```ts
// playwright.config.ts: one server per lane on LANE_PORT; never reuse another lane's server.
import { defineConfig, devices } from '@playwright/test'
const port = Number(process.env.LANE_PORT)
if (!port) throw new Error('LANE_PORT is not set')
export default defineConfig({
  use: { baseURL: `http://127.0.0.1:${port}`, timezoneId: 'UTC', locale: 'en-US' },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1440, height: 900 } } },
    { name: 'phone', use: { ...devices['iPhone 13'] } },
  ],
  webServer: { command: `npx vite --port ${port} --strictPort --host 127.0.0.1`, url: `http://127.0.0.1:${port}`, reuseExistingServer: false },
  expect: { toHaveScreenshot: { animations: 'disabled', maxDiffPixelRatio: 0.01 } },
})
```

**Worktree setup**

- Install per worktree. pnpm with `--frozen-lockfile` is fast because it hard-links from its store. Keep the store on the same volume as the worktrees, or pnpm falls back to copying.
- `npm ci` is slow but safe.
- If you must share `node_modules` between worktrees:
  - Link it to the **integration** worktree's install, never the main checkout's. The main checkout is on another branch, and its dependencies differ.
  - Forbid installs in lanes.
  - Expect Vite `server.fs.allow` errors, duplicate React and wrong tsconfig or eslint roots, because tools resolve the real path outside the project.
- Keep `.turbo`, `.nx` and `.next` per worktree.

**Pitfalls**

- `reuseExistingServer: true` on a shared port. A lane then silently tests another lane's server. This is the most important pitfall.
- Screenshot baselines carry an OS suffix (`-darwin`, `-linux`). Mac baselines fail on Linux. Generate and compare in one place.
- Never run `--update-snapshots` or `-u` in a lane. The gate fails on `*-actual.png` and `*-diff.png` leftovers.

### 8.4 Windows notes (all stacks)

- Use PowerShell 7 and `integration-gate.ps1`. Check `$LASTEXITCODE` after every native command.
- Set `git config core.longpaths true` and enable Win32 long paths. Keep worktrees short (`C:\w\<lane>`), because `Library` and `node_modules` paths exceed 260 characters.
- In `.gitattributes`, mark baselines `text eol=lf` and golden PNGs `binary`.
- `git worktree remove` fails while a process holds files (Unity, MSBuild nodes, dev servers, Defender). Stop the lane's processes first, then `git worktree remove --force` and `git worktree prune`.
- Exclude the worktree root, `Library`, `node_modules` and the NuGet cache from Defender real-time scanning.
- Symlinks need Developer Mode, which is one more reason not to share folders by link.
- Bind servers to `127.0.0.1`, so the firewall doesn't prompt.

---

## 9. Running unattended overnight

You start an unattended run by telling the orchestrator, e.g. "bedtime, full auto until 8". From then on:

- **No blocking questions.** Every question becomes a decision card (section 6.6) with options and a recommended default. Work goes ahead on the provisional default, which is marked in the dependent cards and commit bodies. If you overrule it, the work is redone.
- **Hard limits still hold.** No releases, tags, publishes, deploy dispatches or merges to `main`. No force-push to `integration`. No deleting scripts or unmerged branches.
- **Always keep one background job running.** A finishing workflow is what wakes the session. When a lane finishes, integrate it, then launch the next unblocked lane straight away.
  - If nothing can run, schedule a check-in (e.g. `/loop` or a cron task). Use it to run the audit (6.7) and `review.js`, and to look for new unblocked cards.
- **Log everything** in `tools/lanes/log/overnight-<date>.md`, timestamped from the shell (`date +%H:%M`, since Workflow scripts cannot read the clock). Commit and push the log with each integration.
- **Before a known interruption** (a usage-limit reset, a reboot), write resume details for every running job to the log.
- **Resuming after a usage limit:**
  - For each interrupted lane, relaunch it with `Workflow({ scriptPath: 'tools/lanes/lane.js', args: <tools/lanes/args/<lane>.json>, resumeFromRunId: '<runId>' })`.
  - Finished agents replay from the cache. If you appended steps to the args file, the old steps replay and only the new ones run live.
  - Then run the audit, because cards may have drifted while the session was down.
- **Flakes.** A failure counts as a flake only if that one check, rerun alone on the same tree, passes. Log every flake with the machine load. If the same check flakes twice, lower the lane cap or open a card to fix the check.
- **Morning summary**, at the top of the log and in chat:
  - what merged, with hashes
  - what is blocked and why
  - the decisions made provisionally
  - a "Needs <human>" list
  - the board and gallery links

### Log template

```markdown
# Overnight <YYYY-MM-DD>

Integration branch: integration @ <hash at start>. Board: <url>. Gallery: <url>. Lane cap: <n>.

## Morning summary
- Merged: ...
- Blocked: ...
- Provisional decisions: D12 (b) 30 days, ...
- Needs <human>: ...

## Running jobs (resume table)
| Lane | Port | runId | scriptPath | args | started |
|---|---|---|---|---|---|
| auth | 5301 | <runId> | tools/lanes/lane.js | tools/lanes/args/auth.json | 01:12 |

## Timeline
- 01:12 launched auth (port 5301), steps auth-1..auth-3; cards AUTH.1-3 -> doing
- 03:40 auth: auth-1, auth-2 committed (3f2a9c1, 8d0e441); auth-3 blocked: <gate summary>
- 04:02 integrated auth-1..2: rebase clean; gate PASS (14 checks, baseline empty); shots read; ff b71c0de; board, gallery updated
- 04:10 flake: test-api once at load ~12; passed alone

## Flakes
## Watchlist (refuted-for-now findings, picked-ahead commits)
```

---

## 10. Lessons learned

These are failure modes from real overnight runs. Each produced a rule, and the rule is enforced in the place named.

| What went wrong | Rule | Enforced in |
|---|---|---|
| Every lane passed its own gate, but five bugs appeared only after rebasing onto the integration branch: a bar measured before a placement fix, a pooled resource not released (the dispose commit was older than the pool commit), one cost counted twice by two lanes, a shared asset drawn twice, a new term ignored | A lane's gate proves it works alone. Rerun the full gate on the rebased tree before every fast-forward. When two lanes touch the same concept, assume a conflict | recipe step 3; `REQUIRE_BASE`; `review.js` |
| The lane gate ran a hand-picked list of checks and skipped the one that would have caught a regression | Discover checks automatically. Lanes and integration run the same gate script | `discover_checks`; gate prompt |
| A chained command hid a paused rebase, and the gate ran on a half-rebased tree | Never gate, commit or merge mid-rebase. Run state-changing git commands alone and check exit codes | gate refusal; rules file |
| A runbook with conflict markers was staged during a rebase, which had to be aborted and redone | Before `git add`, check for markers and compile | recipe step 2; gate marker check |
| Every lane's browser checks defaulted to the same port, so one lane could test another lane's server | One port per lane and per gate, assigned by the orchestrator. No shared default | `new-lane.sh`; gate refuses an unset `LANE_PORT`; `--strictPort`; `reuseExistingServer: false` |
| A commit body described code the agent hadn't read ("a ledge object" where the diff added a trigger and actors) | The message describes only the diff, written after reading `git diff --cached` | commit prompt; orchestrator reads `git show` before merging; reviewer "false text" rule |
| A commit recorded the gate's own start patch and tree hash | Commit product changes plus a compact gate record, never gate scratch files | commit prompt; `git show --stat` before merging |
| Lanes committed 4,098 and 1,145 evidence files, and one step committed copies of `src/` and `tools/` plus symlinks | Commit only evidence that can't be regenerated, under 60 files and 2 MB. Never full captures or repo copies | commit prompt; `check-staged.sh` |
| A row-merge helper re-added a row the integration branch had already folded into another, four times | Shared-table merges are three-way against the base, removed rows stay removed, and duplicates are checked after. Prefer one file per entry | recipe step 2 |
| Checks rewrote tracked fingerprints, leaving the tree dirty and risking a lane's uncommitted work | The gate leaves the tree as it found it. It restores tracked output and fails if the tree changed | gate snapshot, restore and compare |
| Probe scripts, pruned evidence and caches piled up as untracked files in worktrees | All generated output goes to gitignored folders, added in the same commit. The gate fails on new untracked files | gate untracked check; worktree clean before removal |
| Lanes' shared `node_modules` pointed at the main checkout, whose dependencies differed, so a typecheck failed | Dependencies match the integration branch. Lanes never install. Sharing points at the integration install | `new-lane.sh`; `check_deps`; rules |
| Tests written before a routing change asserted the old routing | When shared behaviour moves, update every test that pins it in the same change. After a rebase, decide which side is stale from the spec | recipe step 2; reviewer lens 1 |
| Commits cherry-picked ahead of their lane caused extra rebase conflicts later | Gate picked commits, log their hashes, rebase the lane promptly, and confirm with `git cherry` | standing habits |
| Screenshots caught visual defects that every check passed: identical props, an object visible through a wall, a double exposure | Visual changes merge only after someone reads real screenshots at fixed viewports | gate prompt; recipe step 4; gallery 7.4 |
| Board cards drifted: queued steps marked doing, done deps not moved on, decisions only in chat | Update the board in the same turn as the work, with hashes, and audit it regularly | standing habits; 6.7 |
| Questions during an unattended run would have stalled the night | Decision cards with provisional defaults. Never block | 6.6; section 9 |
| The session only wakes when a background job finishes | Always keep one job running, and launch the next lane on each completion | section 9 |
| A usage-limit reset could kill running lanes | Log the runId, script and args file of every job before the reset, and resume from the cache | section 9 resume table |
| Checks flaked under load (about 13 to 16) | A flake is a FAIL that passes when rerun alone. Log it with the load, and cap lanes | gate prompt; lane cap |
| Shared engine changes could alter untested legacy modes | Capture deterministic fingerprints of every existing mode before the rebuild. Legacy differences are regressions | baseline; rules |
| Lanes merged on gates run against a slightly older base | Reuse a gate result only if the commits in between touch only allow-listed docs | recipe step 3 |
| A finding refuted "for now" became real once the work it depended on merged | Refuted-for-now findings go on a watchlist and are rechecked on merge | 6.7; log watchlist |
| Gallery shots pointed into deleted lane worktrees | Merged sections reference committed paths on the integration branch | `build-gallery.mjs` fails on them |
| A reviewer that died left a step judged on one review | A round passes only when every lens returned | `lane.js` (`reviews.length === LENSES.length`) |
