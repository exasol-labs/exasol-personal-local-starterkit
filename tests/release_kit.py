"""A kit root with more than this release offers, for the tests of the mechanisms that serve it.

The release ships one persona (General) and shows two sample datasets; TPC-H, energy and weather stay in the kit
hidden ("hidden=yes", kept for kits that loaded them before). The persona and data-table code still combines several
personas and lists many datasets, so the tests that exercise that run against a copy of this checkout with:

- the hidden datasets switched back on,
- two fixture datasets, orders_demo and payments_demo (a dataset.conf and a schema script each, nothing to load),
- two fixture personas: analyst (offered) and engineer (kept, not offered: "visible": false).

Everything is linked to the checkout except personas/ and data/datasets, which are built here.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HIDDEN_DATASETS = ("tpch", "energy", "weather")
FIXTURE_DATASETS = {
    "orders_demo": {"label": "Orders demo (fixture orders, ~10 lines)", "description": "Online orders",
                    "schema": "ORDERS_DEMO", "markers": "ORDER_LINES", "order": "50"},
    "payments_demo": {"label": "Payments demo (fixture payments, with gaps)", "description": "Payments with a flag",
                      "schema": "PAYMENTS_DEMO", "markers": "TRANSACTIONS", "order": "60"},
}
FIXTURE_PERSONAS = {
    "analyst": {"schema_version": 1, "id": "analyst", "title": "Data Analyst",
                "summary": "Explore data, ask it questions, share dashboards.", "picker": True, "visible": False,
                "order": 10, "datasets": ["orders_demo", "payments_demo"], "mcp_clients": "all",
                "addons": ["dash-server", "dbt-exasol", "json-tables", "semantic-views"],
                "addon_reasons": {"dash-server": "Share what you find as a live dashboard others open in a browser",
                                  "dbt-exasol": "Model your data with dbt against the local database",
                                  "json-tables": "Load JSON files and folders as tables, nested data included",
                                  "semantic-views": "The semantic layer AI clients query"}},
    "engineer": {"schema_version": 1, "id": "engineer", "title": "Engineer",
                 "summary": "Build and schedule the jobs that keep the data fresh.", "picker": True, "visible": False,
                 "order": 20, "datasets": ["orders_demo", "payments_demo"], "mcp_clients": "all",
                 "addons": ["dbt-exasol", "exasol-scheduler"],
                 "addon_reasons": {"dbt-exasol": "Build the models your jobs run, with dbt",
                                   "exasol-scheduler": "Run SQL jobs on a schedule inside the database"}},
}


def kit_with_hidden_parts_on(where: Path, personas: tuple[str, ...] = ("analyst",), addons: tuple[str, ...] = (),
                             datasets: tuple[str, ...] = HIDDEN_DATASETS) -> Path:
    """The kit copy at ``where`` with the fixture personas (those in ``personas`` offered), the fixture datasets,
    ``datasets`` switched on and the marketplace ``addons`` made visible. data/datasets is a folder of links whose
    dataset.conf files are copies, edited."""
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
    for dataset_id, conf in FIXTURE_DATASETS.items():
        folder = where / "data" / "datasets" / dataset_id
        folder.mkdir(parents=True)
        (folder / "dataset.conf").write_text(f"id={dataset_id}\n" + "".join(f"{k}={v}\n" for k, v in conf.items()),
                                             encoding="utf-8")
        (folder / "01_create_schema.sql").write_text(f"CREATE SCHEMA IF NOT EXISTS {conf['schema']};\n", encoding="utf-8")
    shutil.copytree(ROOT / "personas", where / "personas")
    for persona_id, doc in FIXTURE_PERSONAS.items():
        (where / "personas" / f"{persona_id}.json").write_text(
            json.dumps({**doc, "visible": persona_id in personas}), encoding="utf-8")
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
