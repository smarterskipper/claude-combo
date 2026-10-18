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
