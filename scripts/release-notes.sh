#!/usr/bin/env bash
#
# release-notes.sh — prints the GitHub release notes for a version: its
# CHANGELOG.md section plus install steps. Fails when the section is missing.
#
# Usage:
#   scripts/release-notes.sh 1.1.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: release-notes.sh VERSION}"

notes="$(awk -v heading="## [$VERSION]" '
  index($0, heading) == 1 { found = 1; next }
  found && (/^## \[/ || /^\[[^]]+\]: /) { exit }
  found { print }
' "$ROOT/CHANGELOG.md")"

if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
  echo "error: CHANGELOG.md has no section for $VERSION" >&2
  exit 1
fi

printf '%s\n' "$notes" | sed -e '/./,$!d'
cat <<'EOF'

### Install

Unzip `Cursito.zip` and move `Cursito.app` to `/Applications`. This build is signed ad hoc, not notarized: the first time, right-click the app and choose **Open**, or run `xattr -dr com.apple.quarantine /Applications/Cursito.app`. Building from source with `scripts/build-app.sh --install` avoids the warning.
EOF
