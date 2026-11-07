#!/bin/bash
# Runs on a build Mac inside an xq job, for xq-test on ubuntu-pc. Each run gets its own copy in /tmp/xqt/<id>,
# so nothing is installed on the Macs. macOS bash is 3.2: no wait -n, no associative arrays.
#   build <dir> <scheme> <session> <sims> <repo> <ref> [bundle]   lane build, then the a* shards
#   run   <dir> <scheme> <session> <sims>                         the b* shards from products sent to <dir>/products
# Tells xq-test what happened in lines that start with XQT.
set -u
eval "$(/opt/homebrew/bin/brew shellenv)"
MODE=$1; W=$2; SCHEME=$3; SESSION=$4; SIMS=$5; shift 5
LAUNCH_FAIL='Failed to install or launch the test runner'
say() { echo "XQT $*"; }
sim_udid() { xcrun simctl list devices | sed -nE "s/^ +xq-$1 \(([0-9A-F-]{36})\).*/\1/p" | head -1; }
# In the background: nobody waits for a shutdown, and the files go with the run's folder.
stop_sims() { local u; u=$(cat "$W"/sim.* 2>/dev/null); [ -n "$u" ] && (for x in $u; do xcrun simctl shutdown "$x"; done) >/dev/null 2>&1 & }

# xq sim creates the simulator if needed, boots it and checks it answers. The session's name stays in the
# simulator's, so a job starting on this Mac leaves it booted while we hold the slot.
boot_sims() {
  local i
  for i in $(seq 1 "$SIMS"); do ~/bin/xq sim "$SESSION-$i" > "$W/sim.$i" 2>/dev/null & done
}

run_shard() {
  local name=$1 file=$2 n=$3 xctestrun=$4 u line rc t0 try=0 args=()
  u=$(cat "$W/sim.$n" 2>/dev/null)
  [ -n "$u" ] || { say shard "$name" 1 0 0; echo "no simulator for $name" > "$W/$name.log"; return; }
  while IFS= read -r line; do [ -n "$line" ] && args+=("$line"); done < "$file"
  t0=$(date +%s)
  while :; do
    # A test that hangs must not hold the slot: SIGALRM survives exec and ends xcodebuild.
    perl -e 'alarm shift; exec @ARGV or die' 900 xcodebuild test-without-building -xctestrun "$xctestrun" \
      -destination "platform=iOS Simulator,id=$u" -resultBundlePath "$W/$name.$try.xcresult" \
      -collect-test-diagnostics never ${args[@]+"${args[@]}"} > "$W/$name.log" 2>&1
    rc=$?
    # A simulator can refuse the first launch just after booting. No test has run, so one more try is safe.
    if [ "$rc" -ne 0 ] && [ "$try" -eq 0 ] && grep -q "$LAUNCH_FAIL" "$W/$name.log"; then try=1; sleep 3; continue; fi
    break
  done
  say shard "$name" "$rc" $(($(date +%s) - t0)) "$try"
}

run_shards() {
  local prefix=$1 xctestrun=$2 f n=0
  for f in "$W/$prefix"*.args; do
    [ -e "$f" ] || continue
    n=$((n+1)); run_shard "$(basename "$f" .args)" "$f" "$n" "$xctestrun" &
  done
  wait
  stop_sims
}

wait_for() { local i; for i in $(seq 1 900); do [ -e "$1" ] && return 0; sleep 0.2; done; return 1; }

case "$MODE" in
build)
  REPO=$1; REF=$2; BUNDLE=${3:-}
  if [ -n "$BUNDLE" ]; then
    eval "$(~/bin/ci path "$REPO")"
    git -C "$CI_SRC" fetch -q origin && git -C "$CI_SRC" fetch -q "$BUNDLE" "+refs/heads/*:refs/local/xqt/*" \
      || { say failed "could not bring in the bundle"; exit 1; }
  fi
  exec ~/bin/ci run "$REPO" "$REF" -- bash "$0" inner "$W" "$SCHEME" "$SESSION" "$SIMS"
  ;;
inner)
  # The first simulator's id is needed for the build, so a new one is made now. Booting doesn't hold up the build.
  U=$(sim_udid "$SESSION-1"); [ -n "$U" ] || U=$(~/bin/xq sim "$SESSION-1" 2>/dev/null)
  [ -n "$U" ] || { say failed "no simulator"; exit 1; }
  boot_sims
  t0=$(date +%s)
  if ! xcodebuild build-for-testing -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$U" \
       -derivedDataPath "$CI_DD" > "$W/build.log" 2>&1; then
    grep -E '\.swift:[0-9]+:[0-9]+: error:|^error:|BUILD FAILED' "$W/build.log" | sort -u | head -40
    wait; stop_sims; say failed "build failed"; exit 1
  fi
  P=$CI_DD/Build/Products
  X=$(ls -t "$P/${SCHEME}"_iphonesimulator*.xctestrun 2>/dev/null | head -1)
  [ -n "$X" ] || { wait; stop_sims; say failed "no xctestrun"; exit 1; }
  # A test that finds repo files through #filePath or the suite's SourceTree helper was compiled with this Mac's
  # path, so it stays on this Mac.
  grep -rlE '#filePath|#file([^A-Za-z]|$)|SourceTree' "$SCHEME" --include='*.swift' 2>/dev/null | while IFS= read -r f; do
    sed -nE 's/^([a-zA-Z@ ]* )?class ([A-Za-z0-9_]+).*/XQT pin \2/p' "$f"
  done
  # What the other Mac needs: the xctestrun and the bundles it names (the test bundle sits inside the app).
  SHIP=$(plutil -convert xml1 -o - "$X" | sed -nE 's#.*<string>__TESTROOT__/([^:<]*\.(app|appex))</string>.*#\1#p' \
    | grep -v '\.app/' | sort -u | while IFS= read -r p; do [ -e "$P/$p" ] && printf '%s,' "$p"; done)
  say built "$(($(date +%s) - t0))" "$P" "$(basename "$X")" "$SHIP"
  wait_for "$W/go" || { wait; stop_sims; say failed "no plan arrived"; exit 1; }
  wait
  run_shards a "$X"
  ;;
run)
  boot_sims
  wait_for "$W/products/ready" || { wait; stop_sims; say failed "products never arrived"; exit 1; }
  wait
  X=$(ls -t "$W"/products/*.xctestrun | head -1)
  run_shards b "$X"
  ;;
esac
