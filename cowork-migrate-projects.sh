#!/usr/bin/env bash
#
# cowork-migrate-projects.sh
#
# Migrate Claude CoWork **projects/spaces** and **scheduled tasks** between Macs.
# (cowork-migrate already handles the local_* conversation sessions; this fills
# the gap it leaves: the spaces.json catalog, scheduled-tasks.json, the project
# cache, space memory, and the ~/Documents/Claude content folders.)
#
# Two phases:
#   export   run on the OLD Mac -> produces a single tarball
#   import   run on the NEW Mac -> unpacks it, rewrites paths, merges by id
#
# What it touches:
#   ~/Documents/Claude/{Projects,Scheduled,Artifacts}                 (content)
#   ~/Library/Application Support/Claude/local-agent-mode-sessions/
#       <APP_ID>/<ACCOUNT_ID>/{spaces.json,scheduled-tasks.json,
#                              .project-cache/,spaces/}                (catalog)
#
# What it deliberately does NOT touch:
#   IndexedDB / Local Storage / Partitions leveldb (renderer UI cache; the app
#   rebuilds it from spaces.json) and the Claude Code CLI's own
#   claude-code-sessions/.../scheduled-tasks.json (different feature).
#
# Safety: refuses to run while the CoWork desktop app is open, backs up anything
# it overwrites (timestamped), supports --dry-run, and merges by id rather than
# clobbering existing state.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants / helpers
# ---------------------------------------------------------------------------
APP_SUPPORT="$HOME/Library/Application Support/Claude"
SESS_ROOT="$APP_SUPPORT/local-agent-mode-sessions"
CONTENT_DIR="$HOME/Documents/Claude"
CONTENT_SUBDIRS=(Projects Scheduled Artifacts)
# Control files copied out of the session dir (relative to the session dir):
SESSION_PAYLOAD=(spaces.json scheduled-tasks.json .project-cache spaces)

STAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0

c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()   { printf '\033[33m%s\033[0m\n' "$*"; }
info()    { printf '  %s\n' "$*"; }
step()    { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()     { c_red "ERROR: $*" >&2; exit 1; }
run()     { if [ "$DRY_RUN" = 1 ]; then echo "    [dry-run] $*"; else eval "$@"; fi; }

usage() {
  cat <<'EOF'
Usage:
  cowork-migrate-projects.sh export [--out FILE] [--dry-run]
  cowork-migrate-projects.sh import <FILE.tar.gz> [--dry-run]

  export   Run on the OLD Mac. Bundles CoWork projects/spaces + scheduled tasks
           into a tarball (default: ~/cowork-projects-<timestamp>.tar.gz).

  import   Run on the NEW Mac. Unpacks the tarball, rewrites the old home-dir
           prefix to this machine's, and merges spaces + tasks by id.

  --dry-run   Show what would happen without writing anything.

Before import: log into the SAME Claude account in CoWork, launch it once so the
session directory is created, then fully quit it.
EOF
}

# Fail if the CoWork desktop app is running (it rewrites these JSON files on exit
# and locks the leveldb). Skipped under --dry-run since that writes nothing.
assert_claude_quit() {
  [ "$DRY_RUN" = 1 ] && return 0
  if pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1; then
    die "The Claude desktop app is running. Quit it fully (Cmd-Q) and re-run."
  fi
}

# Locate the active session dir: <SESS_ROOT>/<APP_ID>/<ACCOUNT_ID>/ that actually
# contains spaces.json. Echoes the path; errors if zero or >1 candidates.
# If $1 is given, prefer a dir whose ACCOUNT_ID (last path segment) equals it.
find_session_dir() {
  local prefer_account="${1:-}"
  [ -d "$SESS_ROOT" ] || return 1
  # If we know the account id (import side), the session dir is
  # <SESS_ROOT>/<APP_ID>/<account_id>. Match it by directory structure so a FRESH
  # target works too -- a just-initialised CoWork has the dir but no spaces.json /
  # scheduled-tasks.json yet, so content-based detection would miss it.
  if [ -n "$prefer_account" ]; then
    local byacct=()
    while IFS= read -r d; do byacct+=("$d"); done < <(
      find "$SESS_ROOT" -mindepth 2 -maxdepth 2 -type d -name "$prefer_account" 2>/dev/null | sort -u
    )
    if [ "${#byacct[@]}" -ge 1 ]; then
      for d in "${byacct[@]}"; do  # prefer one that already has catalog files
        if [ -f "$d/spaces.json" ] || [ -f "$d/scheduled-tasks.json" ]; then echo "$d"; return 0; fi
      done
      echo "${byacct[0]}"; return 0
    fi
  fi
  local matches=()
  while IFS= read -r d; do matches+=("$d"); done < <(
    find "$SESS_ROOT" -mindepth 3 -maxdepth 3 -name spaces.json 2>/dev/null \
      | sed 's#/spaces.json$##' | sort -u
  )
  # Fall back to dirs that at least have scheduled-tasks.json (fresh accounts may
  # have a session dir but no spaces.json yet).
  if [ "${#matches[@]}" -eq 0 ]; then
    while IFS= read -r d; do matches+=("$d"); done < <(
      find "$SESS_ROOT" -mindepth 3 -maxdepth 3 -name scheduled-tasks.json 2>/dev/null \
        | sed 's#/scheduled-tasks.json$##' | sort -u
    )
  fi
  [ "${#matches[@]}" -gt 0 ] || return 1
  if [ -n "$prefer_account" ]; then
    for d in "${matches[@]}"; do
      [ "$(basename "$d")" = "$prefer_account" ] && { echo "$d"; return 0; }
    done
  fi
  if [ "${#matches[@]}" -gt 1 ]; then
    c_ylw "Multiple session dirs found; pick one and set COWORK_SESSION_DIR:" >&2
    printf '   %s\n' "${matches[@]}" >&2
    [ -n "${COWORK_SESSION_DIR:-}" ] && { echo "$COWORK_SESSION_DIR"; return 0; }
    return 2
  fi
  echo "${matches[0]}"
}

backup_path() {  # back up a file/dir in place before we modify/overwrite it
  local p="$1"
  [ -e "$p" ] || return 0
  local b="${p}.bak-${STAMP}"
  info "backup: $p -> $b"
  run "cp -a \"$p\" \"$b\""
}

# ---------------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------------
do_export() {
  local out="$HOME/cowork-projects-${STAMP}.tar.gz"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2;;
      --dry-run) DRY_RUN=1; shift;;
      *) die "unknown export arg: $1";;
    esac
  done

  assert_claude_quit
  step "Locating session directory"
  local sess; sess="$(find_session_dir || true)"
  [ -n "$sess" ] || die "No CoWork session dir with spaces.json under $SESS_ROOT"
  local app_id account_id
  account_id="$(basename "$sess")"
  app_id="$(basename "$(dirname "$sess")")"
  info "session: $sess"
  info "APP_ID=$app_id  ACCOUNT_ID=$account_id"

  step "Staging files"
  local stage; stage="$(mktemp -d)/cowork-export"
  run "mkdir -p \"$stage/content\" \"$stage/session\""

  # Content folders
  for sub in "${CONTENT_SUBDIRS[@]}"; do
    if [ -d "$CONTENT_DIR/$sub" ]; then
      info "content: $sub"
      run "rsync -a --exclude '.DS_Store' \"$CONTENT_DIR/$sub\" \"$stage/content/\""
    else
      c_ylw "  (skip: $CONTENT_DIR/$sub not found)"
    fi
  done

  # Session catalog/control payload
  for item in "${SESSION_PAYLOAD[@]}"; do
    if [ -e "$sess/$item" ]; then
      info "session: $item"
      run "rsync -a --exclude '.DS_Store' \"$sess/$item\" \"$stage/session/\""
    else
      c_ylw "  (skip: $item not present)"
    fi
  done

  # Manifest
  step "Writing manifest"
  if [ "$DRY_RUN" = 0 ]; then
    OLD_HOME="$HOME" APP_ID="$app_id" ACCOUNT_ID="$account_id" \
    python3 - "$stage/manifest.json" <<'PY'
import json, os, sys, socket
m = {
  "tool": "cowork-migrate-projects",
  "version": 1,
  "old_home": os.environ["OLD_HOME"],
  "old_user": os.path.basename(os.environ["OLD_HOME"]),
  "app_id": os.environ["APP_ID"],
  "account_id": os.environ["ACCOUNT_ID"],
  "hostname": socket.gethostname(),
}
json.dump(m, open(sys.argv[1], "w"), indent=2)
print("  manifest:", m)
PY
  else
    echo "    [dry-run] manifest (old_home=$HOME app_id=$app_id account_id=$account_id)"
  fi

  step "Creating archive"
  info "out: $out"
  run "tar -C \"$(dirname "$stage")\" -czf \"$out\" \"$(basename "$stage")\""
  run "rm -rf \"$(dirname "$stage")\""
  c_grn "Export complete: $out"
  info "Move it to the new Mac (AirDrop / drive / scp), then run: import $out"
}

# ---------------------------------------------------------------------------
# IMPORT
# ---------------------------------------------------------------------------
do_import() {
  local archive=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift;;
      -*) die "unknown import arg: $1";;
      *) archive="$1"; shift;;
    esac
  done
  [ -n "$archive" ] || { usage; die "import needs a tarball path"; }
  [ -f "$archive" ] || die "no such file: $archive"

  assert_claude_quit

  step "Unpacking archive"
  # Always extract to temp (read-only side effect) so --dry-run can read the real
  # manifest and show accurate paths/account. Only writes to live locations below
  # are gated by DRY_RUN.
  local tmp; tmp="$(mktemp -d)"
  tar -C "$tmp" -xzf "$archive"
  local stage="$tmp/cowork-export"
  [ -d "$stage" ] || die "unexpected archive layout (no cowork-export/)"

  # Read manifest
  local old_home account_id
  old_home="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["old_home"])' "$stage/manifest.json")"
  account_id="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["account_id"])' "$stage/manifest.json")"
  info "old home : $old_home"
  info "new home : $HOME"
  info "account  : $account_id"

  # 1) Content folders ------------------------------------------------------
  step "Restoring ~/Documents/Claude content"
  run "mkdir -p \"$CONTENT_DIR\""
  for sub in "${CONTENT_SUBDIRS[@]}"; do
    if [ -d "$stage/content/$sub" ]; then
      [ -d "$CONTENT_DIR/$sub" ] && backup_path "$CONTENT_DIR/$sub"
      info "content: $sub"
      run "rsync -a \"$stage/content/$sub\" \"$CONTENT_DIR/\""
    fi
  done

  # 2) Locate / prepare the target session dir -----------------------------
  step "Locating target session directory"
  local target; target="$(find_session_dir "$account_id" || true)"
  if [ -z "$target" ]; then
    c_red "No CoWork session directory found on this Mac."
    cat <<EOF
  Do this first, then re-run import:
    1. Open the Claude desktop app and sign into the SAME account.
    2. Make sure CoWork / local agent mode has initialised (open it once).
    3. Fully quit Claude (Cmd-Q).
  Expected location: $SESS_ROOT/<APP_ID>/$account_id/
EOF
    die "target session dir missing"
  fi
  info "target: $target"
  if [ "$(basename "$target")" != "$account_id" ] && [ "$DRY_RUN" = 0 ]; then
    c_ylw "  Note: target account id ($(basename "$target")) != source ($account_id)."
    c_ylw "  Proceeding, but double-check you're on the same Claude account."
  fi

  # 3) Copy project cache + space memory (additive) ------------------------
  step "Restoring project cache + space memory"
  for item in .project-cache spaces; do
    if [ -d "$stage/session/$item" ]; then
      info "session: $item (merge, no delete)"
      run "mkdir -p \"$target/$item\""
      run "rsync -a \"$stage/session/$item/\" \"$target/$item/\""
    fi
  done

  # 4) Merge spaces.json + scheduled-tasks.json with path rewrite ----------
  step "Merging catalog (spaces.json, scheduled-tasks.json) + rewriting paths"
  backup_path "$target/spaces.json"
  backup_path "$target/scheduled-tasks.json"

  if [ "$DRY_RUN" = 0 ]; then
    OLD_HOME="$old_home" NEW_HOME="$HOME" \
    SRC_SPACES="$stage/session/spaces.json" \
    SRC_TASKS="$stage/session/scheduled-tasks.json" \
    DST_SPACES="$target/spaces.json" \
    DST_TASKS="$target/scheduled-tasks.json" \
    python3 - <<'PY'
import json, os, re

OLD = os.environ["OLD_HOME"].rstrip("/")
NEW = os.environ["NEW_HOME"].rstrip("/")
# Match the old home prefix anywhere in a string (incl. inside prose like persona
# instructions), but only at a path boundary so /Users/bob never matches
# /Users/bobby. Continuation chars [A-Za-z0-9_-] mean the username token goes on.
OLD_RE = re.compile(re.escape(OLD) + r"(?![A-Za-z0-9_-])")

def rewrite(obj):
    """Recursively replace the old home-dir prefix with the new one in any string."""
    if isinstance(obj, str):
        return OLD_RE.sub(NEW, obj)
    if isinstance(obj, list):
        return [rewrite(x) for x in obj]
    if isinstance(obj, dict):
        return {k: rewrite(v) for k, v in obj.items()}
    return obj

def load(path, default):
    try:
        return json.load(open(path))
    except FileNotFoundError:
        return default

def merge_by_id(existing, incoming, key):
    """List-merge by item[key]; incoming wins on collision; order = existing then new."""
    out, seen = [], {}
    for item in existing:
        seen[item.get(key)] = len(out); out.append(item)
    n_new = n_upd = 0
    for item in incoming:
        k = item.get(key)
        if k in seen:
            out[seen[k]] = item; n_upd += 1
        else:
            seen[k] = len(out); out.append(item); n_new += 1
    return out, n_new, n_upd

# --- spaces.json ---
if os.path.exists(os.environ["SRC_SPACES"]):
    src = rewrite(load(os.environ["SRC_SPACES"], {"spaces": []}))
    dst = load(os.environ["DST_SPACES"], {"spaces": []})
    merged, n_new, n_upd = merge_by_id(dst.get("spaces", []), src.get("spaces", []), "id")
    dst["spaces"] = merged
    json.dump(dst, open(os.environ["DST_SPACES"], "w"), indent=2)
    print(f"  spaces.json:        +{n_new} new, ~{n_upd} updated, {len(merged)} total")

# --- scheduled-tasks.json ---
if os.path.exists(os.environ["SRC_TASKS"]):
    src = rewrite(load(os.environ["SRC_TASKS"], {"scheduledTasks": []}))
    dst = load(os.environ["DST_TASKS"], {"scheduledTasks": []})
    merged, n_new, n_upd = merge_by_id(
        dst.get("scheduledTasks", []), src.get("scheduledTasks", []), "id")
    dst["scheduledTasks"] = merged
    dst.setdefault("recordedSkips", src.get("recordedSkips", {}))
    json.dump(dst, open(os.environ["DST_TASKS"], "w"), indent=2)
    print(f"  scheduled-tasks.json: +{n_new} new, ~{n_upd} updated, {len(merged)} total")
PY
  else
    echo "    [dry-run] would rewrite '$old_home' -> '$HOME' and merge by id into:"
    echo "              $target/spaces.json"
    echo "              $target/scheduled-tasks.json"
  fi

  rm -rf "$tmp"
  c_grn "Import complete."
  cat <<EOF

Next:
  * Confirm the folders referenced by your projects/tasks exist on THIS Mac at
    the new home path (esp. anything under ~/Developer). Missing folders won't
    break the app, but those projects/tasks will point at nothing.
  * Launch the Claude desktop app and verify your spaces + scheduled tasks.
  * Backups (if any) are alongside the originals as *.bak-${STAMP}.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
[ $# -ge 1 ] || { usage; exit 1; }
cmd="$1"; shift
case "$cmd" in
  export) do_export "$@";;
  import) do_import "$@";;
  -h|--help|help) usage;;
  *) usage; die "unknown command: $cmd";;
esac
