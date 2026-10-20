"""setup/udf/udf_tool.py - the UDF dev kit's rules, shared by the shell and PowerShell modules (run:
python3 tests/test_udf_tool.py). No database: the smoke UDF is checked as the SQL it sends."""

from __future__ import annotations

import io
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "setup" / "udf"))

import udf_tool  # noqa: E402


def run(*argv: str, stdin: str = "") -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err), mock.patch.object(sys, "stdin", io.StringIO(stdin)):
        code = udf_tool.main(list(argv))
    return code, out.getvalue(), err.getvalue()


class RulesTest(unittest.TestCase):
    def test_the_launcher_must_be_new_enough(self):
        self.assertEqual(run("atleast", "2.3.0", "2.3.0")[0], 0)
        self.assertEqual(run("atleast", "v2.4.1", "2.3.0")[0], 0)
        self.assertEqual(run("atleast", "2.2.9", "2.3.0")[0], 1)
        self.assertEqual(run("atleast", "0", "2.3.0")[0], 1)

    def test_only_exact_pins_build_a_container(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = Path(tmp, "ok.txt")
            good.write_text("# models\nnumpy==1.26.4\npandas==2.2.2  # comment\n")
            self.assertEqual(run("pinned", str(good))[:2], (0, "numpy==1.26.4\npandas==2.2.2\n"))
            for text, reason in (("numpy>=1\n", "not pinned"), ("-r other.txt\n", "options, URLs and paths"),
                                 ("https://x/y.whl\n", "options, URLs and paths"), ("\n# nothing\n", "names no package")):
                with self.subTest(text=text):
                    bad = Path(tmp, "bad.txt")
                    bad.write_text(text)
                    code, _, err = run("pinned", str(bad))
                    self.assertEqual(code, 2)
                    self.assertIn(reason, err)

    def test_a_bucket_path_never_leaves_the_bucket(self):
        self.assertEqual(run("relative", "models/model.pkl")[1], "models/model.pkl\n")
        self.assertEqual(run("relative", "/models\\\\m.pkl")[1], "models/m.pkl\n")
        for bad in ("../x", "a/../../x", "C:/x", ""):
            with self.subTest(path=bad):
                self.assertEqual(run("relative", bad)[0], 2)

    def test_the_installed_aliases_come_from_the_launchers_list(self):
        listing = 'WARN noise\n[{"alias": "PYTHON3", "installed": true}, {"aliases": ["PYTHON3_ML", "ML"], "installed": true},' \
                  ' {"alias": "R", "installed": false}]'
        self.assertEqual(run("aliases", stdin=listing)[1].split(), ["PYTHON3", "PYTHON3_ML", "ML"])
        self.assertEqual(run("aliases", stdin="not json")[0], 2)

    def test_names_are_plain_sql_names(self):
        self.assertEqual(run("identifier", "python3_custom")[1], "PYTHON3_CUSTOM\n")
        for bad in ("a;b", "1abc", "", "x y"):
            with self.subTest(name=bad):
                self.assertEqual(run("identifier", bad)[0], 2)

    def test_the_smoke_udf_reports_python_and_every_package(self):
        script = udf_tool.smoke_script("PYTHON3_ML", "exakit_udf", ["numpy", "scikit-learn"])
        self.assertTrue(script.startswith("CREATE OR REPLACE PYTHON3_ML SCALAR SCRIPT EXAKIT_UDF.EXAKIT_SMOKE()"))
        self.assertIn("ctx.emit('python', sys.version.split()[0])", script)
        self.assertIn("for name in ['numpy', 'scikit-learn']:", script)
        with self.assertRaises(udf_tool.Refused):
            udf_tool.smoke_script("x;drop", "S", [])

    def test_an_unknown_command_prints_the_usage(self):
        code, _, err = run("frob")
        self.assertEqual(code, 2)
        self.assertIn("udf_tool.py atleast", err)


if __name__ == "__main__":
    unittest.main()
