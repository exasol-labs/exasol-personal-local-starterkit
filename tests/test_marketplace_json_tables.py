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


class AssetSourceTest(unittest.TestCase):
    """The engine comes from the kit's repository, through the API with a token when that repository is private, and
    else from the public kit repository's copy of the same release - only with a pinned checksum."""

    PRIVATE = "ranjanm-chn/exasol-personal-local-starterkit-backup"

    def _fetch(self, token: str | None, digest: str | None):
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
            if request.full_url.startswith(f"https://github.com/{self.PRIVATE}/"):
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

    def test_a_private_repository_is_read_through_the_api_with_the_token(self):
        seen, error = self._fetch("t0k", "real")
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
