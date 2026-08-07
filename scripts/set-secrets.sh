#!/usr/bin/env bash
#
# Distributes the Discord webhook to every repo.
#
#   DISCORD_RELEASES_WEBHOOK='https://discord.com/api/webhooks/...' ./set-secrets.sh
#
# A personal GitHub account has no organization secrets, so this has to be a
# per-repo secret and every rotation repeats the loop. The secret NAME is fixed
# so that the day these repos move to the FireLabsCA org, one org secret
# replaces all of them and no workflow YAML changes.

set -euo pipefail

OWNER="${OWNER:-FireBall1725}"
: "${DISCORD_RELEASES_WEBHOOK:?set DISCORD_RELEASES_WEBHOOK in the environment}"

case "$DISCORD_RELEASES_WEBHOOK" in
  https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) ;;
  *) echo "error: that does not look like a Discord webhook URL"; exit 1 ;;
esac

REPOS=(
  librarium-api librarium-web librarium-mcp
  firebin-api firebin-web firebin-mcp firebin-kicad
  pcexpress-mcp-server
  LayerLens
)
if [ $# -gt 0 ]; then REPOS=("$@"); fi

for repo in "${REPOS[@]}"; do
  full="${OWNER}/${repo}"
  if gh secret set DISCORD_RELEASES_WEBHOOK \
      --repo "$full" --body "$DISCORD_RELEASES_WEBHOOK" 2>/dev/null; then
    echo "  set  ${full}"
  else
    echo "  FAIL ${full}"
  fi
done
