# Mac queue: jobs go to whichever build Mac is free

Every Mac runs its own `~/bin/xq` queue and warm `~/bin/ci` lanes, as it always has. `xq` here (installed at `~/.local/bin/xq` on ubuntu-pc) only decides which Mac a job goes to.

```bash
xq mysession -- ci run menos-ios dev -- bash -c 'xcodebuild ... -derivedDataPath "$CI_DD"'
xq run mysession 'U=$(~/bin/xq sim mysession); ~/bin/xq mysession -- ~/bin/ci run menos-ios dev -- ...'
MAC=$(xq pick mysession)   # gate scripts: use "$MAC" for every ssh and scp in that run
xq status
```

`ssh macbook '~/bin/xq ...'` still works and always lands on the MacBook. `xq --help` has every command.

How a Mac is chosen:

| Job | Goes to |
|---|---|
| `XQ_HOST=<alias>` set | that Mac |
| Archive, export, upload, `devicectl`, keychain unlock | MacBook: signing only lives there |
| Names a simulator UDID or a `/tmp/` path | the session's Mac, because that state lives there |
| Anything else | the session's Mac if free, otherwise the first free Mac in the list |

If every Mac is full, the job waits in one line on ubuntu-pc, in arrival order, and goes to the first Mac that frees up. A Mac that's down is skipped, so losing the mini means everything runs on the MacBook as before.

The list of Macs is `~/.config/xq/macs`, preferred first. The MacBook goes last so Boston's laptop takes the overflow.

## Full test runs across both Macs

```bash
xq test fulltest <branch-or-sha>
xq test fulltest <sha> --bundle commits.bundle    # work that isn't on GitHub yet
```

Use the session name `fulltest` unless two runs need to go at once: the simulators are named after the session, and a new name's first run takes more than twice as long (150 s against 65 s) while they are made and booted for the first time.

This builds once in the first free Mac's warm lane, copies the app (about 250 MB, through ubuntu-pc) to the other Mac if it has a free slot, and runs `test-without-building` on two simulators per idle Mac. A Mac with another job running gets one simulator, and if the other Mac is full or down everything stays on the building Mac. The result is one pass or fail, with the usual `Executed N tests` and `** TEST SUCCEEDED **` lines and exit code 0 or 1. Logs stay in `~/.cache/xq/test-runs/<id>/`. Run `xq test -h` for the options. Only test runs go through it: signing, archives and TestFlight stay on the MacBook.

How the split stays safe:

- Times come from the last green run, in `~/.cache/xq/timings/`. With no times yet, the whole suite runs as one shard and saves them.
- The first shard skips what the other shards run, instead of listing what it runs, so a new test always runs somewhere. A run fails if a shard runs nothing, a test runs twice, or under 95% of the last green run's tests ran.
- A class too big for one shard is split by method (`SessionRenderTests` is 35 s of the 78 s).
- Tests that read repo files through `#filePath` or `SourceTree` have the build Mac's path compiled in, so their classes stay on the build Mac. The worker finds them by grep on every run. A test that finds repo files some other way fails on the second Mac with "no such file": add its marker to the grep in `xq-test-worker.sh`.
- A shard that can't launch the test runner gets one more try, because a just-booted simulator sometimes refuses the first launch. A test failure never retries.

Measured at menos-ios fedbaf3e7 (3853 tests, 6 skipped, 0 failed), 2026-11-07, build on the mini:

| Run | Nothing changed | One Swift file changed |
|---|---|---|
| Before: `xcodebuild test`, one Mac | 115 s | 134 s |
| `xq test --one-mac`, 2 simulators | 79 s | |
| `xq test`, 2 + 2 simulators | 65 s | |
| `xq test`, MacBook busy, 2 + 1 simulators | | 97 s |

Most of the time left is the build. `-collect-test-diagnostics never` alone saves about 9 s per `xcodebuild` run, and the failure text is still in the log. Xcode's own `-parallel-testing-enabled` doesn't help: 96 s with 4 workers against 90 s without, because it clones and boots simulators on each run and keeps a class on one worker.

Tests: `python3 test-xq-test.py` covers the split and the merge.

## Adding a Mac

1. At the Mac: turn on Remote Login, add ubuntu-pc's public key, use an admin user.
2. Add a `Host` entry in `~/.ssh/config`.
3. Run `setup-mac.sh <alias> check`, then `tools`. Install Xcode from the App Store. A person then selects Xcode, accepts the license, installs Homebrew and signs in with `gh auth login -h github.com -p https -w --insecure-storage` (the keychain is locked over SSH). Then run `brew`, `ci --secrets`, `runtimes`, `sims`, `warm`.
4. Warm one lane, run a small gate, then add the alias to `~/.config/xq/macs`.

## Tests

`bash test-xq.sh` runs against a stub ssh and touches no real Mac.

## Xcode versions

Both Macs run Xcode 27.2 (27B52) with the iOS 26.4 and watchOS 26.4 simulators, and full MenosTests pass on both (3812 tests). Keep them on the same Xcode: a job that compiles on one version isn't proof for another. The next TestFlight build is the first one made with 27.2.

## Gates

The lane scripts in `post-3.0/batch/gates/{cb1,cbtwo,iw,cs1,bw,sg}/` and `post-3.0/batch/coreloop/baseline/run/` start with `MAC=$(xq pick <session>)`, export it as `XQ_HOST`, use `$MAC` for every ssh and scp, and send their jobs with `xq run`, so the pick's claim ends when the job gets its slot. Each script copies what it needs, so a shots run doesn't have to land on the Mac that ran the gate. To force a Mac: `XQ_HOST=macbook bash gaterun.sh ...`. A session with no Mac yet starts on the mini, and its first run there builds cold. Signing and TestFlight stay on the MacBook.

Screenshots match across Macs apart from the scene's own animation. A simulator's first boot shows system banners over the app, so `setup-mac.sh <alias> warm` gives every xq-* iPhone its first boot ahead of time.
