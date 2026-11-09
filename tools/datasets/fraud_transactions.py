"""Build the fraud_transactions dataset from the Kaggle "Fraud Detection Dataset" CSV: the CSV and the manifest in
data/datasets/fraud_transactions.

51,000 card and bank transactions of 4,000 users, each with its amount, type, the hour of day it happened, the device,
city and payment method used, the user's earlier fraud count, account age and number of transactions in the last 24
hours, and whether it was FRAUDULENT (the label, 4.9% of rows). There is no date: TRANSACTION_HOUR is the hour of day.

It is the Data Scientist's messy dataset ON PURPOSE, and nothing is cleaned away: 1,000 transaction IDs occur twice (881
as exact copies), about 5% of the amount, hour, device, city and payment method are empty, and two placeholder values
stand in for unknowns ("Unknown Device", "Invalid Method"). Finding those - and deciding what to do with them before
trusting a fraud rate - is the Prepare and Validate part of the persona's loop. ROW_ID is the key the kit adds, because
TRANSACTION_ID is not unique. Column names are spelled out in SQL style, the hour becomes a whole number (the source
writes 16.0), amounts are cents (the source carries float noise such as 49997.799999999996), empty cells become NULL;
nothing else changes.

    python3 tools/datasets/fraud_transactions.py "~/Downloads/Fraud Detection Dataset.csv"
"""

from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

URL = "https://www.kaggle.com/search?q=Fraud+Detection+Dataset"   # the file's title; the page it came from was not recorded
HERE = DATASETS / "fraud_transactions"
TABLES = {"TRANSACTIONS": ["ROW_ID", "TRANSACTION_ID", "USER_ID", "TRANSACTION_AMOUNT", "TRANSACTION_TYPE",
                           "TRANSACTION_HOUR", "DEVICE_USED", "LOCATION", "PREVIOUS_FRAUDULENT_TRANSACTIONS",
                           "ACCOUNT_AGE", "TRANSACTIONS_LAST_24H", "PAYMENT_METHOD", "FRAUDULENT"]}


def _hour(value: str) -> str:
    """16.0 -> 16; empty stays empty (NULL)."""
    return str(int(float(value))) if value.strip() else ""


def _amount(value: str) -> str:
    """49997.799999999996 -> 49997.80; empty stays empty (NULL)."""
    return f"{float(value):.2f}" if value.strip() else ""


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    with Path(argv[0]).expanduser().open(encoding="utf-8", newline="") as handle:
        source = list(csv.DictReader(handle))
    rows = []
    for n, r in enumerate(source, 1):                      # the source order, kept: ROW_ID is the line it was on
        rows.append([n, clean(r["Transaction_ID"]), int(r["User_ID"]), _amount(r["Transaction_Amount"]),
                     clean(r["Transaction_Type"]), _hour(r["Time_of_Transaction"]), clean(r["Device_Used"]),
                     clean(r["Location"]), int(r["Previous_Fraudulent_Transactions"]), int(r["Account_Age"]),
                     int(r["Number_of_Transactions_Last_24H"]), clean(r["Payment_Method"]), int(r["Fraudulent"])])
    files = write_tables(HERE, TABLES, {"TRANSACTIONS": rows})
    write_manifest(HERE,
                   {"name": "Fraud Detection Dataset (Kaggle; the exact page was not recorded)", "url": URL,
                    "file": "Fraud Detection Dataset.csv", "builder": "tools/datasets/fraud_transactions.py"},
                   {"url": URL, "license": "as stated on the Kaggle dataset page (not confirmed)",
                    "summary": "51,000 card and bank transactions with a fraud label, as published on Kaggle. The "
                               "licence has not been confirmed: check the dataset page before redistributing it.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
