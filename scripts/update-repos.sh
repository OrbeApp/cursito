#!/usr/bin/env bash
#
# update-repos.sh — fetch + fast-forward pull of every git repo directly
# inside a folder.
#
# Usage:
#   update-repos.sh                 # every repo in the current folder
#   update-repos.sh -C ~/code       # every repo in ~/code
#   update-repos.sh -f              # fetch only, never touches working trees
#   update-repos.sh -j 8            # parallel jobs (default 6)
#   update-repos.sh -p              # machine-readable output, used by Cursito.app
#   update-repos.sh api web         # only these repos
#
# Never merges or rebases on its own: a diverged branch or a dirty working
# tree is reported and left alone. Exits 1 when a repo needs attention.

set -uo pipefail

ROOT="$PWD"
FETCH_ONLY=0
JOBS=6
PORCELAIN=0

usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

while getopts ":C:fj:ph" opt; do
  case "$opt" in
    C) ROOT="${OPTARG%/}" ;;
    f) FETCH_ONLY=1 ;;
    j) JOBS="$OPTARG" ;;
    p) PORCELAIN=1 ;;
    h) usage 0 ;;
    *) echo "Invalid option: -$OPTARG" >&2; usage 1 ;;
  esac
done
shift $((OPTIND - 1))

[ -d "$ROOT" ] || { echo "error: $ROOT isn't a folder" >&2; exit 1; }
ROOT="$(cd "$ROOT" && pwd)"

if [ -t 1 ] && [ "$PORCELAIN" -eq 0 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=; DIM=; RED=; GREEN=; YELLOW=; BLUE=; RESET=
fi

# Nobody can answer a credentials prompt here: fail instead of hanging
export GIT_TERMINAL_PROMPT=0

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT

# ---------------------------------------------------------------- repos
repos=()
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    if [ -d "$ROOT/$name/.git" ]; then
      repos+=("$ROOT/$name")
    else
      echo "${YELLOW}warning:${RESET} '$name' isn't a git repo in $ROOT" >&2
    fi
  done
else
  for dir in "$ROOT"/*/; do
    [ -d "$dir/.git" ] && repos+=("${dir%/}")
  done
fi

if [ "${#repos[@]}" -eq 0 ]; then
  echo "error: no git repos found in $ROOT" >&2
  exit 1
fi

# ------------------------------------------------------------ one repo
# Writes "state<TAB>repo<TAB>detail" to $out.status and git's own errors to $out.log
update_repo() {
  local dir="$1" out="$2"
  local name branch upstream counts ahead behind err
  name="$(basename "$dir")"

  cd "$dir" || { printf 'ERROR\t%s\tcan'"'"'t enter the folder\n' "$name" > "$out.status"; return; }

  branch="$(git symbolic-ref --short -q HEAD)"
  if [ -z "$branch" ]; then
    printf 'SKIP\t%s\tdetached HEAD\n' "$name" > "$out.status"
    return
  fi

  if ! err="$(git fetch --prune --tags --quiet 2>&1)"; then
    printf 'ERROR\t%s\tfetch failed\n' "$name" > "$out.status"
    printf '%s\n' "$err" > "$out.log"
    return
  fi
  [ -n "$err" ] && printf '%s\n' "$err" > "$out.log"

  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  if [ -z "$upstream" ]; then
    printf 'SKIP\t%s\t%s has no upstream branch\n' "$name" "$branch" > "$out.status"
    return
  fi

  counts="$(git rev-list --left-right --count "HEAD...@{u}" 2>/dev/null)"
  ahead="$(printf '%s' "$counts" | cut -f1)"
  behind="$(printf '%s' "$counts" | cut -f2)"
  : "${ahead:=0}" "${behind:=0}"

  if [ "$behind" -eq 0 ] && [ "$ahead" -eq 0 ]; then
    printf 'OK\t%s\t%s up to date\n' "$name" "$branch" > "$out.status"
    return
  fi

  if [ "$behind" -eq 0 ]; then
    printf 'AHEAD\t%s\t%s has %s unpushed commit(s)\n' "$name" "$branch" "$ahead" > "$out.status"
    return
  fi

  if [ "$ahead" -gt 0 ]; then
    printf 'DIVERGED\t%s\t%s: %s local / %s remote — needs a manual merge or rebase\n' \
      "$name" "$branch" "$ahead" "$behind" > "$out.status"
    return
  fi

  if [ "$FETCH_ONLY" -eq 1 ]; then
    printf 'BEHIND\t%s\t%s is %s commit(s) behind (fetch only)\n' "$name" "$branch" "$behind" > "$out.status"
    return
  fi

  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    printf 'DIRTY\t%s\t%s is %s commit(s) behind, but has uncommitted changes\n' \
      "$name" "$branch" "$behind" > "$out.status"
    return
  fi

  if err="$(git merge --ff-only "@{u}" 2>&1)"; then
    printf 'PULLED\t%s\t%s +%s commit(s)\n' "$name" "$branch" "$behind" > "$out.status"
  else
    printf 'ERROR\t%s\t%s: fast-forward failed\n' "$name" "$branch" > "$out.status"
    printf '%s\n' "$err" > "$out.log"
  fi
}

# ------------------------------------------------------------ parallel
if [ "$PORCELAIN" -eq 0 ]; then
  echo "${BOLD}Updating ${#repos[@]} repos in $ROOT${RESET}"
  [ "$FETCH_ONLY" -eq 1 ] && echo "${DIM}(fetch only)${RESET}"
  echo
fi

running=0
for dir in "${repos[@]}"; do
  update_repo "$dir" "$TMPDIR_RUN/$(basename "$dir")" &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done
wait

# ------------------------------------------------------------ report
problems=0
for dir in "${repos[@]}"; do
  name="$(basename "$dir")"
  file="$TMPDIR_RUN/$name.status"
  if [ -f "$file" ]; then
    IFS=$'\t' read -r state repo detail < "$file"
  else
    state=ERROR; repo="$name"; detail="no result"
  fi

  case "$state" in
    OK)       icon="${DIM}·${RESET}"; color="$DIM" ;;
    PULLED)   icon="${GREEN}✓${RESET}"; color="$GREEN" ;;
    AHEAD)    icon="${BLUE}↑${RESET}"; color="$BLUE" ;;
    BEHIND)   icon="${BLUE}↓${RESET}"; color="$BLUE" ;;
    DIRTY)    icon="${YELLOW}~${RESET}"; color="$YELLOW"; problems=1 ;;
    DIVERGED) icon="${YELLOW}⇅${RESET}"; color="$YELLOW"; problems=1 ;;
    SKIP)     icon="${YELLOW}-${RESET}"; color="$YELLOW" ;;
    ERROR)    icon="${RED}✗${RESET}"; color="$RED"; problems=1 ;;
    *)        icon="?"; color= ;;
  esac

  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'REPO\t%s\t%s\t%s\n' "$state" "$repo" "$detail"
    if [ -s "$TMPDIR_RUN/$name.log" ]; then
      while IFS= read -r log_line; do
        printf 'LOG\t%s\t%s\n' "$name" "$log_line"
      done < "$TMPDIR_RUN/$name.log"
    fi
    continue
  fi

  printf '%s %s%-38s%s %s\n' "$icon" "$BOLD" "$repo" "$RESET" "${color}${detail}${RESET}"
  if [ -s "$TMPDIR_RUN/$name.log" ]; then
    sed 's/^/    /' "$TMPDIR_RUN/$name.log"
  fi
done

if [ "$problems" -eq 1 ]; then
  [ "$PORCELAIN" -eq 1 ] || { echo; echo "${YELLOW}Some repos need manual attention (see above).${RESET}"; }
  exit 1
fi
[ "$PORCELAIN" -eq 1 ] || { echo; echo "${GREEN}All good.${RESET}"; }
