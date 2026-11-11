"""The guided view: cards that do each notebook's steps, the Guided / Code switch over its code cells, and the rule
that ties them together - every card action is one exact exakit.nb call, shown as code, run as that code, and present
as a cell in the notebook's code section; every fact a card shows is read from the kit live.

The structure is checked everywhere; the cards themselves where anywidget is installed (the kit's notebook
environment), with the kit faked - no database.
"""

from __future__ import annotations

import ast
import importlib
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
            self.assertTrue(form["inputs"], connector["id"])
            for spec in form["inputs"]:
                self.assertTrue(spec["label"] and spec["kind"], (connector["id"], spec))
        self.assertEqual("postgresql", nb.connector_inputs("pg")["id"])           # an alias, as exakit connect takes
        self.assertEqual("secret-file", next(i["kind"] for i in nb.connector_inputs("bigquery")["inputs"] if i["file"]
                                             and i["secret"]))

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

    def test_connecting_a_source_keeps_the_password_out_of_the_code(self):
        understand = importlib.import_module("exakit_guide.screens.understand")
        nb = importlib.import_module("exakit_nb")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said = [], ""
        card.forms = {"postgresql": nb.connector_inputs("postgresql")}          # the kit's own form for it
        f = card._fid
        with mock.patch.object(understand.actions, "run", return_value="VS_SALES") as run:
            schema = card._connect({"connector": "postgresql", "src_name": "Sales", f("postgresql", "password"): "s3cret",
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
        card.forms = {"postgresql": nb.connector_inputs("postgresql")}
        with mock.patch.object(understand.actions, "run") as run:
            with self.assertRaisesRegex(ValueError, "Fill in: Host name or address, Database, Reader account"):
                card._connect({"connector": "postgresql", "src_name": "sales"})
        run.assert_not_called()

    def test_run_logs_exactly_what_it_ran_and_returns_the_result(self):
        actions = importlib.import_module("exakit_guide.actions")
        session = importlib.import_module("exakit_guide.session")
        fake = session.Session()
        fake._ns = {"nb": mock.Mock(**{"addon_ready.return_value": {"state": "running"}}), "connection": object()}
        result = actions.run("share.server", fake)
        self.assertEqual({"state": "running"}, result)
        self.assertEqual(['dash_server_state = nb.addon_ready("dash-server")'], fake.code)

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
        screen.confirm, screen.outputs, screen.failed = None, {}, set()
        with mock.patch.object(home.actions, "run") as run, mock.patch.object(screen, "_rows", return_value=[]), \
             mock.patch.object(screen, "_other_rows", return_value=[]), mock.patch.object(screen, "_reload"), \
             mock.patch.object(home.SESSION, "changed") as changed:
            screen._run("kit.data_load", {"what": "<file, folder or dataset>"}, {"what": "~/data/retail", "schema": "retail"})
        self.assertEqual(("kit.data_load_into",), run.call_args.args)
        self.assertEqual({"what": "~/data/retail", "schema": "RETAIL"}, {k: run.call_args.kwargs[k] for k in ("what", "schema")})
        self.assertEqual('nb.exakit("data-load", "~/data/retail", env={"EXAKIT_SCHEMA": "RETAIL"})',
                         actions.code("kit.data_load_into", what="~/data/retail", schema="RETAIL"))
        changed.assert_called_once_with("data", screen)
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
