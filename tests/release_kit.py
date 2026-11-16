"""A kit root with this release's hidden parts switched back on, for the tests that exercise them.

The release ships the Data Scientist and ML Engineer personas and the notebook and udf-devkit add-ons disabled
("visible": false - kept, not removed). What they do once switched on is still the kit's code, so the tests that
exercise it run against a copy of this checkout where they are on: everything is linked to the checkout except
personas/ and marketplace/, which are copied and edited.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HIDDEN_PERSONAS = ("data-scientist", "ml-engineer")
HIDDEN_ADDONS = ("notebook", "udf-devkit")
HIDDEN_DATASETS = ("tpch", "energy", "weather", "amazon_sales", "fraud_transactions")


def kit_with_hidden_parts_on(where: Path, personas: tuple[str, ...] = HIDDEN_PERSONAS,
                             addons: tuple[str, ...] = HIDDEN_ADDONS,
                             datasets: tuple[str, ...] = HIDDEN_DATASETS) -> Path:
    """The kit copy at ``where`` with ``personas``, ``addons`` and ``datasets`` switched on (by default every hidden
    one). data/datasets is a folder of links whose dataset.conf files are copies, edited."""
    where.mkdir(parents=True)
    for entry in ROOT.iterdir():
        if entry.name in (".git", "personas", "marketplace", "data"):
            continue
        try:
            (where / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
        except OSError:                                    # no symlinks here (Windows without the right): a copy
            (shutil.copytree if entry.is_dir() else shutil.copy2)(entry, where / entry.name)
    _link_tree(ROOT / "data", where / "data", skip={"datasets"})
    for dataset in sorted((ROOT / "data" / "datasets").iterdir()):
        if not dataset.is_dir():
            continue
        _link_tree(dataset, where / "data" / "datasets" / dataset.name, skip={"dataset.conf"})
        conf = dataset / "dataset.conf"
        if conf.is_file():
            lines = conf.read_text(encoding="utf-8").splitlines()
            if dataset.name in datasets:
                lines = [line for line in lines if not line.startswith("hidden=")]
            (where / "data" / "datasets" / dataset.name / "dataset.conf").write_text("\n".join(lines) + "\n", encoding="utf-8")
    shutil.copytree(ROOT / "personas", where / "personas")
    for persona in personas:
        path = where / "personas" / f"{persona}.json"
        path.write_text(json.dumps({**json.loads(path.read_text(encoding="utf-8")), "visible": True}), encoding="utf-8")
    shutil.copytree(ROOT / "marketplace", where / "marketplace", ignore=shutil.ignore_patterns("__pycache__"))
    catalog = where / "marketplace" / "catalog.json"
    doc = json.loads(catalog.read_text(encoding="utf-8"))
    for row in doc["addons"]:
        if row["id"] in addons:
            row["visible"] = True
    catalog.write_text(json.dumps(doc), encoding="utf-8")
    return where


def _link_tree(source: Path, target: Path, skip: set[str]) -> None:
    """``target`` as a folder holding a link to each entry of ``source`` but those in ``skip``."""
    target.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        if entry.name in skip:
            continue
        try:
            (target / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
        except OSError:
            (shutil.copytree if entry.is_dir() else shutil.copy2)(entry, target / entry.name)
