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
