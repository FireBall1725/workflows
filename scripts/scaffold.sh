#!/usr/bin/env bash
#
# Copies the shared config into a repo and prints the caller workflows to add.
#
#   ./scaffold.sh ~/Repos/firebin/mcp go
#   ./scaffold.sh ~/Repos/pcexpress-mcp-server python
#
# Language is one of: go, node, python, swift, astro.
#
# These files are copied rather than referenced because golangci-lint, ruff,
# swift-format, and editorconfig all read from the repo root. Re-run this after
# changing anything under templates/ and commit the result; check-alignment.sh
# reports repos that have drifted.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?usage: scaffold.sh <repo-path> <go|node|python|swift|astro>}"
LANG="${2:?usage: scaffold.sh <repo-path> <go|node|python|swift|astro>}"

[ -d "$TARGET/.git" ] || { echo "error: $TARGET is not a git repo"; exit 1; }

copy() {
  local src="$HERE/templates/$1" dst="$TARGET/${2:-$1}"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    echo "  same    ${2:-$1}"
  elif [ -f "$dst" ]; then
    cp "$src" "$dst"; echo "  updated ${2:-$1}"
  else
    cp "$src" "$dst"; echo "  added   ${2:-$1}"
  fi
}

echo "==> $TARGET ($LANG)"
copy .editorconfig
copy .editorconfig-checker.json
copy cliff.toml

case "$LANG" in
  go)     copy .golangci.yml ;;
  python) copy ruff.toml ;;
  swift)  copy .swift-format ;;
  node|astro) ;;
  *) echo "error: unknown language '$LANG'"; exit 1 ;;
esac

if [ ! -f "$TARGET/.github/release-announce.yml" ]; then
  mkdir -p "$TARGET/.github"
  cp "$HERE/templates/release-announce.yml.example" "$TARGET/.github/release-announce.yml"
  echo "  added   .github/release-announce.yml  <- EDIT THIS, it still says FireBin MCP"
fi

cat <<EOF

Next, replace the repo's .github/workflows/ci.yml with:

  name: CI
  on:
    push: { branches: [main] }
    pull_request:
  concurrency:
    group: ci-\${{ github.ref }}
    cancel-in-progress: true
  jobs:
    ci:
      uses: FireBall1725/workflows/.github/workflows/ci-${LANG}.yml@v1

and release.yml with:

  name: Release
  on:
    workflow_dispatch:
      inputs:
        channel:
          type: choice
          options: [rc, stable]
          default: rc
        dry-run:
          type: boolean
          default: false
  jobs:
    release:
      uses: FireBall1725/workflows/.github/workflows/release-container.yml@v1
      with:
        image: ghcr.io/fireball1725/$(basename "$TARGET")
        channel: \${{ inputs.channel }}
        dry-run: \${{ inputs.dry-run }}
      secrets: inherit

plus nightly.yml:

  name: Nightly
  on:
    push: { branches: [main] }
  jobs:
    nightly:
      uses: FireBall1725/workflows/.github/workflows/release-container.yml@v1
      with:
        image: ghcr.io/fireball1725/$(basename "$TARGET")
        channel: nightly
      secrets: inherit
EOF
