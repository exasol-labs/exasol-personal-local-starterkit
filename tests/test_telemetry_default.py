"""DS1.6: Exasol usage telemetry stays off in every process the kit starts, and a value the user set is kept.

pyexasol 3 sends one anonymous usage event per connect through exasol-telemetry-client unless
EXASOL_TELEMETRY_DISABLE is present (any value disables it). Each entry point below is checked twice: with the
variable absent it must reach pyexasol (or the child process) as "1"; with the user's own value it must arrive
unchanged. The last class is the source-wide grep guard, in the style of the X1.2 credential scan.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import runpy
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
sys.path.insert(0, str(ROOT / "setup" / "lib"))

import kit_telemetry  # noqa: E402
import dash_launcher  # noqa: E402
import dbt_launcher  # noqa: E402
import scheduler_launcher  # noqa: E402
from addons import json_tables  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402

VAR = "EXASOL_TELEMETRY_DISABLE"
USER = "set-by-user"
CASES = (({}, "1"), ({VAR: USER}, USER), ({VAR: ""}, ""))   # absent -> "1"; a user value, even empty, is kept


def _without_var() -> dict[str, str]:
    return {k: v for k, v in os.environ.items() if k != VAR}


def _fake_modules(**modules: dict) -> dict[str, types.ModuleType]:
    """Stand-in packages so a connect path can run without pyexasol or a database."""
    built = {}
    for dotted, attrs in modules.items():
        parts = dotted.split(".")
        for i in range(1, len(parts) + 1):
            name = ".".join(parts[:i])
            built.setdefault(name, types.ModuleType(name))
        for key, value in attrs.items():
            setattr(built[dotted], key, value)
    return built


class Recorder:
    """A fake connect(): remembers the variable as pyexasol would read it at connect time."""

    def __init__(self):
        self.seen = []

    def __call__(self, *args, **kwargs):
        self.seen.append(os.environ.get(VAR))
        conn = mock.MagicMock()
        conn.execute.return_value.fetchval.return_value = 1
        return conn


class HelperTest(unittest.TestCase):
    def test_python_helper_sets_only_when_absent(self):
        self.assertEqual("EXASOL_TELEMETRY_DISABLE", kit_telemetry.VARIABLE)
        for given, expected in CASES:
            with self.subTest(given=given):
                self.assertEqual(expected, kit_telemetry.default_off(dict(given))[VAR])
                with mock.patch.dict(os.environ, given, clear=True):
                    kit_telemetry.default_off()
                    self.assertEqual(expected, os.environ[VAR])

    def test_dbt_and_mlflow_telemetry_are_off_too_unless_the_user_chose(self):
        """dbt's anonymous usage stats and MLflow's telemetry follow the same rule (audit SEC-04), in the marketplace
        and the shell entry point."""
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual({"DBT_SEND_ANONYMOUS_USAGE_STATS": "false", "MLFLOW_DISABLE_TELEMETRY": "true"},
                             {k: v for k, v in kit_telemetry.default_off().items() if k in kit_telemetry.OTHERS})
        mine = {"DBT_SEND_ANONYMOUS_USAGE_STATS": "true", "MLFLOW_DISABLE_TELEMETRY": "false"}
        self.assertEqual(mine["MLFLOW_DISABLE_TELEMETRY"], kit_telemetry.default_off(dict(mine))["MLFLOW_DISABLE_TELEMETRY"])
        with mock.patch.dict(os.environ, mine, clear=True):
            kit_telemetry.default_off()
            self.assertEqual("true", os.environ["DBT_SEND_ANONYMOUS_USAGE_STATS"], "a value the user set is kept")
        shell = subprocess.run(["bash", "-c", f'. "{ROOT}/setup/lib/common.sh" >/dev/null 2>&1; '
                                'printf "%s %s" "$DBT_SEND_ANONYMOUS_USAGE_STATS" "$MLFLOW_DISABLE_TELEMETRY"'],
                               capture_output=True, text=True,
                               env={"HOME": os.environ.get("HOME", "/tmp"), "PATH": os.environ["PATH"]})
        self.assertEqual("false true", shell.stdout)

class MarketplaceImportTest(unittest.TestCase):
    """Every marketplace command imports runtime first; the variable is in place, and inherited, before it runs."""

    MODULES = ("runtime", "service", "apply", "persona_apply", "installer_flow", "launch")
    PROBE = ("import importlib, os, subprocess, sys\n"
             "importlib.import_module(sys.argv[1])\n"
             "code = 'import os; print(os.environ.get(' + repr(sys.argv[2]) + '))'\n"
             "child = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True).stdout.strip()\n"
             "print(os.environ.get(sys.argv[2]), child)\n")

    def test_each_entry_module_sets_it_for_itself_and_its_children(self):
        for module in self.MODULES:
            for given, expected in CASES[:2]:
                with self.subTest(module=module, given=given):
                    result = subprocess.run([sys.executable, "-c", self.PROBE, module, VAR], cwd=ROOT / "marketplace",
                                            env={**_without_var(), **given}, capture_output=True, text=True,
                                            timeout=60, check=False)
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertEqual(f"{expected} {expected}", result.stdout.strip().splitlines()[-1])


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        credential = self.home / "db-password"
        credential.write_text("not-a-real-password\n", encoding="utf-8")
        doc = {"runtime": {"dsn": "127.0.0.1:8563", "user": "SYS", "password_file": str(credential)},
               "components": {"dash_server": {"port": 5102, "venv": str(self.home / "dash"),
                                              "instance": str(self.home / "instance")},
                              "dbt_exasol": {"venv": str(self.home / "dbt"), "profiles_dir": str(self.home / "p")},
                              "exasol_scheduler": {}}}
        (self.home / "manifest.json").write_text(json.dumps(doc), encoding="utf-8")
        self.credential = credential

    def tearDown(self):
        self.temp.cleanup()

    def _environment(self, given):
        return mock.patch.dict(os.environ, {**_without_var(), "EXAKIT_HOME": str(self.home), **given}, clear=True)

    def test_dash_server_launcher(self):
        for given, expected in CASES:
            with self.subTest(given=given), self._environment(given), \
                    mock.patch.object(sys, "argv", ["dash-server"]), \
                    mock.patch.object(dash_launcher.os, "execve") as execve, \
                    mock.patch.object(dash_launcher.subprocess, "call", return_value=0) as call:
                dash_launcher.main()
                env = (call.call_args.kwargs["env"] if os.name == "nt" else execve.call_args.args[2])
                self.assertEqual(expected, env[VAR])
                self.assertNotIn(VAR, os.environ if not given else {})   # the launcher changes its child's env only

    def test_dbt_launcher(self):
        for given, expected in CASES:
            with self.subTest(given=given), self._environment(given), \
                    mock.patch.object(sys, "argv", ["dbt-exasol", "debug"]), \
                    mock.patch.object(dbt_launcher.subprocess, "call", return_value=0) as call:
                dbt_launcher.main()
                self.assertEqual(expected, call.call_args.kwargs["env"][VAR])

    def test_scheduler_supervisor(self):
        for given, expected in CASES:
            child = mock.MagicMock()
            child.wait.return_value = 0
            argv = ["scheduler", str(self.home / "sched"), str(self.home / "engine"),
                    str(self.home / "manifest.json"), str(self.credential)]
            with self.subTest(given=given), self._environment(given), mock.patch.object(sys, "argv", argv), \
                    mock.patch.object(scheduler_launcher.signal, "signal"), \
                    mock.patch.object(scheduler_launcher.socket, "create_connection"), \
                    mock.patch.object(scheduler_launcher.subprocess, "Popen", return_value=child) as popen:
                self.assertEqual(0, scheduler_launcher.main())
                self.assertEqual(expected, popen.call_args.kwargs["env"][VAR])


class GeneratedLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        store = Manifest(self.home / "manifest.json")
        store.path.write_text("{}")
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", store, Path("uv"))

    def tearDown(self):
        self.temp.cleanup()

    @unittest.skipIf(os.name == "nt", "POSIX launcher")
    def test_json_tables_launcher_runs_the_cli_with_it(self):
        venv, _, launcher = json_tables.paths(self.ctx)
        cli = venv / "bin" / "exasol-json-tables"
        cli.parent.mkdir(parents=True)
        cli.write_text('#!/bin/sh\nprintf "%s" "${EXASOL_TELEMETRY_DISABLE-unset}"\n', encoding="utf-8")
        cli.chmod(0o755)
        json_tables._write_launchers(self.ctx)
        for given, expected in CASES:
            with self.subTest(given=given):
                result = subprocess.run([str(launcher)], env={**_without_var(), **given}, capture_output=True,
                                        text=True, timeout=30, check=False)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(expected, result.stdout)

    def test_json_tables_windows_launcher_text(self):
        with mock.patch.object(json_tables.os, "name", "nt"), mock.patch.object(json_tables, "_shim",
                                                                                return_value=self.home / "shim" / "cargo.cmd"):
            launcher = json_tables.paths(self.ctx)[2]
            launcher.parent.mkdir(parents=True, exist_ok=True)
            json_tables._write_launchers(self.ctx)
            text = launcher.read_text(encoding="utf-8")
        self.assertIn(f'if not defined {VAR} set "{VAR}=1"', text)
        self.assertLess(text.index(VAR), text.index("%*"))


class ShellEntryTest(unittest.TestCase):
    """common.sh and exakit-common.ps1 export it for exakit, the installers, data loading and the upgrade."""

    @unittest.skipUnless(shutil.which("bash") and os.name != "nt", "bash")
    def test_common_sh(self):
        script = f'. "{ROOT}/setup/lib/common.sh"; printf "%s|" "${{{VAR}-unset}}"; ' \
                 f'sh -c \'printf "%s" "${{{VAR}-unset}}"\''
        for given, expected in CASES:
            with self.subTest(given=given), tempfile.TemporaryDirectory() as home:
                result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60, check=False,
                                        env={**_without_var(), "EXAKIT_HOME": home, **given})
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(f"{expected}|{expected}", result.stdout.strip().splitlines()[-1])

    @unittest.skipUnless(shutil.which("pwsh") or shutil.which("powershell"), "PowerShell")
    def test_exakit_common_ps1(self):
        host = shutil.which("pwsh") or shutil.which("powershell")
        script = (f'. "{ROOT / "setup" / "lib" / "exakit-common.ps1"}"; '
                  f'$v = [Environment]::GetEnvironmentVariable("{VAR}", "Process"); '
                  'if ($null -eq $v) { "unset" } else { "[" + $v + "]" }')
        # Windows cannot hold an empty environment variable, so only absent and set are portable cases.
        for given, expected in CASES[:2]:
            with self.subTest(given=given), tempfile.TemporaryDirectory() as home:
                result = subprocess.run([host, "-NoProfile", "-NonInteractive", "-Command", script], capture_output=True,
                                        text=True, timeout=120, check=False,
                                        env={**_without_var(), "EXAKIT_HOME": home, **given})
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(f"[{expected}]", result.stdout.strip().splitlines()[-1])


class SourceGuardTest(unittest.TestCase):
    """X1.2-style grep: no kit-owned code opens pyexasol without the default in place."""

    EXCLUDED = ("tests/", "docs/", ".claude/")
    OPENS = re.compile(r"^\s*(import pyexasol|from pyexasol\b|from exasol\.nb_connector\.connections import"
                       r"|from exasol\.nb_connector\.connections import open_pyexasol_connection)", re.M)
    APPLIES = ("EXASOL_TELEMETRY_DISABLE", "telemetry_off(", "kit_telemetry.default_off(")

    def _sources(self, *patterns):
        for pattern in patterns:
            for path in sorted(ROOT.rglob(pattern)):
                rel = path.relative_to(ROOT).as_posix()
                if not rel.startswith(self.EXCLUDED) and "__pycache__" not in rel:
                    yield rel, path.read_text(encoding="utf-8", errors="replace")

    def test_every_python_file_that_opens_pyexasol_applies_the_default(self):
        found = []
        for rel, text in self._sources("*.py"):
            for match in self.OPENS.finditer(text):
                found.append(rel)
                before = text[:match.start()]
                # The default must come before the import, in the same file.
                applied = any(token in before for token in self.APPLIES)
                self.assertTrue(applied, f"{rel} imports pyexasol without setting {VAR} first")
        self.assertIn("marketplace/addons/semantic_views.py", found)

    def test_shell_snippets_that_import_pyexasol_live_behind_the_shared_default(self):
        for rel, text in self._sources("*.sh", "*.ps1"):
            if re.search(r"^\s*import\b.*\bpyexasol\b", text, re.M):
                self.assertTrue(rel.startswith("setup/lib/"), f"{rel}: pyexasol snippet outside setup/lib")
        common = (ROOT / "setup/lib/common.sh").read_text(encoding="utf-8")
        self.assertRegex(common, r"(?m)^exakit_telemetry_default$")
        self.assertLess(common.index("\nexakit_telemetry_default\n"), common.index("EXAKIT_HOME="))
        ps = (ROOT / "setup/lib/exakit-common.ps1").read_text(encoding="utf-8")
        self.assertRegex(ps, r"(?m)^Set-ExakitTelemetryDefault$")
        for script in ("setup/exakit", "setup/setup-macos.sh", "setup/setup-linux.sh", "setup/load-data.sh",
                       "upgrade/upgrade-kit2.sh", "upgrade/rollback-kit2.sh"):
            self.assertIn("common.sh", (ROOT / script).read_text(encoding="utf-8"), script)
        for script in ("setup/exakit.ps1", "setup/setup-windows.ps1"):
            self.assertIn("exakit-common.ps1", (ROOT / script).read_text(encoding="utf-8"), script)

    def test_marketplace_applies_it_on_import_and_in_every_service_launcher(self):
        runtime = (ROOT / "marketplace/runtime.py").read_text(encoding="utf-8")
        self.assertRegex(runtime, r"(?m)^kit_telemetry\.default_off\(\)$")
        for launcher in sorted((ROOT / "marketplace").glob("*_launcher.py")):
            self.assertIn("kit_telemetry.default_off(env)", launcher.read_text(encoding="utf-8"), launcher.name)


if __name__ == "__main__":
    unittest.main()
