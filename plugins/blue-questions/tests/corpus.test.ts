import { expect, test } from 'claude-code/testing'

import { classifyLine, plain, words } from '../hooks/classify'
import { CORPUS } from './corpus'

for (const c of CORPUS) {
  test(`${c.expected}: ${c.line}`, () => {
    expect(classifyLine(c.line)).toBe(c.expected)
  })
}

// What a bar draws: the words of the line, nothing dropped, markdown syntax outside code removed.
const SHOWN: [string, string][] = [
  ['- **Bold** lead-in with `code` and a [link](https://example.com/a.b).', '• Bold lead-in with code and a link (https://example.com/a.b).'],
  ['Saved `__init__.py`, `**/*.swift` and MY__VAR.', 'Saved __init__.py, **/*.swift and MY__VAR.'],
  ['**Fixed `Foo.swift:42`** in v3.331.1 for $9.99 — e.g. 2.5 GB, i.e. done.', 'Fixed Foo.swift:42 in v3.331.1 for $9.99 — e.g. 2.5 GB, i.e. done.'],
  ['Run ``a `nested` tick`` then 2 * 3 * 4.', 'Run a `nested` tick then 2 * 3 * 4.'],
  ['A lone ` backtick and a lone ** stay as written.', 'A lone ` backtick and a lone ** stay as written.'],
]
for (const [line, shown] of SHOWN) {
  test(`drawn whole: ${line}`, () => {
    expect(plain(line)).toBe(shown)
    expect(words(shown).join('')).toBe(shown)
  })
}

test('a colored run never holds a space and never splits a word', () => {
  for (const run of words('  • Merged  and live,\tsee ~/a/very/long/path/that/never/breaks.txt now.')) {
    expect(/^\s+$/u.test(run) || !/\s/u.test(run)).toBe(true)
  }
})
