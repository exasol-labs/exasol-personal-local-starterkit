"""(run: python3 tests/test_notebook_contents.py) What the notebook add-on ships, held to what exists: every call a shipped
notebook makes into exakit.nb or exasol_mlflow (and on the Dataset and the MLflow run they return) is one the packages
define, every `exakit <command>` a notebook or helper tells the user to run is a command of this kit, the descriptor
rules shipped with exakit.nb are byte-identical to tools/descriptor_rules.py, every notebook has its .py source, the
catalog is the requirements' notebook catalogue (Appendix B) and nothing more, each notebook's first cell states its
dataset and run time, both quickstarts carry the same shared cells, no shipped file holds a connection value (AC-DS1.2),
and no build output or egg-info is tracked."""

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
import importlib.util  # noqa: E402

import exakit_nb  # noqa: E402
import exasol_mlflow  # noqa: E402
from exakit_nb.dataset import Dataset  # noqa: E402

# tools/notebooks.py, under a name of its own (notebook/kit/notebooks.py is "notebooks" in another suite)
_spec = importlib.util.spec_from_file_location("kit_build_notebooks", ROOT / "tools" / "notebooks.py")
build_tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(build_tool)

SOURCES = ROOT / "notebook" / "notebooks"
NOTEBOOKS = sorted(SOURCES.glob("*/*.py")) + sorted((ROOT / "notebook" / "marimo").glob("*/*.py"))
HELPERS = sorted((ROOT / "notebook" / "package").glob("*/**/*.py")) + sorted((ROOT / "notebook" / "kit").glob("*.py"))
# Commands other work items add to this kit in parallel: `exakit model put|list` (ML-4) is named by the ML Engineer's
# checks before its dispatch arm lands.
PENDING_COMMANDS = {"model"}
SPRINT_NOTEBOOKS = {"data-scientist": ["00_quickstart.ipynb", "01_explore.ipynb", "02_ask_your_data.ipynb", "03_share.ipynb"],
                    "ml-engineer": ["00_quickstart.ipynb", "01_train.ipynb", "02_rust_score.ipynb", "03_score_external_model.ipynb"]}


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


def _built_cells(py: Path) -> list[dict]:
    return json.loads(build_tool.build(py))["cells"]


class CallsExistTest(unittest.TestCase):
    def test_every_package_call_a_notebook_makes_exists(self):
        targets = {"nb": set(dir(exakit_nb)), "exakit_nb": set(dir(exakit_nb)), "exasol_mlflow": set(dir(exasol_mlflow)),
                   "ds": _members(Dataset), "run": _members(exasol_mlflow.Run) | set(vars(exasol_mlflow.Run(
                       None, None, experiment="e", run_name=None, params=None, tags=None, tracking_dir=None)))}
        for path in NOTEBOOKS:
            for name, known in targets.items():
                with self.subTest(notebook=path.relative_to(ROOT).as_posix(), on=name):
                    self.assertEqual(sorted(_uses(path, name) - known), [], f"{path.name} calls what {name} does not have")

    def test_the_notebooks_use_exakit_nb_by_its_new_name(self):
        for path in SOURCES.glob("*/*.py"):
            with self.subTest(notebook=path.relative_to(SOURCES).as_posix()):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("import exakit_nb", text)
                if "nb." in text and "[include]" not in text:
                    self.assertIn("import exakit.nb as nb", text)

    def test_every_ipynb_has_its_source(self):
        for ipynb in SOURCES.glob("**/*.ipynb"):
            with self.subTest(notebook=ipynb.name):
                self.assertTrue(ipynb.with_suffix(".py").is_file(), f"{ipynb.name} has no .py source for tools/notebooks.py --check")

    def test_every_exakit_command_they_name_is_a_command(self):
        commands = _commands() | PENDING_COMMANDS
        self.assertIn("notebook", commands)
        for path in [*NOTEBOOKS, *SOURCES.glob("**/*.ipynb"), *HELPERS,
                     ROOT / "notebook" / "README.md", ROOT / "packages" / "exasol-mlflow" / "README.md"]:
            for command in set(re.findall(r"\bexakit ([a-z][a-z-]+)", path.read_text(encoding="utf-8"))) - {"import"}:
                with self.subTest(file=path.name, command=command):
                    self.assertIn(command, commands)

    def test_every_notebook_option_they_name_exists(self):
        source = (ROOT / "setup" / "lib" / "notebook.sh").read_text(encoding="utf-8")
        for path in [*NOTEBOOKS, *HELPERS, ROOT / "notebook" / "README.md"]:
            for option in set(re.findall(r"\bexakit notebook (--[a-z-]+)", path.read_text(encoding="utf-8"))):
                with self.subTest(file=path.name, option=option):
                    self.assertRegex(source, rf"\n\s+([a-z|-]*\|)?{re.escape(option)}(\|[a-z-]*)*\)")

    def test_no_reference_to_files_this_kit_lacks(self):
        for path in [*NOTEBOOKS, *SOURCES.glob("**/*.ipynb"), *HELPERS, ROOT / "notebook" / "README.md"]:
            text = path.read_text(encoding="utf-8")
            for gone in ("data/datasets/README.md", "docs/design.md", "start_here", "text_classification",
                         "bank_marketing", "fda_recalls"):
                with self.subTest(file=path.name, reference=gone):
                    self.assertNotIn(gone, text)


class CatalogTest(unittest.TestCase):
    DOC = json.loads((ROOT / "notebook" / "catalog.json").read_text(encoding="utf-8"))

    def test_the_catalog_is_the_sprint_notebooks_and_the_shared_cells(self):
        found: dict[str, list[str]] = {}
        for entry in self.DOC["notebooks"]:
            found.setdefault(entry["persona"], []).append(entry["jupyter"])
        self.assertEqual(found, SPRINT_NOTEBOOKS)
        self.assertEqual(self.DOC["shared"]["folder"], "00_shared")
        steps = {(e["persona"], e["step"]) for e in self.DOC["notebooks"]}
        self.assertEqual(len(steps), len(self.DOC["notebooks"]), "one step per notebook within a persona")
        for entry in self.DOC["notebooks"]:
            with self.subTest(entry=entry["id"]):
                self.assertTrue(entry["jupyter"].startswith(f"{int(entry['step']):02d}_"), "the file's number is its step")
                self.assertEqual(Path(entry["jupyter"]).stem, Path(entry["marimo"]).stem)

    def test_the_catalog_names_files_that_exist(self):
        """Each entry's files are there - except an entry whose .py is not in the tree yet (built when it lands)."""
        pending = set(build_tool.pending())
        self.assertLessEqual(pending, {"ml-engineer/03_score_external_model.py"}, "only the ML-4 notebook may be pending")
        for folder, jupyter, marimo in build_tool.catalog_files():
            if f"{folder}/{Path(jupyter).stem}.py" in pending:
                continue
            for front, name in (("jupyter", jupyter), ("marimo", marimo)):
                with self.subTest(entry=f"{folder}/{name}", front=front):
                    self.assertTrue((ROOT / self.DOC["sources"][front] / folder / name).is_file())

    def test_no_notebook_ships_that_the_catalog_does_not_name(self):
        named = {f"{folder}/{Path(jupyter).stem}" for folder, jupyter, _ in build_tool.catalog_files()}
        for py in SOURCES.glob("*/*.py"):
            with self.subTest(notebook=py.relative_to(SOURCES).as_posix()):
                self.assertIn(f"{py.parent.name}/{py.stem}", named)
        for path in (ROOT / "notebook" / "marimo").glob("**/*.py"):
            with self.subTest(marimo=path.relative_to(ROOT).as_posix()):
                self.assertIn(f"{path.parent.name}/{path.stem}", named)

    def test_the_personas_first_prompts_open_a_quickstart_that_ships(self):
        for persona in SPRINT_NOTEBOOKS:
            with self.subTest(persona=persona):
                prompt = json.loads((ROOT / "personas" / f"{persona}.json").read_text(encoding="utf-8"))["first_prompt"]
                self.assertIn(f"{persona}/00_quickstart.ipynb", prompt)
                self.assertTrue((SOURCES / persona / "00_quickstart.ipynb").is_file())


class NotebookShapeTest(unittest.TestCase):
    def test_the_first_cell_states_the_dataset_and_the_run_time(self):
        for py in SOURCES.glob("*/*.py"):
            with self.subTest(notebook=py.relative_to(SOURCES).as_posix()):
                first = "".join(_built_cells(py)[0]["source"])
                self.assertIn("Dataset:", first)
                self.assertTrue("How long:" in first or "Run time:" in first, first)

    def test_both_quickstarts_carry_the_same_shared_cells(self):
        shared = [(c["cell_type"], c["source"]) for c in _built_cells(SOURCES / "00_shared" / "data_paths.py")[1:]]
        for persona in ("data-scientist", "ml-engineer"):
            with self.subTest(persona=persona):
                cells = [(c["cell_type"], c["source"]) for c in _built_cells(SOURCES / persona / "00_quickstart.py")
                         if c["metadata"].get("tags")]
                self.assertEqual(cells, shared)

    def test_role_review_follows_selection_and_precedes_queries(self):
        for persona in ("data-scientist", "ml-engineer"):
            cells = ["".join(c["source"]) for c in _built_cells(SOURCES / persona / "00_quickstart.py")]
            selected = next(i for i, cell in enumerate(cells) if "nb.first(source, own, sample)" in cell)
            review = next(i for i, cell in enumerate(cells) if "nb.review_roles(conn, ds)" in cell)
            approved = next(i for i, cell in enumerate(cells) if "ds = review.dataset()" in cell)
            query = next(i for i, cell in enumerate(cells) if "first_rows = nb.sql(" in cell)
            self.assertLess(selected, review)
            self.assertLess(review, approved)
            self.assertLess(approved, query)

    def test_the_ml_quickstart_checks_before_it_loads(self):
        sources = ["".join(c["source"]) for c in _built_cells(SOURCES / "ml-engineer" / "00_quickstart.py")]
        order = [next(i for i, s in enumerate(sources) if needle in s)
                 for needle in ("nb.connect()", "nb.check_container", "nb.check_mlflow", "nb.check_bucket", "nb.load_sample")]
        self.assertEqual(order, sorted(order))
        for check in ("nb.check_container", "nb.check_mlflow", "nb.check_bucket"):
            self.assertEqual(sum(check in s for s in sources), 1, f"{check} in one cell of its own")

    def test_the_quickstart_has_one_cell_per_way_data_comes_in(self):
        sources = ["".join(c["source"]) for c in _built_cells(SOURCES / "data-scientist" / "00_quickstart.py")]
        for loader in ("nb.load_sample(", "nb.load_own_file(", "nb.load_source("):
            with self.subTest(loader=loader):
                self.assertEqual(sum(loader in s for s in sources), 1)
        self.assertIn("01_explore", sources[-1])

    def test_explore_ends_by_writing_the_handoff(self):
        """AC-DS3.4: explore's last cell writes the handoff for the ML Engineer and reads it back to say what it holds;
        the markdown names Langfuse's SDK 5 variable (LANGFUSE_BASE_URL) with LANGFUSE_HOST only as its alias."""
        cells = _built_cells(SOURCES / "data-scientist" / "01_explore.py")
        last = "".join(cells[-1]["source"])
        self.assertEqual(cells[-1]["cell_type"], "code")
        self.assertIn("nb.write_handoff(conn, ds)", last)
        self.assertIn("nb.read_handoff(", last)
        self.assertIn("01_train", last)
        self.assertEqual(sum("nb.write_handoff(" in "".join(c["source"]) for c in cells
                             if c["cell_type"] == "code"), 1, "written once, at the end")
        self.assertIn("Hand off to the ML Engineer", "".join(cells[-2]["source"]))
        text = (SOURCES / "data-scientist" / "01_explore.py").read_text(encoding="utf-8")
        self.assertIn("`LANGFUSE_BASE_URL`", text)
        for match in re.finditer("LANGFUSE_HOST", text):
            self.assertIn("alias", text[match.end():match.end() + 80], "LANGFUSE_HOST is named only as the alias of LANGFUSE_BASE_URL")
        summary = next(e["summary"] for e in CatalogTest.DOC["notebooks"] if e["id"] == "explore")
        self.assertIn("handoff", summary)

    def test_no_dataset_is_named_in_the_code(self):
        for py in SOURCES.glob("*/*.py"):
            text = py.read_text(encoding="utf-8")
            code = "\n".join(line for line in text.splitlines() if not line.startswith(("#", "DATASET = ", "SAMPLE = ")))
            for name in ("PHARMA", "BANKING", "TERMINATED", "MONETARY_RELIEF", "BRIEF_SUMMARY", "LEAD_SPONSOR", "COMPANY"):
                with self.subTest(notebook=py.name, name=name):
                    self.assertNotIn(name, code, "the SQL comes from the descriptor's roles")

    def test_no_shipped_file_holds_a_connection_value(self):
        """AC-DS1.2 / AC-DS4.3: no notebook, kernel helper or helper output template holds a host, user or password."""
        files = [p for p in (ROOT / "notebook").rglob("*") if p.is_file() and p.suffix in (".py", ".ipynb", ".json", ".md")]
        for path in files:
            text = path.read_text(encoding="utf-8")
            for needle in ("127.0.0.1", "localhost", ":8563", "password=", "dsn=", "LANGFUSE_SECRET_KEY=", "sk-"):
                with self.subTest(file=path.relative_to(ROOT).as_posix(), needle=needle):
                    self.assertNotIn(needle, text)


class GuardTest(unittest.TestCase):
    def test_the_descriptor_rules_are_one_file_in_two_places(self):
        self.assertEqual((ROOT / "notebook" / "package" / "exakit_nb" / "descriptor_rules.py").read_bytes(),
                         (ROOT / "tools" / "descriptor_rules.py").read_bytes(),
                         "notebook/package/exakit_nb/descriptor_rules.py must stay a byte-identical copy of tools/descriptor_rules.py")

    def test_the_package_ships_both_names(self):
        text = (ROOT / "notebook" / "package" / "pyproject.toml").read_text(encoding="utf-8")
        self.assertIn('packages = ["exakit_nb", "exakit", "exakit.nb"]', text)

    def test_no_build_output_is_tracked(self):
        done = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=False)
        if done.returncode != 0:
            self.skipTest("not a git checkout")
        bad = [f for f in done.stdout.splitlines()
               if "/build/lib" in f or f.startswith("build/") or ".egg-info" in f or "/__pycache__/" in f]
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
