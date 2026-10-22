"""Build the fda_recalls snapshot from openFDA's recall enforcement reports: the CSVs and the manifest in
data/datasets/fda_recalls.

The snapshot is every food, drug and device recall the FDA reported in 2024 - a few thousand recalls, each with the firm,
the product type, the free-text reason and product description, and the FDA's classification. Class I is the serious
one (a reasonable probability of serious harm), so the label is "Class I or not", and the text-classification notebook
learns it - and the product type - from the reason's words. The classification itself sits in a table of its own, as the
banking dataset keeps its company responses apart: the label is derived from it, so it is for reading, never a feature.

Free text (where the product went, the product, the reason) is folded to one line and cut on a word (snapshot.clean).
Names and categories (the firm, its state and country, voluntary or mandated, the first notification, the status) are
never cut: a value wider than its column in 01_create_schema.sql stops the build instead. openFDA writes "N/A" where it
has no value in those fields; the snapshot keeps that as empty (NULL), the same as a field openFDA leaves out.

    python3 tools/datasets/fda_recalls.py       # writes data/datasets/fda_recalls/data/*.csv and manifest.json
"""

from __future__ import annotations

import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

API = "https://api.fda.gov/{kind}/enforcement.json"
KINDS = ("food", "drug", "device")
SEARCH = "report_date:[20240101 TO 20241231]"
PAGE = 1000
HERE = DATASETS / "fda_recalls"

TABLES = {
    "FDA_RECALLS": ["RECALL_NUMBER", "EVENT_ID", "PRODUCT_TYPE", "RECALLING_FIRM", "FIRM_STATE", "FIRM_COUNTRY",
                    "VOLUNTARY_MANDATED", "INITIAL_NOTIFICATION", "RECALL_STATUS", "DISTRIBUTION_PATTERN",
                    "PRODUCT_DESCRIPTION", "REASON_FOR_RECALL", "RECALL_INITIATION_DATE", "REPORT_DATE", "SERIOUS"],
    "FDA_CLASSIFICATIONS": ["RECALL_NUMBER", "CLASSIFICATION", "CLASSIFICATION_DATE"],   # the label's source
}
TEXT = {"DISTRIBUTION_PATTERN": 400, "PRODUCT_DESCRIPTION": 600, "REASON_FOR_RECALL": 600}   # cut on a word
WIDTH = {"RECALLING_FIRM": 200, "FIRM_STATE": 40, "FIRM_COUNTRY": 60, "VOLUNTARY_MANDATED": 60,      # never cut: the
         "INITIAL_NOTIFICATION": 100, "RECALL_STATUS": 20}                                          # VARCHAR widths


def _date(value: str | None) -> str:
    """openFDA's YYYYMMDD as YYYY-MM-DD; empty stays empty."""
    value = (value or "").strip()
    return f"{value[:4]}-{value[4:6]}-{value[6:8]}" if len(value) == 8 and value.isdigit() else ""


def fetch(kind: str) -> list[dict]:
    """Every recall of one kind the search matches, a page at a time."""
    found: list[dict] = []
    while True:
        query = urllib.parse.urlencode({"search": SEARCH, "limit": PAGE, "skip": len(found)})
        with urllib.request.urlopen(f"{API.format(kind=kind)}?{query}", timeout=120) as answer:   # noqa: S310 - a fixed https URL
            doc = json.load(answer)
        found += doc["results"]
        total = doc["meta"]["results"]["total"]
        print(f"  {kind}: {len(found)} of {total}", file=sys.stderr)
        if len(found) >= total or not doc["results"]:
            return found
        time.sleep(0.5)


def _name(column: str, value: str | None) -> str:
    """A name or a category, whole: one line, "N/A" as empty; a value wider than its column is an error, never cut."""
    value = clean(value)
    if value.upper() == "N/A":
        return ""
    if len(value) > WIDTH[column]:
        raise SystemExit(f"{column}: {value!r} is {len(value)} characters, wider than VARCHAR({WIDTH[column]}) - "
                         "widen the column in 01_create_schema.sql and WIDTH here")
    return value


def row(r: dict) -> list:
    """One recall as a row of FDA_RECALLS (its classification goes to FDA_CLASSIFICATIONS)."""
    return [r["recall_number"], int(r["event_id"]) if str(r.get("event_id", "")).isdigit() else "", r["product_type"],
            _name("RECALLING_FIRM", r["recalling_firm"]), _name("FIRM_STATE", r.get("state")),
            _name("FIRM_COUNTRY", r.get("country")), _name("VOLUNTARY_MANDATED", r.get("voluntary_mandated")),
            _name("INITIAL_NOTIFICATION", r.get("initial_firm_notification")), _name("RECALL_STATUS", r.get("status")),
            clean(r.get("distribution_pattern"), TEXT["DISTRIBUTION_PATTERN"]),
            clean(r.get("product_description"), TEXT["PRODUCT_DESCRIPTION"]),
            clean(r.get("reason_for_recall"), TEXT["REASON_FOR_RECALL"]), _date(r.get("recall_initiation_date")),
            _date(r["report_date"]), 1 if r.get("classification") == "Class I" else 0]


def main() -> int:
    recalls = {r["recall_number"]: r for kind in KINDS for r in fetch(kind) if r.get("recall_number")}   # one row per recall number
    files = write_tables(HERE, TABLES, {
        "FDA_RECALLS": [row(r) for r in recalls.values()],
        "FDA_CLASSIFICATIONS": [[n, r.get("classification") or "", _date(r.get("center_classification_date"))] for n, r in recalls.items()]})
    write_manifest(HERE,
                   {"name": "openFDA recall enforcement reports (U.S. Food and Drug Administration)",
                    "url": "https://open.fda.gov/apis/food/enforcement/",
                    "query": {"endpoints": [API.format(kind=k) for k in KINDS], "search": SEARCH},
                    "builder": "tools/datasets/fda_recalls.py"},
                   {"url": "https://open.fda.gov/license/",
                    "license": "Public domain (CC0 1.0): openFDA data is a work of the U.S. government",
                    "summary": "Free to copy, change and redistribute. openFDA says its data is not for clinical use; a "
                               "recall report is the FDA's record of a firm's action, not medical advice.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
