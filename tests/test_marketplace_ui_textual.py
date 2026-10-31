"""Exercise the actual Textual screen with its headless pilot."""

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


@unittest.skipIf(textual is None, "Textual is provided by uv at the persona boundary")
class ChoiceScreenTest(unittest.TestCase):
    def test_persona_confirm_and_cancel(self) -> None:
        from ui import ChoiceApp

        async def confirm() -> None:
            app = ChoiceApp("persona", [{"id": "operations", "label": "Operations"}], set(), set())
            async with app.run_test() as pilot:
                app.query_one("#table").move_cursor(row=0)
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

    def test_unavailable_addon_is_disabled(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("marketplace", [{"id": "notebook", "label": "Notebooks", "disabled": True,
                                             "detail": "managed outside the kit"}], {"notebook"}, {"marimo"})
            async with app.run_test() as pilot:
                app.query_one("#table").move_cursor(row=1)
                await pilot.press("space")
                self.assertEqual(set(), app.selected)
                await pilot.press("enter")
            self.assertEqual([], app.return_value["selected"])

        asyncio.run(check())

    def test_notebook_children_come_from_catalog_rows(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("marketplace", [{"id": "notebook", "label": "Notebooks",
                                             "choices": (("marimo", "Marimo"), ("future-ui", "Future UI"))}],
                            {"notebook"}, {"marimo"})
            async with app.run_test() as pilot:
                self.assertIn("future-ui", app.choices)
                app.query_one("#table").move_cursor(row=3)
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
                app.query_one("#table").move_cursor(row=3)
                await pilot.press("space")
                await pilot.press("enter")
            self.assertEqual(["future-addon"], app.return_value["selected"])
            self.assertEqual({"future-addon": ["local"]}, app.return_value["choices"])

        asyncio.run(check())

    def test_notebook_tool_menu_keeps_disabled_positron_unselected(self) -> None:
        from ui import ChoiceApp

        async def check() -> None:
            app = ChoiceApp("notebook", [{"id": "jupyterlab", "label": "JupyterLab"},
                                         {"id": "marimo", "label": "Marimo"},
                                         {"id": "positron", "label": "Positron", "disabled": True}],
                            {"jupyterlab"}, set())
            async with app.run_test() as pilot:
                app.query_one("#table").move_cursor(row=2)
                await pilot.press("space")
                self.assertNotIn("positron", app.selected)
                app.query_one("#table").move_cursor(row=1)
                await pilot.press("space")
                await pilot.press("enter")
            self.assertEqual(["jupyterlab", "marimo"], app.return_value["selected"])

        asyncio.run(check())

    def test_activity_is_above_progress_at_narrow_and_wide_terminal_sizes(self) -> None:
        from ui import ChoiceApp
        from apply import Event
        from textual.widgets import DataTable, ProgressBar, Static

        async def check(width: int) -> None:
            app = ChoiceApp("marketplace", [{"id": "udf-devkit", "label": "UDF Devkit"}],
                            {"udf-devkit"}, set())
            async with app.run_test(size=(width, 24)) as pilot:
                table = app.query_one(DataTable)
                self.assertEqual("[✓] Select All", table.get_cell_at((0, 0)))
                self.assertEqual("[ ] Skip", table.get_cell_at((2, 0)))
                activity = app.query_one("#activity", Static)
                progress = app.query_one("#progress", ProgressBar)
                activity.display = progress.display = True
                app.applying = True
                app._on_event(Event("udf-devkit", "installing"))
                app._on_activity("Waiting for database restart")
                await pilot.pause()
                self.assertLess(activity.region.y, progress.region.y)
                self.assertGreater(activity.region.width, 0)
                self.assertIn("Waiting for database restart", str(activity.render()))
                self.assertEqual(0, progress.progress)
                await pilot.press("escape")
                self.assertTrue(app.is_running)
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
                    app.query_one("#table").move_cursor(row=1)
                    await pilot.press("enter")
                    await pilot.pause(0.2)
            self.assertTrue(app.return_value["success"])
            self.assertEqual(["dash-server"], app.return_value["selected"])
            self.assertEqual("dashboards ready", app.rows[0]["detail"])
            self.assertEqual("validation needs a retry", app.apply_events[1].detail)

        asyncio.run(check())


if __name__ == "__main__":
    unittest.main()
