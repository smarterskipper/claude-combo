# Overnight <YYYY-MM-DD>

Integration branch: integration @ <hash at start>. Board: <url>. Gallery: <url>. Lane cap: <n>.

## Morning summary
- Merged: ...
- Blocked: ...
- Provisional decisions: D12 (b) 30 days, ...
- Needs <human>: ...

## Running jobs (resume table)
| Lane | Port | runId | scriptPath | args | started |
|---|---|---|---|---|---|
| auth | 5301 | <runId> | tools/lanes/lane.js | tools/lanes/args/auth.json | 01:12 |

## Timeline
- 01:12 launched auth (port 5301), steps auth-1..auth-3; cards AUTH.1-3 -> doing
- 03:40 auth: auth-1, auth-2 committed (3f2a9c1, 8d0e441); auth-3 blocked: <gate summary>
- 04:02 integrated auth-1..2: rebase clean; gate PASS (14 checks, baseline empty); shots read; ff b71c0de; board, gallery updated
- 04:10 flake: test-api once at load ~12; passed alone

## Flakes
## Watchlist (refuted-for-now findings, picked-ahead commits)
