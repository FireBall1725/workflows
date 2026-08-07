# The gold standard

What every FireBall1725 repo does, and why. A new repo inherits this by running
`scripts/scaffold.sh`; an old one is migrated by the same script plus a PR.

## Versioning

`YY.M.revision`. Month is not zero-padded. The revision counts releases within
the month and resets when the month rolls over. Local builds carry `YY.M.DEV`.

The padding matters more than it looks. `26.08.1` is not valid SemVer, because
the spec forbids leading zeros in numeric identifiers. Helm rejects it as a
chart version, npm rejects it in `package.json`, and anything parsing the image
tag as SemVer chokes. `26.8.1` is accepted everywhere including iOS.

Nobody hand-edits a version. CI computes it from the tag list and injects it at
build time through ldflags, a build arg, or a plist substitution.

### The two bugs this replaces

Both were live in the tree and both fail after an image has already been pushed.

**Prerelease tags feeding the next stable.** `librarium-api` computed the last
revision with `git tag --list "v26.8.*" | sort -V | tail -1` and then took the
text after the final dot. That glob matches `v26.8.1-rc.1`, and the strip yields
`1`, so the next stable is computed from a candidate. It never fired only
because Librarium had never cut a prerelease. `actions/compute-version` filters
to `^v26\.8\.[0-9]+$` before doing arithmetic.

**A computed tag that already exists.** The old `bump: major` input forced
`REV=0` regardless of history, so choosing it in a month that already had
releases produced a tag that `git tag` then refused. The input is gone;
`force-version` replaces it for the rare deliberate re-cut, and the
tag-exists check runs before the build rather than after the push.

## Channels

Three, and they answer different questions.

**nightly** exists because the homelab can only run an image that exists. Every
merge to `main` publishes one. No tag, no Release, no announcement. The version
is `26.8.1-nightly.<UTC YYYYMMDDHHMM>`: a timestamp rather than a counter,
because it sorts chronologically and reads as a date when someone asks which
build they are on.

**rc** is for humans testing a candidate. Tagged, published as a prerelease,
never moves `:latest`. `/releases/latest` excludes prereleases, so an update
checker stays quiet while a change is being tried.

**stable** moves `:latest` and gets the full announcement.

SemVer precedence orders them without any extra work: any prerelease sorts below
its release, and `nightly` sorts below `rc` because `n` precedes `r`. The one
wart worth knowing is that within a single base version the ordering is
maturity, not chronology, so a nightly built today sorts below an rc cut last
week. Nothing consumes nightlies by range, so it costs nothing.

## Deploying

ArgoCD watches the git manifest, not the registry. There is no Image Updater
and no Flux. A moved tag changes nothing ArgoCD can see, and `pullPolicy` is
`IfNotPresent`, so pointing a chart at `:nightly` would silently keep running
whatever the node already had.

So a deploy is a git write: `image.tag` in
`homelab-applications/<app>/values.yaml`, pinned to the immutable version. Roll
back by reverting the commit.

## Changelogs

git-cliff, one `cliff.toml`, byte-identical in every repo. Text comes from the
PR title where a PR exists and the commit subject where it doesn't, so it works
both for repos that merge PRs and for repos that ship straight from `main`.

Squash-merge with the PR title as the subject is a prerequisite, which is why
`set-repo-settings.sh` enforces `squash_merge_commit_title=PR_TITLE`.

There is no `CHANGELOG.md` in any repo. Release notes are generated; a
hand-maintained file goes stale and then lies.

### Why not group by PR label

The first design grouped lines under Added/Fixed/Changed from a `type/*` label
on the PR. It was tested and dropped, because a `commit_parser` matching on
`remote.pr_labels` raises a field error for any commit with no associated PR,
and git-cliff then skips that commit entirely instead of falling through to the
catch-all. Verified against firebin-mcp on 2026-08-07: one unmerged commit
produced an empty changelog and a warning nobody would read in CI.

Commits with no PR are normal in LayerLens and pcexpress-mcp-server. Silently
dropping them from a changelog is worse than a flat list. Grouping can return
the day every repo merges through labelled PRs, and it will be a change to one
file.

### Conventional commits

Not required, and not wanted. A PR title written for a changelog reader beats a
prefix:

```
Show an MPN that has no manufacturer          (good)
feat: show an MPN that has no manufacturer    (worse, for the same information)
```

LayerLens writes prefixes because it predates this decision; `cliff.toml`
strips them so its output matches everything else.

## Formatting

Each language's toolchain wins. The 2-space house default applies to everything
the toolchains do not own.

| Language | Indent | Owner |
|---|---|---|
| TS, JS, JSON, YAML, Swift, C++, SQL, shell | 2 spaces | `.editorconfig`, eslint, swift-format |
| Go | tabs | gofmt, which is not configurable |
| Python | 4 spaces | ruff, and every other Python tool |

`.editorconfig` is enforced in CI by `editorconfig-checker`, which covers the
file types no language formatter touches. There is no Prettier: the web repos
are already 2-space, eslint is settled with about a hundred rules, and adding a
second formatter means adding `eslint-config-prettier` to stop the two of them
fighting.

## Every repo runs

- CI on every pull request: build, test, lint, formatting.
- CodeQL, on every public repo. It is free there and not elsewhere, which is a
  billing constraint rather than a decision.
- A release workflow calling `release-container.yml`, unless it ships no
  container.

## Branch protection

`main` is protected on every repo, and the rule applies to the owner too. There
is no reason to push to `main` directly when a PR costs one command.

Rulesets rather than legacy branch protection, because only rulesets have bypass
actors. The release bot needs one: two workflows push to `main` as part of
releasing, LayerLens committing `appcast.xml` and librarium-ios committing the
version bump. Until that app exists, `set-repo-settings.sh` deliberately skips
those two repos rather than protecting them into a broken state.

Private repos need GitHub Pro or Team for rulesets. On a Free plan the private
repos stay unprotected, and that is a billing decision.

## Secrets

`DISCORD_RELEASES_WEBHOOK` is a per-repo secret, because a personal account has
no organization secrets. `set-secrets.sh` distributes it.

The name is fixed so the move to the FireLabsCA org is a no-op for the
workflows: create one org secret, delete the per-repo copies, change no YAML.

## Announcements

The Discord post is a job inside the release run. It cannot be triggered by
`on: release: published`, because a Release created with the default
`GITHUB_TOKEN` does not fire that event. librarium-ios already works around the
same rule by dispatching its TestFlight workflow explicitly.

Every step in the announce workflow is `continue-on-error`. A Discord outage
must not fail a release whose image and tag are already published.

Per-repo content lives in `.github/release-announce.yml`: name, emoji,
thumbnail, per-channel colour, a getting-started block, and links. A repo with
no template still gets a plain embed.

The embed builder exists because Discord's limits are awkward. Individually:
256 for a title, 4096 for a description, 1024 per field value, 25 fields. On top
of that there is a 6000-character budget across the title, description, every
field name and value, the footer, and the author name combined. A payload that
passes every individual limit and busts the total is rejected with a 400 that
explains nothing, so the description is sized last from what is left.

It also translates markdown into the subset Discord renders. Tables are dropped,
`##` is demoted because h2 is enormous in a chat client, images become plain
links, and PR URLs are rewritten to `[#123](url)`, which is the single biggest
length saving on a generated changelog. Truncation cuts on a line boundary and
closes an open code fence, because an unbalanced fence swallows the rest of the
embed.

## Things that will bite

**Moving to the FireLabsCA org.** GHCR packages belong to the account, not the
repo, and do not follow a transfer. The move forces `ghcr.io/firelabsca/*`,
which invalidates every `image.repository` in `homelab-applications` and every
pull command anyone has been given. Plan on dual-publishing for a while.

**GHCR cleanup.** Nightlies generate unbounded package versions, but deleting
"untagged" versions destroys the per-arch child manifests that a multi-arch
image points at. It fails at `docker pull` on one architecture, not at delete
time. Delete by tag pattern, keep the newest few, never touch untagged.

**Multi-arch nightly cost.** A Go Dockerfile with no `--platform=$BUILDPLATFORM`
builds arm64 under QEMU emulation. Tolerable for a monthly release, miserable
per merge. Fix the Dockerfile before turning nightly on.

**Sparkle and prereleases.** Sparkle's version comparator does not understand
SemVer prerelease precedence, so an rc can be offered to a stable user. LayerLens
needs a separate prerelease appcast before its first rc, not after.
