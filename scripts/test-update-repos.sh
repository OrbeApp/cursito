#!/usr/bin/env bash
#
# test-update-repos.sh — end-to-end test of update-repos.sh against throwaway
# git repos: one clone per state the script reports.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$ROOT/update-repos.sh"
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

export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name Test
git config --global user.email test@example.com
git config --global init.defaultBranch main

commit() { (cd "$1" && echo "$2" > "$2.txt" && git add "$2.txt" && git commit -qm "$2"); }

# One remote; each clone in $REPOS ends up in a different state
git init -q --bare "$WORK/remote.git"
git clone -q "$WORK/remote.git" "$WORK/seed" 2>/dev/null
commit "$WORK/seed" first
(cd "$WORK/seed" && git push -q origin main)

REPOS="$WORK/repos"
mkdir -p "$REPOS"
for name in up-to-date behind ahead dirty diverged detached; do
  git clone -q "$WORK/remote.git" "$REPOS/$name"
done
mkdir "$REPOS/not-a-repo"
git init -q "$REPOS/no-upstream"
commit "$REPOS/no-upstream" local

commit "$WORK/seed" second
(cd "$WORK/seed" && git push -q origin main)
(cd "$REPOS/up-to-date" && git pull -q)
commit "$REPOS/ahead" unpushed
(cd "$REPOS/ahead" && git pull -q --rebase)
echo change >> "$REPOS/dirty/first.txt"
commit "$REPOS/diverged" local-only
(cd "$REPOS/detached" && git checkout -q --detach)

state_of() { awk -F'\t' -v repo="$2" '$1 == "REPO" && $3 == repo { print $2 }' <<< "$1"; }

# ------------------------------------------------------------ fetch only
OUTPUT="$(bash "$SCRIPT" -C "$REPOS" -p -f || true)"
check "fetch only reports behind without pulling" test "$(state_of "$OUTPUT" behind)" = BEHIND
check "fetch only leaves the working tree alone" test ! -e "$REPOS/behind/second.txt"

# ------------------------------------------------------------ pull
set +e
OUTPUT="$(bash "$SCRIPT" -C "$REPOS" -p)"
STATUS=$?
set -e

check "pulls a repo that is behind" test "$(state_of "$OUTPUT" behind)" = PULLED
check "pulled repo has the new commit" test -f "$REPOS/behind/second.txt"
check "reports an up-to-date repo" test "$(state_of "$OUTPUT" up-to-date)" = OK
check "reports unpushed commits" test "$(state_of "$OUTPUT" ahead)" = AHEAD
check "leaves a dirty repo alone" test "$(state_of "$OUTPUT" dirty)" = DIRTY
check "dirty changes are kept" grep -q change "$REPOS/dirty/first.txt"
check "leaves a diverged repo alone" test "$(state_of "$OUTPUT" diverged)" = DIVERGED
check "skips a detached HEAD" test "$(state_of "$OUTPUT" detached)" = SKIP
check "skips a repo without upstream" test "$(state_of "$OUTPUT" no-upstream)" = SKIP
check "ignores folders that aren't repos" test -z "$(state_of "$OUTPUT" not-a-repo)"
check "exits 1 when a repo needs attention" test "$STATUS" = 1

wip_of() { awk -F'\t' -v repo="$2" '$1 == "WIP" && $2 == repo { print $3 }' <<< "$1"; }
check "counts uncommitted changes" test "$(wip_of "$OUTPUT" dirty)" = 1
check "a clean repo has no uncommitted changes" test -z "$(wip_of "$OUTPUT" up-to-date)"

echo new > "$REPOS/up-to-date/notes.txt"
OUTPUT="$(bash "$SCRIPT" -C "$REPOS" -p -f up-to-date)"
check "an up-to-date repo still reports work in progress" \
  test "$(state_of "$OUTPUT" up-to-date)/$(wip_of "$OUTPUT" up-to-date)" = OK/1
rm "$REPOS/up-to-date/notes.txt"

OUTPUT="$(bash "$SCRIPT" -C "$REPOS" -p up-to-date)"
check "only updates the named repos" test "$(grep -c '^REPO' <<< "$OUTPUT")" = 1

echo
if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "All checks passed"
