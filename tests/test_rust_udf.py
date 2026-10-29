import importlib.util
import contextlib
import io
import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from unittest.mock import MagicMock

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
        self.assertTrue(rust.create("score_model", str(source))["reused"])
        source.write_text(source.read_text().replace("0.5", "0.6"))
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
            (project / "Cargo.lock").write_text("# pinned fixture\n")

        with patch.object(rust.platform, "system", return_value="Darwin"), \
                patch.object(rust, "architecture", return_value="aarch64"), \
                patch.object(rust, "container_runtime", return_value="docker"), \
                patch.object(rust, "_run", side_effect=built):
            record = rust.build("score_model")
        self.assertEqual(record["arch"], "aarch64")
        self.assertIn("linux/arm64", seen)
        self.assertIn("exakit-rust-cargo-aarch64:/cargo-home", seen)
        self.assertIn(rust.IMAGE, seen)
        self.assertEqual(len(record["cargo_lock_sha256"]), 64)

    def test_deploy_requires_validated_rust_container(self):
        result = rust.create("score_model", None)
        project = Path(result["project"])
        artifact = project / "target/release/libscore_model.so"
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"ELF fixture")
        lock = project / "Cargo.lock"
        lock.write_text("# pinned fixture\n")
        row = rust.rust_pins(rust.architecture())
        (project / "build.json").write_text(json.dumps({"artifact": str(artifact),
            "sha256": __import__("hashlib").sha256(artifact.read_bytes()).hexdigest(),
            "arch": rust.architecture(), "sdk": row["crates"]["exasol-udf-sdk"],
            "rustc": row["runtime"]["rustc"],
            "cargo_lock_sha256": __import__("hashlib").sha256(lock.read_bytes()).hexdigest(),
            "container_sha256": row["sha256"]}))
        with self.assertRaisesRegex(rust.Refused, "validated RUST container"):
            rust.deploy("score_model", "SCORING")

    def test_cli_bad_arguments_keep_json_contract(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = rust.main(["deploy", "--json"])
        self.assertEqual(code, 2)
        answer = json.loads(output.getvalue())
        self.assertFalse(answer["ok"])
        self.assertEqual(answer["step"], "deploy")
        self.assertEqual(answer["language"], "rust")
        self.assertEqual(answer["reason"], answer["error"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = rust.main(["new", "missing_model", "--coefficients",
                              str(Path(self.temp.name) / "missing.json"), "--json"])
        self.assertEqual(code, 2)
        self.assertIn("Cannot read the coefficients file", json.loads(output.getvalue())["reason"])

    def validated_project(self):
        project = Path(rust.create("score_model", None)["project"])
        artifact = project / "target/release/libscore_model.so"
        artifact.parent.mkdir(parents=True)
        artifact.write_bytes(b"validated ELF fixture")
        lock = project / "Cargo.lock"
        lock.write_text("# pinned fixture\n")
        row = rust.rust_pins(rust.architecture())
        (project / "build.json").write_text(json.dumps({"artifact": str(artifact),
            "sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(), "arch": rust.architecture(),
            "sdk": row["crates"]["exasol-udf-sdk"], "rustc": row["runtime"]["rustc"],
            "cargo_lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(), "container_sha256": row["sha256"]}))
        return project

    def test_bucketless_deploy_requires_restart_consent_before_mutation(self):
        self.validated_project()
        with patch.dict(os.environ, {"EXAKIT_RUST_BUCKET_DIR": "", "EXAKIT_RUST_UDF_ROOT": ""}), \
                patch.object(rust, "rust_installed"), patch.object(rust, "_connect") as connect:
            with self.assertRaises(rust.Refused) as caught:
                rust.deploy("score_model", "SCORING")
        self.assertEqual(caught.exception.code, 5)
        self.assertEqual(caught.exception.step, "confirm")
        self.assertIn("restarts the database", str(caught.exception))
        self.assertIn("--yes", caught.exception.remedy)
        connect.assert_not_called()

    def test_bucketless_deploy_packages_before_reconnecting_and_creating_sql(self):
        self.validated_project()
        connection = MagicMock()
        connection.execute.return_value.fetchall.return_value = [("8.39.0",)]
        with patch.dict(os.environ, {"EXAKIT_RUST_BUCKET_DIR": "", "EXAKIT_RUST_UDF_ROOT": ""}), \
                patch.object(rust, "rust_installed"), patch.object(rust, "_connect", return_value=connection), \
                patch.object(rust, "install_container_library", return_value={"container_sha256": "a"*64}) as install:
            answer = rust.deploy("score_model", "SCORING", yes=True)
        install.assert_called_once()
        sql = "\n".join(str(call.args[0]) for call in connection.execute.call_args_list)
        self.assertIn("%udf_object /opt/exakit/udf/libscore_model.so", sql)
        self.assertEqual(answer["deployment"], "container")
        self.assertTrue(answer["database_restart_requested"])

    def test_invalid_schema_never_restarts_database(self):
        self.validated_project()
        with patch.object(rust, "rust_installed"), patch.object(rust, "_connect") as connect:
            with self.assertRaisesRegex(rust.Refused, "Schema"):
                rust.deploy("score_model", "bad;drop", yes=True)
        connect.assert_not_called()

    def test_host_bucket_that_is_invisible_to_a_udf_uses_fallback(self):
        self.validated_project()
        import rust_container
        bucket = Path(self.temp.name) / "bucket"; bucket.mkdir()
        with patch.dict(os.environ, {"EXAKIT_RUST_BUCKET_DIR": str(bucket), "EXAKIT_RUST_UDF_ROOT": "/buckets/bfs/default"}), \
                patch.object(rust, "rust_installed"), patch.object(rust, "_connect", return_value=MagicMock()), \
                patch.object(rust_container, "bucket_visible", return_value=False), \
                patch.object(rust, "install_container_library", return_value={"container_sha256": "a"*64}) as install:
            result = rust.deploy("score_model", "SCORING", yes=True)
        install.assert_called_once()
        self.assertEqual(result["deployment"], "container")

    def test_matching_packaged_library_can_be_reused_without_restart_consent(self):
        self.validated_project()
        import rust_container
        with patch.dict(os.environ, {"EXAKIT_RUST_BUCKET_DIR": "", "EXAKIT_RUST_UDF_ROOT": ""}), \
                patch.object(rust, "rust_installed"), patch.object(rust, "_connect", return_value=MagicMock()), \
                patch.object(rust_container, "installed_library", return_value={"container_sha256": "a"*64}), \
                patch.object(rust, "install_container_library") as install:
            result = rust.deploy("score_model", "SCORING")
        install.assert_not_called()
        self.assertFalse(result["database_restart_requested"])
        self.assertEqual(result["container_sha256"], "a"*64)

    def test_driver_failures_keep_private_details_out_of_json(self):
        output = io.StringIO()
        with patch.object(rust, "deploy", side_effect=RuntimeError("password=private-value")), \
                contextlib.redirect_stdout(output):
            code = rust.main(["deploy", "score_model", "--json"])
        self.assertEqual(code, 6)
        self.assertNotIn("private-value", output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["remedy"], "exakit status")


if __name__ == "__main__":
    unittest.main()
