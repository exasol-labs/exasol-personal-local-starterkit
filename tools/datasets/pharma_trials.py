"""Build the pharma_trials snapshot from the ClinicalTrials.gov API v2: the CSVs and the manifest in data/datasets/pharma_trials.

The snapshot is the industry-sponsored, interventional Phase 2 and Phase 3 trials that started in 2016-2018 and ended
COMPLETED or TERMINATED - outcomes that are known, a few thousand rows, small enough for an 8 GB laptop. Rerunning it
on another day can return a few changed records; the manifest records the date and the digests of what shipped.

    python3 tools/datasets/pharma_trials.py            # writes data/datasets/pharma_trials/data/pharma_*.csv and manifest.json
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

API = "https://clinicaltrials.gov/api/v2/studies"
QUERY = ("AREA[StudyType]INTERVENTIONAL AND AREA[Phase](PHASE2 OR PHASE3) AND "
         "AREA[StartDate]RANGE[2016-01-01,2018-12-31] AND AREA[LeadSponsorClass]INDUSTRY")
STATUSES = "COMPLETED,TERMINATED"
FIELDS = ("NCTId,BriefTitle,Phase,OverallStatus,StartDate,PrimaryCompletionDate,EnrollmentCount,LeadSponsorName,"
          "LeadSponsorClass,CollaboratorName,CollaboratorClass,DesignAllocation,DesignPrimaryPurpose,DesignMasking,Condition,"
          "InterventionType,InterventionName,BriefSummary,EligibilityCriteria,WhyStopped,HasResults")
HERE = DATASETS / "pharma_trials"
TEXT_LIMIT = 2000                  # characters of a summary or of the criteria kept: a paragraph, not the protocol

TABLES = {
    "PHARMA_TRIALS": ["NCT_ID", "BRIEF_TITLE", "PHASE", "OVERALL_STATUS", "TERMINATED", "START_DATE", "PRIMARY_COMPLETION_DATE",
               "ENROLLMENT", "LEAD_SPONSOR", "ALLOCATION", "PRIMARY_PURPOSE", "MASKING", "HAS_RESULTS", "BRIEF_SUMMARY",
               "ELIGIBILITY_CRITERIA"],
    "PHARMA_SPONSORS": ["NCT_ID", "SEQ", "SPONSOR_ROLE", "SPONSOR_NAME", "SPONSOR_CLASS"],
    "PHARMA_CONDITIONS": ["NCT_ID", "CONDITION_NAME"],
    "PHARMA_INTERVENTIONS": ["NCT_ID", "SEQ", "INTERVENTION_TYPE", "INTERVENTION_NAME"],
    "PHARMA_STOP_REASONS": ["NCT_ID", "WHY_STOPPED"],
}


def fetch() -> list[dict]:
    """Every study the query matches, page by page."""
    studies, token = [], None
    while True:
        params = {"filter.advanced": QUERY, "filter.overallStatus": STATUSES, "fields": FIELDS, "pageSize": "1000"}
        if token:
            params["pageToken"] = token
        with urllib.request.urlopen(f"{API}?{urllib.parse.urlencode(params)}", timeout=120) as answer:   # noqa: S310 - a fixed https URL
            page = json.load(answer)
        studies += page.get("studies", [])
        token = page.get("nextPageToken")
        print(f"  {len(studies)} studies", file=sys.stderr)
        if not token:
            return studies
        time.sleep(0.5)


def month(value: str | None) -> str:
    """"2017-03" or "2017-03-14" as a DATE literal (a month alone is its first day); empty when unknown."""
    if not value:
        return ""
    return value if len(value) == 10 else f"{value[:7]}-01"


def rows(study: dict) -> dict[str, list[list]]:
    """One study's rows, per table."""
    p = study["protocolSection"]
    nct = p["identificationModule"]["nctId"]
    status = p["statusModule"]["overallStatus"]
    design = p.get("designModule", {})
    info = design.get("designInfo", {})
    trial = [nct, clean(p["identificationModule"].get("briefTitle"), 300), "/".join(design.get("phases", [])), status,
             1 if status == "TERMINATED" else 0, month(p["statusModule"].get("startDateStruct", {}).get("date")),
             month(p["statusModule"].get("primaryCompletionDateStruct", {}).get("date")),
             design.get("enrollmentInfo", {}).get("count", ""), clean(p["sponsorCollaboratorsModule"]["leadSponsor"]["name"], 200),
             info.get("allocation", ""), info.get("primaryPurpose", ""), info.get("maskingInfo", {}).get("masking", ""),
             1 if study.get("hasResults") else 0, clean(p.get("descriptionModule", {}).get("briefSummary"), TEXT_LIMIT),
             clean(p.get("eligibilityModule", {}).get("eligibilityCriteria"), TEXT_LIMIT)]
    conditions = sorted({clean(c, 200) for c in p.get("conditionsModule", {}).get("conditions", []) if clean(c)})
    interventions = p.get("armsInterventionsModule", {}).get("interventions", [])
    out = {"PHARMA_TRIALS": [trial], "PHARMA_SPONSORS": sponsors(nct, p["sponsorCollaboratorsModule"]),
           "PHARMA_CONDITIONS": [[nct, c] for c in conditions],
           "PHARMA_INTERVENTIONS": [[nct, i + 1, x.get("type", ""), clean(x.get("name"), 200)] for i, x in enumerate(interventions)],
           "PHARMA_STOP_REASONS": []}
    why = clean(p["statusModule"].get("whyStopped"), 500)
    if why:
        out["PHARMA_STOP_REASONS"].append([nct, why])
    return out


def sponsors(nct: str, module: dict) -> list[list]:
    """The lead sponsor (SEQ 1) and the collaborators after it, in the order the record lists them."""
    lead = module["leadSponsor"]
    found = [["LEAD", lead]] + [["COLLABORATOR", c] for c in module.get("collaborators", []) if clean(c.get("name"))]
    return [[nct, i + 1, role, clean(x.get("name"), 200), x.get("class", "")] for i, (role, x) in enumerate(found)]


def write(studies: list[dict]) -> dict:
    """The CSVs; {path: {rows, sha256}} for the manifest."""
    tables: dict[str, list[list]] = {name: [] for name in TABLES}
    for study in studies:
        if not study["protocolSection"].get("descriptionModule", {}).get("briefSummary"):
            continue                                      # the text role needs a summary on every row
        for name, found in rows(study).items():
            tables[name] += found
    return write_tables(HERE, TABLES, tables)


def main() -> int:
    files = write(fetch())
    write_manifest(HERE,
                   {"name": "ClinicalTrials.gov API v2 (U.S. National Library of Medicine)", "url": API,
                    "query": {"filter.advanced": QUERY, "filter.overallStatus": STATUSES, "fields": FIELDS},
                    "builder": "tools/datasets/pharma_trials.py"},
                   {"url": "https://clinicaltrials.gov/about-site/terms-conditions",
                    "summary": "ClinicalTrials.gov data are provided by the U.S. National Library of Medicine; the site "
                               "asks users to cite it as the source and not to imply endorsement.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
