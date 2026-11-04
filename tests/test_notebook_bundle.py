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
                    # The README says what the guides did; they and the shared cells (build input) stay in the kit.
                    for left_out in ("MODEL-PROVIDERS.md", "INSTALL-AND-UPDATE.md", "00_shared", "useful-notebooks"):
                        self.assertFalse((base / left_out).exists(), left_out)
                    sample = base / "data-scientist" / doc["notebooks"][0][front]
                    sample.write_text("my notebook")
                    self.assertEqual(bundle.copy(front, ROOT, Path(tmp)), ([], []))
                    self.assertEqual(sample.read_text(), "my notebook")
            readme = Path(tmp) / doc["folders"]["jupyter"] / "README.md"
            self.assertIn("EXAKIT_PROVIDER_BASE_URL", readme.read_text())

    def test_a_persona_brings_its_own_notebooks_and_one_added_later_joins(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / bundle.catalog(ROOT)["folders"]["jupyter"]
            bundle.copy("jupyter", ROOT, Path(tmp), {"data-scientist"})
            self.assertTrue((base / "data-scientist").is_dir())
            self.assertFalse((base / "ml-engineer").exists())
            self.assertNotIn("ml-engineer/", (base / "README.md").read_text())
            bundle.copy("jupyter", ROOT, Path(tmp), {"data-scientist", "ml-engineer"})
            self.assertTrue((base / "ml-engineer").is_dir())
            self.assertIn("ml-engineer/", (base / "README.md").read_text(), "the kit's README follows the personas")
            (base / "README.md").write_text("my notes")
            bundle.copy("jupyter", ROOT, Path(tmp), {"general"})
            self.assertEqual("my notes", (base / "README.md").read_text(), "an edited README is the user's")

    def test_no_persona_with_notebooks_brings_them_all(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / bundle.catalog(ROOT)["folders"]["jupyter"]
            bundle.copy("jupyter", ROOT, Path(tmp), {"general"})
            self.assertTrue((base / "data-scientist").is_dir() and (base / "ml-engineer").is_dir())

    def test_an_older_kits_readme_is_replaced_and_kept_beside(self):
        """A README an older kit wrote (no marker; it names useful-notebooks/ and Positron) is replaced, the old one
        kept as README.old.md; one of the user's own is left alone (audit DAY-02)."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / bundle.catalog(ROOT)["folders"]["jupyter"]
            base.mkdir(parents=True)
            (base / "README.md").write_text("# The starter kit's notebooks\n\nexakit notebook positron; useful-notebooks/\n")
            bundle.copy("jupyter", ROOT, Path(tmp), {"data-scientist"})
            self.assertTrue((base / "README.md").read_text().startswith("# Your notebooks"))
            self.assertIn("positron", (base / "README.old.md").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / bundle.catalog(ROOT)["folders"]["jupyter"]
            base.mkdir(parents=True)
            (base / "README.md").write_text("# My own notes\n")
            bundle.copy("jupyter", ROOT, Path(tmp), {"data-scientist"})
            self.assertEqual("# My own notes\n", (base / "README.md").read_text())
            self.assertFalse((base / "README.old.md").exists())

    def test_removing_a_persona_does_not_bring_the_other_ones(self):
        """Data Scientist removed, General left (audit DAY-04): the next copy adds no ML Engineer notebooks, and the
        README still names the data-scientist folder that is on disk."""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / bundle.catalog(ROOT)["folders"]["jupyter"]
            bundle.copy("jupyter", ROOT, Path(tmp), {"data-scientist", "general"})
            self.assertEqual(bundle.copy("jupyter", ROOT, Path(tmp), {"general"}), ([], []))
            self.assertFalse((base / "ml-engineer").exists())
            self.assertIn("data-scientist/", (base / "README.md").read_text(), "a folder still there is still named")


if __name__ == "__main__":
    unittest.main()
