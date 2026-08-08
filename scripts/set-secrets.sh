#!/usr/bin/env bash
#
# Distributes the shared CI secrets to every repo that needs them.
#
#   ./set-secrets.sh                          # all secrets, all their repos
#   ./set-secrets.sh HOMELAB_DEPLOY_TOKEN     # one secret, its repos
#   DRY_RUN=1 ./set-secrets.sh                # show what would be set
#
# Values come from the macOS Keychain, never from a file and never from the
# command line. Store them once, with -w and no value so the secret is typed at
# a prompt rather than left in shell history:
#
#   security add-generic-password -a "$USER" -s ci/DISCORD_RELEASES_WEBHOOK -w
#   security add-generic-password -a "$USER" -s ci/HOMELAB_DEPLOY_TOKEN -w
#
# Rotate with -U to overwrite the existing entry:
#
#   security add-generic-password -U -a "$USER" -s ci/HOMELAB_DEPLOY_TOKEN -w
#
# Read one back yourself (prints the value, so mind the terminal):
#
#   security find-generic-password -a "$USER" -s ci/HOMELAB_DEPLOY_TOKEN -w
#
# A personal GitHub account has no organization secrets, so every secret is a
# per-repo secret and every rotation is this loop. The secret NAMES are fixed,
# so the day these repos move to an org, one org secret replaces all the copies
# and no workflow YAML changes.

set -euo pipefail

OWNER="${OWNER:-FireBall1725}"
DRY_RUN="${DRY_RUN:-}"

# Repos that publish a release and can announce it.
ANNOUNCE_REPOS=(
  librarium-api librarium-web librarium-mcp
  firebin-api firebin-web firebin-mcp firebin-kicad
  pcexpress-mcp-server
  LayerLens
)

# Repos whose release pins a new image into homelab-applications. Narrower on
# purpose: this token can write to the GitOps repo, so it goes only where a
# deploy actually happens. LayerLens ships a dmg and deploys nothing.
DEPLOY_REPOS=(
  librarium-api librarium-web librarium-mcp
  firebin-api firebin-web firebin-mcp
  pcexpress-mcp-server
)

repos_for() {
  case "$1" in
    DISCORD_RELEASES_WEBHOOK) printf '%s\n' "${ANNOUNCE_REPOS[@]}" ;;
    HOMELAB_DEPLOY_TOKEN)     printf '%s\n' "${DEPLOY_REPOS[@]}" ;;
    *) echo "unknown secret '$1'" >&2; return 1 ;;
  esac
}

from_keychain() {
  security find-generic-password -a "$USER" -s "ci/$1" -w 2>/dev/null || true
}

if [ $# -gt 0 ]; then
  SECRETS=("$@")
else
  SECRETS=(DISCORD_RELEASES_WEBHOOK HOMELAB_DEPLOY_TOKEN)
fi

for name in "${SECRETS[@]}"; do
  echo "==> ${name}"

  value="$(from_keychain "$name")"
  if [ -z "$value" ]; then
    echo "  not in the Keychain. Store it with:"
    echo "    security add-generic-password -a \"\$USER\" -s ci/${name} -w"
    continue
  fi

  # Cheap sanity checks. Pasting the wrong value into 9 repos is tedious to
  # undo, and a truncated token fails at release time with a 403 that reads
  # like a permissions problem.
  case "$name" in
    DISCORD_RELEASES_WEBHOOK)
      case "$value" in
        https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*) ;;
        *) echo "  that does not look like a Discord webhook URL; skipping"; continue ;;
      esac ;;
    HOMELAB_DEPLOY_TOKEN)
      case "$value" in
        ghp_*|github_pat_*) ;;
        *) echo "  that does not look like a GitHub token; skipping"; continue ;;
      esac ;;
  esac

  # Length only. Never print a secret, not even a prefix: these end up in
  # terminal scrollback and pasted transcripts.
  echo "  loaded from Keychain (${#value} chars)"

  while read -r repo; do
    full="${OWNER}/${repo}"
    if [ -n "$DRY_RUN" ]; then
      echo "  would set  ${full}"
      continue
    fi
    if printf '%s' "$value" | gh secret set "$name" --repo "$full" 2>/dev/null; then
      echo "  set        ${full}"
    else
      echo "  FAILED     ${full}"
    fi
  done < <(repos_for "$name")

  unset value
done
