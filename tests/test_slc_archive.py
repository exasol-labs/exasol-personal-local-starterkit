"""The alias rewrite preserves payload bytes and keeps both digest records."""
import hashlib
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "setup" / "udf"))
import slc_archive


class IsolatedArchiveTest(unittest.TestCase):
    def archive(self, root, *, duplicate=False, metadata=True):
        source = root / "official.tar.gz"
        definition = {"language_definitions": [{"aliases": ["PYTHON3", "PYTHON312"],
                      "parameters": [{"key": "lang", "value": "python"}],
                      "udf_client_path": {"executable": "/exaudf/exaudfclient"}}]}
        with tarfile.open(source, "w:gz") as tar:
            for name, body in [("exaudf/exaudfclient", b"unchanged binary"),
                               ("usr/lib/library.so", b"unchanged library"),
                               *([(slc_archive.METADATA, json.dumps(definition).encode())] * (2 if duplicate else 1) if metadata else [])]:
                item = tarfile.TarInfo(name); item.mode = 0o755; item.uid = 42; item.size = len(body)
                tar.addfile(item, io.BytesIO(body))
            link = tarfile.TarInfo("bin/python"); link.type = tarfile.SYMTYPE; link.linkname = "../usr/bin/python3"
            tar.addfile(link)
        return source, hashlib.sha256(source.read_bytes()).hexdigest()

    def test_only_metadata_changes_and_the_cache_proves_both_digests(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source, sha = self.archive(root); target = root / "isolated.tar.gz"
            slc_archive.prepare(source, target, "PYTHON3_ML", sha)
            with tarfile.open(source) as old, tarfile.open(target) as new:
                self.assertEqual(old.getnames(), new.getnames())
                for member in old:
                    copied = new.getmember(member.name)
                    self.assertEqual((member.uid, member.mode, member.type, member.linkname),
                                     (copied.uid, copied.mode, copied.type, copied.linkname))
                    if not member.isfile(): continue
                    if member.name == slc_archive.METADATA:
                        doc = json.load(new.extractfile(copied))
                        self.assertEqual(doc["language_definitions"][0]["aliases"], ["PYTHON3_ML"])
                    else:
                        self.assertEqual(old.extractfile(member).read(), new.extractfile(copied).read())
            self.assertEqual(slc_archive.digest(source), sha)
            proof = json.loads(target.with_suffix(".gz.json").read_text())
            self.assertEqual(proof["source_sha256"], sha)
            self.assertEqual(proof["sha256"], slc_archive.digest(target))
            with mock.patch.object(slc_archive.tarfile, "open", side_effect=AssertionError("cache should be reused")):
                self.assertEqual(slc_archive.prepare(source, target, "PYTHON3_ML", sha), target)
            target.write_bytes(b"corrupted cache")
            slc_archive.prepare(source, target, "PYTHON3_ML", sha)
            self.assertEqual(slc_archive.digest(target), proof["sha256"])

    def test_bad_source_and_invalid_metadata_never_produce_an_installable_archive(self):
        for case in ("digest", "missing", "duplicate"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp); source, sha = self.archive(root, duplicate=case == "duplicate", metadata=case != "missing")
                target = root / "isolated.tar.gz"
                with self.assertRaises(ValueError):
                    slc_archive.prepare(source, target, "PYTHON3_ML", "0" * 64 if case == "digest" else sha)
                self.assertFalse(target.exists())
                self.assertFalse(target.with_suffix(".gz.part").exists())


if __name__ == "__main__":
    unittest.main()
