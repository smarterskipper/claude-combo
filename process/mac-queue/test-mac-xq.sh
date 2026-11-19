#!/bin/bash
# Tests for the Mac-side xq's simulator cleanup (prune, drop, the low-disk check), against a stub xcrun and df.
# shellcheck disable=SC2016,SC2034  # checks are eval'd strings
# No Mac and no real simulator is touched. Run: bash test-mac-xq.sh
HERE=$(cd "$(dirname "$0")" && pwd); XQ=$HERE/mac-xq
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
export PATH="$T/bin:$PATH" XQ_DIR=$T/q XQ_KEEP_FILE=$T/keep-sims XQ_PY=python3 XQ_DROP_WAIT=1 STUB=$T XQ_SIM_HOME=$T/devices
cat > "$T/bin/xcrun" <<'S'
#!/usr/bin/env python3
# Stub simctl over $STUB/devices.json. Logs what changes a simulator to $STUB/log. A deleted one is hidden.
import json, os, sys, uuid
st = os.environ["STUB"]; db = f"{st}/devices.json"; a = sys.argv[1:]
if a[0] != "simctl": sys.exit(1)
devs = json.load(open(db)); cmd = a[1]
def log(line): open(f"{st}/log", "a").write(line + "\n")
def save(): json.dump(devs, open(db, "w"))
def find(u): return next(d for v in devs["devices"].values() for d in v if d["udid"] == u and not d.get("deleted"))
def apps(u):
    p = f"{st}/apps/{u}"
    return [l for l in open(p).read().split() if l] if os.path.exists(p) else []
if cmd == "list":
    live = {rt: [d for d in v if not d.get("deleted")] for rt, v in devs["devices"].items()}
    if len(a) > 3 and a[3] == "-j": print(json.dumps({"devices": live}))
    else:
        for v in live.values():
            for d in v: print("    %s (%s) (%s)" % (d["name"], d["udid"], d["state"]))
elif cmd == "create":
    u = str(uuid.uuid4()).upper()
    devs["devices"].setdefault(a[4], []).append({"name": a[2], "udid": u, "state": "Shutdown", "isAvailable": True,
        "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType." + a[3].replace(" ", "-"),
        "dataPath": f"{st}/devices/{u}/data", "dataPathSize": 0})
    save(); log(f"create {a[2]}"); print(u)
elif cmd == "bootstatus": find(a[2])["state"] = "Booted"; save(); log(f"boot {a[2]}")
elif cmd == "shutdown": find(a[2])["state"] = "Shutdown"; save(); log(f"shutdown {a[2]}")
elif cmd == "delete": find(a[2])["deleted"] = True; save(); log(f"delete {a[2]}")
elif cmd == "listapps":
    if os.path.exists(f"{st}/listapps-fail"): sys.exit(1)
    out = {"com.apple.Preferences": {"ApplicationType": "System"}}
    out.update({b: {"ApplicationType": "User"} for b in apps(a[2])})
    print(json.dumps(out))
elif cmd == "uninstall":
    log(f"uninstall {a[2]} {a[3]}")
    if not os.path.exists(f"{st}/uninstall-noop"):
        open(f"{st}/apps/{a[2]}", "w").write("\n".join(x for x in apps(a[2]) if x != a[3]))
elif cmd in ("keychain", "privacy", "pbcopy", "erase"): log(f"{cmd} {a[2]}")
elif cmd == "spawn": pass
else: sys.exit(1)
S
cat > "$T/bin/plutil" <<'S'
#!/bin/bash
cat
S
cat > "$T/bin/sqlite3" <<'S'
#!/bin/bash
t=${2##* }; cat "$STUB/count.$t" 2>/dev/null || echo 0
S
cat > "$T/bin/df" <<'S'
#!/bin/bash
echo "Filesystem 1G-blocks Used Available Capacity Mounted"
echo "/dev/disk3s5 460 400 $(cat "$STUB/free") 90% /"
S
chmod +x "$T/bin/xcrun" "$T/bin/df" "$T/bin/plutil" "$T/bin/sqlite3"
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

# --- xq test's simulator pool ---
# An empty Mac apart from one ordinary booted simulator whose session holds no slot.
pool_reset() {
  rm -rf "$XQ_DIR" "$T/devices" "$T/apps" "$T/listapps-fail" "$T/uninstall-noop" "$T"/count.*; : > "$T/log"
  mkdir -p "$XQ_DIR/slots" "$XQ_DIR/queue" "$T/apps"; : > "$XQ_KEEP_FILE"; echo 200 > "$T/free"
  python3 -c 'import json,sys; json.dump({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-4": [
    {"name": "xq-idle-1", "udid": "00000001-0000-0000-0000-000000000000", "state": "Booted", "isAvailable": True,
     "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}]}}, open(sys.argv[1], "w"))' "$T/devices.json"
}
udid_of() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["devices"]; print(next(x["udid"] for v in d.values() for x in v if x["name"]==sys.argv[2] and not x.get("deleted")))' "$T/devices.json" "$1" 2>/dev/null; }
state_of() { "$T/bin/xcrun" simctl list devices | sed -nE "s/^ +$1 \(.*\) \((.*)\)/\1/p"; }
dead_pid() { sh -c 'exit 0' & wait $!; echo $!; }
creates() { grep -c "^create " "$T/log"; }

pool_reset; "$XQ" lease scrap-06 2 $$ > "$T/out" 2>&1
check "lease on an empty pool makes the simulators" '[ "$(cat "$T/out")" = "$(printf "pool-1 new\npool-2 new")" ] && [ "$(creates)" = 2 ]'
"$XQ" lease scrap-07 2 $$ > "$T/out" 2>&1
check "a live lease is not handed out again" '[ "$(cat "$T/out")" = "$(printf "pool-3 new\npool-4 new")" ]'
"$XQ" unlease $$ pool-1 pool-2; : > "$T/log"; "$XQ" lease scrap-08 1 $$ > "$T/out" 2>&1
check "a handed-back simulator is reused, nothing is made" '[ "$(cat "$T/out")" = "pool-1 cold" ] && [ "$(creates)" = 0 ]'

pool_reset; XQ_POOL_MAX=3 "$XQ" lease a 2 $$ >/dev/null 2>&1; XQ_POOL_MAX=3 "$XQ" lease b 2 $$ > "$T/out" 2>&1
check "a full pool gives fewer than asked (the worker makes the rest itself)" '[ "$(cat "$T/out")" = "pool-3 new" ]'

pool_reset; "$XQ" lease a 1 "$(dead_pid)" >/dev/null 2>&1; : > "$T/log"; "$XQ" lease b 1 $$ > "$T/out" 2>&1
check "a dead job's lease ends by itself" '[ "$(cat "$T/out")" = "pool-1 cold" ] && [ "$(creates)" = 0 ]'
pool_reset; "$XQ" lease a 1 $$ >/dev/null 2>&1; echo "$$ $(( $(date +%s) - 9999 )) a" > "$XQ_DIR/pool/pool-1"; "$XQ" lease b 1 $$ > "$T/out" 2>&1
check "an over-time lease ends by itself" '[ "$(cat "$T/out")" = "pool-1 cold" ]'
pool_reset; "$XQ" lease a 1 $$ >/dev/null 2>&1; "$XQ" unlease 1 pool-1
check "unlease leaves another pid's lease alone" '[ -e "$XQ_DIR/pool/pool-1" ]'

pool_reset; "$XQ" lease fulltest 2 $$ > "$T/out" 2>&1
check "a long-lived name gets no pool simulators" '[ ! -s "$T/out" ] && [ "$(creates)" = 0 ]'
pool_reset; echo "xq-mine-*" > "$XQ_KEEP_FILE"; "$XQ" lease mine 2 $$ > "$T/out" 2>&1
check "neither does a name in keep-sims" '[ ! -s "$T/out" ]'
pool_reset; "$XQ" lease pool 1 $$ > "$T/out" 2>&1; rc=$?
check "pool is not a session name" '[ $rc -ne 0 ] && [ "$(creates)" = 0 ]'
pool_reset; "$XQ" drop pool > "$T/out" 2>&1; rc=$?
check "xq drop pool is refused" '[ $rc -ne 0 ]'

pool_reset; "$XQ" lease a 1 $$ >/dev/null 2>&1; u=$(udid_of xq-pool-1)
printf 'com.x.game\ncom.x.gameUITests.xctrunner\n' > "$T/apps/$u"; mkdir -p "$T/devices/$u"; touch "$T/devices/$u/xq-wiped"
"$XQ" ready pool-1 > "$T/out" 2>&1; rc=$?
check "ready boots it and prints its id" '[ $rc -eq 0 ] && [ "$(tail -1 "$T/out")" = "$u" ] && grep -q "^boot $u" "$T/log"'
check "ready uninstalls every user app, the test runner too" 'grep -q "^uninstall $u com.x.game$" "$T/log" && grep -q "^uninstall $u com.x.gameUITests.xctrunner$" "$T/log" && ! grep -q Preferences "$T/log"'
check "ready resets the keychain, permissions and pasteboard" 'grep -q "^keychain $u" "$T/log" && grep -q "^privacy $u" "$T/log" && grep -q "^pbcopy $u" "$T/log"'
check "a plain wipe erases nothing" '! grep -q "^erase" "$T/log"'

pool_reset; "$XQ" lease a 1 $$ >/dev/null 2>&1; u=$(udid_of xq-pool-1); echo com.x.game > "$T/apps/$u"; touch "$T/uninstall-noop"
"$XQ" ready pool-1 > "$T/out" 2>&1; rc=$?
check "an app that won't uninstall: the simulator is deleted, not handed out" '[ $rc -ne 0 ] && grep -q "^delete $u" "$T/log" && [ ! -e "$XQ_DIR/pool/pool-1" ]'
pool_reset; "$XQ" lease a 1 $$ >/dev/null 2>&1; u=$(udid_of xq-pool-1); touch "$T/listapps-fail"
"$XQ" ready pool-1 > "$T/out" 2>&1; rc=$?
check "an app list it can't read: deleted too" '[ $rc -ne 0 ] && grep -q "^delete $u" "$T/log"'

pool_reset; "$XQ" lease a 1 $$ >/dev/null 2>&1; u=$(udid_of xq-pool-1); d=$T/devices/$u
mkdir -p "$d/data/Media/DCIM/100APPLE" "$d/data/Library/AddressBook"; touch "$d/data/Media/DCIM/100APPLE/IMG_0001.JPG"
touch "$d/data/Library/AddressBook/AddressBook.sqlitedb"; echo 6 > "$T/count.ABPerson"
"$XQ" ready pool-1 > "$T/out" 2>&1
check "the wipe keeps the photo, contact and Health counts" '[ "$(cat "$d/xq-wiped")" = "photos=1 contacts=6 health=0" ]'
: > "$T/log"; touch "$d/data/Library/AddressBook/AddressBook.sqlitedb"; "$XQ" ready pool-1 > "$T/out" 2>&1
check "databases written to but no new photos or contacts: no erase" '! grep -q "^erase" "$T/log" && grep -q "^keychain" "$T/log"'
touch "$d/data/Media/DCIM/100APPLE/IMG_0002.JPG"; : > "$T/log"; "$XQ" ready pool-1 > "$T/out" 2>&1; rc=$?
check "a run that added a photo gets an erase" '[ $rc -eq 0 ] && grep -q "^erase $u" "$T/log" && grep -q "^boot $u" "$T/log" && ! grep -q "^keychain" "$T/log"'
echo 7 > "$T/count.ABPerson"; : > "$T/log"; "$XQ" ready pool-1 > "$T/out" 2>&1
check "so does one that added a contact" 'grep -q "^erase $u" "$T/log"'
pool_reset; "$XQ" ready pool-1 > "$T/out" 2>&1; rc=$?
check "ready of an unleased simulator is refused" '[ $rc -ne 0 ]'

# Slot grab: an ordinary idle simulator is shut down, a free pool one stays booted until it's idle for 2 h.
pool_reset; "$XQ" lease a 3 $$ >/dev/null 2>&1; for k in 1 2 3; do "$XQ" ready pool-$k >/dev/null 2>&1; done
"$XQ" unlease $$ pool-1 pool-2; touch -d '3 hours ago' "$XQ_DIR/seen/pool-2"; touch -d '3 hours ago' "$XQ_DIR/seen/pool-3"
: > "$T/log"; job s -- true > "$T/out" 2>&1
check "slot grab still shuts down an idle session's simulator" '[ "$(state_of xq-idle-1)" = Shutdown ]'
check "slot grab leaves a free pool simulator booted" '[ "$(state_of xq-pool-1)" = Booted ]'
check "a pool simulator unused for 2 h is shut down" '[ "$(state_of xq-pool-2)" = Shutdown ]'
check "a leased pool simulator stays booted, however old" '[ "$(state_of xq-pool-3)" = Booted ]'
"$XQ" gc > "$T/out" 2>&1
check "gc follows the same rule" '[ "$(state_of xq-pool-1)" = Booted ] && [ "$(state_of xq-pool-3)" = Booted ]'

# prune: a shut-down pool simulator unused for 2 days goes like any run simulator; a leased one stays.
pool_reset; "$XQ" lease a 2 $$ >/dev/null 2>&1; "$XQ" unlease $$ pool-1
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p))
for v in d["devices"].values():
    for x in v: x["lastUsedAt"] = "2020-01-01T00:00:00Z"
json.dump(d, open(p, "w"))' "$T/devices.json"
touch -d "3 days ago" "$XQ_DIR/seen/pool-1"; u1=$(udid_of xq-pool-1); u2=$(udid_of xq-pool-2); "$XQ" prune > "$T/out" 2>&1
check "prune deletes an old shut-down pool simulator" 'grep -q "^delete $u1" "$T/log"'
check "prune leaves a leased one" '! grep -q "^delete $u2" "$T/log"'
check "prune leaves the lock free" '[ ! -d "$XQ_DIR/.lock" ]'

reset; "$XQ" --help > "$T/out" 2>&1
check "help lists prune and drop" 'grep -q "xq prune" "$T/out" && grep -q "xq drop" "$T/out" && ! grep -q "Stale jobs" "$T/out"'

echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
