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

    def test_a_source_with_settings_is_picked_from_a_tree_and_asked_only_what_is_left(self):
        """Data source lists a connector's settings as a tree under it (a Lakehouse's catalogs, and under each the files
        it reads). A leaf settles them; a setting the tree does not hold (the catalog login) is one more step; the
        connector's own row asks them one by one. The settings go to exakit connect, the two secrets apart."""
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said, card.parsed, card.source_tables = [], "", {}, {}
        card.connectors = nb.connectors()
        card.forms = {c["id"]: nb.connector_inputs(c["id"]) for c in card.connectors}
        card._settle = lambda cid, chosen: card.forms.__setitem__(cid, nb.connector_inputs(cid, **chosen)) or card.forms[cid]
        only = {"field": "src_schema", "equals": "__connect__"}
        cid = next(c["id"] for c in card.connectors if card.forms[c["id"]]["tree"])
        tree = card.forms[cid]["tree"]
        card.step = "source"
        values = [o["value"] for o in next(f for f in card._source_fields(only) if f["id"] == "connector")["options"]]
        self.assertLess(values.index(cid), values.index(card._pick(cid, tree[0]["set"])))            # the parent, then its tree
        for node in tree:
            self.assertIn(card._pick(cid, node["set"]), values)
            for child in node["children"]:
                self.assertIn(card._pick(cid, child["set"]), values)
        self.assertEqual(len(values), len(set(values)))

        def pending():
            return [spec["name"] for spec in card._pending(card.forms[cid])]

        # A leaf with nothing left to choose goes straight on; one with a setting outside the tree asks it.
        leaves = [child["set"] for node in tree for child in node["children"]]
        for leaf in leaves:
            card.step = "source"
            card.on_src_next({"connector": card._pick(cid, leaf)})
            with self.subTest(leaf=leaf):
                self.assertEqual(leaf, card.preset)
                self.assertEqual(bool(pending()), card.step == "settings")
                self.assertEqual(bool(pending()), "settings" in card._steps())
        asking = next(leaf for leaf in leaves if nb.connector_inputs(cid, **leaf)["setting_inputs"][-1]["name"] not in leaf)
        card.step = "source"
        card.on_src_next({"connector": card._pick(cid, asking)})
        left = card._pending(card.forms[cid])
        shown = [f for f in card._source_fields(only) if f.get("type") == "select"]
        self.assertEqual([spec["label"].split(" - ")[0] + " *" for spec in left], [f["label"] for f in shown])
        self.assertEqual(left[0]["choice_labels"], [o["label"] for o in shown[0]["options"]])
        card.on_src_next({shown[0]["id"]: left[0]["choices"][-1]})
        self.assertEqual(left[0]["choices"][-1], card.preset[left[0]["name"]])
        self.assertNotEqual("settings", card.step)
        self.assertEqual([], pending())

        # The connector's own row: every setting is asked, one step, until none is left.
        card.step = "source"
        card.on_src_next({"connector": cid})
        self.assertEqual(({}, "settings"), (card.preset, card.step))
        for _ in range(4):
            if card.step != "settings":
                break
            fields = [f for f in card._source_fields(only) if f.get("type") == "select"]
            card.on_src_next({f["id"]: f["value"] for f in fields})
        self.assertNotEqual("settings", card.step)
        self.assertEqual([], pending())

        # What goes to the kit: the settings as inputs, the login as the password, the storage secret apart.
        both = next((leaf for leaf in leaves if any(i.get("storage") for i in nb.connector_inputs(cid, **leaf)["inputs"])), None)
        self.assertIsNotNone(both, "no combination has a second secret any more: drop this part with it")
        card.step = "source"
        card.on_src_next({"connector": card._pick(cid, both)})
        if card.step == "settings":
            card.on_src_next({})
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
        """The password is typed on an earlier step and its box is emptied when it is sent. A connect that fails (the
        source refused, a name did not resolve) and is tried again from the last step goes out with the password
        typed before, not with none; a new one typed wins; it is forgotten once connected and for another source."""
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
        card._kept_secret, card.step = "held", "source"
        card.on_src_next({"connector": "mysql"}) if "mysql" in card.forms else card.forms.update(mysql=nb.connector_inputs("mysql")) or card.on_src_next({"connector": "mysql"})
        self.assertEqual("", card._kept_secret)                                          # another source: its own
        self.assertNotIn("_kept_secret", repr(vars(card).get("flash", "")))

    def test_a_new_connection_is_entered_one_step_at_a_time(self):
        """Connection, data source, connection string, name, details, optional settings: Next checks each answer and
        shows only the next step; Back returns. A data source without a connection string has no such step."""
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said, card.parsed, card.source_tables = ["VS_OLD"], "", {}, {}
        card.connectors = nb.connectors()
        card.forms = {c["id"]: nb.connector_inputs(c["id"]) for c in card.connectors}
        only = {"field": "src_schema", "equals": "__connect__"}
        first = card._source_fields(only)
        self.assertEqual("Connection", first[0]["label"])                       # the connections there are, first
        self.assertEqual(["VS_OLD", "__connect__"], [o["value"] for o in first[0]["options"]])
        card.on_src_next({})
        self.assertEqual("source", card.step)
        self.assertEqual(["Data source"], [f["label"] for f in card._source_fields(only) if f.get("type") == "select"])
        with self.assertRaisesRegex(ValueError, "Choose the data source"):
            card.on_src_next({"connector": "nope"})
        card.on_src_next({"connector": "postgresql"})
        self.assertEqual(["connection", "source", "string", "name", "needed", "optional"], card._steps())
        self.assertEqual("string", card.step)
        with self.assertRaisesRegex(ValueError, "Paste the connection string, or choose Manual configuration"):
            card.on_src_next({})
        self.assertEqual(["string", "manual"], [o["value"] for o in card._source_fields(only)[1]["options"]])
        card.on_src_next({card._fid("postgresql", "how"): "manual"})            # manual: every input is asked
        self.assertEqual("name", card.step)
        with self.assertRaisesRegex(ValueError, "Give the connection a name"):
            card.on_src_next({"src_name": "My Sales"})
        card.on_src_next({"src_name": "sales"})
        labels = [f["label"] for f in card._source_fields(only)[1:]]
        self.assertEqual(["Host name or address *", "Database *", "Reader account *"], labels[:3])
        self.assertIn("Password", labels[3])
        with self.assertRaisesRegex(ValueError, "Fill in: Host name or address"):
            card.on_src_next({})
        self.assertEqual("needed", card.step)
        card.on_src_back({})
        self.assertEqual("name", card.step)
        card.forms["plain"] = {**card.forms["postgresql"], "forms": []}          # a data source that takes no string
        card.step = "source"
        card.on_src_next({"connector": "plain"})
        self.assertEqual("name", card.step)
        self.assertNotIn("string", card._steps())

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
            card.connector, card.step = "postgresql", "string"
            card.on_src_next({card._fid("postgresql", "url"): "postgres://db.example.com:5433/shop"})
            self.assertEqual(["user", "password"], card.parsed["postgresql"]["missing"])
            self.assertEqual("name", card.step)
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


if __name__ == "__main__":
    unittest.main()
