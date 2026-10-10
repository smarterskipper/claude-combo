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
  expect(bars(await draw($, 'Done.\n\n**Needs you:**\n- Answer the privacy questions\n- Accept Paid Apps\n\nThat is all.'))).toBe(3)
  expect(await draw($, 'Please sign in on that tab and tell me when you are through.')).toContain('#f59e0b')

  expect(await draw($, "There's nothing you need to do with it.")).not.toContain('#f59e0b')
  expect(await draw($, 'Next, the simulator: the welcome screen.')).not.toContain('#f59e0b')
  expect(await draw($, '```\nyou need to run this\n```')).not.toContain('#f59e0b')
})
