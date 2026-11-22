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

# Simulators come from the Mac's pool (xq lease): booted, wiped, shared by every session, so a run skips the
# create and the first boot. What the pool can't give (it's full, the Mac's xq is older, a long-lived name like
# fulltest, or xq-test left a "fresh" file) is a session simulator made by xq sim as before, which xq-test deletes
# at the end. $W/pool.<n> names the pool simulator behind $W/sim.<n>.
boot_sims() {
  local i=0 name how
  SIMS_T0=$(date +%s)
  if [ ! -e "$W/fresh" ]; then
    while read -r name how; do
      [ -n "$name" ] || continue
      i=$((i+1)); echo "$name" > "$W/pool.$i"; echo "$how" > "$W/how.$i"
    done <<EOF
$(~/bin/xq lease "$SESSION" "$SIMS" $$ 2>/dev/null)
EOF
  fi
  for i in $(seq 1 "$SIMS"); do
    if [ -e "$W/pool.$i" ]; then
      # A pool simulator that fails to boot or wipe is deleted by the Mac's xq; this slot then makes its own.
      ( if ~/bin/xq ready "$(cat "$W/pool.$i")" > "$W/sim.$i" 2> "$W/ready.$i"; then
          grep -q erasing "$W/ready.$i" && echo erased > "$W/how.$i"
        else
          rm -f "$W/pool.$i"; echo failed > "$W/how.$i"; ~/bin/xq sim "$SESSION-$i" > "$W/sim.$i" 2>>"$W/ready.$i"
        fi
        cat "$W/ready.$i" >> "$W/sims.log"; date +%s > "$W/done.$i" ) &
    else
      echo session > "$W/how.$i"
      ( ~/bin/xq sim "$SESSION-$i" > "$W/sim.$i" 2>/dev/null; date +%s > "$W/done.$i" ) &
    fi
  done
}

# Call after every boot_sims job is done: tells xq-test how many seconds the simulators took to be ready and where
# they came from (warm: booted pool simulator, cold: shut-down one, new: just made, erased: a pool one that had to
# be erased, failed: a pool one that broke and was replaced, session: made for this run).
sims_ready() {
  local last; last=$(sort -n "$W"/done.* 2>/dev/null | tail -1)
  say sims $((${last:-$SIMS_T0} - SIMS_T0)) "$(cat "$W"/how.* 2>/dev/null | sort | uniq -c | awk '{printf "%s%s=%s", s, $2, $1; s=","}')"
}

# Session simulators are shut down in the background: nobody waits for a shutdown, and the files go with the
# run's folder. Pool simulators stay booted for the next run and are handed back.
stop_sims() {
  local i u pooled="" down=""
  for i in $(seq 1 "$SIMS"); do
    if [ -e "$W/pool.$i" ]; then pooled="$pooled $(cat "$W/pool.$i")"
    else u=$(cat "$W/sim.$i" 2>/dev/null); down="$down $u"; fi
  done
  [ -n "$pooled" ] && ~/bin/xq unlease $$ $pooled >/dev/null 2>&1
  [ -n "${down// /}" ] && (for x in $down; do xcrun simctl shutdown "$x"; done) >/dev/null 2>&1 &
  return 0
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
  # The build only needs a simulator's id; the booting and wiping go on behind it.
  boot_sims
  if [ -e "$W/pool.1" ]; then U=$(sim_udid "$(cat "$W/pool.1")")
  else U=$(sim_udid "$SESSION-1"); [ -n "$U" ] || U=$(~/bin/xq sim "$SESSION-1" 2>/dev/null); fi
  [ -n "$U" ] || { wait; stop_sims; say failed "no simulator"; exit 1; }
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
  # This ref's tests: each `func test...` under the last top-level (unindented) class or extension above it in its
  # file, so a nested helper class or a comment that says "class" doesn't take it. The timings are shared by every
  # branch, so xq-test plans and counts only the timed tests this build has. A test this misses (say, an inherited
  # one) only drops out of the count, and still runs in the first shard.
  find "$SCHEME" -name '*.swift' -print0 2>/dev/null | xargs -0 awk '
    function flush(  t) { for (t in m) print "XQT tests " t m[t]; split("", m); ty = "" }
    FNR == 1 { flush() }
    match($0, /^(@[A-Za-z0-9_]+[ \t]+)*((final|public|private|fileprivate|internal|open|package)[ \t]+)*(class|extension)[ \t]+[A-Za-z0-9_]+/) {
      ty = substr($0, RSTART, RLENGTH); sub(/.*(class|extension)[ \t]+/, "", ty) }
    ty != "" && match($0, /func +test[A-Za-z0-9_]*/) { f = substr($0, RSTART, RLENGTH); sub(/func +/, "", f); m[ty] = m[ty] " " f }
    END { flush() }' 2>/dev/null
  # What the other Mac needs: the xctestrun and the bundles it names (the test bundle sits inside the app).
  SHIP=$(plutil -convert xml1 -o - "$X" | sed -nE 's#.*<string>__TESTROOT__/([^:<]*\.(app|appex))</string>.*#\1#p' \
    | grep -v '\.app/' | sort -u | while IFS= read -r p; do [ -e "$P/$p" ] && printf '%s,' "$p"; done)
  say built "$(($(date +%s) - t0))" "$P" "$(basename "$X")" "$SHIP"
  wait_for "$W/go" || { wait; stop_sims; say failed "no plan arrived"; exit 1; }
  wait; sims_ready
  run_shards a "$X"
  ;;
run)
  boot_sims
  wait_for "$W/products/ready" || { wait; stop_sims; say failed "products never arrived"; exit 1; }
  wait; sims_ready
  X=$(ls -t "$W"/products/*.xctestrun | head -1)
  run_shards b "$X"
  ;;
esac
