#!/bin/sh
# Integration gate: refuses mid-rebase/merge, runs every discovered check, the baseline capture + diff and the build on a worktree, and leaves the tree as it found it. Run: LANE_PORT=<port> [REQUIRE_BASE=integration] sh tools/lanes/integration-gate.sh <worktree>   (logs in <worktree>/tools/lanes/out/integration/; exit 0 pass, 1 fail, 2 refused)
set -u
root=${1:?usage: integration-gate.sh <worktree>}
cd "$root" || exit 2

# ===== STACK: fill in once (section 8) =====
BASE_BRANCH=${BASE_BRANCH:-integration}
COMPILE='npx tsc --noEmit'
BUILD='npm run build'
BASELINE_DIR=tools/lanes/baseline
TRACKED_OUTPUT=''          # tracked folders the checks regenerate, restored after the run (space-separated)
LEFTOVERS='\.received\.|-actual\.png$|-diff\.png$'   # snapshot output that means "not accepted"
discover_checks() {        # print one "name command..." line per check
  node -e 'const s=require("./package.json").scripts||{};for(const k of Object.keys(s))if(/^(lint|typecheck|test|test:.+|check:.+)$/.test(k)&&!/watch|dev|ui/.test(k))console.log(k.replace(/:/g,"-")+" npm run "+k)'
  # checks the branch added that no script runs yet
  git diff --name-only --diff-filter=A "$BASE_BRANCH"...HEAD -- 'tools/qa/*-check.*' | while read -r f; do
    grep -q "$f" package.json || echo "$(basename "$f" | sed 's/\..*//') npx tsx $f"
  done
}
check_deps() { :; }        # e.g. fail if the dependency install doesn't match the lock file
teardown() { :; }          # e.g. dotnet build-server shutdown; docker compose -p "$COMPOSE_PROJECT_NAME" down -v
# ===== end STACK =====

# 1. Refuse a half-finished rebase, merge or cherry-pick.
gp() { [ -e "$(git rev-parse --git-path "$1")" ]; }
if gp rebase-merge || gp rebase-apply || gp MERGE_HEAD || gp CHERRY_PICK_HEAD || git diff --name-only --diff-filter=U | grep -q .; then
  echo "GATE REFUSED: a rebase, merge or cherry-pick is in progress in $root"; exit 2
fi
if git grep --untracked -qE '^(<<<<<<<|>>>>>>>)( |$)' -- . 2>/dev/null; then
  echo "GATE REFUSED: conflict markers in:"; git grep --untracked -lE '^(<<<<<<<|>>>>>>>)( |$)' -- . | head -5; exit 2
fi
if [ -n "${REQUIRE_BASE:-}" ] && ! git merge-base --is-ancestor "$REQUIRE_BASE" HEAD; then
  echo "GATE REFUSED: HEAD does not contain $REQUIRE_BASE; rebase first"; exit 2
fi

# 2. Per-gate port and environment. An explicit LANE_PORT wins over .lane.env; nothing falls back to a shared default.
port_override=${LANE_PORT:-}
[ -f .lane.env ] && . ./.lane.env
[ -n "$port_override" ] && LANE_PORT=$port_override
[ -n "${LANE_PORT:-}" ] || { echo "GATE REFUSED: LANE_PORT is not set"; exit 2; }
export LANE_PORT CI=1
trap teardown EXIT

OUT="$root/tools/lanes/out/integration"     # must be gitignored
rm -rf "$OUT" && mkdir -p "$OUT"
fail=0
run() { name=$1; shift
  if "$@" > "$OUT/$name.log" 2>&1 < /dev/null; then echo "pass  $name" | tee -a "$OUT/summary.txt"
  else echo "FAIL  $name" | tee -a "$OUT/summary.txt"; tail -15 "$OUT/$name.log" | sed 's/^/      /'; fail=1; fi; }

# 3. Snapshot the tree. Lanes gate uncommitted work, so the tree must end as it started (not clean).
state() { git status --porcelain --untracked-files=no; git diff | git hash-object --stdin; }
before=$(state)
git status --porcelain --untracked-files=all | grep '^??' | sort > "$OUT/untracked-before.txt"
[ -n "$TRACKED_OUTPUT" ] && git diff --binary --output="$OUT/tracked-output-start.patch" -- $TRACKED_OUTPUT

# 4. Every check.
run deps check_deps
run compile sh -c "$COMPILE"
discover_checks > "$OUT/checks.txt"
while read -r name cmd; do [ -n "$name" ] && run "$name" sh -c "$cmd"; done < "$OUT/checks.txt"
run baseline env BASELINE_OUT="$OUT/baseline" sh tools/lanes/capture-baseline.sh
run baseline-diff git diff --no-index --exit-code -- "$BASELINE_DIR" "$OUT/baseline"
run build sh -c "$BUILD"
run no-leftovers sh -c "! git status --porcelain --untracked-files=all | grep -E '$LEFTOVERS'"

# 5. Restore tracked output the checks regenerated, then compare.
if [ -n "$TRACKED_OUTPUT" ]; then
  git checkout -- $TRACKED_OUTPUT 2>/dev/null
  [ -s "$OUT/tracked-output-start.patch" ] && git apply --binary "$OUT/tracked-output-start.patch"
fi
after=$(state)
[ "$before" = "$after" ] || { git status --short > "$OUT/tree-after.txt"; echo "FAIL  tree changed by the gate (see tree-after.txt)"; fail=1; }
git status --porcelain --untracked-files=all | grep '^??' | sort > "$OUT/untracked-after.txt"
comm -13 "$OUT/untracked-before.txt" "$OUT/untracked-after.txt" > "$OUT/untracked-new.txt"
[ -s "$OUT/untracked-new.txt" ] && { echo "FAIL  the gate left untracked files (gitignore their folder):"; sed 's/^/      /' "$OUT/untracked-new.txt"; fail=1; }

[ $fail = 0 ] && echo "GATE PASS" || echo "GATE FAIL"; exit $fail
