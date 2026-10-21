"""Build the bank_marketing dataset from the UCI Machine Learning Repository: the CSV and the manifest in
data/datasets/bank_marketing.

Bank Marketing (Moro, Cortez and Rita, 2014) holds the 45,211 clients a Portuguese bank phoned in its term-deposit
campaigns of May 2008 to November 2010: who they are (age, job, marital status, education), their money (balance,
credit in default, housing and personal loans), the campaign's contacts, and whether they subscribed - the label. It is
the ML Engineer persona's dataset: a banking classification problem whose models the notebook trains, tracks with MLflow
and compares. The column names are spelled out (``default`` is an SQL keyword), yes/no become 1/0, and nothing else
changes.

    python3 tools/datasets/bank_marketing.py       # writes data/datasets/bank_marketing/data/bank_clients.csv and manifest.json
"""

from __future__ import annotations

import csv
import io
import json
import sys
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, write_manifest, write_tables

URL = "https://archive.ics.uci.edu/static/public/222/bank+marketing.zip"
HERE = DATASETS / "bank_marketing"
TABLES = {"BANK_CLIENTS": ["CLIENT_ID", "AGE", "JOB", "MARITAL", "EDUCATION", "CREDIT_IN_DEFAULT", "BALANCE", "HOUSING_LOAN",
                           "PERSONAL_LOAN", "CONTACT_TYPE", "LAST_CONTACT_DAY", "LAST_CONTACT_MONTH", "CALL_DURATION",
                           "CAMPAIGN_CONTACTS", "DAYS_SINCE_PREVIOUS", "PREVIOUS_CONTACTS", "PREVIOUS_OUTCOME", "SUBSCRIBED"]}
YES_NO = ("default", "housing", "loan", "y")


def main() -> int:
    with urllib.request.urlopen(URL, timeout=120) as answer:      # noqa: S310 - a fixed https URL
        outer = zipfile.ZipFile(io.BytesIO(answer.read()))
    inner = zipfile.ZipFile(io.BytesIO(outer.read("bank.zip")))
    reader = csv.DictReader(io.StringIO(inner.read("bank-full.csv").decode("utf-8")), delimiter=";")
    rows = []
    for n, r in enumerate(reader, 1):
        flags = {k: 1 if r[k] == "yes" else 0 for k in YES_NO}
        rows.append([n, int(r["age"]), r["job"], r["marital"], r["education"], flags["default"], int(r["balance"]),
                     flags["housing"], flags["loan"], r["contact"], int(r["day"]), r["month"], int(r["duration"]),
                     int(r["campaign"]), int(r["pdays"]), int(r["previous"]), r["poutcome"], flags["y"]])
    files = write_tables(HERE, TABLES, {"BANK_CLIENTS": rows})
    write_manifest(HERE,
                   {"name": "Bank Marketing (UCI Machine Learning Repository; S. Moro, P. Rita, P. Cortez, 2014)",
                    "url": "https://archive.ics.uci.edu/dataset/222/bank+marketing", "download": URL, "file": "bank.zip/bank-full.csv",
                    "doi": "10.24432/C5K306", "builder": "tools/datasets/bank_marketing.py"},
                   {"url": "https://creativecommons.org/licenses/by/4.0/",
                    "license": "CC BY 4.0 (the UCI dataset page)",
                    "summary": "Free to copy, change and redistribute with attribution: cite Moro, Rita and Cortez (2014), "
                               "Bank Marketing, UCI Machine Learning Repository, https://doi.org/10.24432/C5K306.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
