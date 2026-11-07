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

## Adding a Mac

1. At the Mac: turn on Remote Login, add ubuntu-pc's public key, use an admin user.
2. Add a `Host` entry in `~/.ssh/config`.
3. Run `setup-mac.sh <alias> check`, then `tools`, `xcode`. A person then selects Xcode, accepts the license, installs Homebrew and signs in with `gh auth login -h github.com -p https -w --insecure-storage` (the keychain is locked over SSH). Then run `brew`, `ci --secrets`, `runtimes`, `sims`.
4. Warm one lane, run a small gate, then add the alias to `~/.config/xq/macs`.

## Tests

`bash test-xq.sh` runs against a stub ssh and touches no real Mac.

## Xcode versions

The mini runs Xcode 27.2 (macOS 27.2 wouldn't open 26.4 and its test runner hung), the MacBook 26.4. Builds and tests pass on both, but a job that compiles on one isn't proof for the other. Release builds and screenshot lanes stay on the MacBook.
