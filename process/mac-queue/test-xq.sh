#!/bin/bash
# Tests for the ubuntu-pc xq dispatcher, against a stub ssh (no real Mac is touched). Run: bash test-xq.sh
HERE=$(cd "$(dirname "$0")" && pwd); XQ=$HERE/xq
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export STUB=$T/stub XQ_SSH=$T/ssh XQ_SCP=$T/scp XQ_MACS=$T/macs XQ_POLL=0.2 XQ_DOWN_LIMIT=1 XQ_CLAIM_TTL=180
unset XQ_HOST
cat > "$XQ_SSH" <<'S'
#!/bin/bash
while [ "${1:-}" = -o ]; do shift 2; done
h=$1; shift; d=$STUB/$h
[ -e "$d/down" ] && exit 255
if [ "$*" = "bash -s" ]; then cat >/dev/null; echo "XQ $(cat "$d/slots") $(cat "$d/busy") $(cat "$d/wait")"; exit 0; fi
echo "$h $*" >> "$STUB/log"
[ -e "$d/nostart" ] || echo "xq: [s] got slot 1 (busy jobs ...)" >&2
[ -e "$d/hold" ] && sleep 0.5
[ -e "$d/slow" ] && sleep 5
[ -e "$d/tail" ] && printf 'FATAL no newline' >&2
exit "$(cat "$d/rc" 2>/dev/null || echo 0)"
S
cat > "$XQ_SCP" <<'S'
#!/bin/bash
echo "scp $*" >> "$STUB/log"
S
chmod +x "$XQ_SSH" "$XQ_SCP"
printf 'mini\nmacbook\n' > "$XQ_MACS"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
no() { fail=$((fail+1)); echo "FAIL $1"; }
reset() {
  rm -rf "$STUB" "$T/state"; export XQ_STATE=$T/state
  mkdir -p "$STUB/mini" "$STUB/macbook"; : > "$STUB/log"
  echo 1 > "$STUB/mini/slots"; echo 2 > "$STUB/macbook/slots"
  for m in mini macbook; do echo 0 > "$STUB/$m/busy"; echo 0 > "$STUB/$m/wait"; done
}
full() { echo "$(cat "$STUB/$1/slots")" > "$STUB/$1/busy"; }
ran_on() { grep -c "^$1 " "$STUB/log"; }

reset; "$XQ" a -- echo hi 2>/dev/null
[ "$(ran_on macbook)" = 1 ] && ok "most free slots wins" || no "most free slots wins"

reset; echo 1 > "$STUB/macbook/busy"; "$XQ" a -- echo hi 2>/dev/null
[ "$(ran_on mini)" = 1 ] && ok "tie goes to the first Mac in the list" || no "tie goes to the first Mac in the list"

reset; mkdir -p "$T/state/pins"; echo mini > "$T/state/pins/a"; "$XQ" a -- echo hi 2>/dev/null
[ "$(ran_on mini)" = 1 ] && ok "free pinned Mac is kept" || no "free pinned Mac is kept"

reset; mkdir -p "$T/state/pins"; echo mini > "$T/state/pins/a"; full mini; "$XQ" a -- echo hi 2>/dev/null
[ "$(ran_on macbook)" = 1 ] && [ "$("$XQ" host a)" = macbook ] && ok "full pinned Mac: moves, and the pin follows" || no "full pinned Mac: moves, and the pin follows"

reset; echo 1 > "$STUB/macbook/slots"; full macbook; "$XQ" a -- xcodebuild archive -scheme Menos 2>/dev/null
[ "$(ran_on macbook)" = 1 ] && [ "$(ran_on mini)" = 0 ] && ok "archive goes to the MacBook even if it is full" || no "archive goes to the MacBook even if it is full"

reset; "$XQ" run a 'xcrun altool --upload-app -f x.ipa' 2>/dev/null
[ "$(ran_on macbook)" = 1 ] && ok "upload goes to the MacBook" || no "upload goes to the MacBook"

reset; mkdir -p "$T/state/pins"; echo mini > "$T/state/pins/a"; full mini
"$XQ" a -- xcodebuild test -destination id=1DF7A941-C442-4653-8A2D-0A4BEA6FC975 2>/dev/null
[ "$(ran_on mini)" = 1 ] && ok "a simulator UDID stays on the session's Mac" || no "a simulator UDID stays on the session's Mac"

reset; "$XQ" a -- bash /tmp/a-gate.sh 2>/dev/null
[ "$(ran_on macbook)" = 1 ] && ok "a /tmp path with no pin means the MacBook" || no "a /tmp path with no pin means the MacBook"

reset; XQ_HOST=mini "$XQ" a -- echo hi 2>/dev/null
[ "$(ran_on mini)" = 1 ] && ok "XQ_HOST forces the Mac" || no "XQ_HOST forces the Mac"

reset; touch "$STUB/mini/down"; "$XQ" a -- echo hi 2>/dev/null
[ "$(ran_on macbook)" = 1 ] && ok "a Mac that is down is skipped" || no "a Mac that is down is skipped"

reset; touch "$STUB/mini/down" "$STUB/macbook/down"; "$XQ" a -- echo hi 2>/dev/null; rc=$?
[ "$rc" != 0 ] && ok "every Mac down fails instead of hanging" || no "every Mac down fails instead of hanging"

reset; echo 7 > "$STUB/macbook/rc"; "$XQ" a -- false 2>/dev/null; rc=$?
[ "$rc" = 7 ] && ok "the job's exit code comes back" || no "the job's exit code comes back ($rc)"

reset; full mini; full macbook
"$XQ" first -- echo 1 2>/dev/null & sleep 0.5
"$XQ" second -- echo 2 2>/dev/null & sleep 0.5
[ ! -s "$STUB/log" ] && ok "all Macs full: jobs wait here" || no "all Macs full: jobs wait here"
echo 0 > "$STUB/macbook/busy"; wait
[ "$(sed -n 1p "$STUB/log" | grep -c 'first')" = 1 ] && [ "$(wc -l < "$STUB/log")" = 2 ] && ok "first in line goes first" || no "first in line goes first"

reset; "$XQ" a -- ~/bin/ci run menos-ios dev -- echo 'two words' 2>/dev/null
grep -q ' ~/bin/ci run menos-ios dev -- echo two\\ words' "$STUB/log" && ok "~ stays a Mac path, args stay quoted" || no "~ stays a Mac path, args stay quoted: $(cat "$STUB/log")"

reset; "$XQ" run a 'ls ~/ci' 2>/dev/null
grep -q '~/bin/xq a -- bash -c' "$STUB/log" && ok "a string without xq still goes through the queue" || no "a string without xq still goes through the queue"

reset; "$XQ" run a 'U=$(~/bin/xq sim a); ~/bin/xq a -- echo $U' 2>/dev/null
grep -q 'U=$(~/bin/xq sim a); ~/bin/xq a -- echo $U' "$STUB/log" && ok "a string with xq is sent as written" || no "a string with xq is sent as written"

reset; echo 1 > "$STUB/macbook/slots"
m1=$("$XQ" pick a 2>/dev/null); m2=$("$XQ" pick b 2>/dev/null)
[ "$m1" != "$m2" ] && ok "a fresh pick counts as busy for the next pick" || no "a fresh pick counts as busy for the next pick ($m1 $m2)"

reset; "$XQ" pick a >/dev/null 2>&1; "$XQ" cp a x.sh mac:/tmp/x.sh 2>/dev/null
grep -q "macbook:/tmp/x.sh" "$STUB/log" && ok "cp swaps mac: for the session's Mac" || no "cp swaps mac: for the session's Mac"

reset; "$XQ" a -- echo hi 2>/dev/null; ls "$T/state/claims" 2>/dev/null | grep -q . && no "claim left behind after the job" || ok "claim is gone after the job"

reset; "$XQ" 'bad name' -- echo hi 2>/dev/null; [ $? != 0 ] && ok "bad session name refused" || no "bad session name refused"

reset; mkdir -p "$T/state/pins"; echo mini > "$T/state/pins/a"
"$XQ" a -- ci run menos-ios fix/testflight-banner -- xcodebuild test 2>/dev/null
[ "$(ran_on mini)" = 1 ] && ok "a branch name doesn't force the MacBook" || no "a branch name doesn't force the MacBook"

reset; mkdir -p "$T/state/pins"; echo mini > "$T/state/pins/a"; "$XQ" a -- xcodebuild build -destination "generic/platform=iOS Simulator" 2>/dev/null
[ "$(ran_on mini)" = 1 ] && ok "a simulator build is not a signing job" || no "a simulator build is not a signing job"

reset; mkdir -p "$T/state/pins"; echo mini > "$T/state/pins/a"; "$XQ" a -- bash /tmp/rel-archive.sh 2>/dev/null
[ "$(ran_on macbook)" = 1 ] && [ "$("$XQ" host a)" = mini ] && ok "signing job leaves the session's pin alone" || no "signing job leaves the session's pin alone"

reset; echo 1 > "$STUB/macbook/slots"; m=$("$XQ" pick a 2>/dev/null); "$XQ" a -- echo hi 2>/dev/null
[ "$(ran_on "$m")" = 1 ] && ok "a session's own pick doesn't push it off that Mac" || no "a session's own pick doesn't push it off that Mac"

reset; echo 1 > "$STUB/macbook/slots"; m=$("$XQ" pick a 2>/dev/null); "$XQ" sim a >/dev/null 2>&1
[ "$("$XQ" host a)" = "$m" ] && ok "xq sim stays on the picked Mac" || no "xq sim stays on the picked Mac"

reset; echo 255 > "$STUB/mini/rc"; touch "$STUB/mini/nostart"; echo 1 > "$STUB/macbook/busy"; rm -f "$STUB/log"; touch "$STUB/log"
"$XQ" a -- echo hi 2>/dev/null; rc=$?
[ "$rc" = 0 ] && [ "$(ran_on macbook)" = 1 ] && [ "$("$XQ" host a)" = macbook ] && ok "a Mac lost before the job starts: next Mac takes it" || no "a Mac lost before the job starts: next Mac takes it (rc $rc)"

reset; touch "$STUB/macbook/slow"; "$XQ" a -- echo hi >/dev/null 2>&1 & p=$!; sleep 0.6; kill -TERM "$p"; S=$SECONDS; wait "$p"; rc=$?
[ "$rc" = 143 ] && [ $((SECONDS-S)) -le 1 ] && ok "TERM stops xq right away" || no "TERM stops xq right away (rc $rc)"

reset; echo x > "$STUB/macbook/tail"; e=$("$XQ" a -- echo hi 2>&1 >/dev/null)
[[ $e == *"FATAL no newline"* ]] && ok "last stderr line without a newline survives" || no "last stderr line without a newline survives"

reset; "$XQ" run a 'U=$(~/bin/xq sim a); xcodebuild test -destination id=$U' 2>/dev/null
grep -q '~/bin/xq a -- bash -c' "$STUB/log" && ok "a string that only uses xq sim still gets queued" || no "a string that only uses xq sim still gets queued"

reset; "$XQ" a -- echo === 2>/dev/null
grep -q 'echo \\===' "$STUB/log" && ok "a leading = is escaped for zsh" || no "a leading = is escaped for zsh"

reset; mkdir -p "$T/state/queue"; sleep 30 & sp=$!; echo "$sp a 1" > "$T/state/queue/0000000001-$sp"; timeout 5 "$XQ" a -- echo hi 2>/dev/null; rc=$?; kill "$sp" 2>/dev/null
[ "$rc" = 0 ] && ok "a ticket whose pid was reused doesn't block the line" || no "a ticket whose pid was reused doesn't block the line (rc $rc)"

XQ_CLAIM_TTL=0.5 "$XQ" --help >/dev/null 2>&1 && ok "fractional settings don't break startup" || no "fractional settings don't break startup"

echo; echo "$pass passed, $fail failed"; [ "$fail" = 0 ]
