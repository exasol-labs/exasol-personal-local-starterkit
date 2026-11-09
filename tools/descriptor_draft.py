#!/usr/bin/env python3
"""Draft a shipped dataset's descriptor offline: the column types from its 01_create_schema.sql, the rows from its
CSV, then the same profile and draft code `exakit describe` runs on the database (setup/lib/descriptor).

    python3 tools/descriptor_draft.py data/datasets/amazon_sales                  # the first table, YAML on stdout
    python3 tools/descriptor_draft.py data/datasets/amazon_sales --table ORDER_LINES --profile profile.json
    python3 tools/descriptor_draft.py data/datasets/amazon_sales --ship --target CANCELLED --grain "one row per order line" \
        --slot category=CATEGORY --slot entity=SHIP_STATE \
        --approved-at 2026-11-05 > data/datasets/amazon_sales/descriptor.yaml     # the descriptor the kit ships

Types are written as EXA_ALL_COLUMNS reports them (VARCHAR(n) UTF8, DECIMAL(p,s), ...), so the schema digest is
the one the database gives, as far as the declaration says it; the live profile is the authority.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "lib"))
from descriptor import draft, profile  # noqa: E402

ALIASES = {"INTEGER": "DECIMAL(18,0)", "INT": "DECIMAL(18,0)", "BIGINT": "DECIMAL(36,0)", "SMALLINT": "DECIMAL(9,0)",
           "TINYINT": "DECIMAL(3,0)", "DOUBLE PRECISION": "DOUBLE", "FLOAT": "DOUBLE", "REAL": "DOUBLE"}


def exasol_type(declared: str) -> str:
    """A declared type as EXA_ALL_COLUMNS shows it."""
    text = re.sub(r"\s+", " ", declared.strip().upper())
    text = re.sub(r"\s*\(\s*", "(", re.sub(r"\s*,\s*", ",", re.sub(r"\s*\)", ")", text)))
    if text in ALIASES:
        return ALIASES[text]
    if re.fullmatch(r"(VAR)?CHAR\(\d+\)", text):
        return text + " UTF8"
    if re.fullmatch(r"DECIMAL\(\d+\)", text):
        return text[:-1] + ",0)"
    return text


def tables(schema_sql: str) -> tuple[str, dict[str, list[tuple[str, str]]]]:
    """(schema, {table: [(column, type)]}) from a dataset's CREATE statements, in file order."""
    schema = re.search(r"CREATE SCHEMA(?: IF NOT EXISTS)?\s+(\w+)", schema_sql, re.I).group(1).upper()
    found: dict[str, list[tuple[str, str]]] = {}
    for match in re.finditer(r"CREATE (?:OR REPLACE )?TABLE\s+(?:\w+\.)?(\w+)\s*\((.*?)\n\);", schema_sql, re.I | re.S):
        columns = []
        for line in match.group(2).splitlines():
            line = line.split("--", 1)[0].strip().rstrip(",")
            if not line or line.upper().startswith(("CONSTRAINT", "PRIMARY KEY", "FOREIGN KEY")):
                continue
            name, rest = line.split(None, 1)
            declared = re.split(r"\s+(?:NOT NULL|NULL|DEFAULT|IDENTITY|CONSTRAINT)\b", rest, maxsplit=1, flags=re.I)[0]
            columns.append((name.strip('"').upper(), exasol_type(declared)))
        found[match.group(1).upper()] = columns
    return schema, found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("folder", type=Path)
    parser.add_argument("--table")
    parser.add_argument("--profile", type=Path, help="also write the profile as JSON here")
    parser.add_argument("--ship", action="store_true", help="approved by the kit: the descriptor a dataset ships")
    parser.add_argument("--target", help="the target slot (never drafted)")
    parser.add_argument("--grain", help="what one row is")
    parser.add_argument("--slot", action="append", default=[], metavar="SLOT=COLUMN", help="set a slot (COLUMN '-' empties it)")
    parser.add_argument("--approved-at", default="2026-11-03", help="the approval date of a shipped descriptor")
    args = parser.parse_args(argv)
    schema, found = tables((args.folder / "01_create_schema.sql").read_text(encoding="utf-8"))
    table = (args.table or next(iter(found))).upper()
    columns = found[table]
    path = args.folder / "data" / f"{table.lower()}.csv"
    with path.open(encoding="utf-8", newline="") as handle:
        reader = csv.reader(handle)
        header = [name.upper() for name in next(reader)]
        if header != [name for name, _ in columns]:
            raise SystemExit(f"{path.name}'s header is not the table's columns in order")
        profiled = profile.profile_rows(columns, reader, f"{schema}.{table}")
    if args.profile:
        args.profile.write_text(json.dumps(profiled, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    doc = draft.draft(profiled, args.folder.name)
    slots = {name: (None if column == "-" else column.upper()) for name, column in (item.split("=", 1) for item in args.slot)}
    if args.target:
        slots["target"] = args.target.upper()
    if slots:
        doc = draft.with_slots(doc, **slots)
    if args.grain:
        doc["grain"] = args.grain
    if args.ship:
        doc = draft.approved(doc, "kit", f"{args.approved_at}T00:00:00Z")
    sys.stdout.write(draft.to_yaml(doc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
