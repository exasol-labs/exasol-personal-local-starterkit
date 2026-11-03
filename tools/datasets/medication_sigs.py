"""Build the medication_sigs dataset: the CSV and the manifest in data/datasets/medication_sigs.

49 prescription directions ("sigs") as prescribers write them - "1 cap(s) po tid,x7 day(s)", "take 1 capsule (100 mg total)
by mouth 3 (three) times a day as needed for cough" - abbreviations, Latin and plain English mixed. A small text set
for reading the dose, the route, how often and for how long out of free text, and for checking a model that does it.

Cleaning: spaces folded, the text otherwise as written (lower case and abbreviations kept: they are the point).

    python3 tools/datasets/medication_sigs.py ~/Downloads/ReadFile_Medical_1.txt
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

HERE = DATASETS / "medication_sigs"
TABLES = {"MEDICATION_SIGS": ["SIG_ID", "WORD_COUNT", "SIG_TEXT"]}


def main(argv: list[str]) -> int:
    if not argv:
        print("Name the sigs file: python3 tools/datasets/medication_sigs.py ReadFile_Medical_1.txt", file=sys.stderr)
        return 2
    rows, seen = [], set()
    for line in Path(argv[0]).expanduser().read_text(encoding="utf-8").splitlines():
        text = clean(line)
        if text and text not in seen:
            seen.add(text)
            rows.append([len(rows) + 1, len(text.split()), text])
    files = write_tables(HERE, TABLES, {"MEDICATION_SIGS": rows})
    write_manifest(HERE,
                   {"name": "Prescription directions (sigs), a sample for medication-text extraction",
                    "file": "ReadFile_Medical_1.txt", "builder": "tools/datasets/medication_sigs.py"},
                   {"license": "Supplied with the kit's requirements; origin and terms to be confirmed",
                    "summary": "Generic prescription directions with no patient, prescriber or pharmacy named.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
