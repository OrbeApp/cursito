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
#   sync-cursor.sh verify        # check the export can be read (and decrypted)
#   sync-cursor.sh status        # what changed on this Mac since its last export or import
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
# With CURSITO_PASSPHRASE set, export encrypts everything but the MANIFEST
# (AES-256-CBC, key from PBKDF2-SHA256 with 600,000 iterations). Reading an
# encrypted export needs the same passphrase; without it, or with a wrong one,
# the script exits with status 3 (in a terminal it asks for it instead).
#
# Exporting to an archive keeps the export it replaces in previous-exports/
# next to it (last 3), named "<date> <host>.tar.gz"; import one with -d to
# undo an export.
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
LAST_SYNC_FILE="$STATE_ROOT/last-sync"
BACKUPS_KEPT=5
EXPORTS_KEPT=3
PREVIOUS_EXPORTS="previous-exports"
MANIFEST_FORMAT=1
SKIP_EXTENSIONS=0
ASSUME_YES=0
PORCELAIN=0
PASSPHRASE_STATUS=3
CIPHER=(enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256)

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
die_passphrase() { echo "${RED}error:${RESET} $*" >&2; exit "$PASSPHRASE_STATUS"; }

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
  [ "$(manifest_value encrypted)" = 1 ] && decrypt_payload
  return 0
}

# Swaps SRC for a directory with the decrypted payload and the MANIFEST
decrypt_payload() {
  local plain="$WORK/plain"
  [ -f "$SRC/payload.enc" ] || die "the encrypted export is incomplete (still syncing?)"
  if [ -z "${CURSITO_PASSPHRASE:-}" ] && [ -t 0 ] && [ "$PORCELAIN" -eq 0 ]; then
    read -rsp "Passphrase for this export: " CURSITO_PASSPHRASE; echo >&2
    export CURSITO_PASSPHRASE
  fi
  [ -n "${CURSITO_PASSPHRASE:-}" ] || die_passphrase "this export is encrypted and needs its passphrase"
  mkdir -p "$plain"
  openssl "${CIPHER[@]}" -d -pass env:CURSITO_PASSPHRASE -in "$SRC/payload.enc" 2>/dev/null \
    | tar -xzf - -C "$plain" 2>/dev/null \
    || die_passphrase "wrong passphrase for this export"
  cp "$SRC/MANIFEST" "$plain/MANIFEST"
  SRC="$plain"
}

# What an export holds besides the MANIFEST
payload_files() {
  local name
  for name in home state-plugins.json extensions.txt; do
    [ -e "$1/$name" ] && echo "$name"
  done
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

# Fingerprint of this Mac's synced setup, one "<item><TAB><sha256>" line per item named
# as in `diff`; "missing" when it doesn't exist, "-" when it can't be read (not compared).
# Contents only, so a rewrite that changes nothing doesn't count.
write_snapshot() {
  local out="$1" cli extensions="$WORK/snapshot-extensions.txt"
  cli="$(cursor_cli)"
  if [ -z "$cli" ] || ! "$cli" --list-extensions > "$extensions" 2>/dev/null; then
    rm -f "$extensions"
  fi
  python3 - "$out" "$HOME" "$STATE_DB" "$extensions" "$CLI_CONFIG" "${SESSION_KEYS[*]}" \
    "${FILES[@]}" --dirs "${DIRS[@]}" <<'PY'
import hashlib, json, os, sqlite3, sys
from urllib.parse import quote

out, home, db, extensions, cli_config, session_keys = sys.argv[1:7]
rest = sys.argv[7:]
files, dirs = rest[:rest.index("--dirs")], rest[rest.index("--dirs") + 1:]
# Same exclusions as the rsync copies
SKIPPED = {".DS_Store", ".system"}

def sha(data):
    return hashlib.sha256(data).hexdigest()

def file_hash(rel):
    path = os.path.join(home, rel)
    if not os.path.isfile(path):
        return "missing"
    with open(path, "rb") as f:
        data = f.read()
    if rel == cli_config:
        try:
            config = json.loads(data)
            for key in session_keys.split():
                config.pop(key, None)
            data = json.dumps(config, sort_keys=True).encode()
        except ValueError:
            pass
    return sha(data)

def dir_hash(rel):
    top = os.path.join(home, rel)
    if not os.path.isdir(top):
        return "missing"
    entries = []
    for root, subdirs, names in os.walk(top):
        subdirs[:] = sorted(d for d in subdirs if d not in SKIPPED)
        for name in sorted(set(names) | set(subdirs)):
            path = os.path.join(root, name)
            short = os.path.relpath(path, top)
            if os.path.islink(path):
                entries.append(f"L {short} {os.readlink(path)}")
                if name in subdirs:
                    subdirs.remove(name)
            elif name in names and name not in SKIPPED:
                with open(path, "rb") as f:
                    entries.append(f"F {short} {sha(f.read())}")
    return sha("\n".join(entries).encode())

def plugins_hash():
    try:
        con = sqlite3.connect(f"file:{quote(db)}?mode=ro", uri=True)
        rows = con.execute(
            "SELECT key, value FROM ItemTable WHERE key >= ? AND key < ?",
            ("cursor.plugins.installedIds.", "cursor.plugins.installedIds/"),
        ).fetchall()
    except sqlite3.Error:
        return "-"
    data = {k: v.decode() if isinstance(v, bytes) else v for k, v in rows}
    return sha(json.dumps(data, sort_keys=True).encode())

def extensions_hash():
    if not os.path.isfile(extensions):
        return "-"
    with open(extensions) as f:
        ids = {line.strip().split("@")[0].lower() for line in f if line.strip()}
    return sha("\n".join(sorted(ids)).encode())

with open(out, "w") as f:
    for rel in files:
        f.write(f"{rel}\t{file_hash(rel)}\n")
    for rel in dirs:
        f.write(f"{rel}/\t{dir_hash(rel)}\n")
    f.write(f"installed plugins\t{plugins_hash()}\n")
    f.write(f"extensions\t{extensions_hash()}\n")
PY
}

# Remembers this Mac's setup right after an export or import, for `status`
save_last_sync() {
  local snapshot="$WORK/last-sync"
  mkdir -p "$STATE_ROOT" && chmod 700 "$STATE_ROOT"
  if write_snapshot "$snapshot.items"; then
    { printf 'kind=%s\nepoch=%s\n' "$1" "$(date +%s)"; cat "$snapshot.items"; } > "$snapshot"
    mv -f "$snapshot" "$LAST_SYNC_FILE"
  else
    rm -f "$LAST_SYNC_FILE"
  fi
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

# Where MCP commands usually live; apps opened from Finder don't get the shell's PATH
mcp_command_path() {
  local dirs=("$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin" "$HOME/.volta/bin"
    "$HOME/.deno/bin" "$HOME/.local/share/mise/shims" "$HOME/.asdf/shims"
    /opt/homebrew/bin /usr/local/bin) dir
  for dir in "$HOME"/.nvm/versions/node/*/bin "$HOME"/.fnm/node-versions/*/installation/bin; do
    [ -d "$dir" ] && dirs+=("$dir")
  done
  local IFS=:
  echo "${dirs[*]}:$PATH"
}

# MCP servers in the export that won't start, or will ask for a login, on this Mac
check_mcp_servers() {
  local file="$1" servers="$WORK/mcp-servers.tsv" kind name value has_auth total=0 search_path
  local missing=() logins=() locals=() summary=() note
  [ -f "$file" ] || return 0
  # A file, not <(…): bash 3.2 mangles a heredoc inside process substitution
  python3 - "$file" > "$servers" <<'PY'
import json, os, shlex, sys
from urllib.parse import urlparse
try:
    with open(sys.argv[1]) as f:
        servers = json.load(f).get("mcpServers") or {}
except (ValueError, AttributeError):
    print("invalid\t-\t-\t0")
    sys.exit(0)
for name, server in servers.items():
    if not isinstance(server, dict):
        continue
    name = name.replace("\t", " ")
    if server.get("command"):
        # Cursor also accepts the arguments inline: "npx -y package"
        try:
            words = shlex.split(server["command"])
        except ValueError:
            words = server["command"].split()
        print(f"command\t{name}\t{words[0] if words else server['command']}\t0")
        for arg in words[1:] + (server.get("args") or []):
            if isinstance(arg, str) and arg.startswith(("/", "~/")) and not os.path.exists(os.path.expanduser(arg)):
                print(f"path\t{name}\t{arg}\t0")
    elif server.get("url"):
        host = urlparse(server["url"]).hostname or ""
        if host in ("localhost", "127.0.0.1", "::1"):
            print(f"local\t{name}\t{urlparse(server['url']).netloc}\t0")
            continue
        headers = set(key.lower() for key in (server.get("headers") or {}))
        has_auth = int(bool(headers.intersection(["authorization", "x-api-key", "api-key"])))
        print(f"url\t{name}\t{host}\t{has_auth}")
PY
  search_path="$(mcp_command_path)"
  while IFS=$'\t' read -r kind name value has_auth; do
    total=$((total + 1))
    case "$kind" in
      command)
        if [[ "$value" == /* || "$value" == "~/"* ]]; then
          [ -x "${value/#\~/$HOME}" ] || missing+=("$name: $value doesn't exist on this Mac")
        elif ! PATH="$search_path" command -v "$value" >/dev/null 2>&1; then
          missing+=("$name: needs '$value', not installed on this Mac")
        fi ;;
      path)
        missing+=("$name: uses $value, which doesn't exist on this Mac") ;;
      local)
        locals+=("$name: served by an app at $value, which has to be running") ;;
      url)
        [ "$has_auth" = 1 ] || logins+=("$name: $value may ask you to log in (OAuth tokens aren't synced)") ;;
      invalid)
        line warn "MCP servers" "mcp.json isn't valid JSON"; return ;;
    esac
  done < "$servers"
  [ "$total" -eq 0 ] && return 0

  [ "${#missing[@]}" -gt 0 ] && summary+=("${#missing[@]} won't start")
  [ "${#logins[@]}" -gt 0 ] && summary+=("${#logins[@]} may ask you to log in")
  case "${#locals[@]}" in
    0) ;;
    1) summary+=("1 needs its app running") ;;
    *) summary+=("${#locals[@]} need their app running") ;;
  esac
  if [ "${#summary[@]}" -eq 0 ]; then
    line ok "MCP servers" "all can start on this Mac"
    return
  fi
  local text="${summary[0]}" i
  for ((i = 1; i < ${#summary[@]}; i++)); do text+=", ${summary[$i]}"; done
  if [ "${#missing[@]}" -gt 0 ]; then
    line warn "MCP servers" "$text"
  else
    line ok "MCP servers" "$text"
  fi
  for note in ${missing[@]+"${missing[@]}"} ${logins[@]+"${logins[@]}"} ${locals[@]+"${locals[@]}"}; do
    detail "MCP servers" "$note"
  done
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

# Copies the archive about to be replaced into previous-exports/ (an APFS clone,
# so no extra space on this Mac) and keeps the last $EXPORTS_KEPT
keep_previous_export() {
  local dir manifest epoch host name entry entries=() i
  [ -f "$SYNC_PATH" ] || return 0
  dir="$(dirname "$SYNC_PATH")/$PREVIOUS_EXPORTS"
  if ! mkdir -p "$dir"; then
    line warn "previous export" "can't create $dir"
    return 0
  fi
  chmod 700 "$dir"

  manifest="$(tar -xzOf "$SYNC_PATH" MANIFEST 2>/dev/null)"
  epoch="$(printf '%s\n' "$manifest" | sed -n 's/^epoch=//p')"
  host="$(printf '%s\n' "$manifest" | sed -n 's/^host=//p' | tr -d '/:')"
  case "$epoch" in ''|*[!0-9]*) epoch="$(stat -f %m "$SYNC_PATH")" ;; esac
  name="$(date -r "$epoch" +%Y%m%d-%H%M%S) ${host:-unknown}.tar.gz"
  if cp -c "$SYNC_PATH" "$dir/$name" 2>/dev/null || cp -p "$SYNC_PATH" "$dir/$name"; then
    chmod 600 "$dir/$name"
    line ok "previous export" "kept in $PREVIOUS_EXPORTS/"
  else
    line warn "previous export" "couldn't keep a copy"
  fi

  # Names start with the date, so the glob lists them oldest first
  for entry in "$dir"/2*.tar.gz; do
    [ -f "$entry" ] && entries+=("$entry")
  done
  i=0
  while [ $((${#entries[@]} - i)) -gt "$EXPORTS_KEPT" ]; do
    rm -f "${entries[$i]}"
    i=$((i + 1))
  done
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

  if [ -n "${CURSITO_PASSPHRASE:-}" ]; then
    # shellcheck disable=SC2046 # payload_files prints names without spaces
    (cd "$out" && COPYFILE_DISABLE=1 tar -czf - $(payload_files .) 2>/dev/null) \
      | openssl "${CIPHER[@]}" -salt -pass env:CURSITO_PASSPHRASE -out "$out/payload.enc" \
      || die "can't encrypt the export"
    # shellcheck disable=SC2046
    (cd "$out" && rm -rf $(payload_files .))
    echo "encrypted=1" >> "$out/MANIFEST"
    line ok "encryption" "AES-256, with your passphrase"
  fi

  if is_archive; then
    mkdir -p "$(dirname "$SYNC_PATH")" || die "can't create $(dirname "$SYNC_PATH")"
    archive_tmp="$WORK/export.tar.gz"
    # MANIFEST first so `info` stops reading early; no AppleDouble ._ files
    # shellcheck disable=SC2046
    (cd "$out" && COPYFILE_DISABLE=1 tar -czf "$archive_tmp" MANIFEST \
      $(payload_files .) $([ -f payload.enc ] && echo payload.enc) 2>/dev/null) \
      || die "can't create the archive"
    chmod 600 "$archive_tmp"
    keep_previous_export
    mv -f "$archive_tmp" "$SYNC_PATH" || die "can't write $SYNC_PATH"
  else
    rm -rf "$SYNC_PATH"
    mkdir -p "$(dirname "$SYNC_PATH")"
    mv "$out" "$SYNC_PATH" || die "can't move the export to $SYNC_PATH"
  fi
  save_last_sync export

  say
  say "${GREEN}Export ready.${RESET} On the other Mac: ${BOLD}sync-cursor.sh import${RESET}"
  if [ -z "${CURSITO_PASSPHRASE:-}" ]; then
    say "${YELLOW}Heads up:${RESET} mcp.json may hold plain-text tokens; don't commit $SYNC_PATH anywhere."
  fi
}

# ------------------------------------------------------------ verify
cmd_verify() {
  load_export
  say "${GREEN}The export can be read.${RESET}"
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

# ------------------------------------------------------------ status
# Items whose contents changed since this Mac's last export or import. Doesn't read
# the sync location, so it's cheap and works with the export still in iCloud.
cmd_status() {
  local current="$WORK/snapshot" kind epoch item state count=0
  if [ ! -f "$LAST_SYNC_FILE" ]; then
    [ "$PORCELAIN" -eq 1 ] && echo "last_sync=none" \
      || echo "No export or import on this Mac yet; run one to start tracking changes."
    return 0
  fi
  kind="$(sed -n 's/^kind=//p' "$LAST_SYNC_FILE")"
  epoch="$(sed -n 's/^epoch=//p' "$LAST_SYNC_FILE")"
  write_snapshot "$current" || die "couldn't read this Mac's setup"

  if [ "$PORCELAIN" -eq 1 ]; then
    echo "last_sync=$kind"
    echo "last_sync_epoch=$epoch"
  else
    echo "Since the last $kind on this Mac (${BOLD}$(date -r "$epoch" '+%Y-%m-%d %H:%M')${RESET}):"
    echo
  fi
  while IFS=$'\t' read -r item state; do
    count=$((count + 1))
    case "$state" in
      new)     line new "$item" "new on this Mac" ;;
      deleted) line changed "$item" "deleted" ;;
      *)       line changed "$item" "changed" ;;
    esac
  done < <(awk -F'\t' '
    NR == FNR { if (NF == 2) saved[$1] = $2; next }
    ($1 in saved) && saved[$1] != "-" && $2 != "-" && saved[$1] != $2 {
      print $1 "\t" (saved[$1] == "missing" ? "new" : $2 == "missing" ? "deleted" : "changed")
    }' "$LAST_SYNC_FILE" "$current")
  [ "$count" -eq 0 ] && say "${GREEN}No changes.${RESET}"
  return 0
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

  check_mcp_servers "$SRC/home/.cursor/mcp.json"
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
  save_last_sync import

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
  verify) cmd_verify ;;
  status) cmd_status ;;
  "")     usage 1 ;;
  *)      echo "Unknown command: $COMMAND" >&2; usage 1 ;;
esac
