// Which lines of a reply get a bar, and the text each bar draws. Pure: no engine API, so
// the corpus test and scripts can run it directly.

export type Kind = 'text' | 'question' | 'action' | 'done'
export type Part = { kind: Kind; text: string }

// Prose only: not a table row, heading, or quote.
const isProse = (line: string) => !/^\s*(\||#|>)/.test(line) && line.trim().length > 1

// A question is a prose line ending in "?".
const isQuestion = (line: string) => /\?[*_`")\]]*\s*$/.test(line) && isProse(line)

// Text someone else said ("You must be 18 or older") is quoted, not an ask of the person.
const unquote = (text: string) => text.replace(/"[^"]*"|“[^”]*”/g, '""')

// The line with list markers, emphasis and quotes stripped, for matching.
const bare = (line: string) =>
  unquote(line.replace(/\*\*|__|`/g, '').replace(/^\s*([-*+]|\d+[.)])\s+(\[ \]\s*)?/, '')).trim()

// A label that hands the person something to do: "Next action:", "**Needs you:**".
const LABEL = /^(next (real )?(action|step)s?|action items?|actions?|to ?dos?|needs you|on you|for you|your (call|move|turn|side|part)|you)\s*[:—–-]/i
// Phrases that ask the person to act, anywhere in the line.
const ASK = /\b(you('ll| will)? need to|you have to|you must|please (sign|log|open|run|merge|approve|send|check|tap|click|confirm|reply|answer|pick|choose|add|enter|install|restart|test|try|review|accept|tell|let|paste)|for you to (merge|approve|review|test|try|run|sign|answer|pick|accept|check)|ready for you to|tell me when|let me know when|needs you\b|you can merge)/i
// "nothing you need to do", "Nothing needs you right now" and friends are the opposite of an action.
const NOT = /\b(nothing (you|for you)|nothing (else )?(needs|is waiting on|waits on) you|no action|you don't (need|have)|you do not (need|have)|(doesn't|does not|don't) need (you|anything from you)|no need)\b/i

const isAction = (line: string) => {
  const text = bare(line)
  return isProse(line) && !NOT.test(text) && (LABEL.test(text) || ASK.test(text) || /^\s*[-*]\s+\[ \]/.test(line))
}

// Work Claude reports as finished: "Merged #3.", "Both are done:", "The fix is now live."
const FINISHED = 'done|finished|fixed|merged|shipped|deployed|installed|pushed|published|uploaded|complete|completed|live|up to date|in place'
const DONE_START = new RegExp(`^(✅|(all|both|everything('s| is)?)\\s+(\\w+\\s+)?(are\\s+)?(done|finished|fixed|in place)\\b|(done|finished|fixed|merged|shipped|deployed|installed|pushed|published|uploaded)\\b)`, 'i')
const DONE_IS = new RegExp(`\\b(is|are|'s|was|were|has been|have been) (now )?(all )?(${FINISHED})\\b`, 'i')
const NOT_DONE = /\b(not|never)\b|n't\b|\bstill\b|\byet\b/i
// "None are merged", "Nothing is merged or deployed": the subject says no work was finished.
const NONE_DONE = new RegExp(`\\b(none|nothing|neither)\\b[^.;:!?]*\\b(is|are|was|were|has been|have been) (now )?(${FINISHED})\\b`, 'i')
// Promises and conditions ("I'll report back when that's done") aren't finished work.
const LATER = /\b(I'll|I will|will|once|when|after|if|until)\b/i
// A progress note moves on in the same line: "Merged. Running the tests".
const MOVING_ON = /(^|[.;!]\s+)(\w+ing|Now|Next|Then)\b/

const isDone = (line: string) => {
  const text = bare(line)
  return isProse(line) && !/\?/.test(text.split(/[.!:]/)[0]!) && !NOT_DONE.test(text) && !NONE_DONE.test(text) &&
    !LATER.test(text) && !MOVING_ON.test(text) && (DONE_START.test(text) || DONE_IS.test(text))
}

// A label alone on its line ("**Needs you:**") makes the list under it action items.
const isActionHeader = (line: string) => LABEL.test(bare(line)) && /:\s*$/.test(bare(line))
const isListItem = (line: string) => /^\s*([-*+]|\d+[.)])\s+/.test(line)

// Inline markdown a bar can't show, outside code: links as "text (url)", **bold** and __bold__
// pairs as their words. Inside `code` every character stays, so `__init__.py` and `**/*.swift` survive.
const unmark = (text: string) =>
  text
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '$1 ($2)')
    .replace(/\*\*(?=\S)(.+?)(?<=\S)\*\*/g, '$1')
    .replace(/(?<![\w\\])__(?=\S)(.+?)(?<=\S)__(?!\w)/g, '$1')

// Drawn text: the line as the bar shows it, bullets as "•". Code spans are set aside while the
// emphasis is stripped, so **bold around `code`** still loses its stars and the code keeps all of its own.
export const plain = (line: string) => {
  const code: string[] = []
  const hidden = line
    .replace(/^(\s*)[-*+]\s+(\[ \]\s*)?/, '$1• ')
    .replace(/(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/g, (_, _ticks: string, body: string) => `${code.push(body) - 1}`)
  return unmark(hidden).replace(/(\d+)/g, (_, i: string) => code[Number(i)] ?? '')
}

// The drawn text as runs to color: each word its own run, each stretch of spaces bare between them.
// The desktop draws a short run with no space in it as `white-space: pre`, so a space inside a run, or a
// run that splits a word, leaves the line nowhere to wrap and it runs past the edge of the reply.
export const words = (text: string) => text.match(/\s+|\S+/gu) ?? []

// Claude marks the lines itself (see MARKS in register.tsx); a marked line is always highlighted
// and the mark is hidden. The phrase guesses above only catch lines left unmarked.
const MARK_KIND: Record<string, Exclude<Kind, 'text'>> = { '❓': 'question', '👉': 'action', '✅': 'done' }
const MARKED = /^(\s*(?:(?:[-*+]|\d+[.)])\s+)?(?:\*\*|__)?)\s*(❓|👉|✅)️?\s*/u

export const split = (text: string): Part[] => {
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

// The kind one line gets on its own, as the last line of a reply (where a question counts).
export const classifyLine = (line: string): Kind => split(line)[0]?.kind ?? 'text'
