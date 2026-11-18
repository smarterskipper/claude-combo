#!/bin/bash
# Tests for the Mac-side xq's simulator cleanup (prune, drop, the low-disk check), against a stub xcrun and df.
# shellcheck disable=SC2016,SC2034  # checks are eval'd strings
# No Mac and no real simulator is touched. Run: bash test-mac-xq.sh
HERE=$(cd "$(dirname "$0")" && pwd); XQ=$HERE/mac-xq
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH" XQ_DIR=$T/q XQ_KEEP_FILE=$T/keep-sims XQ_PY=python3 XQ_DROP_WAIT=1 STUB=$T
cat > "$T/bin/xcrun" <<'S'
#!/bin/bash
[ "$1" = simctl ] || exit 1
case $2 in
  list) if [ "${4:-}" = -j ]; then cat "$STUB/devices.json"
        else python3 -c 'import json,sys
for v in json.load(open(sys.argv[1]))["devices"].values():
    for d in v: print("    %s (%s) (%s)" % (d["name"], d["udid"], d["state"]))' "$STUB/devices.json"; fi ;;
  delete|shutdown) echo "$2 $3" >> "$STUB/log" ;;
  *) exit 1 ;;
esac
S
cat > "$T/bin/df" <<'S'
#!/bin/bash
echo "Filesystem 1G-blocks Used Available Capacity Mounted"
echo "/dev/disk3s5 460 400 $(cat "$STUB/free") 90% /"
S
chmod +x "$T/bin/xcrun" "$T/bin/df"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
no() { fail=$((fail+1)); echo "FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else no "$1"; sed 's/^/     /' "$T/out"; fi; }
deleted() { grep -c "^delete " "$T/log"; }
del_of() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["devices"]; print(next(x["udid"] for v in d.values() for x in v if x["name"]==sys.argv[2]))' "$T/devices.json" "$1"; }
was_deleted() { grep -q "^delete $(del_of "$1")$" "$T/log"; }
# A job waits behind every live ticket, so the job tests drop the waiting one.
job() { rm -f "$XQ_DIR/queue/000-1"; timeout 60 "$XQ" "$@"; }

# name, device, runtime, state, last used (hours ago; "" = never and no file to date it), extra
fixture() {
  python3 - "$T" <<'P'
import json, os, sys, time
from datetime import datetime, timezone
t = sys.argv[1]
RT = "com.apple.CoreSimulator.SimRuntime.iOS-26-4"; PRO = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
SE = "com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
sims = [  # name, device, runtime, state, hours since last use (None: never booted, no device.plist)
    ("xq-ru7gate-1", PRO, RT, "Shutdown", 72), ("xq-ru7gate-2", PRO, RT, "Shutdown", 72),
    ("xq-ru7gate-b-1", PRO, RT, "Shutdown", 72), ("xq-oldtag", PRO, RT, "Shutdown", 100),
    ("xq-recent-1", PRO, RT, "Shutdown", 1),             # used an hour ago
    ("xq-booted-1", PRO, RT, "Booted", 72),              # booted
    ("xq-fulltest-1", PRO, RT, "Shutdown", 200), ("xq-fulltest-b-1", PRO, RT, "Shutdown", 200),
    ("xq-tf-g9", PRO, RT, "Shutdown", 200), ("xq-shots-std", PRO, RT, "Shutdown", 200),
    ("xq-ftime-se", PRO, RT, "Shutdown", 200), ("xq-freelooks", PRO, RT, "Shutdown", 200),
    ("xq-cbtwo-se", SE, RT, "Shutdown", 200),            # another device type: made on purpose
    ("xq-ios27", PRO, "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "Shutdown", 200),
    ("xq-l10n253-02", PRO, RT, "Shutdown", 200),         # named in the keep file
    ("xq-busy-1", PRO, RT, "Shutdown", 200),             # its session holds a slot
    ("xq-waiting", PRO, RT, "Shutdown", 200),            # its session waits for a slot
    ("xq-noage", PRO, RT, "Shutdown", None),             # no date at all
    ("xq-nevbooted", PRO, RT, "Shutdown", "plist"),      # never booted, device.plist is 4 days old
    ("other-sim", PRO, RT, "Shutdown", 200),             # not xq's
]
devs = {}
for i, (n, dt, rt, st, h) in enumerate(sims):
    u = f"{i:08X}-0000-0000-0000-000000000000"
    d = {"name": n, "udid": u, "deviceTypeIdentifier": dt, "state": st, "isAvailable": True,
         "dataPath": f"{t}/devices/{u}/data", "dataPathSize": 2_000_000_000}
    if isinstance(h, int):
        d["lastUsedAt"] = datetime.fromtimestamp(time.time() - h * 3600, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    elif h == "plist":
        os.makedirs(f"{t}/devices/{u}", exist_ok=True)
        p = f"{t}/devices/{u}/device.plist"; open(p, "w").close(); os.utime(p, (time.time() - 96 * 3600,) * 2)
    devs.setdefault(rt, []).append(d)
json.dump({"devices": devs}, open(f"{t}/devices.json", "w"))
P
}
reset() {
  rm -rf "$XQ_DIR" "$T/devices"; : > "$T/log"; mkdir -p "$XQ_DIR/slots/1" "$XQ_DIR/queue"
  fixture
  echo "$$ $(date +%s) busy true" > "$XQ_DIR/slots/1/info"         # this shell is the live holder
  echo "$$ waiting" > "$XQ_DIR/queue/000-1"
  printf '# kept for a re-check\nxq-l10n253-02   # iOS 27 sheet\n' > "$XQ_KEEP_FILE"
  echo 200 > "$T/free"
}
EXPECT="xq-nevbooted xq-oldtag xq-ru7gate-1 xq-ru7gate-2 xq-ru7gate-b-1"

reset; "$XQ" prune --dry-run > "$T/out" 2>&1
got=$(awk '/would delete xq-/{print $3}' "$T/out" | sort | tr '\n' ' ')
check "dry run lists only old, shut-down run simulators" '[ "$got" = "$EXPECT " ]'
check "dry run deletes nothing" '[ "$(deleted)" = 0 ]'
check "dry run sums the size" 'grep -q "would delete 5 simulator(s) unused for 2d, 10.0 GB" "$T/out"'

reset; "$XQ" prune > "$T/out" 2>&1
check "prune deletes exactly the dry run's list" '[ "$(deleted)" = 5 ] && for n in $EXPECT; do was_deleted $n || exit 1; done'
check "prune never touches a booted simulator" '! grep -q "^shutdown" "$T/log"'
# The list said Shutdown, but it was booted by the time of the delete.
reset; cat > "$T/bin/python3" <<'S'
#!/bin/bash
/usr/bin/python3 "$@"; rc=$?
sed -i 's/"name": "xq-oldtag", \("udid": "[^"]*", "deviceTypeIdentifier": "[^"]*", "state": "\)Shutdown/"name": "xq-oldtag", \1Booted/' "$STUB/devices.json"
exit $rc
S
chmod +x "$T/bin/python3"; XQ_PY=$T/bin/python3 "$XQ" prune > "$T/out" 2>&1; rm -f "$T/bin/python3"
check "prune skips a simulator booted after the list was made" '! was_deleted xq-oldtag && was_deleted xq-ru7gate-1'

reset; "$XQ" prune > "$T/out" 2>&1
check "prune leaves no lock behind" '[ ! -e "$XQ_DIR/.prune" ]'

reset; mkdir -p "$XQ_DIR/seen"; touch "$XQ_DIR/seen/oldtag"; "$XQ" prune --dry-run > "$T/out" 2>&1
check "a recent xq sim of that name keeps it" '! grep -q "would delete xq-oldtag " "$T/out"'

reset; "$XQ" prune --older-than 30m --dry-run > "$T/out" 2>&1
check "--older-than 30m also takes the one used an hour ago" 'grep -q "would delete xq-recent-1 " "$T/out"'

reset; "$XQ" prune --older-than 5d --dry-run > "$T/out" 2>&1
check "--older-than 5d keeps the 4-day-old ones" 'grep -q "would delete 0 simulator" "$T/out"'

reset; "$XQ" prune --older-than 2x > "$T/out" 2>&1; rc=$?
check "a bad --older-than is refused" '[ $rc -ne 0 ] && [ "$(deleted)" = 0 ]'

reset; mkdir "$XQ_DIR/.prune"; "$XQ" prune > "$T/out" 2>&1
check "a second prune at once does nothing" '[ "$(deleted)" = 0 ] && grep -q "another prune" "$T/out"'

reset; "$XQ" drop ru7gate > "$T/out" 2>&1
check "drop deletes the run's numbered simulators only" '[ "$(deleted)" = 2 ] && was_deleted xq-ru7gate-1 && was_deleted xq-ru7gate-2'
reset; "$XQ" drop ru7gate-b > "$T/out" 2>&1
check "drop of <session>-b takes the second Mac's shards" '[ "$(deleted)" = 1 ] && was_deleted xq-ru7gate-b-1'
reset; "$XQ" drop booted > "$T/out" 2>&1
check "drop shuts a still-booted simulator down first" 'grep -q "^shutdown $(del_of xq-booted-1)$" "$T/log" && was_deleted xq-booted-1'
reset; "$XQ" drop fulltest > "$T/out" 2>&1
check "drop never takes the fulltest pool" '[ "$(deleted)" = 0 ]'
reset; "$XQ" drop busy > "$T/out" 2>&1
check "drop skips a session that still holds a slot" '[ "$(deleted)" = 0 ]'

reset; echo 12 > "$T/free"; job s -- true > "$T/out" 2>&1
check "low disk: a job warns and prunes before it runs" 'grep -q "WARNING only 12 GB free" "$T/out" && [ "$(deleted)" -ge 1 ]'
check "low disk: prune keeps what was used in the last 3 h" '! was_deleted xq-recent-1'
reset; echo 12 > "$T/free"; XQ_LOW_AGE=bogus job s -- bash -c 'cat "$XQ_DIR/slots/$XQ_SLOT/info"' > "$T/out" 2>&1; rc=$?
check "a failing disk check doesn't stop the job or lose its slot" '[ $rc -eq 0 ] && grep -q "^[0-9]* [0-9]* s bash" "$T/out"'
reset; echo 200 > "$T/free"; job s -- true > "$T/out" 2>&1
check "enough disk: no warning, nothing deleted" '! grep -q WARNING "$T/out" && [ "$(deleted)" = 0 ]'

reset; "$XQ" --help > "$T/out" 2>&1
check "help lists prune and drop" 'grep -q "xq prune" "$T/out" && grep -q "xq drop" "$T/out" && ! grep -q "Stale jobs" "$T/out"'

echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
