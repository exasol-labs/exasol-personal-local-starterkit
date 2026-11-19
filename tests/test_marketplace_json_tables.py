"""JSON Tables release selection and launcher behavior."""

from __future__ import annotations

import contextlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import json_tables  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402
from service import invoke  # noqa: E402


class JsonTablesTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit home"
        self.home.mkdir()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text("{}", encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_release_pin_and_override_do_not_mix_builds(self) -> None:
        pin = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"]["json-tables"]
        self.manifest.set_many({"kit.source": "owner/fork@main"})
        repo, tag, assets = json_tables._release_info(self.ctx, pin["version"])
        self.assertEqual(("owner/fork", pin["release"], pin), (repo, tag, assets))
        repo, tag, assets = json_tables._release_info(self.ctx, "v9.9")
        self.assertEqual(("owner/fork", "json-tables-v9.9", {}), (repo, tag, assets))
        with patch.dict(os.environ, {"EXAKIT_JSON_TABLES_MIRROR_TAG": "rebuilt-v9"}):
            self.assertEqual(("owner/fork", "rebuilt-v9", {}),
                             json_tables._release_info(self.ctx, pin["version"]))
        self.manifest.set_many({"kit.source": "checkout:/tmp/local kit"})
        with patch.dict(os.environ, {"EXAKIT_JSON_TABLES_MIRROR_REPO": "", "EXAKIT_KIT_REPO": "main/kit"}):
            self.assertEqual("main/kit", json_tables._release_info(self.ctx, pin["version"])[0])

    def test_offline_version_uses_catalog_fallback(self) -> None:
        catalog = json.loads((ROOT / "marketplace/catalog.json").read_text(encoding="utf-8"))
        expected = next(row["default_version"] for row in catalog["addons"] if row["id"] == "json-tables")
        with patch.object(KitContext, "versions_document", return_value={}):
            self.assertEqual(expected, json_tables.latest(self.ctx))

    def test_published_engine_platforms(self) -> None:
        cases = (("Darwin", "arm64", ("macos", "aarch64")),
                 ("Linux", "x86_64", ("linux", "x86_64")),
                 ("Linux", "aarch64", ("linux", "aarch64")),
                 ("Windows", "AMD64", ("windows", "x86_64")))
        for system, machine, expected in cases:
            with self.subTest(system=system, machine=machine), \
                 patch.object(json_tables.platform, "system", return_value=system), \
                 patch.object(json_tables.platform, "machine", return_value=machine):
                self.assertEqual(expected, json_tables._platform())
        for system, machine in (("Darwin", "x86_64"), ("Windows", "ARM64")):
            with self.subTest(system=system, machine=machine), \
                 patch.object(json_tables.platform, "system", return_value=system), \
                 patch.object(json_tables.platform, "machine", return_value=machine):
                with self.assertRaises(AddonFailure):
                    json_tables._platform()

    def on(self, system: str, machine: str, glibc: str | None) -> contextlib.ExitStack:
        """This machine as `system`/`machine` with glibc `glibc` (None: musl, the name is unknown to confstr)."""
        def confstr(name: str) -> str:
            if name != "CS_GNU_LIBC_VERSION" or glibc is None:
                raise ValueError("unrecognized configuration name")
            return f"glibc {glibc}"
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(json_tables.platform, "system", return_value=system))
        stack.enter_context(patch.object(json_tables, "host_machine", return_value=machine))
        stack.enter_context(patch.object(os, "confstr", confstr, create=True))
        return stack

    def test_linux_below_the_engines_glibc_is_not_on_offer_and_says_why(self) -> None:
        # LNX-07: the x86_64 engine needs GLIBC_2.38; Ubuntu 22.04 (WSL's usual distro), Debian 12 and RHEL 9 have
        # less. Not applicable is what keeps it out of the background auto-install and the add-ons table, and what
        # sends `exakit load data.json` to the kit's own "not available on this machine" advice.
        for have in ("2.35", "2.36", "2.34"):
            with self.subTest(have=have), self.on("Linux", "x86_64", have):
                self.assertFalse(json_tables.applicable(self.ctx))
                self.assertEqual(f"The prebuilt JSON Tables engine needs glibc 2.38 or newer (this system has {have})",
                                 json_tables.applicable_reason(self.ctx))
                self.assertEqual(1, invoke(ROOT, "json-tables", "applicable", ctx=self.ctx)[0])   # the shell gate's rc
        with self.on("Linux", "x86_64", None):
            self.assertFalse(json_tables.applicable(self.ctx))
            self.assertIn("not glibc", json_tables.applicable_reason(self.ctx))

    def test_linux_at_or_above_the_engines_glibc_is_on_offer(self) -> None:
        for machine, have in (("x86_64", "2.38"), ("x86_64", "2.39"), ("aarch64", "2.35"), ("aarch64", "2.34")):
            with self.subTest(machine=machine, have=have), self.on("Linux", machine, have):
                self.assertTrue(json_tables.applicable(self.ctx))
                self.assertEqual("", json_tables.applicable_reason(self.ctx))
                self.assertEqual(0, invoke(ROOT, "json-tables", "applicable", ctx=self.ctx)[0])
        with self.on("Linux", "aarch64", "2.33"):                 # the arm64 engine is built on Ubuntu 22.04: 2.34
            self.assertIn("needs glibc 2.34 or newer (this system has 2.33)", json_tables.applicable_reason(self.ctx))

    def test_glibc_is_only_asked_on_linux(self) -> None:
        for system, machine in (("Darwin", "arm64"), ("Windows", "AMD64")):
            with self.subTest(system=system), self.on(system, machine, None):
                self.assertTrue(json_tables.applicable(self.ctx))

    def test_install_below_the_floor_refuses_before_any_download(self) -> None:
        with self.on("Linux", "x86_64", "2.35"), \
             patch.object(json_tables, "system_present", return_value=False), \
             patch.object(KitContext, "require_uv", return_value=Path("uv")), \
             patch.object(json_tables, "_asset", side_effect=AssertionError("downloaded")), \
             patch.object(json_tables, "_api_assets", side_effect=AssertionError("looked up")):
            with self.assertRaisesRegex(AddonFailure, r"needs glibc 2\.38 or newer \(this system has 2\.35\)"):
                json_tables.install(self.ctx)
        self.assertIsNone(self.manifest.get("components.json_tables.ownership"))

    @unittest.skipIf(os.name == "nt", "Unix shim only")
    def test_cargo_shim_forwards_ingest_and_delegates_other_commands(self) -> None:
        engine = json_tables._engine(self.ctx)
        engine.parent.mkdir(parents=True)
        engine.write_text('#!/bin/sh\nprintf "<%s>" "$@"\n', encoding="utf-8")
        engine.chmod(0o755)
        real_cargo = self.home / "real cargo"
        real_cargo.mkdir()
        (real_cargo / "cargo").write_text('#!/bin/sh\nprintf "REAL <%s>" "$@"\n', encoding="utf-8")
        (real_cargo / "cargo").chmod(0o755)
        json_tables._write_launchers(self.ctx)
        shim = json_tables._shim(self.ctx)
        ingest = subprocess.run([str(shim), "run", "--manifest-path", "/src/json_tables_ingest/Cargo.toml",
                                 "--", "--input", "a file.json", "--output-dir", "out"],
                                text=True, capture_output=True, check=True)
        self.assertEqual("<--input><a file.json><--output-dir><out>", ingest.stdout)
        env = {**os.environ, "PATH": f"{shim.parent}:{real_cargo}"}
        other = subprocess.run([str(shim), "build", "--release"], env=env,
                               text=True, capture_output=True, check=True)
        self.assertEqual("REAL <build>REAL <--release>", other.stdout)
        launcher = json_tables.paths(self.ctx)[2]
        self.assertIn(str(shim.parent), launcher.read_text(encoding="utf-8"))



class AssetSourceTest(unittest.TestCase):
    """The engine comes from the kit's repository, through the API with a token when that repository is private, and
    else from the public kit repository's copy of the same release - only with a pinned checksum."""

    PRIVATE = "ranjanm-chn/exasol-personal-local-starterkit-backup"

    def _fetch(self, token: str | None, digest: str | None, public_down: bool = False):
        import hashlib
        import io
        from urllib.error import HTTPError
        body = b"wheel bytes"
        pins = {"sha256": {"wheel": digest or ""}} if digest is not None else {"sha256": {}}
        if digest == "real":
            pins = {"sha256": {"wheel": hashlib.sha256(body).hexdigest()}}
        seen = []

        class Response(io.BytesIO):
            url = "https://objects.githubusercontent.com/x"
            def __enter__(self): return self
            def __exit__(self, *a): return False

        def fake_open(request, timeout):
            seen.append((request.full_url, request.get_header("Authorization")))
            if request.full_url.startswith(f"https://github.com/{self.PRIVATE}/") or (
                    public_down and request.full_url.startswith("https://github.com/exasol-labs/")):
                raise HTTPError(request.full_url, 404, "Not Found", None, None)
            if request.full_url.endswith("/releases/tags/json-tables-v0.4.1"):
                return Response(json.dumps({"assets": [{"name": "w.whl", "url":
                    f"https://api.github.com/repos/{self.PRIVATE}/releases/assets/7"}]}).encode())
            return Response(body)

        class Ctx:
            def log_event(self, *_a, **_k): pass

        env = {k: v for k, v in os.environ.items() if k not in ("GITHUB_TOKEN", "GH_TOKEN")}
        if token:
            env["GITHUB_TOKEN"] = token
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, env, clear=True), \
                patch.object(json_tables, "open_url", side_effect=fake_open):
            dest = Path(tmp) / "w.whl"
            error = None
            try:
                json_tables._asset(Ctx(), self.PRIVATE, "json-tables-v0.4.1", "w.whl", "wheel", pins, None, dest)
            except json_tables.AddonFailure as failure:
                error = str(failure)
            return seen, error

    def test_with_a_pin_the_public_copy_comes_first_even_with_a_token(self):
        seen, error = self._fetch("t0k", "real")
        self.assertIsNone(error)
        self.assertEqual(1, len(seen), "one plain download, no API lookup")
        self.assertTrue(seen[0][0].startswith("https://github.com/exasol-labs/"), seen[0][0])
        self.assertIsNone(seen[0][1], "the plain link never carries the token")

    def test_a_private_repository_is_read_through_the_api_with_the_token(self):
        seen, error = self._fetch("t0k", "real", public_down=True)
        self.assertIsNone(error)
        self.assertEqual(f"https://api.github.com/repos/{self.PRIVATE}/releases/assets/7", seen[-1][0])
        self.assertEqual("Bearer t0k", seen[-1][1])
        self.assertIsNone(seen[0][1], "the plain link never carries the token")

    def test_without_a_token_the_public_copy_is_used_when_the_checksum_is_pinned(self):
        seen, error = self._fetch(None, "real")
        self.assertIsNone(error)
        self.assertEqual("https://github.com/exasol-labs/exasol-personal-local-starterkit/releases/download/"
                         "json-tables-v0.4.1/w.whl", seen[-1][0])

    def test_without_a_pin_no_other_copy_is_trusted(self):
        with patch.dict(os.environ, {"EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES": "1"}):
            seen, error = self._fetch(None, None)
        self.assertEqual(1, len(seen), "only the kit's own repository is tried")
        self.assertIn("needs GITHUB_TOKEN", error)


class DownloadProgressTest(unittest.TestCase):
    """A slow download reads as progress on the bar that is running, in either shell's format."""

    class Slow:
        def __init__(self, size, length=True):
            self.left, self.headers = size, ({"Content-Length": str(size)} if length else {})

        def read(self, n):
            if self.left <= 0:
                return b""
            block = min(n, self.left)
            self.left -= block
            return b"x" * block

    def run_copy(self, first_line, length=True):
        import io
        with tempfile.TemporaryDirectory() as tmp:
            phase = Path(tmp) / "phase"
            phase.write_text(first_line, encoding="utf-8")
            out = io.BytesIO()
            with patch.dict(os.environ, {"EXAKIT_PROGRESS_PHASE_FILE": str(phase)}), \
                    patch.object(json_tables.time, "monotonic", side_effect=[float(i) for i in range(10_000)]):
                json_tables._copy_with_progress(self.Slow(15_000_000, length), out, "the JSON engine")
            self.assertEqual(15_000_000, len(out.getvalue()))
            return phase.read_text(encoding="utf-8").strip()

    def test_bash_state_keeps_its_fields_and_gets_the_megabytes(self):
        self.assertEqual("1|2|3|4|downloading the JSON engine, 15 of 15 MB", self.run_copy("1|2|3|4|installing\n"))

    def test_the_powershell_bar_gets_a_plain_line(self):
        self.assertEqual("downloading the JSON engine, 15 of 15 MB", self.run_copy(""))

    def test_an_unknown_size_counts_what_arrived(self):
        self.assertRegex(self.run_copy("", length=False), r"^downloading the JSON engine, \d+ MB$")

    def test_no_bar_no_file_written(self):
        import io
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("EXAKIT_PROGRESS_PHASE_FILE", None)
            json_tables._copy_with_progress(self.Slow(1000), io.BytesIO(), "the JSON engine")


class ModuleTest(unittest.TestCase):
    """JSON queries work in every session: the add-on builds JSON Tables' module for the wrappers in the database
    and registers it with the kit's SQL preprocessor framework - after install and update, after a wrap the
    launcher ran, and never as a failure of the add-on; uninstall retires it first."""

    GENERATE = ROOT / "setup" / "preprocessor" / "modules" / "json-tables" / "generate.py"
    STUB = ROOT / "tests" / "lib" / "stub-json-tables"
    FIXTURE = ROOT / "tests" / "lib" / "json-tables-jvs-fixture.json"

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit home"
        self.home.mkdir()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text("{}", encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def active(self) -> None:
        self.manifest.set_many({"components.preprocessor": {"state": "active", "version": "0.9.1"}})

    # --- the add-on's hooks -------------------------------------------------------------------------------------

    def test_without_an_active_framework_nothing_is_built(self) -> None:
        for record in ({}, {"state": "active", "declined": True}, {"state": "absent"}):
            with self.subTest(record=record), \
                 patch.object(json_tables.subprocess, "run", side_effect=AssertionError("built")), \
                 patch.object(json_tables.preprocessor_modules, "register", side_effect=AssertionError("registered")):
                self.manifest.set_many({"components.preprocessor": record})
                self.assertEqual("skipped", json_tables.register_module(self.ctx))

    def test_the_summary_promises_json_queries_only_while_the_framework_runs_the_module(self) -> None:
        self.active()
        self.manifest.set_many({"components.preprocessor.modules.json-tables.version": 1})
        self.assertEqual("ingest JSON: exasol-json-tables; JSON queries on its wrappers work in every session, no setup",
                         json_tables.summary(self.ctx))
        # The user's own preprocessor took the slot (declined): the modules record stays, but nothing runs it.
        self.manifest.set_many({"components.preprocessor.declined": True,
                                "components.preprocessor.slot_holder": "MY.OWN"})
        self.assertEqual("ingest JSON: exasol-json-tables", json_tables.summary(self.ctx))

    def test_a_build_that_fails_is_logged_and_never_raised(self) -> None:
        self.active()
        failed = subprocess.CompletedProcess([], 1, "", "the JSON Tables module was not built: exapump down\n")
        with patch.object(json_tables.subprocess, "run", return_value=failed), \
             patch.object(json_tables.preprocessor_modules, "register", side_effect=AssertionError("registered")), \
             patch.object(KitContext, "log_event") as log:
            self.assertEqual("failed", json_tables.register_module(self.ctx))
        self.assertIn("exapump down", log.call_args.args[0])

    def test_a_built_artifact_is_registered_with_its_note(self) -> None:
        self.active()
        seen = {}

        def build(argv, **_kwargs):
            seen["argv"] = argv
            Path(argv[-1]).write_text("--/\nCREATE ...\n/\n", encoding="utf-8")
            return subprocess.CompletedProcess(argv, 0, "exasol-json-tables v0.4.1 + 2 wrappers\n", "")

        def register(ctx, addon, *, artifact=None, note=None):
            seen.update(addon=addon, artifact_exists=artifact.is_file(), note=note)
            return "ok", "JSON Tables registered"

        with patch.object(json_tables.subprocess, "run", side_effect=build), \
             patch.object(json_tables.preprocessor_modules, "register", side_effect=register):
            self.assertEqual("ok", json_tables.register_module(self.ctx))
        self.assertEqual(str(json_tables.venv_python(json_tables.paths(self.ctx)[0])), seen["argv"][0])
        self.assertEqual(str(self.GENERATE), seen["argv"][1])
        self.assertEqual(("json-tables", True, "exasol-json-tables v0.4.1 + 2 wrappers"),
                         (seen["addon"], seen["artifact_exists"], seen["note"]))

    def test_an_installed_version_registers_on_install_and_update(self) -> None:
        self.manifest.set_many({"components.json_tables": {"ownership": "kit", "version": "v0.4.1"}})
        with patch.object(json_tables, "system_present", return_value=False), \
             patch.object(KitContext, "require_uv", return_value=Path("uv")), \
             patch.object(json_tables, "applicable", return_value=True), \
             patch.object(json_tables, "_assets_complete", return_value=True), \
             patch.object(json_tables, "_asset", side_effect=AssertionError("downloaded")), \
             patch.object(KitContext, "run_logged", side_effect=AssertionError("ran a command")), \
             patch.object(KitContext, "target_version", return_value="v0.4.1"), \
             patch.object(json_tables, "_write_launchers"), \
             patch.object(json_tables, "register_module", return_value="ok") as register:
            json_tables.install(self.ctx)
        register.assert_called_once_with(self.ctx)

    def test_uninstall_retires_the_module_before_anything_is_removed(self) -> None:
        venv = json_tables.paths(self.ctx)[0]
        venv.mkdir(parents=True)
        self.manifest.set_many({"components.json_tables": {"ownership": "kit", "version": "v0.4.1"}})
        seen = []
        with patch.object(json_tables.preprocessor_modules, "retire",
                          side_effect=lambda ctx, addon: seen.append((addon, venv.exists())) or ("ok", "")):
            self.assertEqual([venv], json_tables.uninstall(self.ctx, dry_run=True))
            self.manifest.set_many({"components.preprocessor.modules.json-tables.version": 1})
            # A registered module is retired by the removal: the preview names it.
            self.assertEqual(["JSON queries stop working in every session (the SQL preprocessor's JSON Tables module "
                              "is switched off); your wrapper schemas and their data stay", venv],
                             json_tables.uninstall(self.ctx, dry_run=True))
            self.assertEqual([], seen)                                 # a dry run touches nothing
            json_tables.uninstall(self.ctx)
        self.assertEqual([("json-tables", True)], seen)
        self.assertFalse(venv.exists())

    def test_a_retire_that_fails_stops_the_removal_and_says_how_to_retry(self) -> None:
        # PPX-06: the rule stays live when the retire fails, so the add-on is not reported removed.
        venv = json_tables.paths(self.ctx)[0]
        venv.mkdir(parents=True)
        self.manifest.set_many({"components.json_tables": {"ownership": "kit", "version": "v0.4.1"},
                                "components.preprocessor.modules.json-tables.version": 1})
        failed = ("failed", "JSON Tables could not be retired from the SQL preprocessor framework: boom")
        with patch.object(json_tables.preprocessor_modules, "retire", return_value=failed):
            with self.assertRaisesRegex(AddonFailure, "could not be retired .*: boom; nothing was removed. "
                                                      "Retry with: exakit uninstall json-tables"):
                json_tables.uninstall(self.ctx)
        self.assertTrue(venv.exists())
        self.assertEqual("kit", self.manifest.get("components.json_tables.ownership"))
        # A module the kit never registered has no rule to leave behind: the removal goes on as before.
        self.manifest.delete("components.preprocessor")
        with patch.object(json_tables.preprocessor_modules, "retire", return_value=failed):
            json_tables.uninstall(self.ctx)
        self.assertFalse(venv.exists())

    # --- the launchers --------------------------------------------------------------------------------------------

    @unittest.skipIf(os.name == "nt", "Unix launcher")
    def test_the_launcher_registers_after_a_wrap_that_installs_and_keeps_the_clis_answer(self) -> None:
        venv = json_tables.paths(self.ctx)[0]
        (venv / "bin").mkdir(parents=True)
        log = self.home / "python.log"
        (venv / "bin" / "exasol-json-tables").write_text(
            '#!/bin/sh\nprintf "CLI %s|" "$@"\nexit "${FAKE_CLI_RC:-0}"\n', encoding="utf-8")
        (venv / "bin" / "python").write_text(
            f'#!/bin/sh\nprintf "%s|" "$@" >> "{log}"\nprintf "\\n" >> "{log}"\necho REGISTERED\n', encoding="utf-8")
        for name in ("exasol-json-tables", "python"):
            (venv / "bin" / name).chmod(0o755)
        json_tables._write_launchers(self.ctx)
        launcher = json_tables.paths(self.ctx)[2]

        def run(*args: str, rc: int = 0) -> tuple[int, str, str, str]:
            log.write_text("", encoding="utf-8")
            done = subprocess.run([str(launcher), *args], text=True, capture_output=True,
                                  env={**os.environ, "FAKE_CLI_RC": str(rc)})
            return done.returncode, done.stdout, done.stderr, log.read_text(encoding="utf-8")

        rc, out, err, called = run("ingest-and-wrap", "--input", "a b.json", "--json")
        self.assertEqual((0, "CLI ingest-and-wrap|CLI --input|CLI a b.json|CLI --json|"), (rc, out))
        self.assertEqual(f"{self.GENERATE}|--register|--home|{self.home}|\n", called)
        self.assertIn("REGISTERED", err)                               # the kit's line never reaches stdout
        for args in (("wrap", "install", "--package-config", "p.json"), ("wrap", "deploy")):
            with self.subTest(args=args):
                self.assertIn("--register", run(*args)[3])
        for args in (("wrap", "generate", "--input", "x"), ("wrap", "validate"), ("describe", "wrappers"),
                     ("ingest", "--input", "x"), ("wrap", "install", "--help"), ("ingest-and-wrap", "-h"),
                     ("wrap", "--help")):
            with self.subTest(args=args):
                self.assertEqual("", run(*args)[3])
        rc, out, _err, called = run("ingest-and-wrap", "--input", "x", rc=3)
        self.assertEqual((3, ""), (rc, called))                        # a failed wrap: its exit code, no register

    def test_the_windows_launcher_has_the_same_rule(self) -> None:
        fake_os = type("FakeOs", (), {"name": "nt", "environ": os.environ})()
        with patch.object(json_tables, "os", fake_os), \
             patch.object(json_tables, "cmd_file_bytes", side_effect=lambda text: text.encode("utf-8")):
            json_tables._write_launchers(self.ctx)
            text = json_tables.paths(self.ctx)[2].read_bytes().decode("utf-8")
        lines = text.split("\r\n")
        cli = next(index for index, line in enumerate(lines) if line.endswith(" %*"))
        self.assertIn("setlocal", lines[:cli])
        self.assertEqual(['set "EXAKIT_JT_RC=%ERRORLEVEL%"', 'if not "%EXAKIT_JT_RC%"=="0" exit /b %EXAKIT_JT_RC%'],
                         lines[cli + 1:cli + 3])
        for rule in ('if /i "%~2"=="--help" exit /b 0', 'if /i "%~3"=="-h" exit /b 0',
                     'if /i "%~1"=="ingest-and-wrap" goto exakit_register', 'if /i not "%~1"=="wrap" exit /b 0',
                     'if /i "%~2"=="install" goto exakit_register', 'if /i "%~2"=="deploy" goto exakit_register'):
            self.assertIn(rule, lines)
        register = lines[lines.index(":exakit_register") + 1]
        self.assertTrue(register.endswith(f'"{self.GENERATE}" "--register" "--home" "{self.home}" 1>&2'), register)
        self.assertEqual(["exit /b 0", ""], lines[-2:])

    # --- the generator --------------------------------------------------------------------------------------------

    def generate(self, packages: dict, python: str | None = None, extra_env: dict | None = None) -> tuple[str, str]:
        state = self.home / "state.json"
        schemas = sorted(set(row["PUBLIC_SCHEMA"] for package in packages.values() for row in package["roots"]))
        state.write_text(json.dumps({"jvs": packages, "schemas": schemas}), encoding="utf-8")
        exapump = self.home / "exapump"
        exapump.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{ROOT / "tests/lib/fake-exapump.py"}" "$@"\n',
                           encoding="utf-8")
        exapump.chmod(0o755)
        out = self.home / "module.sql"
        env = {**os.environ, "FAKE_EXAPUMP_STATE": str(state), "PYTHONPATH": str(self.STUB), **(extra_env or {})}
        done = subprocess.run([python or sys.executable, str(self.GENERATE), "--home", str(self.home), "--exapump",
                               str(exapump), "--profile", "p", str(out)], text=True, capture_output=True, env=env)
        self.assertEqual(0, done.returncode, done.stderr)
        return out.read_text(encoding="utf-8"), done.stdout.strip()

    def fixture(self) -> dict:
        return json.loads(self.FIXTURE.read_text(encoding="utf-8"))

    @unittest.skipIf(os.name == "nt", "the stand-in exapump is a shell script")
    def test_the_artifact_is_a_framework_module_for_every_wrapper(self) -> None:
        sys.path.insert(0, str(ROOT / "setup" / "preprocessor"))
        import manage
        text, note = self.generate(self.fixture())
        self.assertEqual("exasol-json-tables v0.4.1 + 1 wrapper", note)
        artifact = self.home / "module.sql"
        module = manage.load_module("json-tables", artifact=str(artifact))
        self.assertEqual(("json_tables", "TRANSLATE", "ROLE", "PUBLIC", "self-deployed"),
                         (module["name"], module["phase"], module["scope_type"], module["scope_value"],
                          module["deploy_mode"]))
        self.assertEqual([("LUA SCALAR SCRIPT", "PREPROC_RT.JSON_TABLES_REFUSE_V{VERSION}"),
                          ("LUA SCRIPT", "PREPROC_RT.JSON_TABLES_LIB_V{VERSION}"),
                          ("LUA SCRIPT", "PREPROC_RT.JSON_TABLES_V{VERSION}")], module["objects"])
        self.assertIn("local SCHEMAS = {'SAMPLE_ORDERS_VIEW'}", text)
        self.assertIn("-- STUB JSON TABLES LIBRARY", text)                           # upstream's library, inline
        self.assertIn("['SAMPLE_ORDERS_VIEW'] = 'SAMPLE_ORDERS_VIEW_INTERNAL'", text)  # its configuration, inline
        self.assertIn("function rewrite_statement(sqltext)\n    return rewrite(sqltext, CONFIG)\nend", text)
        # The entry: the library only for a statement naming a wrapper schema; JSON Tables' own error, loud.
        self.assertIn('import("PREPROC_RT.JSON_TABLES_LIB_V{VERSION}", "json_tables_lib")', text)
        self.assertIn("local ok, result = pcall(rewriter.rewrite_statement, sqltext)", text)
        self.assertIn('return "SELECT PREPROC_RT.JSON_TABLES_REFUSE_V{VERSION}(" .. quoted(tostring(result)) .. ")"',
                      text)
        self.assertIn("error(ctx.message, 0)", text)
        self.assertEqual(text, self.generate(self.fixture())[0])                     # same wrappers, same module

    @unittest.skipIf(os.name == "nt", "the stand-in exapump is a shell script")
    def test_a_wrapper_whose_schema_was_dropped_is_left_out(self) -> None:
        # PPX-09: its helper schema (where upstream finds it) stays when the wrapper schema is dropped by hand.
        state = self.home / "state.json"
        packages = self.fixture()
        exapump = self.home / "exapump"
        self.generate(packages)                                          # writes the stand-in exapump
        state.write_text(json.dumps({"jvs": packages, "schemas": ["SAMPLE_ORDERS_VIEW_INTERNAL"]}), encoding="utf-8")
        out = self.home / "module.sql"
        env = {**os.environ, "FAKE_EXAPUMP_STATE": str(state), "PYTHONPATH": str(self.STUB)}
        done = subprocess.run([sys.executable, str(self.GENERATE), "--home", str(self.home), "--exapump",
                               str(exapump), "--profile", "p", str(out)], text=True, capture_output=True, env=env)
        self.assertEqual((0, "exasol-json-tables v0.4.1 + 0 wrappers"), (done.returncode, done.stdout.strip()),
                         done.stderr)
        self.assertIn("local SCHEMAS = {}", out.read_text(encoding="utf-8"))

    @unittest.skipIf(os.name == "nt", "the stand-in exapump is a shell script")
    def test_no_wrappers_is_a_module_that_passes_every_statement_through(self) -> None:
        text, note = self.generate({})
        self.assertEqual("exasol-json-tables v0.4.1 + 0 wrappers", note)
        self.assertIn("local SCHEMAS = {}", text)
        self.assertIn("function rewrite_statement(sqltext)\n    return sqltext\nend", text)
        self.assertNotIn("STUB JSON TABLES LIBRARY", text)

    @unittest.skipIf(os.name == "nt", "the stand-in exapump is a shell script")
    def test_a_null_the_database_left_out_is_still_in_its_column(self) -> None:
        # exapump's JSON omits a NULL value's key; the connection must not shift the next column into its place.
        from importlib import util
        spec = util.spec_from_file_location("jt_generate", self.GENERATE)
        generate = util.module_from_spec(spec)
        spec.loader.exec_module(generate)
        exapump = self.home / "exapump"
        exapump.write_text('#!/bin/sh\ncat >/dev/null\necho \'[{"A":1,"C":"c"},{"B":true}]\'\n', encoding="utf-8")
        exapump.chmod(0o755)
        con = generate.ExapumpConnection(str(exapump), "p")
        self.assertEqual([(1, None, "c"), (None, True, None)],
                         con.execute('SELECT A, x.B, "C" FROM T').fetchall())
        exapump.write_text('#!/bin/sh\ncat >/dev/null\necho \'[{"D":1}]\'\n', encoding="utf-8")
        with self.assertRaisesRegex(generate.GenerateError, "columns D the query did not ask for"):
            con.execute("SELECT A FROM T")

    @unittest.skipUnless(os.environ.get("EXAKIT_TEST_JSON_TABLES_PYTHON"),
                         "set EXAKIT_TEST_JSON_TABLES_PYTHON to a Python with upstream exasol-json-tables")
    def test_with_the_real_upstream_the_rewriter_is_json_tables_own(self) -> None:
        text, note = self.generate(self.fixture(), python=os.environ["EXAKIT_TEST_JSON_TABLES_PYTHON"],
                                   extra_env={"PYTHONPATH": ""})
        self.assertTrue(note.startswith("exasol-json-tables v") and note.endswith("+ 1 wrapper"), note)
        self.assertIn("function rewrite(sqltext, config)", text)
        self.assertIn("['allowed_json_schemas'] = {\n        ['SAMPLE_ORDERS_VIEW'] = true,", text)

class EngineReachTest(unittest.TestCase):
    """Windows ingest exited 127 on a fresh GA install: the .cmd launcher never told the cargo shim where the
    engine is. The launcher carries it now; a launcher an earlier kit wrote reads as installed and in need of an
    update, so every update path rewrites it; and validation is a real ingest through the launcher."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "kit home"
        self.home.mkdir()
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.path.write_text("{}", encoding="utf-8")
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))
        self.manifest.set_many({"components.json_tables": {"ownership": "kit", "version": "v0.4.1"}})

    def tearDown(self) -> None:
        self.temp.cleanup()

    def windows(self) -> contextlib.ExitStack:
        stack = contextlib.ExitStack()
        stack.enter_context(patch.object(json_tables, "os", type("FakeOs", (), {"name": "nt", "environ": os.environ})()))
        stack.enter_context(patch.object(json_tables, "cmd_file_bytes", side_effect=lambda text: text.encode("utf-8")))
        return stack

    def test_the_windows_launcher_tells_the_cargo_shim_where_the_engine_is(self) -> None:
        with self.windows():
            json_tables._write_launchers(self.ctx)
            engine = json_tables._engine(self.ctx)
            lines = json_tables.paths(self.ctx)[2].read_bytes().decode("utf-8").split("\r\n")
        self.assertTrue(str(engine).endswith("json_to_parquet.exe"), engine)
        setting = f'set "EXAKIT_JSON_TABLES_ENGINE={engine}"'
        self.assertIn(setting, lines)
        cli = next(index for index, line in enumerate(lines) if line.endswith(" %*"))
        self.assertLess(lines.index(setting), cli)                  # set before the CLI (and its shim) runs

    @unittest.skipIf(os.name == "nt", "POSIX shim")
    def test_the_posix_shim_carries_the_engine_path_itself(self) -> None:
        json_tables._write_launchers(self.ctx)
        import shlex
        self.assertIn(f"exec {shlex.quote(str(json_tables._engine(self.ctx)))} ",
                      json_tables._shim(self.ctx).read_text(encoding="utf-8"))

    def test_a_launcher_an_earlier_kit_wrote_is_stale_and_install_rewrites_it_without_a_download(self) -> None:
        old_windows = ('@echo off\r\nset "PATH=C:\\x\\shim;%PATH%"\r\nif not defined EXASOL_TELEMETRY_DISABLE '
                       'set "EXASOL_TELEMETRY_DISABLE=1"\r\n"C:\\x\\Scripts\\exasol-json-tables.exe" %*\r\n')
        for platform_name, stack, old in (("windows", self.windows, old_windows.encode()),
                                           ("posix", contextlib.ExitStack, b"#!/bin/sh\nexec cli \"$@\"\n")):
            with self.subTest(platform=platform_name), stack(), \
                 patch.object(json_tables, "_assets_complete", return_value=True), \
                 patch.object(json_tables, "system_present", return_value=False), \
                 patch.object(KitContext, "require_uv", return_value=Path("uv")), \
                 patch.object(json_tables, "applicable", return_value=True), \
                 patch.object(KitContext, "target_version", return_value="v0.4.1"), \
                 patch.object(json_tables, "_asset", side_effect=AssertionError("downloaded")), \
                 patch.object(json_tables, "register_module", return_value="skipped"):
                json_tables._write_launchers(self.ctx)
                self.assertEqual("v0.4.1", json_tables.installed_version(self.ctx))
                self.assertFalse(json_tables.needs_update(self.ctx))
                launcher = json_tables.paths(self.ctx)[2]
                launcher.write_bytes(old)
                # Installed (never "not installed"), and in need of the update that update, kit update, data load run.
                self.assertEqual("v0.4.1", json_tables.installed_version(self.ctx))
                self.assertTrue(json_tables.needs_update(self.ctx))
                json_tables.install(self.ctx)
                self.assertNotEqual(old, launcher.read_bytes())
                self.assertEqual("v0.4.1", json_tables.installed_version(self.ctx))
                self.assertFalse(json_tables.needs_update(self.ctx))

    @unittest.skipIf(os.name == "nt", "POSIX launcher")
    def test_a_0_2_5_install_is_installed_and_its_update_rewrites_validates_and_registers(self) -> None:
        """The 0.2.5 -> 0.3.0 upgrade: kit 0.2.5's receipt (no ownership field) and its launcher, byte for byte.
        The add-on reads as installed at v0.4.1 and in need of an update; the update the kit runs rewrites the
        launcher without a download, validates, registers the module, and the receipt the framework's own pass
        reads is the kit's from then on."""
        sys.path.insert(0, str(ROOT / "setup" / "preprocessor"))
        import manage  # noqa: E402
        venv, home, launcher = json_tables.paths(self.ctx)
        engine, shim = json_tables._engine(self.ctx), json_tables._shim(self.ctx)
        self.manifest.path.write_text(json.dumps({"components": {"json_tables": {
            "version": "v0.4.1", "venv": str(venv), "python": str(venv / "bin" / "python"),
            "engine": str(engine), "command": str(launcher), "validated": True}}}), encoding="utf-8")
        # setup/lib/json-tables.sh json_tables_write_launcher at 14df2ecb (kit 0.2.5), with its placeholders filled
        old = ("#!/bin/sh\n"
               "# exasol-json-tables launcher \u2014 generated by the Exasol Personal Local Starter\n"
               "# Kit. Runs the CLI from its kit-managed venv with the prebuilt ingest engine\n"
               "# in front of PATH, so no Rust toolchain is needed. Regenerated by:\n"
               "#   exakit update json-tables\n"
               f'PATH="{shim.parent}:$PATH"\nexport PATH\nexec "{venv}/bin/exasol-json-tables" "$@"\n').encode("utf-8")
        launcher.parent.mkdir(parents=True, exist_ok=True)
        launcher.write_bytes(old)
        doc = json.loads(self.manifest.path.read_text(encoding="utf-8"))
        self.assertNotIn("json-tables", manage.installed_addons(doc, str(ROOT / "setup" / "preprocessor" / "modules")))
        with patch.object(json_tables, "_assets_complete", return_value=True), \
             patch.object(json_tables, "system_present", return_value=False), \
             patch.object(KitContext, "require_uv", return_value=Path("uv")), \
             patch.object(json_tables, "applicable", return_value=True), \
             patch.object(KitContext, "target_version", return_value="v0.4.1"), \
             patch.object(json_tables, "_asset", side_effect=AssertionError("downloaded")), \
             patch.object(json_tables, "validate", return_value=True) as validate, \
             patch.object(json_tables, "register_module", return_value="ok") as register:
            self.assertEqual((0, "v0.4.1"), invoke(ROOT, "json-tables", "installed-version", ctx=self.ctx))
            self.assertEqual((0, None), invoke(ROOT, "json-tables", "needs-update", ctx=self.ctx))
            invoke(ROOT, "json-tables", "update", ctx=self.ctx)
            self.assertEqual((1, None), invoke(ROOT, "json-tables", "needs-update", ctx=self.ctx))
        self.assertNotEqual(old, launcher.read_bytes())
        validate.assert_called_once()
        register.assert_called_once()
        doc = json.loads(self.manifest.path.read_text(encoding="utf-8"))
        self.assertEqual("kit", doc["components"]["json_tables"]["ownership"])
        self.assertIn("json-tables", manage.installed_addons(doc, str(ROOT / "setup" / "preprocessor" / "modules")))

    @unittest.skipIf(os.name == "nt", "POSIX launcher")
    def test_validation_is_a_real_ingest_through_the_launcher(self) -> None:
        venv = json_tables.paths(self.ctx)[0]
        cli = venv / "bin" / "exasol-json-tables"
        cli.parent.mkdir(parents=True)
        writes = ('#!/bin/sh\n[ "$1" = ingest ] || exit 2\nwhile [ "$#" -gt 0 ]; do [ "$1" = --output-dir ] && '
                  'out="$2"; shift; done\nmkdir -p "$out" && : > "$out/sample.parquet"\n')
        with patch.object(json_tables, "_assets_complete", return_value=True):
            json_tables._write_launchers(self.ctx)
            for body, expected in ((writes, True), ("#!/bin/sh\necho 'cargo is not installed' >&2\nexit 127\n", False),
                                   ("#!/bin/sh\nexit 0\n", False)):
                with self.subTest(expected=expected, body=body[:30]):
                    cli.write_text(body, encoding="utf-8")
                    cli.chmod(0o755)
                    self.assertIs(expected, json_tables.validate(self.ctx))
                    self.assertIs(expected, self.manifest.get("components.json_tables.validated"))


if __name__ == "__main__":
    unittest.main()
