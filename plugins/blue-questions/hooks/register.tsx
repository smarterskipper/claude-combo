import { atom, read, update, type Register } from 'claude-code'

type RGB = [number, number, number]
type Kind = 'text' | 'question' | 'action' | 'done'

// Gradient stops: deep -> bright -> deep, repeating every SPAN characters,
// which reads as a soft glow rather than a flat color.
const LOOK: Record<Exclude<Kind, 'text'>, { bar: string; stops: RGB[]; sweepMs: number }> = {
  question: { bar: '#3b82f6', stops: [[59, 130, 246], [125, 211, 252], [59, 130, 246]], sweepMs: 800 },
  action: { bar: '#f59e0b', stops: [[245, 158, 11], [253, 224, 71], [245, 158, 11]], sweepMs: 800 },
  done: { bar: '#22c55e', stops: [[34, 197, 94], [134, 239, 172], [34, 197, 94]], sweepMs: 1600 },
}

// Colors sit by character position, not line length, so a line still streaming in doesn't slide.
const SPAN = 48
const CHUNK = 2

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

// Prose only: not a table row, heading, or quote.
const isProse = (line: string) => !/^\s*(\||#|>)/.test(line) && line.trim().length > 1

// A question is a prose line ending in "?".
const isQuestion = (line: string) => /\?[*_`")\]]*\s*$/.test(line) && isProse(line)

// The line with list markers and emphasis stripped, for matching.
const bare = (line: string) => line.replace(/\*\*|__|`/g, '').replace(/^\s*([-*+]|\d+[.)])\s+(\[ \]\s*)?/, '').trim()

// A label that hands the person something to do: "Next action:", "**Needs you:**".
const LABEL = /^(next (real )?(action|step)s?|action items?|actions?|to ?dos?|needs you|on you|for you|your (call|move|turn|side|part)|you)\s*[:—–-]/i
// Phrases that ask the person to act, anywhere in the line.
const ASK = /\b(you('ll| will)? need to|you have to|you must|please (sign|log|open|run|merge|approve|send|check|tap|click|confirm|reply|answer|pick|choose|add|enter|install|restart|test|try|review|accept|tell|let|paste)|for you to (merge|approve|review|test|try|run|sign|answer|pick|accept|check)|ready for you to|tell me when|let me know when|needs you\b|you can merge)/i
// "nothing you need to do" and friends are the opposite of an action.
const NOT = /\b(nothing (you|for you)|no action|you don't (need|have)|you do not (need|have)|no need)\b/i

const isAction = (line: string) => {
  const text = bare(line)
  return isProse(line) && !NOT.test(text) && (LABEL.test(text) || ASK.test(text) || /^\s*[-*]\s+\[ \]/.test(line))
}

// Work Claude reports as finished: "Merged #3.", "Both are done:", "The fix is now live."
const FINISHED = 'done|finished|fixed|merged|shipped|deployed|installed|pushed|published|uploaded|complete|completed|live|up to date|in place'
const DONE_START = new RegExp(`^(✅|(all|both|everything('s| is)?)\\s+(\\w+\\s+)?(are\\s+)?(done|finished|fixed|in place)\\b|(done|finished|fixed|merged|shipped|deployed|installed|pushed|published|uploaded)\\b)`, 'i')
const DONE_IS = new RegExp(`\\b(is|are|'s|was|were|has been|have been) (now )?(all )?(${FINISHED})\\b`, 'i')
const NOT_DONE = /\b(not|never)\b|n't\b|\bstill\b|\byet\b/i
// Promises and conditions ("I'll report back when that's done") aren't finished work.
const LATER = /\b(I'll|I will|will|once|when|after|if|until)\b/i
// A progress note moves on in the same line: "Merged. Running the tests".
const MOVING_ON = /(^|[.;!]\s+)(\w+ing|Now|Next|Then)\b/

const isDone = (line: string) => {
  const text = bare(line)
  return isProse(line) && !/\?/.test(text.split(/[.!:]/)[0]!) && !NOT_DONE.test(text) && !LATER.test(text) && !MOVING_ON.test(text) &&
    (DONE_START.test(text) || DONE_IS.test(text))
}

// A label alone on its line ("**Needs you:**") makes the list under it action items.
const isActionHeader = (line: string) => LABEL.test(bare(line)) && /:\s*$/.test(bare(line))
const isListItem = (line: string) => /^\s*([-*+]|\d+[.)])\s+/.test(line)

// Drawn text: emphasis dropped, links shown as "text (url)", bullets as "•".
const plain = (line: string) =>
  line
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '$1 ($2)')
    .replace(/\*\*|__|`/g, '')
    .replace(/^(\s*)[-*+]\s+(\[ \]\s*)?/, '$1• ')

// Claude marks the lines itself (see MARKS below); a marked line is always highlighted
// and the mark is hidden. The phrase guesses above only catch lines left unmarked.
const MARK_KIND: Record<string, Exclude<Kind, 'text'>> = { '❓': 'question', '👉': 'action', '✅': 'done' }
const MARKED = /^(\s*(?:(?:[-*+]|\d+[.)])\s+)?(?:\*\*|__)?)\s*(❓|👉|✅)\uFE0F?\s*/u

const MARKS = `Highlight marks: the person's terminal draws these as colored bars and hides the mark itself.
- Start a line with ❓ when it asks the person a question that needs their answer.
- Start a line with 👉 when it is something the person has to do (an action item for them, not for you). In a list of these, mark every item.
- Start a line with ✅ when it reports work you finished.
Put the mark first on the line, after any list marker. Mark every such line in text the person reads, wherever it sits in the reply, and no other lines. Never put marks in code blocks, tables, commit messages, PR text, files or tool input.`

type Part = { kind: Kind; text: string }

const split = (text: string): Part[] => {
  const parts: Part[] = []
  let isFenced = false
  let inActionList = false
  const lines = text.split('\n')

  // A block ending in ":" is a progress note before a tool call, not a report of finished work.
  const isNote = /:\s*$/.test(text.trimEnd())

  // Only the reply's last paragraph can be a question that's waiting on the person.
  let tail = lines.length
  while (tail > 0 && lines[tail - 1]!.trim() === '') tail--
  while (tail > 0 && lines[tail - 1]!.trim() !== '') tail--

  for (const [i, line] of lines.entries()) {
    if (/^\s*(```|~~~)/.test(line)) isFenced = !isFenced

    let kind: Kind = 'text'
    const mark = isFenced ? null : MARKED.exec(line)
    if (mark) {
      parts.push({ kind: MARK_KIND[mark[2]!]!, text: mark[1] + line.slice(mark[0].length) })
      continue
    }
    if (!isFenced && i >= tail && isQuestion(line)) kind = 'question'
    else if (!isFenced && (isAction(line) || (inActionList && isListItem(line)))) kind = 'action'
    else if (!isFenced && !isNote && isDone(line)) kind = 'done'

    // A header's list runs until the first line that isn't a list item.
    if (!isFenced && isActionHeader(line)) inActionList = true
    else if (inActionList && !isListItem(line) && !/^\s+\S/.test(line)) inActionList = false

    const last = parts[parts.length - 1]
    if (kind === 'text' && last && last.kind === 'text') last.text += '\n' + line
    else parts.push({ kind, text: line })
  }

  return parts
}

export const register: Register = on => {
  let lastDrawn = -Infinity
  let frames: { cancel: () => void } | null = null

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
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
          const phase = now === null ? 0 : now / sweepMs
          const chars = [...plain(part.text)]
          const chunks: string[] = []
          for (let i = 0; i < chars.length; i += CHUNK) chunks.push(chars.slice(i, i + CHUNK).join(''))

          // Where chunk i sits in the repeating gradient, slid back by the sweep's phase.
          const at = (i: number) => {
            const t = (i * CHUNK) / SPAN - phase
            return t - Math.floor(t)
          }

          return (
            <Box key={`h${n}`}>
              <Text color={bar} bold>{'▌ '}</Text>
              <Text bold>
                {chunks.map((chunk, i) => (
                  <Text bold color={shade(stops, at(i))}>
                    {chunk}
                  </Text>
                ))}
              </Text>
            </Box>
          )
        })}
      </Box>
    )
  })

  // Ask Claude to mark the lines, wherever something draws the reply.
  on('prompt.compose', async ($, e, next) => {
    const result = await next(e)
    // Nothing draws the reply under -p or for the engine's own analysis calls, so a mark would show raw.
    if (e.surfaces.length === 0 || e.traits.some(t => t === 'print' || t === 'analysis')) return result
    if (result.sections.some(s => s.id === 'blue-questions:marks')) return result
    return { sections: [...result.sections, { id: 'blue-questions:marks', text: MARKS, scope: 'session' as const }] }
  })

}
