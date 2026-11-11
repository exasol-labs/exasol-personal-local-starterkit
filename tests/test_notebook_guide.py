"""The guided view: the cards a Data Scientist notebook opens with, and the Guided / Code toggle over its own code cells.

The structure is checked everywhere (the build, the toggle's CSS, the notebooks' layout); the cards themselves only
where anywidget is installed (the kit's notebook environment), with the kit's helpers faked - no database.
"""

from __future__ import annotations

import importlib
import json
import os
import stat
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

try:
    import anywidget  # noqa: F401
    HAVE_ANYWIDGET = True
except ImportError:
    HAVE_ANYWIDGET = False

CARDS = {"00_quickstart": "guide.start()", "01_explore": "guide.explore()", "02_ask_your_data": "guide.ask()",
         "03_share": "guide.share()"}


def _cells(name: str) -> list[dict]:
    return json.loads(build_tool.build(SOURCES / "data-scientist" / f"{name}.py"))["cells"]


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
                marker = cells[2]
                self.assertIn(build_tool.CODE_START_TAG, marker["metadata"]["tags"])
                self.assertIn('class="guide-code-start"', "".join(marker["source"]))

    def test_the_code_heading_is_the_only_top_level_heading(self):
        """The page's own title moves under "The code behind this page", so the outline (table of contents) shows
        the code section as one part with the steps inside it."""
        for name in CARDS:
            with self.subTest(notebook=name):
                tops = ["".join(c["source"]).split("\n")[0] for c in _cells(name)
                        if c["cell_type"] == "markdown" and "".join(c["source"]).startswith("# ")]
                self.assertEqual(["# The code behind this page"], tops)

    def test_the_shipped_ipynb_carries_the_code_marker(self):
        for name in CARDS:
            with self.subTest(notebook=name):
                built = json.loads((SOURCES / "data-scientist" / f"{name}.ipynb").read_text(encoding="utf-8"))
                self.assertTrue(any('class="guide-code-start"' in "".join(c["source"]) for c in built["cells"]))

    def test_other_notebooks_have_no_guided_cards(self):
        for py in [*SOURCES.glob("ml-engineer/*.py"), SOURCES / "00_shared" / "data_paths.py"]:
            with self.subTest(notebook=py.name):
                self.assertNotIn("exakit_guide", py.read_text(encoding="utf-8"))


class ToggleTest(unittest.TestCase):
    def setUp(self):
        self.js = (GUIDE / "static" / "card.js").read_text(encoding="utf-8")

    def test_guided_hides_the_code_section(self):
        self.assertIn("body.guide-cards .jp-Cell:has(.guide-code-start) ~ .jp-Cell { display: none !important; }", self.js)
        self.assertIn("body:not(.guide-code) .guide-code-only { display: none !important; }", self.js,
                      "Code also shows the kit calls behind each card's buttons")

    def test_the_choice_is_remembered_across_notebooks(self):
        self.assertIn('localStorage.setItem(MODE_KEY, mode)', self.js)

    def test_a_password_box_is_masked_and_not_kept(self):
        self.assertIn('type: f.type === "password" ? "password" : "text"', self.js)
        self.assertIn('st.secret.forEach((k) => { st.fields[k] = ""; });', self.js)

    def test_the_package_ships_the_card_files(self):
        toml = (PACKAGE / "pyproject.toml").read_text(encoding="utf-8")
        self.assertIn('exakit_guide = ["static/*.js", "static/*.css"]', toml)
        self.assertIn('"anywidget==0.11.0"', toml)


class NoBypassTest(unittest.TestCase):
    def test_no_card_opens_its_own_database_connection(self):
        """Every card goes through the kit: nb.connect() for the admin connection the notebooks use, and the kit's
        read-only MCP service for approved questions - never a connection of its own, never TLS checks off."""
        for path in GUIDE.glob("*.py"):
            text = path.read_text(encoding="utf-8")
            with self.subTest(file=path.name):
                self.assertNotIn("pyexasol.connect(", text)
                self.assertNotIn("CERT_NONE", text)
                self.assertNotIn('["password_file"]).read_text', text)


@unittest.skipUnless(HAVE_ANYWIDGET, "anywidget is not installed here (the kit's notebook environment has it)")
class CardTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.home.name}, clear=False)
        self.env.start()
        for name in ("LANGFUSE_BASE_URL", "LANGFUSE_PUBLIC_KEY", "LANGFUSE_SECRET_KEY", "LANGFUSE_HOST"):
            os.environ.pop(name, None)

    def tearDown(self):
        self.env.stop()
        self.home.cleanup()

    def test_langfuse_is_saved_privately_and_loaded_by_every_step(self):
        aikey = importlib.import_module("exakit_guide.aikey")
        aikey.save_langfuse("https://cloud.langfuse.com", "pk-lf-1", "secret-1")
        folder = Path(self.home.name) / "credentials"
        for path in folder.iterdir():
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode), path.name)
        self.assertNotIn("secret-1", (folder / "guide_langfuse.json").read_text(encoding="utf-8"))
        self.assertTrue(aikey.load_langfuse())
        self.assertEqual("secret-1", os.environ["LANGFUSE_SECRET_KEY"])
        aikey.forget_langfuse()
        self.assertFalse(aikey.langfuse_saved())
        self.assertNotIn("LANGFUSE_SECRET_KEY", os.environ)

    def test_the_home_card_sets_up_langfuse_with_both_keys(self):
        home = importlib.import_module("exakit_guide.home")
        card = home.Home.__new__(home.Home)
        card.data, card.flash = {"langfuse": {"on": False, "url": "", "half": False}}, None
        card._reload = lambda: None
        asked = []

        def use_model(model, url, langfuse, ask):
            asked.extend([ask("public"), ask("secret")])
            return {"notes": []}

        with mock.patch("exakit_nb.setup_env.use_model", side_effect=use_model):
            card.on_langfuse_setup({"url": "https://cloud.langfuse.com", "public": "pk", "secret": "sk"})
        self.assertEqual(["pk", "sk"], asked)
        self.assertNotIn("sk", card.flash["v"])
        with self.assertRaises(ValueError):
            card.on_langfuse_setup({"url": "https://cloud.langfuse.com", "public": "pk", "secret": ""})

    def test_connecting_a_source_sends_the_password_to_the_kit_and_logs_none(self):
        understand = importlib.import_module("exakit_guide.understand")
        session = importlib.import_module("exakit_guide.session")
        card = understand.ChooseData.__new__(understand.ChooseData)
        card.sources, card.kit_said = [], ""
        with mock.patch("exakit.nb.connect_source", return_value="VS_SALES") as connect, \
             mock.patch.object(session, "SESSION", session.Session()) as fresh, \
             mock.patch.object(understand, "SESSION", fresh):
            schema = card._connect({"connector": "postgresql", "src_name": "Sales", "src_password": "s3cret",
                                    "src_url": "postgres://reader@db.example.com:5432/shop"})
            logged = "\n".join(fresh.code)
        self.assertEqual("VS_SALES", schema)
        self.assertEqual(["VS_SALES"], card.sources)
        self.assertEqual("s3cret", connect.call_args.kwargs["secret"]("Password for sales"))
        self.assertNotIn("s3cret", logged)
        with self.assertRaises(ValueError):
            card._connect({"connector": "postgresql", "src_name": "", "src_url": ""})

    def test_the_data_map_card_shows_every_table_and_its_column_map(self):
        understand = importlib.import_module("exakit_guide.understand")
        session = importlib.import_module("exakit_guide.session")
        found = mock.Mock(table_rows=[{"origin_label": "Sample data", "table": "AMAZON.ORDER_LINES", "rows_shown": "128,975",
                                       "columns": 24, "map": "approved v1, published", "summary": "key ORDER_LINE_ID"}],
                          link_rows=[])
        card = understand.DataMap.__new__(understand.DataMap)
        card.flash = None
        card.refresh = lambda: None
        fake = session.Session()
        fake.connection = lambda: object()
        with mock.patch("exakit.nb.data_map", return_value=found), mock.patch.object(understand, "SESSION", fake):
            card._load()
        blocks = card.build()
        table = next(b for b in blocks if b["t"] == "table")
        self.assertEqual(["Origin", "Table", "Rows", "Columns", "Column map", "Roles"], table["columns"])
        self.assertEqual("approved v1, published", table["rows"][0][4])

    def test_the_publish_note_says_whether_agents_can_read_the_roles(self):
        understand = importlib.import_module("exakit_guide.understand")
        self.assertIn("Published as EXAKIT_SEMANTIC.AMAZON__ORDER_LINES",
                      understand._publish_note("Published as EXAKIT_SEMANTIC.AMAZON__ORDER_LINES: agents read the roles."))
        self.assertIn("Not published for AI agents yet",
                      understand._publish_note("Approved, not published: refused. Retry with: exakit describe x --comments"))

    def test_marimo_gets_the_cards_stacked(self):
        card = importlib.import_module("exakit_guide.card")
        screen = mock.Mock()
        screen._display_.return_value = "card"
        fake_mo = mock.Mock()
        fake_mo.running_in_notebook.return_value = True
        fake_mo.vstack.side_effect = lambda items: ("stack", items)
        with mock.patch.dict(sys.modules, {"marimo": fake_mo}):
            self.assertEqual(("stack", ["card", "card"]), card.show(screen, screen))


if __name__ == "__main__":
    unittest.main()
