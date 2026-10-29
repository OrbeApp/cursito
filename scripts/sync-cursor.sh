#!/usr/bin/env bash
#
# sync-cursor.sh — moves your Cursor setup from one Mac to another through a
# sync location: a folder, or a single .tar.gz file (recommended for iCloud
# Drive, since it's replaced in one go and never half-synced).
#
# Usage:
#   sync-cursor.sh export        # main Mac: write this Mac's setup to the sync location
#   sync-cursor.sh diff          # what an import would change on this Mac
#   sync-cursor.sh import        # other Mac: apply the export (backs up first)
#   sync-cursor.sh info          # who exported, when, and with which Cursor
#
# Options (before or after the command):
#   -d PATH   sync location; a .tar.gz/.tgz path is used as an archive
#             (default: ./cursor-sync next to this script)
#   -y        don't ask for confirmation
#   -E        don't install extensions on import
#   -p        machine-readable output (tab-separated), used by Cursito.app
#
# Syncs mcp.json, hooks.json, cli-config.json (minus the login session),
# settings, keybindings, snippets, extensions, plugins, skills and subagents.
# Doesn't sync chats, login or MCP OAuth tokens: they are encrypted with each
# Mac's keychain, so OAuth MCP servers ask you to log in again after an import.
#
# Import refuses to run while Cursor is open and backs up what it replaces in
# ~/.cursito/backups/<date> (last 5 kept). Restore one with:
#   sync-cursor.sh import -d ~/.cursito/backups/<date>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_PATH="$ROOT/cursor-sync"
STATE_ROOT="$HOME/.cursito"
BACKUP_ROOT="$STATE_ROOT/backups"
LAST_IMPORT_FILE="$STATE_ROOT/last-import"
BACKUPS_KEPT=5
MANIFEST_FORMAT=1
SKIP_EXTENSIONS=0
ASSUME_YES=0
PORCELAIN=0

CURSOR_USER="Library/Application Support/Cursor/User"
STATE_DB="$HOME/$CURSOR_USER/globalStorage/state.vscdb"
CLI_CONFIG=".cursor/cli-config.json"
SESSION_KEYS=(authInfo privacyCache)

FILES=(
  ".cursor/mcp.json"
  ".cursor/hooks.json"
  "$CLI_CONFIG"
  "$CURSOR_USER/settings.json"
  "$CURSOR_USER/keybindings.json"
)
DIRS=(
  ".cursor/agents"
  ".cursor/commands"
  ".cursor/rules"
  ".cursor/skills"
  ".cursor/plugins"
  ".agents/skills"
  ".claude/skills"
  ".codex/skills"
  "$CURSOR_USER/snippets"
)
# Codex manages .system on each Mac; excluded paths are also kept by rsync --delete
EXCLUDES=(--exclude=.DS_Store --exclude=.system)

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

COMMAND=
parse_options() {
  local opt
  OPTIND=1
  while getopts ":d:Eyph" opt; do
    case "$opt" in
      d) SYNC_PATH="${OPTARG%/}" ;;
      E) SKIP_EXTENSIONS=1 ;;
      y) ASSUME_YES=1 ;;
      p) PORCELAIN=1 ;;
      h) usage 0 ;;
      *) echo "Invalid option: -$OPTARG" >&2; usage 1 ;;
    esac
  done
  ARGS_CONSUMED=$((OPTIND - 1))
}
parse_options "$@"; shift "$ARGS_CONSUMED"
if [ "$#" -gt 0 ]; then
  COMMAND="$1"; shift
  parse_options "$@"; shift "$ARGS_CONSUMED"
fi
[ "$#" -gt 0 ] && { echo "Unexpected argument: $1" >&2; usage 1; }

if [ -t 1 ] && [ "$PORCELAIN" -eq 0 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=; DIM=; RED=; GREEN=; YELLOW=; RESET=
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { echo "${RED}error:${RESET} $*" >&2; exit 1; }

# Human-only messages; porcelain output carries only ITEM/DETAIL/key=value lines
say() { [ "$PORCELAIN" -eq 1 ] || echo "$@"; }

# line <state> <item> [detail]; state: ok, same, new, changed, skip, warn, error
line() {
  local state="$1" item="$2" detail="${3:-}" icon color
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'ITEM\t%s\t%s\t%s\n' "$state" "$item" "$detail"
    return
  fi
  case "$state" in
    ok)      icon="${GREEN}✓${RESET}"; color="$DIM" ;;
    same)    icon="${DIM}·${RESET}"; color="$DIM" ;;
    new)     icon="${GREEN}+${RESET}"; color="$GREEN" ;;
    changed) icon="${YELLOW}~${RESET}"; color="$YELLOW" ;;
    skip)    icon="${DIM}-${RESET}"; color="$DIM" ;;
    warn)    icon="${YELLOW}!${RESET}"; color="$YELLOW" ;;
    *)       icon="${RED}✗${RESET}"; color="$RED" ;;
  esac
  printf '%s %s%-48s%s %s\n' "$icon" "$BOLD" "$item" "$RESET" "${color}${detail}${RESET}"
}

# detail <item> <text>: sub-line of the previous item
detail() {
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'DETAIL\t%s\t%s\n' "$1" "$2"
  else
    echo "    ${DIM}$2${RESET}"
  fi
}

# ------------------------------------------------------------ helpers
cursor_cli() {
  if command -v cursor >/dev/null 2>&1; then
    command -v cursor
  elif [ -x /Applications/Cursor.app/Contents/Resources/app/bin/cursor ]; then
    echo /Applications/Cursor.app/Contents/Resources/app/bin/cursor
  fi
}

# No grep -q: it closes the pipe early and pipefail turns ps's SIGPIPE into a failure
cursor_running() { ps -axo comm= | grep '/Cursor\.app/Contents/MacOS/Cursor$' >/dev/null; }

machine_id() { ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/ { print $4 }'; }

computer_name() { scutil --get ComputerName 2>/dev/null || hostname; }

is_archive() { case "$SYNC_PATH" in *.tar.gz|*.tgz) return 0 ;; *) return 1 ;; esac; }

# Older iCloud Drive versions replace evicted files with a ".name.icloud" placeholder
ensure_local() {
  local file="$1" placeholder i
  placeholder="$(dirname "$file")/.$(basename "$file").icloud"
  [ -f "$file" ] && return 0
  [ -f "$placeholder" ] || return 1
  brctl download "$file" >/dev/null 2>&1
  for i in $(seq 1 120); do
    [ -f "$file" ] && return 0
    sleep 1
  done
  return 1
}

# Sets SRC to a directory with the export (extracting the archive if needed)
SRC=
load_export() {
  if is_archive; then
    ensure_local "$SYNC_PATH" || die "no export at $SYNC_PATH (run 'export' on the other Mac)"
    mkdir -p "$WORK/src"
    tar -xzf "$SYNC_PATH" -C "$WORK/src" || die "can't extract $SYNC_PATH (still syncing?)"
    SRC="$WORK/src"
  else
    SRC="$SYNC_PATH"
  fi
  [ -f "$SRC/MANIFEST" ] || die "no export at $SYNC_PATH (run 'export' on the other Mac)"
}

manifest_value() { sed -n "s/^$1=//p" "$SRC/MANIFEST" 2>/dev/null; }

print_manifest_header() {
  say "Export from ${BOLD}$(manifest_value host)${RESET} on $(manifest_value date)" \
    "${DIM}(Cursor $(manifest_value cursor))${RESET}"
  say
}

# cli-config.json without the login session (Cursor fills it in on login)
strip_session() {
  python3 - "$1" "$2" "${SESSION_KEYS[@]}" <<'PY'
import json, sys
src, dst, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(src) as f:
    data = json.load(f)
for key in keys:
    data.pop(key, None)
with open(dst, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Writes the exported cli-config keeping this Mac's login session
merge_session() {
  python3 - "$1" "$2" "${SESSION_KEYS[@]}" <<'PY'
import json, os, sys
src, dst, keys = sys.argv[1], sys.argv[2], sys.argv[3:]
with open(src) as f:
    data = json.load(f)
if os.path.exists(dst):
    try:
        with open(dst) as f:
            local = json.load(f)
    except ValueError:
        local = {}
    for key in keys:
        if key in local:
            data[key] = local[key]
with open(dst, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
}

# Installed plugins live in state.vscdb (cursor.plugins.installedIds.<team>|<workspace>).
# Usage: state_tool export|diff|import <db> <json> [backup.json]
state_tool() {
  python3 - "$@" <<'PY'
import json, sqlite3, sys
from urllib.parse import quote

# Range instead of LIKE so SQLite uses the key index on a multi-GB database
LO, HI = "cursor.plugins.installedIds.", "cursor.plugins.installedIds/"
QUERY = "SELECT key, value FROM ItemTable WHERE key >= ? AND key < ?"
action, db, path = sys.argv[1:4]

def read(con):
    rows = con.execute(QUERY, (LO, HI)).fetchall()
    return {k: v.decode() if isinstance(v, bytes) else v for k, v in rows}

def dump(data, target):
    with open(target, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")

if action == "export":
    dump(read(sqlite3.connect(f"file:{quote(db)}?mode=ro", uri=True)), path)
    sys.exit(0)

with open(path) as f:
    wanted = json.load(f)

if action == "diff":
    local = read(sqlite3.connect(f"file:{quote(db)}?mode=ro", uri=True))
    print("same" if local == wanted else "changed")
elif action == "import":
    con = sqlite3.connect(db, timeout=10)
    dump(read(con), sys.argv[4])
    with con:
        con.execute("DELETE FROM ItemTable WHERE key >= ? AND key < ?", (LO, HI))
        con.executemany("INSERT INTO ItemTable (key, value) VALUES (?, ?)", wanted.items())
PY
}

# Up to 8 lines of "diff -rq" with short paths
print_dir_diff() {
  local item="$1" output="$2" local_dir="$3" export_dir="$4" count=0 row
  while IFS= read -r row; do
    count=$((count + 1))
    [ "$count" -gt 8 ] && continue
    row="${row//"$local_dir"/local}"
    row="${row//"$export_dir"/export}"
    detail "$item" "$row"
  done <<< "$output"
  [ "$count" -gt 8 ] && detail "$item" "… and $((count - 8)) more"
}

write_manifest() {
  {
    echo "format=$MANIFEST_FORMAT"
    echo "host=$(computer_name)${2:-}"
    echo "machine_id=$(machine_id)"
    echo "epoch=$(date +%s)"
    echo "date=$(date '+%Y-%m-%d %H:%M')"
    echo "cursor=$3"
  } > "$1"
}

prune_backups() {
  local backups=() i
  for i in "$BACKUP_ROOT"/2*; do
    [ -d "$i" ] && backups+=("$i")
  done
  i=0
  while [ $((${#backups[@]} - i)) -gt "$BACKUPS_KEPT" ]; do
    rm -rf "${backups[$i]}"
    i=$((i + 1))
  done
}

# ------------------------------------------------------------ export
cmd_export() {
  local out="$WORK/export" rel src dst cli version archive_tmp

  if ! is_archive && [ -e "$SYNC_PATH" ] && [ ! -f "$SYNC_PATH/MANIFEST" ] \
      && [ -n "$(ls -A "$SYNC_PATH" 2>/dev/null)" ]; then
    die "$SYNC_PATH exists and isn't an export from this script; not overwriting it"
  fi

  say "${BOLD}Exporting Cursor's setup to $SYNC_PATH${RESET}"
  say

  mkdir -p "$out/home"
  chmod 700 "$out"

  for rel in "${FILES[@]}"; do
    src="$HOME/$rel"; dst="$out/home/$rel"
    if [ ! -f "$src" ]; then
      line skip "$rel" "doesn't exist"
      continue
    fi
    mkdir -p "$(dirname "$dst")"
    if [ "$rel" = "$CLI_CONFIG" ]; then
      strip_session "$src" "$dst" || { line error "$rel" "invalid JSON"; continue; }
      line ok "$rel" "without authInfo / privacyCache"
    else
      cp -p "$src" "$dst"
      line ok "$rel"
    fi
  done

  for rel in "${DIRS[@]}"; do
    src="$HOME/$rel"; dst="$out/home/$rel"
    [ -d "$src" ] || continue
    mkdir -p "$dst"
    if rsync -a "${EXCLUDES[@]}" "$src/" "$dst/"; then
      line ok "$rel/" "$(du -sh "$dst" | cut -f1 | tr -d ' ')"
    else
      line error "$rel/" "rsync failed"
    fi
  done

  if [ -f "$STATE_DB" ] && state_tool export "$STATE_DB" "$out/state-plugins.json"; then
    line ok "installed plugins" "state.vscdb"
  else
    line warn "installed plugins" "couldn't read state.vscdb"
  fi

  cli="$(cursor_cli)"
  if [ -n "$cli" ] && "$cli" --list-extensions --show-versions > "$out/extensions.txt" 2>/dev/null; then
    line ok "extensions" "$(wc -l < "$out/extensions.txt" | tr -d ' ')"
    version="$("$cli" --version 2>/dev/null | head -1)"
  else
    rm -f "$out/extensions.txt"
    line warn "extensions" "no 'cursor' CLI, not exported"
    version=
  fi

  write_manifest "$out/MANIFEST" "" "$version"

  if is_archive; then
    mkdir -p "$(dirname "$SYNC_PATH")" || die "can't create $(dirname "$SYNC_PATH")"
    archive_tmp="$WORK/export.tar.gz"
    # MANIFEST first so `info` stops reading early; no AppleDouble ._ files
    (cd "$out" && COPYFILE_DISABLE=1 tar -czf "$archive_tmp" MANIFEST home \
      state-plugins.json $([ -f extensions.txt ] && echo extensions.txt) 2>/dev/null) \
      || die "can't create the archive"
    chmod 600 "$archive_tmp"
    mv -f "$archive_tmp" "$SYNC_PATH" || die "can't write $SYNC_PATH"
  else
    rm -rf "$SYNC_PATH"
    mkdir -p "$(dirname "$SYNC_PATH")"
    mv "$out" "$SYNC_PATH" || die "can't move the export to $SYNC_PATH"
  fi

  say
  say "${GREEN}Export ready.${RESET} On the other Mac: ${BOLD}sync-cursor.sh import${RESET}"
  say "${YELLOW}Heads up:${RESET} mcp.json may hold plain-text tokens; don't commit $SYNC_PATH anywhere."
}

# ------------------------------------------------------------ info
cmd_info() {
  if is_archive; then
    ensure_local "$SYNC_PATH" || die "no export at $SYNC_PATH"
    mkdir -p "$WORK/src"
    tar -xzf "$SYNC_PATH" -C "$WORK/src" MANIFEST 2>/dev/null || die "can't read $SYNC_PATH (still syncing?)"
    SRC="$WORK/src"
  else
    SRC="$SYNC_PATH"
  fi
  [ -f "$SRC/MANIFEST" ] || die "no export at $SYNC_PATH"

  if [ "$PORCELAIN" -eq 1 ]; then
    cat "$SRC/MANIFEST"
    echo "this_machine_id=$(machine_id)"
    echo "last_import_epoch=$(cat "$LAST_IMPORT_FILE" 2>/dev/null || echo 0)"
    return
  fi
  print_manifest_header
  if [ "$(manifest_value machine_id)" = "$(machine_id)" ]; then
    echo "${DIM}Exported from this Mac.${RESET}"
  elif [ "$(manifest_value epoch)" -gt "$(cat "$LAST_IMPORT_FILE" 2>/dev/null || echo 0)" ]; then
    echo "${GREEN}Not imported on this Mac yet.${RESET}"
  else
    echo "${DIM}Already imported on this Mac.${RESET}"
  fi
}

# ------------------------------------------------------------ diff
cmd_diff() {
  local rel src dst output count state cli installed id stripped="$WORK/cli-config.json"
  local -a missing

  load_export
  print_manifest_header

  for rel in "${FILES[@]}"; do
    src="$SRC/home/$rel"; dst="$HOME/$rel"
    [ -f "$src" ] || continue
    if [ ! -f "$dst" ]; then
      line new "$rel" "new"
      continue
    fi
    if [ "$rel" = "$CLI_CONFIG" ]; then
      strip_session "$dst" "$stripped" 2>/dev/null
      dst="$stripped"
    fi
    if cmp -s "$src" "$dst"; then
      line same "$rel" "same"
    else
      line changed "$rel" "changes"
    fi
  done

  for rel in "${DIRS[@]}"; do
    src="$SRC/home/$rel"; dst="$HOME/$rel"
    [ -d "$src" ] || continue
    if [ ! -d "$dst" ]; then
      line new "$rel/" "new"
      continue
    fi
    output="$(diff -rq -x .DS_Store -x .system "$dst" "$src" 2>&1)"
    if [ -z "$output" ]; then
      line same "$rel/" "same"
    else
      count="$(printf '%s\n' "$output" | wc -l | tr -d ' ')"
      line changed "$rel/" "$count difference(s)"
      print_dir_diff "$rel/" "$output" "$dst" "$src"
    fi
  done

  if [ -f "$SRC/state-plugins.json" ] && [ -f "$STATE_DB" ]; then
    state="$(state_tool diff "$STATE_DB" "$SRC/state-plugins.json" 2>/dev/null)"
    case "$state" in
      same)    line same "installed plugins" "same" ;;
      changed) line changed "installed plugins" "changes" ;;
      *)       line error "installed plugins" "couldn't read state.vscdb" ;;
    esac
  fi

  cli="$(cursor_cli)"
  if [ -f "$SRC/extensions.txt" ] && [ -n "$cli" ]; then
    installed="$("$cli" --list-extensions 2>/dev/null)"
    missing=()
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      id="${id%@*}"
      printf '%s\n' "$installed" | grep -ixF "$id" >/dev/null || missing+=("$id")
    done < "$SRC/extensions.txt"
    if [ "${#missing[@]}" -eq 0 ]; then
      line same "extensions" "all installed"
    else
      line new "extensions" "${#missing[@]} to install"
      for id in "${missing[@]}"; do detail "extensions" "$id"; done
    fi
  fi
}

# ------------------------------------------------------------ import
cmd_import() {
  local backup rel src dst cli installed id answer problems=0

  load_export
  print_manifest_header

  if cursor_running; then
    die "Cursor is open. Quit it (Cmd+Q) and run the import from Terminal; otherwise Cursor overwrites settings, cli-config and plugins when it quits."
  fi

  if [ "$ASSUME_YES" -eq 0 ]; then
    printf "This replaces this Mac's Cursor setup (after backing it up). Continue? [y/N] "
    read -r answer
    case "$answer" in y|Y|s|S) ;; *) echo "Cancelled."; exit 0 ;; esac
    echo
  fi

  # Never reuse a backup: restoring one in the same second would overwrite it first
  backup="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  while [ -e "$backup" ]; do
    sleep 1
    backup="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  done
  mkdir -p "$backup/home" || die "can't create the backup at $backup"
  chmod 700 "$STATE_ROOT" "$BACKUP_ROOT" "$backup"
  write_manifest "$backup/MANIFEST" " (before import)" "$(manifest_value cursor)"

  for rel in "${FILES[@]}"; do
    src="$SRC/home/$rel"; dst="$HOME/$rel"
    [ -f "$src" ] || continue
    if [ -f "$dst" ]; then
      mkdir -p "$(dirname "$backup/home/$rel")"
      cp -p "$dst" "$backup/home/$rel"
    fi
    mkdir -p "$(dirname "$dst")"
    if [ "$rel" = "$CLI_CONFIG" ]; then
      merge_session "$src" "$dst" || { line error "$rel" "couldn't merge"; problems=1; continue; }
      line ok "$rel" "keeps this Mac's login session"
    else
      cp -p "$src" "$dst"
      line ok "$rel"
    fi
  done

  for rel in "${DIRS[@]}"; do
    src="$SRC/home/$rel"; dst="$HOME/$rel"
    [ -d "$src" ] || continue
    if [ -d "$dst" ]; then
      mkdir -p "$backup/home/$rel"
      rsync -a "$dst/" "$backup/home/$rel/"
    fi
    mkdir -p "$dst"
    if rsync -a --delete "${EXCLUDES[@]}" "$src/" "$dst/"; then
      line ok "$rel/"
    else
      line error "$rel/" "rsync failed"; problems=1
    fi
  done

  if [ -f "$SRC/state-plugins.json" ]; then
    if [ ! -f "$STATE_DB" ]; then
      line warn "installed plugins" "open Cursor once, quit it and import again"
    elif state_tool import "$STATE_DB" "$SRC/state-plugins.json" "$backup/state-plugins.json"; then
      line ok "installed plugins"
    else
      line error "installed plugins" "couldn't write state.vscdb"; problems=1
    fi
  fi

  cli="$(cursor_cli)"
  if [ "$SKIP_EXTENSIONS" -eq 1 ] || [ ! -f "$SRC/extensions.txt" ]; then
    :
  elif [ -z "$cli" ]; then
    line warn "extensions" "no 'cursor' CLI, install them by hand"
  else
    installed="$("$cli" --list-extensions 2>/dev/null)"
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      id="${id%@*}"
      printf '%s\n' "$installed" | grep -ixF "$id" >/dev/null && continue
      if "$cli" --install-extension "$id" >/dev/null 2>&1; then
        line ok "extension $id" "installed"
      else
        line error "extension $id" "couldn't install"; problems=1
      fi
    done < "$SRC/extensions.txt"
  fi

  manifest_value epoch > "$LAST_IMPORT_FILE"
  prune_backups

  if [ "$PORCELAIN" -eq 1 ]; then
    echo "backup=$backup"
  else
    echo
    echo "Previous setup backed up to ${BOLD}$backup${RESET}"
    echo "${DIM}OAuth MCP servers will ask you to log in again the first time you open Cursor.${RESET}"
  fi
  if [ "$problems" -eq 1 ]; then
    say "${YELLOW}Import finished with errors (see above).${RESET}"
    exit 1
  fi
  say "${GREEN}Import done. You can open Cursor now.${RESET}"
}

case "$COMMAND" in
  export) cmd_export ;;
  diff)   cmd_diff ;;
  import) cmd_import ;;
  info)   cmd_info ;;
  "")     usage 1 ;;
  *)      echo "Unknown command: $COMMAND" >&2; usage 1 ;;
esac
