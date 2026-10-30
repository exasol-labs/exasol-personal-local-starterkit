"""JSON Tables release selection and launcher behavior."""

from __future__ import annotations

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


if __name__ == "__main__":
    unittest.main()
