"""Build the pubmed_abstracts dataset: the CSV and the manifest in data/datasets/pubmed_abstracts.

1,409 PubMed abstracts of clinical studies - interferon beta in multiple sclerosis, lymphoma, drug safety - one per
line in the source file, the input a medical NLP service (entity, relation and condition extraction) is shown with. It
is the free-text dataset: long documents to summarise, search, classify or extract from. The opening section heading
(BACKGROUND, OBJECTIVE, ...) is kept as its own column, so structured and unstructured abstracts can be told apart.

Cleaning: leading and trailing spaces stripped, the twelve repeated abstracts kept once, the seven "FDA review"
placeholder lines dropped. The text is otherwise as given.

    python3 tools/datasets/pubmed_abstracts.py ~/Downloads/CarteraDB_Compreend.txt
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

HERE = DATASETS / "pubmed_abstracts"
TABLES = {"PUBMED_ABSTRACTS": ["ABSTRACT_ID", "FIRST_SECTION", "WORD_COUNT", "ABSTRACT_TEXT"]}
HEADING = re.compile(r"^([A-Z][A-Z ]{2,40}):\s")
PLACEHOLDERS = {"FDA review"}


def main(argv: list[str]) -> int:
    if not argv:
        print("Name the abstracts file: python3 tools/datasets/pubmed_abstracts.py CarteraDB_Compreend.txt", file=sys.stderr)
        return 2
    rows, seen = [], set()
    for line in Path(argv[0]).expanduser().read_text(encoding="utf-8").splitlines():
        text = clean(line)
        if not text or text in PLACEHOLDERS or text in seen:
            continue
        seen.add(text)
        heading = HEADING.match(text)
        rows.append([len(rows) + 1, heading.group(1).strip() if heading else "", len(text.split()), text])
    files = write_tables(HERE, TABLES, {"PUBMED_ABSTRACTS": rows})
    write_manifest(HERE,
                   {"name": "PubMed abstracts of clinical studies (U.S. National Library of Medicine), as supplied for "
                            "medical text extraction", "url": "https://pubmed.ncbi.nlm.nih.gov/",
                    "file": "CarteraDB_Compreend.txt", "builder": "tools/datasets/pubmed_abstracts.py"},
                   {"url": "https://www.nlm.nih.gov/databases/download/terms_and_conditions.html",
                    "license": "PubMed abstracts: copyright stays with the publishers; NLM's terms apply",
                    "summary": "Abstracts as published in PubMed. Some publishers hold copyright on their abstracts; "
                               "whether they may be redistributed here is still to be confirmed.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
