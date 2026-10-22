"""Build the banking_complaints snapshot from the CFPB Consumer Complaint Database: the CSV and the manifest in
data/datasets/banking_complaints.

The snapshot is every complaint about a credit card, a mortgage or a checking or savings account that the CFPB received
in the first two weeks of January 2025 - a few thousand rows whose outcome (closed with monetary relief or not) is
settled. The CFPB stopped publishing complaint narratives in 2026, so the text columns are the issue, the sub-issue and
the company's public response (see data/datasets/banking_complaints/README.md, "No complaint narratives").

    python3 tools/datasets/banking_complaints.py       # writes data/datasets/banking_complaints/data/*.csv and manifest.json
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

API = "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/"
QUERY = [("product", "Credit card"), ("product", "Mortgage"), ("product", "Checking or savings account"),
         ("date_received_min", "2025-01-01"), ("date_received_max", "2025-01-14")]
PAGE = 1000
HERE = DATASETS / "banking_complaints"
RELIEF = "Closed with monetary relief"

TABLES = {
    "BANKING_COMPLAINTS": ["COMPLAINT_ID", "DATE_RECEIVED", "DATE_SENT_TO_COMPANY", "PRODUCT", "SUB_PRODUCT", "ISSUE",
                           "SUB_ISSUE", "COMPANY", "CONSUMER_STATE", "SUBMITTED_VIA", "TAGS", "TIMELY", "MONETARY_RELIEF",
                           "COMPANY_PUBLIC_RESPONSE"],
    "BANKING_RESPONSES": ["COMPLAINT_ID", "COMPANY_RESPONSE"],     # the label's source: apart, so it is never a feature
}


def fetch() -> list[dict]:
    """Every complaint the query matches, a page at a time, oldest first: each page starts after the last one's sort key
    (the API ignores an offset)."""
    found: list[dict] = []
    after = ""
    while True:
        params = [*QUERY, ("size", str(PAGE)), ("no_aggs", "true"), ("sort", "created_date_asc")]
        if after:
            params.append(("search_after", after))
        with urllib.request.urlopen(f"{API}?{urllib.parse.urlencode(params)}", timeout=120) as answer:   # noqa: S310 - a fixed https URL
            hits = json.load(answer)["hits"]
        found += [hit["_source"] for hit in hits["hits"]]
        print(f"  {len(found)} of {hits['total']['value']} complaints", file=sys.stderr)
        if not hits["hits"] or len(found) >= hits["total"]["value"]:
            return found
        after = "_".join(str(v) for v in hits["hits"][-1]["sort"])
        time.sleep(0.5)


def row(c: dict) -> list:
    """One complaint as a row of BANKING_COMPLAINTS (its company response goes to BANKING_RESPONSES)."""
    return [int(c["complaint_id"]), c["date_received"][:10], (c.get("date_sent_to_company") or "")[:10], c["product"],
            c.get("sub_product") or "", c.get("issue") or "", c.get("sub_issue") or "", clean(c["company"], 200),
            c.get("state") or "", c.get("submitted_via") or "", c.get("tags") or "", 1 if c.get("timely") == "Yes" else 0,
            1 if c.get("company_response") == RELIEF else 0,
            clean(c.get("company_public_response"), 300)]


def main() -> int:
    complaints = {c["complaint_id"]: c for c in fetch()}          # a page boundary never doubles a complaint
    files = write_tables(HERE, TABLES, {"BANKING_COMPLAINTS": [row(c) for c in complaints.values()],
                                        "BANKING_RESPONSES": [[int(i), c.get("company_response") or ""] for i, c in complaints.items()]})
    write_manifest(HERE,
                   {"name": "Consumer Complaint Database (U.S. Consumer Financial Protection Bureau)", "url": API,
                    "query": dict(QUERY[3:]) | {"product": [v for k, v in QUERY if k == "product"]},
                    "builder": "tools/datasets/banking_complaints.py"},
                   {"url": "https://www.consumerfinance.gov/complaint/data-use/",
                    "license": "CC0 1.0 (the API answers with _meta.license = CC0)",
                    "summary": "Public domain dedication: free to copy, change and redistribute. The CFPB does not verify "
                               "complaints; a complaint is not a finding against the company.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
