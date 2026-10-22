"""(run: python3 tests/test_notebook_contents.py) What the notebook add-on ships, held to what exists: every call a shipped
notebook makes into exakit_nb or exasol_mlflow (and on the Dataset and the MLflow run they return) is one the packages
define, every `exakit <command>` a notebook or helper tells the user to run is a command of this kit, the descriptor
rules shipped with exakit_nb are byte-identical to tools/descriptor_rules.py, every notebook has its .py source, and no
build output or egg-info is tracked."""

from __future__ import annotations

import ast
import dataclasses
import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))
sys.path.insert(0, str(ROOT / "packages" / "exasol-mlflow"))

import exakit_nb  # noqa: E402
import exasol_mlflow  # noqa: E402
from exakit_nb.dataset import Dataset  # noqa: E402

NOTEBOOKS = sorted((ROOT / "notebook" / "notebooks").glob("*.py")) + sorted((ROOT / "notebook" / "marimo").glob("*.py"))
HELPERS = sorted((ROOT / "notebook" / "package" / "exakit_nb").glob("*.py")) + sorted((ROOT / "notebook" / "kit").glob("*.py"))


def _members(cls) -> set[str]:
    names = set(dir(cls))
    if dataclasses.is_dataclass(cls):
        names |= {field.name for field in dataclasses.fields(cls)}
    return names


def _uses(path: Path, name: str) -> set[str]:
    """Every ``<name>.<attribute>`` in a notebook's code."""
    return {node.attr for node in ast.walk(ast.parse(path.read_text(encoding="utf-8")))
            if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == name}


def _commands() -> set[str]:
    """The commands setup/exakit dispatches (its `case "$1"` arms)."""
    text = (ROOT / "setup" / "exakit").read_text(encoding="utf-8")
    found = set()
    for arm in re.findall(r"^\s{4}([a-z][a-z0-9|-]*)\)", text, flags=re.M):
        found.update(arm.split("|"))
    return found


class CallsExistTest(unittest.TestCase):
    def test_every_package_call_a_notebook_makes_exists(self):
        targets = {"exakit_nb": set(dir(exakit_nb)), "exasol_mlflow": set(dir(exasol_mlflow)),
                   "ds": _members(Dataset), "run": _members(exasol_mlflow.Run) | set(vars(exasol_mlflow.Run(
                       None, None, experiment="e", run_name=None, params=None, tags=None, tracking_dir=None)))}
        for path in NOTEBOOKS:
            for name, known in targets.items():
                with self.subTest(notebook=path.relative_to(ROOT).as_posix(), on=name):
                    self.assertEqual(sorted(_uses(path, name) - known), [], f"{path.name} calls what {name} does not have")

    def test_start_here_has_its_source(self):
        for ipynb in (ROOT / "notebook" / "notebooks").glob("*.ipynb"):
            with self.subTest(notebook=ipynb.name):
                self.assertTrue(ipynb.with_suffix(".py").is_file(), f"{ipynb.name} has no .py source for tools/notebooks.py --check")

    def test_every_exakit_command_they_name_is_a_command(self):
        commands = _commands()
        self.assertIn("notebook", commands)
        for path in [*NOTEBOOKS, *(ROOT / "notebook" / "notebooks").glob("*.ipynb"), *HELPERS,
                     ROOT / "notebook" / "README.md", ROOT / "packages" / "exasol-mlflow" / "README.md"]:
            for command in set(re.findall(r"\bexakit ([a-z][a-z-]+)", path.read_text(encoding="utf-8"))):
                with self.subTest(file=path.name, command=command):
                    self.assertIn(command, commands)

    def test_every_notebook_option_they_name_exists(self):
        source = (ROOT / "setup" / "lib" / "notebook.sh").read_text(encoding="utf-8")
        for path in [*NOTEBOOKS, *HELPERS, ROOT / "notebook" / "README.md"]:
            for option in set(re.findall(r"\bexakit notebook (--[a-z-]+)", path.read_text(encoding="utf-8"))):
                with self.subTest(file=path.name, option=option):
                    self.assertRegex(source, rf"\n\s+([a-z|-]*\|)?{re.escape(option)}(\|[a-z-]*)*\)")

    def test_no_reference_to_files_this_kit_lacks(self):
        for path in [*NOTEBOOKS, *(ROOT / "notebook" / "notebooks").glob("*.ipynb"), *HELPERS, ROOT / "notebook" / "README.md"]:
            text = path.read_text(encoding="utf-8")
            for gone in ("data/datasets/README.md", "docs/design.md"):
                with self.subTest(file=path.name, reference=gone):
                    self.assertNotIn(gone, text)

    def test_the_catalog_names_files_that_exist(self):
        doc = json.loads((ROOT / "notebook" / "catalog.json").read_text(encoding="utf-8"))
        for entry in doc["notebooks"]:
            for front in ("jupyter", "marimo"):
                if entry.get(front):
                    with self.subTest(entry=entry["id"], front=front):
                        self.assertTrue((ROOT / doc["sources"][front] / entry[front]).is_file())


class GuardTest(unittest.TestCase):
    def test_the_descriptor_rules_are_one_file_in_two_places(self):
        self.assertEqual((ROOT / "notebook" / "package" / "exakit_nb" / "descriptor_rules.py").read_bytes(),
                         (ROOT / "tools" / "descriptor_rules.py").read_bytes(),
                         "notebook/package/exakit_nb/descriptor_rules.py must stay a byte-identical copy of tools/descriptor_rules.py")

    def test_no_build_output_is_tracked(self):
        done = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=False)
        if done.returncode != 0:
            self.skipTest("not a git checkout")
        bad = [f for f in done.stdout.splitlines()
               if "/build/lib" in f or f.startswith("build/") or ".egg-info" in f or "/__pycache__/" in f]
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
