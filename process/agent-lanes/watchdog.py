#!/usr/bin/env python3
# Token watchdog: flags workflow agents that look hung (no transcript write for STALE_MIN), looping (> MAX_TURNS assistant turns)
# or stuck in retries (same label started > MAX_RESTARTS times). Prints findings and exits 1 when any new one appears.
# Run: python3 watchdog.py   (checks every Claude Code session's workflows under ~/.claude/projects; acks in ~/.claude/watchdog.ack, one "agentId", "wf_<id>" (whole workflow) or "wf:label" per line, are skipped)
# Loop while workflows run: while python3 watchdog.py > /tmp/watchdog.last 2>&1; do sleep 300; done; cat /tmp/watchdog.last
import json, os, sys, time, glob, collections
ACK = os.path.expanduser("~/.claude/watchdog.ack")
STALE_MIN, MAX_TURNS, MAX_RESTARTS, ACTIVE_H = 30, 300, 6, 8
now = time.time()
acked = set(open(ACK).read().split()) if os.path.exists(ACK) else set()
found = []
for d in glob.glob(os.path.expanduser("~/.claude/projects/*/*/subagents/workflows/wf_*")):
    j = os.path.join(d, "journal.jsonl")
    if not os.path.exists(j) or now - os.path.getmtime(d) > ACTIVE_H * 3600:
        continue
    started, done, dkeys, labels = {}, set(), set(), collections.Counter()
    for line in open(j, errors="ignore"):
        try:
            e = json.loads(line)
        except Exception:
            continue
        aid = e.get("agentId")
        if e.get("type") == "started" and aid:
            k = e.get("key")
            if k:
                for old in [a for a, v in started.items() if v[1] == k]:
                    del started[old]  # superseded by a resumed/relaunched agent for the same step
            started[aid] = (e.get("label", "?"), k)
            labels[e.get("label", "?")] += 1
        elif aid and e.get("type") in ("result", "error", "skipped", "failed"):
            done.add(aid)
            if e.get("key"): dkeys.add(e.get("key"))
    wf = os.path.basename(d)
    if wf in acked:
        continue  # whole workflow acked (e.g. a run that was stopped on purpose)
    for lab, n in labels.items():
        if n > MAX_RESTARTS and f"{wf}:{lab}" not in acked:
            found.append(f"RETRIES {wf} label={lab} started {n}x")
    for aid, (lab, key) in started.items():
        if aid in done or aid in acked or (key and key in dkeys):
            continue
        t = os.path.join(d, f"agent-{aid}.jsonl")
        if not os.path.exists(t):
            continue
        idle = (now - os.path.getmtime(t)) / 60
        turns = sum(1 for l in open(t, errors="ignore") if '"type":"assistant"' in l)
        if idle > STALE_MIN:
            found.append(f"STALE {wf} {lab} agent={aid} idle={idle:.0f}m turns={turns}")
        elif turns > MAX_TURNS:
            found.append(f"LOOPING {wf} {lab} agent={aid} turns={turns} idle={idle:.0f}m")
if found:
    print("\n".join(found))
    sys.exit(1)
