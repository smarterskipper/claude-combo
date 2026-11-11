# Menos brain review (on Proxmox)

The brain review is an automatic code review for every pull request in the `menos-app` GitHub org. When someone pushes to an
open PR, it reads the change and posts one comment titled **🧠 Menos brain review**. The comment lists the problems it
found (blocker / major / minor) and ends with a verdict. Each new push gets a new comment, which also says which earlier
findings are now fixed. It is written by Claude Sonnet 5.5 using the Anthropic API keys, and it posts as `smarterskipper`.

To review well, it uses a **code index**: a database with a short plain-English note about every piece of code in the org.
Those notes are grouped into features, each with an overview and "known gotchas", and the database also logs recent merged
changes. The review is given the features a PR touches, so it can catch repeats of old mistakes and broken iOS ↔ backend
contracts.

## Where it runs

- **LXC CT 129 `brain-review`** on Proxmox node **pve1** (Debian 12, 2 cores, 2 GB RAM, 16 GB disk, DHCP, currently
  10.0.1.158). Starts on boot.
- Code: `/opt/code-notes/` (`reviewer.py`, `code_notes.py`, `journal.py`, plus `bin/` wrappers). A copy of this README is
  at `/opt/code-notes/README.md`.
- Data: `/var/lib/brain/` (the `notes.db` index, a mirror of every menos-app repo in `code-index/menos-app`, logs).
- Keys: `/etc/brain-review/env`, readable only by the service user `brain`. It holds both Anthropic keys, the GitHub
  token and the caps. The originals live in `~/secret/env` on ubuntu-pc; if you rotate a key there, update this file too.
- Moved here from ubuntu-pc on 2026-11-11. The old timers on ubuntu-pc are off and stay off.

## Schedule

| Timer | When | What it does |
|---|---|---|
| `brain-review.timer` | every 5 min | Reviews every open PR whose newest commit has no brain review yet, one at a time. |
| `menos-code-sync.timer` | every 30 min | Pulls every menos-app repo (the `dev` branch where there is one), then updates the index: it writes notes for new or changed code only (paid), refreshes the features, and logs merged PRs. |

Repos reviewed: menos-ios, menos-api, menosapp-site, menos-infra, menos-growth, menos-status, menos-community-bot,
ironhollow. The index covers the whole org. No embeddings or Ollama: reviews don't use them.

## Costs and caps

- Each key has a **$190 per calendar month** cap, and the count resets on the 1st (UTC). The main key pays for
  notes and reviews. The fallback key pays only for reviews, and only once the main key is at its cap or refuses for
  billing or limits. When both keys are at their cap, everything stops until the 1st.
- Rough costs: a review is about $0.13 (a tiny PR can be a few cents more or less). Notes cost about $1–2 on a normal day.
  A big merge or a backlog costs more: about 3,700 un-noted chunks were waiting on 2026-11-11, about $17 one time (half a cent per chunk).
- If the caps pause reviews, the next run also reviews PRs that merged during the pause, but at most the **30 newest
  per repo** (`BRAIN_CATCHUP_MAX`). Without that limit, one catch-up on 2026-11-11 cost $34.
- Check spend:
  `pct exec 129 -- runuser -u brain -- env HOME=/var/lib/brain bash -c 'set -a; . /etc/brain-review/env; /opt/code-notes/.venv/bin/python /opt/code-notes/code_notes.py stats'`
- To change a cap, edit `CODE_NOTES_MONTHLY_CAP` / `CODE_NOTES_FALLBACK_CAP` in `/etc/brain-review/env`. The next run
  picks it up.

## Stop, start, check

Run these on pve1 (`ssh root@10.0.1.26`):

```bash
pct exec 129 -- systemctl disable --now brain-review.timer menos-code-sync.timer   # stop everything
pct exec 129 -- systemctl enable --now brain-review.timer menos-code-sync.timer    # start again
pct exec 129 -- systemctl list-timers brain-review.timer menos-code-sync.timer     # next runs
pct exec 129 -- journalctl -u brain-review -n 30 --no-pager                        # what the reviewer did
pct exec 129 -- tail -n 30 /var/lib/brain/logs/sync.log                            # index refresh log
pct stop 129                                                                       # hard stop
```

To review one PR right now, as the `brain` user: `reviewer.py one <repo> <number>`. Add `--dry-run` to print the
review without posting it.

## Not moved

The nightly and weekly maintenance agents (`agents.py`: API contract, architecture, gotchas, factcheck) are on the LXC
but have no timer. The menos-code MCP search server and the Obsidian vault pages (`~/Documents/Vault/Code/*`) are no
longer updated.
