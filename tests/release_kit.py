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


def kit_with_hidden_parts_on(where: Path, personas: tuple[str, ...] = HIDDEN_PERSONAS,
                             addons: tuple[str, ...] = HIDDEN_ADDONS) -> Path:
    """The kit copy at ``where`` with ``personas`` and ``addons`` switched on (by default every hidden one)."""
    where.mkdir(parents=True)
    for entry in ROOT.iterdir():
        if entry.name in (".git", "personas", "marketplace"):
            continue
        try:
            (where / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
        except OSError:                                    # no symlinks here (Windows without the right): a copy
            (shutil.copytree if entry.is_dir() else shutil.copy2)(entry, where / entry.name)
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
