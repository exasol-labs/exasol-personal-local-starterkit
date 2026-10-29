"""The bucketless fallback updates the pinned runtime without losing earlier UDFs."""
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "setup/udf"))
import rust_container as container


class RustContainerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "rust.tar.gz"
        with tarfile.open(self.source, "w:gz") as archive:
            for name, body in [("exaudf/exaudfclient", b"pinned runner"),
                               ("build_info/language_definitions.json", b'{"aliases":["RUST"]}')]:
                info = tarfile.TarInfo(name)
                info.mode = 0o755; info.size = len(body)
                archive.addfile(info, io.BytesIO(body))
        self.row = {"url": "https://example.invalid/rust.tar.gz", "sha256": container.digest(self.source),
                    "size": self.source.stat().st_size}
        self.launcher = self.root / "exasol"
        self.launcher.write_text("test fixture")
        self.deployment = self.root / "deployment"; self.deployment.mkdir()
        self.env = patch.dict(os.environ, {"EXAKIT_UDF_CONTAINERS_MIRROR": str(self.root)})
        self.env.start(); self.addCleanup(self.env.stop)

    def library(self, name, body):
        path = self.root / name; path.write_bytes(body)
        return path

    def test_pack_preserves_runtime_bytes_and_permissions(self):
        library = self.library("libscore.so", b"validated scoring library")
        target = self.root / "combined.tar.gz"
        container.pack(self.source, target, self.row["sha256"], {library.name: library})
        with tarfile.open(self.source) as old, tarfile.open(target) as new:
            for item in old:
                self.assertEqual(new.getmember(item.name).mode, item.mode)
                self.assertEqual(new.extractfile(item.name).read(), old.extractfile(item).read())
            self.assertEqual(new.extractfile("opt/exakit/udf/libscore.so").read(), library.read_bytes())
        self.assertEqual(container.digest(self.source), self.row["sha256"])

    def test_bad_digest_never_produces_a_container(self):
        target = self.root / "combined.tar.gz"
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            container.pack(self.source, target, "0"*64, {})
        self.assertFalse(target.exists())

    def test_two_deploys_keep_both_libraries_and_request_a_restart(self):
        with patch.object(container.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as run:
            for name in ["libfirst.so", "libsecond.so"]:
                library = self.library(name, name.encode())
                result = container.install(self.root / "kit", self.row, library, container.digest(library),
                                           str(self.launcher), self.deployment)
        self.assertEqual(set(result["libraries"]), {"libfirst.so", "libsecond.so"})
        args = run.call_args.args[0]
        self.assertEqual(args[1:4], ["slc", "custom", "update"])
        self.assertIn("--auto-approve", args)
        self.assertNotIn("--no-restart", args)
        with tarfile.open(args[args.index("--source")+1]) as archive:
            self.assertEqual(archive.extractfile("opt/exakit/udf/libfirst.so").read(), b"libfirst.so")
            self.assertEqual(archive.extractfile("opt/exakit/udf/libsecond.so").read(), b"libsecond.so")

    def test_failed_update_does_not_record_success_or_print_launcher_output(self):
        library = self.library("libscore.so", b"validated")
        with patch.object(container.subprocess, "run", return_value=subprocess.CompletedProcess([], 1,
                                stdout="private connection details", stderr="private connection details")):
            with self.assertRaisesRegex(ValueError, "launcher could not update") as caught:
                container.install(self.root / "kit", self.row, library, container.digest(library),
                                  str(self.launcher), self.deployment)
        self.assertNotIn("private connection", str(caught.exception))
        self.assertFalse((self.root / "kit/rust-udfs/.container/installed.json").exists())
        self.assertFalse((self.root / "kit/rust-udfs/.container/update.lock").exists())

    def test_tampered_prior_library_is_not_silently_dropped(self):
        library = self.library("libscore.so", b"validated")
        with patch.object(container.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            container.install(self.root / "kit", self.row, library, container.digest(library),
                              str(self.launcher), self.deployment)
        state = self.root / "kit/rust-udfs/.container"
        (state / (container.digest(library)+".so")).write_bytes(b"changed")
        with patch.object(container.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "previously deployed"):
                container.install(self.root / "kit", self.row, library, container.digest(library),
                                  str(self.launcher), self.deployment)
        run.assert_not_called()

    def test_base_replacement_deactivates_overlay_but_preserves_libraries(self):
        library = self.library("libfirst.so", b"validated")
        home = self.root / "kit"
        with patch.object(container.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            container.install(home, self.row, library, container.digest(library), str(self.launcher), self.deployment)
            self.assertTrue(container.installed_library(home, self.row, library.name, container.digest(library)))
            container.invalidate(home)
            self.assertFalse(container.current_receipt(home, self.row))
            other = self.library("libsecond.so", b"second")
            result = container.install(home, self.row, other, container.digest(other), str(self.launcher), self.deployment)
        self.assertTrue(result["active"])
        self.assertEqual(set(result["libraries"]), {"libfirst.so", "libsecond.so"})

    def test_visibility_probe_hashes_the_file_inside_the_udf(self):
        from unittest.mock import MagicMock
        conn = MagicMock()
        library = self.library("libprobe.so", b"real probe bytes")
        expected = container.digest(library)
        conn.execute.return_value.fetchall.return_value = [{"SHA256": expected}]
        self.assertTrue(container.bucket_visible(conn, "/buckets/bfs/default/libprobe.so", expected))
        script = conn.execute.call_args_list[1].args[0].split(" AS\n", 1)[1]
        namespace = {}; exec(script, namespace)
        self.assertEqual(namespace["run"](type("Ctx", (), {"p": str(library)})()), expected)
        library.unlink()
        self.assertIsNone(namespace["run"](type("Ctx", (), {"p": str(library)})()))
        conn.execute.return_value.fetchall.return_value = [(None,)]
        self.assertFalse(container.bucket_visible(conn, "/buckets/bfs/default/libprobe.so", expected))


if __name__ == "__main__":
    unittest.main()
