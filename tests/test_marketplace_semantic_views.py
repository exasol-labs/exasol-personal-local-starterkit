"""(run: python3 tests/test_marketplace_semantic_views.py) The semantic-views add-on: the release it installs is the
pinned one, its digest is checked before anything is unpacked, it is installed with the release's own installer and
the kit's connection (the password only in that process's environment, and redacted from the log), it never touches
an installation the kit did not make, and removing it never deletes a model."""

from __future__ import annotations

import hashlib
import io
import json
import os
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
sys.path.insert(0, str(ROOT / "marketplace" / "addons"))

import semantic_views as sv  # noqa: E402
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402

SECRET = "pa55-not-shown"


def release_zip(version: str = "v0.6.1", *, escape: bool = False, complete: bool = True) -> bytes:
    """A stand-in release archive, shaped like the real one (one top folder, built install SQL, the installer)."""
    top = f"exasol-semantic-views-{version}"
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        if complete:
            archive.writestr(f"{top}/tools/install.py", "print('installed')\n")
            archive.writestr(f"{top}/build/install/000_create_schemas.sql", "CREATE SCHEMA IF NOT EXISTS SYS_SEMANTIC;\n")
        archive.writestr(f"{top}/README.md", "readme\n")
        if escape:
            archive.writestr("../outside.txt", "no\n")
    return buffer.getvalue()


class Response(io.BytesIO):
    url = "https://github.com/example"

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class SemanticViewsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name) / "home"
        self.home.mkdir()
        credential = self.home / "credentials" / "exasol_password"
        credential.parent.mkdir()
        credential.write_text(SECRET + "\n", encoding="utf-8")
        python = self.home / "pyexasol-venv" / "bin" / "python"
        python.parent.mkdir(parents=True)
        python.write_text("")
        (self.home / "manifest.json").write_text("{}\n", encoding="utf-8")       # a kit is installed here
        self.manifest = Manifest(self.home / "manifest.json")
        self.manifest.set_many({"runtime.dsn": "127.0.0.1:8563", "runtime.user": "sys",
                                "runtime.password_file": str(credential), "components.pyexasol.python": str(python)})
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.manifest, Path("uv"))
        self.addCleanup(self.temp.cleanup)
        for name in ("EXAKIT_MARKETPLACE_TARGET_VERSION", "EXAKIT_VERSION_POLICY"):
            self.addCleanup(os.environ.pop, name, None)
            os.environ.pop(name, None)
        os.environ["EXAKIT_VERSION_POLICY"] = "pinned"

    def present(self, schemas=(), role=False, version=None, models=None):
        return {"schemas": sorted(schemas), "role": role, "version": version, "models": models}

    # -- the catalog, the pin and the help agree ------------------------------------------------------------------

    def test_the_catalog_the_pin_and_the_help_agree(self):
        catalog = json.loads((ROOT / "marketplace" / "catalog.json").read_text(encoding="utf-8"))
        row = next(r for r in catalog["addons"] if r["id"] == sv.ID)
        pin = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"][sv.ID]
        self.assertEqual(sv.REPO, row["github"]["repo"])
        self.assertEqual(row["default_version"], pin["version"])
        self.assertEqual(f"exasol-semantic-views-{pin['version']}.zip", pin["asset"])
        self.assertRegex(pin["sha256"]["archive"], r"^[0-9a-f]{64}$")
        self.assertEqual(pin["version"], sv._version(self.ctx))
        self.assertTrue((ROOT / "setup" / "help" / f"{sv.ID}.json").is_file())
        lock = json.loads((ROOT / "skills" / "upstream.lock.json").read_text(encoding="utf-8"))["skills"]
        for name in ("exasol-semantic-analyst", "exasol-semantic-modeler", "exasol-semantic-reviewer"):
            self.assertEqual(sv.ID, lock[name]["addon"])

    # -- the download -----------------------------------------------------------------------------------------------

    def test_the_pinned_digest_is_used_and_a_mismatch_installs_nothing(self):
        version = sv._version(self.ctx)
        pin = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"][sv.ID]["sha256"]["archive"]
        self.assertEqual(pin, sv._expected_digest(self.ctx, version, sv.REPO, f"exasol-semantic-views-{version}.zip"))
        archive = Path(self.temp.name) / "release.zip"
        with mock.patch.object(sv, "_https", side_effect=lambda url: Response(release_zip())):
            with self.assertRaisesRegex(AddonFailure, "Checksum mismatch"):
                sv._download(self.ctx, version, archive)
        self.assertFalse(archive.exists())

    def test_a_good_archive_downloads_and_unpacks_and_a_bad_one_is_refused(self):
        data = release_zip()
        archive = Path(self.temp.name) / "release.zip"
        with mock.patch.object(sv, "_expected_digest", return_value=hashlib.sha256(data).hexdigest()), \
                mock.patch.object(sv, "_https", side_effect=lambda url: Response(data)):
            sv._download(self.ctx, "v0.6.1", archive)
        top = sv._unpack(archive, Path(self.temp.name) / "out")
        self.assertTrue((top / "tools" / "install.py").is_file())
        for bad, why in ((release_zip(escape=True), "outside its folder"), (release_zip(complete=False), "no built install SQL")):
            path = Path(self.temp.name) / "bad.zip"
            path.write_bytes(bad)
            with self.subTest(why=why), self.assertRaisesRegex(AddonFailure, why):
                sv._unpack(path, Path(tempfile.mkdtemp(dir=self.temp.name)))

    def test_no_checksum_is_no_install(self):
        with mock.patch.object(sv, "_expected_digest", return_value=None):
            with self.assertRaisesRegex(AddonFailure, "refusing an unverified archive"):
                sv._download(self.ctx, "v9.9.9", Path(self.temp.name) / "x.zip")

    # -- install ----------------------------------------------------------------------------------------------------

    def test_install_runs_the_releases_installer_with_the_kits_connection_and_records_it(self):
        data = release_zip()
        calls = []

        def run_logged(label, *argv, env=None, cwd=None, timeout=None):     # patched on the class: no self
            calls.append((argv, env, cwd))

        with mock.patch.object(sv, "_expected_digest", return_value=hashlib.sha256(data).hexdigest()), \
                mock.patch.object(sv, "_https", side_effect=lambda url: Response(data)), \
                mock.patch.object(sv, "_present", return_value=self.present()), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1/ABCDEF:8563"), \
                mock.patch.object(KitContext, "run_logged", side_effect=run_logged), \
                mock.patch.object(sv, "system_present", return_value=False):
            sv.install(self.ctx)
        (argv, env, cwd), = calls
        version = sv._version(self.ctx)
        self.assertEqual(self.home / "semantic-views" / version, Path(cwd))
        self.assertEqual([str(cwd / Path("tools") / "install.py"), "--skip-package"], [str(a) for a in argv[1:]])
        self.assertNotIn(SECRET, " ".join(map(str, argv)))                             # never an argument
        self.assertEqual((SECRET, "127.0.0.1/ABCDEF", "8563", "sys"),
                         (env["EXASOL_PASSWORD"], env["EXASOL_HOST"], env["EXASOL_PORT"], env["EXASOL_USER"]))
        self.assertTrue(env["EXASOL_PASSWORD"] and "PASSWORD" in "EXASOL_PASSWORD")   # run_logged redacts *PASSWORD
        self.assertEqual(version.removeprefix("v"), sv.installed_version(self.ctx))
        self.assertTrue(self.manifest.get(f"{sv.RECEIPT}.role_created"))
        self.assertEqual("kit", self.manifest.get(f"{sv.RECEIPT}.ownership"))

    def test_an_installation_the_kit_did_not_make_is_left_alone(self):
        with mock.patch.object(sv, "_present", return_value=self.present(sv.SCHEMAS, True, "0.5.0", 2)):
            self.assertTrue(sv.system_present(self.ctx))
            with self.assertRaisesRegex(AddonFailure, "not installed by the kit"):
                sv.install(self.ctx)
            self.manifest.set_many({f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1"})
            self.assertFalse(sv.system_present(self.ctx))

    def test_without_a_database_it_is_not_offered(self):
        self.manifest.delete("runtime.dsn")
        self.assertFalse(sv.applicable(self.ctx))
        with self.assertRaisesRegex(AddonFailure, "no database connection"):
            sv.install(self.ctx)

    def test_validate_needs_every_schema_and_a_recorded_version(self):
        for found, ok in ((self.present(sv.SCHEMAS, True, "0.6.1", 0), True),
                          (self.present(sv.SCHEMAS[1:], True, "0.6.1", 0), False),
                          (self.present(sv.SCHEMAS, True, None, None), False)):
            with self.subTest(found=found), mock.patch.object(sv, "_present", return_value=found):
                self.assertEqual(ok, sv.validate(self.ctx))

    # -- an install that stops part-way (audit MKT-06) ------------------------------------------------------------

    def interrupted(self):
        """The add-on module as service.py loads it, a database that starts empty, and a first install whose
        installer created two schemas and the role and then failed (its 900 s timeout, a dropped connection, Ctrl-C)."""
        import service

        _, module = service._module(ROOT, sv.ID)
        db = {"schemas": set(), "role": False, "version": None}
        state = {"fail": True}

        def present(_ctx):                      # no model was defined: a count of 0 (None is "could not count")
            return {"schemas": sorted(db["schemas"]), "role": db["role"], "version": db["version"],
                    "models": 0, "models_error": None}

        def installer(_ctx, _release):
            db["schemas"] |= {"SYS_SEMANTIC", "SEMANTIC_ADMIN"}
            db["role"] = True
            if state["fail"]:
                raise AddonFailure("Installing Exasol Semantic Views into the database failed (timeout 900s)")
            db["schemas"] |= set(sv.SCHEMAS)
            db["version"] = "0.6.1"

        def run_sql(_ctx, *statements, timeout=120):
            for statement in statements:
                if statement.startswith("DROP SCHEMA IF EXISTS "):
                    db["schemas"].discard(statement.split()[4])
                elif statement == f"DROP ROLE {sv.ROLE} CASCADE":
                    db["role"] = False
            return []

        data = release_zip()
        patches = [mock.patch.object(module, "_present", side_effect=present),
                   mock.patch.object(module, "_run_installer", side_effect=installer),
                   mock.patch.object(module, "_db", side_effect=run_sql),
                   mock.patch.object(module, "_expected_digest", return_value=hashlib.sha256(data).hexdigest()),
                   mock.patch.object(module, "_https", side_effect=lambda url: Response(data))]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        with self.assertRaisesRegex(AddonFailure, "timeout"):
            service.invoke(ROOT, sv.ID, "install", ctx=self.ctx)
        return service, module, db, state

    def test_an_interrupted_install_stays_the_kits_and_the_next_install_resumes_it(self):
        service, module, db, state = self.interrupted()
        self.assertEqual("kit", self.manifest.get(f"{sv.RECEIPT}.ownership"))
        self.assertEqual("installing", self.manifest.get(f"{sv.RECEIPT}.state"))
        self.assertFalse(module.system_present(self.ctx))              # not "installed outside the kit"
        self.assertIsNone(module.installed_version(self.ctx))          # and not installed either
        state["fail"] = False
        service.invoke(ROOT, sv.ID, "install", ctx=self.ctx)
        self.assertEqual(set(sv.SCHEMAS), db["schemas"])
        self.assertEqual(sv._version(self.ctx).removeprefix("v"), module.installed_version(self.ctx))
        self.assertIsNone(self.manifest.get(f"{sv.RECEIPT}.state"))
        self.assertTrue(self.manifest.get(f"{sv.RECEIPT}.role_created"))   # the first attempt made it

    def test_an_interrupted_install_can_be_updated_and_removed(self):
        service, module, db, state = self.interrupted()
        state["fail"] = False
        with mock.patch.object(module, "validate", return_value=True):
            service.invoke(ROOT, sv.ID, "update", ctx=self.ctx)
        self.assertIsNone(self.manifest.get(f"{sv.RECEIPT}.state"))
        db.update({"schemas": {"SYS_SEMANTIC", "SEMANTIC_ADMIN"}, "role": True, "version": None})
        self.manifest.set_many({f"{sv.RECEIPT}.state": "installing"})
        # The preview names the database steps of the removal below, not only the folder.
        self.assertEqual(["the schemas SEMANTIC_AGENT, SEMANTIC_SOURCE, SEMANTIC_CATALOG, SEMANTIC_ADMIN, SYS_SEMANTIC where present (DROP SCHEMA ... CASCADE); nothing is removed while a semantic model is defined, or when the models cannot be counted",
                          "the role SEMANTIC_USER (DROP ROLE ... CASCADE)", str(self.home / "semantic-views")],
                         [str(item) for item in service.invoke(ROOT, sv.ID, "uninstall", dry_run=True, ctx=self.ctx)[1]])
        removed = service.invoke(ROOT, sv.ID, "uninstall", ctx=self.ctx)[1]
        self.assertEqual((set(), False), (db["schemas"], db["role"]))   # the role too: the kit made it
        # It names what it removed, which `exakit uninstall` reports: what was there, not the five it might have made.
        self.assertEqual(["schema SEMANTIC_ADMIN", "schema SYS_SEMANTIC", "role SEMANTIC_USER"],
                         [str(item) for item in removed if isinstance(item, str)])
        self.assertIsNone(self.manifest.get(sv.RECEIPT))

    def test_an_installation_made_outside_the_kit_still_gets_no_receipt(self):
        import service

        _, module = service._module(ROOT, sv.ID)
        with mock.patch.object(module, "_present", return_value=self.present(sv.SCHEMAS, True, "0.5.0", 2)), \
                mock.patch.object(module, "_run_installer") as installer:
            with self.assertRaisesRegex(AddonFailure, "outside the kit"):
                service.invoke(ROOT, sv.ID, "install", ctx=self.ctx)
        installer.assert_not_called()
        self.assertIsNone(self.manifest.get(sv.RECEIPT))

    # -- removal ----------------------------------------------------------------------------------------------------

    def test_removal_never_deletes_a_model_and_drops_only_what_the_kit_made(self):
        self.manifest.set_many({f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1",
                                f"{sv.RECEIPT}.role_created": False})
        (self.home / "semantic-views" / "v0.6.1").mkdir(parents=True)
        # The 0.3.0 upgrade test: the preview listed the folder only, while the removal drops five schemas (and the
        # role the kit made, revokes the AI login's grant, retires the module): every one is named. A role the kit
        # did not make is not.
        self.assertEqual(["the schemas SEMANTIC_AGENT, SEMANTIC_SOURCE, SEMANTIC_CATALOG, SEMANTIC_ADMIN, SYS_SEMANTIC where present (DROP SCHEMA ... CASCADE); nothing is removed while a semantic model is defined, or when the models cannot be counted", self.home / "semantic-views"], sv.uninstall(self.ctx, dry_run=True))
        self.manifest.set_many({f"{sv.RECEIPT}.role_created": True, f"{sv.RECEIPT}.mcp_login": "MCP_READONLY",
                                "components.preprocessor.modules.semantic-views.version": 1})
        self.assertEqual(["Semantic SQL stops working in every session (the SQL preprocessor's Semantic SQL module is switched off)",
                          "the SEMANTIC_USER grant to MCP_READONLY (REVOKE)", "the schemas SEMANTIC_AGENT, SEMANTIC_SOURCE, SEMANTIC_CATALOG, SEMANTIC_ADMIN, SYS_SEMANTIC where present (DROP SCHEMA ... CASCADE); nothing is removed while a semantic model is defined, or when the models cannot be counted",
                          "the role SEMANTIC_USER (DROP ROLE ... CASCADE)", self.home / "semantic-views"],
                         sv.uninstall(self.ctx, dry_run=True))
        self.manifest.set_many({f"{sv.RECEIPT}.role_created": False, f"{sv.RECEIPT}.mcp_login": None,
                                "components.preprocessor.modules.semantic-views": None})
        with mock.patch.object(sv, "_present", return_value=self.present(sv.SCHEMAS, True, "0.6.1", 3)), \
                mock.patch.object(sv, "_db") as db:
            with self.assertRaisesRegex(AddonFailure, "3 semantic model"):
                sv.uninstall(self.ctx)
        db.assert_not_called()
        self.assertTrue((self.home / "semantic-views").exists())
        with mock.patch.object(sv, "_present", return_value=self.present(sv.SCHEMAS, True, "0.6.1", 0)), \
                mock.patch.object(sv, "_db") as db:
            sv.uninstall(self.ctx)
        dropped = db.call_args[0][1:]
        self.assertEqual({f"DROP SCHEMA IF EXISTS {name} CASCADE" for name in sv.SCHEMAS}, set(dropped))
        self.assertNotIn(f"DROP ROLE {sv.ROLE} CASCADE", dropped)                      # it was there before the kit
        self.assertFalse((self.home / "semantic-views").exists())
        self.assertIsNone(self.manifest.get(sv.RECEIPT))

    def test_removal_fails_closed_when_the_models_cannot_be_counted(self):
        """Audit SCR-06: the version and the model count were read as one batch and any failure was swallowed, so a
        count that could not be read (no PRODUCT_VERSION in a partial install, a privilege, a timeout) read as "no
        models" and DROP SCHEMA ... CASCADE took the user's models. The real _present runs here, on a simulated
        database: the count is read on its own, and a count that cannot be read refuses the removal."""
        folder = self.home / "semantic-views" / "v0.6.1"

        def removal(models, fail=(), table=True):
            folder.mkdir(parents=True, exist_ok=True)
            self.manifest.set_many({f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1",
                                    f"{sv.RECEIPT}.role_created": True})
            issued, retired = [], []

            def db(_ctx, *statements, timeout=120):
                answers = []
                for statement in statements:
                    issued.append(statement)
                    if any(part in statement for part in fail):
                        raise AddonFailure(f"Semantic Views database step failed: {statement[:40]} refused")
                    if "EXA_SCHEMAS" in statement:
                        answers.append([[name] for name in sv.SCHEMAS])
                    elif "EXA_ALL_ROLES" in statement:
                        answers.append([[sv.ROLE]])
                    elif "PRODUCT_VERSION" in statement:
                        answers.append([["0.6.1"]])
                    elif "EXA_DBA_TABLES" in statement:
                        answers.append([[1]] if table else [])
                    elif "COUNT(*)" in statement:
                        answers.append([[models]])
                    else:
                        answers.append(0)
                return answers

            with mock.patch.object(sv, "_db", side_effect=db), \
                    mock.patch.object(sv.preprocessor_modules, "retire",
                                      side_effect=lambda ctx, addon: retired.append(addon) or ("ok", "")):
                try:
                    sv.uninstall(self.ctx)
                    error = None
                except AddonFailure as failure:
                    error = str(failure)
            return error, [s for s in issued if s.startswith(("DROP", "REVOKE"))], retired

        for fail in (("COUNT(*)",), ("EXA_DBA_TABLES",)):            # the count cannot be read: nothing removed
            with self.subTest(fail=fail):
                error, drops, retired = removal(3, fail=fail)
                self.assertIn("Could not check whether semantic models exist (Semantic Views database step failed",
                              error or "")
                self.assertIn("nothing was removed", error)
                self.assertEqual(([], []), (drops, retired))
                self.assertTrue(folder.exists())
                self.assertEqual("kit", self.manifest.get(f"{sv.RECEIPT}.ownership"))
        # The version cannot be read but the count can: the count still decides.
        error, drops, retired = removal(2, fail=("PRODUCT_VERSION",))
        self.assertIn("2 semantic model(s) are defined", error or "")
        self.assertEqual(([], []), (drops, retired))
        error, drops, _ = removal(0, fail=("PRODUCT_VERSION",))
        self.assertIsNone(error)
        self.assertIn("DROP SCHEMA IF EXISTS SEMANTIC_CATALOG CASCADE", drops)
        # Models defined: refused. None: removed. An install that stopped before the MODELS table: removed too.
        error, drops, _ = removal(4)
        self.assertIn("4 semantic model(s) are defined", error or "")
        # The way out is a command that runs as printed once the name is filled in, not "(...)".
        self.assertIn("Drop each one first with EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('<model name>'), then remove "
                      "the add-on again", error)
        self.assertEqual([], drops)
        for table in (True, False):
            with self.subTest(table=table):
                error, drops, retired = removal(0, table=table)
                self.assertIsNone(error)
                self.assertEqual({f"DROP SCHEMA IF EXISTS {name} CASCADE" for name in sv.SCHEMAS}
                                 | {f"DROP ROLE {sv.ROLE} CASCADE"}, set(drops))
                self.assertEqual([sv.ID], retired)
                self.assertFalse(folder.exists())
                self.assertIsNone(self.manifest.get(sv.RECEIPT))
        # The count comes from the table that holds the models, not a view filtered by the reader's roles.
        with mock.patch.object(sv, "_db", side_effect=lambda ctx, *s, timeout=120:
                               [[[name] for name in sv.SCHEMAS], []] if len(s) == 2 else [[[7]]]) as db:
            self.assertEqual(7, sv._present(self.ctx)["models"])
        self.assertIn(mock.call(self.ctx, "SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS"), db.call_args_list)

    # -- the AI login: Semantic SQL through the kit's MCP server (PRE-01) -------------------------------------------

    def test_install_and_update_grant_the_ai_login_semantic_user(self):
        self.manifest.set_many({"components.mcp_server.connection.user": "mcp_readonly"})
        answers = {"EXA_DBA_USERS": [[1]], "EXA_DBA_ROLE_PRIVS": []}

        def db(ctx, *statements, timeout=120):
            if statements[0].startswith("SELECT"):
                return [answers["EXA_DBA_USERS"], answers["EXA_DBA_ROLE_PRIVS"]]
            return [0 for _ in statements]

        with mock.patch.object(sv, "_db", side_effect=db) as called:
            sv.grant_mcp_login(self.ctx)
        self.assertEqual(('GRANT SEMANTIC_USER TO "MCP_READONLY"',), called.call_args_list[-1][0][1:])
        self.assertEqual("MCP_READONLY", self.manifest.get(f"{sv.RECEIPT}.mcp_login"))
        answers["EXA_DBA_ROLE_PRIVS"] = [[1]]                                   # an update: already granted
        with mock.patch.object(sv, "_db", side_effect=db) as called:
            sv.grant_mcp_login(self.ctx)
        self.assertEqual(1, called.call_count)
        self.manifest.delete(f"{sv.RECEIPT}.mcp_login")
        answers["EXA_DBA_USERS"] = []                                          # the login is not there yet
        with mock.patch.object(sv, "_db", side_effect=db) as called:
            sv.grant_mcp_login(self.ctx)
        self.assertEqual(1, called.call_count)
        self.assertIsNone(self.manifest.get(f"{sv.RECEIPT}.mcp_login"))
        with mock.patch.object(sv, "_db", side_effect=AddonFailure("down")):  # never fatal to the install
            sv.grant_mcp_login(self.ctx)
        self.manifest.delete("components.mcp_server")
        with mock.patch.object(sv, "_db") as called:                           # no AI login: nothing asked
            sv.grant_mcp_login(self.ctx)
        called.assert_not_called()

    def test_install_ends_with_the_ai_login_grant(self):
        data = release_zip()
        with mock.patch.object(sv, "_expected_digest", return_value=hashlib.sha256(data).hexdigest()), \
                mock.patch.object(sv, "_https", side_effect=lambda url: Response(data)), \
                mock.patch.object(sv, "_present", return_value=self.present()), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1:8563"), \
                mock.patch.object(KitContext, "run_logged"), \
                mock.patch.object(sv, "system_present", return_value=False), \
                mock.patch.object(sv, "grant_mcp_login") as grant:
            sv.install(self.ctx)
        grant.assert_called_once_with(self.ctx)

    def test_removal_takes_the_ai_logins_grant_back(self):
        self.manifest.set_many({f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1",
                                f"{sv.RECEIPT}.role_created": False, f"{sv.RECEIPT}.mcp_login": "MCP_READONLY"})
        with mock.patch.object(sv, "_present", return_value=self.present(sv.SCHEMAS, True, "0.6.1", 0)), \
                mock.patch.object(sv, "_db", side_effect=lambda ctx, *s, timeout=120: [[[1]]] if s[0].startswith("SELECT") else []) as db:
            sv.uninstall(self.ctx)
        statements = db.call_args[0][1:]
        self.assertEqual('REVOKE SEMANTIC_USER FROM "MCP_READONLY"', statements[0])
        self.assertIsNone(self.manifest.get(sv.RECEIPT))

    def test_the_mcp_server_offers_no_tool_that_switches_the_preprocessor(self):
        """Semantic SQL is a framework module in every session (RPM-01): the kit's MCP server has the
        SQL-preprocessor tools off in both twins, and the master skill says why."""
        bash = (ROOT / "setup" / "lib" / "mcp.sh").read_text(encoding="utf-8")
        ps = (ROOT / "setup" / "lib" / "mcp.ps1").read_text(encoding="utf-8")
        skill = (ROOT / "skills" / "exakit" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn('"enable_preprocessor_tools": False', bash)
        self.assertNotIn('"enable_preprocessor_tools": True', bash)
        self.assertIn("enable_preprocessor_tools = $false", ps)
        self.assertNotIn("enable_preprocessor_tools = $true", ps)
        self.assertIn("The kit's MCP server has no\n  preprocessor tools for that reason.", skill)

    # -- Semantic SQL in every session: the add-on is a module of the kit's SQL preprocessor framework ---------------

    def module(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("exakit_preproc_manage", ROOT / "setup" / "preprocessor" / "manage.py")
        manage = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(manage)
        return manage, manage.load_module(sv.ID)

    def test_the_module_folder_is_a_valid_pinned_module_for_every_user(self):
        manage, module = self.module()
        self.assertEqual((sv.RECEIPT, "EXPAND", "ROLE", "PUBLIC"),
                         (module["receipt"], module["phase"], module["scope_type"], module["scope_value"]))
        self.assertEqual("PREPROC_RT.SEMANTIC_VIEWS_V1", module["script"])
        self.assertEqual([("LUA SCALAR SCRIPT", "PREPROC_RT.SEMANTIC_VIEWS_REFUSE_V1"),
                          ("LUA SCRIPT", "PREPROC_RT.SEMANTIC_VIEWS_V1")], module["objects"])
        pin = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"][sv.ID]
        self.assertEqual(pin["version"], module["source_ref"])          # provenance names the release it delegates to

    def test_the_entry_function_keeps_the_frameworks_module_contract(self):
        """No Lua runner here: the contract is checked on the text (framework docs/module-authoring.md)."""
        _, module = self.module()
        entry = next(statement for statement in __import__("re").split(r"\n/\n", module["text"])
                     if "PREPROC_RT.SEMANTIC_VIEWS_V1()" in statement)
        entry = "\n".join(line for line in entry.splitlines() if not line.strip().startswith("--"))   # code only
        body = entry[entry.index("function semantic_views(sqltext)"):]
        self.assertRegex(entry, r"(?m)^function semantic_views\(sqltext\)$")      # a plain global, not local
        self.assertNotIn("pcall", entry)                                         # no defensive pcall
        self.assertNotIn("setsqltext", entry)                                    # MASTER sets the text, not a module
        self.assertNotIn("getsqltext", body)                                     # the entry decides on its argument
        self.assertNotIn("import(", body)                                        # import only at the top of the script
        self.assertIn('if result.status == "UNCHANGED" then\n        return nil', body)   # EXPAND: decline = nil
        self.assertNotRegex(entry, r"return [^\n]*gsub\(")                      # the gsub trap
        for name in ("SEMANTIC_ADMIN.COMPILER_RUNTIME", "SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME",
                     "compile_sql_for_preprocessor(sqltext)", "preprocess_sql(sqltext)"):
            self.assertIn(name, entry)                                           # upstream's own code does the work
        self.assertIn("SELECT PREPROC_RT.SEMANTIC_VIEWS_REFUSE_V1(", body)       # a refusal keeps its own words
        self.assertNotIn("SEMANTIC_PREPROCESSOR", entry)                          # never the slot-taking script

    def test_install_registers_the_module_and_update_retires_it_while_the_installer_runs(self):
        data = release_zip()
        order = []
        with mock.patch.object(sv, "_expected_digest", return_value=hashlib.sha256(data).hexdigest()), \
                mock.patch.object(sv, "_https", side_effect=lambda url: Response(data)), \
                mock.patch.object(sv, "_present", return_value=self.present()), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1:8563"), \
                mock.patch.object(KitContext, "run_logged", side_effect=lambda *a, **k: order.append("installer")), \
                mock.patch.object(sv, "system_present", return_value=False), \
                mock.patch.object(sv, "grant_mcp_login", side_effect=lambda ctx: order.append("grant")), \
                mock.patch.object(sv.preprocessor_modules, "register",
                                  side_effect=lambda ctx, addon: order.append("register " + addon) or ("ok", "")), \
                mock.patch.object(sv.preprocessor_modules, "retire",
                                  side_effect=lambda ctx, addon: order.append("retire " + addon) or ("ok", "")):
            sv.install(self.ctx)
            self.assertEqual(["installer", "grant", "register semantic-views"], order)
            order.clear()
            with mock.patch.object(sv, "validate", return_value=True):
                sv.update(self.ctx)
            self.assertEqual(["retire semantic-views", "installer", "grant", "register semantic-views"], order)

    def test_an_update_whose_installer_fails_registers_the_module_again_or_leaves_the_update_to_retry(self):
        # PPX-05: the update retired the module; a failed installer left Semantic SQL off for every user, the receipt
        # stuck installing (which the framework's verify skips), and nothing ever registered it again.
        data = release_zip()

        def update(valid, registered):
            self.manifest.set_many({sv.RECEIPT: {"ownership": "kit", "version": "v0.6.1"}})
            order = []

            def installer(*_args, **_kwargs):
                order.append("installer")
                raise AddonFailure("the installer exited with 1")

            with mock.patch.object(sv, "_expected_digest", return_value=hashlib.sha256(data).hexdigest()), \
                    mock.patch.object(sv, "_https", side_effect=lambda url: Response(data)), \
                    mock.patch.object(sv, "_present", return_value=self.present()), \
                    mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1:8563"), \
                    mock.patch.object(KitContext, "run_logged", side_effect=installer), \
                    mock.patch.object(sv, "validate", return_value=valid), \
                    mock.patch.object(sv, "grant_mcp_login"), \
                    mock.patch.object(sv.preprocessor_modules, "register",
                                      side_effect=lambda ctx, addon: order.append("register " + addon)
                                      or (registered, "")), \
                    mock.patch.object(sv.preprocessor_modules, "retire",
                                      side_effect=lambda ctx, addon: order.append("retire " + addon) or ("ok", "")):
                with self.assertRaisesRegex(AddonFailure, "the installer exited with 1"):
                    sv.update(self.ctx)
            return order, self.manifest.get(f"{sv.RECEIPT}.state"), sv.needs_update(self.ctx)

        # The database still holds a whole Semantic Views: the module is back, the receipt is the earlier install.
        self.assertEqual((["retire semantic-views", "installer", "register semantic-views"], None, False),
                         update(valid=True, registered="ok"))
        self.assertEqual("v0.6.1", self.manifest.get(f"{sv.RECEIPT}.version"))
        # The registration fails as well, or the runtimes are gone: the next `exakit update` runs the update again.
        self.assertEqual((["retire semantic-views", "installer", "register semantic-views"], "installing", True),
                         update(valid=True, registered="failed"))
        self.assertEqual((["retire semantic-views", "installer"], "installing", True),
                         update(valid=False, registered="ok"))

    def test_a_framework_that_cannot_take_the_module_never_fails_the_install(self):
        data = release_zip()
        with mock.patch.object(sv, "_expected_digest", return_value=hashlib.sha256(data).hexdigest()), \
                mock.patch.object(sv, "_https", side_effect=lambda url: Response(data)), \
                mock.patch.object(sv, "_present", return_value=self.present()), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1:8563"), \
                mock.patch.object(KitContext, "run_logged"), \
                mock.patch.object(sv, "system_present", return_value=False), \
                mock.patch.object(sv, "grant_mcp_login"):
            sv.install(self.ctx)                       # the real call: no framework recorded here, so it is skipped
        self.assertEqual("kit", self.manifest.get(f"{sv.RECEIPT}.ownership"))
        self.assertIn("Semantic SQL is not on yet", sv.summary(self.ctx))
        self.manifest.set_many({f"components.preprocessor.modules.{sv.ID}.version": 1,
                                "components.preprocessor.state": "active"})
        self.assertIn("Semantic SQL works in every session", sv.summary(self.ctx))
        # The user's own preprocessor took the slot (declined): the modules record stays, but nothing runs it.
        self.manifest.set_many({"components.preprocessor.declined": True,
                                "components.preprocessor.slot_holder": "MY.OWN"})
        self.assertEqual("semantic models in SEMANTIC_CATALOG; Semantic SQL is not on yet: it needs the kit's SQL "
                         "preprocessor framework active in this database", sv.summary(self.ctx))

    def test_removal_retires_the_module_before_it_drops_the_schemas_and_never_when_it_refuses(self):
        self.manifest.set_many({f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1",
                                f"{sv.RECEIPT}.role_created": False})
        order = []
        with mock.patch.object(sv.preprocessor_modules, "retire",
                               side_effect=lambda ctx, addon: order.append("retire") or ("ok", "")):
            with mock.patch.object(sv, "_present", return_value=self.present(sv.SCHEMAS, True, "0.6.1", 2)):
                with self.assertRaisesRegex(AddonFailure, "semantic model"):
                    sv.uninstall(self.ctx)
            sv.uninstall(self.ctx, dry_run=True)
            self.assertEqual([], order)                # models kept, or only a preview: the module stays
            with mock.patch.object(sv, "_present", return_value=self.present(sv.SCHEMAS, True, "0.6.1", 0)), \
                    mock.patch.object(sv, "_db", side_effect=lambda ctx, *s, timeout=120: order.append("drop")):
                sv.uninstall(self.ctx)
        self.assertEqual(["retire", "drop"], order)

    def test_a_retire_that_fails_stops_the_removal_and_says_how_to_retry(self):
        # PPX-06: the rule stays live when the retire fails, so the schemas it imports stay and the receipt too.
        self.manifest.set_many({f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1",
                                f"{sv.RECEIPT}.role_created": False,
                                f"components.preprocessor.modules.{sv.ID}.version": 1})
        failed = ("failed", "Semantic Views could not be retired from the SQL preprocessor framework: boom")
        with mock.patch.object(sv.preprocessor_modules, "retire", return_value=failed), \
                mock.patch.object(sv, "_present", return_value=self.present(sv.SCHEMAS, True, "0.6.1", 0)), \
                mock.patch.object(sv, "_db", side_effect=AssertionError("dropped")):
            with self.assertRaisesRegex(AddonFailure, "could not be retired .*: boom; nothing was removed. "
                                                      "Retry with: exakit uninstall semantic-views"):
                sv.uninstall(self.ctx)
        self.assertEqual("kit", self.manifest.get(f"{sv.RECEIPT}.ownership"))

    def test_nothing_the_kit_says_switches_the_preprocessor_per_session(self):
        help_text = (ROOT / "setup" / "help" / f"{sv.ID}.json").read_text(encoding="utf-8")
        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        for text in (help_text, sv.summary(self.ctx), agents):
            for token in ("ENABLE_SEMANTIC_SQL", "set_exasol_preprocessor", "list_exasol_preprocessors"):
                self.assertNotIn(token, text)
        self.assertNotRegex(help_text, r"(?i)sql_preprocessor_script\s*=")
        skill = (ROOT / "skills" / "exakit" / "SKILL.md").read_text(encoding="utf-8")
        never = skill[skill.index("- **Never switch the session's preprocessor.**"):]
        never = never[:never.index("\n- ")]
        outside = skill.replace(never, "")
        for token in ("ENABLE_SEMANTIC_SQL", "set_exasol_preprocessor", "sql_preprocessor_script"):
            self.assertIn(token, never)                # named only to say: never run it
            self.assertNotIn(token, outside)

    def test_register_and_retire_run_the_frameworks_mechanism_end_to_end(self):
        """The real module folder through marketplace/preprocessor_modules.py and setup/preprocessor/manage.py,
        against the simulated database (tests/lib/fake-exapump.py)."""
        if os.name == "nt":
            self.skipTest("the stand-in exapump is a shell script")
        import preprocessor_modules

        fake = Path(self.temp.name) / "exapump"
        fake.write_text(f"#!/bin/sh\nexec '{sys.executable}' '{ROOT / 'tests' / 'lib' / 'fake-exapump.py'}' \"$@\"\n")
        fake.chmod(0o755)
        state = Path(self.temp.name) / "db.json"
        scripts = ["PREPROC_RT.MASTER", "PREPROC.RULE_ENSURE", "PREPROC.RULE_DROP", "PREPROC.REFRESH",
                   "PREPROC.MODULE_REGISTER", "PREPROC.MODULE_RETIRE", "PREPROC.MODULE_RECLAIM"]
        state.write_text(json.dumps({"system_slot": "PREPROC_RT.MASTER", "schemas": ["PREPROC", "PREPROC_RT"],
                                     "role": True, "scripts": scripts}))
        self.manifest.set_many({"components.exapump.path": str(fake), "components.preprocessor.state": "active",
                                "components.preprocessor.version": "0.9.1",
                                f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1"})
        with mock.patch.dict(os.environ, {"FAKE_EXAPUMP_STATE": str(state)}):
            status, message = preprocessor_modules.register(self.ctx, sv.ID)
            db = json.loads(state.read_text())
            self.assertEqual("ok", status, message)
            self.assertIn("PREPROC_RT.SEMANTIC_VIEWS_V1 for role PUBLIC", message)
            self.assertEqual([("ROLE", "PUBLIC", "EXPAND", "PREPROC_RT.SEMANTIC_VIEWS_V1", "semantic_views")],
                             [(r["scope_type"], r["scope_value"], r["phase"], r["script"], r["function"])
                              for r in db["rules"]])
            self.assertTrue({"PREPROC_RT.SEMANTIC_VIEWS_V1", "PREPROC_RT.SEMANTIC_VIEWS_REFUSE_V1"} <= set(db["scripts"]))
            self.assertEqual([("semantic_views", 1, "deployed", "v0.6.1")],
                             [(m["name"], m["version"], m["status"], m["ref"]) for m in db["modules"]])
            self.assertTrue(sv.semantic_sql_active(self.ctx))
            status, _ = preprocessor_modules.retire(self.ctx, sv.ID)
            db = json.loads(state.read_text())
            self.assertEqual(("ok", [], []), (status, db["rules"], db["modules"]))
            self.assertNotIn("PREPROC_RT.SEMANTIC_VIEWS_V1", db["scripts"])
            self.assertFalse(sv.semantic_sql_active(self.ctx))
            self.manifest.set_many({"components.preprocessor.state": None, "components.preprocessor.declined": True,
                                    "components.preprocessor.slot_holder": "MY.OWN"})
            status, message = preprocessor_modules.register(self.ctx, sv.ID)
            self.assertEqual("skipped", status)
            self.assertIn("MY.OWN", message)

    def test_the_module_step_finds_the_kits_exapump_profile_without_the_shell(self):
        """The kit keeps the starter-kit profile in <home>/exapump/config.toml; a caller that did not export
        EXAPUMP_CONFIG (the shells do) still reaches it."""
        import preprocessor_modules

        config = self.home / "exapump" / "config.toml"
        config.parent.mkdir()
        config.write_text("[starter-kit]\n")
        seen = {}

        def run(argv, **kwargs):
            seen.update(kwargs["env"])
            return mock.Mock(returncode=5, stdout="INFO skipped\n", stderr="")

        with mock.patch.dict(os.environ, {}, clear=False), mock.patch.object(preprocessor_modules.subprocess, "run", side_effect=run):
            os.environ.pop("EXAPUMP_CONFIG", None)
            self.assertEqual(("skipped", "skipped"), preprocessor_modules.register(self.ctx, sv.ID))
        self.assertEqual(str(config), seen["EXAPUMP_CONFIG"])

    def test_a_database_error_never_shows_the_password(self):
        failed = mock.Mock(returncode=1, stdout="", stderr=f"pyexasol.ExaAuthError: login with {SECRET} refused")
        with mock.patch.object(sv.subprocess, "run", return_value=failed), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1:8563"):
            with self.assertRaises(AddonFailure) as caught:
                sv._db(self.ctx, "SELECT 1")
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertIn("***", str(caught.exception))

    # -- a Windows console: the installer's output is piped, not a console --------------------------------------

    def test_the_installer_prints_its_box_rule_under_a_cp1252_parent(self):
        """G (Windows 11 upgrade): v0.6.1's tools/install.py prints "\u2500" * 42; piped on Windows its stdout was
        cp1252 and the install ended in UnicodeEncodeError (exit 1). The installer now runs with PYTHONUTF8=1 and
        PYTHONIOENCODING=utf-8 whatever its parent says, and its output reaches the log intact."""
        release = self.home / "semantic-views" / "v0.6.1"
        (release / "tools").mkdir(parents=True)
        (release / "tools" / "install.py").write_text(
            "import os, sys\n"
            "print('env', os.environ.get('PYTHONUTF8'), os.environ.get('PYTHONIOENCODING'), sys.stdout.encoding)\n"
            "print('\\u2500' * 42)\n", encoding="utf-8")
        self.manifest.set_many({"components.pyexasol.python": sys.executable})
        windows_pipe = {"PYTHONIOENCODING": "cp1252", "PYTHONUTF8": "0"}          # what a piped cp1252 child gets
        with mock.patch.dict(os.environ, windows_pipe), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1/ABCDEF:8563"), \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            sv._run_installer(self.ctx, release)
        log = (self.home / "logs" / "marketplace.log").read_text(encoding="utf-8")
        self.assertIn("env 1 utf-8 utf-8", log)
        self.assertIn("\u2500" * 42, log)
        self.assertNotIn("UnicodeEncodeError", log)

    def test_the_database_step_reads_its_answer_as_utf8(self):
        seen = {}

        def run(argv, **kwargs):
            seen.update(kwargs)
            return mock.Mock(returncode=0, stdout="[1]", stderr="")

        with mock.patch.object(sv.subprocess, "run", side_effect=run), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1:8563"):
            self.assertEqual([1], sv._db(self.ctx, "SELECT 1"))
        self.assertEqual(("utf-8", "replace"), (seen["encoding"], seen["errors"]))
        self.assertEqual(("1", "utf-8"), (seen["env"]["PYTHONUTF8"], seen["env"]["PYTHONIOENCODING"]))


if __name__ == "__main__":
    unittest.main()
