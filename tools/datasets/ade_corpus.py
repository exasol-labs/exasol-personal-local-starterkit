"""Build the ade_corpus dataset from ADE-Corpus-V2: the CSVs and the manifest in data/datasets/ade_corpus.

The ADE corpus (Gurulingappa et al., 2012) is 20,960 sentences from PubMed case reports, each one read by annotators
for an adverse drug effect: 4,272 sentences name one (DRUG-AE.rel gives the drug and the effect, DRUG-DOSE.rel the
dose where one is named) and 16,688 do not (ADE-NEG.txt). It is a labelled text classification problem - does this
sentence report an adverse drug effect? - and an extraction one: which drug, which effect. One row per sentence carries
the label; the drug-effect and drug-dose pairs sit in their own tables, keyed to their sentence.

Cleaning: the seven repeated negative lines and the 188 repeated drug-effect pairs are kept once; the character offsets
(which point into the abstracts, not the sentences) are dropped; text is folded to one line. Nothing else changes.

    python3 tools/datasets/ade_corpus.py ~/Downloads/ADE-Corpus-V2.zip      # writes data/*.csv and manifest.json
"""

from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from snapshot import DATASETS, clean, write_manifest, write_tables

HERE = DATASETS / "ade_corpus"
TABLES = {"ADE_SENTENCES": ["SENTENCE_ID", "PUBMED_ID", "SENTENCE", "HAS_ADE"],
          "ADE_DRUG_EFFECTS": ["PAIR_ID", "SENTENCE_ID", "DRUG", "ADVERSE_EFFECT"],
          "ADE_DRUG_DOSES": ["PAIR_ID", "SENTENCE_ID", "DRUG", "DOSE"]}


def lines(archive: zipfile.ZipFile, name: str) -> list[str]:
    member = next(n for n in archive.namelist() if n.endswith("/" + name) and "__MACOSX" not in n)
    return [line for line in archive.read(member).decode("utf-8").splitlines() if line.strip()]


def main(argv: list[str]) -> int:
    if not argv:
        print("Name the ADE-Corpus-V2 zip: python3 tools/datasets/ade_corpus.py ADE-Corpus-V2.zip", file=sys.stderr)
        return 2
    archive = zipfile.ZipFile(Path(argv[0]).expanduser())
    effects = [line.split("|") for line in lines(archive, "DRUG-AE.rel")]
    doses = [line.split("|") for line in lines(archive, "DRUG-DOSE.rel")]
    negatives = [line.split(" NEG ", 1) for line in lines(archive, "ADE-NEG.txt")]
    # Sentences in the order the corpus gives them: the ones with an effect, then the ones without.
    ids: dict[tuple[str, str], int] = {}
    sentences = []
    for pmid, text, label in [(r[0], r[1], 1) for r in effects] + [(r[0], r[1], 0) for r in negatives]:
        key = (pmid.strip(), clean(text))
        if key not in ids:
            ids[key] = len(ids) + 1
            sentences.append([ids[key], int(key[0]), key[1], label])
    pairs, seen = [], set()
    for r in effects:
        row = (ids[(r[0].strip(), clean(r[1]))], clean(r[5]), clean(r[2]))
        if row not in seen:
            seen.add(row)
            pairs.append([len(pairs) + 1, *row])
    dose_rows, seen = [], set()
    for r in doses:
        row = (ids[(r[0].strip(), clean(r[1]))], clean(r[5]), clean(r[2]))
        if row not in seen:
            seen.add(row)
            dose_rows.append([len(dose_rows) + 1, *row])
    files = write_tables(HERE, TABLES, {"ADE_SENTENCES": sentences, "ADE_DRUG_EFFECTS": pairs, "ADE_DRUG_DOSES": dose_rows})
    write_manifest(HERE,
                   {"name": "ADE-Corpus-V2 (H. Gurulingappa et al., Benchmark Corpus to Support Information Extraction "
                            "for Adverse Drug Effects, Journal of Biomedical Informatics 45(5), 2012)",
                    "url": "https://doi.org/10.1016/j.jbi.2012.04.008", "file": "ADE-Corpus-V2.zip",
                    "builder": "tools/datasets/ade_corpus.py"},
                   {"url": "https://doi.org/10.1016/j.jbi.2012.04.008",
                    "license": "Research corpus, distributed with a request to cite the source article; no licence named",
                    "summary": "Sentences quoted from PubMed case-report abstracts with their annotations. Cite "
                               "Gurulingappa et al. (2012). Redistribution terms are still to be confirmed.",
                    "confirmed": False},
                   files)
    print(json.dumps({k: v["rows"] for k, v in files.items()}), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
