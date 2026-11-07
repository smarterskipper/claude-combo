#!/bin/bash
# setup-mac.sh <alias> <step> - brings a new build Mac in line with the MacBook, run from ubuntu-pc.
# Steps (each is safe to re-run):
#   check   what's there: macOS, Xcode, brew, GitHub sign-in, disk, sleep settings, simulator runtimes
#   tools   copies ~/bin/xq, ~/bin/ci and ~/ci/README.md from the MacBook, then patches this Mac's xq copy
#   xcode   streams /Applications/Xcode.app from the MacBook (no Apple ID needed; needs a person for sudo after)
#   runtimes  downloads the iOS and watchOS simulators (needs the Xcode license accepted first)
#   brew    installs the build tools the gates use
#   ci      creates ~/ci/<repo> with remote and keep.list. Add --secrets to also copy secrets/ Mac to Mac
#   sims    creates every xq-* simulator the MacBook has, same name and device type
# A step that needs a person (sudo, GitHub sign-in) says so. Nothing here touches the MacBook except reads.
set -u -o pipefail
M=${1:-}; STEP=${2:-}; [ -n "$M" ] && [ -n "$STEP" ] || { sed -n '2,11p' "$0"; exit 1; }
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
  scp -q "${SSHO[@]}" "$SRC:bin/xq" "$SRC:bin/ci" "$SRC:ci/README.md" "$t/" || return 1
  # Slots: the gate scripts set XQ_SLOTS=2 for the MacBook, so this Mac reads its own variable instead.
  # Watcher: its `sleep` otherwise keeps the job's stderr open, and ssh stays connected up to 60 s after the job ends.
  sed -E -i "s/SLOTS=\\\$\{XQ_SLOTS:-[0-9]+\}/SLOTS=\${XQ_MAC_SLOTS:-$SLOTS}/; s/^( *)watch_job \\\$\\\$ \"\\\$SLOT\" & WATCH=\\\$!/\1watch_job \$\$ \"\$SLOT\" <\/dev\/null >\/dev\/null 2>\&1 \& WATCH=\$!/" "$t/xq"
  grep -q "XQ_MAC_SLOTS:-$SLOTS" "$t/xq" && grep -q 'watch_job $$ "$SLOT" </dev/null' "$t/xq" || { echo "patching xq failed: the MacBook's copy changed shape"; return 1; }
  sed -i "2a # This Mac's copy (from the MacBook on $(date +%F)): $SLOTS slot(s) via XQ_MAC_SLOTS, watcher detached from stderr." "$t/xq"
  bash -n "$t/xq" || return 1
  on 'mkdir -p ~/bin ~/ci' && scp -q "${SSHO[@]}" "$t/xq" "$t/ci" "$M:bin/" && scp -q "${SSHO[@]}" "$t/README.md" "$M:ci/README.md" && on 'chmod +x ~/bin/xq ~/bin/ci && ~/bin/xq status | sed "/^sims:/,\$d"'
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
        if d["name"].startswith("xq-") and d["isAvailable"]:
            print(d["name"],d["deviceTypeIdentifier"],rt)' > /tmp/xq-sims.$$
  on 'bash -s' < <(echo 'have=$(xcrun simctl list devices)'; while read -r n t r; do
    echo "grep -q -- ' $n (' <<<\"\$have\" || xcrun simctl create '$n' '$t' '$r' >/dev/null && echo '$n'"
  done < /tmp/xq-sims.$$) | wc -l > /tmp/xq-sims-made.$$
  want=$(wc -l < /tmp/xq-sims.$$); made=$(cat /tmp/xq-sims-made.$$); rm -f /tmp/xq-sims.$$ /tmp/xq-sims-made.$$
  echo "$made of $want xq simulators present or created"; [ "$made" = "$want" ]
}

case "$STEP" in
  check|tools|xcode|runtimes|brew|sims) "step_$STEP" ;;
  ci) step_ci "${3:-}" ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
