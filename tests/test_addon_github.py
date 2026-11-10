"""tools/addon_github.py writes each add-on's GitHub block from what GitHub answers - never typed by hand."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import addon_github  # noqa: E402


def answer(**overrides) -> dict:
    doc = {"full_name": "exasol-labs/dash-server", "name": "dash-server",
           "html_url": "https://github.com/exasol-labs/dash-server", "archived": False,
           "description": "Agent-operated Dash hosting for live analytical apps"}
    doc.update(overrides)
    return doc


class LiveBlockTest(unittest.TestCase):
    def test_the_block_is_what_github_says(self) -> None:
        with patch.object(addon_github, "fetch", return_value=answer()):
            self.assertEqual({"repo": "exasol-labs/dash-server", "url": "https://github.com/exasol-labs/dash-server",
                              "name": "dash-server", "about": "Agent-operated Dash hosting for live analytical apps"},
                             addon_github.live_block("exasol-labs/dash-server"))

    def test_a_renamed_repository_is_followed(self) -> None:
        moved = answer(full_name="exasol/dash", name="dash", html_url="https://github.com/exasol/dash")
        with patch.object(addon_github, "fetch", return_value=moved):
            self.assertEqual("exasol/dash", addon_github.live_block("exasol-labs/dash-server")["repo"])

    def test_an_about_is_one_clean_line(self) -> None:
        with patch.object(addon_github, "fetch", return_value=answer(description="Live\x1b[31m red\n\tdash  ")):
            self.assertEqual("Live red dash", addon_github.live_block("exasol-labs/dash-server")["about"])

    def test_what_cannot_be_the_source_is_refused(self) -> None:
        for reason, doc in (("archived", answer(archived=True)), ("no About", answer(description="")),
                            ("no usable name", answer(html_url="https://evil.example/x"))):
            with self.subTest(reason), patch.object(addon_github, "fetch", return_value=doc), \
                    self.assertRaisesRegex(ValueError, reason):
                addon_github.live_block("exasol-labs/dash-server")


class RenderTest(unittest.TestCase):
    def test_the_shipped_catalog_is_one_add_on_per_line(self) -> None:
        # The shell reads an add-on's line with sed when it has no Python: rendering must not move a field.
        text = (ROOT / "marketplace/catalog.json").read_text(encoding="utf-8")
        self.assertEqual(text, addon_github.render(json.loads(text)))
        for row in json.loads(text)["addons"]:
            line = next(line for line in text.splitlines() if f'{{"id": "{row["id"]}",' in line)
            self.assertIn(f'"repo": "{row["github"]["repo"]}"', line)


if __name__ == "__main__":
    unittest.main()
