#!/bin/sh
# Fails if the staged change breaks the commit budget: symlinks, dependency/build folders, unaccepted snapshot output, or an evidence record over 60 files / 2 MB. Run before every lane commit: sh tools/lanes/check-staged.sh
fail=0
links=$(git diff --cached --raw --no-abbrev --diff-filter=AM | awk '$2 == "120000" {print $NF}')
[ -n "$links" ] && { echo "symlinks staged:"; echo "$links"; fail=1; }
bad=$(git diff --cached --name-only --diff-filter=AM | grep -E '(^|/)(node_modules|bin|obj|Library|Temp|Logs|UserSettings|\.next|tools/lanes/out|tools/gallery/out)/|\.received\.|-actual\.png$|-diff\.png$')
[ -n "$bad" ] && { echo "forbidden paths staged:"; echo "$bad" | head -20; fail=1; }
n=$(git diff --cached --name-only --diff-filter=AM -- tools/lanes/evidence | wc -l | tr -d ' ')
bytes=$(git diff --cached --raw --no-abbrev --diff-filter=AM -- tools/lanes/evidence | awk '{print $4}' | git cat-file --batch-check='%(objectsize)' | awk '{s+=$1} END {print s+0}')
[ "$n" -gt 60 ] && { echo "evidence has $n files (limit 60)"; fail=1; }
[ "$bytes" -gt 2097152 ] && { echo "evidence is $bytes bytes (limit 2 MB)"; fail=1; }
git diff --cached --stat | tail -1
[ $fail = 0 ] && echo "staged OK" || echo "staged FAIL"; exit $fail
