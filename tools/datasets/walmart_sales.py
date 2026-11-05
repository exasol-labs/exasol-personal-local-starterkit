"""Build the walmart_sales dataset from the Kaggle "Walmart Data Analysis and Forecasting" CSV: the CSV and the manifest
in data/datasets/walmart_sales.

45 Walmart stores, one row per store and week from February 2010 to October 2012: the week's sales, whether a holiday
fell in it, and four things around the store that week (temperature, fuel price, consumer price index, unemployment).
The Data Scientist explores sales by store and season. ABOVE_STORE_MEDIAN is the one column the kit adds: 1 when the
week sold more than that store's median week - the label a model of "a strong week" predicts. Dates become ISO (the
source writes DD-MM-YYYY), the flag gets a name, and nothing else changes.

    python3 tools/datasets/walmart_sales.py "~/Downloads/Walmart Data Analysis and Forcasting.csv"
"""

from __future__ import annotations

import csv
import datetime as dt
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, write_manifest, write_tables

URL = "https://www.kaggle.com/search?q=Walmart+Data+Analysis+and+Forcasting"   # the file's title; the page it came from was not recorded
HERE = DATASETS / "walmart_sales"
TABLES = {"WEEKLY_SALES": ["SALES_ID", "STORE", "WEEK_DATE", "WEEKLY_SALES", "HOLIDAY_WEEK", "TEMPERATURE_F",
                           "FUEL_PRICE", "CPI", "UNEMPLOYMENT", "ABOVE_STORE_MEDIAN"]}


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    with Path(argv[0]).expanduser().open(encoding="utf-8", newline="") as handle:
        source = list(csv.DictReader(handle))
    source.sort(key=lambda r: (int(r["Store"]), dt.datetime.strptime(r["Date"], "%d-%m-%Y").date()))
    # The label: a week that sold more than the store's own median week. Computed from WEEKLY_SALES alone, per store,
    # so a big store's ordinary week is not a "strong" one.
    by_store: dict[int, list[float]] = {}
    for r in source:
        by_store.setdefault(int(r["Store"]), []).append(float(r["Weekly_Sales"]))
    median = {store: statistics.median(sales) for store, sales in by_store.items()}
    rows = []
    for n, r in enumerate(source, 1):
        week = dt.datetime.strptime(r["Date"], "%d-%m-%Y").date().isoformat()
        rows.append([n, int(r["Store"]), week, r["Weekly_Sales"], int(r["Holiday_Flag"]), r["Temperature"],
                     r["Fuel_Price"], r["CPI"], r["Unemployment"],
                     1 if float(r["Weekly_Sales"]) > median[int(r["Store"])] else 0])
    files = write_tables(HERE, TABLES, {"WEEKLY_SALES": rows})
    write_manifest(HERE,
                   {"name": "Walmart Data Analysis and Forecasting (Kaggle; the exact page was not recorded)", "url": URL,
                    "file": "Walmart Data Analysis and Forcasting.csv", "builder": "tools/datasets/walmart_sales.py"},
                   {"url": URL, "license": "as stated on the Kaggle dataset page (not confirmed)",
                    "summary": "Weekly sales of 45 Walmart stores, 2010-2012, as published on Kaggle. The licence has not "
                               "been confirmed: check the dataset page before redistributing it.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
