"""What every reference-dataset builder shares: one-line text, the CSVs and the manifest that names them.

A reference dataset (data/README.md, "Reference datasets") ships its CSVs with a manifest.json that records the source,
the terms, the snapshot date and the rows and SHA-256 of every file; tools/dataset_check.py checks the files against it.
"""

from __future__ import annotations

import csv
import datetime as dt
import hashlib
import json
from pathlib import Path

DATASETS = Path(__file__).resolve().parents[2] / "data" / "datasets"


ELLIPSIS = " …"


def clean(text: str | None, limit: int = 0) -> str:
    """One line of plain text: newlines and runs of spaces folded; longer than ``limit`` characters, it is cut at a word
    and ends in " …", the whole at most ``limit`` characters (a single word longer than that is cut inside it)."""
    words = " ".join((text or "").split())
    if limit and len(words) > limit:
        room = limit - len(ELLIPSIS)
        head = words[:room + 1]                       # one more: a space right after the room keeps the last word whole
        head = head.rsplit(" ", 1)[0] if " " in head else words[:room]
        words = head + ELLIPSIS
    return words


def write_tables(folder: Path, headers: dict[str, list[str]], tables: dict[str, list[list]]) -> dict:
    """data/<table>.csv for each table, rows sorted by their first two columns; {path: {rows, sha256}} for the manifest."""
    (folder / "data").mkdir(parents=True, exist_ok=True)
    files = {}
    for name, header in headers.items():
        path = folder / "data" / f"{name.lower()}.csv"
        with path.open("w", newline="", encoding="utf-8") as handle:
            out = csv.writer(handle, lineterminator="\n")
            out.writerow(header)
            out.writerows(sorted(tables[name], key=lambda r: (r[0], r[1] if len(r) > 1 else "")))
        files[f"data/{name.lower()}.csv"] = {"rows": len(tables[name]), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return files


def write_manifest(folder: Path, source: dict, terms: dict, files: dict) -> None:
    """manifest.json: the source and its query, the terms, today's date as the snapshot, and the files."""
    manifest = {"id": folder.name, "source": source, "terms": terms, "snapshot": dt.date.today().isoformat(), "files": files}
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
