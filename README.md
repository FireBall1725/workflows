# firelabs-ci

Shared CI, release, and announcement workflows for FireBall1725's repos. One
copy of the logic that used to be pasted into a dozen repos and drift.

Public on purpose. A private reusable workflow can only be shared with repos
owned by the same account, which would stop working the day anything moves to
the FireLabsCA org. Nothing secret lives here; the workflows consume secrets
from the repos that call them.

## Using it

```bash
scripts/scaffold.sh ~/Repos/firebin/mcp go
```

That copies the shared config into the repo and prints the three caller
workflows to add. A caller ends up about ten lines long:

```yaml
jobs:
  ci:
    uses: FireBall1725/firelabs-ci/.github/workflows/ci-go.yml@v1
```

## Release channels

| | nightly | rc | stable |
|---|---|---|---|
| Trigger | merge to `main` | manual | manual |
| Version | `26.8.1-nightly.202608071432` | `26.8.1-rc.1` | `26.8.1` |
| Git tag | no | yes | yes |
| GitHub Release | no | yes, prerelease | yes |
| Image tags | immutable and `:nightly` | immutable and `:rc` | immutable and `:latest` |
| Discord | nothing | quiet line | full embed |

Versions are `YY.M.revision` with the month not zero-padded, so `26.8.1` rather
than `26.08.1`. A zero-padded month is not valid SemVer, which would break Helm
chart versions and `package.json` outright.

Nightly writes no git tag and no Release. Hundreds of tags per repo make
`git fetch` slow and `git describe` useless, and every tag lookup would then
need its own numeric guard. What a nightly leaves behind is the image and a
changelog diff in the job summary.

`:nightly` and `:rc` are floating tags for people. ArgoCD pins the immutable
version string, because a moved tag never changes the git manifest and so never
triggers a sync.

## What lives here

| Path | What it is |
|---|---|
| `.github/workflows/ci-*.yml` | Per-language CI: build, test, lint, formatting |
| `.github/workflows/release-container.yml` | The three channels, GHCR, tag, Release |
| `.github/workflows/announce-discord.yml` | Posts a release to `#releases` |
| `actions/compute-version` | The single copy of the version algorithm |
| `actions/changelog` | git-cliff wrapper |
| `actions/discord-embed` | Builds the embed inside Discord's limits |
| `templates/` | Config copied into repos by `scaffold.sh` |
| `scripts/` | Scaffolding, repo settings, secret distribution |
| `docs/gold-standard.md` | The full contract |

## Changing something

`main` is protected and `v1` moves only after a green run. Callers pin `@v1`, so
a bad merge here reaches every repo at once. Treat the branch protection as the
control it is, not as paperwork.

## Licence

AGPL-3.0-only. Copyright (C) 2026 FireBall1725.
