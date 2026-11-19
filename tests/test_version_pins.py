"""Sprint 1 #6: the release pins the plan names stay where the kit reads them, and stay consistent with each other:
one exasol-mcp-server version for the stdio server and the launcher sidecar, and one pyexasol floor.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

VERSIONS = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"]


class LauncherPinTest(unittest.TestCase):
    def test_launcher_pin_is_a_release_version(self):
        self.assertRegex(VERSIONS["personal"]["version"], r"^\d+\.\d+\.\d+$")


class McpPinTest(unittest.TestCase):
    """One exasol-mcp-server version for the kit's stdio server and the launcher sidecar it runs on 2.4.0+, so
    `exakit version` (which reads the sidecar's version from its image tag) says what actually answers."""

    def test_the_sidecar_image_is_the_pinned_version_by_digest(self):
        mcp = VERSIONS["mcp"]
        image = mcp["sidecar_image"]
        self.assertRegex(image, r"^docker\.io/exasol/mcp-server:[0-9][^@]*@sha256:[0-9a-f]{64}$")
        self.assertEqual(image.split("@")[0].rsplit(":", 1)[1], mcp["version"])

    def test_every_fallback_is_the_same_version(self):
        version = VERSIONS["mcp"]["version"]
        image = VERSIONS["mcp"]["sidecar_image"]
        sources = {
            "setup/lib/common.sh": f'EXAKIT_MCP_VERSION_FALLBACK="${{EXAKIT_MCP_VERSION_FALLBACK:-{version}}}"',
            "setup/lib/exakit-common.ps1": f'else {{ "{version}" }}',
            "mcp/runtime/exakit.py": f'DEFAULT_MCP_VERSION = "{version}"',
            "setup/lib/mcp.sh": f'EXAKIT_MCP_SIDECAR_IMAGE_FALLBACK="{image}"',
            "setup/lib/mcp.ps1": f'$script:McpSidecarImageFallback = "{image}"',
        }
        for path, needle in sources.items():
            with self.subTest(path=path):
                self.assertIn(needle, (ROOT / path).read_text(encoding="utf-8"))


class PyexasolPinTest(unittest.TestCase):
    """The kit's own pyexasol defaults to versions.json's pin, at or above the floor."""

    def test_the_kit_default_and_one_floor_in_both_installers(self):
        shell = re.search(r'^_pyx_min_version="([^"]+)"', (ROOT / "setup/lib/pyexasol.sh").read_text(encoding="utf-8"), re.M)
        windows = re.search(r'^\$script:PyexasolMinVersion = "([^"]+)"',
                            (ROOT / "setup/lib/pyexasol.ps1").read_text(encoding="utf-8"), re.M)
        self.assertEqual(shell.group(1), windows.group(1))
        pinned = tuple(int(part) for part in VERSIONS["pyexasol"]["version"].split("."))
        self.assertGreaterEqual(pinned, tuple(int(part) for part in shell.group(1).split(".")),
                                "versions.json pins a pyexasol below the floor Exasol Personal needs")


if __name__ == "__main__":
    unittest.main()
