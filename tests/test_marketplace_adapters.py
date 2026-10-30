"""Dry-run must cross each thin platform adapter without changing resources."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AdapterDryRunTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="exakit adapter ")
        self.base = Path(self.temp.name)
        self.home = self.base / "kit home"
        self.home.mkdir()
        self.bin_dir = self.base / "kit bin"
        self.bin_dir.mkdir()
        (self.home / "manifest.json").write_text(json.dumps({"components": {
            "dbt_exasol": {"ownership": "kit", "version": "1.12.1"}}}))
        self.venv = self.home / "dbt-exasol-venv"
        self.venv.mkdir()
        self.profile = self.home / "dbt" / "profiles.yml"
        self.profile.parent.mkdir()
        self.profile.write_text("generated profile\n")
        self.launcher = self.bin_dir / ("dbt-exasol.cmd" if os.name == "nt" else "dbt-exasol")
        self.launcher.write_text("generated launcher\n")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _environment(self) -> dict[str, str]:
        return {**os.environ, "EXAKIT_HOME": str(self.home), "EXAKIT_BIN_DIR": str(self.bin_dir),
                "EXAKIT_NO_FANCY": "1", "HOME": str(self.base)}

    def _assert_preserved(self) -> None:
        self.assertTrue(self.venv.exists())
        self.assertTrue(self.profile.exists())
        self.assertTrue(self.launcher.exists())
        self.assertEqual("kit", json.loads((self.home / "manifest.json").read_text())
                         ["components"]["dbt_exasol"]["ownership"])

    def test_bash_uninstall_preview_keeps_everything(self) -> None:
        script = f'. "{ROOT / "setup/lib/common.sh"}"\n_exakit_marketplace_load_modules\ndbt_exasol_uninstall 1\n'
        result = subprocess.run(["bash", "-c", script], env=self._environment(),
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(str(self.profile), result.stdout)
        self._assert_preserved()

    def test_public_catalog_lists_dbt_on_both_platform_entry_points(self) -> None:
        commands = [[str(ROOT / "setup/exakit")]]
        if shutil.which("pwsh"):
            commands.append(["pwsh", "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")])
        for prefix in commands:
            with self.subTest(prefix=prefix[0]):
                result = subprocess.run([*prefix, "marketplace", "--list", "--json"],
                                        env=self._environment(), capture_output=True,
                                        text=True, timeout=35, check=False)
                self.assertEqual(0, result.returncode, result.stderr)
                addons = json.loads(result.stdout)["addons"]
                self.assertIn("dbt-exasol", {addon["id"] for addon in addons})

    def test_bash_install_passes_selected_version_document(self) -> None:
        selected = self.base / "selected versions.json"
        selected.write_text('{"components":{}}')
        script = (f'. "{ROOT / "setup/lib/common.sh"}"\n'
                  f'exakit_versions_active_doc() {{ printf "%s\\n" "{selected}"; }}\n'
                  'exakit_component_available() { printf "2.0.0\\n"; }\n'
                  '_exakit_marketplace_run_python() { '
                  'printf "%s|%s\\n" "$EXAKIT_MARKETPLACE_VERSIONS_DOC" '
                  '"$EXAKIT_MARKETPLACE_TARGET_VERSION"; }\n'
                  '_exakit_marketplace_python dash-server install\n'
                  '_exakit_marketplace_cli udf_manage udf-use --list\n')
        environment = {**self._environment(), "EXAKIT_VERSION_POLICY": "manifest"}
        result = subprocess.run(["bash", "-c", script], env=environment,
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([f"{selected}|2.0.0", f"{selected}|"], result.stdout.splitlines())

    def test_notebook_python_lifecycle_and_choices_need_no_legacy_module(self) -> None:
        script = (f'. "{ROOT / "setup/lib/common.sh"}"\n'
                  'EXAKIT_MARKETPLACE_PYTHON_HOOKS=1 _exakit_marketplace_python_hooks\n'
                  'declare -f notebook_install\n'
                  'notebook_table_children\n'
                  'notebook_table_children_picked marimo,positron\n'
                  'printf "selected=%s\\n" "$EXAKIT_NOTEBOOK_FRONTENDS"\n')
        result = subprocess.run(["bash", "-c", script], env=self._environment(),
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("_exakit_marketplace_python 'notebook' 'install'", result.stdout)
        self.assertIn("jupyterlab|JupyterLab|", result.stdout)
        self.assertIn("selected=marimo,positron", result.stdout)

    def test_bash_json_loader_needs_no_legacy_addon_module(self) -> None:
        engine = self.bin_dir / "exasol-json-tables"
        engine.write_text("#!/bin/sh\nprintf 'ingested\\n'\n", encoding="utf-8")
        engine.chmod(0o755)
        script = (f'. "{ROOT / "setup/lib/common.sh"}"\n'
                  f'. "{ROOT / "setup/lib/exapump.sh"}"\n'
                  'exakit_component_current() { printf "v0.3.2\\n"; }\n'
                  '_exakit_json_tables_ready && _exakit_json_tables_logged '
                  f'"{engine}" ingest\n')
        result = subprocess.run(["bash", "-c", script], env=self._environment(),
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("ingested", result.stdout)
        self.assertIn("ingested", (self.home / "logs/json-tables.log").read_text(encoding="utf-8"))

    def test_bash_json_loader_registers_python_hook_once_per_run(self) -> None:
        script = (f'. "{ROOT / "setup/lib/exapump.sh"}"\n'
                  '_exakit_marketplace_load_modules() { printf x >> "$EXAKIT_HOME/load-count"; }\n'
                  'exakit_marketplace_addon_available() { return 0; }\n'
                  '_exakit_json_tables_load_module\n'
                  '_exakit_json_tables_load_module\n')
        result = subprocess.run(["bash", "-c", script], env=self._environment(),
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("x", (self.home / "load-count").read_text(encoding="utf-8"))

    def test_bash_selection_controller_streams_python_result(self) -> None:
        script = (f'. "{ROOT / "setup/lib/common.sh"}"\n'
                  'EXAKIT_MARKETPLACE_PYTHON_APPLY=1\n'
                  '_exakit_marketplace_questions() { :; }\n'
                  '_exakit_marketplace_run_python() { '
                  'printf "@@EXAKIT|dash-server|installing||0\\n@@EXAKIT|dash-server|done|ready|2\\n"; }\n'
                  '_exakit_marketplace_apply dash-server\n')
        result = subprocess.run(["bash", "-c", script], env=self._environment(),
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("dash-server installed", result.stdout)
        self._assert_preserved()

    def test_public_marketplace_preflights_selection(self) -> None:
        checkout = self.base / "checkout with spaces"
        for name in ("setup", "marketplace", "personas", "data"):
            shutil.copytree(ROOT / name, checkout / name)
        shutil.copy2(ROOT / "versions.json", checkout / "versions.json")
        home = self.base / "fault kit"
        home.mkdir()
        (home / "manifest.json").write_text("{}\n")
        environment = {**self._environment(), "EXAKIT_HOME": str(home),
                       "EXAKIT_MARKETPLACE_ADDONS": "dash-server,notebook",
                       "EXAKIT_NOTEBOOK_FRONTENDS": "jupyterlab,unknown-tool",
                       "EXAKIT_MARKETPLACE_PYTHON_APPLY": "1"}
        commands = [[str(checkout / "setup/exakit")]]
        if shutil.which("pwsh"):
            commands.append(["pwsh", "-NoProfile", "-File", str(checkout / "setup/exakit.ps1")])
        for command in commands:
            with self.subTest(command=command[0]):
                result = subprocess.run([*command, "marketplace"], env=environment,
                                        capture_output=True, text=True, timeout=35, check=False)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("Unknown or repeated notebook frontend", result.stdout + result.stderr)
                self.assertIsNone(json.loads((home / "manifest.json").read_text())
                                  .get("components", {}).get("dash_server"))
        for answer, error in (("dash-server,", "empty add-on ID"),
                              ("dash-server,,notebook", "empty add-on ID"),
                              ("dash-server,unknown-addon", "Unknown marketplace add-on")):
            for command in commands:
                with self.subTest(command=command[0], answer=answer):
                    result = subprocess.run([*command, "marketplace"],
                                            env={**environment, "EXAKIT_MARKETPLACE_ADDONS": answer},
                                            capture_output=True, text=True, timeout=35, check=False)
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn(error, result.stdout + result.stderr)
                    self.assertIsNone(json.loads((home / "manifest.json").read_text())
                                      .get("components", {}).get("dash_server"))
        (checkout / "marketplace/catalog.json").write_text("{broken", encoding="utf-8")
        for command in commands:
            with self.subTest(command=command[0], fault="malformed catalog"):
                result = subprocess.run([*command, "marketplace"], env=environment,
                                        capture_output=True, text=True, timeout=35, check=False)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("marketplace catalog:", result.stdout + result.stderr)
                self.assertIsNone(json.loads((home / "manifest.json").read_text())
                                  .get("components", {}).get("dash_server"))
        catalog = json.loads((ROOT / "marketplace/catalog.json").read_text(encoding="utf-8"))
        catalog["addons"][0].pop("default_version")
        (checkout / "marketplace/catalog.json").write_text(json.dumps(catalog), encoding="utf-8")
        for command in commands:
            with self.subTest(command=command[0], fault="missing fallback version"):
                result = subprocess.run([*command, "marketplace"], env=environment,
                                        capture_output=True, text=True, timeout=35, check=False)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("missing default_version", result.stdout + result.stderr)
                self.assertIsNone(json.loads((home / "manifest.json").read_text())
                                  .get("components", {}).get("dash_server"))
        catalog = json.loads((ROOT / "marketplace/catalog.json").read_text(encoding="utf-8"))
        next(row for row in catalog["addons"] if row["id"] == "dash-server")["visible"] = False
        (checkout / "marketplace/catalog.json").write_text(json.dumps(catalog), encoding="utf-8")
        direct_environment = {key: value for key, value in environment.items()
                              if key != "EXAKIT_MARKETPLACE_ADDONS"}
        path_dirs = {str(Path(shutil.which("python3")).parent)}
        if shutil.which("pwsh"):
            path_dirs.add(str(Path(shutil.which("pwsh")).parent))
        direct_environment["PATH"] = os.pathsep.join([*sorted(path_dirs), os.defpath])
        for command in commands:
            for addon_id, expected in (("dash-server", "disabled in marketplace/catalog.json"),
                                       ("unknown-addon", "Unknown marketplace add-on")):
                with self.subTest(command=command[0], addon=addon_id):
                    result = subprocess.run([*command, "marketplace", addon_id], env=direct_environment,
                                            capture_output=True, text=True, timeout=35, check=False)
                    self.assertIn(expected, result.stdout + result.stderr)
                    if addon_id == "unknown-addon":
                        self.assertNotEqual(0, result.returncode)
                    self.assertIsNone(json.loads((home / "manifest.json").read_text())
                                      .get("components", {}).get("dash_server"))

    def test_udf_command_refusal_is_one_json_object_on_both_entry_points(self) -> None:
        commands = [[str(ROOT / "setup/exakit")]]
        if shutil.which("pwsh"):
            commands.append(["pwsh", "-NoProfile", "-File", str(ROOT / "setup/exakit.ps1")])
        for prefix in commands:
            with self.subTest(prefix=prefix[0]):
                result = subprocess.run([*prefix, "udf-setup", "--json"], env=self._environment(),
                                        capture_output=True, text=True, timeout=90, check=False)
                self.assertEqual(5, result.returncode, result.stderr)
                payload = json.loads(result.stdout)
                self.assertEqual("select-container", payload["step"])
                self.assertEqual("exakit marketplace udf-devkit", payload["remedy"])

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is not installed")
    def test_powershell_uninstall_preview_keeps_everything(self) -> None:
        script = (f'. "{ROOT / "setup/lib/exakit-common.ps1"}"\n'
                  f'. "{ROOT / "setup/lib/persona.ps1"}"\n'
                  'Initialize-ExakitMarketplacePythonHooks\n'
                  'Invoke-MarketplaceDbtExasolUninstall -DryRun\n')
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=self._environment(),
                                capture_output=True, text=True, timeout=45, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("will remove", result.stdout)
        self._assert_preserved()

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is not installed")
    def test_powershell_install_passes_selected_version_document(self) -> None:
        selected = self.base / "selected versions.json"
        selected.write_text('{"components":{}}')
        captured = self.base / "captured version.txt"
        fake = self.base / "fake uv"
        fake.write_text("#!/bin/sh\nprintf '%s|%s\\n' \"$EXAKIT_MARKETPLACE_VERSIONS_DOC\" "
                        "\"$EXAKIT_MARKETPLACE_TARGET_VERSION\" >> \"$EXAKIT_TEST_CAPTURE\"\n", encoding="utf-8")
        fake.chmod(0o755)
        script = (f'. "{ROOT / "setup/lib/exakit-common.ps1"}"\n'
                  f'function Resolve-ExakitVersionsDoc {{ return "{selected}" }}\n'
                  'function Get-ExakitComponentAvailable { return "2.0.0" }\n'
                  "function Get-ExakitPersonaPython { return '' }\n"
                  f'function Get-ExakitUvBin {{ return "{fake}" }}\n'
                  'Invoke-ExakitMarketplacePython -Id dash-server -Operation install | Out-Null\n'
                  "Invoke-ExakitMarketplaceCli -Script udf_manage -CmdArgs @('udf-use','--list')\n")
        environment = {**self._environment(), "EXAKIT_VERSION_POLICY": "manifest",
                       "EXAKIT_TEST_CAPTURE": str(captured)}
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=environment,
                                capture_output=True, text=True, timeout=35, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([f"{selected}|2.0.0", f"{selected}|"], captured.read_text().splitlines())

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is not installed")
    def test_powershell_json_loader_uses_python_marketplace_hooks(self) -> None:
        engine = self.bin_dir / "exasol-json-tables.cmd"
        engine.write_text("stub", encoding="utf-8")
        script = (f'. "{ROOT / "setup/lib/exakit-common.ps1"}"\n'
                  f'. "{ROOT / "setup/lib/exapump.ps1"}"\n'
                  'function Get-ExakitManifestValue { param([string]$Path) '
                  f'if ($Path -eq "components.json_tables.command") {{ return "{engine}" }} }}\n'
                  'function Invoke-ExakitMarketplacePython { param([string]$Id, [string]$Operation) '
                  'if ($Id -ne "json-tables") { throw "wrong add-on" }; '
                  'if ($Operation -eq "installed-version") { return "v0.3.2" }; '
                  'if ($Operation -eq "applicable") { return $true } }\n'
                  '"$(Test-ExakitJsonTablesReady)|$(Test-ExakitJsonTablesApplicable)|$(Get-ExakitJsonTablesBin)"\n')
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=self._environment(),
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f"True|True|{engine}", result.stdout)

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell is not installed")
    def test_powershell_selection_controller_streams_python_result(self) -> None:
        fake = self.base / ("fake-uv.cmd" if os.name == "nt" else "fake-uv")
        if os.name == "nt":
            fake.write_text("@echo off\r\necho @@EXAKIT^|dash-server^|installing^|^|0\r\n"
                            "echo @@EXAKIT^|dash-server^|done^|ready^|2\r\n", encoding="ascii")
        else:
            fake.write_text("#!/bin/sh\nprintf '@@EXAKIT|dash-server|installing||0\\n"
                            "@@EXAKIT|dash-server|done|ready|2\\n'\n", encoding="utf-8")
            fake.chmod(0o755)
        script = (f'. "{ROOT / "setup/lib/exakit-common.ps1"}"\n'
                  'function Invoke-ExakitMarketplaceQuestions { param([string[]]$Ids) }\n'
                  f'function Get-ExakitUvBin {{ return "{fake}" }}\n'
                  'Invoke-ExakitMarketplaceApplyPython -Ids @("dash-server")\n')
        result = subprocess.run(["pwsh", "-NoProfile", "-Command", script], env=self._environment(),
                                capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("dash-server installed", result.stdout)
        self._assert_preserved()


if __name__ == "__main__":
    unittest.main()
