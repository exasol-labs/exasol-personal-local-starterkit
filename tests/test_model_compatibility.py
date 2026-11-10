import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "notebook/package"))
from exakit_nb import checks


class ModelCompatibilityTests(unittest.TestCase):
    def test_mismatch_is_one_line_and_refuses(self):
        output = io.StringIO()
        with patch.object(checks, "_probe", return_value={"scikit-learn": "1.9.0"}), redirect_stdout(output):
            self.assertFalse(checks.check_model_compatibility(None, "1.9.1", model_path="/buckets/x/model.pkl"))
        self.assertEqual(len(output.getvalue().splitlines()), 1)
        self.assertIn("/buckets/x/model.pkl", output.getvalue())
        self.assertIn("pickled with scikit-learn 1.9.1", output.getvalue())
        self.assertIn("container has 1.9.0", output.getvalue())

    def test_match_proceeds(self):
        with patch.object(checks, "_probe", return_value={"scikit-learn": "1.9.0"}):
            self.assertTrue(checks.check_model_compatibility(None, "1.9.0"))


if __name__ == "__main__":
    unittest.main()
