"""Persona add sequence and failure recovery with child CLIs stubbed."""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from cli_entrypoints import entrypoints

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
import persona_apply  # noqa: E402
from model import Addon  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402


sys.path.insert(0, str(ROOT / "tests"))
from release_kit import kit_with_hidden_parts_on  # noqa: E402  (the fixture personas: analyst, engineer)


class PersonaApplyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.kit = tempfile.TemporaryDirectory()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text(json.dumps({"persona": {"id": "analyst"}}))
        root = kit_with_hidden_parts_on(Path(self.kit.name) / "kit", personas=("analyst", "engineer"))
        self.ctx = KitContext(root, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()
        self.kit.cleanup()

    def test_a_persona_the_shipped_kit_lacks_is_refused(self) -> None:
        shipped = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))
        with self.assertRaisesRegex(persona_apply.persona_service.BadInput, "engineer"):
            persona_apply.apply(shipped, "engineer", ["exakit"])
        self.assertEqual("analyst", self.manifest.get("persona.id"))

    def test_union_runs_the_three_existing_steps(self) -> None:
        calls = []

        def child(_prefix, command, args, env):
            calls.append((command, args, dict(env)))
            return True

        with patch.dict(os.environ, {"EXAKIT_DATASETS": "", "EXAKIT_MCP_CLIENTS": "",
                                     "EXAKIT_MARKETPLACE_ADDONS": "", "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_child", side_effect=child), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "engineer", ["exakit"]))
        self.assertEqual("analyst,engineer", self.manifest.get("persona.id"))
        self.assertEqual("add", self.manifest.get("persona.source"))
        self.assertEqual(["data-load", "mcp-setup", "marketplace"],
                         [command for command, _, _ in calls])
        self.assertIn("orders_demo", calls[0][2]["EXAKIT_DATASETS"])
        self.assertIn("exasol-scheduler", calls[2][2]["EXAKIT_MARKETPLACE_ADDONS"])

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
            self.assertEqual(1, persona_apply.apply(self.ctx, "engineer", ["exakit"]))
        self.assertEqual(["data-load", "mcp-setup", "marketplace"], calls)
        self.assertIn("retry with: EXAKIT_DATASETS=", output.getvalue())
        self.assertEqual("analyst,engineer", self.manifest.get("persona.id"))

    def test_explicit_answer_wins_and_interactive_children_use_existing_tables(self) -> None:
        calls = []

        def child(_prefix, command, _args, env):
            calls.append((command, dict(env)))
            return True

        with patch.dict(os.environ, {"EXAKIT_DATASETS": "tpch", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "dbt-exasol", "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_child", side_effect=child), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "analyst", ["exakit"], live=True))
        self.assertEqual(["data-load", "marketplace"], [command for command, _ in calls])
        self.assertEqual("tpch", calls[0][1]["EXAKIT_DATASETS_PRESELECT"])
        self.assertNotIn("EXAKIT_DATASETS", calls[0][1])
        # Every add-on and sample is listed and asked, the persona's ticked: no filter, no auto-confirm.
        self.assertEqual("dbt-exasol", calls[1][1]["EXAKIT_MARKETPLACE_PRESELECT"])
        self.assertNotIn("EXAKIT_MARKETPLACE_ONLY", calls[1][1])
        self.assertNotIn("EXAKIT_MARKETPLACE_ADDONS", calls[1][1])
        self.assertNotIn("UI_TABLE_AUTO", calls[0][1])
        self.assertNotIn("UI_TABLE_AUTO", calls[1][1])

    def test_reapply_only_runs_missing_datasets_and_addons(self) -> None:
        calls = []
        output = io.StringIO()

        def child(_prefix, command, _args, env):
            calls.append((command, dict(env)))
            return True

        def query(_prefix, command, _args, _env):
            if command == "status":
                return {"datasets_loaded": ["payments_demo"]}
            return {"addons": [{"id": "dbt-exasol", "installed": True},
                               {"id": "dash-server", "status": "managed outside the kit"}]}

        with patch.dict(os.environ, {"EXAKIT_DATASETS": "orders_demo,payments_demo",
                                     "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "dbt-exasol,dash-server,exasol-scheduler",
                                     "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_query", side_effect=query), \
             patch.object(persona_apply, "_child", side_effect=child), \
             contextlib.redirect_stdout(output):
            self.assertEqual(0, persona_apply.apply(self.ctx, "engineer", ["exakit"]))
        self.assertEqual(["data-load", "marketplace"], [name for name, _ in calls])
        self.assertEqual("orders_demo", calls[0][1]["EXAKIT_DATASETS"])
        self.assertEqual("exasol-scheduler", calls[1][1]["EXAKIT_MARKETPLACE_ADDONS"])
        self.assertIn("Already loaded: Payments demo", output.getvalue())
        self.assertIn("Already installed: dbt-exasol", output.getvalue())
        self.assertIn("Already available outside the kit: dash-server", output.getvalue())

    def test_disabled_addon_fails_before_membership_change(self) -> None:
        addon = Addon("dbt-exasol", "dbt-exasol", "python", "1.12.3", "1.12.3", False, ())
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ADDONS": "dbt-exasol"}), \
             patch.object(persona_apply, "load_addons", return_value=[addon]):
            with self.assertRaises(persona_apply.CatalogError):
                persona_apply.apply(self.ctx, "analyst", ["exakit"])
        self.assertEqual("analyst", self.manifest.get("persona.id"))

    def test_existing_hidden_addon_can_remain_in_persona(self) -> None:
        addon = Addon("dbt-exasol", "dbt-exasol", "python", "1.12.3", "1.12.3", False, ())
        calls = []
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ADDONS": "dbt-exasol",
                                     "EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip"}), \
             patch.object(persona_apply, "load_addons", return_value=[addon]), \
             patch.object(persona_apply, "_query", return_value={"addons": [
                 {"id": "dbt-exasol", "installed": True}]}), \
             patch.object(persona_apply, "_child", side_effect=lambda _p, command, _a, _e:
                          calls.append(command) or True), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "analyst", ["exakit"]))
        self.assertNotIn("marketplace", calls)

    def test_bad_dataset_fails_before_membership_change(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_DATASETS": "missing-dataset"}):
            with self.assertRaises(persona_apply.persona_service.BadInput):
                persona_apply.apply(self.ctx, "engineer", ["exakit"])
        self.assertEqual("analyst", self.manifest.get("persona.id"))

    def test_external_is_the_menu_row_and_persona_add_skips_it(self) -> None:
        # EXAKIT_DATASETS may carry `external` (the data menu's external-source
        # row) from the shell or exakit.env: not a dataset, and not an error.
        self.assertEqual(["retail_sales"], persona_apply._requested_datasets(ROOT, "retail_sales,external"))
        self.assertEqual([], persona_apply._requested_datasets(ROOT, "external"))
        with self.assertRaises(persona_apply.persona_service.BadInput):
            persona_apply._requested_datasets(ROOT, "retail_sales,nope")
        calls = []
        with patch.dict(os.environ, {"EXAKIT_DATASETS": "orders_demo,external", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "none", "EXAKIT_SKIP_MCP": ""}), \
             patch.object(persona_apply, "_query", return_value=None), \
             patch.object(persona_apply, "_child", side_effect=lambda _p, command, _a, env:
                          calls.append((command, dict(env))) or True), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "analyst", ["exakit"]))
        self.assertEqual("data-load", calls[0][0])
        self.assertEqual("orders_demo", calls[0][1]["EXAKIT_DATASETS"])

    def test_marketplace_answer_keeps_existing_case_insensitive_ids(self) -> None:
        self.assertEqual(["dbt-exasol", "exasol-scheduler"],
                         persona_apply._requested_addons(ROOT, "DBT-EXASOL, EXASOL-SCHEDULER"))
        self.assertEqual([], persona_apply._requested_addons(ROOT, " NONE "))

    def test_empty_persona_answers_do_not_probe_resource_state(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "none"}), \
             patch.object(persona_apply, "_query") as query, \
             patch.object(persona_apply, "_child", return_value=True) as child, \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(0, persona_apply.apply(self.ctx, "analyst", ["exakit"]))
        query.assert_not_called()
        # No skill names the fixture persona ("persona:" in a SKILL.md), so no child command is left.
        self.assertEqual([], [call.args[1] for call in child.call_args_list])

    def test_explicit_no_addons_runs_nothing(self) -> None:
        output = io.StringIO()
        with patch.dict(os.environ, {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "none"}), \
             patch.object(persona_apply, "_child") as child, contextlib.redirect_stdout(output):
            self.assertEqual(0, persona_apply.apply(self.ctx, "engineer", ["exakit"]))
        child.assert_not_called()

    def test_a_failed_addon_install_is_reported(self) -> None:
        calls = []

        def child(_prefix, command, _args, _env):
            calls.append(command)
            return command != "marketplace"

        with patch.dict(os.environ, {"EXAKIT_LOAD_SAMPLE": "0", "EXAKIT_MCP_CLIENTS": "skip",
                                     "EXAKIT_MARKETPLACE_ADDONS": "exasol-scheduler"}), \
             patch.object(persona_apply, "_child", side_effect=child), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(1, persona_apply.apply(self.ctx, "engineer", ["exakit"]))
        self.assertEqual(["marketplace"], calls)

    def test_public_add_apply_remove_preserve_shared_files(self) -> None:
        commands = entrypoints(self.ctx.root)     # Data Analyst is disabled in the shipped kit; this one has it on
        self.assertTrue(commands)
        shared = self.home / 'shared' / 'my-work.txt'
        shared.parent.mkdir()
        shared.write_text('keep my work')
        env = {**os.environ, 'EXAKIT_HOME': str(self.home), 'EXAKIT_BIN_DIR': str(self.home / 'bin'),
               'EXAKIT_NO_UPDATE_NOTICE': '1', 'EXAKIT_NO_FANCY': '1', 'EXAKIT_LOAD_SAMPLE': '0',
               'EXAKIT_DATASETS': '', 'EXAKIT_MCP_CLIENTS': 'skip', 'EXAKIT_MARKETPLACE_ADDONS': 'none'}
        for prefix in commands:
            with self.subTest(shell=prefix[0]):
                self.manifest.delete('persona')
                for args in (('add', 'analyst'), ('apply', 'general', '--yes'), ('add', 'general')):
                    result = subprocess.run([*prefix, 'persona', *args], env=env, input='',
                                            capture_output=True, text=True, timeout=45)
                    self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual('analyst,general', self.manifest.get('persona.id'))
                for _ in range(2):
                    result = subprocess.run([*prefix, 'persona', 'remove', 'analyst'], env=env, input='',
                                            capture_output=True, text=True, timeout=45)
                    self.assertEqual(0, result.returncode, result.stdout + result.stderr)
                self.assertEqual('general', self.manifest.get('persona.id'))
                self.assertEqual('keep my work', shared.read_text())


if __name__ == "__main__":
    unittest.main()
