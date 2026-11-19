"""Ownership, receipt and credential invariants for Python add-on lifecycle."""

from __future__ import annotations

import json
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from runtime import AddonFailure, KitContext, Manifest, activity_sink, cmd_quote, venv_executable, venv_python  # noqa: E402
import runtime  # noqa: E402
from addons import dash_server, dbt_exasol, exasol_scheduler, exasol_vscode, json_tables  # noqa: E402
from service import invoke  # noqa: E402


def fake_glibc(version: str | None):
    """os.confstr as a glibc system of `version` answers it; None is musl, where the name is unknown."""
    def confstr(name: str) -> str:
        if name != "CS_GNU_LIBC_VERSION" or version is None:
            raise ValueError("unrecognized configuration name")
        return f"glibc {version}"
    return patch.object(os, "confstr", confstr, create=True)


class GlibcFloorTest(unittest.TestCase):
    """LNX-07: the Linux add-on binaries are linked against glibc 2.38 (x86_64), and the loader refuses them on an
    older one. The floor sits beside each digest in versions.json; the add-ons compare the system's against it."""

    DOC = {"components": {"tool": {"glibc": {"linux-x86_64": "2.38", "linux-aarch64": "2.34", "bad": "2.x"}}}}

    def test_the_system_glibc_is_read_from_the_c_library(self) -> None:
        for answer, expected in (("2.35", (2, 35)), ("2.38", (2, 38)), ("2.39.9000", (2, 39)), (None, None)):
            with self.subTest(answer=answer), fake_glibc(answer):
                self.assertEqual(expected, runtime.host_glibc())
        with patch.object(os, "confstr", lambda _name: "", create=True):
            self.assertIsNone(runtime.host_glibc())

    def test_below_the_floor_says_both_versions(self) -> None:
        for have in ("2.34", "2.35", "2.36", "2.37"):            # RHEL 9, Ubuntu 22.04, Debian 12, Ubuntu 23.04
            with self.subTest(have=have), fake_glibc(have):
                self.assertEqual(f"needs glibc 2.38 or newer (this system has {have})",
                                 runtime.glibc_floor_reason(self.DOC, "tool", "linux-x86_64"))

    def test_at_or_above_the_floor_nothing_is_said(self) -> None:
        for have in ("2.38", "2.39", "2.41", "3.0"):
            with self.subTest(have=have), fake_glibc(have):
                self.assertEqual("", runtime.glibc_floor_reason(self.DOC, "tool", "linux-x86_64"))
        with fake_glibc("2.35"):
            self.assertEqual("", runtime.glibc_floor_reason(self.DOC, "tool", "linux-aarch64"))   # its own floor

    def test_musl_or_an_unreadable_version_is_not_assumed_to_be_new_enough(self) -> None:
        with fake_glibc(None):
            self.assertEqual("needs glibc 2.38 or newer, and this system's C library is not glibc or its version "
                             "cannot be read", runtime.glibc_floor_reason(self.DOC, "tool", "linux-x86_64"))

    def test_no_floor_recorded_checks_nothing(self) -> None:
        with fake_glibc("2.17"):
            for component, key in (("tool", "linux-riscv64"), ("tool", "bad"), ("other", "linux-x86_64")):
                with self.subTest(component=component, key=key):
                    self.assertEqual("", runtime.glibc_floor_reason(self.DOC, component, key))
            self.assertEqual("", runtime.glibc_floor_reason({}, "tool", "linux-x86_64"))

    def test_every_pinned_linux_binary_of_these_add_ons_has_a_floor(self) -> None:
        # Measured from each pinned asset's ELF version references (objdump -p, the highest GLIBC_x.y).
        components = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"]
        for component in ("json-tables", "exasol-scheduler"):
            block = components[component]
            for key in (key for key in block["sha256"] if key.startswith("linux-")):
                with self.subTest(component=component, key=key):
                    self.assertRegex(block.get("glibc", {}).get(key, ""), r"^\d+\.\d+$")


class WindowsWrapperQuotingTest(unittest.TestCase):
    """A generated .cmd file is read by cmd: & ^ | split commands outside quotes and %NAME% expands inside them."""

    def test_every_argument_is_quoted_so_an_ampersand_stays_text(self) -> None:
        self.assertEqual(r'"C:\Users\R&D\python.exe"', cmd_quote(Path("C:/Users/R&D/python.exe")).replace("/", "\\"))
        self.assertEqual('"plain"', cmd_quote("plain"))

    def test_percent_is_doubled_so_cmd_does_not_expand_it(self) -> None:
        self.assertEqual('"C:\\a%%PATH%%b"', cmd_quote("C:\\a%PATH%b"))

    def test_a_quote_inside_an_argument_is_doubled(self) -> None:
        self.assertEqual('"say ""hi"""', cmd_quote('say "hi"'))

    def test_every_cmd_writer_builds_its_line_with_cmd_quote(self) -> None:
        for path in sorted((ROOT / "marketplace").rglob("*.py")):
            lines = path.read_text(encoding="utf-8").splitlines()
            for number, line in enumerate(lines):
                if "@echo off" in line or ".cmd\").write_text" in line:
                    statement = "\n".join(lines[max(0, number - 2):number + 3])
                    with self.subTest(file=path.name, line=number + 1):
                        self.assertIn("cmd_quote", statement)


class ManifestTest(unittest.TestCase):
    def test_recorded_kit_paths_survive_changed_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "kit"
            home.mkdir()
            store = Manifest(home / "manifest.json")
            recorded = Path(temp) / "recorded"
            other = Path(temp) / "other"
            store.path.write_text(json.dumps({"components": {
                "dash_server": {"ownership": "kit", "venv": str(recorded / "dash-venv"),
                                "instance": str(recorded / "dash/instance"), "command": str(recorded / "dash-bin")},
                "dbt_exasol": {"ownership": "kit", "venv": str(recorded / "dbt-venv"),
                               "profiles_dir": str(recorded / "dbt"), "command": str(recorded / "dbt-bin")},
                "json_tables": {"ownership": "kit", "venv": str(recorded / "json-venv"),
                                "engine": str(recorded / "json/libexec/engine"), "command": str(recorded / "json-bin")},
                "exasol_scheduler": {"ownership": "kit", "engine": str(recorded / "sched/libexec/engine"),
                                     "command": str(recorded / "sched-bin")}}}))
            ctx = KitContext(ROOT, home, home / "bin", store, Path("uv"))
            with patch.dict(os.environ, {"EXAKIT_DASH_SERVER_VENV": str(other),
                                      "EXAKIT_DBT_EXASOL_VENV": str(other),
                                      "EXAKIT_JSON_TABLES_VENV": str(other),
                                      "EXAKIT_EXASOL_SCHEDULER_HOME": str(other)}):
                self.assertEqual(recorded / "dash-venv", dash_server.paths(ctx)[0])
                self.assertEqual(recorded / "dbt-venv", dbt_exasol.paths(ctx)[0])
                self.assertEqual(recorded / "json-venv", json_tables.paths(ctx)[0])
                self.assertEqual(recorded / "sched", exasol_scheduler.paths(ctx)[0])

    def test_parallel_receipts_are_not_lost(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "manifest.json"
            path.write_text("{}\n")
            store = Manifest(path)
            with ThreadPoolExecutor(max_workers=8) as pool:
                list(pool.map(lambda index: store.set_many({f"components.item_{index}.version": "1"}), range(24)))
            self.assertEqual(24, len(store.read()["components"]))

    def test_missing_manifest_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(AddonFailure):
                Manifest(Path(temp) / "missing.json").set_many({"x.y": "z"})

    def test_version_source_uses_release_then_marketplace_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "versions.json").write_text(json.dumps({"components": {"dbt-exasol": {"version": "2.0.0"}}}))
            home = root / "home"
            home.mkdir()
            ctx = KitContext(root, home, root / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.dict("os.environ", {"EXAKIT_VERSION_POLICY": "manifest"}, clear=True):
                self.assertEqual("2.0.0", ctx.target_version("dbt-exasol", "1.0.0"))
                self.assertEqual("1.0.0", ctx.target_version("missing-addon", "1.0.0"))
            with patch.dict("os.environ", {"EXAKIT_VERSION_POLICY": "pinned"}, clear=True):
                self.assertEqual("1.0.0", ctx.target_version("dbt-exasol", "1.0.0"))
            with patch.dict("os.environ", {"EXAKIT_DBT_EXASOL_VERSION": "9.0.0"}, clear=True):
                self.assertEqual("9.0.0", ctx.target_version("dbt-exasol", "1.0.0"))

    def test_a_published_manifest_without_a_kit_block_uses_the_kits_own(self) -> None:
        # The default policy reads <repo>/main/versions.json, which can predate a block this kit ships
        # (an add-on newer than the published manifest); without it the add-on refused to install.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "checkout"
            root.mkdir()
            (root / "versions.json").write_text(json.dumps({"components": {
                "semantic-views": {"version": "v0.6.1", "sha256": "0" * 64},
                "exasol-vscode": {"version": "1.0.0"}}}))
            cache = Path(temp) / "published.json"
            cache.write_text(json.dumps({"components": {"exasol-vscode": {"version": "2.0.0"}}}))
            home = Path(temp) / "home"
            home.mkdir()
            ctx = KitContext(root, home, root / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_VERSIONS_DOC": str(cache)}, clear=True):
                components = ctx.versions_document()["components"]
            self.assertEqual("v0.6.1", components["semantic-views"]["version"])
            self.assertEqual("2.0.0", components["exasol-vscode"]["version"], "an advertised block wins")

    def test_selected_manifest_pairs_version_with_asset_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "checkout"
            root.mkdir()
            (root / "versions.json").write_text(json.dumps({"components": {
                "exasol-vscode": {"version": "1.0.0", "sha256": {"vsix": "b" * 64}}}}))
            cache = Path(temp) / "version cache.json"
            cache.write_text(json.dumps({"components": {
                "exasol-vscode": {"version": "2.0.0", "sha256": {"vsix": "a" * 64}},
                "json-tables": {"version": "v2.0.0", "release": "json-tables-v2", "sha256": {"wheel": "c" * 64}}}}))
            home = Path(temp) / "home"
            home.mkdir()
            ctx = KitContext(root, home, root / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.dict(os.environ, {"EXAKIT_VERSION_POLICY": "manifest",
                                      "EXAKIT_MARKETPLACE_VERSIONS_DOC": str(cache)}, clear=True):
                self.assertEqual("2.0.0", ctx.target_version("exasol-vscode", "1.0.0"))
                cache.write_text("{invalid")
                # SEC-13: the digest is never the fetched document's ("a" * 64). The kit copy's pin answers for
                # its own version; any other is checked against the release's own published digest.
                with patch.object(exasol_vscode, "_release_digest", return_value="d" * 64) as published:
                    self.assertEqual("b" * 64, exasol_vscode.expected_digest(ctx, "1.0.0", "editor.vsix"))
                    published.assert_not_called()
                    self.assertEqual("d" * 64, exasol_vscode.expected_digest(ctx, "2.0.0", "editor.vsix"))
                self.assertEqual("json-tables-v2.0.0", json_tables._release_info(ctx, "v2.0.0")[1])
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_VERSIONS_DOC": str(cache)}, clear=True):
                with self.assertRaises(AddonFailure):
                    KitContext(root, home, root / "bin", Manifest(home / "manifest.json"), Path("uv")).versions_document()

    def test_logged_step_updates_activity_above_progress(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            activity = home / "marketplace.activity"
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ACTIVITY_FILE": str(activity),
                                      "EXAKIT_MARKETPLACE_ACTIVITY_ROW": "4"}), \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                ctx.run_logged("Installing verified package", sys.executable, "-c", "pass")
            self.assertEqual("4|Installing verified package\n", activity.read_text())
            self.assertEqual("", output.getvalue(), "a live table owns stdout")

    def test_activity_without_a_table_remains_plain_text(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_ACTIVITY_FILE": str(home / "unused"),
                                      "EXAKIT_MARKETPLACE_ACTIVITY_ROW": ""}), \
                 patch("sys.stdout", new_callable=io.StringIO) as output:
                ctx.activity("Checking package")
            self.assertIn("Checking package", output.getvalue())
            self.assertFalse((home / "unused").exists())

    def test_textual_activity_sink_keeps_stdout_clean(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            labels = []
            with patch("sys.stdout", new_callable=io.StringIO) as output:
                with activity_sink(labels.append):
                    ctx.activity("Downloading release")
            self.assertEqual(["Downloading release"], labels)
            self.assertEqual("", output.getvalue())

    def test_child_diagnostics_cannot_persist_delegated_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            secret = "synthetic-credential-7c90b6a1"
            env = {**os.environ, "DBT_ENV_SECRET_EXASOL_PASSWORD": secret,
                   "GITHUB_TOKEN": "synthetic-token-a8591d3f",
                   "LANGFUSE_SECRET_KEY": "synthetic-langfuse-key-a8bc51"}
            for fail in (False, True):
                script = ("import os,sys; print(os.environ['DBT_ENV_SECRET_EXASOL_PASSWORD']); "
                          "print(os.environ['GITHUB_TOKEN'], file=sys.stderr); "
                          "print(os.environ['LANGFUSE_SECRET_KEY']); "
                          f"sys.exit({1 if fail else 0})")
                with patch("sys.stdout", new_callable=io.StringIO) as output:
                    if fail:
                        with self.assertRaises(AddonFailure) as error:
                            ctx.run_logged("Checking connection", sys.executable, "-c", script, env=env)
                        self.assertNotIn(secret, str(error.exception))
                    else:
                        ctx.run_logged("Checking connection", sys.executable, "-c", script, env=env)
                log = (home / "logs/marketplace.log").read_text()
                self.assertNotIn(secret, log)
                self.assertNotIn(env["GITHUB_TOKEN"], log)
                self.assertNotIn(env["LANGFUSE_SECRET_KEY"], log)
                self.assertIn("[redacted]", log)
                self.assertNotIn(secret, output.getvalue())

    def test_timeout_keeps_redacted_diagnostics_and_private_log(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            secret = "synthetic-timeout-credential-54950d"
            with patch.dict(os.environ, {"EXA_PASSWORD": secret}):
                with self.assertRaisesRegex(AddonFailure, "did not finish"):
                    ctx.run_logged("Checking connection", sys.executable, "-c",
                                   "import os,time; print(os.environ['EXA_PASSWORD'], flush=True); time.sleep(10)",
                                   timeout=2)
            log = home / "logs/marketplace.log"
            self.assertNotIn(secret, log.read_text())
            self.assertIn("[redacted]", log.read_text())
            if os.name != "nt":
                self.assertEqual(0o600, log.stat().st_mode & 0o777)


class PythonUtf8ChildTest(unittest.TestCase):
    """G (Windows 11 upgrade): a Python child writing into a pipe or a file uses the locale's code page (cp1252 on
    Windows) and failed on its first U+2500. Every Python the kit starts is told to write UTF-8, the encoding the kit
    reads it back in: run_logged, the marketplace process itself, and both shell entry points."""

    RULE = "import os; print(os.environ.get('PYTHONUTF8'), os.environ.get('PYTHONIOENCODING'), '\\u2500' * 42)"

    def test_a_logged_child_prints_u2500_under_a_cp1252_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
            windows_pipe = {"PYTHONIOENCODING": "cp1252", "PYTHONUTF8": "0"}
            with patch.dict(os.environ, windows_pipe), patch("sys.stdout", new_callable=io.StringIO):
                ctx.run_logged("Printing a box rule", sys.executable, "-c", self.RULE)
                ctx.run_logged("Printing a box rule", sys.executable, "-c", self.RULE, env=dict(windows_pipe))
            log = (home / "logs" / "marketplace.log").read_text(encoding="utf-8")
            self.assertEqual(2, log.count("1 utf-8 " + "\u2500" * 42), log)

    def test_the_marketplace_process_hands_the_pair_to_every_child(self) -> None:
        self.assertEqual({"PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8"}, runtime.UTF8_CHILD)
        self.assertEqual(("1", "utf-8"), (os.environ.get("PYTHONUTF8"), os.environ.get("PYTHONIOENCODING")))

    def test_both_shell_entry_points_export_the_pair(self) -> None:
        # The whole environment (Windows needs SystemRoot and friends to start pwsh), the pair set the wrong way.
        base = {**os.environ, "HOME": tempfile.mkdtemp(), "PYTHONIOENCODING": "cp1252", "PYTHONUTF8": "0"}
        # On Windows `bash` is WSL's bash.exe, not the kit's shell: the bash half runs where common.sh does.
        if os.name != "nt":
            bash = subprocess.run(["bash", "-c", f'. "{ROOT}/setup/lib/common.sh" >/dev/null 2>&1; '
                                   'printf "%s %s" "$PYTHONUTF8" "$PYTHONIOENCODING"'],
                                  capture_output=True, text=True, env=base, check=False)
            self.assertEqual("1 utf-8", bash.stdout)
        pwsh = shutil.which("pwsh")
        if not pwsh:
            self.skipTest("pwsh is not installed")
        script = (f". '{ROOT / 'setup' / 'lib' / 'exakit-common.ps1'}' *> $null; "
                  "[Console]::Out.Write($env:PYTHONUTF8 + ' ' + $env:PYTHONIOENCODING)")
        ps = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
                            capture_output=True, text=True, env=base, check=False, timeout=120)
        self.assertEqual("1 utf-8", ps.stdout.strip().splitlines()[-1] if ps.stdout.strip() else ps.stderr)


class UvSystemCertsTest(unittest.TestCase):
    """WPS-01: behind a proxy that re-signs TLS (Zscaler, Fortinet; the company root in the system store) every uv
    download failed with "invalid peer certificate", because uv checks its own bundled roots unless told otherwise.
    Every uv the kit starts gets UV_SYSTEM_CERTS=1 - a value the user set, or UV_NATIVE_TLS, is left alone. A fake uv
    records the environment it was started with, on each path: run_logged, the marketplace process and both shell
    twins' Python runners (the UI launcher: test_marketplace_ui)."""

    SWITCHES = ("UV_SYSTEM_CERTS", "UV_NATIVE_TLS")
    SEEN = "import os, sys; print('seen', os.environ.get('UV_SYSTEM_CERTS'), os.environ.get('UV_NATIVE_TLS'))"

    def _without_switches(self) -> dict[str, str]:
        return {k: v for k, v in os.environ.items() if k not in self.SWITCHES}

    def test_run_logged_hands_every_uv_the_switch_and_keeps_the_users_value(self) -> None:
        cases = (({}, "seen 1 None"), ({"UV_SYSTEM_CERTS": "0"}, "seen 0 None"),
                 ({"UV_NATIVE_TLS": "false"}, "seen None false"))
        for preset, expected in cases:
            with self.subTest(preset=preset), tempfile.TemporaryDirectory() as temp:
                home = Path(temp)
                ctx = KitContext(ROOT, home, home / "bin", Manifest(home / "manifest.json"), Path("uv"))
                with patch.dict(os.environ, {}, clear=False), patch("sys.stdout", new_callable=io.StringIO):
                    for name in self.SWITCHES:
                        os.environ.pop(name, None)
                    os.environ.update(preset)
                    ctx.run_logged("Fake uv", sys.executable, "-c", self.SEEN)
                    ctx.run_logged("Fake uv", sys.executable, "-c", self.SEEN, env={**os.environ})
                log = (home / "logs" / "marketplace.log").read_text(encoding="utf-8")
                self.assertEqual(2, log.count(expected), log)

    def test_the_marketplace_process_sets_it_for_every_child(self) -> None:
        for preset, expected in (({}, "1 None"), ({"UV_SYSTEM_CERTS": "0"}, "0 None"),
                                 ({"UV_NATIVE_TLS": "0"}, "None 0")):
            with self.subTest(preset=preset):
                done = subprocess.run([sys.executable, "-c", "import os, runtime; print(os.environ.get('UV_SYSTEM_CERTS'),"
                                       " os.environ.get('UV_NATIVE_TLS'))"], cwd=ROOT / "marketplace",
                                      env={**self._without_switches(), **preset, "PYTHONPATH": str(ROOT / "marketplace")},
                                      capture_output=True, text=True, check=False, timeout=60)
                self.assertEqual(expected, done.stdout.strip(), done.stderr)

    def _fake_uv(self, folder: Path) -> Path:
        """A uv that writes the switches it was started with to uv-env.txt beside itself, whatever its arguments."""
        record = folder / "uv-env.txt"
        if os.name == "nt":
            fake = folder / "uv.cmd"
            fake.write_text(f'@echo off\r\n>>"{record}" echo seen %UV_SYSTEM_CERTS%,%UV_NATIVE_TLS%\r\nexit /b 0\r\n',
                            encoding="ascii")
        else:
            fake = folder / "uv"
            fake.write_text(f'#!/bin/sh\nprintf "seen %s,%s\\n" "$UV_SYSTEM_CERTS" "$UV_NATIVE_TLS" >> "{record}"\n'
                            "exit 0\n", encoding="ascii")
            fake.chmod(0o755)
        return fake

    def _seen(self, folder: Path) -> list[str]:
        record = folder / "uv-env.txt"
        lines = record.read_text(encoding="utf-8", errors="replace").splitlines() if record.exists() else []
        # cmd prints an unset %NAME% as the literal text; the shell prints nothing.
        return [line.strip().replace("%UV_SYSTEM_CERTS%", "").replace("%UV_NATIVE_TLS%", "") for line in lines]

    def test_both_shell_twins_hand_the_switch_to_the_uv_their_python_runners_start(self) -> None:
        cases = (({}, "seen 1,"), ({"UV_SYSTEM_CERTS": "0"}, "seen 0,"), ({"UV_NATIVE_TLS": "0"}, "seen ,0"))
        # On Windows `bash` is WSL's bash.exe, not the kit's shell: the bash half runs where common.sh does.
        if os.name != "nt":
            for preset, expected in cases:
                with self.subTest(shell="bash", preset=preset), tempfile.TemporaryDirectory() as temp:
                    folder = Path(temp)
                    fake = self._fake_uv(folder)
                    env = {**self._without_switches(), **preset, "HOME": temp}
                    # run_python (every kit Python on a machine without python3 >= 3.11) and the bounded runner's argv.
                    script = (f'. "{ROOT}/setup/lib/common.sh" >/dev/null 2>&1; '
                              '_exakit_has_system_python3() { return 1; }; _exakit_python3_present() { return 1; }; '
                              f'exakit_ensure_uv() {{ EXAKIT_UV_BIN="{fake}"; }}; '
                              'run_python -c pass; exakit_python_any_argv && "${_EXAKIT_PY_ANY[@]}" -c pass')
                    subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, check=False,
                                   timeout=120)
                    self.assertEqual([expected, expected], self._seen(folder))
        shells = [shell for shell in (shutil.which("pwsh"), shutil.which("powershell") if os.name == "nt" else None)
                  if shell]
        if not shells:
            self.skipTest("pwsh is not installed")
        for shell in shells:
            for preset, expected in cases:
                with self.subTest(shell=shell, preset=preset), tempfile.TemporaryDirectory() as temp:
                    folder = Path(temp)
                    fake = self._fake_uv(folder)
                    env = {**self._without_switches(), **preset, "EXAKIT_HOME": str(folder / "home"),
                           "EXAKIT_DISABLE_SYSTEM_PYTHON": "1"}
                    if os.name != "nt":
                        env["HOME"] = temp
                    pyfile = folder / "p.py"
                    pyfile.write_text("pass\n", encoding="ascii")
                    # Invoke-ExakitPythonFile (the preprocessor step, the marketplace CLI) and Invoke-ExakitPython.
                    script = (f". '{ROOT / 'setup' / 'lib' / 'exakit-common.ps1'}' *> $null; "
                              f"function Install-ExakitUv {{ return '{fake}' }}; "
                              f"$null = Invoke-ExakitPythonFile -Path '{pyfile}'; $null = Invoke-ExakitPython -Script 'pass'")
                    done = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-Command", script], env=env,
                                          capture_output=True, text=True, check=False, timeout=180)
                    self.assertEqual([expected, expected], self._seen(folder), done.stdout + done.stderr)


class KeychainTrustTest(unittest.TestCase):
    """WPS-01, the urllib half: a Python uv installed reads only /etc/ssl/cert.pem on macOS, so behind a proxy whose
    root sits in the keychain every add-on download failed while curl worked. A refused certificate is asked again
    with the keychain's trusted roots added - on macOS only, and only for a certificate error."""

    def _handler(self, first_error: Exception) -> tuple[runtime.SystemTrustHTTPSHandler, list]:
        import urllib.error

        calls: list = []
        handler = runtime.SystemTrustHTTPSHandler()

        def do_open(http_class, req, **kwargs):
            calls.append(kwargs.get("context"))
            if len(calls) == 1:
                raise urllib.error.URLError(first_error)
            return "answer"
        handler.do_open = do_open
        return handler, calls

    def test_a_refused_certificate_is_retried_with_the_keychain_on_macos(self) -> None:
        import ssl
        import urllib.request

        handler, calls = self._handler(ssl.SSLCertVerificationError("unable to get local issuer certificate"))
        keychain = object()
        with patch("runtime.sys.platform", "darwin"), patch("runtime.keychain_tls_context", return_value=keychain):
            self.assertEqual("answer", handler.https_open(urllib.request.Request("https://example.invalid/")))
        self.assertIs(keychain, calls[-1])

    def test_nothing_is_retried_off_macos_or_for_another_error(self) -> None:
        import ssl
        import urllib.error
        import urllib.request

        for platform, error in (("linux", ssl.SSLCertVerificationError("x")), ("win32", ssl.SSLCertVerificationError("x")),
                                ("darwin", ConnectionRefusedError("no"))):
            with self.subTest(platform=platform, error=type(error).__name__):
                handler, calls = self._handler(error)
                with patch("runtime.sys.platform", platform), self.assertRaises(urllib.error.URLError):
                    handler.https_open(urllib.request.Request("https://example.invalid/"))
                self.assertEqual(1, len(calls))

    def test_every_urlopen_and_open_url_go_through_it(self) -> None:
        import urllib.request

        self.assertTrue(any(isinstance(h, runtime.SystemTrustHTTPSHandler) for h in urllib.request._opener.handlers))
        captured = {}
        real = urllib.request.build_opener

        def build(*handlers):
            captured["handlers"] = handlers
            return real(*handlers)
        with patch("runtime.urllib.request.build_opener", side_effect=build), \
             patch.object(urllib.request.OpenerDirector, "open", return_value="answer"):
            self.assertEqual("answer", runtime.open_url(urllib.request.Request("https://example.invalid/"), 1))
        self.assertIn(runtime.SystemTrustHTTPSHandler, captured["handlers"])

    def test_only_roots_the_keychain_trusts_are_taken(self) -> None:
        pem = "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----"
        listed = "\n".join(pem.format(name) for name in ("TRUSTED", "IDENTITY"))

        def run(argv, **kwargs):
            if "find-certificate" in argv:
                return subprocess.CompletedProcess(argv, 0, listed, "")
            return subprocess.CompletedProcess(argv, 0 if "TRUSTED" in kwargs["input"] else 1, "", "")
        with patch("runtime.subprocess.run", side_effect=run):
            self.assertEqual(pem.format("TRUSTED"), runtime._keychain_roots())


class DbtLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit"
        self.home.mkdir()
        self.bin_dir = Path(self.temp.name) / "bin"
        self.bin_dir.mkdir()
        self.credential = Path(self.temp.name) / "secret.txt"
        self.credential.write_text("sensitive-test-password\n")
        self.store = Manifest(self.home / "manifest.json")
        self.store.path.write_text(json.dumps({"runtime": {"dsn": "localhost:8563", "user": "SYS",
                                                         "password_file": str(self.credential)}}))
        self.ctx = KitContext(ROOT, self.home, self.bin_dir, self.store, Path(shutil.which("uv") or "/usr/bin/uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_install_writes_no_secret_and_reuses_existing_package(self) -> None:
        venv, profile_dir, launcher = dbt_exasol.paths(self.ctx)
        python = venv_python(venv)
        dbt = venv_executable(venv, "dbt")
        python.parent.mkdir(parents=True)
        python.write_text("fake")
        dbt.write_text("fake")
        # The version the kit pins today (versions.json), so a bump never fails this test.
        pinned = self.ctx.target_version("dbt-exasol", "1.12.3")
        with patch.object(dbt_exasol, "package_version", return_value=pinned), \
             patch.object(dbt_exasol, "validate", return_value=True), \
             patch.object(KitContext, "run_logged") as run_logged:
            dbt_exasol.install(self.ctx)
        run_logged.assert_not_called()
        self.assertTrue(launcher.is_file())
        self.assertNotIn("sensitive-test-password", (profile_dir / "profiles.yml").read_text())
        self.assertNotIn("sensitive-test-password", launcher.read_text())
        self.assertEqual("kit", self.store.get("components.dbt_exasol.ownership"))

    def test_uninstall_preserves_user_files_and_refuses_unowned(self) -> None:
        with self.assertRaises(AddonFailure):
            dbt_exasol.uninstall(self.ctx)
        venv, profile_dir, launcher = dbt_exasol.paths(self.ctx)
        venv.mkdir()
        profile_dir.mkdir()
        (profile_dir / "profiles.yml").write_text("generated")
        (profile_dir / "my-project.yml").write_text("personal")
        launcher.write_text("generated")
        self.store.set_many({"components.dbt_exasol.ownership": "kit"})
        self.assertEqual(3, len(dbt_exasol.uninstall(self.ctx, dry_run=True)))
        self.assertTrue(launcher.exists())
        dbt_exasol.uninstall(self.ctx)
        self.assertFalse(venv.exists())
        self.assertFalse(launcher.exists())
        self.assertTrue((profile_dir / "my-project.yml").exists())
        self.assertIsNone(self.store.get("components.dbt_exasol"))


class VscodeOwnershipTest(unittest.TestCase):
    def test_external_extension_is_reused_without_claim_or_download(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "kit"
            home.mkdir()
            store = Manifest(home / "manifest.json")
            store.path.write_text("{}\n")
            ctx = KitContext(ROOT, home, Path(temp) / "bin", store, Path("/usr/bin/uv"))
            with patch.object(exasol_vscode, "code_cli", return_value=Path("/fake/code")), \
                 patch.object(exasol_vscode, "live_version", return_value="1.8.0"), \
                 patch.object(exasol_vscode.urllib.request, "urlopen") as urlopen:
                exasol_vscode.install(ctx)
            urlopen.assert_not_called()
            self.assertIsNone(store.get("components.exasol_vscode"))
            with self.assertRaises(AddonFailure):
                exasol_vscode.uninstall(ctx)


class DashOwnershipTest(unittest.TestCase):
    def test_uninstall_keeps_dashboard_instance(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp) / "kit"
            home.mkdir()
            store = Manifest(home / "manifest.json")
            store.path.write_text(json.dumps({"components": {"dash_server": {"ownership": "kit", "version": "0.1.1"}}}))
            ctx = KitContext(ROOT, home, Path(temp) / "bin", store, Path("uv"))
            venv, state, launcher = dash_server.paths(ctx)
            venv.mkdir()
            state.joinpath("instance").mkdir(parents=True)
            state.joinpath("instance", "my-dashboard.py").write_text("keep me")
            launcher.parent.mkdir()
            launcher.write_text("generated")
            with patch.object(dash_server, "stop"):
                with patch.object(dash_server, "status", return_value="stopped"):
                    targets = dash_server.uninstall(ctx, dry_run=True)
                self.assertEqual(2, len(targets))
                # A running server is stopped by the removal: the preview names it.
                with patch.object(dash_server, "status", return_value="running"):
                    self.assertEqual("the running Dash Server (it is stopped first)",
                                     dash_server.uninstall(ctx, dry_run=True)[0])
                self.assertTrue(venv.exists())
                dash_server.uninstall(ctx)
            self.assertFalse(venv.exists())
            self.assertFalse(launcher.exists())
            self.assertTrue(state.joinpath("instance", "my-dashboard.py").exists())
            self.assertIsNone(store.get("components.dash_server"))


class JsonTablesArtifactTest(unittest.TestCase):
    def test_bad_digest_deletes_download_and_refuses_install(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            store = Manifest(home / "manifest.json")
            store.path.write_text("{}\n")
            ctx = KitContext(ROOT, home, home / "bin", store, Path("uv"))
            destination = home / "engine"
            response = io.BytesIO(b"wrong asset")
            response.url = "https://github.com/release/engine"
            with patch.object(json_tables, "open_url", return_value=response):
                with self.assertRaisesRegex(AddonFailure, "Checksum mismatch"):
                    json_tables._asset(ctx, "owner/repo", "tag", "engine", "linux-x86_64",
                                       {"sha256": {"linux-x86_64": "0" * 64}}, None, destination)
            self.assertFalse(destination.exists())

    def test_external_install_is_never_claimed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            store = Manifest(home / "manifest.json")
            store.path.write_text(json.dumps({"components": {"json_tables": {"ownership": "user", "version": "v0.3.2"}}}))
            ctx = KitContext(ROOT, home, home / "bin", store, Path("uv"))
            with patch.object(json_tables, "_asset") as asset:
                json_tables.install(ctx)
            asset.assert_not_called()
            self.assertEqual("user", store.get("components.json_tables.ownership"))


class ServiceDispatchTest(unittest.TestCase):
    def test_missing_install_refuses_before_any_addon_side_effect(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            with patch.dict("os.environ", {"EXAKIT_HOME": temp}), \
                 patch.object(dbt_exasol, "install") as install:
                with self.assertRaisesRegex(AddonFailure, "No starter kit installation"):
                    invoke(ROOT, "dbt-exasol", "install")
            install.assert_not_called()

    def test_disabled_addon_cannot_be_newly_installed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "marketplace").mkdir()
            (root / "marketplace/addons").mkdir()
            for module in (ROOT / "marketplace/addons").glob("*.py"):
                (root / "marketplace/addons" / module.name).touch()
            catalog = json.loads((ROOT / "marketplace/catalog.json").read_text())
            for row in catalog["addons"]:
                if row["id"] == "dbt-exasol":
                    row["visible"] = False
            (root / "marketplace/catalog.json").write_text(json.dumps(catalog))
            (root / "versions.json").write_text((ROOT / "versions.json").read_text())
            with self.assertRaisesRegex(AddonFailure, "disabled"):
                invoke(root, "dbt-exasol", "install")

    def test_unknown_addon_is_rejected_before_mutation(self) -> None:
        from model import CatalogError

        with self.assertRaises(CatalogError):
            invoke(ROOT, "not-listed", "install")


if __name__ == "__main__":
    unittest.main()
