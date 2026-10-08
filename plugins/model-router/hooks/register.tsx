import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Decision, Effort, HistoryEntry, Mode, ModelKey } from '../types'
import {
  CLASSIFIER_SYSTEM,
  COMPLAINT,
  EFFORTS,
  MODELS,
  bump,
  clamp,
  classifierPrompt,
  classifyHeuristic,
  colorAt,
  commandFloor,
  costUsd,
  effortAt,
  labelAt,
  modelAt,
  nextModel,
  parseClassifier,
  rungFromSession,
  rungOf,
  shortLabelAt,
} from './ladder'

const CACHE_WARM_MS = 5 * 60_000
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const HISTORY_MAX = 8
// Prompts nobody typed: they route as usual but stay out of the history and the redo check.
const BACKGROUND = new Set(['task-notification', 'scheduled-trigger', 'auto-continuation', 'coordinator', 'observer', 'observer-activity'])

const mode = atom({ plugin: 'model-router', key: 'mode' } as const, 'auto' as Mode)
const decision = atom({ plugin: 'model-router', key: 'decision' } as const, null as Decision | null)
const active = atom({ plugin: 'model-router', key: 'active' } as const, null as number | null)
const lastTurn = atom({ plugin: 'model-router', key: 'lastTurn' } as const, null as { rung: number; costUsd: number; endedAt: number } | null)
const sessionUsd = atom({ plugin: 'model-router', key: 'sessionUsd' } as const, 0)
const pin = atom({ plugin: 'model-router', key: 'pin' } as const, rungOf('opus', 'medium'))
const history = atom({ plugin: 'model-router', key: 'history' } as const, [] as HistoryEntry[])

type Options = { classifier?: string; ceiling?: string; stickiness?: number }

async function setMode($: EngineInterface, next: Mode, pinned?: number) {
  await update($, mode, () => next)
  await $.store.set('mode', next)
  if (pinned === undefined) return
  await update($, pin, () => pinned)
  await $.store.set('pin', pinned)
  if (next === 'pinned') await update($, decision, (): Decision => ({ rung: pinned, reason: 'pinned by you', source: 'pinned' }))
}

/** Raises this turn's rung to at least `floor` (auto mode only; never lowers it). */
async function raise($: EngineInterface, floor: number, reason: string, ceiling: ModelKey) {
  if ((await read($, mode)) !== 'auto') return
  const target = clamp(floor, ceiling)
  await update($, decision, (d): Decision => (d && d.rung >= target ? d : { rung: target, reason, source: 'escalated' }))
}

export const register: Register = (on, options) => {
  const opts = (options ?? {}) as Options
  const ceiling = (opts.ceiling ?? 'fable') as ModelKey
  const stickiness = Math.max(0, Number(opts.stickiness ?? 3))

  // Per-turn escalation signals; a reload resetting them is harmless.
  let failures = 0
  let edited = new Set<string>()

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'route',
      description: 'Model router: show the ladder, or set auto | off | pin <haiku|sonnet|opus|fable> [effort]',
      argumentHint: '[auto | off | pin <haiku|sonnet|opus|fable> [effort]]',
      immediate: true,
    })
    // The side pane is gone; close it if an older session left it open.
    await $.ui.close({ id: 'model-router' })
    const savedMode = (await $.store.get('mode')) as Mode | undefined
    const savedPin = (await $.store.get('pin')) as number | undefined
    if (savedMode) await setMode($, savedMode, savedPin)

    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (e.text.trimStart().startsWith('/')) return next(e)
    const m = await read($, mode)
    const typed = !BACKGROUND.has(e.origin?.kind ?? '')
    const redo = typed && COMPLAINT.test(e.text)
    if (typed) {
      const text = e.text.trim().replace(/\s+/g, ' ').slice(0, 60)
      await update($, history, h => {
        const kept = h.slice(-(HISTORY_MAX - 1))
        const last = kept[kept.length - 1]
        if (redo && last) kept[kept.length - 1] = { ...last, rejected: true }
        return [...kept, { text, rung: null, costUsd: null, rejected: false, redo }]
      })
    }
    if (m !== 'auto') return next(e)

    const current = await read($, active)
    let pick = classifyHeuristic(e.text)
    let source: Decision['source'] = 'heuristic'

    if (opts.classifier !== 'heuristic') {
      // A refused request (model not allowed, bad args) falls back to the heuristic.
      const r = await $.model
        .complete({
          model: 'claude-haiku-5-5',
          system: CLASSIFIER_SYSTEM,
          prompt: classifierPrompt(e.text, current),
          effort: 'low',
          maxTokens: 120,
          timeoutMs: 6000,
        })
        .catch(() => null)
      const graded = r?.isAnswered ? parseClassifier(r.text) : null
      if (graded) (pick = graded), (source = 'haiku')
    }

    let rung = clamp(pick.rung, ceiling)
    let reason = pick.reason

    // A prompt folded into a running turn may only raise the rung.
    if (e.turnId !== undefined && current !== null) rung = Math.max(rung, current)

    // Switching model or effort re-bills the cached prefix, so small downgrades
    // aren't worth it while the cache is still warm.
    const last = await read($, lastTurn)
    const warm = last !== null && (await $.clock.now()) - last.endedAt < CACHE_WARM_MS
    if (warm && current !== null && rung < current && current - rung < stickiness) {
      reason = `cache warm; wanted ${labelAt(rung)} (${reason})`
      rung = current
      source = 'held'
    }

    // You said the last turn was wrong: the next model up takes this one.
    if (redo && current !== null) {
      const up = clamp(nextModel(current), ceiling)
      if (up > rung) (rung = up), (reason = 'you said the last answer was wrong'), (source = 'escalated')
    }

    failures = 0
    edited = new Set()
    await update($, decision, () => ({ rung, reason, source }))

    return next(e)
  }).catch(($, e, next) => next(e))

  on('turn.step', async function* ($, e, next) {
    // Subagents keep whatever model their definition asked for.
    if (e.agentId !== undefined) return yield* next(e)

    const m = await read($, mode)
    const d = await read($, decision)
    if (m === 'off' || d === null) {
      const seen = rungFromSession(e.model, e.effort)
      await update($, active, () => seen)
      return yield* next(e)
    }

    const rung = m === 'pinned' ? d.rung : clamp(d.rung, ceiling)
    if ((await read($, active)) !== rung) {
      await update($, active, () => rung)
      $.ui.status(`⇅ ${labelAt(rung)}`)
    }

    return yield* next({ ...e, model: modelAt(rung).id, effort: effortAt(rung) })
  })

  on('tool.call', async ($, e, next) => {
    if (e.agentId !== undefined) return next(e)

    const tool = String(e.tool)
    if (e.tool === 'Bash') {
      const floor = commandFloor(e.command)
      if (floor) await raise($, floor.rung, floor.reason, ceiling)
    }

    const ran = await next(e)

    if (ran.deny === undefined && ran.isError === true) {
      failures += 1
      // Every second failure in a turn, step up to the next sensible rung.
      if (failures % 2 === 0) {
        const d = await read($, decision)
        await raise($, bump(d?.rung ?? 0), `${failures} failed tool calls this turn`, ceiling)
      }
    }

    if (EDIT_TOOLS.has(tool) && 'file_path' in e && typeof e.file_path === 'string') {
      edited.add(e.file_path)
      if (edited.size === 6) await raise($, rungOf('opus', 'high'), 'editing 6+ files', ceiling)
    }

    return ran
  }).catch(($, e, next) => next(e))

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const cost = e.usage ? costUsd(e.usage) : 0
      const rung = (await read($, active)) ?? 0
      const endedAt = await $.clock.now()
      await update($, lastTurn, () => ({ rung, costUsd: cost, endedAt }))
      await update($, sessionUsd, total => total + cost)
      await update($, history, h => {
        const last = h[h.length - 1]
        return last && last.rung === null ? [...h.slice(0, -1), { ...last, rung, costUsd: cost }] : h
      })
    }

    return next(e)
  })

  on('command.run', { command: 'route' }, async ($, e) => {
    const [verb = '', model, effort] = e.args.trim().toLowerCase().split(/\s+/)

    if (verb === 'auto' || verb === 'off') {
      await setMode($, verb)
      return { text: `Model router: ${verb === 'auto' ? 'routing automatically' : 'off, the session model runs as set'}.` }
    }

    if (verb === 'pin') {
      if (!MODELS.some(x => x.key === model)) return { text: 'Usage: /route pin <haiku|sonnet|opus|fable> [low|medium|high|xhigh|max]' }
      const ef = (EFFORTS.includes(effort as Effort) ? effort : 'medium') as Effort
      const rung = rungOf(model as ModelKey, ef)
      await setMode($, 'pinned', rung)
      return { text: `Model router: pinned to ${labelAt(rung)}.` }
    }

    const d = await read($, decision)
    const a = await read($, active)
    const now = a === null ? 'nothing yet' : labelAt(a)
    return { text: `Model router (${await read($, mode)}): ${now}${d ? ` — ${d.source}: ${d.reason}` : ''}` }
  })

  // Two rows above the prompt:
  //   ⇅ "fix the race cond…" ━━━━━━━━━━━━▶ Opus·xhigh $0.097
  //     H━━S━━O━━F │ ● $0.002  ✗ $0.010  ↑● $0.041   Σ $0.35
  // The arrow grows longer and redder the pricier the pick.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    const m = await read($, mode)
    const a = await read($, active)
    const total = await read($, sessionUsd)
    const past = await read($, history)
    const latest = past[past.length - 1]
    const tag = m === 'auto' ? '' : ` (${m})`

    if (!latest) return <Text dimColor>{`⇅ router${tag} · waiting for your first prompt`}</Text>

    const running = latest.rung === null
    const rung = latest.rung ?? a ?? 0
    const cur = Math.floor(rung / EFFORTS.length)
    const snippet = latest.text.length > 24 ? `${latest.text.slice(0, 23)}…` : latest.text
    const money = (x: number | null) => (x === null ? '…' : `$${x.toFixed(3)}`)

    return (
      <Box flexDirection="column">
        <Box>
          <Text dimColor>{`⇅ "${snippet}" `}</Text>
          <Text color={colorAt(rung)} dimColor={running}>{`${(running ? '┄' : '━').repeat(3 + rung)}▶ `}</Text>
          <Text color={colorAt(rung)} bold>{`${shortLabelAt(rung).replace(' · ', '·')}${tag}`}</Text>
          <Text dimColor>{` ${latest.redo ? '↑ ' : ''}${money(latest.costUsd)}`}</Text>
        </Box>
        <Box>
          <Text>{'  '}</Text>
          {MODELS.map((model, mi) => (
            <Text key={model.key} color={mi <= cur ? colorAt(mi * EFFORTS.length + 2) : undefined} dimColor={mi > cur} bold={mi === cur}>
              {`${mi ? '━━' : ''}${model.label[0]}`}
            </Text>
          ))}
          <Text dimColor>{' │'}</Text>
          {past.slice(-5, -1).map((x, i) => (
            <Text key={String(i)} color={x.rejected ? '#ef4444' : x.rung === null ? undefined : colorAt(x.rung)}>
              {` ${x.redo ? '↑' : ''}${x.rejected ? '✗' : '●'} ${money(x.costUsd)}`}
            </Text>
          ))}
          <Text dimColor>{`   Σ $${total.toFixed(2)}`}</Text>
        </Box>
      </Box>
    )
  })
}
