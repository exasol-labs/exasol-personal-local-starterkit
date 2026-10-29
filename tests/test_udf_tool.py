"""setup/udf/udf_tool.py - the UDF dev kit's rules, shared by the shell and PowerShell modules (run:
python3 tests/test_udf_tool.py). No database: the smoke UDF is checked as the SQL it sends."""

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

    def test_the_smoke_udf_asks_for_bare_names_and_compares_the_pins(self):
        # A pin travels as name==version; the UDF is asked for the name only.
        self.assertEqual(udf_tool.split_pins(["numpy==2.4.6", "pandas"]), [("numpy", "2.4.6"), ("pandas", "")])
        found = {"python": "3.12.3", "numpy": "2.4.6", "pandas": "2.3.3"}
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(udf_tool.smoke_verdict(found, [("numpy", "2.4.6"), ("pandas", "")]), 0)
            self.assertEqual(udf_tool.smoke_verdict(found, [("numpy", "2.4.6"), ("scipy", "1.18.0")]), 3)
            self.assertIn("missing: scipy", err.getvalue())
        with redirect_stderr(io.StringIO()) as err:
            self.assertEqual(udf_tool.smoke_verdict(found, [("numpy", "2.4.0"), ("pandas", "")]), 7)
            self.assertEqual(err.getvalue().strip(), "numpy reported 2.4.6, pinned 2.4.0")
        # Missing wins over a mismatch: the container lacks something, not merely the wrong one.
        with redirect_stderr(io.StringIO()):
            self.assertEqual(udf_tool.smoke_verdict(found, [("numpy", "2.4.0"), ("scipy", "1.18.0")]), 3)

    def test_the_rust_smoke_udf_is_one_script_over_a_bucket_library(self):
        # The library's /buckets path is the only text that reaches the SQL, and only a .so under /buckets does.
        script = udf_tool.rust_smoke_script("rust", "starter_kit", "/buckets/bfsdefault/default/udf/libexakit_smoke.so")
        self.assertEqual(script, "CREATE OR REPLACE RUST SCALAR SCRIPT STARTER_KIT.EXAKIT_SMOKE(x BIGINT) RETURNS VARCHAR(2000) AS\n"
                                 "%udf_object /buckets/bfsdefault/default/udf/libexakit_smoke.so;\n")
        self.assertIn("%udf_object /opt/exakit/udf/libexakit_smoke.so;",
                      udf_tool.rust_smoke_script("RUST", "STARTER_KIT", "/opt/exakit/udf/libexakit_smoke.so"))
        for bad in ("/tmp/x.so", "/buckets/a/b.so; DROP", "/buckets/a/lib.tar.gz", "", "/buckets/../etc/x.so"):
            with self.subTest(path=bad):
                with self.assertRaises(udf_tool.Refused):
                    udf_tool.rust_smoke_script("RUST", "S", bad)
        with self.assertRaises(udf_tool.Refused):
            udf_tool.rust_smoke_script("x;drop", "S", "/buckets/a/b.so")

    def test_the_rust_smoke_verdict_holds_rustc_and_sdk_against_the_pins(self):
        # The library reports rustc --version in full; the kit compares the x.y.z and keeps the full string too.
        report = udf_tool.rust_smoke_report('{"container": "RUST", "rustc": "rustc 1.98.1 (48a229cea 2026-09-01)", "sdk": "0.33.0", "x": 1}')
        self.assertEqual(udf_tool.rustc_semver(report["rustc"]), "1.98.1")
        with redirect_stderr(io.StringIO()) as err:
            lines, code = udf_tool.rust_smoke_verdict(report, "1.98.1", "0.33.0")
        self.assertEqual((lines, code, err.getvalue()),
                         (["container RUST", "rustc 1.98.1", "sdk 0.33.0", "rustc_full rustc 1.98.1 (48a229cea 2026-09-01)"], 0, ""))
        with redirect_stderr(io.StringIO()) as err:
            lines, code = udf_tool.rust_smoke_verdict({"rustc": "rustc 1.97.0 (abc 2026-01-01)", "sdk": "0.33.0"}, "1.98.1", "0.33.0")
        self.assertEqual((code, lines[1], err.getvalue().strip()), (7, "rustc 1.97.0", "rustc reported 1.97.0, pinned 1.98.1"))
        with redirect_stderr(io.StringIO()) as err:
            _, code = udf_tool.rust_smoke_verdict({"rustc": "1.98.1", "sdk": "0.32.0"}, "1.98.1", "0.33.0")
        self.assertEqual((code, err.getvalue().strip()), (7, "exasol-udf-sdk reported 0.32.0, pinned 0.33.0"))
        # An unpinned sdk is reported, not compared.
        with redirect_stderr(io.StringIO()):
            self.assertEqual(udf_tool.rust_smoke_verdict({"rustc": "1.98.1", "sdk": "0.32.0"}, "1.98.1")[1], 0)
        for text in ("not json", '"a string"', '{"container": "RUST"}'):
            with self.subTest(text=text):
                with self.assertRaises(udf_tool.Refused):
                    udf_tool.rust_smoke_report(text)

    def test_a_container_refusing_the_library_names_the_fingerprint(self):
        # F-UDF-CL-RUST-9001 is the database's ABI fingerprint check (SDK_VERSION:RUSTC_VERSION): the reason says so
        # and what the container expects, so the user knows the library and the container disagree.
        reason = udf_tool.rust_load_reason("ExaQueryError: F-UDF-CL-RUST-9001: fingerprint 0.33.0:rustc_1.97.0\n  (Session: 7)", "1.98.1", "0.33.0")
        self.assertTrue(reason.startswith("the RUST container refused to load the smoke library (F-UDF-CL-RUST-9001: ABI fingerprint mismatch)"))
        self.assertIn("than the container's 0.33.0:rustc_1.98.1 - ExaQueryError: F-UDF-CL-RUST-9001: fingerprint 0.33.0:rustc_1.97.0 (Session: 7)", reason)
        self.assertEqual(udf_tool.rust_load_reason("object STARTER_KIT.EXAKIT_SMOKE not found", "1.98.1", "0.33.0"),
                         "the smoke UDF did not run: object STARTER_KIT.EXAKIT_SMOKE not found")

    def test_smoke_rust_takes_four_or_five_arguments(self):
        # Fewer than four is the usage; the database step itself is not run here.
        code, _, err = run("smoke-rust", "RUST", "STARTER_KIT", "/buckets/bfsdefault/default/udf/libexakit_smoke.so")
        self.assertEqual(code, 2)
        self.assertIn("udf_tool.py smoke-rust", err)
        with mock.patch.object(udf_tool, "_connect", side_effect=AssertionError("no database in this test")):
            code, _, err = run("smoke-rust", "RUST", "STARTER_KIT", "/tmp/escape.so", "1.98.1")
        self.assertEqual(code, 2)
        self.assertIn("not a bucket or packaged Rust library path", err)

    def test_an_unknown_command_prints_the_usage(self):
        code, _, err = run("frob")
        self.assertEqual(code, 2)
        self.assertIn("udf_tool.py atleast", err)


MATRIX = {"components": {"udf-devkit": {"version": "0.1.0", "containers": [
    {"language": "python", "alias": "PYTHON3_ML", "arch": "x86_64", "db_versions": ">=2026.1",
     "packages": {"scikit-learn": "1.9.0", "numpy": "2.4.6"}, "url": "https://x/py-x64.tar.gz", "sha256": "a" * 64, "size": 10},
    {"language": "python", "alias": "PYTHON3_ML", "arch": "aarch64", "db_versions": ">=2026.1,<2027",
     "packages": {"scikit-learn": "1.9.0", "numpy": "2.4.6"}, "url": "https://x/py-arm64.tar.gz", "sha256": "b" * 64, "size": 11},
    {"language": "rust", "alias": "RUST", "arch": "x86_64", "db_versions": ">=2026.1",
     "crates": {"exasol-udf-sdk": "0.33.0"}, "url": "https://x/lc-rust.tar.gz", "sha256": "c" * 64, "size": 12}]}}}


class ContainerMatrixTest(unittest.TestCase):
    """The container matrix (ML-1): which row a machine gets, and the digest check before any install."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.doc = Path(self.tmp.name, "versions.json")
        self.doc.write_text(json.dumps(MATRIX))

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_arch_is_the_databases_not_the_shells(self):
        # An Apple-silicon Mac runs an aarch64 database VM; Windows runs Podman's x86_64 machine.
        for machine, system, want in (("arm64", "darwin", "aarch64"), ("x86_64", "darwin", "x86_64"),
                                      ("arm64", "windows", "x86_64"), ("AMD64", "windows", "x86_64"),
                                      ("x86_64", "linux", "x86_64"), ("amd64", "linux", "x86_64"),
                                      ("aarch64", "linux", "aarch64"), ("arm64", "linux", "aarch64")):
            with self.subTest(machine=machine, system=system):
                self.assertEqual(run("arch", machine, system)[:2], (0, want + "\n"))
        for machine, system in (("riscv64", "linux"), ("x86_64", "freebsd")):
            with self.subTest(machine=machine, system=system):
                code, _, err = run("arch", machine, system)
                self.assertEqual(code, 2)
                self.assertIn("No container is built for", err)
        with mock.patch.dict("os.environ", {"EXAKIT_UDF_ARCH": "x86_64"}):
            self.assertEqual(run("arch", "arm64", "darwin")[1], "x86_64\n")
        with mock.patch.dict("os.environ", {"EXAKIT_UDF_ARCH": "arm64"}):
            code, _, err = run("arch", "arm64", "darwin")
            self.assertEqual(code, 2)
            self.assertIn("EXAKIT_UDF_ARCH must be x86_64 or aarch64", err)

    def test_a_version_range_is_comparators_on_dotted_numbers(self):
        self.assertEqual(udf_tool._key("2026.2.0-nano.3"), [2026, 2, 0, 0, 0, 0])
        self.assertTrue(udf_tool.version_in_range("2026.2.0-nano.3", ">=2026.1"))
        self.assertTrue(udf_tool.version_in_range("2026.1", ">=2026.1,<2027"))
        self.assertFalse(udf_tool.version_in_range("2027.0", ">=2026.1,<2027"))
        self.assertFalse(udf_tool.version_in_range("2025.3", ">=2026.1"))
        self.assertTrue(udf_tool.version_in_range("2026.2.5", "==2026.2"))
        self.assertFalse(udf_tool.version_in_range("2026.3", "==2026.2"))
        self.assertTrue(udf_tool.version_in_range("1.0", ""))
        with self.assertRaises(udf_tool.Refused):
            udf_tool.version_in_range("2026.1", "~2026")

    def test_resolve_names_what_did_not_match(self):
        code, out, _ = run("resolve", str(self.doc), "python", "aarch64", "2026.2.0-nano.3")
        self.assertEqual(code, 0)
        row = json.loads(out)
        self.assertEqual((row["alias"], row["url"], row["size"]), ("PYTHON3_ML", "https://x/py-arm64.tar.gz", 11))
        for language, arch, version, reason in (("rust", "aarch64", "2026.1", "no rust container for aarch64"),
                                                ("python", "x86_64", "2025.3", "container needs database >=2026.1, this one is 2025.3"),
                                                ("python", "aarch64", "2027.1", "container needs database >=2026.1,<2027, this one is 2027.1"),
                                                ("go", "x86_64", "2026.1", "no go container is published"),
                                                ("python", "x86_64", "", "the database version is not known")):
            with self.subTest(language=language, arch=arch, version=version):
                code, out, err = run("resolve", str(self.doc), language, arch, version)
                self.assertEqual((code, out), (4, ""))
                self.assertIn(reason, err)

    def test_pins_are_the_rows_packages_or_crates(self):
        self.assertEqual(run("pins", str(self.doc), "python", "x86_64")[1], "scikit-learn 1.9.0\nnumpy 2.4.6\n")
        self.assertEqual(run("pins", str(self.doc), "rust", "x86_64", "2026.1")[1], "exasol-udf-sdk 0.33.0\n")
        code, _, err = run("pins", str(self.doc), "rust", "aarch64")
        self.assertEqual(code, 4)
        self.assertIn("no rust container for aarch64", err)
        row = json.dumps(MATRIX["components"]["udf-devkit"]["containers"][0])
        self.assertEqual(run("field", "url", stdin=row)[1], "https://x/py-x64.tar.gz\n")
        self.assertEqual(run("field", "size", stdin=row)[1], "10\n")
        self.assertEqual(run("field", "nope", stdin=row)[0], 1)

    def test_verify_checks_the_size_then_the_digest(self):
        import hashlib
        file = Path(self.tmp.name, "c.tar.gz")
        file.write_bytes(b"container bytes")
        digest = hashlib.sha256(b"container bytes").hexdigest()
        self.assertEqual(run("verify", str(file), digest, "15")[0], 0)
        code, _, err = run("verify", str(file), digest, "866462911")
        self.assertEqual(code, 4)
        self.assertEqual(err.strip(), "expected 866462911 bytes, got 15")
        code, _, err = run("verify", str(file), "0" * 64, "15")
        self.assertEqual(code, 4)
        self.assertEqual(err.strip(), f"sha256 expected {'0' * 64}, got {digest}")
        code, _, err = run("verify", str(Path(self.tmp.name, "missing")), digest, "15")
        self.assertEqual(code, 4)
        self.assertIn("is not there", err)


if __name__ == "__main__":
    unittest.main()
