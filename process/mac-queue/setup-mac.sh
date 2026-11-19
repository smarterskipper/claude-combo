#!/bin/bash
# setup-mac.sh <alias> <step> - brings a new build Mac in line with the MacBook, run from ubuntu-pc.
# Steps (each is safe to re-run):
#   check   what's there: macOS, Xcode, brew, GitHub sign-in, disk, sleep settings, simulator runtimes
#   tools   copies ~/bin/ci and ~/ci/README.md from the MacBook, then installs xq (the xq step)
#   xq      installs this folder's mac-xq as ~/bin/xq, keeping the Mac's slot count; the old one stays as a backup
#   xcode   streams /Applications/Xcode.app from the MacBook (no Apple ID needed; needs a person for sudo after)
#   runtimes  downloads the iOS and watchOS simulators (needs the Xcode license accepted first)
#   brew    installs the build tools the gates use
#   ci      creates ~/ci/<repo> with remote and keep.list. Add --secrets to also copy secrets/ Mac to Mac
#   sims    creates every xq-* simulator the MacBook has, same name and device type
#   warm    boots each xq-* iPhone simulator that has never booted, once, through the Mac's queue
# A step that needs a person (sudo, GitHub sign-in) says so. Only `xq` run for the MacBook itself writes to it.
set -u -o pipefail
M=${1:-}; STEP=${2:-}; [ -n "$M" ] && [ -n "$STEP" ] || { sed -n '2,13p' "$0"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${XQ_SRC_MAC:-macbook}
SLOTS=${XQ_NEW_SLOTS:-1}
TOOLS="xcodegen gh node"
SSHO=(-o BatchMode=yes -o ConnectTimeout=8)
on() { ssh "${SSHO[@]}" "$M" "$@"; }
src() { ssh "${SSHO[@]}" "$SRC" "$@"; }
BREW='eval "$(/opt/homebrew/bin/brew shellenv)"'

step_check() {
  on 'bash -s' <<'R'
echo "user:     $(whoami)   host: $(hostname)"
echo "macOS:    $(sw_vers -productVersion)   model: $(sysctl -n hw.model)   cores: $(sysctl -n hw.ncpu)   RAM GB: $(( $(sysctl -n hw.memsize) / 1073741824 ))"
echo "disk:     $(df -g ~ | awk 'NR==2{print $4" GB free of "$2}')"
echo "xcode:    $(xcodebuild -version 2>&1 | tr '\n' ' ')"
echo "selected: $(xcode-select -p 2>&1)   app: $(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')"
echo "brew:     $(ls /opt/homebrew/bin/brew 2>/dev/null || echo none)"
if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; echo "tools:    $(command -v xcodegen gh node | tr '\n' ' ')"; gh auth status 2>&1 | sed -n 2p; fi
echo "runtimes: $(xcrun simctl list runtimes 2>/dev/null | grep -c -E '^iOS') iOS, $(xcrun simctl list runtimes 2>/dev/null | grep -c -E '^watchOS') watchOS"
echo "sleep:    $(pmset -g | awk '/^ *(sleep|womp|autorestart) /{printf "%s=%s ", $1, $2}')"
echo "xq:       $(ls ~/bin/xq ~/bin/ci 2>/dev/null | tr '\n' ' ')"
R
}

step_tools() {
  local t; t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
  if [ "$M" != "$SRC" ]; then
    scp -q "${SSHO[@]}" "$SRC:bin/ci" "$SRC:ci/README.md" "$t/" || return 1
    on 'mkdir -p ~/bin ~/ci' && scp -q "${SSHO[@]}" "$t/ci" "$M:bin/" && scp -q "${SSHO[@]}" "$t/README.md" "$M:ci/README.md" &&
      on 'chmod +x ~/bin/ci' || return 1
  fi
  step_xq
}

# The Mac's own queue. Its slot count stays: the SLOTS= line is also what ubuntu-pc's xq reads. A new Mac gets
# XQ_NEW_SLOTS. The new copy is checked on the Mac (macOS bash is 3.2) and then renamed over the old one, so a
# job starting meanwhile reads either the old file or the new one.
step_xq() {
  local t n; t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
  # A failed read must not reset a Mac to XQ_NEW_SLOTS, so only a Mac with no ~/bin/xq gets that.
  if on '[ -e ~/bin/xq ]'; then
    n=$(on 'cat ~/bin/xq' | sed -nE 's/.*SLOTS=\$\{XQ_(MAC_)?SLOTS:-([0-9]+)\}.*/\2/p' | head -1)
    [ -n "$n" ] || { echo "could not read $M's slot count; nothing installed"; return 1; }
  else
    on true || { echo "$M is unreachable"; return 1; }
    n=$SLOTS
  fi
  sed -E "s/SLOTS=\\\$\{XQ_MAC_SLOTS:-[0-9]+\}/SLOTS=\${XQ_MAC_SLOTS:-$n}/" "$HERE/mac-xq" > "$t/xq"
  grep -q "SLOTS=\${XQ_MAC_SLOTS:-$n}" "$t/xq" || { echo "setting the slot count failed: mac-xq changed shape"; return 1; }
  sed -i "/^set -u$/i # This Mac's copy, from claude-combo process/mac-queue/mac-xq on $(date +%F): $n slot(s)." "$t/xq"
  bash -n "$t/xq" || return 1
  on 'mkdir -p ~/bin' && scp -q "${SSHO[@]}" "$t/xq" "$M:bin/.xq.new" || return 1
  on "chmod +x ~/bin/.xq.new && /bin/bash -n ~/bin/.xq.new && ~/bin/.xq.new status >/dev/null &&
      { [ ! -e ~/bin/xq ] || cp -p ~/bin/xq ~/bin/xq.bak-$(date +%Y%m%d-%H%M%S); } && mv ~/bin/.xq.new ~/bin/xq &&
      ~/bin/xq status | sed '/^sims:/,\$d'" || { echo "installing xq on $M failed; the old copy is still in place"; return 1; }
}

step_xcode() {
  if on '[ -d /Applications/Xcode.app ]'; then echo "Xcode.app is already there: $(on 'xcodebuild -version 2>&1 | tr "\n" " "')"; return 0; fi
  on '[ -w /Applications ]' || { echo "$M: this user can't write to /Applications (needs an admin user)"; return 1; }
  echo "streaming Xcode.app from $SRC"
  # Into a side folder first, so a dropped stream can't leave a half Xcode that a re-run would accept.
  src 'tar -C /Applications -cf - Xcode.app' | on 'rm -rf /Applications/.xcode-partial && mkdir /Applications/.xcode-partial && tar -C /Applications/.xcode-partial -xf -' &&
    on 'mv /Applications/.xcode-partial/Xcode.app /Applications/Xcode.app && rmdir /Applications/.xcode-partial && (xattr -dr com.apple.quarantine /Applications/Xcode.app 2>/dev/null; du -sh /Applications/Xcode.app)' ||
    { echo "copying Xcode failed; re-run this step"; return 1; }
  echo "A person now runs on $M: sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch"
}

step_runtimes() {
  on 'xcodebuild -downloadPlatform iOS 2>&1 | tail -1; xcodebuild -downloadPlatform watchOS 2>&1 | tail -1; xcrun simctl list runtimes'
}

step_brew() {
  on '[ -x /opt/homebrew/bin/brew ]' || { echo "$M: Homebrew isn't installed; it needs a person (sudo)"; return 1; }
  on "$BREW; brew install $TOOLS 2>&1 | tail -3"
}

step_ci() {
  local r
  for r in menos-ios north-ios; do
    on "mkdir -p ~/ci/$r"
    src "cd ~/ci/$r && tar -cf - \$(ls remote keep.list 2>/dev/null)" | on "tar -C ~/ci/$r -xf -"
    if [ "${1:-}" = --secrets ] && src "[ -d ~/ci/$r/secrets ]"; then
      src "tar -C ~/ci/$r -cf - secrets" | on "tar -C ~/ci/$r -xf - && chmod 700 ~/ci/$r/secrets"
      echo "$r: secrets copied Mac to Mac"
    fi
  done
}

step_sims() {
  src 'xcrun simctl list devices -j' | python3 -c '
import json,sys
for rt,devs in json.load(sys.stdin)["devices"].items():
    for d in devs:
        if d["name"].startswith("xq-") and not d["name"].startswith("xq-pool-") and d["isAvailable"]:
            print(d["name"],d["deviceTypeIdentifier"],rt)' > /tmp/xq-sims.$$
  on 'bash -s' < <(echo 'have=$(xcrun simctl list devices)'; while read -r n t r; do
    echo "grep -q -- ' $n (' <<<\"\$have\" || xcrun simctl create '$n' '$t' '$r' >/dev/null && echo '$n'"
  done < /tmp/xq-sims.$$) | wc -l > /tmp/xq-sims-made.$$
  want=$(wc -l < /tmp/xq-sims.$$); made=$(cat /tmp/xq-sims-made.$$); rm -f /tmp/xq-sims.$$ /tmp/xq-sims-made.$$
  echo "$made of $want xq simulators present or created"; [ "$made" = "$want" ]
}

# A simulator's first boot shows system banners ("Ready for Apple Intelligence") that land on top of screenshots, and
# they don't come back on later boots. So every xq-* iPhone gets its first boot here, 4 at a time, instead of in a gate.
step_warm() {
  on 'cat > /tmp/xq-sim-warm.sh' <<'EOF'
list=$(xcrun simctl list devices -j | /usr/bin/python3 -c '
import json,sys
for rt,devs in json.load(sys.stdin)["devices"].items():
    if ".iOS-" in rt:
        for d in devs:
            if d["name"].startswith("xq-") and d["isAvailable"] and d["state"]=="Shutdown" and not (d.get("lastUsedAt") or d.get("lastBootedAt")):
                print(d["udid"])')
warm() {
  for u; do xcrun simctl boot "$u"; done
  for u; do xcrun simctl bootstatus "$u" -b >/dev/null; done
  sleep 60
  for u; do xcrun simctl shutdown "$u"; done
  echo "warmed $#"
}
set --
for u in $list; do
  set -- "$@" "$u"
  if [ $# -eq 4 ]; then warm "$@"; set --; fi
done
[ $# -eq 0 ] || warm "$@"
EOF
  on '~/bin/xq sim-warm -- bash /tmp/xq-sim-warm.sh'
}

case "$STEP" in
  check|tools|xq|xcode|runtimes|brew|sims|warm) "step_$STEP" ;;
  ci) step_ci "${3:-}" ;;
  *) sed -n '2,13p' "$0"; exit 1 ;;
esac
