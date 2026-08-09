#!/usr/bin/env bash
#
# Aligns merge settings and the `main` ruleset across every repo.
#
#   DRY_RUN=1 ./set-repo-settings.sh          # print the plan, change nothing
#   ./set-repo-settings.sh                    # apply to every repo
#   ./set-repo-settings.sh firebin-api        # just one
#
# Two separate things, both needed:
#
#   Repo settings   squash-only merging, PR title as the commit subject,
#                   delete the branch on merge, allow auto-merge.
#   Ruleset "main"  require a PR, require the CI checks, block force-push
#                   and deletion.
#
# squash_merge_commit_title=PR_TITLE is not cosmetic. Release notes are
# generated from PR titles, and the default COMMIT_OR_PR_TITLE silently uses the
# commit subject on a single-commit PR, so the changelog says something
# different from the PR.

set -uo pipefail

OWNER="${OWNER:-FireBall1725}"
DRY_RUN="${DRY_RUN:-}"

# No repo gets a bypass, and none needs one.
#
# The obvious design was to let GitHub Actions bypass the rule on the two repos
# whose releases pushed to main. That is not possible on a personal account:
#
#   Actor GitHub Actions integration must be part of the ruleset source or
#   owner organization
#
# A RepositoryRole admin bypass is accepted but useless, because a workflow
# pushes as github-actions[bot], which is not an admin. So both repos were
# reworked instead. LayerLens opens a pull request for its appcast and merges
# it, since a ruleset cares how a change reaches main rather than who sent it.
# librarium-ios stopped committing version strings altogether: the tag and the
# archive already carried the number.
#
# If these repos ever move to the FireLabsCA org, an Integration bypass becomes
# available. Reworking them was the better answer anyway.

REPOS_DEFAULT=(
  librarium-api librarium-web librarium-mcp librarium librarium-ios
  firebin-api firebin-web firebin-mcp firebin-kicad firebin firebin-site
  pcexpress-mcp-server LayerLens fireball1725-ca
  workflows homelab-applications homelab-config
)

if [ $# -gt 0 ]; then REPOS=("$@"); else REPOS=("${REPOS_DEFAULT[@]}"); fi

# Required checks are read from what a real PR actually reported, never
# guessed. Requiring a context that never reports blocks every PR forever, and
# the repos differ: Go has "ci / Lint", Astro has "ci / Build", pcexpress has
# "ci / Lint and test", and a repo with no CI has none at all.
#
# CodeQL is deliberately not required. It is a scanner whose findings you want
# to read, not a merge gate: it takes 15+ minutes on LayerLens, and on
# librarium-ios it only runs on main and weekly, so requiring it would block on
# a check that never reports for a PR.
required_checks_for() {
  local repo="$1" pr
  pr=$(gh pr list --repo "${OWNER}/${repo}" --state merged --limit 1 \
        --json number --jq '.[0].number' 2>/dev/null)
  [ -n "$pr" ] || return 0
  gh pr view "$pr" --repo "${OWNER}/${repo}" --json statusCheckRollup \
    --jq '[.statusCheckRollup[].name] | unique | .[] | select(startswith("ci /") or . == "DCO")' 2>/dev/null
}

for repo in "${REPOS[@]}"; do
  full="${OWNER}/${repo}"
  echo "==> ${full}"

  if ! gh repo view "$full" --json name >/dev/null 2>&1; then
    echo "  skip: not found or no access"
    continue
  fi

  # No mapfile: macOS ships bash 3.2 and does not have it.
  checks=()
  while IFS= read -r line; do
    [ -n "$line" ] && checks+=("$line")
  done < <(required_checks_for "$repo")

  if [ "${#checks[@]}" -eq 0 ]; then
    echo "  no CI checks found; requiring a PR only"
  else
    echo "  required checks: ${checks[*]}"
  fi

  bypass="[]"

  if [ "${#checks[@]}" -eq 0 ]; then
    checks_json="[]"
  else
    checks_json=$(printf '%s\n' "${checks[@]}" \
      | jq -R 'select(length > 0) | {context: .}' | jq -s '.')
  fi

  payload=$(jq -n \
    --argjson bypass "$bypass" \
    --argjson checks "$checks_json" '
    {
      name: "main",
      target: "branch",
      enforcement: "active",
      conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
      bypass_actors: $bypass,
      rules: (
        [
          { type: "deletion" },
          { type: "non_fast_forward" },
          { type: "pull_request", parameters: {
              required_approving_review_count: 0,
              dismiss_stale_reviews_on_push: false,
              require_code_owner_review: false,
              require_last_push_approval: false,
              required_review_thread_resolution: false,
              allowed_merge_methods: ["squash"]
          }}
        ]
        + (if ($checks | length) > 0 then
            [{ type: "required_status_checks", parameters: {
                # Not strict: with one person and squash merges, forcing a
                # rebase every time main moves costs more than it catches.
                strict_required_status_checks_policy: false,
                do_not_enforce_on_create: false,
                required_status_checks: $checks
            }}]
           else [] end)
      )
    }')

  if [ -n "$DRY_RUN" ]; then
    echo "  would set merge settings and the main ruleset"
    continue
  fi

  gh api -X PATCH "repos/${full}" \
    -F allow_squash_merge=true \
    -F allow_merge_commit=false \
    -F allow_rebase_merge=false \
    -f squash_merge_commit_title=PR_TITLE \
    -f squash_merge_commit_message=PR_BODY \
    -F delete_branch_on_merge=true \
    -F allow_auto_merge=true \
    --silent && echo "  merge settings ok" || echo "  merge settings FAILED"

  # Replace rather than duplicate: a second ruleset named main would apply on
  # top of the first and the effective rules become hard to reason about.
  existing=$(gh api "repos/${full}/rulesets" --jq '.[] | select(.name=="main") | .id' 2>/dev/null | head -n1)
  if [ -n "$existing" ]; then
    printf '%s' "$payload" | gh api -X PUT "repos/${full}/rulesets/${existing}" --input - --silent \
      && echo "  ruleset updated" || echo "  ruleset UPDATE FAILED"
  else
    printf '%s' "$payload" | gh api -X POST "repos/${full}/rulesets" --input - --silent \
      && echo "  ruleset created" || echo "  ruleset CREATE FAILED"
  fi
done
