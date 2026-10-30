"""Persona add sequence and failure recovery with child CLIs stubbed."""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import persona_apply  # noqa: E402
from model import Addon  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402


class PersonaApplyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"persona": {"id": "data-scientist"}}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_union_runs_three_existing_services_and_new_persona_service(self) -> None:
        calls = []

        def child(_prefix, command, args, env):
            calls.append((command, args, dict(env)))
            return True

        with patch.dict(os.environ, {"EXAKIT_DATASETS": "", "EXAKIT_MCP_CLIENTS": "",
                                     "EXAKIT_MARKETPLACE_ADDONS": "", "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_child", side_effect=child), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "ml-engineer", ["exakit"]))
        self.assertEqual("data-scientist,ml-engineer", self.manifest.get("persona.id"))
        self.assertEqual("add", self.manifest.get("persona.source"))
        self.assertEqual(["data-load", "mcp-setup", "marketplace", "mlflow"],
                         [command for command, _, _ in calls])
        self.assertIn("pharma_trials", calls[0][2]["EXAKIT_DATASETS"])
        self.assertIn("udf-devkit", calls[2][2]["EXAKIT_MARKETPLACE_ADDONS"])
        self.assertEqual("start", calls[3][1][0])

    def test_one_failed_part_keeps_other_steps_and_retryable_membership(self) -> None:
        calls = []

        def child(_prefix, command, _args, _env):
            calls.append(command)
            return command != "data-load"

        output = io.StringIO()
        with patch.dict(os.environ, {"EXAKIT_DATASETS": "", "EXAKIT_MCP_CLIENTS": "",
                                     "EXAKIT_MARKETPLACE_ADDONS": "", "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_child", side_effect=child), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(output):
            self.assertEqual(1, persona_apply.apply(self.ctx, "ml-engineer", ["exakit"]))
        self.assertEqual(["data-load", "mcp-setup", "marketplace", "mlflow"], calls)
        self.assertIn("retry with: EXAKIT_DATASETS=", output.getvalue())
        self.assertEqual("data-scientist,ml-engineer", self.manifest.get("persona.id"))

    def test_explicit_answer_wins_and_interactive_children_use_existing_tables(self) -> None:
        calls = []

        def child(_prefix, command, _args, env):
            calls.append((command, dict(env)))
            return True

        with patch.dict(os.environ, {"EXAKIT_DATASETS": "tpch", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "notebook", "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_child", side_effect=child), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "data-scientist", ["exakit"], live=True))
        self.assertEqual(["data-load", "marketplace"], [command for command, _ in calls])
        self.assertEqual("tpch", calls[0][1]["EXAKIT_DATASETS_PRESELECT"])
        self.assertNotIn("EXAKIT_DATASETS", calls[0][1])
        self.assertEqual("notebook", calls[1][1]["EXAKIT_MARKETPLACE_ONLY"])
        self.assertNotIn("EXAKIT_MARKETPLACE_ADDONS", calls[1][1])

    def test_reapply_only_runs_missing_datasets_and_addons(self) -> None:
        calls = []
        output = io.StringIO()

        def child(_prefix, command, _args, env):
            calls.append((command, dict(env)))
            return True

        def query(_prefix, command, _args, _env):
            if command == "status":
                return {"datasets_loaded": ["pharma_trials"]}
            return {"addons": [{"id": "notebook", "installed": True},
                               {"id": "dash-server", "status": "managed outside the kit"}]}

        with patch.dict(os.environ, {"EXAKIT_DATASETS": "pharma_trials,banking_complaints",
                                     "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "notebook,dash-server,udf-devkit",
                                     "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_query", side_effect=query), \
             patch.object(persona_apply, "_child", side_effect=child), \
             contextlib.redirect_stdout(output):
            self.assertEqual(0, persona_apply.apply(self.ctx, "ml-engineer", ["exakit"]))
        self.assertEqual(["data-load", "marketplace", "mlflow"], [name for name, _ in calls])
        self.assertEqual("banking_complaints", calls[0][1]["EXAKIT_DATASETS"])
        self.assertEqual("udf-devkit", calls[1][1]["EXAKIT_MARKETPLACE_ADDONS"])
        self.assertIn("Already loaded: Pharma clinical trials", output.getvalue())
        self.assertIn("Already installed: notebook", output.getvalue())
        self.assertIn("Already available outside the kit: dash-server", output.getvalue())

    def test_disabled_addon_fails_before_membership_change(self) -> None:
        addon = Addon("notebook", "Notebooks", "python", "3.1.0", "3.1.0", False, ())
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ADDONS": "notebook"}), \
             patch.object(persona_apply, "load_addons", return_value=[addon]):
            with self.assertRaises(persona_apply.CatalogError):
                persona_apply.apply(self.ctx, "data-scientist", ["exakit"])
        self.assertEqual("data-scientist", self.manifest.get("persona.id"))

    def test_existing_hidden_addon_can_remain_in_persona(self) -> None:
        addon = Addon("notebook", "Notebooks", "python", "3.1.0", "3.1.0", False, ())
        calls = []
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ADDONS": "notebook",
                                     "EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip"}), \
             patch.object(persona_apply, "load_addons", return_value=[addon]), \
             patch.object(persona_apply, "_query", return_value={"addons": [
                 {"id": "notebook", "installed": True}]}), \
             patch.object(persona_apply, "_child", side_effect=lambda _p, command, _a, _e:
                          calls.append(command) or True), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "data-scientist", ["exakit"]))
        self.assertNotIn("marketplace", calls)

    def test_bad_dataset_fails_before_membership_change(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_DATASETS": "missing-dataset"}):
            with self.assertRaises(persona_apply.persona_service.BadInput):
                persona_apply.apply(self.ctx, "ml-engineer", ["exakit"])
        self.assertEqual("data-scientist", self.manifest.get("persona.id"))

    def test_marketplace_answer_keeps_existing_case_insensitive_ids(self) -> None:
        self.assertEqual(["notebook", "udf-devkit"],
                         persona_apply._requested_addons(ROOT, "NOTEBOOK, UDF-DEVKIT"))
        self.assertEqual([], persona_apply._requested_addons(ROOT, " NONE "))

    def test_empty_persona_answers_do_not_probe_resource_state(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "none"}), \
             patch.object(persona_apply, "_query") as query, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "data-scientist", ["exakit"]))
        query.assert_not_called()

    def test_explicit_no_addons_does_not_start_mlflow(self) -> None:
        output = io.StringIO()
        with patch.dict(os.environ, {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "none"}), \
             patch.object(persona_apply, "_child") as child, contextlib.redirect_stdout(output):
            self.assertEqual(0, persona_apply.apply(self.ctx, "ml-engineer", ["exakit"]))
        child.assert_not_called()
        self.assertIn("Skipping MLflow service - missing: udf-devkit, notebook", output.getvalue())

    def test_failed_udf_addon_does_not_start_mlflow(self) -> None:
        calls = []

        def child(_prefix, command, _args, _env):
            calls.append(command)
            return command != "marketplace"

        with patch.dict(os.environ, {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "udf-devkit"}), \
             patch.object(persona_apply, "_child", side_effect=child), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(1, persona_apply.apply(self.ctx, "ml-engineer", ["exakit"]))
        self.assertEqual(["marketplace"], calls)

    def test_existing_kit_udf_still_starts_mlflow_with_no_new_addons(self) -> None:
        self.manifest.set_many({"components.udf_devkit.ownership": "kit",
                                "components.notebook.ownership": "kit"})
        calls = []
        with patch.dict(os.environ, {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "none"}), \
             patch.object(persona_apply, "_child", side_effect=lambda _p, command, _a, _e:
                          calls.append(command) or True), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "ml-engineer", ["exakit"]))
        self.assertEqual(["mlflow"], calls)


if __name__ == "__main__":
    unittest.main()
