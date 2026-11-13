"""The tables chosen in the quickstart, carried to the next notebook.

The quickstart picks the data (step 1: kit datasets, your own tables and files, external sources - any number);
01_explore understands it (step 2: the column map and the semantic views). Each notebook runs in its own kernel, so
the choice is written to one small file in the kit's home (chosen-tables.json): the table names and nothing else,
never a row. ``open_chosen`` opens each with ``use_table``, the same call the quickstart makes for a table already in
the database, so a saved column map is found again by the review.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

CHOSEN_FILE = "chosen-tables.json"


def _file() -> Path:
    return Path(os.environ.get("EXAKIT_HOME") or Path.home() / ".exasol-starter-kit").expanduser() / CHOSEN_FILE


def _table_of(item: Any) -> str | None:
    table = getattr(item, "fact_table", None) if not isinstance(item, str) else item
    text = str(table or "").strip()
    return text if "." in text else None


def remember_chosen(*data: Any) -> list[str]:
    """Note the tables chosen here as the ones the next notebook opens: each a dataset, a loaded table or a
    "SCHEMA.TABLE" name (a dict of them, as ``chosen_tables`` holds, gives its keys). Returns the names written; a
    failure to write is said in one line and never fails the cell."""
    items: list[Any] = []
    for item in data:
        if isinstance(item, dict):
            items += list(item.keys())
        elif isinstance(item, (list, tuple)):
            items += list(item)
        elif item is not None:
            items.append(item)
    tables = list(dict.fromkeys(t for t in (_table_of(i) for i in items) if t))
    try:
        _file().parent.mkdir(parents=True, exist_ok=True)
        _file().write_text(json.dumps({"tables": tables}, indent=1) + "\n", encoding="utf-8")
    except OSError as exc:
        print(f"Could not note the chosen tables for the next notebook ({exc}). It opens the dataset approved last.")
    return tables


def chosen_tables() -> list[str]:
    """The tables the quickstart chose last ("SCHEMA.TABLE", first one first); empty when none was noted."""
    try:
        found = json.loads(_file().read_text(encoding="utf-8")).get("tables") or []
    except (OSError, ValueError, AttributeError):
        return []
    return [str(t) for t in found if isinstance(t, str) and "." in t]


def open_chosen(conn, tables: list[str] | None = None) -> dict[str, Any]:
    """Each chosen table opened (``use_table``), by name: {"SCHEMA.TABLE": table}. ``tables`` None: the ones the
    quickstart chose. A table that is gone is left out and said in one line; none at all is an empty dict."""
    from .own_file import use_table

    opened: dict[str, Any] = {}
    for table in tables if tables is not None else chosen_tables():
        try:
            data = use_table(conn, table)
        except Exception as exc:          # dropped since, or a source disconnected: the others still open
            print(f"{table} could not be opened: {str(exc).splitlines()[0] if str(exc) else type(exc).__name__}")
            continue
        opened[str(data.fact_table)] = data
    return opened
