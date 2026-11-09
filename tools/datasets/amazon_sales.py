"""Build the amazon_sales dataset from the Kaggle "Amazon Sale Report" CSV: the CSV and the manifest in
data/datasets/amazon_sales.

128,975 order lines of an Indian fashion seller on Amazon.in, April to June 2022: the order, its status and how it was
fulfilled and shipped, the product (style, SKU, category, size), quantity and amount in rupees, and where it went. It is
both personas' sales dataset: the Data Scientist asks what sells and where, the ML Engineer trains a model of which
orders get cancelled - CANCELLED (1 when the status is "Cancelled") is the label.

Cleaned, nothing invented: column names spelled out in SQL style, dates ISO (the source writes MM-DD-YY), postal codes
without the ".0" a spreadsheet gave them, True/False as 1/0, text folded to one line. Two source columns are left out:
the empty "Unnamed: 22", and the promotion IDs (internal codes up to 2,300 characters), kept as HAS_PROMOTION.

    python3 tools/datasets/amazon_sales.py "~/Downloads/Amazon Sale Report.csv"
"""

from __future__ import annotations

import csv
import datetime as dt
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

URL = "https://www.kaggle.com/search?q=Amazon+Sale+Report"   # the file's title; the page it came from was not recorded
HERE = DATASETS / "amazon_sales"
TABLES = {"ORDER_LINES": ["ORDER_LINE_ID", "ORDER_ID", "ORDER_DATE", "STATUS", "FULFILMENT", "SALES_CHANNEL",
                          "SHIP_SERVICE_LEVEL", "STYLE_CODE", "SKU", "CATEGORY", "SIZE", "ASIN", "COURIER_STATUS", "QTY",
                          "CURRENCY", "AMOUNT", "SHIP_CITY", "SHIP_STATE", "SHIP_POSTAL_CODE", "SHIP_COUNTRY",
                          "HAS_PROMOTION", "IS_B2B", "FULFILLED_BY", "CANCELLED"]}


def _postal(value: str) -> str:
    value = value.strip()
    return value[:-2] if value.endswith(".0") else value


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    with Path(argv[0]).expanduser().open(encoding="utf-8", newline="") as handle:
        source = list(csv.DictReader(handle))
    rows = []
    for r in source:
        status = clean(r["Status"])
        rows.append([int(r["index"]) + 1, r["Order ID"].strip(),
                     dt.datetime.strptime(r["Date"], "%m-%d-%y").date().isoformat(), status, r["Fulfilment"].strip(),
                     r["Sales Channel "].strip(), r["ship-service-level"].strip(), r["Style"].strip(), r["SKU"].strip(),
                     clean(r["Category"]), r["Size"].strip(), r["ASIN"].strip(), r["Courier Status"].strip(),
                     int(r["Qty"]), r["currency"].strip(), r["Amount"].strip(), clean(r["ship-city"]).upper(),
                     clean(r["ship-state"]).upper(), _postal(r["ship-postal-code"]), r["ship-country"].strip(),
                     1 if r["promotion-ids"].strip() else 0, 1 if r["B2B"] == "True" else 0, r["fulfilled-by"].strip(),
                     1 if status == "Cancelled" else 0])
    files = write_tables(HERE, TABLES, {"ORDER_LINES": rows})
    write_manifest(HERE,
                   {"name": "Amazon Sale Report (Kaggle; the exact page was not recorded)", "url": URL,
                    "file": "Amazon Sale Report.csv", "builder": "tools/datasets/amazon_sales.py"},
                   {"url": URL, "license": "as stated on the Kaggle dataset page (not confirmed)",
                    "summary": "Amazon.in order lines of one fashion seller, April-June 2022, as published on Kaggle. The "
                               "licence has not been confirmed: check the dataset page before redistributing it.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
