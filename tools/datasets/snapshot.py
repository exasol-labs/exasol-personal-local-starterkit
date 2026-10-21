"""What every reference-dataset builder shares: one-line text, the CSVs and the manifest that names them (docs/design.md D68)."""

from __future__ import annotations

import csv
import datetime as dt
import hashlib
import json
from pathlib import Path

DATASETS = Path(__file__).resolve().parents[2] / "data" / "datasets"


def clean(text: str | None, limit: int = 0) -> str:
    """One line of plain text: newlines and runs of spaces folded, cut to ``limit`` characters at a word."""
    words = " ".join((text or "").split())
    if limit and len(words) > limit:
        words = words[:limit].rsplit(" ", 1)[0] + " …"
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
