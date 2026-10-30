"""The installed bundle contains runnable notebooks; provenance stays internal."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("notebook_bundle", ROOT / "notebook/kit/notebooks.py")
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


class BundleTest(unittest.TestCase):
    def test_both_fronts_receive_real_notebooks_without_a_source_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            doc = bundle.catalog(ROOT)
            for front in ("jupyter", "marimo"):
                with self.subTest(front=front):
                    added, problems = bundle.copy(front, ROOT, Path(tmp))
                    self.assertEqual(problems, [])
                    base = Path(tmp) / doc["folders"][front]
                    for entry in doc["notebooks"]:
                        path = base / entry["persona"] / entry[front]
                        self.assertTrue(path.is_file())
                        self.assertIn("nb.connect()", path.read_text())
                    self.assertFalse((base / "upstream-sources.json").exists())
                    self.assertTrue((base / "UPSTREAM-LICENSE.txt").is_file())
                    guide = base / "MODEL-PROVIDERS.md"
                    self.assertEqual(guide.read_bytes(), (ROOT / "notebook/MODEL-PROVIDERS.md").read_bytes())
                    guide.write_text("my provider notes")
                    sample = base / "data-scientist" / doc["notebooks"][0][front]
                    sample.write_text("my notebook")
                    self.assertEqual(bundle.copy(front, ROOT, Path(tmp)), ([], []))
                    self.assertEqual(sample.read_text(), "my notebook")
                    self.assertEqual(guide.read_text(), "my provider notes")

    def test_old_generated_manifest_is_removed_but_user_changes_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            for front, edited in (("jupyter", False), ("marimo", True)):
                base = Path(tmp) / bundle.catalog(ROOT)["folders"][front]
                base.mkdir(parents=True)
                manifest = base / "upstream-sources.json"
                manifest.write_bytes(b"my source notes" if edited else (ROOT / "notebook/upstream-sources.json").read_bytes())
                (base / bundle.STATE).write_text("upstream-sources.json\n")
                _, problems = bundle.copy(front, ROOT, Path(tmp))
                self.assertEqual(problems, [])
                self.assertEqual(manifest.exists(), edited)
                if edited:
                    self.assertEqual(manifest.read_bytes(), b"my source notes")


if __name__ == "__main__":
    unittest.main()
