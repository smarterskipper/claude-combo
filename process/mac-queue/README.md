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
3. Run `setup-mac.sh <alias> check`, then `tools`. Install Xcode from the App Store. A person then selects Xcode, accepts the license, installs Homebrew and signs in with `gh auth login -h github.com -p https -w --insecure-storage` (the keychain is locked over SSH). Then run `brew`, `ci --secrets`, `runtimes`, `sims`, `warm`.
4. Warm one lane, run a small gate, then add the alias to `~/.config/xq/macs`.

## Tests

`bash test-xq.sh` runs against a stub ssh and touches no real Mac.

## Xcode versions

Both Macs run Xcode 27.2 (27B52) with the iOS 26.4 and watchOS 26.4 simulators, and full MenosTests pass on both (3812 tests). Keep them on the same Xcode: a job that compiles on one version isn't proof for another. The next TestFlight build is the first one made with 27.2.

## Gates

The lane scripts in `post-3.0/batch/gates/{cb1,cbtwo,iw,cs1,bw,sg}/` start with `MAC=$(xq pick <session>)`, export it as `XQ_HOST`, use `$MAC` for every ssh and scp, and send their jobs with `xq run`, so the pick's claim ends when the job gets its slot. Each script copies what it needs, so a shots run doesn't have to land on the Mac that ran the gate. To force a Mac: `XQ_HOST=macbook bash gaterun.sh ...`. A session with no Mac yet starts on the mini, and its first run there builds cold. Signing and TestFlight stay on the MacBook.

Screenshots match across Macs apart from the scene's own animation. A simulator's first boot shows system banners over the app, so `setup-mac.sh <alias> warm` gives every xq-* iPhone its first boot ahead of time.
