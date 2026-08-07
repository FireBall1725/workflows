#!/usr/bin/env bash
#
# Applies the house repo settings: squash-only merging with the PR title as the
# commit subject, and a ruleset protecting main.
#
#   ./set-repo-settings.sh                 # every repo in REPOS
#   ./set-repo-settings.sh firebin-mcp     # just one
#   DRY_RUN=1 ./set-repo-settings.sh       # print what would change
#
# Squash-with-PR-title is not cosmetic: the changelog reads PR titles, and the
# squash subject is what git-cliff falls back to when the API lookup misses.
#
# The ruleset applies to you as well. The release bot is the only bypass, and
# it needs one because two workflows push to main (LayerLens commits appcast.xml,
# librarium-ios commits the version bump). Set BYPASS_APP_ID once that GitHub
# App exists; until then those two repos are left unprotected on purpose rather
# than protected in a way that breaks their releases.

set -euo pipefail

OWNER="${OWNER:-FireBall1725}"
BYPASS_APP_ID="${BYPASS_APP_ID:-}"
DRY_RUN="${DRY_RUN:-}"

REPOS_DEFAULT=(
  librarium-api librarium-web librarium-mcp librarium
  firebin-api firebin-web firebin-mcp firebin-kicad firebin firebin-site
  pcexpress-mcp-server
  LayerLens
)

# These push to main from a release workflow. Protecting them before the bypass
# app exists would break the release, so they are skipped unless BYPASS_APP_ID
# is set.
PUSHES_TO_MAIN=(LayerLens librarium-ios)

if [ $# -gt 0 ]; then REPOS=("$@"); else REPOS=("${REPOS_DEFAULT[@]}"); fi

run() {
  if [ -n "$DRY_RUN" ]; then echo "  would: $*"; else "$@"; fi
}

for repo in "${REPOS[@]}"; do
  full="${OWNER}/${repo}"
  echo "==> ${full}"

  if ! gh repo view "$full" --json name >/dev/null 2>&1; then
    echo "  skip: not found or no access"
    continue
  fi

  echo "  merge settings"
  run gh api -X PATCH "repos/${full}" \
    -F allow_squash_merge=true \
    -F allow_merge_commit=false \
    -F allow_rebase_merge=false \
    -f squash_merge_commit_title=PR_TITLE \
    -f squash_merge_commit_message=PR_BODY \
    -F delete_branch_on_merge=true \
    --silent

  skip_protection=""
  for r in "${PUSHES_TO_MAIN[@]}"; do
    if [ "$r" = "$repo" ] && [ -z "$BYPASS_APP_ID" ]; then skip_protection=1; fi
  done

  if [ -n "$skip_protection" ]; then
    echo "  ruleset SKIPPED: this repo's release workflow pushes to main and"
    echo "    BYPASS_APP_ID is unset. Protecting it now would break the release."
    continue
  fi

  if gh api "repos/${full}/rulesets" --jq '.[].name' 2>/dev/null | grep -qx "main"; then
    echo "  ruleset already present"
    continue
  fi

  bypass="[]"
  if [ -n "$BYPASS_APP_ID" ]; then
    bypass="[{\"actor_id\":${BYPASS_APP_ID},\"actor_type\":\"Integration\",\"bypass_mode\":\"always\"}]"
  fi

  echo "  ruleset on main"
  payload=$(cat <<JSON
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": ${bypass},
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false,
        "allowed_merge_methods": ["squash"]
      }
    }
  ]
}
JSON
)
  if [ -n "$DRY_RUN" ]; then
    echo "  would POST repos/${full}/rulesets"
  else
    # A private repo on a Free plan cannot have rulesets. Report it and carry
    # on rather than aborting the sweep.
    if ! echo "$payload" | gh api -X POST "repos/${full}/rulesets" --input - --silent 2>/tmp/ruleset.err; then
      echo "  ruleset FAILED: $(head -c 200 /tmp/ruleset.err)"
      echo "    (private repos need GitHub Pro or Team for rulesets)"
    fi
  fi
done

echo
echo "Done. Status checks are deliberately not required yet: bind them once the"
echo "shared CI job names have run at least once, or every PR blocks on a check"
echo "that has never reported."
