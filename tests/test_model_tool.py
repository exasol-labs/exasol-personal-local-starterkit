"""setup/udf/model_tool.py - the rules behind `exakit model put | list`, shared by the shell and PowerShell modules
(run: python3 tests/test_model_tool.py). The commands around it: tests/model-commands.sh and its -ps twin."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "udf"))

import model_tool  # noqa: E402

ROOT_UDF = "/buckets/bfsdefault/default"


def run(*argv: str, stdin: str = "{}") -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err), mock.patch.object(sys, "stdin", io.StringIO(stdin)):
        code = model_tool.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class ModelToolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.bucket = self.dir / "bucket"
        self.model = self.dir / "churn.pkl"
        self.model.write_bytes(b"one")

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, source: Path, replace: str = "0", record: str = "{}"):
        return run("put", str(source), str(self.bucket), ROOT_UDF, replace, stdin=record)

    def test_put_answers_in_three_lines(self):
        code, out, err = self.put(self.model)
        self.assertEqual((code, err), (0, ""))
        action, answer, record = out.splitlines()
        self.assertEqual(action, "copied")
        self.assertEqual(json.loads(answer), {"name": "churn.pkl", "path": f"{ROOT_UDF}/models/churn.pkl",
                                              "sha256": model_tool.digest(self.model)[0], "size": 3, "replaced": False,
                                              "trusted_origin": False,
                                              "warning": "Only load pickle or joblib models from a source you trust."})
        self.assertEqual(sorted(json.loads(record)["churn.pkl"]), ["path", "provenance", "put_at", "sha256", "size"])
        self.assertEqual((self.bucket / "models" / "churn.pkl").read_bytes(), b"one")

    def test_other_records_are_kept(self):
        _, out, _ = self.put(self.model, record='{"other.onnx": {"sha256": "ab"}}')
        self.assertIn("other.onnx", json.loads(out.splitlines()[2]))

    def test_a_different_file_needs_replace_and_exits_5(self):
        self.put(self.model)
        changed = self.dir / "v2"
        changed.mkdir()
        (changed / "churn.pkl").write_bytes(b"two")
        code, out, err = self.put(changed / "churn.pkl")
        self.assertEqual((code, out), (5, ""))
        self.assertIn("--replace", err)
        self.assertEqual((self.bucket / "models" / "churn.pkl").read_bytes(), b"one")
        code, out, _ = self.put(changed / "churn.pkl", replace="1")
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines()[0], "replaced")
        self.assertTrue(json.loads(out.splitlines()[1])["replaced"])

    def test_the_same_file_is_unchanged_and_keeps_its_time(self):
        _, out, _ = self.put(self.model)
        record = out.splitlines()[2]
        _, again, _ = self.put(self.model, record=record)
        self.assertEqual(again.splitlines()[0], "unchanged")
        self.assertEqual(json.loads(again.splitlines()[2])["churn.pkl"]["put_at"], json.loads(record)["churn.pkl"]["put_at"])

    def test_names_a_bucket_path_cannot_hold_are_refused(self):
        for name in ("my model.pkl", "-x.pkl", "a'b.pkl", "m.pkl.part", "modèle.pkl"):
            with self.subTest(name=name):
                bad = self.dir / name
                bad.write_bytes(b"x")
                code, _, err = self.put(bad)
                self.assertEqual(code, 2)
                self.assertIn("cannot be a model name", err)
        self.assertEqual(self.put(self.dir / "absent.pkl")[0], 2)

    def test_list_flags_changes_and_ignores_copies_in_progress(self):
        _, out, _ = self.put(self.model)
        record = out.splitlines()[2]
        (self.bucket / "models" / "half.pkl.part").write_bytes(b"x")
        (self.bucket / "models" / "churn.pkl").write_bytes(b"tampered")
        code, out, _ = run("list", str(self.bucket), ROOT_UDF + "/", stdin=record)
        doc = json.loads(out)
        self.assertEqual(code, 0)
        self.assertEqual(doc["udf_root"], ROOT_UDF)
        self.assertEqual([(m["name"], m["status"]) for m in doc["models"]], [("churn.pkl", "changed")])
        self.assertEqual(doc["missing"], [])

    def test_list_of_nothing_is_an_empty_list(self):
        code, out, _ = run("list", str(self.dir / "no-bucket-yet"), ROOT_UDF, stdin="not json")
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["models"], [])

    def test_unknown_usage_exits_2(self):
        self.assertEqual(run("frob")[0], 2)
        self.assertEqual(run("put", "x")[0], 2)

    def test_matching_provenance_and_remove(self):
        sidecar = Path(str(self.model) + ".provenance.json")
        sidecar.write_text(json.dumps({"sha256": model_tool.digest(self.model)[0], "python": "3.12", "scikit-learn": "1.9.0"}))
        _, out, _ = self.put(self.model)
        self.assertTrue(json.loads(out.splitlines()[1])["trusted_origin"])
        record = out.splitlines()[2]
        code, out, err = run("rm", "churn.pkl", str(self.bucket), ROOT_UDF, stdin=record)
        self.assertEqual((code, err), (0, ""))
        self.assertFalse((self.bucket / "models" / "churn.pkl").exists())
        self.assertEqual(json.loads(out.splitlines()[1]), {})

    def test_size_limit_before_copy(self):
        with mock.patch.object(model_tool, "MAX_MODEL_BYTES", 2):
            code, _, err = self.put(self.model)
        self.assertEqual(code, 6)
        self.assertIn("500 MB", err)
        self.assertFalse((self.bucket / "models" / "churn.pkl").exists())


if __name__ == "__main__":
    unittest.main()
