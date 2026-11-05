"""Keep each add-on's GitHub block in marketplace/catalog.json the same as its repository on GitHub.

    python3 tools/addon_github.py            # write the current name, link and About into the catalog
    python3 tools/addon_github.py --check    # exit 1 when the catalog no longer matches GitHub

The block is the offline answer: the kit shows the repository's live name and About when it can reach GitHub,
and this copy when it cannot. It is never typed by hand - this tool writes it - so it says exactly what the
repository says. A renamed or transferred repository is followed (GitHub answers for the new name) and the
catalog takes the new owner/name; an archived or missing one, or an empty About, is an error to fix here.
GITHUB_TOKEN, when set, raises the API's rate limit; it is sent only to api.github.com.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "marketplace" / "catalog.json"
API = "https://api.github.com/repos/"
REPO = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
ABOUT_MAX = 300


def clean(text: str) -> str:
    """One printable line, as the kit shows it: escape sequences and control bytes out, whitespace collapsed."""
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    text = re.sub(r"\x1b\]8;;.*?(?:\x07|\x1b\\)", "", text)
    text = " ".join(CONTROL.sub(" ", text).split())
    if len(text) > ABOUT_MAX:
        text = text[:ABOUT_MAX].rsplit(" ", 1)[0]
    return text


class SameHostAuthRedirect(urllib.request.HTTPRedirectHandler):
    """Follow a redirect, but never hand the Authorization header to another host.

    urllib copies every header but the content ones onto the redirected request,
    a token included, wherever the redirect points (SEC-12). GitHub redirects a
    renamed repository within api.github.com, which keeps the token; anything
    else gets the request without it.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        import urllib.parse

        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None and urllib.parse.urlsplit(newurl).hostname != urllib.parse.urlsplit(req.full_url).hostname:
            new.remove_header("Authorization")
        return new


def fetch(repo: str) -> dict:
    request = urllib.request.Request(API + repo, headers={"Accept": "application/vnd.github+json",
                                                          "User-Agent": "exasol-starter-kit-addon-github"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    # Follows a renamed repository's redirect, keeping the token on GitHub's own host only.
    with urllib.request.build_opener(SameHostAuthRedirect).open(request, timeout=20) as response:
        return json.load(response)


def live_block(repo: str) -> dict:
    """What GitHub says now, in the catalog's shape; ValueError when the repository cannot be the source."""
    try:
        doc = fetch(repo)
    except urllib.error.HTTPError as error:
        raise ValueError(f"{repo}: GitHub answered {error.code}") from error
    full_name, name, url = doc.get("full_name"), doc.get("name"), doc.get("html_url")
    about = clean(doc.get("description") or "")
    if not (isinstance(full_name, str) and REPO.fullmatch(full_name) and isinstance(name, str)
            and url == f"https://github.com/{full_name}"):
        raise ValueError(f"{repo}: GitHub's answer has no usable name or link")
    if doc.get("archived"):
        raise ValueError(f"{repo}: the repository is archived - an add-on must not point at it")
    if not about:
        raise ValueError(f"{repo}: the repository has no About text")
    return {"repo": full_name, "url": url, "name": name, "about": about}


def render(catalog: dict) -> str:
    """The catalog with one add-on per line (its choices indented below it), as the shell's fallback reads it."""
    lines = ["{", f'  "schema_version": {catalog["schema_version"]},', '  "addons": [']
    rows = catalog["addons"]
    for index, row in enumerate(rows):
        head = {key: value for key, value in row.items() if key != "choices"}
        text = "    " + json.dumps(head, ensure_ascii=False)
        if row.get("choices"):
            choices = ",\n".join("      " + json.dumps(choice, ensure_ascii=False) for choice in row["choices"])
            text = text[:-1] + ', "choices": [\n' + choices + "\n    ]}"
        lines.append(text + ("," if index < len(rows) - 1 else ""))
    lines += ["  ]", "}"]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="report drift instead of writing")
    args = parser.parse_args()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    drift, errors = [], []
    for row in catalog["addons"]:
        current = row.get("github") or {}
        repo = current.get("repo", "")
        if not REPO.fullmatch(repo or ""):
            errors.append(f"{row.get('id')}: github.repo must be owner/name, not {repo!r}")
            continue
        try:
            live = live_block(repo)
        except (ValueError, urllib.error.URLError, OSError, json.JSONDecodeError) as error:
            errors.append(f"{row['id']}: {error}")
            continue
        for key in ("repo", "url", "name", "about"):
            if current.get(key) != live[key]:
                drift.append(f"{row['id']}: github.{key} is {current.get(key)!r}, GitHub says {live[key]!r}")
        # Key order: id, github, then everything the catalog carried after it.
        rest = {key: value for key, value in row.items() if key not in ("id", "github")}
        row_id = row["id"]
        row.clear()
        row.update({"id": row_id, "github": live, **rest})
    for message in errors:
        print(f"error: {message}", file=sys.stderr)
    if args.check:
        for message in drift:
            print(f"drift: {message}", file=sys.stderr)
        if not drift and not errors:
            print(f"catalog matches GitHub for {len(catalog['addons'])} add-ons")
        return 1 if drift or errors else 0
    if errors:
        return 1
    CATALOG.write_text(render(catalog), encoding="utf-8")
    print(f"catalog written: {len(drift)} field(s) changed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
