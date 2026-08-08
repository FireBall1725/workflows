#!/usr/bin/env bash
#
# Reports repos whose copy of the shared config has drifted from templates/.
#
#   ./check-drift.sh                 # every repo in REPOS_DEFAULT
#   ./check-drift.sh ~/Repos/firebin/api
#
# The config files are copied into repos rather than referenced, because
# golangci-lint, ruff, swift-format, and editorconfig all read from the repo
# root. So a fix to a template does not reach a repo until someone re-copies it,
# and a repo can sit on a broken rule for weeks without failing: the rule simply
# has nothing to trip on yet. Three repos were in exactly that state on
# 2026-08-08, all migrated before the Go and SQL exclusions landed.
#
# Exits non-zero when anything has drifted, so CI can gate on it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPOS_DEFAULT=(
  "$HOME/Repos/firebin/api" "$HOME/Repos/firebin/web"
  "$HOME/Repos/firebin/mcp" "$HOME/Repos/firebin/kicad"
  "$HOME/Repos/librarium/api" "$HOME/Repos/librarium/web"
  "$HOME/Repos/librarium/mcp"
  "$HOME/Repos/pcexpress-mcp-server"
  "$HOME/Repos/LayerLens"
)

# Only compare a file the repo already has. A Go repo has no ruff.toml, and
# that is not drift.
SHARED=(.editorconfig .editorconfig-checker.json cliff.toml .golangci.yml ruff.toml .swift-format)

if [ $# -gt 0 ]; then REPOS=("$@"); else REPOS=("${REPOS_DEFAULT[@]}"); fi

drifted=0
for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || continue
  name="$(basename "$(dirname "$repo")")/$(basename "$repo")"
  out=""
  present=0
  for f in "${SHARED[@]}"; do
    [ -f "$repo/$f" ] || continue
    present=$((present + 1))
    if ! cmp -s "$HERE/templates/$f" "$repo/$f"; then
      out="$out $f"
    fi
  done
  # A repo with none of these has not been migrated yet. Reporting that as "ok"
  # would let an untouched repo read as compliant, which is the opposite of
  # what this script is for.
  if [ "$present" = "0" ]; then
    printf '  --     %-24snot migrated\n' "$name"
    continue
  fi
  if [ -n "$out" ]; then
    printf '  DRIFT  %-24s%s\n' "$name" "$out"
    drifted=1
  else
    printf '  ok     %s\n' "$name"
  fi
done

if [ "$drifted" = "1" ]; then
  echo
  echo "Re-copy with: scripts/scaffold.sh <repo-path> <language>"
  exit 1
fi
