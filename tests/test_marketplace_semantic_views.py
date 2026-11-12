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

    # -- removal ----------------------------------------------------------------------------------------------------

    def test_removal_never_deletes_a_model_and_drops_only_what_the_kit_made(self):
        self.manifest.set_many({f"{sv.RECEIPT}.ownership": "kit", f"{sv.RECEIPT}.version": "v0.6.1",
                                f"{sv.RECEIPT}.role_created": False})
        (self.home / "semantic-views" / "v0.6.1").mkdir(parents=True)
        self.assertEqual([self.home / "semantic-views"], sv.uninstall(self.ctx, dry_run=True))
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

    def test_a_database_error_never_shows_the_password(self):
        failed = mock.Mock(returncode=1, stdout="", stderr=f"pyexasol.ExaAuthError: login with {SECRET} refused")
        with mock.patch.object(sv.subprocess, "run", return_value=failed), \
                mock.patch.object(KitContext, "client_dsn", return_value="127.0.0.1:8563"):
            with self.assertRaises(AddonFailure) as caught:
                sv._db(self.ctx, "SELECT 1")
        self.assertNotIn(SECRET, str(caught.exception))
        self.assertIn("***", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
