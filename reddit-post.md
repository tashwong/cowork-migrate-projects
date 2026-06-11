# Reddit Post for r/ClaudeAI

---

**Title:** I migrated my CoWork sessions to a new Mac — but my projects and scheduled tasks stayed behind. So I built the missing half.

---

**Body:**

If you've moved Claude Desktop CoWork to a new Mac, you may have hit this: there's a
great tool — [cowork-migrate](https://github.com/DRVBSS/cowork-migrate) — that moves
your **conversation sessions** across machines. I used it, and my chats came over.
But my **projects/spaces** and **scheduled tasks** didn't. Empty sidebar, no cron
jobs.

Turns out CoWork keeps that state in completely different files than the
conversations, so a session migration (by design) leaves it behind. I dug through a
real install to map it out and wrote a companion tool that moves the rest.

**What it migrates:**

- Projects / spaces (the catalog the UI lists)
- Scheduled tasks (cron expressions, the SKILL.md they run, permissions)
- Project metadata cache + per-space memory
- The `~/Documents/Claude` content folders

**Stuff I learned the hard way, baked in:**

- Every path in the catalog is absolute (`/Users/<you>/…`) — *including* paths
  buried inside your space/persona instructions. If your username differs between
  Macs (mine did: `tashwong` → `kuriri`), it rewrites them all, at path boundaries
  so `/Users/bob` never mangles `/Users/bobby`.
- It **merges by id** instead of overwriting, and backs up anything it touches.
- `--dry-run` to preview, and it refuses to run while Claude is open (the app
  rewrites these files on quit).
- On a brand-new Mac the session dir exists but has no catalog files yet — the
  README has the one-liner to fix detection.

**Where CoWork actually stores this (the part that took the digging):**

```
~/Documents/Claude/{Projects,Scheduled,Artifacts}          ← content
~/Library/Application Support/Claude/local-agent-mode-sessions/<APP_ID>/<ACCOUNT_ID>/
    ├── spaces.json            ← projects/spaces catalog
    ├── scheduled-tasks.json   ← scheduled tasks
    ├── .project-cache/        ← project metadata
    └── spaces/                ← per-space memory
```

Two things that trip people up: `scheduled-tasks.json` is **not** at the top of the
Claude folder (it's nested in the session dir), and `Partitions/` / `IndexedDB/`
are **not** the projects catalog — they're just the Chromium UI cache, which the
app rebuilds from `spaces.json`. So this tool leaves them alone.

**Use it alongside cowork-migrate for a complete move** — the two touch disjoint
files, so order doesn't matter:

1. `cowork-migrate` → your conversations
2. this tool → your projects + scheduled tasks

**GitHub:** [github.com/tashwong/cowork-migrate-projects](https://github.com/tashwong/cowork-migrate-projects)

No dependencies beyond macOS + Python 3 (pre-installed). MIT licensed. Full credit to
[DRVBSS/cowork-migrate](https://github.com/DRVBSS/cowork-migrate) for the session
half — this is meant to complement it, not replace it. Community workaround until
Anthropic ships native sync. PRs welcome if the storage format changes.
