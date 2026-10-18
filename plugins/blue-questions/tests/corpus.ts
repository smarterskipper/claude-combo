// Reply lines labeled by hand, mostly taken from real replies. Each line is read as a one-line
// reply, so it is also the reply's last paragraph (where a trailing question counts).
// `regression` names the bug a case guards.

import type { Kind } from '../hooks/classify'

export type Case = { line: string; expected: Kind; regression?: string }

export const CORPUS: Case[] = [
  // marked by Claude: always highlighted, whatever the phrasing
  { line: '❓ Which branch should I use?', expected: 'question' },
  { line: '- 👉 **Swap** the SIM tonight', expected: 'action' },
  { line: '✅ Kitchen sink sorted.', expected: 'done' },
  { line: '1. ✅ Build 201 is on TestFlight; v3.331.1 costs $9.99 (see `Settings.swift:42`).', expected: 'done' },

  // questions waiting on the person
  { line: 'Want me to merge `cleanup` into `dev` now so it goes out in the next TestFlight?', expected: 'question' },
  { line: 'Which should I start with: the promo text and keywords in App Store Connect, or the Hall server patch?', expected: 'question' },
  { line: '**Where things stand:** the new Units step is on `dev` but not in a build. Want me to release build 218 now?', expected: 'question' },

  // things the person has to do
  { line: 'Next action: open a new session and test it.', expected: 'action' },
  { line: 'Please sign in on that tab and tell me when you are through.', expected: 'action' },
  { line: '**PR #51 is ready for you to merge.**', expected: 'action' },
  { line: '**You can merge now:** [menos-app/menos-api#39](https://github.com/menos-app/menos-api/pull/39) → *Merge pull request*.', expected: 'action' },
  { line: '- [ ] Check the Cloudflare Pages preview on your phone.', expected: 'action' },

  // finished work
  { line: 'Merged #3. Local main is up to date.', expected: 'done' },
  { line: '**Merged and live on dev** (since this morning)', expected: 'done' },
  { line: 'Build 218 (v2.248.0) is uploaded and VALID in TestFlight. It includes the new Units step and the 18+ message.', expected: 'done' },
  { line: 'Done. There are no open pull requests left in any of the four Menos repos.', expected: 'done' },
  { line: 'The unit and render tests pass with 0 failures, and the fix for the test warnings is pushed to dev.', expected: 'done' },

  // plain text: no bar
  { line: "It's not done yet; tests are still running.", expected: 'text' },
  { line: "I'll report back when that's done.", expected: 'text' },
  { line: 'Merged. Running the tests it touches:', expected: 'text' },
  { line: "There's nothing you need to do with it.", expected: 'text' },
  { line: '| Lane | Progress | State |', expected: 'text' },
  { line: '## Done', expected: 'text' },
  { line: '**Health:** this machine is at 13 of 59 GB with the .NET guard on.', expected: 'text' },
  { line: '```\n❓ not a question\n```', expected: 'text' },

  // phrase-guess fixes (2026-10-17)
  { line: '- **Open PRs:** menos-api #64, menos-infra #1 and menosapp-site #127. None are merged, and auto-merge is off on all of them.', expected: 'text', regression: '"None are merged" was drawn as finished work' },
  { line: 'Nothing is merged or deployed.', expected: 'text' },
  { line: 'Neither branch is deployed, so prod is unchanged.', expected: 'text', regression: '"Neither ... is deployed" was drawn as finished work' },
  { line: 'Nothing needs you right now. Everything is waiting on Apple.', expected: 'text', regression: '"Nothing needs you" was drawn as an action item' },
  { line: 'The age screen shows "You must be 18 or older to use Menos." under the field, and Continue stays disabled.', expected: 'text', regression: 'a quoted "You must" was drawn as an action item' },
  { line: 'The release script does not need you for this one.', expected: 'text' },
]
