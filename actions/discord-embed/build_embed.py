#!/usr/bin/env python3
"""Build a Discord webhook payload from a release and a per-repo template.

Discord's limits are the whole problem here. Individually: 256 for a title,
4096 for a description, 256/1024 for a field name/value, 25 fields. On top of
that there is a 6000-character budget across title, description, every field
name and value, the footer text, and the author name combined. A payload that
passes every individual limit and busts the total is rejected with a 400 that
says nothing useful, so the description is sized last, from what is left.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any

TITLE_MAX = 256
DESC_MAX = 4096
FIELD_VALUE_MAX = 1024
TOTAL_MAX = 6000
# Headroom for the "full notes" link appended after truncation, plus slack so a
# multi-byte character near the boundary can't push the total over.
RESERVE = 120

CONVENTIONAL = re.compile(
    r"^(feat|fix|perf|refactor|docs|test|build|ci|style|chore|revert)"
    r"(\([^)]*\))?!?:\s*",
    re.IGNORECASE,
)


def render(text: str, ctx: dict[str, str]) -> str:
    """Substitute {{placeholders}}. Unknown ones are left alone rather than
    raising, so a typo in a template degrades to visible text."""
    def sub(m: re.Match[str]) -> str:
        return ctx.get(m.group(1).strip(), m.group(0))

    return re.sub(r"\{\{([^}]+)\}\}", sub, text or "")


def to_discord_markdown(md: str, repo: str) -> str:
    """Translate GitHub markdown into the subset Discord actually renders.

    Discord does: bold, italic, strike, inline code, fenced code, headings
    (h1-h3), unordered lists, block quotes, and masked links. It does not do:
    tables, images, HTML, horizontal rules, or GitHub's bare #123 autolinks.
    """
    out: list[str] = []
    in_fence = False

    for line in md.splitlines():
        fence = line.lstrip().startswith("```")
        if fence:
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue

        # A table renders as a wall of pipes. Drop it entirely rather than
        # showing the reader something broken.
        if re.match(r"^\s*\|.*\|\s*$", line):
            continue
        if re.match(r"^\s*\|?[\s:-]+\|[\s:|-]*$", line):
            continue

        line = re.sub(r"<!--.*?-->", "", line)
        # h2 is enormous in Discord and a release body is mostly h2s.
        line = re.sub(r"^##\s+", "### ", line)
        line = re.sub(r"^#\s+", "### ", line)
        line = re.sub(r"^\s*[-*_]{3,}\s*$", "", line)
        line = re.sub(r"^(\s*)\*\s+", r"\1- ", line)
        # An image becomes a bare link, which at least still goes somewhere.
        line = re.sub(r"!\[([^\]]*)\]\(([^)]+)\)", r"[\1](\2)", line)
        # The single biggest length saving on a generated changelog.
        line = re.sub(
            rf"https://github\.com/{re.escape(repo)}/pull/(\d+)",
            r"[#\1](https://github.com/" + repo + r"/pull/\1)",
            line,
        )
        # "by @someone" on every line is noise in a solo repo.
        line = re.sub(r"\s+by\s+@[\w-]+(?=\s*(\(|$))", "", line)
        line = CONVENTIONAL.sub("", line)
        out.append(line)

    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def truncate(text: str, limit: int, more_url: str | None = None) -> str:
    """Cut on a line boundary and never leave a code fence open."""
    if len(text) <= limit:
        return text

    suffix = f"\n\n**[Full release notes →]({more_url})**" if more_url else "\n\n…"
    budget = limit - len(suffix)
    if budget <= 0:
        return suffix.strip()[:limit]

    kept: list[str] = []
    used = 0
    for line in text.splitlines():
        if used + len(line) + 1 > budget:
            break
        kept.append(line)
        used += len(line) + 1

    # An unclosed fence swallows the rest of the embed.
    if sum(1 for ln in kept if ln.lstrip().startswith("```")) % 2 == 1:
        kept.append("```")

    return "\n".join(kept).rstrip() + suffix


def build(cfg: dict[str, Any], ctx: dict[str, str], notes: str) -> dict[str, Any] | None:
    channel = ctx["channel"]
    ch_cfg = (cfg.get("channels") or {}).get(channel) or {}

    if not ch_cfg.get("announce", channel == "stable"):
        return None

    project = cfg.get("project") or {}
    name = project.get("name") or ctx["repo"].split("/")[-1]
    emoji = project.get("emoji", "")

    prefix = ch_cfg.get("prefix", "")
    title = f"{emoji} {prefix}{name} {ctx['version']}".strip()
    title = title[:TITLE_MAX]

    colour_raw = str(ch_cfg.get("colour") or ch_cfg.get("color") or "0x5865F2")
    colour = int(colour_raw, 16) if colour_raw.lower().startswith("0x") else int(colour_raw)

    fields: list[dict[str, Any]] = []

    getting_started = render(cfg.get("getting_started", ""), ctx).strip()
    if getting_started:
        fields.append({
            "name": "Getting started",
            "value": truncate(getting_started, FIELD_VALUE_MAX),
            "inline": False,
        })

    links = cfg.get("links") or []
    if links:
        rendered = " · ".join(
            f"[{link['name']}]({render(link['url'], ctx)})"
            for link in links
            if link.get("name") and link.get("url")
        )
        if rendered:
            fields.append({
                "name": "Links",
                "value": truncate(rendered, FIELD_VALUE_MAX),
                "inline": False,
            })

    if ctx.get("image"):
        fields.append({
            "name": "Image",
            "value": f"`{ctx['image']}`",
            "inline": True,
        })

    fields.append({
        "name": "Channel",
        "value": "Release candidate" if channel == "rc" else "Stable",
        "inline": True,
    })

    footer = project.get("footer", "")
    author = ctx["repo"]

    spent = (
        len(title)
        + len(footer)
        + len(author)
        + sum(len(f["name"]) + len(f["value"]) for f in fields)
    )
    desc_budget = max(0, min(DESC_MAX, TOTAL_MAX - spent - RESERVE))

    body = to_discord_markdown(notes, ctx["repo"])
    description = truncate(body, desc_budget, ctx["release_url"])

    embed: dict[str, Any] = {
        "title": title,
        "url": ctx["release_url"],
        "description": description,
        "color": colour,
        "fields": fields[:25],
        "author": {"name": author},
    }
    if footer:
        embed["footer"] = {"text": footer}
    if project.get("thumbnail"):
        embed["thumbnail"] = {"url": render(project["thumbnail"], ctx)}
    if ctx.get("published_at"):
        embed["timestamp"] = ctx["published_at"]

    payload: dict[str, Any] = {
        "embeds": [embed],
        # Nothing pings unless a template explicitly asks for it.
        "allowed_mentions": {"parse": []},
    }

    mention = ch_cfg.get("mention")
    if mention:
        payload["content"] = mention
        role = re.search(r"\d+", mention)
        if role:
            payload["allowed_mentions"] = {"roles": [role.group(0)]}

    return payload


def post(url: str, payload: dict[str, Any]) -> None:
    data = json.dumps(payload).encode()
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            print(f"Discord responded {resp.status}")
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:500]
        print(f"::warning::Discord rejected the payload ({e.code}): {body}")
        raise


def main() -> int:
    notes = os.environ.get("RELEASE_NOTES", "")
    version = os.environ["VERSION"]
    # IMAGE arrives as the bare repository. Templates document {{image}} as the
    # full pullable reference, which is the only form anyone wants to paste.
    image_repo = os.environ.get("IMAGE", "")
    ctx = {
        "version": version,
        "channel": os.environ["CHANNEL"],
        "repo": os.environ["REPO"],
        "tag": os.environ.get("TAG", ""),
        "image": f"{image_repo}:{version}" if image_repo else "",
        "release_url": os.environ.get("RELEASE_URL", ""),
        "compare_url": os.environ.get("COMPARE_URL", ""),
        "published_at": os.environ.get("PUBLISHED_AT", ""),
    }

    cfg: dict[str, Any] = {}
    path = os.environ.get("TEMPLATE", ".github/release-announce.yml")
    if os.path.exists(path):
        import yaml  # imported late so a repo with no template needs no dependency

        cfg = yaml.safe_load(open(path)) or {}
    else:
        print(f"No {path}; posting a plain embed.")

    payload = build(cfg, ctx, notes)
    if payload is None:
        print(f"Channel {ctx['channel']} is not announced for this repo.")
        return 0

    if os.environ.get("DRY_RUN") == "true":
        print(json.dumps(payload, indent=2))
        return 0

    webhook = os.environ.get("WEBHOOK", "")
    if not webhook:
        # A fork PR gets no secrets. Skipping is correct; failing is not.
        print("::warning::No webhook configured; skipping the announcement.")
        return 0

    post(webhook, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
