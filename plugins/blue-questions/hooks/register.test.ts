import { test, expect } from 'claude-code/testing'

const draw = async ($: any, text: string) =>
  JSON.stringify(
    await (
      await $.ui.mount({
        plugin: 'blue-questions',
        surface: 'terminal',
        component: 'AssistantMessage',
        props: { text, isFirstOfReply: true },
      })
    ).drawn(),
  )

// stands in for the engine's own drawing beneath the mod
const engine = (on: any) =>
  on('ui.render', { component: 'AssistantMessage' }, ($: any, e: any) => { const { Text } = $.ui.resolve(e); return Text({ children: 'engine' }) })

test('a trailing question is drawn blue; other text is left to the engine', async ($, on) => {
  engine(on)

  expect(await draw($, 'Done.\n\nWhich branch should I use?')).toContain('#3b82f6')
  expect(await draw($, 'All done.')).not.toContain('#3b82f6')
  expect(await draw($, 'Why did it fail?\n\nBecause of X.')).not.toContain('#3b82f6')
})

test('action items for the person are drawn amber, wherever they sit', async ($, on) => {
  engine(on)

  expect(await draw($, 'Built it.\n\nNext action: open a new session and test it.')).toContain('#f59e0b')
  expect(await draw($, '**PR #51 is ready for you to merge.**\n\nDetails below.')).toContain('#f59e0b')
  // the header and both items under it each get a bar; the line after the list does not
  const bars = (s: string) => s.split('▌').length - 1
  expect(bars(await draw($, 'Built it.\n\n**Needs you:**\n- Answer the privacy questions\n- Accept Paid Apps\n\nThat is all.'))).toBe(3)
  expect(await draw($, 'Please sign in on that tab and tell me when you are through.')).toContain('#f59e0b')

  expect(await draw($, "There's nothing you need to do with it.")).not.toContain('#f59e0b')
  expect(await draw($, 'Next, the simulator: the welcome screen.')).not.toContain('#f59e0b')
  expect(await draw($, '```\nyou need to run this\n```')).not.toContain('#f59e0b')
})

test('finished-work lines are drawn green; unfinished ones are not', async ($, on) => {
  engine(on)

  expect(await draw($, 'Merged #3. Local main is up to date.')).toContain('#22c55e')
  expect(await draw($, 'Both are done:\n\n1. CLAUDE.md updated.')).toContain('#22c55e')
  expect(await draw($, 'Some context first.\n\nThe fix is now live on prod.')).toContain('#22c55e')
  expect(await draw($, '✅ Build 201 uploaded.')).toContain('#22c55e')

  expect(await draw($, "It's not done yet; tests are still running.")).not.toContain('#22c55e')
  expect(await draw($, 'Tests are still running.')).not.toContain('#22c55e')
  expect(await draw($, 'Merged? Not yet.')).not.toContain('#22c55e')
  expect(await draw($, 'Merged. Running the tests it touches:')).not.toContain('#22c55e')
  expect(await draw($, "I'll report back when that's done.")).not.toContain('#22c55e')
})

test('marked lines are always highlighted, wherever they sit, and the mark is hidden', async ($, on) => {
  engine(on)

  const mid = await draw($, 'Intro.\n\n❓ Which branch should I use?\n\nMore text after it.')
  expect(mid).toContain('#3b82f6')
  expect(mid).not.toContain('❓')

  // phrasing the guesses would never catch
  expect(await draw($, '👉 Grab the code off your phone.')).toContain('#f59e0b')
  expect(await draw($, '- 👉 **Swap** the SIM tonight')).toContain('#f59e0b')
  expect(await draw($, '✅ Kitchen sink sorted.')).toContain('#22c55e')
  expect(await draw($, '✅ Kitchen sink sorted.')).not.toContain('✅')

  // a mark inside a code block is left alone
  expect(await draw($, '```\n❓ not a question\n```')).not.toContain('#3b82f6')
})

test('the instruction to mark lines is added to the system prompt', async ($, on) => {
  on('prompt.compose', ($: any, e: any) => ({ sections: [{ id: 'intro', text: 'engine', scope: 'shared' as const }] }))

  const facts = { model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', tools: [], outputStyle: null, traits: [] }
  const { sections } = await $.prompt.compose({ ...facts, surfaces: ['terminal'] })
  expect((await $.prompt.compose({ ...facts, surfaces: [] })).sections.some(s => s.id === 'blue-questions:marks')).toBe(false)
  const marks = sections.find(s => s.id === 'blue-questions:marks')
  expect(marks?.scope).toBe('session')
  expect(marks?.text).toContain('❓')
  expect(marks?.text).toContain('👉')
  expect(marks?.text).toContain('✅')
})
