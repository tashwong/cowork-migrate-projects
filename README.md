# cowork-migrate-projects

**Migrate Claude Desktop CoWork _projects / spaces_ and _scheduled tasks_ between Macs.**

Claude Desktop's CoWork mode keeps a surprising amount of state on your local
disk, and not all of it syncs to a new machine. The excellent
[`cowork-migrate`](https://github.com/DRVBSS/cowork-migrate) tool moves your
**conversation sessions** — but it (by design) leaves behind the things that make
your **projects/spaces** and **scheduled tasks** show up and run. This tool fills
that gap. Use the two together for a complete migration.

> Unofficial, community-built. Not affiliated with Anthropic. Works against
> local files only — no network, no account credentials touched.

---

## The full picture: where CoWork stores things

After reverse-engineering a real install, CoWork state lives in **two** places:

**1. Content folders** — `~/Documents/Claude/`
- `Projects/<name>/` — project working files
- `Scheduled/<id>/SKILL.md` — the skill file each scheduled task runs
- `Artifacts/` — saved artifacts

**2. Catalog + config** — inside one session directory:
```
~/Library/Application Support/Claude/local-agent-mode-sessions/<APP_ID>/<ACCOUNT_ID>/
   ├── spaces.json            ← the projects/spaces catalog (what the UI lists)
   ├── scheduled-tasks.json   ← scheduled task definitions (cron, paths, perms)
   ├── .project-cache/<uuid>/ ← per-project metadata
   ├── spaces/<spaceId>/      ← per-space memory
   └── local_<id>.json …      ← individual conversations  ← cowork-migrate handles these
```
`<ACCOUNT_ID>` is tied to your Claude account, so it's the **same on every Mac you
sign into**. `<APP_ID>` is the install/workspace id.

| Data | Moved by |
|------|----------|
| Conversations (`local_*`) | [`cowork-migrate`](https://github.com/DRVBSS/cowork-migrate) |
| Projects / spaces, scheduled tasks, project cache, space memory, content folders | **this tool** |

### Two common misconceptions
- `scheduled-tasks.json` is **not** at the top of `Application Support/Claude/` —
  it's nested inside the session dir above. (There's a *different* one under
  `claude-code-sessions/` belonging to the Claude Code CLI — a separate feature,
  left untouched.)
- `Partitions/`, `IndexedDB/`, and `Local Storage/` are **not** the projects
  catalog — they're the Chromium renderer's UI cache (draft text, expanded tree
  state). They're machine-coupled and the app rebuilds them from `spaces.json`, so
  this tool deliberately does **not** copy them.

---

## Quick start (complete migration)

Do these in either order — the two tools touch disjoint files and never collide.

### Part A — conversations
Follow [`cowork-migrate`](https://github.com/DRVBSS/cowork-migrate):
```bash
# OLD Mac
./migrate.sh export                 # → ~/cowork-migration
# transfer ~/cowork-migration to the NEW Mac, then:
# NEW Mac
cd ~/cowork-migration && ./migrate.sh install && ./migrate.sh verify
```

### Part B — projects + scheduled tasks (this tool)
```bash
# OLD Mac (quit the Claude desktop app first)
./cowork-migrate-projects.sh export
#   → ~/cowork-projects-<timestamp>.tar.gz

# transfer the tarball to the NEW Mac (AirDrop / drive / scp), then:

# NEW Mac — sign into the SAME Claude account, open CoWork once so its session
# dir exists, then fully quit it (Cmd-Q). Then:
./cowork-migrate-projects.sh import ~/cowork-projects-<timestamp>.tar.gz --dry-run
./cowork-migrate-projects.sh import ~/cowork-projects-<timestamp>.tar.gz
```

`--dry-run` previews without writing.

---

## What this tool does

- **Bundles** the content folders + the session catalog (`spaces.json`,
  `scheduled-tasks.json`, `.project-cache/`, `spaces/`) into one tarball.
- **Rewrites paths** on import. Every path in the catalog is absolute
  (`/Users/<olduser>/…`), including paths baked into space/persona **instructions**.
  On a different username it rewrites the old home prefix to the new machine's
  `$HOME`, at path boundaries so `/Users/bob` never clobbers `/Users/bobby`.
  Tilde paths (`~/…`) are already portable and left alone.
- **Merges by id** — existing spaces/tasks on the target are preserved; matching
  ids are updated, new ones added. Nothing is blindly overwritten.

### Safety
- Refuses to run while the Claude desktop app is open (it rewrites these JSON
  files on exit and locks the leveldb). `--dry-run` bypasses the check.
- Backs up anything it overwrites as `*.bak-<timestamp>` next to the original.
- Never deletes; `.project-cache/` and `spaces/` are merged additively.

---

## Important precondition

Rewriting fixes the path **references**, not the **targets**. Any folders your
projects/tasks point at — e.g. anything under `~/Developer` or other working dirs
— must already exist on the new Mac at the same home-relative path. Migrate those
separately (git, Migration Assistant, rsync). A missing folder won't crash the
app, but that project/task will point at nothing.

---

## Troubleshooting

**`ERROR: target session dir missing`** on a fresh Mac.
Opening Claude isn't always enough — the session dir only gets its catalog files
once CoWork initialises. Open the app, start a CoWork session (any throwaway
prompt), fully quit (Cmd-Q), then re-run. If the session *directory* exists but
has no `spaces.json`/`scheduled-tasks.json` yet, seed an empty one so detection
finds it:
```bash
D=~/Library/Application*Support/Claude/local-agent-mode-sessions/*/*/
[ -f $D/scheduled-tasks.json ] || printf '{"scheduledTasks":[]}' > $D/scheduled-tasks.json
```
(The `Application*Support` glob avoids the space in the folder name, which
otherwise breaks copy-paste.)

**`The Claude desktop app is running`.** Quit it fully with **Cmd-Q** — closing the
window isn't enough.

**A space looks empty / a task points at nothing.** Almost always a working folder
that hasn't been copied to the new Mac yet. See the precondition above.

**Paths with spaces break in the terminal.** "Application Support" has a space;
escaping it (`\ `) often survives copy-paste badly. Use double quotes around the
whole path or the `Application*Support` glob trick.

---

## Credits

- Conversation/session migration: [`cowork-migrate`](https://github.com/DRVBSS/cowork-migrate)
  by Driveboss LLC (MIT). This tool is designed to complement it.
- Built collaboratively with Claude Code.

## License

MIT — see [LICENSE](LICENSE).
