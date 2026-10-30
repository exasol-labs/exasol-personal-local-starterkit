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
