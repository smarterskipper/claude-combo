#!/bin/sh
# Creates a lane: branch lane/<name> from the integration branch, worktree .worktrees/<name>, and a .lane.env with its port. Run: sh tools/lanes/new-lane.sh <name> <port>
set -eu
name=${1:?usage: new-lane.sh <name> <port>}; port=${2:?usage: new-lane.sh <name> <port>}
INT=${INT_BRANCH:-integration}
common=$(cd "$(git rev-parse --git-common-dir)" && pwd)
main=$(dirname "$common")
wt="$main/.worktrees/$name"
if grep -qx "LANE_PORT=$port" "$main"/.worktrees/*/.lane.env 2>/dev/null; then
  echo "port $port is already used by another lane"; exit 1
fi
git worktree add -b "lane/$name" "$wt" "$INT"
cat > "$wt/.lane.env" <<EOF
LANE=$name
LANE_PORT=$port
COMPOSE_PROJECT_NAME=lane_$name
DB_NAME=app_lane_$name
SHOTS_DIR=tools/lanes/out/shots
EOF
# ===== STACK: dependency setup for the new worktree (section 8) =====
# React (pnpm): (cd "$wt" && pnpm install --frozen-lockfile)
# .NET:         (cd "$wt" && dotnet restore --locked-mode)
# Unity:        cp -cR "$main/.worktrees/integration/<UnityProject>/Library" "$wt/<UnityProject>/Library"   # macOS clonefile
echo "$wt"
