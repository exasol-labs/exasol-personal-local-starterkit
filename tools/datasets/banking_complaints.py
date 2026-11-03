"""Build the banking_complaints snapshot from the CFPB Consumer Complaint Database: the CSVs and the manifest in
data/datasets/banking_complaints.

The snapshot is every complaint about a credit card, a mortgage or a checking or savings account that the CFPB received
from October 2025 to September 2026 - twelve complete months, about 215,000 complaints, each with a settled outcome (closed with
monetary relief or not; the few still "In progress" are left out, their label is not known yet). It is read from the
database's full export, complaints.csv.zip (18.9M complaints, 5.7 GB unzipped), streamed: nothing but the window is
kept. The export has no narratives (the CFPB stopped publishing them), so the text columns are the issue, the sub-issue
and the company's public response (see data/datasets/banking_complaints/README.md, "No complaint narratives").

    python3 tools/datasets/banking_complaints.py ~/Downloads/complaints.csv.zip   # from a copy of the export you have
    python3 tools/datasets/banking_complaints.py                                  # downloads the export first (~360 MB)
"""

from __future__ import annotations

import csv
import io
import json
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

EXPORT = "https://files.consumerfinance.gov/ccdb/complaints.csv.zip"
PRODUCTS = ("Credit card", "Mortgage", "Checking or savings account")
FIRST, LAST = "2025-10-01", "2026-09-30"
HERE = DATASETS / "banking_complaints"
RELIEF = "Closed with monetary relief"
OPEN = "In progress"

TABLES = {
    "BANKING_COMPLAINTS": ["COMPLAINT_ID", "DATE_RECEIVED", "DATE_SENT_TO_COMPANY", "PRODUCT", "SUB_PRODUCT", "ISSUE",
                           "SUB_ISSUE", "COMPANY", "CONSUMER_STATE", "SUBMITTED_VIA", "TAGS", "TIMELY", "MONETARY_RELIEF",
                           "COMPANY_PUBLIC_RESPONSE"],
    "BANKING_RESPONSES": ["COMPLAINT_ID", "COMPANY_RESPONSE"],     # the label's source: apart, so it is never a feature
}


def complaints(export: Path):
    """The window's complaints from the export, streamed row by row; one per complaint id."""
    seen = set()
    with zipfile.ZipFile(export) as archive, archive.open("complaints.csv") as raw:
        for c in csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8", newline="")):
            if c["Product"] not in PRODUCTS or not FIRST <= c["Date received"] <= LAST:
                continue
            if c["Company response to consumer"] in ("", OPEN) or c["Complaint ID"] in seen:
                continue
            seen.add(c["Complaint ID"])
            yield c


def row(c: dict) -> list:
    """One complaint as a row of BANKING_COMPLAINTS (its company response goes to BANKING_RESPONSES). The ZIP code is
    left out: with the date and the company it narrows a complaint down to a person."""
    return [int(c["Complaint ID"]), c["Date received"], c["Date sent to company"], c["Product"], clean(c["Sub-product"], 100),
            clean(c["Issue"], 120), clean(c["Sub-issue"], 200), clean(c["Company"], 200), c["State"][:2],
            c["Submitted via"], c["Tags"], 1 if c["Timely response?"] == "Yes" else 0,
            1 if c["Company response to consumer"] == RELIEF else 0, clean(c["Company public response"], 300)]


def main(argv: list[str]) -> int:
    with tempfile.TemporaryDirectory() as temp:
        if argv:
            export = Path(argv[0]).expanduser()
        else:
            export = Path(temp) / "complaints.csv.zip"
            with urllib.request.urlopen(EXPORT, timeout=600) as answer, export.open("wb") as out:   # noqa: S310 - fixed https
                shutil.copyfileobj(answer, out)
        rows, responses = [], []
        for c in complaints(export):
            rows.append(row(c))
            responses.append([int(c["Complaint ID"]), c["Company response to consumer"]])
    files = write_tables(HERE, TABLES, {"BANKING_COMPLAINTS": rows, "BANKING_RESPONSES": responses})
    write_manifest(HERE,
                   {"name": "Consumer Complaint Database (U.S. Consumer Financial Protection Bureau)", "url": EXPORT,
                    "query": {"date_received_min": FIRST, "date_received_max": LAST, "product": list(PRODUCTS),
                              "company_response": f"settled (not '{OPEN}')"},
                    "builder": "tools/datasets/banking_complaints.py"},
                   {"url": "https://www.consumerfinance.gov/complaint/data-use/",
                    "license": "CC0 1.0 (the CFPB's data-use terms)",
                    "summary": "Public domain dedication: free to copy, change and redistribute. The CFPB does not verify "
                               "complaints; a complaint is not a finding against the company.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
