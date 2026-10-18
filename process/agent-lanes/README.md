# Agent lanes: the default way of working

This folder holds reference files, not a plugin. Agent lanes are how every session works by default. `~/.claude/CLAUDE.md`, in the section "Default way of working: ask up front, then get it done alone", points here. Because it is the default, there is no skill, slash command or plugin to turn it on. A session follows it every time.

## What it is

Big work gets split into **lanes**. Each lane has one branch, one git worktree, one port and an ordered list of steps. A Workflow script (`lane.js`) runs every step through the same loop:

1. An agent implements the step.
2. A gate agent runs the full integration gate.
3. Two reviewers check it, one for behaviour and regressions, one for design and hygiene.
4. Up to three fix rounds handle whatever failed.
5. A commit agent commits the step with a small evidence record.

A step that can't pass stops its lane, so nothing gets built on broken work. The orchestrator is the session you talk to. It integrates one lane at a time: rebase onto the integration branch, rerun the gate on the rebased tree, read the screenshots, then `merge --ff-only`. It keeps the board, the gallery and the run log current in the same turn. Only you merge to `main`.

The full guide is [`agent-lanes-bootstrap.md`](agent-lanes-bootstrap.md), an exact copy of the original. Follow its section 2 to set up a new repo.

## How a session uses it

1. **Ask up front, once.** Read the context, then ask in one batch only the questions that really need you: product taste, money, legal. Anything Claude can decide or look up, it doesn't ask.
2. **Then run on its own.** Plan the lanes, create them (`new-lane.sh`), write `tools/lanes/args/<lane>.json` and launch `lane.js` for each. Each finished lane gets integrated, then the next unblocked lane starts. A new question gets the recommended option and is logged as `PROVISIONAL: <question> -> <choice>`, never asked mid-run.
3. **Stuck? Find the way.** If a tool, an API or an asset is missing ("we have no art for X"), research how it's done (web, docs, repo history), then build it ("make it with our pipeline"). Free tools get installed in user space. Claude never waits on you for something it can learn or make.
4. **Stop only for** prod deploys or promotion, money, legal sign-off, publishing or sending outside our repos, deleting things outside the task, and credentials. Those get parked while everything else keeps going.
5. **End with a report:** what merged (with hashes), what's blocked and why, every PROVISIONAL call, and what needs you.

Small single-file tasks skip the lane machinery but still follow steps 1, 3, 4 and 5.

## Templates

`templates/` holds every full file the guide gives, extracted verbatim from its code blocks and laid out at their target paths, so `cp -R templates/tools <repo>/` drops them in place. The STACK blocks are left as the guide wrote them: fill them in per section 8 of the guide, or from the stack notes below.

| File | Guide section | Notes |
|---|---|---|
| `tools/lanes/lane.js` | 3.3 | Lane runner (Workflow script) |
| `tools/lanes/review.js` | 3.6 | Read-only integration review (Workflow script) |
| `tools/lanes/integration-gate.sh` | 4.1 | POSIX gate |
| `tools/lanes/integration-gate.ps1` | 4.2 | PowerShell 7 gate |
| `tools/lanes/capture-baseline.sh` | 4.3 | Deterministic baseline capture |
| `tools/lanes/check-staged.sh` | 3.5 | Commit budget check |
| `tools/lanes/new-lane.sh` | 2.5 | Creates a lane worktree, branch and `.lane.env` |
| `tools/lanes/log/overnight-template.md` | 9 | Run log template |
| `tools/gallery/build-gallery.mjs` | 7.3 | Gallery builder |
| `tools/gallery/gallery.json` | 7.2 | Example gallery source |
| `tools/gallery/package.json` | 2.1 | Builder's one dependency (`sharp`) |
| `agent-rules.md` | 2.2 | Paste into the repo's `CLAUDE.md` / `AGENTS.md`. It's renamed here so it isn't loaded as instructions for this repo |
| `gitignore` | 2.1 | Lines to add to the repo's `.gitignore` |
| `playwright.config.ts` | 8.3 | React: one server per lane on `LANE_PORT` |
| `Assets/Editor/GateBuild.cs` | 8.1 | Unity gate build entry point |

The guide doesn't give the board page (`tools/board/board.html`) in full. Write it from section 6.3 after loading the `artifact-capabilities` and `artifact-design` skills.

## Token watchdog

`watchdog.py` (python3, stdlib) flags workflow agents that look hung (no transcript write for 30 min), looping (300+ turns) or stuck retrying (same step started 6+ times), across every session under `~/.claude/projects`. Keep it running in the background whenever workflows run:

```
while python3 ~/source/repos/claude-combo/process/agent-lanes/watchdog.py > /tmp/watchdog.last 2>&1; do sleep 300; done; cat /tmp/watchdog.last
```

It exits (waking the session) on a finding: inspect, then stop and relaunch narrower, or ack a legitimately long agent in `~/.claude/watchdog.ack`.

## Stack notes

These sit next to the guide's own adapters (section 8). They fill the same STACK slots.

| Stack | Where it runs | Slots and rules |
|---|---|---|
| Unity | local editor per lane folder | Guide 8.1. 2 to 3 lanes. |
| .NET service | local | Guide 8.2. About 4 lanes. |
| React web app | local | Guide 8.3. 4 to 6 lanes. |
| **iOS / Xcode (SwiftUI, XcodeGen)** | **remote Mac over SSH, through the shared build queue** | Every build, test, archive or simulator job goes through `~/bin/xq <session> -- <cmd>` on the Mac. The queue is FIFO with a few slots, and each job gets `$XQ_SLOT`. Never run `xcodebuild` outside xq. Build inside the warm lanes: `~/bin/xq <session> -- ~/bin/ci run <repo> <branch\|sha> -- <cmd>`. The cmd runs in `$CI_SRC` and passes `-derivedDataPath "$CI_DD"`, so each lane keeps its own DerivedData (never share one between lanes, never delete `~/ci/*/dd*`). COMPILE / BUILD: `xcodebuild build -scheme <S> -destination 'generic/platform=iOS Simulator' -derivedDataPath "$CI_DD"`. TEST: `xcodebuild test ... -only-testing:<Target>/<Class>` for the touched area. The full suite runs at integration and on the release build. SCREENSHOTS: `~/bin/xq sim <session>` for a simulator (never ad-hoc ones), then `xcrun simctl io <udid> screenshot`. PORT: usually none. The lane's port only matters for a local mock server. Check in every 5 min (`~/bin/xq checkin <session>`) while you hold a slot idle. The Mac is the real bottleneck, so cap iOS lanes at the queue's slot count. |
| **.NET memory hygiene (any .NET stack)** | local | Run one `dotnet test` at a time per machine. The gate runs checks serially, and lanes queue their test runs instead of starting them together. Cap every .NET process: `DOTNET_GCHeapHardLimit=0x180000000` (6 GiB), `DOTNET_gcServer=0`, `MSBUILDDISABLENODEREUSE=1`, `DOTNET_CLI_USE_MSBUILD_SERVER=0` (exported in the shell profile). Use `-nodeReuse:false` and `dotnet build-server shutdown` in `teardown()`. After a crash, read `journalctl -k` for the OOM table before blaming the lane count: a 44 GB runaway of lingering dotnet processes once took the box down. |
