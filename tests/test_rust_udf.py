import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "setup/udf/rust_udf_tool.py"
spec = importlib.util.spec_from_file_location("rust_udf_tool", SOURCE)
rust = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = rust
spec.loader.exec_module(rust)


class RustUdfTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = patch.dict(os.environ, {"EXAKIT_HOME": self.temp.name}, clear=False)
        env.start()
        self.addCleanup(env.stop)

    def test_scaffold_pins_sdk_and_scores_coefficients(self):
        source = Path(self.temp.name) / "coefficients.json"
        source.write_text(json.dumps({"features": ["DATE_YEAR", "CAT_A"], "coef": [[0.5, -1.25]],
                                      "intercept": [2.0], "classes": [0, 1], "positive_class": 1}))
        result = rust.create("score_model", str(source))
        project = Path(result["project"])
        self.assertIn('exasol-udf-sdk = "=0.33.0"', (project / "Cargo.toml").read_text())
        code = (project / "src/lib.rs").read_text()
        self.assertIn("ctx.get_f64(index)?", code)
        self.assertIn("[0.5, -1.25]", code)
        self.assertEqual(json.loads((project / "exakit-rust.json").read_text())["features"], ["DATE_YEAR", "CAT_A"])
        with self.assertRaisesRegex(rust.Refused, "already exists"):
            rust.create("score_model", str(source))

    def test_bad_coefficient_shape_refused(self):
        source = Path(self.temp.name) / "bad.json"
        source.write_text(json.dumps({"features": ["A"], "coef": [[0.1, 0.2]],
                                      "intercept": [0], "classes": [0, 1]}))
        with self.assertRaisesRegex(rust.Refused, "matching feature"):
            rust.create("score_model", str(source))
        self.assertFalse(rust.project_path("score_model").exists())

    def test_sql_names_match_entry_point_and_bucket(self):
        sql = rust.create_sql("score_model", "SCORING", ["DATE_YEAR", "CAT_A"],
                              "/buckets/bfsdefault/default/udf/libscore_model.so")
        self.assertIn("RUST SCALAR SCRIPT SCORING.SCORE_MODEL", sql)
        self.assertIn('"DATE_YEAR" DOUBLE', sql)
        self.assertIn("%udf_object /buckets/bfsdefault/default/udf/libscore_model.so", sql)

    def test_changed_artifact_never_deploys(self):
        result = rust.create("score_model", None)
        project = Path(result["project"])
        artifact = project / "target/release/libscore_model.so"
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"changed")
        (project / "build.json").write_text(json.dumps({"artifact": str(artifact), "sha256": "0" * 64,
                                                       "arch": rust.architecture(), "sdk": rust.SDK, "rustc": rust.RUSTC}))
        with self.assertRaisesRegex(rust.Refused, "changed"):
            rust.deploy("score_model", "SCORING")

    def test_mac_build_uses_matching_linux_image_and_cached_cargo(self):
        result = rust.create("score_model", None)
        project = Path(result["project"])
        artifact = project / "target/release/libscore_model.so"
        seen = []

        def built(args, *, cwd=None):
            seen.extend(args)
            artifact.parent.mkdir(parents=True)
            artifact.write_bytes(b"ELF fixture")

        with patch.object(rust.platform, "system", return_value="Darwin"), \
                patch.object(rust, "architecture", return_value="aarch64"), \
                patch.object(rust, "container_runtime", return_value="docker"), \
                patch.object(rust, "_run", side_effect=built):
            record = rust.build("score_model")
        self.assertEqual(record["arch"], "aarch64")
        self.assertIn("linux/arm64", seen)
        self.assertIn("exakit-rust-cargo-aarch64:/cargo-home", seen)
        self.assertIn(rust.IMAGE, seen)


if __name__ == "__main__":
    unittest.main()
