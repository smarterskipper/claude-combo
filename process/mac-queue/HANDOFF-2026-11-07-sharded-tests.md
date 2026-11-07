# Handoff: full test runs across both Macs (2026-11-07)

## Done
- `xq test <session> <ref>` runs the whole `MenosTests` suite split across the mini and the MacBook and gives one pass or fail. Code: `xq-test` (ubuntu-pc), `xq-test-worker.sh` (copied to the Mac for each run, nothing installed there). `xq free` is new too. How it works and the rules for the split are in `README.md`.
- Measured at menos-ios fedbaf3e7, 3853 tests: 115 s before, 65 s now with nothing changed; 134 s before, 97 s now with one Swift file changed (MacBook had another job, so it got one simulator). The sharded run's test names and results matched a single run exactly.
- Checked on the real Macs: a failing test on one shard gives `** TEST FAILED **` and exit 1, `--bundle` works, `--one-mac` works (79 s), and a first run with no saved times works and saves them.

## What was found
- Test time is 78 s and the build is most of the rest, so splitting can't do much better than this. `SessionRenderTests` alone is 35 s, which is why big classes split by method.
- `-collect-test-diagnostics never` saves about 9 s per run on any `xcodebuild test`, sharded or not.
- `-parallel-testing-enabled` made the suite slower (96 s against 90 s).
- Tests that read repo files through `#filePath` or `SourceTree` can only run on the Mac that built them. They're pinned there.
- `xcodebuild test` on a simulator that isn't booted yet failed to launch 2 times in 5 ("The request was denied by service delegate"). Gates get a booted simulator from `xq sim`, so they should see this less, and `xq test` retries it once.

## Not done
- Gate scripts in `post-3.0/batch/gates/*` still run `xcodebuild test` themselves. They belong to lanes other threads were using, so I left them. Moving a gate's full-suite step to `xq test fulltest <sha> --bundle <file>` is the next step, and it prints the lines those scripts grep for.
- `MenosUITests` isn't sharded. It needs the stub API and a device-specific simulator.
- Only tried with the mini building. The MacBook building and the mini running the second half should work the same way, with the pins following the build Mac.

## If it breaks
Logs are in `~/.cache/xq/test-runs/<id>/`, one per shard plus `build.log`. A failed run keeps no `.xcresult`, only the text log. Plain `xq <session> -- ci run ...` is untouched and is the fallback.
