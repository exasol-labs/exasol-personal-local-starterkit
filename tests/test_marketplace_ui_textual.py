"""Exercise the actual Textual screen with its headless pilot: the shell's own screens, its keys,
clicks, and the wheel handed back to the terminal."""

from __future__ import annotations

import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    import textual  # noqa: F401
except ImportError:
    textual = None

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))

PERSONAS = [{"id": "data-scientist", "label": "Data Scientist", "detail": "Explore"},
            {"id": "ml-engineer", "label": "ML Engineer", "detail": "Train"},
            {"id": "general", "label": "General", "detail": "The kit's own samples"}]


@unittest.skipIf(textual is None, "Textual is provided by uv at the persona boundary")
class ChoiceScreenTest(unittest.TestCase):
    def test_persona_screen_is_the_shell_checkbox_menu(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("persona", PERSONAS, {"general"}, set())
            async with app.run_test(size=(100, 20)):
                self.assertEqual(["    • Personas - tick one or more",
                                  "    ❯ [ ] Data Scientist - Explore",
                                  "      [ ] ML Engineer - Train",
                                  "      [✓] General - The kit's own samples",
                                  "      ↑/↓ to move · Space to toggle · Enter to confirm"],
                                 app.render_screen(100)[0].plain.splitlines())

        asyncio.run(check())

    def test_general_combines_with_every_persona(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("persona", PERSONAS, {"general"}, set())
            async with app.run_test() as pilot:
                await pilot.press("a")
                await pilot.press("enter")
            self.assertEqual(["data-scientist", "ml-engineer", "general"], app.return_value["selected"])

        asyncio.run(check())

    def test_persona_confirm_needs_a_selection_and_escape_cancels(self) -> None:
        from ui import ChoiceApp

        async def confirm() -> None:
            app = ChoiceApp("persona", [{"id": "operations", "label": "Operations"}], set(), set())
            async with app.run_test() as pilot:
                await pilot.press("enter")                  # nothing ticked: the question stays
                self.assertTrue(app.is_running)
                await pilot.press("space")
                await pilot.press("enter")
            self.assertEqual({"selected": ["operations"], "frontends": []}, app.return_value)

        async def cancel() -> None:
            app = ChoiceApp("persona", [{"id": "operations", "label": "Operations"}], set(), set())
            async with app.run_test() as pilot:
                await pilot.press("escape")
            self.assertIsNone(app.return_value)

        asyncio.run(confirm())
        asyncio.run(cancel())

    def test_a_click_ticks_the_row_under_it_and_only_enter_confirms(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("persona", PERSONAS, {"general"}, set())
            async with app.run_test(size=(100, 20)) as pilot:
                await pilot.click("#screen", offset=(10, 2))     # line 2: ML Engineer
                self.assertEqual({"ml-engineer", "general"}, app.selected)
                self.assertTrue(app.is_running)
                await pilot.click("#screen", offset=(10, 0))     # the title line is not a row
                self.assertEqual({"ml-engineer", "general"}, app.selected)
                await pilot.press("enter")
            self.assertEqual(["ml-engineer", "general"], app.return_value["selected"])

        asyncio.run(check())

    def test_the_wheel_hands_the_mouse_back_to_the_terminal(self) -> None:
        from textual import events
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("persona", PERSONAS, {"general"}, set())
            async with app.run_test() as pilot:
                calls = []
                app._driver._disable_mouse_support = lambda: calls.append("off")
                app._driver._enable_mouse_support = lambda: calls.append("on")
                app.on_mouse_scroll_down(events.MouseScrollDown(None, 0, 0, 0, 0, 0, False, False, False))
                self.assertEqual(["off"], calls)
                self.assertEqual(0, app.cursor)                  # the cursor did not move
                await pilot.press("down")                       # a key re-arms the mouse
                self.assertEqual(["off", "on"], calls)
                await pilot.press("escape")

        asyncio.run(check())

    def test_unavailable_addon_is_disabled(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("marketplace", [{"id": "notebook", "label": "Notebooks", "disabled": True,
                                             "reason": "managed outside the kit"}], {"notebook"}, {"marimo"})
            async with app.run_test() as pilot:
                self.assertEqual([("all", None), ("disabled", "notebook"), ("skip", None)], app.table_rows)
                app.cursor = 1
                await pilot.press("space")
                self.assertEqual(set(), app.selected)
                app.cursor = 2
                await pilot.press("enter")                      # Enter on Skip: nothing installed
            self.assertIsNone(app.return_value)

        asyncio.run(check())

    def test_notebook_children_come_from_catalog_rows(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("marketplace", [{"id": "notebook", "label": "Notebooks",
                                             "choices": (("marimo", "Marimo"), ("future-ui", "Future UI"))}],
                            {"notebook"}, {"marimo"})
            async with app.run_test() as pilot:
                self.assertIn("future-ui", app.choices)
                app.cursor = 3
                await pilot.press("space")
                await pilot.press("enter")
            self.assertEqual(["marimo", "future-ui"], app.return_value["frontends"])

        asyncio.run(check())

    def test_new_addon_choices_need_only_a_catalog_row(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            rows = [{"id": "future-addon", "label": "Future add-on",
                     "choices": (("local", "Local mode"), ("remote", "Remote mode"))}]
            app = ChoiceApp("marketplace", rows, {"future-addon"}, set())
            async with app.run_test() as pilot:
                self.assertEqual([("all", None), ("item", "future-addon"),
                                  ("choice", "future-addon:local"),
                                  ("choice", "future-addon:remote"), ("skip", None)], app.table_rows)
                app.cursor = 3
                await pilot.press("space")
                await pilot.press("enter")
            self.assertEqual(["future-addon"], app.return_value["selected"])
            self.assertEqual({"future-addon": ["local"]}, app.return_value["choices"])

        asyncio.run(check())

    def test_marketplace_is_the_shell_table(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("marketplace", [
                # A row's label is what it shows: the repository's GitHub name, the id beside it when they differ.
                {"id": "notebook", "label": "notebook-connector (notebook)", "version": "3.1.0",
                 "about": "Notebooks on the database", "choices": (("jupyterlab", "JupyterLab"), ("marimo", "Marimo"))},
                {"id": "dash-server", "label": "dash-server", "version": "0.1.1", "disabled": True, "reason": "Installed"}],
                {"notebook"}, {"jupyterlab"})
            async with app.run_test(size=(80, 30)):
                lines = app.render_screen(80)[0].plain.splitlines()
            self.assertEqual("    • Details on any add-on: exakit help <id>", lines[1])
            self.assertTrue(lines[2].startswith("  ╭─ Marketplace add-ons ─"))
            self.assertTrue(lines[2].endswith("╮"))
            self.assertRegex(lines[3], r"^  │     Add-on +Version  Description +│$")
            self.assertRegex(lines[5], r"^  │❯\[✓\] ├─ notebook-connector \(notebook\) +3\.1\.0 +Notebooks on the database +│$")
            self.assertRegex(lines[6], r"^  │ \[✓\] │  ├─ JupyterLab +│$")
            self.assertRegex(lines[7], r"^  │ \[ \] │  └─ Marimo +│$")
            self.assertRegex(lines[8], r"^  │     └─ dash-server +0\.1\.1 +Installed +│$")
            self.assertRegex(lines[9], r"^  │ \[ \] Skip +│$")
            self.assertTrue(lines[10].startswith("  ╰─") and lines[10].endswith("╯"))
            self.assertEqual("      ↑/↓ to move · Space to toggle · Enter to confirm", lines[11])
            self.assertEqual({len(line) for line in lines[2:11]}, {len(lines[2])})

        asyncio.run(check())

    def test_select_all_tracks_children_and_restores_missing_choices(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("marketplace", [{"id": "notebook", "label": "Notebooks",
                "choices": (("jupyterlab", "JupyterLab"), ("marimo", "Marimo"))}],
                {"notebook"}, {"jupyterlab"})
            async with app.run_test() as pilot:
                self.assertFalse(app._ticked("all", None))
                app.cursor = 0
                await pilot.press("space")
                self.assertEqual({"jupyterlab", "marimo"}, app.frontends)
                self.assertTrue(app._ticked("all", None))
                app.cursor = 3
                await pilot.press("space")
                self.assertFalse(app._ticked("all", None))
                app.cursor = 0
                await pilot.press("space")
                self.assertEqual({"jupyterlab", "marimo"}, app.frontends)
                await pilot.press("space")
                self.assertEqual(set(), app.selected)
                self.assertEqual(set(), app.frontends)
                await pilot.press("escape")
        asyncio.run(check())

    def test_notebook_menu_takes_jupyterlab_and_marimo_with_or_without_positron(self) -> None:
        from model import CatalogError
        from ui import notebook_tools

        two = [{"id": "jupyterlab"}, {"id": "marimo"}]
        self.assertEqual(two, notebook_tools({"tools": two}))
        self.assertEqual(3, len(notebook_tools({"tools": [*two, {"id": "positron"}]})))
        for tools in ([{"id": "jupyterlab"}], [*two, {"id": "marimo"}], [*two, {"id": "rstudio"}], "x"):
            with self.subTest(tools=tools), self.assertRaises(CatalogError):
                notebook_tools({"tools": tools})

    def test_notebook_tool_menu_keeps_disabled_positron_unselected(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("notebook", [{"id": "jupyterlab", "label": "JupyterLab"},
                                         {"id": "marimo", "label": "Marimo"},
                                         {"id": "positron", "label": "Positron", "disabled": True}],
                            {"jupyterlab"}, set())
            async with app.run_test() as pilot:
                app.cursor = 2
                await pilot.press("space")
                self.assertNotIn("positron", app.selected)
                await pilot.press("down")                       # the cursor steps over Positron
                self.assertEqual(3, app.cursor)
                app.cursor = 1
                await pilot.press("space")
                await pilot.press("enter")
            self.assertEqual(["jupyterlab", "marimo"], app.return_value["selected"])

        asyncio.run(check())

    def test_progress_is_the_tables_status_column(self) -> None:
        from ui import ChoiceApp
        from apply import Event

        async def check(width: int) -> None:
            app = ChoiceApp("marketplace", [{"id": "udf-devkit", "label": "script-languages-release (udf-devkit)",
                                             "version": "0.1.0"},
                                            {"id": "dash-server", "label": "dash-server", "version": "0.1.1"}],
                            {"udf-devkit", "dash-server"}, set())
            async with app.run_test(size=(width, 24)) as pilot:
                app.applying = True
                app._on_event(Event("dash-server", "done", "dashboards ready", 2))
                app._on_event(Event("udf-devkit", "installing"))
                app._on_activity("Waiting for database restart")
                lines = app.render_screen(width)[0].plain.splitlines()
                activity = next(i for i, line in enumerate(lines) if "Waiting for database restart" in line)
                self.assertIn("udf-devkit", lines[activity + 1])          # the activity sits above its row
                self.assertRegex(lines[activity + 1], r"░+ +0% +│$")      # the data-load table's bar
                done = next(line for line in lines if "dash-serv" in line)
                self.assertRegex(done, r"✓ dashboards ready +\(2s\) +│$")
                long = "Installing notebook connector 3.1.0 and every tool it brings along with it"
                app._on_activity(long)
                lines = app.render_screen(width)[0].plain.splitlines()
                said = next(line for line in lines if "Installing notebook connector" in line)
                self.assertEqual(len(said), len(done), "the activity stays inside the frame")
                if long not in said:                                    # cut where the cell ends, and says so
                    self.assertRegex(said, r"…\s*│$")
                self.assertFalse(any("Enter to confirm" in line for line in lines))
                self.assertFalse(any("❯" in line for line in lines))
                await pilot.press("escape")
                self.assertTrue(app.is_running)                  # no way out mid-install
                app.applying = False
                await pilot.press("escape")

        for width in (80, 120):
            with self.subTest(width=width):
                asyncio.run(check(width))

    def test_confirmed_marketplace_stays_in_textual_during_apply(self) -> None:
        from ui import ChoiceApp
        from apply import Event

        async def check() -> None:
            app = ChoiceApp("marketplace", [{"id": "dash-server", "label": "Dash Server"}],
                            {"dash-server"}, set(), apply_selection=True)

            def install(_ctx, ids, emit) -> bool:
                self.assertEqual("dash-server", ids)
                emit(Event("dash-server", "installing"))
                emit(Event("dash-server", "warning", "validation needs a retry"))
                emit(Event("dash-server", "validating"))
                emit(Event("dash-server", "done", "dashboards ready", 2))
                return True

            with patch("apply.apply", side_effect=install):
                async with app.run_test() as pilot:
                    app.cursor = 1
                    await pilot.press("enter")
                    await pilot.pause(0.2)
            self.assertTrue(app.return_value["success"])
            self.assertEqual(["dash-server"], app.return_value["selected"])
            self.assertEqual("dashboards ready", app.rows[0]["detail"])
            self.assertEqual("validation needs a retry", app.apply_events[1].detail)

        asyncio.run(check())



@unittest.skipIf(textual is None, "Textual is provided by uv at the persona boundary")
class FrameTest(unittest.TestCase):
    def test_a_frame_goes_out_without_its_padding(self) -> None:
        # A line padded to the last column re-wrapped unlike the redraw counts it (iTerm2 kept twice the old
        # frame above the new one): the padding goes, the rest of each line is cleared, the moves stay.
        from ui import _unpadded

        frame = "\x1b[1mab\x1b[0m   \x1b[0m  \nplain    \n│ x │\x1b[0m\n\x1b[J\x1b[3A"
        self.assertEqual("\x1b[1mab\x1b[0m\x1b[K\nplain\x1b[0m\x1b[K\n│ x │\x1b[0m\n\x1b[J\x1b[3A", _unpadded(frame))
        self.assertEqual("one line\x1b[0m\x1b[K", _unpadded("one line   "))
        self.assertEqual("no padding", _unpadded("no padding"))


if __name__ == "__main__":
    unittest.main()
