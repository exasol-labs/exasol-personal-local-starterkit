"""Build the esophageal_posts snapshot from a social-listening export about esophageal cancer: the CSV and the
manifest in data/datasets/esophageal_posts.

The export (one sheet, 40,987 posts from 2019 to 2022 on Twitter, the web, forums, print and TV, 67 columns) is
shipped DE-IDENTIFIED. Everything that identifies or profiles a person or an account is dropped: the sender's ids,
screen and listed names, profile images, follower count, influencer score, age and gender; the location below the
country (location text, state, city, latitude, longitude); the message, conversation and parent ids and the
permalinks, which embed tweet ids. A post's domain and its client app are kept only where at least SHARED_MIN
posts share them, so a personal blog or one account's own posting tool does not name its author. Inside the title and the message, @handles become @user, links become URL
and e-mail addresses become EMAIL. Columns that are empty or one value throughout are dropped, and so are the copies
(Action Time, Message Type, LanguageCode). The message is cut at MESSAGE_LIMIT characters.

    python3 tools/datasets/esophageal_posts.py ~/Downloads/Esophageal.xlsx     # needs openpyxl
"""

from __future__ import annotations

import collections
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

HERE = DATASETS / "esophageal_posts"
SHEET = "Stream-Data-1"
SHARED_MIN = 10
TITLE_LIMIT = 300
MESSAGE_LIMIT = 1000

COLUMNS = ["POST_ID", "CREATED_TIME", "SOCIAL_NETWORK", "MESSAGE_TYPE", "IS_REPLY", "LANGUAGE", "COUNTRY", "SOURCE_DOMAIN",
           "MEDIA_TYPES", "CLIENT_APP", "RETWEETS", "FAVORITES", "SENTIMENT", "IS_NEGATIVE", "TITLE", "MESSAGE"]

_URL = re.compile(r"https?:(?://\s*)?\S*|\bwww\.\S+", re.I)     # "https:// host", "https:\/\/..." and "https:%2F..." too
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
_HANDLE = re.compile(r"(?<![\w@])@\w{1,30}")


TABLES = {"ESOPHAGEAL_POSTS": COLUMNS}


def scrub(text: str | None, limit: int) -> str:
    """One line of text with links, e-mail addresses and @handles replaced, then cut at a word (snapshot.clean)."""
    text = _URL.sub("URL", text or "")
    text = _EMAIL.sub("EMAIL", text)
    return clean(_HANDLE.sub("@user", text), limit)


def read(path: Path) -> list[dict[str, str]]:
    """The export's rows as dicts of trimmed text (empty cells left out)."""
    from openpyxl import load_workbook
    sheet = load_workbook(path, read_only=True)[SHEET]
    rows = sheet.iter_rows(values_only=True)
    header = [str(h) for h in next(rows)]
    return [{k: str(v).strip() for k, v in zip(header, row) if v is not None and str(v).strip()} for row in rows]


def build(posts: list[dict[str, str]]) -> list[list]:
    """The de-identified rows, numbered in time order (the export's own id breaks a tie, and is not kept)."""
    domains = collections.Counter(p.get("Domain", "") for p in posts)
    apps = collections.Counter(p.get("Tweet Generator", "") for p in posts)
    ordered = sorted(posts, key=lambda p: (p["CreatedTime"][:19], p["UniversalMessageId"]))
    rows = []
    for number, post in enumerate(ordered, 1):
        domain, app = post.get("Domain", ""), post.get("Tweet Generator", "")
        sentiment = post.get("Sentiment", "")
        rows.append([number, post["CreatedTime"][:19], post.get("SocialNetwork", ""), post.get("MessageType", ""),
                     1 if post.get("ParentUniversalMessageId") else 0, post.get("Language", ""), post.get("Country", ""),
                     domain if domains[domain] >= SHARED_MIN else "", post.get("MediaTypeList", ""),
                     app if apps[app] >= SHARED_MIN else "", int(post.get("Retweets", "0")), int(post.get("Favorites", "0")),
                     sentiment, 1 if sentiment == "NEGATIVE" else 0, scrub(post.get("Title"), TITLE_LIMIT),
                     scrub(post.get("Message"), MESSAGE_LIMIT)])
    return rows


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    source = Path(argv[0]).expanduser()
    files = write_tables(HERE, {"ESOPHAGEAL_POSTS": COLUMNS}, {"ESOPHAGEAL_POSTS": build(read(source))})
    write_manifest(HERE,
                   {"name": "Social-listening export on esophageal cancer (Twitter, web, forums, print and TV, 2019-2022)",
                    "url": "none: an export the kit owner provided, not published anywhere",
                    "file": source.name, "sheet": SHEET, "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                    "builder": "tools/datasets/esophageal_posts.py"},
                   {"url": "none: the export carries no terms; the owner must establish them",
                    "license": "unknown: third-party social media and web posts collected by a social-listening tool",
                    "summary": "The owner must confirm the redistribution terms before release: the posts are other "
                               "people's content (Twitter's terms in particular restrict redistributing tweets). Personal "
                               "data is removed as the builder's docstring lists; the text is cut and its handles, links "
                               "and e-mail addresses replaced.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
