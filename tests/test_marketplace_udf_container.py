"""Container selection and digest checks before a UDF database restart."""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from runtime import AddonFailure, KitContext, Manifest  # noqa: E402
from udf_container import fetch, rust_smoke, select, verify  # noqa: E402


class ContainerAssetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.home = self.base / "kit home"
        self.home.mkdir()
        self.mirror = self.base / "mirror"
        self.mirror.mkdir()
        self.blob = self.mirror / "container.tar.gz"
        self.blob.write_bytes(b"verified test container")
        self.asset = {"url": "https://example.invalid/container.tar.gz", "size": self.blob.stat().st_size,
                      "sha256": hashlib.sha256(self.blob.read_bytes()).hexdigest()}
        self.store = Manifest(self.home / "manifest.json")
        self.store.path.write_text(json.dumps({}))
        self.ctx = KitContext(ROOT, self.home, self.home / "bin", self.store, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_valid_mirror_is_cached_and_reverified(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_UDF_CONTAINERS_MIRROR": str(self.mirror)}):
            cached = fetch(self.ctx, self.asset)
            self.assertEqual(self.blob.read_bytes(), cached.read_bytes())
            self.assertEqual(cached, fetch(self.ctx, self.asset))
            cached.write_bytes(b"corrupt")
            self.assertEqual(self.blob.read_bytes(), fetch(self.ctx, self.asset).read_bytes())

    def test_bad_digest_never_enters_cache(self) -> None:
        bad = {**self.asset, "sha256": "0" * 64}
        with patch.dict(os.environ, {"EXAKIT_UDF_CONTAINERS_MIRROR": str(self.mirror)}):
            with self.assertRaisesRegex(AddonFailure, "SHA-256"):
                fetch(self.ctx, bad)
        self.assertFalse((self.home / "cache/containers/container.tar.gz").exists())

    def test_invalid_mirror_protocol_and_pin_refused(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_UDF_CONTAINERS_MIRROR": "http://untrusted"}):
            with self.assertRaisesRegex(AddonFailure, "MIRROR"):
                fetch(self.ctx, self.asset)
        with patch.dict(os.environ, {"EXAKIT_UDF_CONTAINERS_MIRROR": "https://user:secret@example.invalid"}):
            with self.assertRaisesRegex(AddonFailure, "plain HTTPS"):
                fetch(self.ctx, self.asset)
        with self.assertRaisesRegex(AddonFailure, "SHA-256 pin"):
            verify(self.blob, {**self.asset, "sha256": "placeholder"})

    def test_release_matrix_selects_language_arch_and_database(self) -> None:
        versions = json.loads((ROOT / "versions.json").read_text())
        rows = versions["components"]["udf-devkit"]["containers"]
        version = "2026.2.0"
        for row in rows:
            if row["language"] != "python":
                continue
            try:
                selected = select(self.ctx, row["language"], row["arch"], version)
            except AddonFailure:
                continue
            self.assertEqual(row["sha256"], selected["sha256"])
            break
        else:
            self.fail("No Python container row matched the test database version")

    def test_bundled_rust_smoke_has_no_release_url(self) -> None:
        root = self.base / "release"
        asset_path = root / "udf/rust-smoke/prebuilt/libexakit_smoke.so"
        asset_path.parent.mkdir(parents=True)
        asset_path.write_bytes(b"bundled smoke library")
        asset = {"url": None, "bundled_path": "udf/rust-smoke/prebuilt/libexakit_smoke.so",
                 "size": asset_path.stat().st_size,
                 "sha256": hashlib.sha256(asset_path.read_bytes()).hexdigest()}
        ctx = KitContext(root, self.home, self.home / "bin", self.store, Path("uv"))
        self.assertEqual(asset_path, rust_smoke(ctx, {"smoke_asset": asset}))


if __name__ == "__main__":
    unittest.main()
