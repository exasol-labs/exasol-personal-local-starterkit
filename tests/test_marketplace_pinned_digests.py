"""Download digests come from the kit copy's own versions.json, never the fetched document (SEC-13).

The versions document fetched from the main branch says what is newest; a SHA-256 read from it would be that
mutable branch vouching for itself. KitContext.pinned_document() is the kit copy's versions.json, and the add-ons
that verify a download read their digest from it.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
from addons import exasol_scheduler, exasol_vscode  # noqa: E402
from runtime import KitContext, Manifest  # noqa: E402

BUNDLED = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"]


class PinnedDigestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        fetched = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
        for block in fetched["components"].values():           # every digest in the fetched copy is someone else's
            if isinstance(block, dict) and isinstance(block.get("sha256"), dict):
                block["sha256"] = {key: "f" * 64 for key in block["sha256"]}
        self.fetched = base / "fetched-versions.json"
        self.fetched.write_text(json.dumps(fetched), encoding="utf-8")
        (base / "kit").mkdir()
        manifest = Manifest(base / "kit" / "manifest.json")
        manifest.path.write_text("{}")
        self.ctx = KitContext(ROOT, base / "kit", base / "bin", manifest, Path("uv"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_the_fetched_document_is_still_what_is_advertised(self) -> None:
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_VERSIONS_DOC": str(self.fetched)}):
            block = self.ctx.versions_document()["components"]["exasol-scheduler"]
        self.assertEqual(set(block["sha256"].values()), {"f" * 64})

    def test_the_scheduler_verifies_against_the_kit_copys_pin(self) -> None:
        version = BUNDLED["exasol-scheduler"]["version"].removeprefix("v")
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_VERSIONS_DOC": str(self.fetched)}), \
                patch.object(exasol_scheduler, "_platform", return_value="linux-x86_64"):
            digest = exasol_scheduler._digest(self.ctx, version, "exasol-labs/exasol-scheduler", f"v{version}", "x")
        self.assertEqual(digest, BUNDLED["exasol-scheduler"]["sha256"]["linux-x86_64"])

    def test_the_vscode_extension_verifies_against_the_kit_copys_pin(self) -> None:
        block = BUNDLED.get("exasol-vscode", {})
        if not isinstance(block.get("sha256"), dict) or "vsix" not in block["sha256"]:
            self.skipTest("this kit copy pins no VS Code extension digest")
        with patch.dict(os.environ, {"EXAKIT_MARKETPLACE_VERSIONS_DOC": str(self.fetched)}):
            self.assertEqual(exasol_vscode.expected_digest(self.ctx, block["version"], "x.vsix"), block["sha256"]["vsix"])


if __name__ == "__main__":
    unittest.main()
