#!/usr/bin/env bash
#
# test-sync.sh — end-to-end test of sync-cursor.sh: exports one fake home
# directory and imports it into another. `ps` and `cursor` are stubbed, so it
# never touches your real Cursor setup.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$ROOT/sync-cursor.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

check() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   $description"
  else
    echo "FAIL $description"
    FAILURES=$((FAILURES + 1))
  fi
}

json_value() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]] if len(sys.argv) > 3 else json.load(open(sys.argv[1]))[sys.argv[2]])' "$@"; }
plugin_value() { sqlite3 "$1/Library/Application Support/Cursor/User/globalStorage/state.vscdb" "SELECT value FROM ItemTable WHERE key = '$2'"; }

# ------------------------------------------------------------ stubs
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ps" <<'SH'
#!/bin/sh
[ "${FAKE_CURSOR_RUNNING:-0}" = 1 ] && echo /Applications/Cursor.app/Contents/MacOS/Cursor
exit 0
SH
cat > "$WORK/bin/cursor" <<'SH'
#!/bin/sh
list="$HOME/.fake-extensions"
case "$1" in
  --version) echo 9.9.9 ;;
  --list-extensions)
    [ -f "$list" ] || exit 0
    if [ "${2:-}" = --show-versions ]; then cat "$list"; else sed 's/@.*//' "$list"; fi ;;
  --install-extension) echo "$2@1.0.0" >> "$list" ;;
esac
exit 0
SH
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

# ------------------------------------------------------------ fake homes
make_home() {
  local user="$1/Library/Application Support/Cursor/User"
  mkdir -p "$1/.cursor" "$user/globalStorage" "$1/.agents/skills" "$1/.codex/skills"
  sqlite3 "$user/globalStorage/state.vscdb" \
    "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)"
}

A="$WORK/mac-a"; B="$WORK/mac-b"; ARCHIVE="$WORK/icloud/Cursito/cursor-sync.tar.gz"
make_home "$A"; make_home "$B"
A_USER="$A/Library/Application Support/Cursor/User"
B_USER="$B/Library/Application Support/Cursor/User"
PLUGINS_KEY='cursor.plugins.installedIds.1|no-workspace'

echo '{"mcpServers":{"x":{"url":"https://example.com","headers":{"Authorization":"Bearer t"}}}}' > "$A/.cursor/mcp.json"
chmod 600 "$A/.cursor/mcp.json"
echo '{"authInfo":{"email":"a@example.com"},"model":"from-a"}' > "$A/.cursor/cli-config.json"
echo '{"editor.fontSize": 16}' > "$A_USER/settings.json"
mkdir -p "$A/.agents/skills/shared" "$A/.claude/skills" "$A/.codex/skills/mine"
echo shared > "$A/.agents/skills/shared/SKILL.md"
echo mine > "$A/.codex/skills/mine/SKILL.md"
ln -s ../../.agents/skills/shared "$A/.claude/skills/shared"
sqlite3 "$A_USER/globalStorage/state.vscdb" "INSERT INTO ItemTable VALUES ('$PLUGINS_KEY', '[{\"id\":\"1\"}]')"
echo "foo.bar@1.2.3" > "$A/.fake-extensions"

echo '{"authInfo":{"email":"b@example.com"},"model":"old"}' > "$B/.cursor/cli-config.json"
echo '{"old": true}' > "$B_USER/settings.json"
mkdir -p "$B/.agents/skills/only-b" "$B/.codex/skills/.system/keep"
echo only-b > "$B/.agents/skills/only-b/SKILL.md"
sqlite3 "$B_USER/globalStorage/state.vscdb" \
  "INSERT INTO ItemTable VALUES ('cursor.plugins.installedIds.1|file:///stale', '[]'), ('unrelated.key', 'keep')"

# ------------------------------------------------------------ export
HOME="$A" bash "$SCRIPT" export -d "$ARCHIVE" >/dev/null
check "export writes the archive" test -f "$ARCHIVE"
check "archive is private (600)" test "$(stat -f %Lp "$ARCHIVE")" = 600
EXPORTED_CLI_CONFIG="$(tar -xzOf "$ARCHIVE" home/.cursor/cli-config.json)"
check "exported cli-config has no session" \
  bash -c 'grep -q from-a <<< "$1" && ! grep -q authInfo <<< "$1"' _ "$EXPORTED_CLI_CONFIG"

INFO="$(HOME="$B" bash "$SCRIPT" info -p -d "$ARCHIVE")"
EPOCH="$(printf '%s\n' "$INFO" | sed -n 's/^epoch=//p')"
check "info reports the export and no previous import" \
  grep -qx 'last_import_epoch=0' <<< "$INFO"

# ------------------------------------------------------------ import
check "import refuses while Cursor is open" \
  bash -c "! FAKE_CURSOR_RUNNING=1 HOME='$B' bash '$SCRIPT' import -y -d '$ARCHIVE'"
check "refused import leaves settings alone" grep -q old "$B_USER/settings.json"

HOME="$B" bash "$SCRIPT" import -y -d "$ARCHIVE" >/dev/null

check "cli-config keeps this Mac's session" test "$(json_value "$B/.cursor/cli-config.json" authInfo email)" = b@example.com
check "cli-config gets the exported settings" test "$(json_value "$B/.cursor/cli-config.json" model)" = from-a
check "mcp.json is copied" cmp "$A/.cursor/mcp.json" "$B/.cursor/mcp.json"
check "mcp.json stays private (600)" test "$(stat -f %Lp "$B/.cursor/mcp.json")" = 600
check "settings.json is copied" cmp "$A_USER/settings.json" "$B_USER/settings.json"
check "skills are mirrored" test -f "$B/.agents/skills/shared/SKILL.md" -a ! -e "$B/.agents/skills/only-b"
check "skill symlinks survive" test -L "$B/.claude/skills/shared" -a -f "$B/.claude/skills/shared/SKILL.md"
check "Codex .system is kept" test -d "$B/.codex/skills/.system/keep"
check "installed plugins are copied" test "$(plugin_value "$B" "$PLUGINS_KEY")" = '[{"id":"1"}]'
check "stale plugin keys are removed" test -z "$(plugin_value "$B" 'cursor.plugins.installedIds.1|file:///stale')"
check "unrelated state is kept" test "$(plugin_value "$B" unrelated.key)" = keep
check "missing extensions are installed" grep -q '^foo.bar@' "$B/.fake-extensions"
check "last import is recorded" test "$(cat "$B/.cursito/last-import")" = "$EPOCH"

DIFF="$(HOME="$B" bash "$SCRIPT" diff -p -d "$ARCHIVE")"
check "diff lists the synced items" grep -q "^ITEM"$'\t'"same"$'\t'".cursor/mcp.json" <<< "$DIFF"
check "nothing left to change after import" \
  bash -c '! grep -qE "^ITEM$1(changed|new)$1" <<< "$2"' _ $'\t' "$DIFF"
check "an MCP server with a token can start" grep -q "^ITEM"$'\t'"ok"$'\t'"MCP servers" <<< "$DIFF"

echo '{"mcpServers":{"py":{"command":"uvx-not-installed"},"ok":{"command":"sh"}}}' > "$A/.cursor/mcp.json"
HOME="$A" bash "$SCRIPT" export -d "$ARCHIVE" >/dev/null
DIFF="$(HOME="$B" bash "$SCRIPT" diff -p -d "$ARCHIVE")"
check "an MCP server whose command is missing is flagged" \
  grep -q "^DETAIL"$'\t'"MCP servers"$'\t'"py: needs 'uvx-not-installed'" <<< "$DIFF"
check "an MCP server whose command exists isn't" bash -c '! grep -q "ok:" <<< "$1"' _ "$DIFF"

# ------------------------------------------------------------ restore
BACKUP="$(ls -d "$B/.cursito/backups/"2* | tail -1)"
check "backup holds the previous settings" grep -q old "$BACKUP/home/Library/Application Support/Cursor/User/settings.json"
HOME="$B" bash "$SCRIPT" import -y -d "$BACKUP" >/dev/null
check "restoring a backup brings the settings back" grep -q old "$B_USER/settings.json"
check "restoring a backup brings the plugin keys back" test -n "$(plugin_value "$B" 'cursor.plugins.installedIds.1|file:///stale')"

# ------------------------------------------------------------ previous exports
PREVIOUS="$(dirname "$ARCHIVE")/previous-exports"
check "replacing an export keeps the previous one" test "$(ls "$PREVIOUS" | wc -l | tr -d ' ')" = 1
check "a previous export is named after its date and host" \
  bash -c 'ls "$1" | grep -qE "^[0-9]{8}-[0-9]{6} .+\.tar\.gz$"' _ "$PREVIOUS"
FIRST_PREVIOUS="$(ls "$PREVIOUS" | head -1)"
check "a previous export keeps its original manifest" \
  test "$(tar -xzOf "$PREVIOUS/$FIRST_PREVIOUS" MANIFEST | sed -n 's/^epoch=//p')" = "$EPOCH"
for i in 1 2 3; do
  sleep 1
  HOME="$A" bash "$SCRIPT" export -d "$ARCHIVE" >/dev/null
done
check "only the last 3 previous exports are kept" test "$(ls "$PREVIOUS" | wc -l | tr -d ' ')" = 3
check "the oldest previous export is the one dropped" test ! -e "$PREVIOUS/$FIRST_PREVIOUS"
check "a previous export can be imported" \
  bash -c 'HOME="$1" bash "$2" verify -p -d "$3/$(ls "$3" | tail -1)"' _ "$B" "$SCRIPT" "$PREVIOUS"

# ------------------------------------------------------------ encryption
SECRET="$WORK/icloud/Cursito/secret.tar.gz"
PASSPHRASE="correct horse battery"
env CURSITO_PASSPHRASE="$PASSPHRASE" HOME="$A" bash "$SCRIPT" export -d "$SECRET" >/dev/null
check "encrypted export hides the setup" bash -c '! tar -tzf "$1" | grep -q "^home/"' _ "$SECRET"
check "encrypted export keeps the manifest readable" \
  bash -c 'HOME="$1" bash "$2" info -p -d "$3" | grep -qx encrypted=1' _ "$B" "$SCRIPT" "$SECRET"
check "reading it without the passphrase exits with 3" \
  bash -c 'HOME="$1" bash "$2" verify -p -d "$3" </dev/null; test $? -eq 3' _ "$B" "$SCRIPT" "$SECRET"
check "a wrong passphrase exits with 3" \
  bash -c 'CURSITO_PASSPHRASE=wrong HOME="$1" bash "$2" verify -p -d "$3"; test $? -eq 3' _ "$B" "$SCRIPT" "$SECRET"
check "the right passphrase reads it" \
  env CURSITO_PASSPHRASE="$PASSPHRASE" HOME="$B" bash "$SCRIPT" verify -p -d "$SECRET"
echo '{"from": "b"}' > "$B_USER/settings.json"
env CURSITO_PASSPHRASE="$PASSPHRASE" HOME="$B" bash "$SCRIPT" import -y -d "$SECRET" >/dev/null
check "an encrypted export imports" cmp "$A_USER/settings.json" "$B_USER/settings.json"
check "an encrypted import records the export" \
  test "$(cat "$B/.cursito/last-import")" = "$(tar -xzOf "$SECRET" MANIFEST | sed -n 's/^epoch=//p')"

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "All checks passed"
