"""Check shipped notebook calls, commands, metadata, and generated-file hygiene."""

from __future__ import annotations

import ast
import dataclasses
import json
import re
import subprocess
import sys
import tempfile
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
NOTEBOOKS = sorted(SOURCES.glob("**/*.py")) + sorted((ROOT / "notebook" / "marimo").glob("**/*.py"))
def helper_sources(package: Path) -> list[Path]:
    return sorted(path for path in package.glob("*/**/*.py")
                  if not any(part in ("build", "dist", "__pycache__") or part.endswith(".egg-info")
                             for part in path.relative_to(package).parts))


HELPERS = helper_sources(ROOT / "notebook" / "package") + sorted((ROOT / "notebook" / "kit").glob("*.py"))
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


GUIDE_TAGS = {"exakit-guide", "exakit-guide-hint", build_tool.CODE_START_TAG}


def _page_cells(py: Path) -> list[dict]:
    """The notebook's own page: a Data Scientist notebook opens with its guided cards and the collapsed "code behind
    this page" heading; its title, steps picture and cells follow that heading. Others have no guided cards."""
    cells = _built_cells(py)
    starts = [i for i, c in enumerate(cells) if build_tool.CODE_START_TAG in c["metadata"].get("tags", [])]
    return cells[starts[0] + 1:] if starts else cells


class CallsExistTest(unittest.TestCase):
    def test_helper_checks_ignore_temporary_wheel_build_copies(self):
        with tempfile.TemporaryDirectory() as folder:
            package = Path(folder)
            source = package / "exakit" / "__init__.py"
            copied = package / "build" / "lib" / "exakit" / "__init__.py"
            for path in (source, copied):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("")
            sources = helper_sources(package)
            copied.unlink()
            self.assertEqual([source], sources)
            for path in sources:
                self.assertEqual("", path.read_text())

    def test_every_package_call_a_notebook_makes_exists(self):
        targets = {"nb": set(dir(exakit_nb)), "exakit_nb": set(dir(exakit_nb)), "exasol_mlflow": set(dir(exasol_mlflow)),
                   "dataset": _members(Dataset), "loaded_dataset": _members(Dataset), "run": _members(exasol_mlflow.Run) | set(vars(exasol_mlflow.Run(
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
        source = ast.parse((ROOT / "marketplace" / "notebook_cli.py").read_text(encoding="utf-8"))
        options = {arg.value for node in ast.walk(source) if isinstance(node, ast.Call)
                   and isinstance(node.func, ast.Attribute) and node.func.attr == "add_argument"
                   for arg in node.args[:1] if isinstance(arg, ast.Constant) and isinstance(arg.value, str)
                   and arg.value.startswith("--")}
        for path in [*NOTEBOOKS, *HELPERS, ROOT / "notebook" / "README.md"]:
            for option in set(re.findall(r"\bexakit notebook (--[a-z-]+)", path.read_text(encoding="utf-8"))):
                with self.subTest(file=path.name, option=option):
                    self.assertIn(option, options)

    def test_no_reference_to_files_this_kit_lacks(self):
        for path in [*NOTEBOOKS, *SOURCES.glob("**/*.ipynb"), *HELPERS, ROOT / "notebook" / "README.md"]:
            text = path.read_text(encoding="utf-8")
            for gone in ("data/datasets/README.md", "docs/design.md", "start_here", "text_classification",
                         "fda_recalls"):
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
        for py in SOURCES.glob("**/*.py"):
            with self.subTest(notebook=py.relative_to(SOURCES).as_posix()):
                self.assertIn(py.relative_to(SOURCES).with_suffix("").as_posix(), named)
        for path in (ROOT / "notebook" / "marimo").glob("**/*.py"):
            with self.subTest(marimo=path.relative_to(ROOT).as_posix()):
                self.assertIn(path.relative_to(ROOT / "notebook/marimo").with_suffix("").as_posix(), named)

    def test_personas_hold_no_notebook_paths_and_the_quickstart_ships(self):
        for persona in SPRINT_NOTEBOOKS:
            with self.subTest(persona=persona):
                doc = json.loads((ROOT / "personas" / f"{persona}.json").read_text(encoding="utf-8"))
                self.assertNotIn("first_prompt", doc)
                self.assertTrue((SOURCES / persona / "00_quickstart.ipynb").is_file())



class NotebookShapeTest(unittest.TestCase):
    def test_each_data_scientist_notebook_shows_its_steps_as_a_picture(self):
        """The nine steps are drawn as a flow chart, not listed: the first cell carries it as an embedded SVG (shown in
        JupyterLab and Marimo without running anything), with this notebook's steps filled in, and the alt text
        still names them for a screen reader."""
        import base64
        import xml.etree.ElementTree as ET
        expected = {"00_quickstart": {"0", "1", "2"}, "01_explore": {"3", "4", "5", "6"},
                    "02_ask_your_data": {"7"}, "03_share": {"8", "9"}}
        for name, current in expected.items():
            with self.subTest(notebook=name):
                first = "".join(_page_cells(SOURCES / "data-scientist" / f"{name}.py")[0]["source"])
                self.assertNotIn("journey:", first, "the placeholder is replaced at build time")
                match = re.search(r"!\[([^\]]+)\]\(data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)\)", first)
                self.assertIsNotNone(match, "the strip is an embedded SVG image")
                self.assertIn("Hand off", match.group(1), "the alt text names the steps")
                svg = ET.fromstring(base64.b64decode(match.group(2)))
                ns = "{http://www.w3.org/2000/svg}"
                steps = {r.get("data-step"): r.get("data-current") for r in svg.iter(ns + "rect") if r.get("data-step")}
                self.assertEqual(current, {n for n, on in steps.items() if on == "1"})
                self.assertEqual({str(n) for n in range(1, 10)} | ({"0"} if "0" in current else set()), set(steps),
                                 "every step of the journey is drawn, step 0 only where the notebook has it")
                self.assertEqual(6 + 2 + ("0" in current), len(list(svg.iter(ns + "line"))),
                                 "arrows: six down within the three stages, one across between each stage")
                self.assertIn("This notebook", "".join(svg.itertext()))
                built = json.loads((SOURCES / "data-scientist" / f"{name}.ipynb").read_text(encoding="utf-8"))
                self.assertIn(first, ["".join(c["source"]) for c in built["cells"]], "the shipped .ipynb carries it")

    def test_the_first_cell_states_the_dataset_and_no_run_time(self):
        """The first cell says which dataset; a run-time estimate was dropped from the Data Scientist notebooks (it
        depends on the machine and the first download, and reads as a promise)."""
        for py in SOURCES.glob("*/*.py"):
            with self.subTest(notebook=py.relative_to(SOURCES).as_posix()):
                first = "".join(_page_cells(py)[0]["source"])
                self.assertIn("Dataset:", first)
                if py.parent.name in ("data-scientist", "00_shared"):
                    self.assertNotIn("How long:", first)
                    self.assertNotIn("Run time:", first)

    def test_both_quickstarts_carry_the_same_shared_cells(self):
        shared = [(c["cell_type"], c["source"]) for c in _built_cells(SOURCES / "00_shared" / "data_paths.py")[1:]]
        for persona in ("data-scientist", "ml-engineer"):
            with self.subTest(persona=persona):
                cells = [(c["cell_type"], c["source"]) for c in _built_cells(SOURCES / persona / "00_quickstart.py")
                         if c["metadata"].get("tags") and not set(c["metadata"]["tags"]) & GUIDE_TAGS]
                self.assertEqual(cells, shared)

    def test_role_review_follows_selection_and_precedes_queries(self):
        for persona in ("data-scientist", "ml-engineer"):
            cells = ["".join(c["source"]) for c in _built_cells(SOURCES / persona / "00_quickstart.py")]
            selected = next(i for i, cell in enumerate(cells) if "nb.first(source_data, own_data, sample_data)" in cell)
            review = next(i for i, cell in enumerate(cells) if "nb.review_roles(connection, chosen_data)" in cell)
            approved = next(i for i, cell in enumerate(cells) if "dataset = role_review.dataset()" in cell)
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

    def test_the_ml_notebooks_set_the_container_alias_once_and_pass_it_on(self):
        """G2 C2: one CONTAINER assignment near the top of each ML notebook, defaulting to the manifest's installed
        alias (ml_train.udf_container: PYTHON3_ML before PYTHON3); the quickstart's container check probes that
        alias and 01_train's plan creates the UDF on it, so the check's fix installs the container training uses."""
        for name, user in (("00_quickstart.py", "nb.check_container(connection, alias=CONTAINER)"),
                           ("01_train.py", "container=CONTAINER")):
            with self.subTest(notebook=name):
                cells = _built_cells(SOURCES / "ml-engineer" / name)
                code = ["".join(c["source"]) for c in cells if c["cell_type"] == "code"]
                assigned = [i for i, s in enumerate(code) if re.search(r"^CONTAINER = ", s, flags=re.M)]
                self.assertEqual(len(assigned), 1, "one CONTAINER assignment")
                self.assertLessEqual(assigned[0], 1, "near the top: the first or second code cell")
                self.assertIn("CONTAINER = nb.ml_train.udf_container()", code[assigned[0]])
                used = [i for i, s in enumerate(code) if user in s]
                self.assertEqual(len(used), 1, f"{user} in one cell")
                self.assertLess(assigned[0], used[0])
                text = "".join(code)
                self.assertNotIn("nb.check_container(connection)", text, "the check never falls back to a default alias here")
                self.assertNotIn('"PYTHON3")', text.replace('"PYTHON3_ML"', ""), "no alias is hard-wired")
                markdown = "".join("".join(c["source"]) for c in cells if c["cell_type"] == "markdown")
                for needle in ("`PYTHON3_ML`", "`exakit udf-use default`", "`PYTHON3`", "`exakit udf-setup`", "`EXAKIT_UDF_CONTAINER`"):
                    self.assertIn(needle, markdown, "the markdown names both aliases, their installers and the override")

    def test_the_ml_quickstarts_first_query_guards_its_roles(self):
        """AC-DS5.3 in the ML quickstart (T8b leftover): the first query falls back to the entity and leaves the label
        count out, printing the reason, instead of raising on a missing category or label role."""
        code = ["".join(c["source"]) for c in _built_cells(SOURCES / "ml-engineer" / "00_quickstart.py") if c["cell_type"] == "code"]
        cell = next(s for s in code if "first_rows = nb.sql(" in s)
        self.assertIn('GROUP_COLUMN = dataset.col("category") if dataset.has("category") else dataset.col("entity")', cell)
        self.assertIn("if dataset.has(\"label\") else None", cell)
        self.assertIn('ROUND(100 * AVG({dataset.col(\'label\')}), 1) AS {LABEL_PCT_HEADER}', cell)
        self.assertIn("nb.note_groups(first_rows, dataset, GROUP_HEADER, COUNT_HEADER, LABEL_PCT_HEADER", cell, "the result carries its plain-language note")
        self.assertIn("dataset.missing", cell)
        self.assertIn("missing_roles[role]", cell)
        self.assertNotIn('SUM({dataset.col("label")})', cell, "no unguarded label column")
        self.assertNotIn('GROUP BY {dataset.col("category")}', cell, "no unguarded category column")

    def test_the_quickstart_has_one_cell_per_way_data_comes_in(self):
        sources = ["".join(c["source"]) for c in _built_cells(SOURCES / "data-scientist" / "00_quickstart.py")]
        for loader in ("nb.load_sample(", "nb.load_own_file(", "nb.load_source("):
            with self.subTest(loader=loader):
                self.assertEqual(sum(loader in s for s in sources), 1)
        self.assertIn("01_explore", sources[-1])

    def test_each_persona_stands_alone(self):
        """A persona's notebooks never need, name or write for another persona's: the Data Scientist writes no
        training handoff, the ML Engineer writes its own (01_train). The Explore markdown names Langfuse's SDK 5
        variable (LANGFUSE_BASE_URL) with LANGFUSE_HOST only as its alias."""
        for persona, other in (("data-scientist", "ml-engineer"), ("ml-engineer", "data-scientist")):
            for py in sorted((SOURCES / persona).glob("*.py")):
                with self.subTest(notebook=f"{persona}/{py.name}"):
                    text = py.read_text(encoding="utf-8")
                    self.assertNotIn(other, text)
                    if persona == "ml-engineer":
                        self.assertNotIn("01_explore", text)
        explore = (SOURCES / "data-scientist" / "01_explore.py").read_text(encoding="utf-8")
        self.assertNotIn("write_handoff", explore)
        self.assertIn("nb.ml_train.training_handoff(connection, dataset", (SOURCES / "ml-engineer" / "01_train.py").read_text(encoding="utf-8"))
        text = explore
        self.assertIn("`LANGFUSE_BASE_URL`", text)
        for match in re.finditer("LANGFUSE_HOST", text):
            self.assertIn("alias", text[match.end():match.end() + 80], "LANGFUSE_HOST is named only as the alias of LANGFUSE_BASE_URL")
        summary = next(e["summary"] for e in CatalogTest.DOC["notebooks"] if e["id"] == "explore")
        self.assertNotIn("handoff", summary)     # explore writes none (f70a957); 01_train writes its own

    def test_explore_skips_what_a_missing_role_needs_and_says_why(self):
        """AC-DS5.3 / design 2.4: a role no column fits does not stop explore. The roles cell takes the date and label
        through dataset.has() and prints the descriptor's reason (dataset.missing) with the steps it skips; the landscape, the
        over-time step and the small model are each wrapped in a dataset.has() guard that prints that reason, with the SQL
        text inside untouched (AC-DS3.2 is held by SwapTest); the text step runs on the text roles alone, its label
        column and ordering coming from dataset.has() fragments; the handoff is left to its own refusal."""
        cells = ["".join(c["source"]) for c in _built_cells(SOURCES / "data-scientist" / "01_explore.py")
                 if c["cell_type"] == "code"]
        roles = next(c for c in cells if 'dataset.col("date") if dataset.has("date") else None' in c)
        for needle in ('dataset.col("date") if dataset.has("date") else None', 'dataset.col("label") if dataset.has("label") else None',
                       "for missing in dataset.missing", "skip below"):
            self.assertIn(needle, roles)
        self.assertNotIn('dataset.col("date"),', roles, "the date and label are no longer read unguarded")
        guarded = {"landscape = nb.sql(": 'if not all(dataset.has(role) for role in ("entity", "category", "label")):',
                   "over_time = nb.sql(": 'if not (dataset.has("date") and dataset.has("label")):',
                   # The small model needs no text and no date: the category or the entity (one that does not give
                   # the label away), and the month only when there is a date.
                   "model_rows = nb.sql(": 'if not (dataset.has("label") and (USE_CATEGORY or USE_ENTITY)):'}
        for sql, guard in guarded.items():
            with self.subTest(cell=sql):
                cell = next(c for c in cells if sql in c)
                self.assertIn(guard, cell)
                self.assertLess(cell.index(guard), cell.index(sql), "the guard comes first and wraps the SQL")
                self.assertIn("missing_line", cell[cell.index(guard):cell.index(sql)], "the skip line carries the reason")
        words = next(c for c in cells if "get_feature_names_out" in c)
        self.assertIn("if model is not None:", words)
        text_step = next(c for c in cells if "SAMPLE_SQL = " in c)
        self.assertIn('if not dataset.has("text"):', text_step)
        self.assertNotIn('if not dataset.has("date")', text_step)
        self.assertNotIn('if not dataset.has("label")', text_step)
        self.assertIn('if dataset.has("label") else ""', text_step)
        self.assertIn('if dataset.has("date") else dataset.col("entity") if dataset.has("entity") else "1"', text_step)
        for role in ("date", "label"):
            self.assertNotIn("{" + role.upper() + "}", text_step, f"the {role} is in the text SQL only when it exists")

    def test_what_a_reader_sets_is_in_the_cell_that_sets_the_dataset(self):
        """Pasting a workflow id into a later cell and running only that cell failed on DATASET: every value a reader
        edits sits in the one cell that assigns DATASET."""
        for py in sorted(SOURCES.glob("*/*.py")):
            code = ["".join(c["source"]) for c in _built_cells(py) if c["cell_type"] == "code"]
            settings = [c for c in code if re.search(r"^DATASET = ", c, re.M)]
            if not settings:
                continue
            with self.subTest(notebook=py.relative_to(SOURCES).as_posix()):
                for name in ("WORKFLOW_ID", "USE_AI_THEMES", "DRAFT_WITH_MODEL"):
                    assigned = [c for c in code if re.search(rf"^{name} = ", c, re.M)]
                    for cell in assigned:
                        self.assertIn(cell, settings, f"{name} is set outside the DATASET cell")

    def test_no_dataset_is_named_in_the_code(self):
        for py in SOURCES.glob("*/*.py"):
            text = py.read_text(encoding="utf-8")
            code = "\n".join(line for line in text.splitlines() if not line.startswith(("#", "DATASET = ", "SAMPLE = ")))
            # The persona datasets' schemas, tables and slot columns (inline comments may name the result columns the
            # descriptor yields, such as ORDER_LINES or CANCELLED_PCT, so those two are not listed).
            for name in ("PHARMA", "TERMINATED", "MONETARY_RELIEF", "BRIEF_SUMMARY", "LEAD_SPONSOR", "COMPANY",
                         "AMAZON", "FRAUD", "FRAUDULENT", "SHIP_STATE", "TRANSACTION_TYPE",
                         "ORDER_DATE", "ORDER_LINE_ID", "SALES_ID"):
                with self.subTest(notebook=py.name, name=name):
                    self.assertNotIn(name, code, "the SQL comes from the descriptor's roles")

    def test_no_shipped_file_holds_a_connection_value(self):
        """AC-DS1.2 / AC-DS4.3: no notebook, kernel helper or helper output template holds a host, user or password."""
        # notebook/docs is the documentation site: its build project (a dependency lock file, node_modules on a
        # maintainer's machine) and the built site. Its pages are checked by tests/test_notebook_docs.py.
        files = [p for p in (ROOT / "notebook").rglob("*") if p.is_file() and p.suffix in (".py", ".ipynb", ".json", ".md")
                 and p.relative_to(ROOT / "notebook").parts[0] != "docs"]
        for path in files:
            text = path.read_text(encoding="utf-8")
            if path == ROOT / "notebook/package/exakit_nb/docs.py":
                # nb.docs() serves the documentation on the loopback address only: the address it binds and shows is
                # a rule about who can reach it, not a connection value. Exactly that one line is exempt.
                text = text.replace('BIND, SHOWN = "127.0.0.1", "localhost"   # served on the loopback address only: no other computer reaches it', "")
            if path in (ROOT / "notebook/MODEL-PROVIDERS.md", ROOT / "notebook/package/exakit_nb/providers.py"):
                # These exact model-server examples are public defaults, not database
                # connection values (the provider list offers them for a server on this computer).
                # Keep all other hosts and every credential check.
                for endpoint in ("http://localhost:11434/v1/", "http://localhost:1234/v1/",
                                 "http://localhost:8000/v1/"):
                    text = text.replace(endpoint, "<documented-model-endpoint>")
            if path == ROOT / "notebook/package/exakit_nb/model_config.py":
                # The clear-text check (audit SEC-08) names the loopback host to ALLOW plain http there;
                # it is a rule about hosts, not a connection value. Exactly that one line is exempt.
                text = text.replace('if host == "localhost" or host.endswith((".localhost", ".local", ".internal")):', "")
            if path == ROOT / "notebook/package/exakit_nb/sources.py":
                # connect_source names the loopback hosts to REPLACE them (a Mac's database reaches this computer
                # at 192.168.64.1) and the query parameter to TAKE a password out of a pasted URL: rules, not values.
                text = text.replace('LOOPBACK = ("localhost", "127.0.0.1", "::1", "0.0.0.0")', "")
                text = text.replace('_PASSWORD_PARAM = re.compile(r"(?:^|[&;])password=([^&;]*)", re.I)', "")
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
        self.assertIn('packages = ["exakit_nb", "exakit", "exakit.nb", "exakit_guide", "exakit_guide.screens", "exakit.guide"]', text)

    def test_no_build_output_is_tracked(self):
        done = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=False)
        if done.returncode != 0:
            self.skipTest("not a git checkout")
        bad = [f for f in done.stdout.splitlines()
               if "/build/lib" in f or f.startswith("build/") or ".egg-info" in f or "/__pycache__/" in f]
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
