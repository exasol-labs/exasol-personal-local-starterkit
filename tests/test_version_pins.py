"""Sprint 1 #6: the release pins the plan names stay where the kit reads them, and stay consistent with each other.

Launcher 2.3.0 and the UDF add-on's refusal of an older one; notebook-connector 3.1.x; Langfuse SDK 5; one MLflow 3
range for the client, exasol-mlflow and the pinned server; one language-container-rs release with its rustc, the
same in every Rust row, in the Rust tool's constants and in its build image.
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "marketplace"))
sys.path.insert(0, str(ROOT / "setup" / "udf"))

import mlflow_cli  # noqa: E402
import udf_tool  # noqa: E402
from addons import notebook, udf_devkit  # noqa: E402

VERSIONS = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))["components"]
CATALOG = {row["id"]: row for row in json.loads((ROOT / "marketplace/catalog.json").read_text(encoding="utf-8"))["addons"]}


def _companion(name: str) -> str:
    rows = [spec for spec in notebook.COMPANIONS if re.match(re.escape(name) + r"[<>=!~ ]", spec)]
    assert len(rows) == 1, f"{name} is in COMPANIONS {len(rows)} times"
    return rows[0]


class LauncherPinTest(unittest.TestCase):
    def test_launcher_pin_and_the_udf_floor(self):
        pinned = VERSIONS["personal"]["version"]
        self.assertRegex(pinned, r"^\d+\.\d+\.\d+$")
        self.assertEqual("2.3.0", udf_devkit.LAUNCHER_FLOOR)
        self.assertTrue(udf_tool.at_least(pinned, udf_devkit.LAUNCHER_FLOOR),
                        f"the pinned launcher {pinned} would be refused by the UDF floor {udf_devkit.LAUNCHER_FLOOR}")
        self.assertFalse(udf_tool.at_least("2.2.9", udf_devkit.LAUNCHER_FLOOR))


class NotebookPinTest(unittest.TestCase):
    def test_notebook_connector_is_3_1(self):
        pinned = VERSIONS["notebook"]["version"]
        self.assertEqual("exasol-notebook-connector", VERSIONS["notebook"]["package"])
        self.assertRegex(pinned, r"^3\.1\.\d+$")
        self.assertEqual(pinned, CATALOG["notebook"]["default_version"], "the offline fallback follows versions.json")

    def test_langfuse_sdk_5(self):
        self.assertEqual("langfuse>=5,<6", _companion("langfuse"))


class MlflowPinTest(unittest.TestCase):
    def test_one_mlflow_3_range_for_client_package_and_server(self):
        self.assertEqual(3, mlflow_cli.MLFLOW_MAJOR)
        self.assertEqual("mlflow-skinny>=3,<4", _companion("mlflow-skinny"))
        project = (ROOT / "packages/exasol-mlflow/pyproject.toml").read_text(encoding="utf-8")
        self.assertIn('"mlflow-skinny>=3,<4"', project)
        self.assertIn('"mlflow>=3,<4"', project)
        server = VERSIONS["udf-devkit"]["mlflow_server"]
        self.assertRegex(server, r"^3\.\d+\.\d+$", "the exact server pin sits inside the client's 3.x range")


class RustPinTest(unittest.TestCase):
    def test_one_language_container_rs_release_with_its_rustc(self):
        rows = [row for row in VERSIONS["udf-devkit"]["containers"] if row.get("language") == "rust"]
        self.assertEqual({"x86_64", "aarch64"}, {row["arch"] for row in rows})
        sdks = {row["crates"]["exasol-udf-sdk"] for row in rows}
        rustcs = {row["runtime"]["rustc"] for row in rows}
        self.assertEqual(1, len(sdks), f"one language-container-rs release, not {sorted(sdks)}")
        self.assertEqual(1, len(rustcs), f"one rustc, not {sorted(rustcs)}")
        sdk, rustc = sdks.pop(), rustcs.pop()
        for row in rows:
            with self.subTest(arch=row["arch"]):
                self.assertIn(f"/language-container-rs/releases/download/v{sdk}/lc-rust-{sdk}", row["url"])
                self.assertRegex(row.get("sha256", ""), r"^[0-9a-f]{64}$")
                self.assertIn(f"rust:{rustc}-", row["smoke_asset"]["note"])
                self.assertIn(f"cargo-exasol-udf {sdk}", row["smoke_asset"]["note"])
        import importlib.util
        spec = importlib.util.spec_from_file_location("rust_udf_tool_pins", ROOT / "setup/udf/rust_udf_tool.py")
        tool = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(tool)
        self.assertEqual((sdk, rustc), (tool.SDK, tool.RUSTC), "rust_udf_tool's constants follow versions.json")
        self.assertEqual(f"docker.io/library/rust:{rustc}-trixie", tool.IMAGE, "the build image carries the pinned rustc")


if __name__ == "__main__":
    unittest.main()
