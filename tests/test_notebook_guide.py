"""The guided view: cards that do each notebook's steps, the Guided / Code switch over its code cells, and the rule
that ties them together - every card action is one exact exakit.nb call, shown as code, run as that code, and present
as a cell in the notebook's code section; every fact a card shows is read from the kit live.

The structure is checked everywhere; the cards themselves where anywidget is installed (the kit's notebook
environment), with the kit faked - no database.
"""

from __future__ import annotations

import ast
import importlib
import inspect
import time
import re
import importlib.util
import json
import types
import os
import stat
import string
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "notebook" / "package"
GUIDE = PACKAGE / "exakit_guide"
SOURCES = ROOT / "notebook" / "notebooks"
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(PACKAGE))

import notebooks as build_tool  # noqa: E402

HAVE_ANYWIDGET = importlib.util.find_spec("anywidget") is not None
HAVE_SKLEARN = importlib.util.find_spec("sklearn") is not None and importlib.util.find_spec("numpy") is not None

CARDS = {"00_quickstart": "guide.start()", "01_explore": "guide.explore()", "02_ask_your_data": "guide.ask()",
         "03_share": "guide.share()"}


def _actions():
    """exakit_guide.actions without importing the guide package (which needs anywidget)."""
    spec = importlib.util.spec_from_file_location("guide_actions", GUIDE / "actions.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["guide_actions"] = module
    spec.loader.exec_module(module)
    return module


def _cells(name: str) -> list[dict]:
    return json.loads(build_tool.build(SOURCES / "data-scientist" / f"{name}.py"))["cells"]


def _code_section(name: str) -> str:
    cells = _cells(name)
    start = next(i for i, c in enumerate(cells) if build_tool.CODE_START_TAG in c["metadata"].get("tags", []))
    return "\n\n".join("".join(c["source"]) for c in cells[start + 1:] if c["cell_type"] == "code")


def _called(source: str) -> set[str]:
    """Every function or method name a piece of code calls (nb.load_sample -> load_sample, role_review.approve -> approve)."""
    out = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Call):
            out.add(node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", ""))
    return out


def _sample_values(action) -> dict:
    fields = {n for _, n, _, _ in string.Formatter().parse(action.code) if n}
    return {f: "X" for f in fields if f not in ("secret", "settings")}


def _flat(fields: list[dict]) -> list[dict]:
    """A form's fields with the ones inside its groups (fields shown side by side) after each group."""
    out = []
    for f in fields:
        out.append(f)
        out += _flat(f.get("fields") or []) if f.get("type") == "group" else []
    return out


class LayoutTest(unittest.TestCase):
    def test_each_notebook_opens_with_its_card_then_its_code_under_one_heading(self):
        for name, call in CARDS.items():
            with self.subTest(notebook=name):
                cells = _cells(name)
                tags = [c["metadata"].get("tags", []) for c in cells]
                self.assertEqual(["exakit-guide-hint"], tags[0])
                self.assertIn("exakit-guide", tags[1])
                self.assertIn("skip-ci", tags[1], "a headless run (tools/notebooks.py --run) never draws a card")
                self.assertIn(call, "".join(cells[1]["source"]))
                self.assertIn(build_tool.CODE_START_TAG, cells[2]["metadata"]["tags"])
                self.assertIn('class="guide-code-start"', "".join(cells[2]["source"]))

    def test_the_code_heading_is_the_only_top_level_heading(self):
        for name in CARDS:
            with self.subTest(notebook=name):
                tops = ["".join(c["source"]).split("\n")[0] for c in _cells(name)
                        if c["cell_type"] == "markdown" and "".join(c["source"]).startswith("# ")]
                self.assertEqual(["# The code behind this page"], tops)

    def test_other_notebooks_have_no_cards(self):
        for py in [*SOURCES.glob("ml-engineer/*.py"), SOURCES / "00_shared" / "data_paths.py"]:
            with self.subTest(notebook=py.name):
                self.assertNotIn("exakit.guide", py.read_text(encoding="utf-8"))


class ParityTest(unittest.TestCase):
    """UI or code, the same call: every card action's code is in its notebook, and calls what the kit has."""

    def setUp(self):
        self.actions = _actions()

    def test_every_action_is_a_cell_of_its_notebook(self):
        sections = {name: _called(_code_section(name)) for name in CARDS}
        for action_id, action in self.actions.ACTIONS.items():
            with self.subTest(action=action_id):
                self.assertIn(action.notebook, sections)
                needed = _called(self.actions.code(action_id, **_sample_values(action)))
                self.assertEqual(set(), needed - sections[action.notebook],
                                 f"{action_id}: no cell of {action.notebook} makes this call")

    def test_every_nb_call_is_one_the_kit_has(self):
        import exakit_nb

        known = set(dir(exakit_nb))
        for action_id, action in self.actions.ACTIONS.items():
            text = self.actions.code(action_id, **_sample_values(action))
            for node in ast.walk(ast.parse(text)):
                if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "nb":
                    with self.subTest(action=action_id, call=node.attr):
                        self.assertIn(node.attr, known)

    def test_a_secret_is_never_in_the_code_shown(self):
        code = self.actions.code("data.connect_source", connector="postgresql", name="sales",
                                 settings={"url": "postgres://reader@db.example.com/shop"},
                                 secret={"secret": lambda _q: "s3cret"})
        self.assertNotIn("s3cret", code)
        self.assertNotIn("__secret__", code)
        self.assertEqual('connected = nb.connect_source("postgresql", "sales", url="postgres://reader@db.example.com/shop")', code)


class SourceFormTest(unittest.TestCase):
    """The external source's form is the kit's own: every connector's inputs from its connector.json."""

    def test_every_connector_has_its_inputs(self):
        nb = importlib.import_module("exakit_nb")
        for connector in nb.connectors():
            form = nb.connector_inputs(connector["id"])
            self.assertEqual(connector["id"], form["id"])
            self.assertTrue(form["inputs"] or form["setting_inputs"], connector["id"])   # or its settings come first
            for spec in form["inputs"]:
                self.assertTrue(spec["label"] and spec["kind"], (connector["id"], spec))
        self.assertEqual("postgresql", nb.connector_inputs("pg")["id"])           # an alias, as exakit connect takes
        self.assertEqual("secret-file", next(i["kind"] for i in nb.connector_inputs("bigquery")["inputs"] if i["file"]
                                             and i["secret"]))

    def test_a_connector_with_settings_gives_its_tree_and_each_combinations_inputs(self):
        """A connector that is several kinds of source in one (Lakehouse) is read from the kit like any other: its
        settings as the connect menu's tree, and for each pick that combination's inputs - none of it typed here."""
        nb = importlib.import_module("exakit_nb")
        found = [c for c in nb.connectors() if nb.connector_inputs(c["id"])["tree"]]
        self.assertTrue(found, "no connector has settings any more: drop this test with them")
        for connector in found:
            form = nb.connector_inputs(connector["id"])
            self.assertEqual([], form["inputs"])                      # nothing to ask before the first setting
            self.assertEqual(1, len(form["setting_inputs"]))
            for node in form["tree"]:
                for pick in [node] + node["children"]:
                    with self.subTest(connector=connector["id"], pick=pick["set"]):
                        chosen = nb.connector_inputs(connector["id"], **pick["set"])
                        self.assertTrue(chosen["inputs"])
                        self.assertEqual(pick["set"], {k: chosen["settings"][k] for k in pick["set"]})
                        self.assertTrue(all(spec["choices"] and spec["default"] for spec in chosen["setting_inputs"]))
        for connector in nb.connectors():
            if connector not in found:
                self.assertEqual([], nb.connector_inputs(connector["id"])["setting_inputs"])

    def test_the_form_is_the_kits_own_engine_not_a_copy(self):
        """Listing, inputs and the connection-string reader are asked of setup/virtual-schemas/engine/cli.py - what
        `exakit connect` itself runs - so the notebook cannot drift from the terminal."""
        nb = importlib.import_module("exakit_nb")
        engine = nb.source_engine("inputs", "postgresql")
        form = nb.connector_inputs("postgresql")
        self.assertEqual([f["name"] for f in engine["inputs"] if f["kind"] != "source-name"], [i["name"] for i in form["inputs"]])
        self.assertEqual("Name (alias) for this connection", form["name_input"]["label"])
        self.assertEqual([c["id"] for c in nb.source_engine("catalog")["connectors"]], [c["id"] for c in nb.connectors()])
        self.assertTrue(all(c["version"] for c in nb.connectors()))                       # the adapter the kit pins
        source = (PACKAGE / "exakit_nb" / "sources.py").read_text(encoding="utf-8")
        self.assertNotIn('import_module("paste")', source)                                # no second reader
        reading = nb.read_connection_string("mongodb", "mongodb+srv://u:p4ss@cluster0.x.mongodb.net/shop")
        self.assertEqual({"uri": "mongodb+srv://cluster0.x.mongodb.net", "database": "shop", "user": "u"}, reading["values"])
        self.assertNotIn("p4ss", json.dumps(reading))
        with self.assertRaisesRegex(nb.SourceProblem, "does not read this as a PostgreSQL connection string"):
            nb.read_connection_string("pg", "http://x")

    def test_a_test_checks_the_inputs_then_the_network_and_sends_no_password(self):
        sources = importlib.import_module("exakit_nb.sources")
        with mock.patch.object(sources, "connect_source") as plan, \
             mock.patch.object(sources.socket, "create_connection", side_effect=OSError(61, "Connection refused")):
            result = sources.test_source("postgresql", "sales", host="db.example.com", database="shop", user="reader")
        self.assertTrue(plan.call_args.kwargs["dry_run"])                 # the kit's own check, nothing connected
        self.assertNotIn("password", plan.call_args.kwargs)
        self.assertFalse(result.ok)
        self.assertEqual("this computer reaches db.example.com:5432", result.checks[1][0])    # the connector's own port
        with mock.patch.object(sources, "connect_source", side_effect=sources.SourceProblem("sales was not connected: "
                                                                                              "host is not a host name")):
            result = sources.test_source("postgresql", "sales", host="bad host")
        self.assertEqual([("the kit's check of the inputs", False, "host is not a host name")], result.checks)


class RunIsTheCodeTest(unittest.TestCase):
    """actions.run executes the very text actions.code shows - nothing else."""

    def test_run_executes_the_shown_code_in_the_notebook_namespace(self):
        actions = _actions()
        calls = []

        class FakeNb:
            def __getattr__(self, name):
                return lambda *args, **kwargs: calls.append((name, args, kwargs))

        text = actions._render("kit.addon", {"addon": "dash-server"}, for_run=True)
        self.assertEqual(actions.code("kit.addon", addon="dash-server"), text)
        exec(compile(text, "<run>", "exec"), {"nb": FakeNb()})
        self.assertEqual([("addon_ready", ("dash-server",), {})], calls)

    def test_secret_is_passed_only_at_run(self):
        actions = _actions()
        run_text = actions._render("model.use", {"model_id": "m", "base_url": "u", "secret": {"ask": print}}, for_run=True)
        shown = actions.code("model.use", model_id="m", base_url="u", secret={"ask": print})
        self.assertEqual('nb.use_model("m", "u", remember=True, **__secret__)', run_text)
        self.assertEqual('nb.use_model("m", "u", remember=True)', shown)


class NoHardcodedFactsTest(unittest.TestCase):
    """The guided view names no kit part: datasets, connectors, add-ons, AI clients and notebook files come live."""

    def test_no_kit_id_is_written_into_the_guided_view(self):
        ids = {p.name for p in (ROOT / "data" / "datasets").iterdir() if p.is_dir()}
        ids |= {c["id"] for c in json.loads((ROOT / "setup/virtual-schemas/catalog.json").read_text())["connectors"]}
        ids |= {a["id"] for a in json.loads((ROOT / "marketplace/catalog.json").read_text())["addons"]}
        catalog = json.loads((ROOT / "notebook/catalog.json").read_text())
        ids |= {n["jupyter"] for n in catalog["notebooks"]}
        from exakit_nb.kit_facts import _client_names

        ids |= set(_client_names())
        # share.server is the kit's own call in 03_share, `nb.addon_ready("dash-server")`; "notebook" is also Jupyter's
        # content type, which the save hook checks.
        allowed = {"dash-server", "notebook"}
        for path in GUIDE.rglob("*.py"):
            for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    for word in ids - allowed:
                        with self.subTest(file=path.name, id=word):
                            self.assertNotEqual(word, node.value.strip(), f"{path.name} names {word}: read it from the kit")

    def test_screens_change_nothing_except_through_actions(self):
        for path in (GUIDE / "screens").glob("*.py"):
            text = path.read_text(encoding="utf-8")
            with self.subTest(file=path.name):
                for needle in (".execute(", "kit_json(", "pyexasol.connect(", "CERT_NONE", "nb.sql(", "nb.connect(",
                               "_run_kit(", "nb.exakit("):
                    self.assertNotIn(needle, text)


class KitFactsTest(unittest.TestCase):
    """exakit.nb's readers answer from the kit's own files (here: this repo, a kit copy)."""

    def test_samples_connectors_notebooks_clients_and_personas(self):
        import exakit_nb as nb
        from exakit_nb.kit_facts import _client_names

        with mock.patch.dict(os.environ, {"EXAKIT_NB_KIT": str(ROOT), "EXAKIT_NB_DATASETS": str(ROOT / "data/datasets")}):
            samples = nb.sample_datasets(loaded=["tpch"])
            self.assertEqual({p.name for p in (ROOT / "data/datasets").iterdir() if p.is_dir()}, {s["id"] for s in samples})
            self.assertTrue(next(s for s in samples if s["id"] == "tpch")["loaded"])
            self.assertEqual(sorted(s["order"] for s in samples), [s["order"] for s in samples])
            self.assertTrue(all("described" in s for s in samples))
            catalog = json.loads((ROOT / "setup/virtual-schemas/catalog.json").read_text())["connectors"]
            self.assertEqual([c["id"] for c in catalog], [c["id"] for c in nb.connectors()])
            files = [n["file"].rsplit("/", 1)[-1] for n in nb.notebooks("data-scientist")]
            self.assertEqual(sorted(files), files)
            self.assertTrue(files)
            adapters = {p.stem for p in (ROOT / "mcp/adapters").glob("*.py")} - {"__init__", "base", "json_config", "registry"}
            self.assertEqual(len(adapters), len(_client_names()))
            self.assertIn("data-scientist", {p["id"] for p in nb.personas()})

    def test_live_answers_come_from_the_kit_command(self):
        from exakit_nb import kit_facts

        answers = {("marketplace", "--list", "--json"): {"addons": [{"id": "x", "name": "X", "installed": True}]},
                   ("mcp-status", "--json"): {"artifacts": [{"client": "codex", "kind": "client_config", "removed_at": None}]},
                   ("version", "--json"): {"components": [{"component": "exakit", "installed_label": "0.3.0", "status": "current"}]}}
        with mock.patch("exakit_nb.kit_commands.kit_json", side_effect=lambda *a, **_k: answers[a]):
            self.assertEqual("X", kit_facts.addons()[0]["name"])
            self.assertTrue(next(c for c in kit_facts.ai_clients() if c["id"] == "codex")["connected"])
            self.assertEqual("0.3.0", kit_facts.components()[0]["installed"])


class MovedHelpersTest(unittest.TestCase):
    """What the cards used to do on their own is now the kit's: a cell can call it too."""

    def test_a_non_utf8_csv_gets_a_utf8_copy_and_utf8_stays(self):
        from exakit_nb.spreadsheet import loadable

        with tempfile.TemporaryDirectory() as folder:
            latin = Path(folder) / "sales.csv"
            latin.write_bytes("name,city\nJos\xe9,M\xfcnchen\n".encode("cp1252"))
            path, notes = loadable(latin)
            self.assertNotEqual(latin, path)
            self.assertIn("José", path.read_text(encoding="utf-8"))
            self.assertTrue(notes)
            fine = Path(folder) / "fine.csv"
            fine.write_text("a,b\n1,2\n", encoding="utf-8")
            self.assertEqual((fine, []), loadable(fine))

    def test_remember_and_forget_the_model(self):
        from exakit_nb import setup_env

        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"EXAKIT_HOME": home}):
            for name in ("EXAKIT_MODEL_ID", "EXAKIT_PROVIDER_BASE_URL", "EXAKIT_PROVIDER_API_KEY"):
                os.environ.pop(name, None)
            setup_env.use_model("m1", "https://example.test/v1/", ask=lambda _q: "k1", remember=True)
            folder = Path(home) / "credentials"
            self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in folder.iterdir()))
            for name in ("EXAKIT_MODEL_ID", "EXAKIT_PROVIDER_BASE_URL", "EXAKIT_PROVIDER_API_KEY"):
                os.environ.pop(name, None)
            self.assertIn("EXAKIT_PROVIDER_API_KEY", setup_env.load_remembered())
            self.assertEqual("k1", os.environ["EXAKIT_PROVIDER_API_KEY"])
            setup_env.forget_model()
            self.assertEqual([], list(folder.iterdir()))
            self.assertNotIn("EXAKIT_MODEL_ID", os.environ)

    @unittest.skipUnless(HAVE_SKLEARN, "scikit-learn is not installed here (the kit's notebook environment has it)")
    def test_model_lab_trains_every_model_on_the_same_split(self):
        import numpy as np
        import pandas as pd

        from exakit_nb import lab

        rng = np.random.default_rng(0)
        frame = pd.DataFrame({"AMOUNT": rng.normal(100, 20, 600), "KIND": rng.choice(["a", "b", "c"], 600)})
        frame["LABEL"] = ((frame["AMOUNT"] > 105) | (frame["KIND"] == "a")).astype(int)
        data = lab.Data(frame, "LABEL", None, ["AMOUNT"], ["KIND"], ["KIND"], [], "SELECT ...")
        ds = mock.Mock()
        ds.descriptor.columns = {}
        with mock.patch("exakit_nb.readout.note_model", return_value="note"):
            result = lab.model_lab(None, ds, "predict_yes_no", model="logistic", leaks=[], data=data, folds=3)
        self.assertEqual("predict_yes_no", result.task)
        self.assertIn(result.pick.get("key"), {"logistic", "baseline"})
        ideas = lab.feature_ideas(result)
        self.assertTrue(all(i.sql for i in ideas))
        with self.assertRaises(ValueError):
            lab.model_lab(None, ds, "predict_yes_no", leaks=[], data=data, unknown_setting=1)


@unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
class CardTest(unittest.TestCase):
    def test_home_rows_come_from_the_kit_and_show_their_code(self):
        home = importlib.import_module("exakit_guide.screens.home")
        card = home.Home.__new__(home.Home)
        card.data = {"kit": {"running": True, "services": {}, "urls": {}},
                     "plan": {"persona": "p", "datasets": {"loaded": ["d1"], "pending": ["d2"]},
                              "addons": {"installed": [], "pending": ["a1"]}},
                     "addons": [{"id": "a1", "name": "Add-on one", "about": "does a thing", "installed": False}],
                     "clients": [{"id": "c1", "name": "Client One", "connected": True}],
                     "model": {"configured": False}, "tracing": False, "approved": [], "components": []}
        rows = {r["id"]: r for r in card._rows()}
        self.assertEqual('nb.addon_ready("a1")', rows["addon_a1"]["cmd"])
        self.assertEqual("Add-on one", rows["addon_a1"]["name"])
        self.assertIn("Client One", rows["assistants"]["text"])
        load = next(a for a in rows["data"]["actions"] if a["label"] == "Load d2")
        self.assertEqual('nb.exakit("data-load", "d2")', load["cmd"])

    def test_the_explore_notebook_starts_with_choose_your_data_which_adds(self):
        understand = importlib.import_module("exakit_guide.screens.understand")
        self.assertTrue(understand.ExploreChoose.ADDING, "what the quickstart chose stays; ticks are added beside it")
        card = understand.ExploreChoose.__new__(understand.ExploreChoose)
        with mock.patch.object(understand.ChooseData, "build", return_value=[{"t": "head", "kicker": understand.KICKER,
                                                                                "title": "Choose your data", "sub": "x"}]), \
                mock.patch.object(understand.SESSION, "chosen", [{"table": "AMAZON.ORDER_LINES"}]):
            head = card.build()[0]
        self.assertEqual(("Step 1 of 4 · Understand your data", "Choose your data"), (head["kicker"], head["title"]))
        self.assertIn("You are working on AMAZON.ORDER_LINES", head["sub"])
        explore = importlib.import_module("exakit_guide.screens.explore")
        import inspect
        self.assertIn("show(ExploreChoose(), AiHelp(), understand", inspect.getsource(explore.explore))

    def test_the_home_card_says_where_you_left_off_and_what_you_did(self):
        home = importlib.import_module("exakit_guide.screens.home")
        notebooks = [{"id": "data-scientist-quickstart", "title": "Start here: your kit and your data", "file": "00_quickstart.ipynb"},
                     {"id": "explore", "title": "Understand and explore", "file": "01_explore.ipynb"}]
        events = [{"kind": "start", "name": "data-scientist-quickstart", "ts": "2026-11-16T00:00:00Z"},
                  {"kind": "guide_action", "card": "ChooseData", "action": "use", "ok": True, "ts": "2026-11-16T00:01:00Z"},
                  {"kind": "sql", "ts": "2026-11-16T00:02:00Z"}]
        left = home._left_off(notebooks, events)
        self.assertEqual(("Start here: your kit and your data", "chose your data", "00_quickstart.ipynb"),
                         (left["where"], left["did"], left["path"]))
        events += [{"kind": "step", "name": "explore"}, {"kind": "guide_action", "card": "_ViewsPart", "ok": True},
                   {"kind": "describe.approve", "dataset": "amazon_sales"}, {"kind": "guide_action", "card": "Ask", "ok": False}]
        left = home._left_off(notebooks, events)
        self.assertEqual(("Understand and explore", "approved the column map of amazon_sales"), (left["where"], left["did"]),
                         "a button that failed is not what you did")
        self.assertIsNone(home._left_off(notebooks, [{"kind": "sql"}]))

    def test_the_journey_reads_the_kits_event_kinds(self):
        home = importlib.import_module("exakit_guide.screens.home")
        wf = importlib.import_module("exakit_nb.workflow")
        notebooks = [{"title": f"T{i}", "summary": "S.", "file": f"f{i}"} for i in range(4)]
        steps = home._journey(notebooks, [{"kind": wf.DESCRIBE_APPROVE}])
        self.assertEqual(["done", "next", "todo", "todo"], [s["state"] for s in steps])

    def test_a_first_run_marks_nothing_done(self):
        """Opening the quickstart runs several queries and, after approval, creates a view: neither makes the second
        notebook done. It is done once a model was trained there, or - on data with no target - once a later notebook
        took the work on."""
        home = importlib.import_module("exakit_guide.screens.home")
        wf = importlib.import_module("exakit_nb.workflow")
        notebooks = [{"id": f"n{i}", "title": f"T{i}", "summary": "S.", "file": f"f{i}"} for i in range(4)]

        def states(events):
            return [s["state"] for s in home._journey(notebooks, events)]

        opened = [{"kind": wf.START, "name": "n0"}] + [{"kind": wf.SQL, "sql": "SELECT 1"}] * 8
        self.assertEqual(["next", "todo", "todo", "todo"], states(opened))
        approved = opened + [{"kind": wf.DESCRIBE_APPROVE}, {"kind": wf.SQL, "sql": "CREATE OR REPLACE VIEW EXAKIT_PREPARED.X AS SELECT 1"}]
        self.assertEqual(["done", "next", "todo", "todo"], states(approved))
        exploring = approved + [{"kind": wf.STEP, "name": "n1"}] + [{"kind": wf.SQL, "sql": "SELECT 2"}] * 6
        self.assertEqual(["done", "next", "todo", "todo"], states(exploring))
        self.assertEqual(["done", "done", "next", "todo"], states(exploring + [{"kind": wf.MODEL}]))
        self.assertEqual(["done", "done", "next", "todo"], states(exploring + [{"kind": wf.STEP, "name": "n2"}]))

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_the_home_cards_steps_follow_the_workflow_live(self):
        """What is done and what is next is read again when a card below approves a column map or trains a model, and
        when the workflow's log changes on disk (another notebook, its own kernel): no cell is run again."""
        home = importlib.import_module("exakit_guide.screens.home")
        wf = importlib.import_module("exakit_nb.workflow")
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "wf-1.jsonl"
            log.write_text("{}\n", encoding="utf-8")
            card = home.Home.__new__(home.Home)
            card.loading = False
            card.data = {"last_workflow": {"id": "wf-1"}, "events": [{"kind": wf.START, "name": "n0"}],
                         "notebooks": [{"id": f"n{i}", "title": "T", "summary": "S.", "file": "f"} for i in range(2)]}
            reads = []

            def read(action_id, **values):
                reads.append((action_id, values))
                return [{"kind": wf.START, "name": "n0"}, {"kind": wf.DESCRIBE_APPROVE}]

            with mock.patch.object(home, "_read", side_effect=read), mock.patch.object(card, "refresh") as redrawn, \
                    mock.patch.object(wf, "log_path", return_value=log), \
                    mock.patch.object(home.SESSION, "latest_approved", return_value="d"):
                before = card._log_stamp()
                self.assertEqual("wf-1", before[0])
                card._follow()
                self.assertEqual([("kit.workflow_log", {"workflow_id": "wf-1"})], reads)      # the kit's own call
                self.assertEqual(2, len(card.data["events"]))
                redrawn.assert_called_once()
                self.assertEqual(["done", "next"], [s["state"] for s in home._journey(card.data["notebooks"], card.data["events"])])

                with mock.patch.object(card, "_follow") as followed:                          # a card below approved
                    card.on_session("dataset")
                    card.on_session("source")                                                 # nothing the steps show
                    for thread in __import__("threading").enumerate():
                        if thread is not __import__("threading").current_thread() and thread.daemon:
                            thread.join(timeout=2)
                    followed.assert_called_once()

                with mock.patch.object(card, "_follow") as followed:                          # another notebook wrote
                    card._watch(every=0.05)
                    time.sleep(0.2)
                    followed.assert_not_called()                                              # nothing changed yet
                    log.write_text("{}\n{}\n", encoding="utf-8")
                    time.sleep(0.4)
                    followed.assert_called_once()
                self.assertNotEqual(before, card._log_stamp())
        self.assertEqual("Steps 1 and 2 of the journey, plus a step 0: check, update or extend the kit…",
                         home._short("Steps 1 and 2 of the journey, plus a step 0: check, update or extend the kit from the notebook", 80))
        self.assertEqual("A short line.", home._short("A short line."))

    def test_continuing_a_workflow_and_training_a_model_leave_their_line(self):
        wf = importlib.import_module("exakit_nb.workflow")
        readout = importlib.import_module("exakit_nb.readout")
        logged = []
        with mock.patch.object(wf, "_continued", return_value="wf-1"), mock.patch.object(wf, "read_log", return_value=[]), \
                mock.patch.object(wf, "log_event", side_effect=lambda kind, **payload: logged.append((kind, payload))):
            self.assertEqual("wf-1", wf.continue_workflow("explore"))
            wf.continue_workflow()
            readout._model_event(mock.Mock(id="d"), 1000, 0.8123456)
        self.assertEqual([(wf.STEP, {"name": "explore"}), (wf.MODEL, {"dataset": "d", "rows": 1000, "score": 0.8123})], logged)

    def test_connecting_a_source_keeps_the_password_out_of_the_code(self):
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said, card.parsed = [], "", {}
        card.forms = {"postgresql": nb.connector_inputs("postgresql")}          # the kit's own form for it
        f = card._fid
        with mock.patch.object(understand.actions, "run", return_value="VS_SALES") as run:
            schema = card._connect({"connector": "postgresql", "src_name": "Sales",
                                    f("postgresql", "password"): "s3cret",
                                    f("postgresql", "host"): "db.example.com", f("postgresql", "database"): "shop",
                                    f("postgresql", "user"): "reader", f("postgresql", "port"): "5432",
                                    f("postgresql", "tls"): "require"})
        self.assertEqual("VS_SALES", schema)
        kwargs = run.call_args.kwargs
        self.assertEqual("s3cret", kwargs["secret"]["secret"]("Password"))
        # Each input by its own name; one left at the kit's default (port 5432) is not repeated.
        self.assertEqual({"host": "db.example.com", "database": "shop", "user": "reader", "tls": "require"}, kwargs["settings"])
        actions = importlib.import_module("exakit_guide.actions")
        shown = actions.code("data.connect_source", **kwargs)
        self.assertNotIn("s3cret", shown)
        self.assertEqual('connected = nb.connect_source("postgresql", "sales", host="db.example.com", database="shop", '
                         'user="reader", tls="require")', shown)

    def test_a_missing_required_input_is_named_before_anything_runs(self):
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.forms, card.parsed = {"postgresql": nb.connector_inputs("postgresql")}, {}
        with mock.patch.object(understand.actions, "run") as run:
            with self.assertRaisesRegex(ValueError, "Fill in: Host name or address, Database, Reader account"):
                card._connect({"connector": "postgresql", "src_name": "sales"})
        run.assert_not_called()

    def test_a_source_with_settings_asks_them_as_lists_that_follow_each_other(self):
        """Data source is the kit's list of sources, one row each. A source that has settings of its own (which, the
        kit says: nothing here names one) shows each as a list; a pick keeps the ones before it and asks the kit
        again for the ones after it, taking the kit's default for each, and the details shown are that combination's.
        The settings go to exakit connect, the two secrets apart."""
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said, card.parsed, card.source_tables = [], "", {}, {}
        card.connectors = nb.connectors()
        card.forms = {c["id"]: nb.connector_inputs(c["id"]) for c in card.connectors}
        card._settle = lambda cid, chosen: card.forms.__setitem__(cid, nb.connector_inputs(cid, **chosen)) or card.forms[cid]
        cid = next(c["id"] for c in card.connectors if card.forms[c["id"]]["setting_inputs"])

        def fields():
            return {f["id"]: f for f in _flat(card._new_connection())}

        # Before a pick: the list of sources, each once, in the kit's order, and nothing else to fill in.
        first = fields()
        self.assertEqual([c["id"] for c in card.connectors], [o["value"] for o in first["connector"]["options"]])
        self.assertEqual({"heading", "select", "group"}, {f["type"] for f in first.values()})
        self.assertFalse(card._ready())

        card.on_src_pick({"connector": cid})
        specs = card.forms[cid]["setting_inputs"]
        asked = fields()[card._fid(cid, "settings")]["fields"]
        self.assertEqual([spec["label"].split(" - ")[0] + " *" for spec in specs], [f["label"] for f in asked])
        self.assertEqual(specs[0].get("choice_labels") or specs[0]["choices"], [o["label"] for o in asked[0]["options"] if not o.get("disabled")])
        self.assertTrue(all(f["send_on_change"] == "src_set" and f["sync"] for f in asked))
        if not specs[0]["default"]:                       # the kit has no default for the first: it is the user's to pick
            self.assertEqual(("", False), (asked[0]["value"], card._ready()))
            self.assertNotIn(card._fid(cid, "needed"), fields())

        # A pick of the first setting: the kit's defaults settle the rest, and that combination's details show.
        sid = lambda spec: card._fid(cid, "set_" + spec["name"])
        card.on_src_set({sid(specs[0]): specs[0]["choices"][0]})
        specs = card.forms[cid]["setting_inputs"]
        self.assertTrue(card._ready())
        self.assertEqual({spec["name"] for spec in specs}, set(card.preset))
        self.assertEqual(specs[0]["choices"][0], card.preset[specs[0]["name"]])
        shown = fields()
        self.assertEqual([card.preset[spec["name"]] for spec in specs], [f["value"] for f in shown[card._fid(cid, "settings")]["fields"]])
        self.assertIn(card._fid(cid, "needed"), shown)
        self.assertEqual("src_name", shown[card._fid(cid, "needed")]["fields"][0]["id"])       # the name, then the details

        # A later setting changed: the ones before it stay, and it is what was picked.
        if len(specs) > 1 and len(specs[1]["choices"]) > 1:
            kept, other = card.preset[specs[0]["name"]], specs[1]["choices"][-1]
            card.on_src_set({sid(specs[0]): kept, sid(specs[1]): other, **{sid(spec): card.preset[spec["name"]] for spec in specs[2:]}})
            self.assertEqual((kept, other), (card.preset[specs[0]["name"]], card.preset[specs[1]["name"]]))
            self.assertTrue(card._ready())
        # Another first setting: what followed it starts again from the kit's defaults.
        card.on_src_set({sid(specs[0]): specs[0]["choices"][-1]})
        self.assertEqual(specs[0]["choices"][-1], card.preset[specs[0]["name"]])
        self.assertEqual([], card._pending(card.forms[cid]))

        # What goes to the kit: the settings as inputs, the login as the password, the storage secret apart.
        leaves = [child["set"] for node in card.forms[cid]["tree"] for child in node["children"]]
        both = next((leaf for leaf in leaves if any(i.get("storage") for i in nb.connector_inputs(cid, **leaf)["inputs"])), None)
        self.assertIsNotNone(both, "no combination has a second secret any more: drop this part with it")
        card.preset = dict(both)
        card._settle_all()
        self.assertTrue(card._ready())
        typed = {"src_name": "lake"}
        for spec in card.forms[cid]["inputs"]:
            typed[card._fid(cid, spec["name"])] = ("STORAGEKEY" if spec.get("storage") else "LOGINTOKEN" if spec["kind"] == "secret"
                                                   else spec["default"] or "https://example.com/x")
        connector, name, settings, password = card._source_inputs({**typed, card._fid(cid, "how"): "manual"})
        self.assertEqual((cid, "lake", "LOGINTOKEN", "STORAGEKEY"), (connector, name, password, card.typed_storage))
        for key, value in both.items():
            self.assertEqual(value, settings[key])
        self.assertNotIn("STORAGEKEY", repr(settings))
        self.assertNotIn("LOGINTOKEN", repr(settings))

    def test_a_connect_tried_again_still_has_its_password(self):
        """The password's box is emptied when it is sent. A connect that fails (the source refused, a name did not
        resolve) and is tried again goes out with the password typed before, not with none; a new one typed wins; it
        is forgotten once connected and for another source."""
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said, card.parsed, card.source_tables = [], "", {}, {}
        card.connectors = nb.connectors()
        card.forms = {"postgresql": nb.connector_inputs("postgresql")}
        card.connector, card.src_name = "postgresql", "sales"
        f = card._fid
        typed = {f("postgresql", "host"): "db.example.com", f("postgresql", "database"): "shop", f("postgresql", "user"): "reader",
                 f("postgresql", "how"): "manual"}
        sent = []

        def run(action_id, **values):
            sent.append(values["secret"]["secret"]("Password"))
            if len(sent) == 1:
                raise RuntimeError("sales was not connected: the host name does not resolve")
            return "VS_SALES"

        with mock.patch.object(understand.actions, "run", side_effect=run):
            with self.assertRaises(RuntimeError):
                card._connect({**typed, f("postgresql", "password"): "s3cret"})
            self.assertEqual("VS_SALES", card._connect({**typed, f("postgresql", "password"): ""}))   # the box is empty now
        self.assertEqual(["s3cret", "s3cret"], sent)
        self.assertEqual("", card._kept_secret)                                          # connected: forgotten
        with mock.patch.object(understand.actions, "run", side_effect=lambda action_id, **values: sent.append(
                values["secret"]["secret"]("Password")) or "VS_SALES"):
            card._kept_secret = "old"
            card._connect({**typed, f("postgresql", "password"): "new"})
        self.assertEqual("new", sent[-1])
        card._kept_secret = "held"
        other = next(c["id"] for c in card.connectors if c["id"] != "postgresql" and not nb.connector_inputs(c["id"])["setting_inputs"])
        card.forms[other] = nb.connector_inputs(other)
        card.on_src_pick({"connector": other})
        self.assertEqual("", card._kept_secret)                                          # another source: its own
        self.assertNotIn("_kept_secret", repr(vars(card).get("flash", "")))

    def test_a_new_connection_is_one_form(self):
        """The connections there are, then - under New connection - one form: the data source, how to fill it in,
        and the name with every detail in one place, the required ones first. No step to press through: a pick of
        the data source shows the whole form, and Connect is the one button left."""
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said, card.parsed, card.source_tables = ["VS_OLD"], "", {}, {}
        card.connectors = nb.connectors()
        card.forms = {c["id"]: nb.connector_inputs(c["id"]) for c in card.connectors}
        only = {"field": "src_schema", "equals": "__connect__"}
        first = card._source_fields(only)
        self.assertEqual("Connections", first[0]["label"])                      # the connections there are, first
        self.assertEqual(["VS_OLD", "__connect__"], [o["value"] for o in first[0]["options"]])
        self.assertEqual(["Data source *"], [f["label"] for f in _flat(first) if f.get("type") == "select"])
        with self.assertRaisesRegex(ValueError, "Choose the data source"):
            card.on_src_pick({"connector": "nope"})
        self.assertFalse(card._ready())
        card.on_src_pick({"connector": "postgresql"})
        self.assertTrue(card._ready())
        top = card._source_fields(only)
        form = {f["id"]: f for f in _flat(top)}
        new = [f for f in top if f["id"] not in ("src_schema", card._tid("VS_OLD"))]
        side = next(f for f in top if f["id"] == "src_top")["fields"]             # the source and how, side by side
        self.assertEqual(["connector", card._fid("postgresql", "how")], [f["id"] for f in side])
        self.assertTrue(all(only in (f["show_if"] if isinstance(f["show_if"], list) else [f["show_if"]]) for f in new))
        self.assertEqual(["manual", "string"], [o["value"] for o in form[card._fid("postgresql", "how")]["options"]])
        self.assertEqual("src_read", form[card._fid("postgresql", "url")]["send_on_change"])
        labels = [f["label"] for f in form[card._fid("postgresql", "needed")]["fields"]]
        self.assertIn("alias", labels[0])                                        # the name, then what is required
        self.assertEqual(["Host name or address *", "Database *", "Reader account *"], labels[1:4])
        self.assertIn("Password", labels[4])
        optional = form[card._fid("postgresql", "rest")]["fields"]
        self.assertTrue(optional and all("(optional)" in f["label"] for f in optional))
        shown = {f["id"] for group in ("needed", "rest") for f in form[card._fid("postgresql", group)]["fields"]}
        self.assertEqual({card._fid("postgresql", i["name"]) for i in card.forms["postgresql"]["inputs"]} | {"src_name"}, shown,
                         "every input the kit asks is on the form")
        with self.assertRaisesRegex(ValueError, "Give the source a name"):
            card._source_inputs({})
        with self.assertRaisesRegex(ValueError, "Fill in: Host name or address"):
            card._source_inputs({"src_name": "sales"})
        card.forms["plain"] = {**card.forms["postgresql"], "forms": []}          # a data source that takes no string
        card.connectors = card.connectors + [{"id": "plain", "name": "Plain"}]
        card.on_src_pick({"connector": "plain"})
        self.assertNotIn(card._fid("plain", "how"), {f["id"] for f in _flat(card._source_fields(only))})

    def test_a_connection_string_is_read_first_and_only_the_rest_is_asked(self):
        """The string is read as `exakit connect --url` reads it; then only what it did not give is required, every
        other input shown as optional and filled in from it. Its password never reaches the code or the log."""
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said, card.parsed, card.flash = [], "", {}, None
        card.forms = {"postgresql": nb.connector_inputs("postgresql")}
        calls = []

        def run(action_id, **values):
            calls.append((action_id, values))
            if action_id == "data.read_string":
                return nb.read_connection_string(values["connector"], understand.SESSION.get("SOURCE_URL"))
            return "VS_SALES"

        with mock.patch.object(understand.actions, "run", side_effect=run):
            card.connector = "postgresql"
            card.on_src_read({card._fid("postgresql", "url"): "postgres://db.example.com:5433/shop"})
            self.assertEqual(["user", "password"], card.parsed["postgresql"]["missing"])
            needed, rest = card._groups("postgresql")
            fields = {f["id"]: f for f in needed + rest}
            sid = card._sid("postgresql")
            self.assertEqual("Reader account *", fields[card._fid(sid, "user")]["label"])              # required
            self.assertEqual([card._fid(sid, "user"), card._fid(sid, "password")], [f["id"] for f in needed])
            self.assertEqual("db.example.com", fields[card._fid(sid, "host")]["value"])               # read, optional
            self.assertIn("(optional)", fields[card._fid(sid, "host")]["label"])
            self.assertEqual("public", fields[card._fid(sid, "schema")]["value"])                     # kit default
            with self.assertRaisesRegex(ValueError, "Fill in: Reader account"):
                card._connect({"connector": "postgresql", "src_name": "sales",
                               card._fid("postgresql", "url"): "postgres://db.example.com:5433/shop"})
            card._connect({"connector": "postgresql", "src_name": "sales",
                           card._fid("postgresql", "url"): "postgres://reader:s3cret@db.example.com:5433/shop",
                           card._fid(card._sid("postgresql"), "tls"): "require"})
        actions = importlib.import_module("exakit_guide.actions")
        read = [v for a, v in calls if a == "data.read_string"][-1]
        # The string is the notebook's SOURCE_URL variable: the code and the log name it, never hold it.
        self.assertEqual('source_reading = nb.read_connection_string("postgresql", SOURCE_URL)',
                         actions.code("data.read_string", **read))
        connect = [v for a, v in calls if a == "data.connect_source"][-1]
        shown = actions.code("data.connect_source", **connect)
        self.assertEqual('connected = nb.connect_source("postgresql", "sales", url=SOURCE_URL, tls="require")', shown)
        self.assertNotIn("s3cret", shown)
        self.assertEqual("****", card.parsed["postgresql"]["masked"].split(":")[2].split("@")[0])   # the engine's mask

    def test_only_a_step_that_follows_the_approved_data_can_fall_behind_it(self):
        """Step 1 chooses its own data: an older approval of another dataset is not "newer", and running its cell
        again would change nothing. A later step that opened the approved-last data is told when that moves on."""
        session = importlib.import_module("exakit_guide.session")
        fake = session.Session()
        fake._ns = {"dataset": mock.Mock(id="amazon_sales")}
        with mock.patch.object(session.Session, "latest_approved", return_value="amazon_sales_prepared"):
            self.assertIsNone(fake.newer_approved())                    # step 1: follows nothing
            fake.followed = "amazon_sales"
            self.assertEqual("amazon_sales_prepared", fake.newer_approved())
            fake.followed = "amazon_sales_prepared"                     # opened again, or picked here on purpose
            self.assertIsNone(fake.newer_approved())

    def test_share_reads_the_answers_of_the_last_workflow(self):
        share = importlib.import_module("exakit_guide.screens.share")
        wf = importlib.import_module("exakit_nb.workflow")
        events = [{"kind": wf.ASK_APPROVE, "dataset": "d", "sql_digest": "x", "question": "How many?", "sql": "SELECT 1"},
                  {"kind": wf.ASK_ANSWER, "sql_digest": "x", "row_count": 3}]

        def run(action_id, **values):
            self.assertIn(action_id, share.actions.ACTIONS)             # only actions there are
            return {"kit.workflows": [{"id": "old", "last": "2026-01-01"}, {"id": "new", "last": "2026-02-01"}],
                    "kit.workflow_log": events if values.get("workflow_id") == "new" else []}[action_id]

        with mock.patch.object(share.actions, "run", side_effect=run):
            self.assertEqual(["How many? · 3 rows"], [a["label"] for a in share._answers("d")])

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_a_preview_sets_up_the_dashboard_server_itself_when_it_is_not_there(self):
        """Sharing needs Dash Server. When it is not installed or not running, making the preview (or publishing)
        installs and starts it with the kit's own nb.addon_ready - nothing is asked and nothing is left to the user -
        and one that went away after the card opened is set up again, once."""
        share = importlib.import_module("exakit_guide.screens.share")
        ran: list[str] = []
        state = {"up": False, "preview_fails": 0}

        def run(action_id, **values):
            ran.append(action_id)
            if action_id == "share.server":
                state["up"] = True
                return {"addon": "x", "installed": True, "state": "running", "url": "http://dash"}
            if action_id == "kit.check":
                return {"services": {}}
            if action_id == "share.draft":
                return mock.Mock(title="T", sql="SELECT 1")
            if action_id == "share.preview":
                if state["preview_fails"]:
                    state["preview_fails"] -= 1
                    raise RuntimeError("the dashboard server does not answer")
                return "/preview"
            return "/live"

        def card(dash):
            made = share.Dashboard.__new__(share.Dashboard)
            made.ds, made.dash, made.draft, made.preview_url, made.live_url = mock.Mock(id="d"), dash, None, None, None
            made._sql_for = lambda v: ("SELECT 1", "T", "count")
            return made

        with mock.patch.object(share.actions, "run", side_effect=run), mock.patch.object(share.SESSION, "release"):
            missing = card({"state": "not running", "url": "", "why": "not installed"})
            self.assertFalse(missing._server_up())
            missing.on_preview({})
            self.assertEqual(["share.server", "share.draft", "share.preview"], ran)      # set up first, then the preview
            self.assertEqual("/preview", missing.preview_url)
            self.assertEqual("http://dash", missing.dash["url"])

            del ran[:]
            there = card({"state": "running", "url": "http://dash"})
            there.on_preview({})
            self.assertEqual(["share.draft", "share.preview"], ran)                       # already there: not touched

            del ran[:]
            state["preview_fails"] = 1                                                    # removed after the card opened
            there.on_preview({})
            self.assertEqual(["share.draft", "share.preview", "kit.check", "share.server", "share.preview"], ran)

            del ran[:]
            stopped = card({"state": "stopped", "url": "http://dash"})
            stopped.draft = mock.Mock()
            stopped.on_publish({"checked": True, "ok_to_share": True})
            self.assertEqual(["share.server", "share.publish"], ran)
        for line in (share.Dashboard.build, share.Dashboard.__init__):
            self.assertNotIn("Start it from the Home screen", inspect.getsource(line))

    def test_a_cell_of_the_code_view_runs_like_a_notebook_cell(self):
        """Code typed (or edited) in a card's Code view runs in the notebook's own namespace: every line runs, the last
        expression's value shows, what it prints shows, a name it assigns stays for the next cell, and an error is
        one line with the line it happened on - never an exception that breaks the card. What ran is logged."""
        actions = importlib.import_module("exakit_guide.actions")
        session = importlib.import_module("exakit_guide.session")
        fake = session.Session()
        fake._ns = {"nb": mock.Mock(), "connection": object()}
        result = actions.run_text("rows = [1, 2, 3]\nprint('counted')\nlen(rows) * 2", fake)
        self.assertEqual((True, "counted\n6", 6), (result["ok"], result["text"], result["value"]))
        self.assertEqual([1, 2, 3], fake.get("rows"))                              # it stays, as in a notebook
        self.assertEqual({"ok": True, "text": "", "value": None}, actions.run_text("total = sum(rows)", fake))
        self.assertEqual(6, fake.get("total"))
        failed = actions.run_text("first = rows[0]\nrows[10]", fake)
        self.assertFalse(failed["ok"])
        self.assertIn("IndexError", failed["text"])
        self.assertIn("(line 2)", failed["text"])
        self.assertEqual(1, fake.get("first"))                                     # the lines before the error ran
        self.assertEqual("rows = [1, 2, 3]\nprint('counted')\nlen(rows) * 2", fake.code[0])     # logged as it ran
        with self.assertRaises(SyntaxError):
            actions.run_text("def broken(:", fake)
        # A cell that holds a query runs it on the notebook's connection, as nb.sql would.
        fake._ns["nb"].sql.return_value = "the rows"
        asked = actions.run_text("# The dashboard's query\nSELECT CATEGORY, COUNT(*)\nFROM AMAZON.ORDER_LINES\nGROUP BY 1", fake)
        self.assertEqual((True, "the rows"), (asked["ok"], asked["value"]))
        connection, statement = fake._ns["nb"].sql.call_args[0]
        self.assertIs(connection, fake._ns["connection"])
        self.assertEqual("SELECT CATEGORY, COUNT(*)\nFROM AMAZON.ORDER_LINES\nGROUP BY 1", statement.strip())
        self.assertTrue(fake.code[-1].startswith('nb.sql(connection, """'))                  # logged as the call it was
        self.assertEqual("select 1", (actions.run_text("select 1", fake), fake._ns["nb"].sql.call_args[0][1])[1])
        with self.assertRaisesRegex(ValueError, "empty"):
            actions.run_text("   \n", fake)
        long = actions.run_text("'x' * 20000", fake)
        self.assertLess(len(long["text"]), actions.SHOWN + 100)
        self.assertIn("cut", long["text"])

        class Frame:                                                               # a table shows its first rows
            def __len__(self):
                return 50

            def head(self, n):
                return self

            def to_string(self, **_):
                return "A  B\n1  2"

        Frame.__name__ = "DataFrame"
        self.assertEqual("A  B\n1  2\n... 50 rows, the first 20 shown", actions._shown(Frame()))

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_a_card_keeps_what_each_cell_showed_and_tells_the_others(self):
        card = importlib.import_module("exakit_guide.card")
        screen = card.Screen.__new__(card.Screen)
        screen.cells = None
        with mock.patch.object(card, "SESSION", create=True), \
                mock.patch("exakit_guide.actions.run_text", return_value={"ok": False, "text": "NameError: x  (line 1)", "value": None}) as ran, \
                mock.patch("exakit_guide.session.SESSION") as shared:
            screen.on_run_code({"cell": "call:nb.kit_check()", "code": "x"})
        ran.assert_called_once_with("x")
        self.assertEqual({"call:nb.kit_check()": {"ok": False, "text": "NameError: x  (line 1)"}}, screen.cells)
        shared.changed.assert_called_once_with("code", screen)
        script = (ROOT / "notebook/package/exakit_guide/static/card.js").read_text(encoding="utf-8")
        self.assertIn('send("run_code", { cell: key, code:', script)
        self.assertIn('b.t !== "ran" && b.t !== "cells"', script)                  # a cell's output is not a control

    def test_run_logs_exactly_what_it_ran_and_returns_the_result(self):
        actions = importlib.import_module("exakit_guide.actions")
        session = importlib.import_module("exakit_guide.session")
        fake = session.Session()
        fake._ns = {"nb": mock.Mock(**{"addon_ready.return_value": {"state": "running"}}), "connection": object()}
        result = actions.run("share.server", fake)
        self.assertEqual({"state": "running"}, result)
        self.assertEqual(['dash_server_state = nb.addon_ready("dash-server")'], fake.code)

    def test_the_first_card_of_a_page_gets_the_mark_and_a_docs_button(self):
        """card.mark makes a card the first of its page: the persona's title beside the logo and the Docs button's
        address, the persona's start page in the kit's documentation. A page the site does not have opens the persona's
        section instead of a search; a kit without the documentation shows no button."""
        card = importlib.import_module("exakit_guide.card")
        exakit_nb = importlib.import_module("exakit_nb")
        screen = mock.Mock()
        with mock.patch.object(card, "_persona_title", return_value="Data Scientist"), \
                mock.patch.object(card, "_docs_url", return_value="http://h:1/docs/data-scientist") as url:
            self.assertIs(screen, card.mark(screen, docs="guides/ask"))
        url.assert_called_once_with("")          # the Docs button opens the persona's start page, whatever the notebook
        self.assertEqual(("Data Scientist", "http://h:1/docs/data-scientist"), (screen.brand, screen.docs_url))
        screen.refresh.assert_called_once()

        def docs(what=None, **_):
            return mock.Mock(url="http://h:1/docs/data-scientist/guides/ask" if what == "guides/ask" else
                             "http://h:1/docs?q=guides%2Fgone" if what else "http://h:1/docs/data-scientist")

        with mock.patch.object(exakit_nb, "docs", side_effect=docs):
            self.assertEqual("http://h:1/docs/data-scientist/guides/ask", card._docs_url("guides/ask"))
            self.assertEqual("http://h:1/docs/data-scientist", card._docs_url("guides/gone"))
            self.assertEqual("http://h:1/docs/data-scientist", card._docs_url(""))
        with mock.patch.object(exakit_nb, "docs", side_effect=RuntimeError("no site in this kit copy")):
            self.assertEqual("", card._docs_url("guides/ask"))
        script = (ROOT / "notebook/package/exakit_guide/static/card.js").read_text(encoding="utf-8")
        self.assertIn('class: "guide-docs", href: docs, target: "_blank", rel: "noopener"', script)
        self.assertEqual(2, script.count("brand(b.brand, b.docs)"))          # the Home card's head and every other head

    def test_marimo_gets_the_cards_stacked(self):
        card = importlib.import_module("exakit_guide.card")
        screen = mock.Mock()
        screen._display_.return_value = "card"
        fake_mo = mock.Mock()
        fake_mo.running_in_notebook.return_value = True
        fake_mo.vstack.side_effect = lambda items: ("stack", items)
        with mock.patch.dict(sys.modules, {"marimo": fake_mo}):
            self.assertEqual(("stack", ["card", "card"]), card.show(screen, screen))


class QuietTest(unittest.TestCase):
    """quiet() must never swap a process-wide object: a card redrawing on a background thread while a cell runs once
    left IPython's capturing publisher installed, and every later output in that notebook vanished."""

    def test_overlapping_threads_leave_output_alone(self):
        import io
        import threading
        import time

        from exakit_guide.session import quiet

        real = io.StringIO()
        with mock.patch.object(sys, "stdout", real):
            def background():
                time.sleep(0.01)
                with quiet():
                    print("hidden in thread")
                    time.sleep(0.05)

            thread = threading.Thread(target=background)
            thread.start()
            with quiet() as out:
                print("hidden here")
                time.sleep(0.03)
            print("shown")
            thread.join()
            print("still shown")
        self.assertEqual(out.text, "hidden here")
        self.assertEqual(real.getvalue(), "shown\nstill shown\n")

    def test_source_never_uses_capture_output(self):
        source = (PACKAGE / "exakit_guide" / "session.py").read_text(encoding="utf-8")
        self.assertNotIn("import capture_output", source)


class BlankFormTest(unittest.TestCase):
    """Load it with the field left blank once ran `exakit data-load "<file, folder or dataset>"` behind a spinning
    button, and a failed kit command still said Done."""

    def test_the_card_never_sends_a_blank_field(self):
        js = (GUIDE / "static" / "card.js").read_text(encoding="utf-8")
        self.assertIn("const missing = blank();", js)
        self.assertIn("if (missing.length) { draw(); return; }", js)

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_a_blank_placeholder_is_refused_before_anything_runs(self):
        from exakit_guide import actions
        from exakit_guide.screens import home

        screen = home.Home.__new__(home.Home)
        screen.confirm = None
        with mock.patch.object(actions, "run") as run:
            with self.assertRaisesRegex(ValueError, "file or folder path"):
                screen._run("kit.data_load", {"what": "<file, folder or dataset>"}, {"what": "  "})
        run.assert_not_called()

    def test_a_failed_kit_command_is_an_error_not_done(self):
        from exakit_guide import actions
        from exakit_nb.kit_commands import KitRun

        failed = KitRun(["data-load", "x"], 1, "  [x] No such file, folder or dataset: x\n    | Log: /logs/install.log\n")
        session = mock.Mock(said="")
        session.namespace.return_value = {"nb": mock.Mock(exakit=mock.Mock(return_value=failed))}
        with self.assertRaisesRegex(RuntimeError, r"^No such file, folder or dataset: x \(Log: /logs/install.log\)$"):
            actions.run("kit.data_load", session, what="x")
        ok = KitRun(["data-load", "x"], 0, "loaded\n")
        session.namespace.return_value = {"nb": mock.Mock(exakit=mock.Mock(return_value=ok))}
        self.assertIs(ok, actions.run("kit.data_load", session, what="x"))


class KitSaidTest(unittest.TestCase):
    def test_the_kit_output_opens_only_after_a_failure(self):
        js = (GUIDE / "static" / "card.js").read_text(encoding="utf-8")
        self.assertIn("open: ui.values[key] ?? !!r.output_open", js)
        self.assertIn("open: ui.values[\"open:\" + b.title] ?? !!b.open", js)
        card = (GUIDE / "card.py").read_text(encoding="utf-8")
        self.assertIn('"title": "What the kit said", "open": True', card)       # under a failed action's error
        for name in ("explore.py", "understand.py"):                            # after one that worked: closed
            self.assertNotIn('"open": True', (GUIDE / "screens" / name).read_text(encoding="utf-8"))


class WorkflowTest(unittest.TestCase):
    """guide.start() starts a workflow; every card action is a line in its log with the exact code it ran."""

    def test_start_begins_a_workflow(self):
        init = (GUIDE / "__init__.py").read_text(encoding="utf-8")
        self.assertIn('actions.run("data.workflow")', init.split("def start():", 1)[1])

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_card_actions_are_logged_under_the_workflow(self):
        from exakit_guide import card

        workflow = importlib.import_module("exakit_nb.workflow")     # exakit_nb.workflow is also a function

        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"EXAKIT_HOME": home}):
            os.environ.pop("EXAKIT_WORKFLOW_ID", None)
            with mock.patch.object(workflow, "recall", return_value=None), mock.patch.object(workflow, "remember"):
                workflow_id = workflow.workflow("test")
                with mock.patch.object(workflow, "current_workflow", return_value=workflow_id):
                    card._log_action("Home", 'run:["kit.data_load", {"what": "x"}]', ['nb.exakit("data-load", "x")'],
                                     "No such file")
                    card._log_action("Home", "refresh", ["nb.kit_check()"], None)        # a redraw is not an action
                events = workflow.read_log(workflow_id)
        actions = [e for e in events if e["kind"] == "guide_action"]
        self.assertEqual(1, len(actions))
        self.assertEqual(("Home", "kit.data_load", 'nb.exakit("data-load", "x")', False, "No such file"),
                         tuple(actions[0][k] for k in ("card", "action", "code", "ok", "error")))


class MessagePlaceTest(unittest.TestCase):
    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_a_result_shows_under_the_button_that_asked_for_it(self):
        """Test connection's answer was drawn at the top of a long card, out of sight of the button: nothing seemed
        to happen. It now sits under the block holding the pressed button, one line per check, and stays."""
        card = importlib.import_module("exakit_guide.card")

        class Long(card.Screen):
            def build(self):
                return [{"t": "head", "title": "Choose"}, {"t": "p", "v": "lots of text"},
                        {"t": "actions", "items": [{"id": "test_source", "label": "Test connection"}]}, {"t": "p", "v": "end"}]

            def on_test_source(self, _v):
                self.flash = {"kind": "error", "keep": True, "v": "not ready",
                              "lines": [("ok", "inputs: fine"), ("error", "network: refused")]}

        screen = Long()
        screen._on_msg(None, {"type": "event", "id": "test_source", "values": {}}, None)
        kinds = [(b["t"], b.get("v")) for b in screen.widget.blocks if b["t"] != "ran"]
        self.assertEqual([("head", None), ("p", "lots of text"), ("actions", None), ("msg", "not ready"),
                          ("msg", "inputs: fine"), ("msg", "network: refused"), ("p", "end")], kinds)
        self.assertTrue(all(b.get("keep") for b in screen.widget.blocks if b["t"] == "msg"))


class ProgressTest(unittest.TestCase):
    """A long kit command (exakit data-load) shows its progress under its button while it runs, from the lines it
    prints, instead of a bare "Working…"."""

    def test_lines_become_a_step_a_share_done_and_the_last_lines(self):
        sys.modules.setdefault("anywidget", mock.MagicMock())   # only Progress is used here
        sys.modules.setdefault("traitlets", mock.MagicMock())
        card = importlib.import_module("exakit_guide.card")
        sent = []
        progress = card.Progress(sent.append)
        progress.EVERY = 0
        progress.feed("\x1b[1mSTEP  Step 2/7  Exasol launcher\x1b[0m\n")
        progress.feed("Imported 51000 rows\n[1/2] -- 03_verify_setup.sql ... OK\n")
        progress.feed("uploading 40%\r")
        progress.feed("uploading 80%\r")
        progress.feed("\n")
        self.assertEqual("STEP  Step 2/7  Exasol launcher", sent[0]["label"])
        self.assertEqual(29, sent[0]["pct"])                                   # Step 2/7
        self.assertEqual(50, sent[1]["pct"])                                   # [1/2]
        self.assertEqual("uploading 80%", sent[-1]["label"])                  # a \r line replaces the one before
        self.assertEqual(80, sent[-1]["pct"])
        self.assertLessEqual(len(sent[-1]["lines"]), 6)

    @unittest.skipIf(os.name == "nt", "the stand-in kit is a shell script")
    def test_the_kits_own_live_progress_reaches_the_listener(self):
        """exakit data-load with no terminal printed one line per finished file; its live progress (the bar the
        terminal draws) now comes through EXAKIT_PROGRESS_LOG, which nb.exakit asks for and follows."""
        kit_commands = importlib.import_module("exakit_nb.kit_commands")
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "exakit"
            script.write_text("#!/bin/sh\n"
                              "printf '0|reading 3 files\\n' >> \"$EXAKIT_PROGRESS_LOG\"; sleep 0.5\n"
                              "printf '40|loading orders.csv\\n' >> \"$EXAKIT_PROGRESS_LOG\"; sleep 0.5\n"
                              "echo '[ok] orders.csv -> ORDERS  51000 rows'\n"
                              "printf '100|3 files loaded\\n' >> \"$EXAKIT_PROGRESS_LOG\"; sleep 0.5\n", encoding="utf-8")
            script.chmod(0o755)
            seen = []
            with mock.patch.object(kit_commands, "exakit_command", return_value=[str(script)]), \
                 mock.patch.object(kit_commands._ProgressFollower, "EVERY", 0.05):
                with kit_commands.watch_progress(lambda pct, phase: seen.append((pct, phase))):
                    run = kit_commands.exakit("data-load", "x", show=False)
            self.assertTrue(run.ok)
            self.assertEqual([(0, "reading 3 files"), (40, "loading orders.csv"), (100, "3 files loaded")], seen)
            self.assertEqual([], list(Path(tempfile.gettempdir()).glob(f"exakit-progress-*{os.getpid()}*")))
            # Nobody watching and no notebook: the command runs exactly as before, no progress file asked for.
            with mock.patch.object(kit_commands, "exakit_command", return_value=[str(script)]), \
                 mock.patch.object(kit_commands.subprocess, "Popen", wraps=kit_commands.subprocess.Popen) as popen:
                kit_commands.exakit("data-load", "x", show=False)
            self.assertNotIn("EXAKIT_PROGRESS_LOG", popen.call_args.kwargs["env"])

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_a_card_action_streams_its_progress_while_it_runs(self):
        card = importlib.import_module("exakit_guide.card")
        session = importlib.import_module("exakit_guide.session")

        class Loading(card.Screen):
            def build(self):
                return [{"t": "actions", "items": [{"id": "load", "label": "Load it"}]}]

            def on_load(self, _v):
                with session.quiet():
                    print("Step 1/2 download")
                    print("Step 2/2 load")

        screen = Loading()
        sent = []
        with mock.patch.object(card.Progress, "EVERY", 0), mock.patch.object(screen.widget, "send", side_effect=sent.append):
            screen._on_msg(None, {"type": "event", "id": "load", "values": {}}, None)
        progress = [m for m in sent if m["type"] == "progress"]
        self.assertEqual([("load", "Step 1/2 download", 50), ("load", "Step 2/2 load", 100)],
                         [(m["id"], m["label"], m["pct"]) for m in progress])
        self.assertEqual("done", sent[-1]["type"])


class LoadIntoSchemaTest(unittest.TestCase):
    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_add_data_asks_the_schema_and_tells_the_other_cards(self):
        """Add data loaded into STARTER_KIT only, and Choose your data did not list what it loaded."""
        actions = importlib.import_module("exakit_guide.actions")
        home = importlib.import_module("exakit_guide.screens.home")
        screen = home.Home.__new__(home.Home)
        screen.confirm, screen.outputs, screen.failed, screen.data = None, {}, set(), None
        with mock.patch.object(home.actions, "run") as run, mock.patch.object(screen, "_rows", return_value=[]), \
             mock.patch.object(screen, "_other_rows", return_value=[]), mock.patch.object(screen, "_reload"), \
             mock.patch.object(home.SESSION, "changed") as changed:
            screen._run("kit.data_load", {"what": "<file, folder or dataset>"}, {"what": "~/data/retail", "schema": "retail"})
        self.assertEqual(("kit.data_load_into",), run.call_args.args)
        # ~ is expanded here: exakit gets no shell (it read "~/..." as a folder named ~).
        self.assertEqual({"what": str(Path.home() / "data" / "retail"), "schema": "RETAIL"},
                         {k: run.call_args.kwargs[k] for k in ("what", "schema")})
        self.assertEqual('nb.exakit("data-load", "~/data/retail", env={"EXAKIT_SCHEMA": "RETAIL"})',
                         actions.code("kit.data_load_into", what="~/data/retail", schema="RETAIL"))
        changed.assert_called_once_with("data", screen)
        with mock.patch.object(home.actions, "run") as run, mock.patch.object(screen, "_rows", return_value=[]), \
             mock.patch.object(screen, "_other_rows", return_value=[]), mock.patch.object(screen, "_reload"), \
             mock.patch.object(home.SESSION, "changed"):
            screen._run("kit.data_load", {"what": "<file, folder or dataset>"}, {"what": "amazon_sales"})
        self.assertEqual("amazon_sales", run.call_args.kwargs["what"])          # a kit dataset's name stays as typed
        with self.assertRaisesRegex(ValueError, "letters, digits and _"):
            screen._run("kit.data_load", {"what": "x"}, {"what": "x", "schema": "bad name"})

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_choose_your_data_reads_the_database_again_after_a_load(self):
        understand = importlib.import_module("exakit_guide.screens.understand")
        card = understand.ChooseData.__new__(understand.ChooseData)
        with mock.patch.object(card, "refresh"), mock.patch.object(card, "_load_options") as load:
            card.on_session("data")
            for thread in __import__("threading").enumerate():
                if thread is not __import__("threading").current_thread() and thread.daemon:
                    thread.join(timeout=2)
        load.assert_called_once()


class SeveralTablesTest(unittest.TestCase):
    """Choose your data takes any number of tables from any mix of kit datasets, your own tables and external
    sources: each is loaded with its own cell and kept, the column map moves between them, and Semantic views
    starts with their schemas ticked. One table chosen runs the cells it always ran."""

    def setUp(self):
        self.understand = importlib.import_module("exakit_guide.screens.understand")
        self.session = self.understand.SESSION
        self.kept = (self.session._ns, self.session.chosen, self.session.chosen_n, list(self.session.code))
        self.session._ns = {"nb": None, "workflow_id": "wf"}
        self.ran: list[tuple[str, dict]] = []
        tables = {"amazon": "AMAZON.ORDER_LINES", "MY_DATA.TARGETS": "MY_DATA.TARGETS",
                  "VS_LOGISTICS.COURIER_DAILY": "VS_LOGISTICS.COURIER_DAILY", "VS_LOGISTICS.STATE_LOGISTICS": None}

        def run(action_id, session=None, **values):
            self.ran.append((action_id, values))
            ns = self.session._ns
            if action_id in ("data.sample", "data.table", "data.source"):
                key = values.get("dataset_id") or values.get("table") or values.get("source")
                if tables[key] is None:
                    raise ValueError("the source refused the read\nmore")
                ns[self.understand.actions.ACTIONS[action_id].result] = mock.Mock(fact_table=tables[key])
            elif action_id == "data.several":
                ns["chosen_tables"] = {}
            elif action_id == "data.keep":
                ns["chosen_tables"][values["table"]] = ns[values["data"].expr]
            elif action_id in ("data.switch", "understand.switch"):
                ns["chosen_data"] = ns["chosen_tables"][values["table"]]
            elif action_id == "data.choose":
                ns["chosen_data"] = ns[values["data"].expr]
            elif action_id == "kit.approved":
                return [{"id": "amazon", "table": "AMAZON.ORDER_LINES", "version": 1}]
            return None

        patch = mock.patch.object(self.understand.actions, "run", side_effect=run)
        patch.start()
        self.addCleanup(patch.stop)
        self.addCleanup(self._restore)
        self.card = self.understand.ChooseData.__new__(self.understand.ChooseData)
        self.card.__dict__.update(samples=[{"id": "amazon", "label": "Amazon sales"}], sources=["VS_LOGISTICS"], rows={},
                                  kit_said="", source_tables={}, forms={}, parsed={}, connectors=[], done=False)

    def _restore(self):
        self.session._ns, self.session.chosen, self.session.chosen_n, self.session.code = self.kept

    def use(self, values):
        with mock.patch.object(self.session, "changed"):
            self.card.on_use(values)
        ran = [a for a, _v in self.ran if a != "kit.approved"]      # (a refused load looks its table up there)
        if not ran or ran[-1] != "data.remember":     # nothing opened: nothing to note
            self.assertNotIn("data.remember", ran)
            return ran
        self.assertEqual([e["table"] for e in self.session.chosen], self.ran[-1][1]["tables"], "noted for 01_explore")
        return ran[:-1]

    def test_one_table_runs_the_cells_it_always_ran(self):
        for values in ({"kind": "sample", "sample": "amazon"}, {"kind": ["sample"], "sample": ["amazon"]}):
            self.ran.clear()
            self.assertEqual(["data.sample", "data.choose"], self.use(values))
            self.assertEqual(["AMAZON.ORDER_LINES"], [e["table"] for e in self.session.chosen])

    def test_tables_of_every_kind_are_loaded_kept_and_the_first_is_worked_on(self):
        ran = self.use({"kind": ["sample", "file", "source"], "sample": ["amazon"], "own": ["tbl:MY_DATA.TARGETS"],
                        "src_schema": ["VS_LOGISTICS"], self.card._tid("VS_LOGISTICS"): ["COURIER_DAILY", "STATE_LOGISTICS"]})
        self.assertEqual(["data.several", "data.sample", "data.keep", "data.table", "data.keep", "data.source", "data.keep",
                          "data.source", "data.switch", "data.prepare"], ran)
        self.assertEqual(["AMAZON.ORDER_LINES", "MY_DATA.TARGETS", "VS_LOGISTICS.COURIER_DAILY"],
                         [e["table"] for e in self.session.chosen])
        self.assertEqual("AMAZON.ORDER_LINES", self.session.source.fact_table)
        # one that could not be read is named with the reason's first line; the others are used
        self.assertEqual(["VS_LOGISTICS.STATE_LOGISTICS (the source refused the read)"], self.card.failed)

    def test_adding_in_explore_keeps_the_tables_there_and_works_on_the_new_one(self):
        """01_explore's Add a source or table: what is ticked joins the tables already chosen (each kept by name, no
        new dict), the first one added is worked on next, and the quickstart's way on is not shown."""
        self.session._ns["chosen_tables"] = {"AMAZON.ORDER_LINES": mock.Mock(fact_table="AMAZON.ORDER_LINES")}
        self.session.chosen = [{"label": "Amazon", "table": "AMAZON.ORDER_LINES", "variable": None, "rows": None, "broken": None}]
        self.card.ADDING = True
        ran = self.use({"kind": ["source"], "src_schema": ["VS_LOGISTICS"], self.card._tid("VS_LOGISTICS"): ["COURIER_DAILY"]})
        self.assertEqual(["data.source", "data.keep", "data.switch", "data.prepare"], ran,
                         "the tables there stay (no data.several); all of them are drafted in the background")
        self.assertEqual(["VS_LOGISTICS.COURIER_DAILY", "AMAZON.ORDER_LINES"], [e["table"] for e in self.session.chosen])
        self.assertEqual({"AMAZON.ORDER_LINES", "VS_LOGISTICS.COURIER_DAILY"}, set(self.session._ns["chosen_tables"]))
        with self.assertRaisesRegex(ValueError, "Nothing new"):
            self.use({"kind": ["source"], "src_schema": ["VS_LOGISTICS"], self.card._tid("VS_LOGISTICS"): ["COURIER_DAILY"]})

    def test_the_flow_shows_each_source_its_approved_maps_and_the_steps(self):
        card = self.understand.Understand.__new__(self.understand.Understand)
        card.__dict__.update(map=None, views=mock.Mock(links=[{"from": "A", "to": "B"}], models=[{"model": "sales_360", "kit": True}]),
                             sources=None, adding=False, kinds={"VS_LOGISTICS": "Snowflake"}, approved={"AMAZON.ORDER_LINES"})
        self.session.chosen = [{"table": t} for t in ("AMAZON.ORDER_LINES", "VS_LOGISTICS.COURIER_DAILY", "VS_LOGISTICS.STATE_LOGISTICS")]
        flow = card._flow()
        self.assertEqual([("this database", "AMAZON", "done", "1 table · 1 approved"), ("Snowflake", "VS_LOGISTICS", "now", "2 tables · 0 approved")],
                         [(s["kind"], s["label"], s["state"], s["sub"]) for s in flow["sources"]])
        steps = {s["label"]: (s["state"], s["sub"]) for s in flow["steps"]}
        self.assertEqual(("now", "1 of 3 approved"), steps["Column maps"])
        self.assertEqual(("done", "1 added"), steps["Links"])
        self.assertEqual(("done", "saved"), steps["Data map"])
        self.assertEqual("src_add", flow["add"]["action"])

    def test_a_live_table_waits_for_a_click_and_only_the_chosen_tables_are_linked(self):
        explore = importlib.import_module("exakit_guide.screens.explore")
        card = explore.Prepare.__new__(explore.Prepare)
        card.__dict__.update(findings=None, typed=None, joined=None, kit_said="", flash=None)
        card.refresh = lambda: None
        self.session._ns["dataset"] = mock.Mock(source="snowflake_sales", fact_table="VS_SALES.ORDERS")
        with mock.patch.object(card, "_check") as check:
            card.on_session("dataset")
            check.assert_not_called()
            self.assertIn("Run it now", json.dumps(card.build()))
            card.on_run_live({})
            check.assert_called_once()
        part = self.understand._ViewsPart.__new__(self.understand._ViewsPart)
        part.__dict__.update(owner=None, tables=[], columns={}, models=[], links=None, loading=False, error=None,
                             ticked=set(), gen=0, link_gen=0, flash=None, fill=None, fill_n=0)
        self.session.chosen = [{"table": "AMAZON.ORDER_LINES"}, {"table": "VS_LOGISTICS.COURIER_DAILY"}]
        every = types.SimpleNamespace(table_rows=[{"table": t, "origin_label": "x", "map": "approved v1", "rows_shown": ""}
                                                  for t in ("AMAZON.ORDER_LINES", "VS_LOGISTICS.COURIER_DAILY", "TPCH.ORDERS")],
                                      column_rows=[{"table": "TPCH.ORDERS", "column": "O_ORDERKEY"}])
        with mock.patch.object(self.understand.actions, "run", side_effect=lambda a, **k: every if a == "understand.map" else
                               ({"links": [], "checked": 1, "statements": 1} if a == "semantic.links_tables" else [])):
            part._load()
        self.assertEqual(["AMAZON.ORDER_LINES", "VS_LOGISTICS.COURIER_DAILY"], [t["table"] for t in part.tables],
                         "only the tables chosen, never every table of the database")
        self.assertNotIn("Semantic views", json.dumps(part.build()))

    def test_all_tables_are_reviewed_and_approved_together_with_one_publish_per_schema(self):
        """nb.schema_review shows only what needs a person (low-confidence columns, personal data); nb.approve_all
        approves each table as drafted with the changes given, publishing once per schema with its last table."""
        picker = importlib.import_module("exakit_nb.role_picker")

        def review(status, columns):
            made = mock.Mock()
            made.draft.status, made.draft.doc = status, {"columns": columns}
            made.approve.side_effect = lambda choices=None, publish=True: f"approved publish={publish} {choices}"
            made.dataset.return_value = "as it was"
            return made
        reviews = {
            "VS_S.ORDERS": review("draft", {"ID": {"role": "key", "confidence": "high"},
                                            "STATUS": {"role": "measure", "confidence": "low", "evidence": "5 distinct"}}),
            "VS_S.CUSTOMERS": review("draft", {"EMAIL": {"role": "text", "confidence": "high", "sensitive": True}}),
            "VS_S.STORES": review("approved", {"NAME": {"role": "text", "confidence": "low"}}),
            "MY_DATA.TARGETS": review("draft", {"STATE": {"role": "category", "confidence": "high"}})}
        found = picker.schema_review(reviews)
        self.assertEqual([("VS_S.ORDERS", "STATUS", "measure", "5 distinct")],
                         [(c["table"], c["column"], c["role"], c["evidence"]) for c in found["check"]],
                         "only the guesses of tables still to approve")
        self.assertEqual([{"table": "VS_S.CUSTOMERS", "column": "EMAIL"}], found["sensitive"])
        self.assertEqual((["VS_S.STORES"], 4), (found["approved"], found["fine"]))
        with mock.patch("builtins.print"):
            done = picker.approve_all(reviews, {"vs_s.orders": {"STATUS": "category"}})
        self.assertEqual({"VS_S.ORDERS": "approved publish=False {'STATUS': 'category'}",
                          "VS_S.CUSTOMERS": "approved publish=True None",     # the schema's last table publishes it
                          "VS_S.STORES": "as it was",                          # approved already: left alone
                          "MY_DATA.TARGETS": "approved publish=True None"}, done)
        reviews["VS_S.ORDERS"].approve.side_effect = ValueError("STATUS sits in two slots")
        with self.assertRaisesRegex(ValueError, "VS_S.ORDERS: STATUS sits in two slots"):
            picker.approve_all(reviews)

    def test_the_card_offers_all_tables_at_once_and_sends_only_the_changed_columns(self):
        card = self.understand.ColumnMap.__new__(self.understand.ColumnMap)
        card.__dict__.update(all_review=None, kit_said="", flash=None, seen={})
        self.session.chosen = [{"table": "VS_S.ORDERS"}, {"table": "VS_S.CUSTOMERS"}]
        self.assertEqual("map_all", card._all_blocks(2)[0]["items"][0]["id"])
        self.assertEqual([], card._all_blocks(1), "one table left: its own tab approves it")
        card.all_review = {"tables": ["VS_S.ORDERS", "VS_S.CUSTOMERS"], "approved": [], "fine": 7,
                           "check": [{"table": "VS_S.ORDERS", "column": "STATUS", "role": "measure", "evidence": "5 distinct"},
                                     {"table": "VS_S.ORDERS", "column": "QTY", "role": "measure", "evidence": ""}],
                           "sensitive": [{"table": "VS_S.CUSTOMERS", "column": "EMAIL"}]}
        text = json.dumps(card._all_blocks(2))
        for needle in ("ORDERS.STATUS (5 distinct)", "CUSTOMERS.EMAIL", "7 other columns look fine", "Approve all 2 tables"):
            self.assertIn(needle, text)
        self.session._ns["chosen_data"] = mock.Mock(fact_table="VS_S.ORDERS")
        self.ran.clear()
        with mock.patch.object(card, "_reload_saved"), mock.patch.object(self.session, "changed_later") as later:
            card.on_map_all_approve({"all:VS_S.ORDERS:STATUS": "category", "all:VS_S.ORDERS:QTY": "measure"})
        approve = next(v for a, v in self.ran if a == "map.approve_all")
        self.assertEqual(({"VS_S.ORDERS": {"STATUS": "category"}}, "VS_S.ORDERS"), (approve["choices"], approve["table"]))
        later.assert_called_once_with("dataset", card)
        self.assertIsNone(card.all_review)

    def test_the_cards_run_with_the_rules_the_notebook_set_else_the_kits_own(self):
        actions = importlib.import_module("exakit_guide.actions")
        self.session._ns = {"nb": None}
        ns = self.session.namespace()
        self.assertEqual(({}, {}, 0.99), (ns["ROLE_RULES"], ns["ASK_RULES"], ns["GIVES_IT_AWAY"]), "nothing set: the kit's own")
        self.assertIn("unknown*", ns["PLACEHOLDER_VALUES"])
        self.assertIsNone(self.session.your_rules("ROLE_RULES"))
        self.session._ns["ROLE_RULES"] = {"CATEGORY_DISTINCT": 100}
        self.assertIn("CATEGORY_DISTINCT = 100", self.session.your_rules("ROLE_RULES", "LINK_RULES")["v"])
        self.assertEqual({"CATEGORY_DISTINCT": 100}, self.session.namespace()["ROLE_RULES"], "what the notebook set stays")
        for action_id, name in (("map.review", "rules=ROLE_RULES"), ("semantic.check_link", "rules=LINK_RULES"),
                                ("explore.checks", "placeholder_values=PLACEHOLDER_VALUES"), ("explore.typed", "date_formats=DATE_FORMATS"),
                                ("map.leakage", "pure=GIVES_IT_AWAY"), ("ask.model", "rules=ASK_RULES"),
                                ("ask.rules", "rules=DRAFT_RULES"), ("ask.insights", "rules=INSIGHT_RULES"),
                                ("share.starter", "rules=STARTER_RULES"), ("share.board_draft", "DASHBOARD_RULES"),
                                ("data.own_file", "rules=LOAD_RULES")):
            with self.subTest(action=action_id):
                self.assertIn(name, actions.ACTIONS[action_id].code)

    def test_nothing_ticked_and_nothing_loaded_are_said(self):
        with self.assertRaisesRegex(ValueError, "Tick at least one"):
            self.use({"kind": ["sample"], "sample": []})
        with self.assertRaisesRegex(ValueError, "refused the read"):         # one table: the kit's own reason
            self.use({"kind": ["source"], "src_schema": ["VS_LOGISTICS"], self.card._tid("VS_LOGISTICS"): ["STATE_LOGISTICS"]})

    def test_a_new_connection_left_unfinished_does_not_stop_the_rest(self):
        ran = self.use({"kind": ["sample", "source"], "sample": ["amazon"], "src_schema": ["__connect__"]})
        self.assertEqual(["data.sample", "data.choose"], ran)

    def test_a_file_and_a_new_connection_ticked_together_are_both_done_by_one_button(self):
        """Load a new file and New connection ticked at once: the one button loads the file and connects the source.
        A connection that fails is named with its reason and the file is still used; alone, its reason is the error.
        A password is used as pasted, without a blank a copy picked up around it."""
        nb = importlib.import_module("exakit_nb")
        self.card.forms = {"postgresql": nb.connector_inputs("postgresql")}
        self.card.connectors, self.card.connector, self.card.sources = nb.connectors(), "postgresql", []
        self.assertTrue(self.card._ready())
        values = {"kind": ["file", "source"], "own": ["tbl:MY_DATA.TARGETS"], "src_schema": ["__connect__"]}
        with mock.patch.object(self.card, "_connect", return_value="VS_LOGISTICS") as connect, \
                mock.patch.object(self.card, "_load_options"):
            ran = self.use({**values, "table": "COURIER_DAILY"})
        connect.assert_called_once()
        self.assertEqual(["data.several", "data.table", "data.keep", "data.source", "data.keep", "data.switch", "data.prepare"], ran)
        self.assertEqual(["MY_DATA.TARGETS", "VS_LOGISTICS.COURIER_DAILY"], [e["table"] for e in self.session.chosen])
        self.ran.clear()
        self.card.connector = "postgresql"
        box = self.card._cf()                              # the connections box starts afresh after a connect
        self.assertNotEqual("src_schema", box)
        values = {"kind": ["file", "source"], "own": ["tbl:MY_DATA.TARGETS"], box: ["__connect__"]}
        with mock.patch.object(self.card, "_connect", side_effect=RuntimeError("the source refused the password\nmore")):
            ran = self.use(values)
            self.assertEqual(["data.table", "data.choose"], ran)                       # the file's table is used
            self.assertEqual(["the new connection (the source refused the password)"], self.card.failed)
            with self.assertRaisesRegex(RuntimeError, "refused the password"):         # alone: its reason is the error
                self.use({"kind": ["source"], box: ["__connect__"]})
        f = self.card._fid
        typed = {"src_name": "sales", f("postgresql", "host"): "db.example.com", f("postgresql", "database"): "shop",
                 f("postgresql", "user"): "reader", f("postgresql", "how"): "manual", f("postgresql", "password"): "  s3cret \t"}
        self.assertEqual("s3cret", self.card._source_inputs(typed)[3])

    def test_a_source_just_connected_opens_its_tables(self):
        """A new connection has no table ticked yet. With a few tables all of them are opened (it was connected to be
        used: no "set SOURCE" to stop on); with many it is connected and listed, and says to tick the ones to use."""
        nb = importlib.import_module("exakit_nb")
        self.card.forms, self.card.connectors, self.card.connector, self.card.sources = {"postgresql": nb.connector_inputs("postgresql")}, nb.connectors(), "postgresql", []

        def listed(names):
            def load():
                self.card.source_tables = {"VS_LOGISTICS": [{"value": n, "label": n} for n in names]}
            return load

        with mock.patch.object(self.card, "_connect", return_value="VS_LOGISTICS"), \
                mock.patch.object(self.card, "_load_options", side_effect=listed(["COURIER_DAILY", "STATE_LOGISTICS"])):
            self.use({"kind": ["source"], "src_schema": ["__connect__"]})
        self.assertEqual(["VS_LOGISTICS.COURIER_DAILY"], [e["table"] for e in self.session.chosen],
                         "both were asked for; the stand-in source refuses the second")
        self.assertEqual([("data.source", {"source": "VS_LOGISTICS.COURIER_DAILY"}), ("data.source", {"source": "VS_LOGISTICS.STATE_LOGISTICS"})],
                         [(a, v) for a, v in self.ran if a == "data.source"])
        self.ran.clear()
        self.card.connector = "postgresql"
        many = [f"T{i}" for i in range(self.card.MANY_TABLES + 1)]
        with mock.patch.object(self.card, "_connect", return_value="VS_LOGISTICS"), \
                mock.patch.object(self.card, "_load_options", side_effect=listed(many)):
            self.use({"kind": ["source"], self.card._cf(): ["__connect__"]})
        self.assertEqual([], [a for a, _v in self.ran if a == "data.source"])
        self.assertIn("VS_LOGISTICS is connected and has 11 tables: tick the ones to use", self.card.failed[0])

    def test_the_card_always_has_a_button(self):
        """Before a data source is chosen for a new connection the plain button is there (the rest ticked is usable);
        once it is chosen, Connect does everything ticked."""
        self.card.__dict__.update(loading=False, own=[], source_tables={})
        self.card.samples = [{"id": "amazon", "label": "Amazon sales", "loaded": True}]
        actions_of = lambda: next(b for b in self.card.build() if b["t"] == "choice")["actions"]
        self.assertEqual([("use", None)], [(a["id"], a.get("show_if")) for a in actions_of()])
        nb = importlib.import_module("exakit_nb")
        self.card.forms, self.card.connectors, self.card.connector = {"postgresql": nb.connector_inputs("postgresql")}, nb.connectors(), "postgresql"
        self.assertEqual(["test_source", "use", "use"], [a["id"] for a in actions_of()])
        self.assertEqual("Connect and use this data", actions_of()[1]["label"])

    def test_the_card_offers_ticks_and_one_use_button(self):
        self.card.__dict__.update(loading=False, own=[{"value": "tbl:MY_DATA.TARGETS", "label": "MY_DATA.TARGETS"}],
                                  source_tables={"VS_LOGISTICS": [{"value": "COURIER_DAILY", "label": "COURIER_DAILY"}]})
        self.card.samples = [{"id": "amazon", "label": "Amazon sales", "loaded": True}]
        choice = next(b for b in self.card.build() if b["t"] == "choice")
        self.assertTrue(choice["multi"])
        self.assertEqual(["sample"], choice["value"])
        ticks = {f["id"]: f for o in choice["options"] for f in o["fields"] if f.get("type") == "picks"}
        self.assertEqual({"sample", "own", "src_schema", self.card._tid("VS_LOGISTICS")}, set(ticks))
        self.assertTrue(all(isinstance(f["value"], list) for f in ticks.values()))
        self.assertEqual(1, sum(1 for a in choice["actions"] if a["id"] == "use"))     # before a new connection's last step

    def _map_card(self):
        card = self.understand.ColumnMap.__new__(self.understand.ColumnMap)
        card.kit_said = ""
        self.session._ns["role_review"] = mock.Mock(draft=mock.Mock(doc={"columns": {"A": {"sensitive": True}, "B": {}}}))
        return card

    def _built(self, card, inner=None):
        inner = inner or [{"t": "head"}, {"t": "rolemap"}, {"t": "actions", "items": [{"id": "approve"}]}]
        with mock.patch.object(card, "_blocks", return_value=[dict(b) for b in inner]):
            return card.build()

    def test_the_column_map_has_the_tables_as_tabs_and_moves_between_them(self):
        """Several tables chosen: one tab each on top of the card, saying which are approved; a click opens another
        (chosen_data = chosen_tables[...]); an approved one shows the way to the next, and the last one that all are."""
        self.use({"kind": ["sample", "file"], "sample": ["amazon"], "own": ["tbl:MY_DATA.TARGETS"]})
        card = self._map_card()
        blocks = self._built(card)
        self.assertEqual(["head", "tablepick", "aicheck", "rolemap", "actions", "linkcard"], [b["t"] for b in blocks])
        tabs = blocks[1]
        self.assertEqual(("AMAZON.ORDER_LINES", "map_switch", "2 tables · 1 approved"), (tabs["value"], tabs["action"], tabs["label"]))
        self.assertEqual([("AMAZON.ORDER_LINES", "approved"), ("MY_DATA.TARGETS", "todo")], [(i["value"], i["state"]) for i in tabs["items"]])
        step = blocks[-1]                                    # this table is approved: on to the next, under Approve
        self.assertEqual(("AMAZON.ORDER_LINES is approved", "map_next"), (step["title"], step["button"]["id"]))
        self.assertIn("1 of 2 tables approved. Next: MY_DATA.TARGETS", step["text"])
        with mock.patch.object(card, "_review") as review, mock.patch.object(self.session, "changed"):
            card.on_map_next({})
        review.assert_called_once()
        self.assertEqual("MY_DATA.TARGETS", self.session.source.fact_table)
        self.assertEqual("MY_DATA.TARGETS (MY_DATA.TARGETS)", self.session.source_label)
        self.assertIsNone(self.session.review, "another table: its own review (the card's _review reads it)")
        review = mock.Mock(draft=mock.Mock(doc={"columns": {}}))
        self.session._ns["role_review"] = review
        self.assertEqual(["head", "tablepick", "aicheck", "rolemap", "actions"], [b["t"] for b in self._built(card)])   # not approved: no way on
        with mock.patch.object(card, "_review"), mock.patch.object(self.session, "changed"):
            card.on_map_switch({tabs["field"]: "AMAZON.ORDER_LINES"})
        self.assertEqual("AMAZON.ORDER_LINES", self.session.source.fact_table)
        self.session._ns["role_review"] = review
        with mock.patch.object(card, "_approved_tables", return_value={"AMAZON.ORDER_LINES", "MY_DATA.TARGETS"}):
            built = self._built(card)
        self.assertEqual("linkcard", built[-1]["t"], [b["t"] for b in built])
        done = built[-1]
        self.assertEqual(("All 2 tables are approved", None), (done["title"], done.get("button")))
        self.assertIn("how they connect", done["text"])
        self.session.chosen = self.session.chosen[:1]                                 # one table: no tabs, no step
        self.assertEqual(["head", "aicheck", "rolemap", "actions"], [b["t"] for b in self._built(card)])

    def tearDown(self):
        self.session.ai_maps, self.session.ai_model, self.session.ai_runs = {}, None, 0

    def test_the_ai_check_is_on_top_and_only_suggests(self):
        """Check with AI asks the model set up for the kit (nb.check_roles) and shows what it would change, with why;
        nothing is saved. Without a model the bar says where to set one up; a provider's refusal is said in one line;
        another table starts without the last one's suggestions."""
        self.use({"kind": ["sample"], "sample": ["amazon"]})
        card = self._map_card()
        answers = {"kit.model": {"configured": False}}
        real = self.understand.actions.run.side_effect

        def run(action_id, session=None, **values):
            if action_id in answers:
                if isinstance(answers[action_id], Exception):
                    raise answers[action_id]
                self.ran.append((action_id, values))
                return answers[action_id]
            return real(action_id, session, **values)

        self.understand.actions.run.side_effect = run
        bar = self._built(card)[1]
        self.assertEqual(("aicheck", False, None), (bar["t"], bar["configured"], bar["items"]))
        self.assertIn("not the 1 personal-data column", bar["sees"])
        answers["kit.model"] = {"configured": True, "model_id": "m1"}
        answers["map.ai_check"] = {"roles": [{"column": "B", "kit_role": "measure", "role": "identifier", "why": "An account number."}],
                                   "slots": {"entity": "B"}, "notes": {"B": "The customer's account."}}
        self.ran.clear()
        card.on_ai_check({})
        self.assertEqual(["map.ai_check"], [a for a, _v in self.ran if a.startswith("map.")])    # asked; nothing approved
        bar = self._built(card)[1]
        self.assertEqual((True, "m1"), (bar["configured"], bar["model"]))
        self.assertEqual([{"column": "B", "to": "identifier", "from_label": self.understand.ROLE_LABELS["measure"],
                           "to_label": self.understand.ROLE_LABELS["identifier"], "why": "An account number."}], bar["items"])
        # ...and the whole answer, for the card to fill in at once: the meanings, the other choices, the descriptions
        self.assertEqual({"id": 1, "roles": {"B": "identifier"}, "slots": {"entity": "B"}, "notes": {"B": "The customer's account."},
                          "slot_labels": {"entity": self.understand.SLOT_LABELS["entity"][0]}}, bar["fill"])
        answers["map.ai_check"] = RuntimeError("401 the provider refused the key\nmore")
        card.on_ai_check({})
        bar = self._built(card)[1]
        self.assertEqual(("401 the provider refused the key", None, None), (bar["error"], bar["items"], bar["fill"]))
        answers["map.review"] = None
        answers["map.draft"] = None
        answers["map.leakage"] = []
        self.session._ns["role_review"].draft.status = "draft"
        card._review()
        self.assertEqual(1, (card.ai or {}).get("id"), "a table keeps its answer: opening it again shows it")
        self.session.ai_maps.clear()
        card._review()
        self.assertIsNone(card.ai)

    INPUTS = {"tables": {
        "AMAZON.ORDER_LINES": {"key": ["ORDER_LINE_ID"], "grain": "one order line", "columns": [
            {"name": "ORDER_LINE_ID", "role": "key", "note": ""}, {"name": "ORDER_ID", "role": "identifier", "note": ""},
            {"name": "SHIP_STATE", "role": "category", "note": "", "values": ["CA", "NY"]},
            {"name": "STATUS", "role": "category", "note": "", "values": ["COMPLETED", "CANCELLED"]},
            {"name": "AMOUNT", "role": "measure", "note": "incl. tax"}]},
        "MY_DATA.TARGETS": {"key": ["STATE"], "grain": "", "columns": [
            {"name": "STATE", "role": "key", "note": ""}, {"name": "TARGET", "role": "measure", "note": ""}]}},
        "missing": ["MY_DATA.DRAFTS"], "saved": False, "grains": {}, "table_notes": {}, "links": [], "starts": [],
        "metrics": [], "instructions": [], "description": ""}

    def _views(self, inputs=None):
        self.session.chosen = [{"table": t} for t in ("AMAZON.ORDER_LINES", "MY_DATA.TARGETS", "MY_DATA.DRAFTS")]
        self.sent = []
        answers = {"semantic.inputs": inputs or json.loads(json.dumps(self.INPUTS))}
        self.answers = answers
        self.understand.actions.run.side_effect = lambda action_id, session=None, **values: self.sent.append((action_id, values)) or answers[action_id]
        views = self.understand.SemanticViews.__new__(self.understand.SemanticViews)
        views.__dict__.update(n=0, facts={"tables": {}, "missing": []}, dm=views._empty(), checked={}, warnings=[],
                              result_text="", preview_text="", saved=False, loading=True, error=None, flash=None)
        views.refresh = lambda: None
        views._load()
        return views

    def _build(self, views):
        with mock.patch.object(self.understand.actions, "code", return_value=""):
            return views.build()

    def test_the_data_map_opens_from_your_column_maps_and_asks_what_semantic_views_needs(self):
        """No query while it opens: the approved column maps and what was saved before, read from this computer. It
        asks for exactly what Semantic Views needs - the grain, the links and their type, where questions start,
        metrics, rules - and nothing is found or guessed for you."""
        views = self._views()
        self.assertEqual([("semantic.inputs", {"tables": ["AMAZON.ORDER_LINES", "MY_DATA.TARGETS", "MY_DATA.DRAFTS"]})], self.sent)
        blocks = self._build(views)
        heads = [b["v"] for b in blocks if b["t"] == "subhead"]
        self.assertEqual(["1 · Tables", "2 · Relationships", "3 · Entry points", "4 · Metrics", "5 · Business rules"], heads)
        self.assertEqual(("head", "Semantic model"), (blocks[0]["t"], blocks[0]["title"]))
        self.assertEqual("Advanced", next(b for b in blocks if b["t"] == "details")["title"], "advanced settings start closed")
        self.assertIn("MY_DATA.DRAFTS", next(b["v"] for b in blocks if b["t"] == "msg"), "a table to approve first is named")
        grains = {f["id"]: f["value"] for b in blocks if b["t"] == "fields" for g in b["items"] if g.get("type") == "group"
                  for f in g["fields"] if f["id"].startswith("dmgrain")}
        self.assertEqual({"dmgrain1:AMAZON.ORDER_LINES": "one order line", "dmgrain1:MY_DATA.TARGETS": ""}, grains)
        self.assertIn("No relationships yet.", json.dumps(blocks))
        keys = next(f for b in blocks if b["t"] == "fields" for g in b["items"] if g["id"] == "dm_new_link" for f in g["fields"]
                    if f["id"] == "dm_to_col")["options_from"]["map"]["MY_DATA.TARGETS"]
        self.assertEqual("STATE (key)", keys[0]["label"], "a link ends on the other table's key, listed first")
        self.assertFalse(any(a in ("semantic.check_link", "semantic.draft") for a, _ in self.sent), "nothing is checked or guessed by itself")

    def test_your_links_metrics_and_rules_go_to_semantic_views_as_you_said_them(self):
        views = self._views()
        for bad, said in (({"dm_from_table": "MY_DATA.TARGETS"}, "Pick the table and the column"),
                          ({"dm_from_table": "MY_DATA.TARGETS", "dm_from_col": "STATE", "dm_to_table": "MY_DATA.TARGETS", "dm_to_col": "STATE"}, "between two tables")):
            with self.assertRaisesRegex(ValueError, said):
                views.on_dm_add_link(bad)
        views.on_dm_add_link({"dm_from_table": "AMAZON.ORDER_LINES", "dm_from_col": "SHIP_STATE", "dm_to_table": "MY_DATA.TARGETS",
                              "dm_to_col": "STATE", "dm_link_type": "MANY_TO_ONE"})
        self.assertEqual([("AMAZON.ORDER_LINES.SHIP_STATE", "MY_DATA.TARGETS.STATE", "MANY_TO_ONE", "you")],
                         [(l["from"], l["to"], l["type"], l["by"]) for l in views.links])
        with self.assertRaisesRegex(ValueError, "Say which values"):
            views.on_dm_add_metric({"dm_m_table": "AMAZON.ORDER_LINES", "dm_m_name": "x", "dm_m_how": "sum", "dm_m_column": "AMOUNT",
                                    "dm_m_where": "STATUS"})
        views.on_dm_add_metric({"dm_m_table": "AMAZON.ORDER_LINES", "dm_m_name": "Completed revenue", "dm_m_how": "sum",
                                "dm_m_column": "AMOUNT", "dm_m_where": "STATUS", "dm_m_values": "COMPLETED, Shipped"})
        self.assertIn("Shipped is not among the values", views.flash["v"], "a value the column map never saw is pointed out")
        self.assertEqual({"table": "AMAZON.ORDER_LINES", "name": "completed_revenue", "how": "sum", "column": "AMOUNT",
                          "where": {"column": "STATUS", "values": ["COMPLETED", "Shipped"]}, "about": ""}, views.dm["metrics"][0])
        n = views.n
        form = {f"dmlinks{n}:": ["0"], f"dmltype{n}:0": "ONE_TO_ONE", f"dmlnote{n}:0": " the  state ", f"dmmetrics{n}:": ["0"],
                f"dmgrain{n}:MY_DATA.TARGETS": "one state's target", f"dmstarts{n}:": ["AMAZON.ORDER_LINES"],
                f"dmrule{n}:0": "Revenue includes tax", f"dmabout{n}:": "Orders and targets"}
        self.answers["semantic.save_map"] = mock.Mock(sql=["EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('all_data')"])
        views.on_sv_preview(form)
        action, given = self.sent[-1]
        self.assertEqual("semantic.save_map", action)
        self.assertEqual(([{"from": "AMAZON.ORDER_LINES.SHIP_STATE", "to": "MY_DATA.TARGETS.STATE", "type": "ONE_TO_ONE", "note": "the state",
                            "join": "LEFT"}],
                          {"MY_DATA.TARGETS": "one state's target"}, ["AMAZON.ORDER_LINES"], ["Revenue includes tax"], "Orders and targets", True),
                         (given["links"], given["grains"], given["starts"], given["instructions"], given["description"], given["preview"]))
        self.assertEqual("completed_revenue", given["metrics"][0]["name"])
        self.assertIn("CREATE_MODEL", views.preview_text)
        # an unticked link is removed; Check with data runs only when pressed, one bounded count per link
        self.answers["semantic.check_link"] = {"links": [{"from": "AMAZON.ORDER_LINES.SHIP_STATE", "to": "MY_DATA.TARGETS.STATE", "found": 48, "checked": 50}]}
        views.on_dm_check({**form})
        self.assertEqual(("semantic.check_link", ["AMAZON.ORDER_LINES.SHIP_STATE=MY_DATA.TARGETS.STATE"]), (self.sent[-1][0], self.sent[-1][1]["check"]))
        self.assertIn("48 of 50", views.checked["AMAZON.ORDER_LINES.SHIP_STATE=MY_DATA.TARGETS.STATE"])
        self.answers["semantic.save_map"] = mock.Mock(views=["SEM_ALL_DATA.ORDER_LINES"],
                                                      found={"warnings": ["ORDER_LINES: SEMANTIC_DDL_095 metric exists"], "notes": []})
        self.answers["semantic.validate"] = {"issues": [{"severity": "ERROR", "object_type": "METRIC", "object": "completed_revenue",
                                                        "rule": "SEMANTIC_MODEL_076", "message": "declares DECIMAL, returns DOUBLE"}],
                                             "types": [], "suggestions": [], "errors": 1}
        views.on_sv_publish({f"dmlinks{views.n}:": [], f"dmmetrics{views.n}:": ["0"], f"dmhide{views.n}:AMAZON.ORDER_LINES": ["SHIP_STATE"]})
        saved = next(given for action, given in reversed(self.sent) if action == "semantic.save_map")
        self.assertEqual([], saved["links"], "unticked: removed from your data map")
        self.assertEqual({"AMAZON.ORDER_LINES": ["SHIP_STATE"]}, saved["hidden"], "hidden in answers by Semantic Views' MASK")
        self.assertEqual("semantic.validate", self.sent[-1][0], "Semantic Views checks it right after the save")
        built = json.dumps(self._build(views))
        self.assertIn("SEMANTIC_MODEL_076", built)
        self.assertIn('"label": "Validate"', built)
        self.assertEqual(["ORDER_LINES: SEMANTIC_DDL_095 metric exists"], views.warnings, "what Semantic Views said, word for word")
        self.assertTrue(views.saved)

    def test_more_from_semantic_views_reads_only_when_asked_and_records_decisions(self):
        inputs = json.loads(json.dumps(self.INPUTS))
        inputs["saved"] = True
        views = self._views(inputs)
        self.assertIn("More from Semantic Views", json.dumps(self._build(views)))
        self.assertEqual(["semantic.inputs"], [a for a, _ in self.sent], "nothing of it is read until a button is pressed")
        self.answers["semantic.suggestions"] = [{"SUGGESTION_ID": 4, "OBJECT_NAME": "completed_revenue", "REVIEW_STATUS": "PENDING"}]
        self.answers["semantic.review"] = {"status": "CERTIFIED"}
        views.on_dm_suggestions({})
        with self.assertRaisesRegex(ValueError, "Say why"):
            views.on_dm_review_send({"dm_review_id": "4", "dm_review_decision": "CERTIFIED", "dm_review_note": " "})
        views.on_dm_review_send({"dm_review_id": "4", "dm_review_decision": "REJECTED", "dm_review_note": "counts tax twice"})
        self.assertIn(("semantic.review", {"suggestion": 4, "decision": "REJECTED", "note": "counts tax twice"}), self.sent)
        self.answers["semantic.totals_store"] = {"table": "EXAKIT_TOTALS.T", "name": "t"}
        self.answers["semantic.totals_list"] = []
        views.on_dm_totals_store({"dm_t_view": "ORDER_LINES", "dm_t_metrics": "total_amount, order_lines_count", "dm_t_dimensions": "ship_state",
                                  "dm_t_max_age": "6 HOURS"})
        self.assertIn(("semantic.totals_store", {"view": "ORDER_LINES", "metrics": ["total_amount", "order_lines_count"],
                                                 "dimensions": ["ship_state"], "max_age": "6 HOURS"}), self.sent)

    def test_your_words_and_the_two_sources_choices_reach_semantic_views(self):
        views = self._views()
        with self.assertRaisesRegex(ValueError, "Name the field"):
            views.on_dm_add_words({"dm_syn_field": "total_amount"})
        views.on_dm_add_words({"dm_syn_field": "Total_Amount", "dm_syn_words": "sales, revenue"})
        views.on_dm_add_words({"dm_syn_field": "total_amount", "dm_syn_words": "revenue, turnover"})
        self.assertEqual({"total_amount": ["sales", "revenue", "turnover"]}, views.dm["synonyms"])
        self.answers["semantic.save_map"] = mock.Mock(sql=["x"])
        views.on_sv_preview({})
        self.assertEqual({"total_amount": ["sales", "revenue", "turnover"]}, self.sent[-1][1]["synonyms"])
        base = {"sv_fuse_table": "AMAZON.ORDER_LINES", "sv_fuse_other": "VS_LAKE.ORDER_LINES"}
        with self.assertRaisesRegex(ValueError, "pairing the ids"):
            views._fusion_inputs({**base, "sv_fuse_how": "mapped"})
        found = views._fusion_inputs({**base, "sv_fuse_how": "split", "sv_fuse_split_column": "order_date", "sv_fuse_split_at": "2026-01-01"})
        self.assertEqual((None, (("at", "2026-01-01"), ("column", "ORDER_DATE"))), found[5:])
        self.answers["semantic.fusion_doc"] = {"entities": {}}
        self.answers["semantic.fuse_check"] = {"status": "ok", "dry_run": True}
        views.on_sv_fuse_check({**base, "sv_fuse_how": "mapped", "sv_fuse_xref": "CRM.XREF", "sv_fuse_local": "account_id",
                                "sv_fuse_semantic": "customer_id"})
        drawn = next(given for action, given in self.sent if action == "semantic.fusion_doc")
        self.assertEqual(({"table": "CRM.XREF", "local": "ACCOUNT_ID", "key": "CUSTOMER_ID"}, None), (drawn["mapping"], drawn["split"]))

    def test_one_button_fills_every_table_and_drafts_the_data_map_without_reading_a_row(self):
        """Fill everything in with AI: each chosen table's column map answer (kept per table), then one call drafting
        the data map - grains, links with their type, starts, metrics, rules - from names, roles, notes and known values.
        No value scan, nothing approved or saved. A part that fails is named, the rest stands."""
        self.use({"kind": ["sample", "file"], "sample": ["amazon"], "own": ["tbl:MY_DATA.TARGETS"]})
        self.session.ai_maps, self.session.ai_model, self.session.ai_runs = {}, None, 0
        self.addCleanup(lambda: self.session.__dict__.update(ai_maps={}, ai_model=None, ai_runs=0))
        draft = {"description": "Orders and targets.", "grains": {"MY_DATA.TARGETS": "one state's target"}, "table_notes": {},
                 "links": [{"from": "AMAZON.ORDER_LINES.SHIP_STATE", "to": "MY_DATA.TARGETS.STATE", "type": "MANY_TO_ONE", "note": "Same state.", "by": "ai"}],
                 "starts": ["AMAZON.ORDER_LINES"], "metrics": [], "instructions": ["Amounts include tax."], "refused": []}
        real, ran = self.understand.actions.run.side_effect, []

        def run(action_id, session=None, **values):
            ran.append(action_id)
            if action_id == "kit.model":
                return {"configured": True, "model_id": "m1"}
            if action_id in ("map.reviews", "map.review_keep"):
                return None
            if action_id == "map.ai_together":
                if values["table"] == "MY_DATA.TARGETS":
                    raise RuntimeError("429 too many requests\nmore")
                return {"roles": [{"column": "B", "kit_role": "measure", "role": "identifier", "why": "A code."}],
                        "slots": {"entity": "B"}, "notes": {"B": "x", "C": "y"}}
            if action_id == "semantic.draft":
                return draft
            return real(action_id, session, **values)

        self.understand.actions.run.side_effect = run
        card = self.understand.AiHelp.__new__(self.understand.AiHelp)
        card.said, card.failed = [], []
        heard = []
        with mock.patch.object(self.session, "changed", side_effect=lambda what, source=None: heard.append(what)):
            card.on_ai_all({})
        self.assertEqual(["source", "ai"], heard)
        self.assertNotIn("semantic.check_link", ran, "no value scan")
        self.assertEqual(1, ran.count("semantic.draft"), "one call for the whole data map")
        self.assertEqual(["1 column map (1 meaning changed, 2 descriptions)", "your data map (1 links, 1 rules, 1 grains)"], card.said)
        self.assertEqual(["MY_DATA.TARGETS (429 too many requests)"], card.failed)
        self.assertFalse([a for a in ran if a in ("map.approve", "semantic.save_map")], "it fills in; it approves and saves nothing")
        self.assertEqual("ai_all", card.build()[1]["items"][0]["id"])
        # the data map card takes the AI's suggestions where you said nothing; what you said stays
        inputs = json.loads(json.dumps(self.INPUTS))
        inputs["grains"] = {"MY_DATA.TARGETS": "yours"}
        views = self._views(inputs)
        views.on_session("ai")
        self.assertEqual(({"MY_DATA.TARGETS": "yours"}, ["ai"], ["AMAZON.ORDER_LINES"], "Orders and targets."),
                         (views.dm["grains"], [l["by"] for l in views.links], views.dm["starts"], views.dm["description"]))
        self.assertIn("suggested by AI", json.dumps(self._build(views)))
        self.understand.actions.run.side_effect = lambda action_id, session=None, **values: {"configured": False}
        self.assertEqual(["head", "msg"], [b["t"] for b in card.build()], "without a model: no button, one line saying so")
        self.session._ns["chosen_data"] = None
        with self.assertRaisesRegex(ValueError, "Choose your data"):
            card.on_ai_all({})


class OneConnectionTest(unittest.TestCase):
    """The cards share the notebook's one database connection, and a database session takes one request at a time
    (pyexasol: "Connection cannot be shared between multiple threads sending requests simultaneously"). A button's
    work and the cards' background reads take turns, and the connection is never closed under running work."""

    def test_actions_from_two_threads_take_turns_and_release_waits(self):
        import threading
        import time

        session_mod = importlib.import_module("exakit_guide.session")
        actions = importlib.import_module("exakit_guide.actions")
        session = session_mod.Session()
        inside, most, order = [0], [0], []

        class Conn:
            closed = False

            def execute(self, _sql):
                inside[0] += 1
                most[0] = max(most[0], inside[0])
                time.sleep(0.05)
                inside[0] -= 1
                if self.closed:
                    raise RuntimeError("used after close")

            def close(self):
                order.append("closed")
                self.closed = True

        session._ns = {"nb": None, "connection": Conn()}
        work = lambda: actions.run_text("connection.execute('SELECT 1')", session)
        threads = [threading.Thread(target=work) for _ in range(4)] + [threading.Thread(target=session.release)]
        for t in threads[:4]:
            t.start()
        time.sleep(0.01)
        threads[4].start()
        for t in threads:
            t.join(timeout=5)
        self.assertEqual(1, most[0], "never two statements at once on the one connection")
        self.assertEqual(["closed"], order)


class ShowingQueriesTest(unittest.TestCase):
    def test_each_statement_is_said_while_a_card_waits_and_the_connection_is_left_as_it_was(self):
        """Opening another table's column map runs many statements; each is printed ("Running: ...") so the card
        shows them as they go, and afterwards the connection's own execute is back."""
        session_mod = importlib.import_module("exakit_guide.session")
        session = session_mod.Session()

        class Conn:
            def execute(self, query):
                return f"ran {query}"

        conn = Conn()
        session._ns = {"nb": None, "connection": conn}
        import io
        from contextlib import redirect_stdout

        out = io.StringIO()
        with redirect_stdout(out), session.showing_queries():
            self.assertEqual("ran SELECT  1", conn.execute("SELECT  1"))
            conn.execute("SELECT " + "X, " * 80 + "Y FROM T")
        lines = out.getvalue().splitlines()
        self.assertEqual("Running: SELECT 1", lines[0])
        self.assertTrue(lines[1].endswith(" ...") and len(lines[1]) < 130, lines[1])
        self.assertNotIn("execute", vars(conn), "the connection's own method again")


class MarimoShownCodeTest(unittest.TestCase):
    def test_guided_notebooks_open_in_marimo_with_their_code_shown(self):
        """In Marimo a guided notebook shows its code: the code cells open with their code visible, the guided cell
        included, as `marimo convert` writes them; only the text cells keep their code folded (their text shows).
        tools/notebooks.py no longer hides anything after the conversion."""
        folder = ROOT / "notebook" / "marimo" / "data-scientist"
        paths = sorted(folder.glob("*.py"))
        self.assertTrue(paths)
        for path in paths:
            text = path.read_text(encoding="utf-8")
            self.assertIn(build_tool.CODE_START_MARKER, text, path.name)
            cells = re.findall(r"(?ms)^(@app\.cell(?:\([^)]*\))?)\n(.*?)(?=^@app\.cell|^if __name__)", text)
            self.assertTrue(cells, path.name)
            shown = [body for decorator, body in cells if decorator == "@app.cell"]
            folded = [body for decorator, body in cells if "hide_code=True" in decorator]
            self.assertEqual(len(cells), len(shown) + len(folded), f"{path.name}: a cell with another setting")
            for body in folded:
                self.assertIn("mo.md(", body, f"{path.name}: a code cell is folded")        # only text is folded
            for body in shown:
                self.assertNotIn("mo.md(", body, f"{path.name}: a text cell shows its source")
            self.assertTrue(any("guide." in body for body in shown), f"{path.name}: the guided cell shows its code")
        self.assertFalse(hasattr(build_tool, "hide_code_behind_page"))


class HomeAddonsTest(unittest.TestCase):
    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_every_add_on_is_listed_and_one_not_installed_can_be_installed(self):
        home = importlib.import_module("exakit_guide.screens.home")
        screen = home.Home.__new__(home.Home)
        screen.data = {"kit": {"services": {"dash-server": "running", "exasol-scheduler": "stopped"},
                               "urls": {"dash-server": "http://127.0.0.1:5100"}},
                       "plan": {"addons": {"installed": ["dash-server"], "pending": ["notebook"]}},
                       "addons": [{"id": "dash-server", "status": "installed", "installed": True},
                                  {"id": "dbt-exasol", "status": "available", "installed": False},
                                  {"id": "exasol-scheduler", "status": "installed", "installed": True},
                                  {"id": "exasol-vscode", "status": "managed outside the kit", "installed": False},
                                  {"id": "notebook", "status": "available", "installed": False},
                                  {"id": "json-tables", "name": "exasol-json-tables", "status": "available",
                                   "installed": False},
                                  {"id": "udf-devkit", "status": "available", "installed": False, "offered": False}]}
        screen.data["components"] = [{"id": "dash-server", "add_on": True, "status": "update_available", "available": "0.3.0"},
                                     {"id": "uv", "installed": "0.13.6", "status": "external"},     # this computer's: not listed
                                     {"id": "exapump", "installed": "0.13.1", "status": "current"},
                                     {"id": "mcp_server", "installed": "2.4.0", "status": "update_available",
                                      "available": "2.5.0"}]
        screen.data["addons"][0]["version"] = "0.2.1"
        # The Marketplace tab: every add-on, the persona's first, with versions and updates.
        rows = {r["id"]: r for r in screen._addon_rows(everything=True)}
        self.assertEqual(["addon_dash-server", "addon_notebook", "addon_dbt-exasol", "addon_exasol-scheduler",
                          "addon_exasol-vscode", "addon_json-tables"], list(rows))      # one the kit does not offer yet: not listed
        label = lambda r: [a["label"] for a in r["actions"]]
        self.assertEqual("Installed 0.2.1 · Running · update to 0.3.0", rows["addon_dash-server"]["text"])
        self.assertEqual(["Update", "Open"], label(rows["addon_dash-server"]))
        self.assertEqual(["Install"], label(rows["addon_dbt-exasol"]))
        self.assertEqual("Not installed (for your persona)", rows["addon_notebook"]["text"])
        self.assertEqual(["Start"], label(rows["addon_exasol-scheduler"]))
        self.assertEqual([], label(rows["addon_exasol-vscode"]))                          # the user's own: never touched
        self.assertEqual("exasol-json-tables", rows["addon_json-tables"]["name"])
        self.assertEqual('nb.addon_ready("dbt-exasol")', rows["addon_dbt-exasol"]["actions"][0]["cmd"])
        # The kit's own parts, with Update where the kit has a newer version.
        parts = {r["id"]: r for r in screen._component_rows()}
        self.assertEqual(["part_exapump", "part_mcp_server"], list(parts))
        self.assertEqual("0.13.1 · up to date", parts["part_exapump"]["text"])
        self.assertEqual(("2.4.0 · update to 2.5.0", ["Update"], 'nb.kit_update("mcp_server")'),
                         (parts["part_mcp_server"]["text"], label(parts["part_mcp_server"]), parts["part_mcp_server"]["cmd"]))
        # Your kit: the persona's add-ons and the installed ones only.
        self.assertEqual(["addon_dash-server", "addon_notebook", "addon_exasol-scheduler"],
                         [r["id"] for r in screen._addon_rows(everything=False)])

    @unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
    def test_the_marketplace_is_a_tab_of_the_home_card(self):
        guide = importlib.import_module("exakit_guide")
        home = importlib.import_module("exakit_guide.screens.home")
        with mock.patch.object(home.Home, "_load"), mock.patch.object(home.threading, "Thread"):
            screen = guide.marketplace()
        self.assertEqual("marketplace", screen.tab)
        screen.loading, screen.data = False, {"addons": [{"id": "dbt-exasol", "status": "available", "installed": False}],
                                              "components": [{"id": "exapump", "installed": "0.13.1", "status": "current"}]}
        blocks = screen.build()
        self.assertEqual({"t": "tabs", "value": "marketplace", "items": [{"id": "kit", "label": "Your kit"},
                                                                         {"id": "marketplace", "label": "Marketplace"}]}, blocks[1])
        self.assertEqual(["Add-ons (0 of 1 installed)", "The kit's parts"], [b["v"] for b in blocks if b["t"] == "section"])
        screen.on_tab_kit({})
        self.assertIn("Your setup", [b["v"] for b in screen.build() if b["t"] == "section"])
        self.assertIn("tabs(b) {", (GUIDE / "static" / "card.js").read_text(encoding="utf-8"))


class ToggleTest(unittest.TestCase):
    def setUp(self):
        self.js = (GUIDE / "static" / "card.js").read_text(encoding="utf-8")

    def test_code_turns_this_card_into_its_code_in_place(self):
        """Code on a card used to reveal every code cell of the notebook below the cards; it now redraws that card,
        where it is, as its code - and only that card."""
        self.assertIn("const setMode = (mode) => { ui.mode = mode; rememberMode(mode); draw(); };", self.js)
        self.assertIn("root.replaceChildren(...(code ? codeView(blocks) : blocks.map(block).filter(Boolean)));", self.js)
        self.assertNotIn("document.body.classList.toggle(\"guide-code\"", self.js)
        # The notebook's code cells stay hidden until asked for, by one link in a card's Code view.
        self.assertIn("body.guide-cards:not(.guide-allcode) .jp-Cell:has(.guide-code-start) ~ .jp-Cell { display: none !important; }",
                      self.js)
        self.assertIn("Show all the notebook's code cells", self.js)

    def test_every_card_opens_guided(self):
        """One Code click used to be remembered, so every later card (and every run) opened as code."""
        body = self.js.split("function defaultMode()", 1)[1].split("\nfunction ", 1)[0]
        self.assertIn('return "guided";', body)
        self.assertNotIn("getItem(MODE_KEY)", body)
        self.assertNotIn("localStorage.setItem(MODE_KEY", self.js)

    def test_a_card_keeps_the_code_it_ran(self):
        card = (GUIDE / "card.py").read_text(encoding="utf-8")
        self.assertIn('blocks = blocks + [{"t": "ran", "v": "\\n".join(self.ran)}]', card)

    def test_the_code_can_be_copied_as_a_cell(self):
        self.assertIn('"Copy as cell"', self.js)
        self.assertIn("navigator.clipboard.writeText(text)", self.js)

    def test_a_password_box_is_masked_and_not_kept(self):
        self.assertIn('type: f.type === "password" ? "password" : "text"', self.js)
        self.assertIn('st.secret.forEach((k) => { st.fields[k] = ""; });', self.js)

    def test_the_package_ships_the_card_files(self):
        toml = (PACKAGE / "pyproject.toml").read_text(encoding="utf-8")
        self.assertIn('exakit_guide = ["static/*.js", "static/*.css"]', toml)
        self.assertIn('"anywidget==0.11.0"', toml)
        self.assertIn('"exakit_guide.screens"', toml)


class PrepareDraftsTest(unittest.TestCase):
    """Use this data: every chosen table's column roles drawn up in the background, sources at once, one source's
    tables in order, and a table being read waited for instead of read twice."""

    def setUp(self):
        import threading

        import exakit_nb  # noqa: F401 - loads the module below (the package's name "describe" is the function)

        module = sys.modules["exakit_nb.describe"]
        self.module = module
        self.lock = threading.Lock()
        self.release = threading.Event()
        self.order: list[str] = []
        self.busy: dict[str, int] = {}
        self.most: dict[str, int] = {}
        self.connections = 0
        test = self

        class Service:
            @staticmethod
            def describe(conn, table):
                schema = table.split(".")[0]
                with test.lock:
                    test.order.append(table)
                    test.busy[schema] = test.busy.get(schema, 0) + 1
                    test.most[schema] = max(test.most.get(schema, 0), test.busy[schema])
                test.release.wait(5)
                with test.lock:
                    test.busy[schema] -= 1
                if table.endswith("BROKEN"):
                    raise RuntimeError("the source refused\nmore detail")
                return {"status": "draft"}

        class Conn:
            def close(self):
                pass

        def connect():
            with self.lock:
                self.connections += 1
            return Conn()

        patches = [mock.patch.object(module, "describe_service", return_value=Service()),
                   mock.patch("exakit_nb.connect", side_effect=connect),
                   mock.patch.dict(module._PREPARING, clear=True), mock.patch.dict(module.PREPARED, clear=True)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_sources_are_read_at_once_and_one_sources_tables_in_order(self):
        tables = ["VS_TEST.ORDERS", "VS_TEST.CUSTOMERS", "VS_CATALOG.category_costs", "AMAZON.ORDER_LINES", "VS_TEST.BROKEN"]
        said = self.module.prepare_drafts(tables)
        self.assertEqual({t: "reading" for t in tables}, said, "returns at once")
        self.module.prepare_drafts(["VS_TEST.ORDERS"])          # a table being read is not queued again (read once, below)
        time.sleep(0.2)
        self.release.set()
        for table in tables:
            self.assertTrue(self.module._PREPARING[table.upper()].wait(5))
        self.assertEqual({"VS_TEST": 1, "VS_CATALOG": 1, "AMAZON": 1}, self.most, "one statement at a time per source")
        self.assertEqual(["VS_TEST.ORDERS", "VS_TEST.CUSTOMERS", "VS_TEST.BROKEN"],
                         [t for t in self.order if t.startswith("VS_TEST.")], "first chosen, first read")
        self.assertEqual(3, self.connections, "one connection a source")
        self.assertEqual(5, len(self.order), "each table read once")
        self.assertEqual("the source refused", self.module.PREPARED["VS_TEST.BROKEN"])
        self.assertEqual("ready", self.module.PREPARED["VS_TEST.ORDERS"])

    def test_describe_waits_for_a_table_being_read(self):
        import threading

        self.module.prepare_drafts(["VS_TEST.ORDERS"])
        waited = threading.Event()
        with mock.patch.object(self.module, "_resolve", side_effect=lambda t: (t, None)), \
                mock.patch.object(self.module._PREPARING["VS_TEST.ORDERS"], "wait",
                                  side_effect=lambda timeout=None: waited.set() or True):
            try:
                self.module.describe("VS_TEST.ORDERS", conn=object())
            except Exception:  # noqa: BLE001 - only the wait is checked here, not the rest of describe
                pass
        self.assertTrue(waited.is_set(), "nb.describe waits for the background read of the same table")
        self.release.set()
        self.assertTrue(self.module._PREPARING["VS_TEST.ORDERS"].wait(5))     # finished before the next test


if __name__ == "__main__":
    unittest.main()
