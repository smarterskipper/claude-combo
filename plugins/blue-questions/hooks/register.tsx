import { atom, read, update, type Register } from 'claude-code'

import { plain, split, words, type Kind } from './classify'

type RGB = [number, number, number]

// Gradient stops: deep -> bright -> deep, repeating every SPAN characters,
// which reads as a soft glow rather than a flat color.
const LOOK: Record<Exclude<Kind, 'text'>, { bar: string; stops: RGB[]; sweepMs: number }> = {
  question: { bar: '#3b82f6', stops: [[59, 130, 246], [125, 211, 252], [59, 130, 246]], sweepMs: 800 },
  action: { bar: '#f59e0b', stops: [[245, 158, 11], [253, 224, 71], [245, 158, 11]], sweepMs: 800 },
  done: { bar: '#22c55e', stops: [[34, 197, 94], [134, 239, 172], [34, 197, 94]], sweepMs: 1600 },
}

// Colors sit by character position, not line length, so a line still streaming in doesn't slide.
const SPAN = 48

// Highlighted lines on screen slide their gradient one SPAN every sweepMs (see LOOK), all the time:
// questions and action items fast, finished work at half their speed.
const FRAME_MS = 50

// Bumped every frame while a highlighted line is on screen; only those lines read it, so only they redraw.
const tick = atom({ plugin: 'blue-questions', key: 'tick' } as const, 0)

const hex = (n: number) => Math.round(n).toString(16).padStart(2, '0')

const shade = (stops: RGB[], t: number) => {
  const x = t * (stops.length - 1)
  const i = Math.min(Math.floor(x), stops.length - 2)
  const f = x - i
  const [a, b] = [stops[i]!, stops[i + 1]!]
  return '#' + a.map((v, k) => hex(v + (b[k]! - v) * f)).join('')
}

const MARKS = `Highlight marks: the person's terminal or desktop app draws these as colored bars and hides the mark itself.
- Start a line with ❓ when it asks the person a question that needs their answer.
- Start a line with 👉 when it is something the person has to do (an action item for them, not for you). In a list of these, mark every item.
- Start a line with ✅ when it reports work you finished.
Put the mark first on the line, after any list marker. Mark every such line in text the person reads, wherever it sits in the reply, and no other lines. Never put marks in code blocks, tables, commit messages, PR text, files or tool input.`

export const register: Register = on => {
  let lastDrawn = -Infinity
  let frames: { cancel: () => void } | null = null
  // Set once any surface asks this session to draw a reply. The desktop app hosts a session over the
  // SDK, so prompt.compose reads `print` there, and its surfaces are empty while no window shows it.
  let isDrawn = false

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    isDrawn = true
    const parts = split(e.props.text)

    if (e.props.isSummary || parts.every(p => p.kind === 'text')) return next(e)

    // No clock means a still gradient, never no highlight; a line scrolled out of view holds still.
    const now = e.props.onScreen === null ? null : await $.clock.now().catch(() => null)

    if (now !== null) {
      lastDrawn = now
      await read($, tick)
      // The timer runs while something on screen redraws from it, and stops a frame after nothing does.
      frames ??= $.clock.every(FRAME_MS, () => {
        void $.clock.now().then(t => {
          if (t - lastDrawn > FRAME_MS * 2) {
            frames?.cancel()
            frames = null
          }
          return update($, tick, n => n + 1)
        })
      })
    }

    const { Box, Text, Markdown } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {parts.map((part, n) => {
          if (part.kind === 'text') {
            return part.text.trim() === '' ? null : <Markdown key={`m${n}`} text={part.text} />
          }

          const { bar, stops, sweepMs } = LOOK[part.kind]
          // How far into its pass the sweep is, in ms; whole numbers keep a full pass landing exactly where it began.
          const into = now === null ? 0 : now % sweepMs

          // Where character `at` sits in the repeating gradient, slid back by the sweep.
          const shadeAt = (at: number) => {
            const span = SPAN * sweepMs
            return shade(stops, ((((at * sweepMs - into * SPAN) % span) + span) % span) / span)
          }

          // One colored run per word, colored where the word starts; the spaces between stay bare so
          // the line wraps at them on every surface (see `words`).
          let at = 0
          const runs = words(plain(part.text)).map((run, i) => {
            const start = at
            at += [...run].length
            return /^\s/u.test(run) ? run : <Text key={`w${i}`} bold color={shadeAt(start)}>{run}</Text>
          })

          return (
            <Box key={`h${n}`}>
              <Text color={bar} bold>{'▌ '}</Text>
              <Text bold>{runs}</Text>
            </Box>
          )
        })}
      </Box>
    )
  })

  // Ask Claude to mark the lines, wherever something draws the reply: the terminal, the desktop app.
  on('prompt.compose', async ($, e, next) => {
    const result = await next(e)
    // /context only measures the prompt. A plain -p run has no surface and nothing ever drew a reply,
    // so a mark would show raw there. `print` alone says nothing: the desktop app's sessions carry it.
    if (e.traits.includes('analysis') || (e.surfaces.length === 0 && !isDrawn)) return result
    if (result.sections.some(s => s.id === 'blue-questions:marks')) return result
    return { sections: [...result.sections, { id: 'blue-questions:marks', text: MARKS, scope: 'session' as const }] }
  })

}
