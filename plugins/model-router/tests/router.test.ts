import { describe, expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { COMPLAINT, classifyHeuristic, colorAt, labelAt, rungOf } from '../hooks/ladder'

// Stands in for the engine beneath the router: records what each step asked for.
function world(on: On, haikuReply?: string) {
  const sent: { model: string; effort: unknown }[] = []
  mock.clock(on, { now: 1_000_000 })
  mock.store(on)
  on('prompt.submit', ($, e) => ({ text: e.text }))
  const usage = { input_tokens: 50, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }
  on('model.complete', () => ({
    value:
      haikuReply === undefined
        ? { isAnswered: false as const, reason: 'empty-reply' as const, usage }
        : { isAnswered: true as const, text: haikuReply, usage },
  }))
  on('turn.step', async function* ($, e) {
    sent.push({ model: e.model, effort: e.effort })
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
  })
  return sent
}

const BAND = { hasSurvey: false, isWorking: false, maxRows: 5, bodyColumns: 120 }
const step = { turnId: 't1', index: 0, model: 'claude-opus-5-5', effort: 'medium', messageCount: 1 } as const

async function drain(stream: AsyncIterable<unknown>) {
  for await (const _ of stream);
}

describe('model-router', () => {
  test('routes a git one-liner down to Haiku', async ($, on) => {
    const sent = world(on)
    await $.prompt.submit({ text: 'git status please', wait: false })
    await drain($.turn.step(step))
    expect(sent[0]).toEqual({ model: 'claude-haiku-5-5', effort: 'medium' })
  })

  test("follows Haiku's grade when it answers", async ($, on) => {
    const sent = world(on, '{"model":"fable","effort":"high","reason":"novel algorithm"}')
    await $.prompt.submit({ text: 'design a lock-free queue and prove it linearizable', wait: false })
    await drain($.turn.step(step))
    expect(sent[0]).toEqual({ model: 'claude-fable-5-1', effort: 'high' })
  })

  test('the ceiling caps the pick', { options: { ceiling: 'opus' } }, async ($, on) => {
    const sent = world(on, '{"model":"fable","effort":"xhigh","reason":"hard"}')
    await $.prompt.submit({ text: 'prove this compiler pass is sound', wait: false })
    await drain($.turn.step(step))
    expect(sent[0]?.model).toBe('claude-opus-5-5')
  })

  test('/route pin holds the model regardless of the prompt', async ($, on) => {
    const sent = world(on)
    await $.command.run({ command: 'route', args: 'pin opus xhigh', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } } as never)
    await $.prompt.submit({ text: 'fix typo', wait: false })
    await drain($.turn.step(step))
    expect(sent[0]).toEqual({ model: 'claude-opus-5-5', effort: 'xhigh' })
  })

  test('/route off leaves the session model alone', async ($, on) => {
    const sent = world(on)
    await $.command.run({ command: 'route', args: 'off', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } } as never)
    await $.prompt.submit({ text: 'fix typo', wait: false })
    await drain($.turn.step(step))
    expect(sent[0]).toEqual({ model: 'claude-opus-5-5', effort: 'medium' })
  })

  test('subagent steps pass through untouched', async ($, on) => {
    const sent = world(on)
    await $.prompt.submit({ text: 'fix typo', wait: false })
    await drain($.turn.step({ ...step, agentId: 'a1' }))
    expect(sent[0]).toEqual({ model: 'claude-opus-5-5', effort: 'medium' })
  })

  test('a risky shell command lifts the rest of the turn to Opus high', async ($, on) => {
    const sent = world(on)
    on('tool.call', () => ({ result: { stdout: '', stderr: '', interrupted: false }, isError: false }) as never)
    await $.prompt.submit({ text: 'deploy it', wait: false })
    await $.tool.call({ tool: 'Bash', command: 'terraform apply -auto-approve' } as never)
    await drain($.turn.step(step))
    expect(sent[0]).toEqual({ model: 'claude-opus-5-5', effort: 'high' })
  })

  test('the band draws a dashed arrow to the pick while the turn runs', async ($, on) => {
    world(on)
    await $.command.run({ command: 'route', args: 'pin opus medium', origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 200 } } as never)
    await $.prompt.submit({ text: 'x', wait: false })
    await drain($.turn.step(step))
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'model-router', surface, component: 'AbovePrompt', props: BAND } as never)
      expect(await ui.find({ type: 'Text', text: /Opus·medium \(pinned\)/ })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: /^┄+▶ $/ })).toBeDefined()
      await ui.unmount()
    }
  })

  test('a finished prompt gets a solid arrow sized by price, and its cost', async ($, on) => {
    world(on)
    on('turn.complete', () => ({ text: '' }))
    const usage = { input_tokens: 1000, output_tokens: 100, cache_read_input_tokens: 0, cache_creation_input_tokens: 0, model: 'claude-haiku-5-5' }
    await $.prompt.submit({ text: 'git status please', wait: false })
    await drain($.turn.step(step))
    await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer', usage } as never)
    const ui = await $.ui.mount({ plugin: 'model-router', surface: 'terminal', component: 'AbovePrompt', props: BAND } as never)
    expect(await ui.find({ type: 'Text', text: /^━━━━▶ $/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /\$0\.000/ })).toBeDefined()
    await ui.unmount()
  })

  test('"that\'s wrong" steps the next turn up and marks the last one rejected', async ($, on) => {
    const sent = world(on)
    on('turn.complete', () => ({ text: '' }))
    await $.prompt.submit({ text: 'git status please', wait: false })
    await drain($.turn.step(step))
    await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' } as never)
    await $.prompt.submit({ text: "that's wrong, it should show the branch", wait: false })
    await drain($.turn.step({ ...step, turnId: 't2' }))
    expect(sent[1]?.model).toBe('claude-sonnet-5-5')
    const ui = await $.ui.mount({ plugin: 'model-router', surface: 'terminal', component: 'AbovePrompt', props: BAND } as never)
    expect(await ui.find({ type: 'Text', text: /✗ \$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /↑/ })).toBeDefined()
    await ui.unmount()
  })

  test('heuristics and ladder helpers', async () => {
    expect(classifyHeuristic('rename foo to bar').rung).toBe(rungOf('haiku', 'medium'))
    expect(classifyHeuristic('refactor the auth layer across all services').rung).toBe(rungOf('opus', 'high'))
    expect(classifyHeuristic('fix the race condition in the job scheduler').rung).toBe(rungOf('opus', 'xhigh'))
    expect(classifyHeuristic('ultrathink: design the consensus protocol').rung).toBe(rungOf('fable', 'xhigh'))
    expect(labelAt(rungOf('opus', 'medium'))).toBe('Opus 5.5 · medium')
    expect(colorAt(0)).toBe('#22c55e')
    expect(colorAt(19)).toBe('#ef4444')
    expect(labelAt(rungOf('haiku', 'low'))).toBe('Haiku 5.5 · low')
    expect(['no, use the other table', 'still broken', "that didn't work", 'try again'].every(t => COMPLAINT.test(t))).toBe(true)
    expect(['no worries, thanks', 'now add a test', 'is this wrong?'].some(t => COMPLAINT.test(t))).toBe(false)
  })
})
