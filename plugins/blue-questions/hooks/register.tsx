import type { Register } from 'claude-code'

type RGB = [number, number, number]
type Kind = 'text' | 'question' | 'action'

// Gradient stops across a highlighted line: deep -> bright -> back,
// which reads as a soft glow rather than a flat color.
const LOOK: Record<'question' | 'action', { bar: string; stops: RGB[] }> = {
  question: { bar: '#3b82f6', stops: [[59, 130, 246], [125, 211, 252], [96, 165, 250]] },
  action: { bar: '#f59e0b', stops: [[245, 158, 11], [253, 224, 71], [251, 191, 36]] },
}

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

// A label alone on its line ("**Needs you:**") makes the list under it action items.
const isActionHeader = (line: string) => LABEL.test(bare(line)) && /:\s*$/.test(bare(line))
const isListItem = (line: string) => /^\s*([-*+]|\d+[.)])\s+/.test(line)

// Drawn text: emphasis dropped, links shown as "text (url)", bullets as "•".
const plain = (line: string) =>
  line
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '$1 ($2)')
    .replace(/\*\*|__|`/g, '')
    .replace(/^(\s*)[-*+]\s+(\[ \]\s*)?/, '$1• ')

type Part = { kind: Kind; text: string }

const split = (text: string): Part[] => {
  const parts: Part[] = []
  let isFenced = false
  let inActionList = false
  const lines = text.split('\n')

  // Only the reply's last paragraph can be a question that's waiting on the person.
  let tail = lines.length
  while (tail > 0 && lines[tail - 1]!.trim() === '') tail--
  while (tail > 0 && lines[tail - 1]!.trim() !== '') tail--

  for (const [i, line] of lines.entries()) {
    if (/^\s*(```|~~~)/.test(line)) isFenced = !isFenced

    let kind: Kind = 'text'
    if (!isFenced && i >= tail && isQuestion(line)) kind = 'question'
    else if (!isFenced && (isAction(line) || (inActionList && isListItem(line)))) kind = 'action'

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
  on('ui.render', { component: 'AssistantMessage' }, ($, e, next) => {
    const parts = split(e.props.text)

    if (e.props.isSummary || parts.every(p => p.kind === 'text')) return next(e)

    const { Box, Text, Markdown } = $.ui.resolve(e)

    return (
      <Box flexDirection="column">
        {parts.map((part, n) => {
          if (part.kind === 'text') {
            return part.text.trim() === '' ? null : <Markdown key={`m${n}`} text={part.text} />
          }

          const { bar, stops } = LOOK[part.kind]
          const chars = [...plain(part.text)]
          const step = Math.max(1, Math.ceil(chars.length / 24))
          const chunks: string[] = []
          for (let i = 0; i < chars.length; i += step) chunks.push(chars.slice(i, i + step).join(''))

          return (
            <Box key={`h${n}`}>
              <Text color={bar} bold>{'▌ '}</Text>
              <Text bold>
                {chunks.map((chunk, i) => (
                  <Text bold color={shade(stops, chunks.length === 1 ? 0.5 : i / (chunks.length - 1))}>
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
}
