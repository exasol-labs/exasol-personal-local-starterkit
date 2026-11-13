"""exakit's terminal view (setup/tui/exakit_tui): what it reads, what it draws, and the exakit command each button
runs. The kit is a stand-in that answers --json in the installed kit's shapes, so nothing here needs an install or
a terminal; the drawing tests need Textual (CI installs the kit's pinned version) and skip without it."""

from __future__ import annotations

import asyncio
import json
import re
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "tui"))

from exakit_tui.kit import Kit, _last_json  # noqa: E402

try:
    import textual  # noqa: F401
    from exakit_tui.app import Confirm, ExakitApp
except ImportError:  # pragma: no cover - the kit's notebook-free CI job has it
    ExakitApp = None

FAKE = textwrap.dedent('''
    import json, sys
    args = [a for a in sys.argv[1:] if a not in ("--json", "-j")]
    key = " ".join(args)
    ANSWERS = json.loads(open(sys.argv[0] + ".json").read())
    if key in ANSWERS:
        print("a notice first\\n" + json.dumps(ANSWERS[key]))
    else:
        print("ran: " + key)
''')

ANSWERS = {
    "status": {"installed": True, "status": "running", "running": True, "platform": "macos",
               "services": {"dash-server": "running"}, "urls": {"dash-server": "http://127.0.0.1:5100"},
               "datasets_loaded": ["amazon_sales"]},
    "version": {"components": [{"component": "runtime", "installed_label": "Exasol Personal 2.4.0", "advertised": "2.4.0",
                                "status": "up to date"},
                               {"component": "mcp-server", "installed": "1.2.0", "advertised": "1.3.0",
                                "status": "update available", "remedy": "exakit update mcp-server"}]},
    "marketplace --list": {"addons": [
        {"id": "dash-server", "name": "Dash Server", "about": "Dashboards.", "status": "running", "installed": True, "version": "0.9.1"},
        {"id": "json-tables", "name": "JSON Tables", "about": "JSON as tables.", "status": "available", "installed": False}]},
    "mcp-status": {"artifacts": [{"client": "claude_code", "kind": "client_config", "path": "~/.claude.json",
                                  "metadata": {"server": "exasol", "entry_name": "exasol"}}]},
    "source list": {"sources": [{"name": "sales", "connector": "postgresql", "connector_name": "PostgreSQL",
                                 "schema": "VS_SALES", "status": "ready", "host": "db.example.com:5432", "tls": "verify"}]},
    "source catalog": {"connectors": [{"id": "postgresql", "name": "PostgreSQL", "status": "GA"},
                                      {"id": "lakehouse", "name": "Lakehouse", "status": "preview"}]},
    "persona list": {"personas": [
        {"id": "data-scientist", "title": "Data Scientist", "summary": "Notebooks and dashboards.", "recorded": True,
         "datasets": ["amazon_sales", "fraud_transactions"], "addons": ["dash-server", "json-tables"], "mcp_clients": "all",
         "notebooks": [{"id": "q", "title": "Start here", "jupyter": "data-scientist/00_quickstart.ipynb"}]},
        {"id": "general", "title": "General", "summary": "Samples.", "recorded": False, "datasets": ["tpch"],
         "addons": [], "mcp_clients": "all", "notebooks": []}]},
    "persona plan data-scientist": {"datasets": {"loaded": ["amazon_sales"], "pending": ["fraud_transactions"]},
                                    "addons": {"installed": ["dash-server"], "pending": ["json-tables"], "unavailable": []}},
    "persona plan general": {"datasets": {"loaded": [], "pending": ["tpch"]}, "addons": {}},
}


def _kit(tmp: Path) -> Kit:
    script = tmp / "fake_exakit.py"
    script.write_text(FAKE, encoding="utf-8")
    Path(str(script) + ".json").write_text(json.dumps(ANSWERS), encoding="utf-8")
    return Kit([sys.executable, str(script)], ROOT)


class ReadingTest(unittest.TestCase):
    def test_the_answer_is_found_after_a_notice(self):
        self.assertEqual({"a": 1}, _last_json('Update available\n{"a": 1}'))
        self.assertEqual({"a": {"b": 2}}, _last_json('{\n  "a": {"b": 2}\n}'))
        self.assertEqual({}, _last_json("no json here"))
        self.assertEqual({"rows": [1, 2]}, _last_json("[1, 2]"))

    def test_every_read_is_the_kits_own_json_and_never_reopens_the_view(self):
        with tempfile.TemporaryDirectory() as tmp:
            kit = _kit(Path(tmp))
            self.assertEqual("running", kit.json("status")["status"])
            self.assertEqual("1", kit.env()["EXAKIT_NO_TUI"])
            self.assertIn("_error", kit.json("nothing", "here"))

    def test_the_clients_and_datasets_are_the_kits_own(self):
        kit = Kit(["true"], ROOT)
        self.assertIn("claude_code", kit.client_names())
        self.assertIn("amazon_sales", kit.datasets())
        self.assertTrue(kit.datasets()["amazon_sales"]["label"])


class CommandSurfaceTest(unittest.TestCase):
    """Every button runs a command the kit has: the first word of each run_kit / confirm_then call is an exakit
    command in setup/help/exakit.json."""

    def test_every_button_names_a_real_command(self):
        source = (ROOT / "setup" / "tui" / "exakit_tui" / "app.py").read_text(encoding="utf-8")
        used = set(re.findall(r'run_kit\(\*?\(?\[?"([a-z-]+)"', source))
        used |= set(re.findall(r'confirm_then\(\s*f?"[^"]*",\s*"([a-z-]+)"', source))
        known = {c["command"] for c in json.loads((ROOT / "setup" / "help" / "exakit.json").read_text())["commands"]}
        self.assertTrue(used, "the buttons were found")
        self.assertEqual(set(), used - known)
        for word in ("marketplace", "update", "uninstall", "source", "connect", "persona", "mcp-setup", "mcp-remove"):
            self.assertIn(word, used)


@unittest.skipIf(ExakitApp is None, "needs Textual (the kit's pinned version)")
class ViewTest(unittest.TestCase):
    def run_app(self, steps, persona=None, tab="status"):
        async def go():
            with tempfile.TemporaryDirectory() as tmp:
                app = ExakitApp(_kit(Path(tmp)), tab=tab, persona=persona)
                ran: list[tuple] = []
                app.run_kit = lambda *args, then=None: ran.append(args)          # the command, not run
                async with app.run_test(size=(150, 44)) as pilot:
                    await pilot.pause()
                    await app.workers.wait_for_complete()
                    await pilot.pause()
                    result = await steps(app, pilot)
                return app, ran, result
        return asyncio.run(go())

    @staticmethod
    async def settle(app, pilot):
        await pilot.pause()
        await app.workers.wait_for_complete()
        await pilot.pause()

    def text(self, app, selector) -> str:
        return str(app.query_one(selector).render())

    def test_a_persona_opens_on_its_own_page_with_what_is_missing(self):
        async def steps(app, pilot):
            await self.settle(app, pilot)
            return (self.text(app, "#persona-detail"), app.query_one("TabbedContent").active,
                    app.query_one("#persona-add").disabled, app.query_one("#persona-missing").disabled)
        _app, _ran, (page, tab, add_off, missing_off) = self.run_app(steps, persona="data-scientist")
        self.assertEqual("personas", tab)
        self.assertIn("Data Scientist", page)
        self.assertIn("This kit is set up as this persona", page)
        self.assertRegex(page, r"loaded\s+Amazon sales")
        self.assertRegex(page, r"to load\s+Fraud transactions")
        self.assertRegex(page, r"to install\s+json-tables")
        self.assertIn("00_quickstart.ipynb", page)
        self.assertTrue(add_off, "already this kit's persona")
        self.assertFalse(missing_off)

    def test_an_unknown_persona_says_which_there_are(self):
        async def steps(app, pilot):
            await self.settle(app, pilot)
            return self.text(app, "#persona-detail")
        _app, _ran, page = self.run_app(steps, persona="nobody")
        self.assertIn("No persona named nobody", page)
        self.assertIn("data-scientist, general", page)

    def test_the_buttons_run_the_kits_commands(self):
        async def steps(app, pilot):
            app.action_tab("marketplace")
            await self.settle(app, pilot)
            table = app.query_one("#addons")
            table.move_cursor(row=1)
            await pilot.pause()
            app.query_one("#addon-install").press()
            await pilot.pause()
            app.action_tab("personas")
            await self.settle(app, pilot)
            app.query_one("#persona-missing").press()
            await pilot.pause()
            app.action_tab("sources")
            await self.settle(app, pilot)
            app.query_one("#source-check").press()
            await pilot.pause()
            app.query_one("#source-remove").press()             # asks first
            await pilot.pause()
            asked = isinstance(app.screen, Confirm)
            await pilot.click("#yes")
            await pilot.pause()
            return asked
        app, ran, asked = self.run_app(steps)
        self.assertIn(("marketplace", "json-tables"), ran)
        self.assertIn(("persona", "add", "data-scientist"), ran)
        self.assertIn(("source", "check", "sales"), ran)
        self.assertTrue(asked, "removing asks first")
        self.assertIn(("source", "remove", "sales"), ran)

    def test_status_shows_the_database_and_what_needs_doing(self):
        async def steps(app, pilot):
            await self.settle(app, pilot)
            return self.text(app, "#summary"), app.query_one("#components").row_count
        _app, _ran, (summary, rows) = self.run_app(steps)
        self.assertIn("Database: running", summary)
        self.assertIn("http://127.0.0.1:5100", summary)
        self.assertEqual(2, rows)


if __name__ == "__main__":
    unittest.main()
