#!/usr/bin/env python3
"""Publish ROADMAP.md into a single, self-updating Discord message.

The message is created once and edited from then on, so the channel holds one
pinned roadmap rather than a growing pile of copies. It carries one embed per
bucket, because one embed stops at 4096 characters and the roadmap passed that.

Environment:
  DISCORD_ROADMAP_WEBHOOK     webhook URL of the target channel (required)
  DISCORD_ROADMAP_MESSAGE_ID  id of the message to edit; unset means "post a
                              new one and print its id"

Usage:
  Scripts/roadmap-to-discord.py [--dry-run] [--roadmap PATH]
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

REPO_URL = "https://github.com/superuser404notfound/Sodalite"
ROADMAP_URL = f"{REPO_URL}/blob/main/ROADMAP.md"
EMBED_TITLE = "Sodalite roadmap"
EMBED_COLOR = 0x007AFF  # the app's accent
FOOTER_TEXT = "Updated automatically from ROADMAP.md"
DESCRIPTION_LIMIT = 4096  # one embed
TOTAL_LIMIT = 6000  # every embed of one message together, title and footer counted
MAX_EMBEDS = 10
USER_AGENT = "Sodalite-Roadmap/1.0 (+%s)" % REPO_URL


def unwrap(markdown: str) -> str:
    """Join a paragraph's hard-wrapped lines.

    The file wraps at column 98 for the sake of a diff. Discord honours every
    single newline, so shipping those wraps breaks sentences mid-air in a
    column half that wide. Headings, list items, quotes and fenced blocks keep
    their own lines.
    """
    out: list[str] = []
    paragraph: list[str] = []
    fenced = False

    def flush() -> None:
        if paragraph:
            out.append(" ".join(paragraph))
            paragraph.clear()

    for line in markdown.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            flush()
            fenced = not fenced
            out.append(line)
        elif fenced:
            out.append(line)
        elif not stripped or stripped[0] in "#-*>|" or stripped[:2].rstrip(".").isdigit():
            flush()
            out.append(line)
        else:
            paragraph.append(stripped)
    flush()
    return "\n".join(out)


def sections(body: str) -> list[str]:
    """Cut the body into the preamble and one chunk per bucket."""
    chunks: list[str] = []
    current: list[str] = []
    for line in body.splitlines():
        if line.startswith("## ") and current:
            chunks.append("\n".join(current).strip())
            current = [line]
        else:
            current.append(line)
    chunks.append("\n".join(current).strip())
    return [chunk for chunk in chunks if chunk]


def build_descriptions(markdown: str) -> list[str]:
    """Drop the file's own H1 (the embed carries the title) and fit the limits.

    A bucket per embed buys room up to the message's own 6000, and the tail
    link stays for the day that runs out too. Truncation lands on an entry
    boundary, so the channel never shows half of one.
    """
    lines = markdown.splitlines()
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    body = unwrap("\n".join(lines)).strip()

    tail = f"\n\n[Read the rest on GitHub]({ROADMAP_URL})"
    budget = TOTAL_LIMIT - len(EMBED_TITLE) - len(FOOTER_TEXT)
    out: list[str] = []
    spent = 0

    for chunk in sections(body):
        room = min(DESCRIPTION_LIMIT, budget - spent)
        if len(out) < MAX_EMBEDS and len(chunk) <= room:
            out.append(chunk)
            spent += len(chunk)
            continue

        room -= len(tail)
        cut = chunk.rfind("\n### ", 0, room) if room > 0 else -1
        if cut == -1 and room > 0:
            cut = chunk.rfind("\n\n", 0, room)
        if cut > 0 and len(out) < MAX_EMBEDS:
            out.append(chunk[:cut].rstrip() + tail)
        elif out:
            # No room for even a stub, so the tail replaces the last entry
            # already published rather than growing the message.
            last = out[-1]
            keep = last.rfind("\n### ", 0, max(len(last) - len(tail), 0))
            out[-1] = last[:keep if keep > 0 else max(len(last) - len(tail), 0)].rstrip() + tail
        break

    return out or [body[:DESCRIPTION_LIMIT]]


def build_payload(descriptions: list[str]) -> dict:
    embeds = []
    for index, description in enumerate(descriptions):
        embed = {"description": description, "color": EMBED_COLOR}
        if index == 0:
            # Only the first one carries the title and the link. Discord merges
            # embeds that share a url.
            embed["title"] = EMBED_TITLE
            embed["url"] = ROADMAP_URL
        if index == len(descriptions) - 1:
            embed["footer"] = {"text": FOOTER_TEXT}
            embed["timestamp"] = datetime.now(timezone.utc).isoformat()
        embeds.append(embed)
    return {"embeds": embeds, "allowed_mentions": {"parse": []}}


def request(method: str, url: str, payload: dict) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", USER_AGENT)
    with urllib.request.urlopen(req, timeout=30) as response:
        raw = response.read().decode("utf-8")
    return json.loads(raw) if raw else {}


def send(method: str, url: str, payload: dict) -> dict:
    """One retry, and only for a rate limit, which is the one retryable answer."""
    for attempt in range(2):
        try:
            return request(method, url, payload)
        except urllib.error.HTTPError as error:
            body = error.read().decode("utf-8", "replace")
            if error.code == 429 and attempt == 0:
                try:
                    wait = float(json.loads(body).get("retry_after", 1.0))
                except (ValueError, AttributeError):
                    wait = 1.0
                print(f"rate limited, retrying in {wait:.1f}s", file=sys.stderr)
                time.sleep(min(wait, 30.0))
                continue
            raise SystemExit(f"discord answered {error.code}: {body}")
    raise SystemExit("discord kept rate limiting")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="print the payload instead of sending it")
    parser.add_argument("--roadmap", default="ROADMAP.md")
    args = parser.parse_args()

    try:
        with open(args.roadmap, encoding="utf-8") as handle:
            markdown = handle.read()
    except OSError as error:
        raise SystemExit(f"cannot read {args.roadmap}: {error}")

    descriptions = build_descriptions(markdown)
    payload = build_payload(descriptions)
    total = sum(len(part) for part in descriptions) + len(EMBED_TITLE) + len(FOOTER_TEXT)
    print(f"{len(descriptions)} embeds, {total} of {TOTAL_LIMIT} characters")

    if args.dry_run:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return

    webhook = (os.environ.get("DISCORD_ROADMAP_WEBHOOK") or "").strip()
    if not webhook:
        raise SystemExit("DISCORD_ROADMAP_WEBHOOK is not set")
    webhook = webhook.rstrip("/")
    message_id = (os.environ.get("DISCORD_ROADMAP_MESSAGE_ID") or "").strip()

    if message_id:
        try:
            send("PATCH", f"{webhook}/messages/{message_id}", payload)
            print(f"edited message {message_id}")
            return
        except SystemExit as error:
            # A deleted message must not wedge the workflow forever.
            if "404" not in str(error):
                raise
            print("message is gone, posting a fresh one", file=sys.stderr)

    created = send("POST", f"{webhook}?wait=true", payload)
    new_id = created.get("id", "")
    print(f"posted message {new_id}")
    print(
        "Set the repository variable DISCORD_ROADMAP_MESSAGE_ID to "
        f"{new_id} so the next run edits this message instead of posting again."
    )
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and new_id:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(
                "### Roadmap posted\n\nSet repository variable "
                f"`DISCORD_ROADMAP_MESSAGE_ID` to `{new_id}`, then pin the "
                "message in Discord.\n"
            )


if __name__ == "__main__":
    main()
