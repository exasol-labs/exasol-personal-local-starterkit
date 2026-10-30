"""Regressions for BRD X1.2 and DS5.3, using actual log and Explore cell paths."""
from __future__ import annotations

import contextlib
import importlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
wf = importlib.import_module("exakit_nb.workflow")
kit = importlib.import_module("exakit_nb._kit")
spec = importlib.util.spec_from_file_location("acceptance_builder", ROOT / "tools/notebooks.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
ROLES = ("entity", "category", "date", "label", "text")


class WorkflowCredentialTest(unittest.TestCase):
    def test_nested_credential_keys_are_refused_before_any_log_write(self):
        for payload in ({"metadata": {"api_key": "dummy-value"}},
                        {"metadata": '{"api_key":"dummy-value"}'},
                        {"items": [{"settings": {"password": "dummy-value"}}]},
                        {"items": ({"access_token": "dummy-value"},)},
                        {"metadata": {"LANGFUSE_SECRET_KEY": "dummy-value"}}):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as tmp, \
                    mock.patch.dict(os.environ, {"EXAKIT_HOME": tmp, "EXAKIT_WORKFLOW_ID": "wf-20261030-abcdef"}, clear=True), \
                    mock.patch.dict(kit.SESSION, {}, clear=True):
                with self.assertRaises(ValueError):
                    wf.log_event(wf.TRACE, **payload)
                self.assertFalse(wf.log_path("wf-20261030-abcdef").exists())

    def test_nested_nonsecret_metadata_is_preserved(self):
        payload = {"metadata": {"versions": [{"library": "1.0"}], "features": ("a", "b")}}
        self.assertEqual(wf._screen(payload), payload)


class DescriptorWorkflowTest(unittest.TestCase):
    def test_real_describe_service_records_draft_and_approval_under_the_active_id(self):
        sys.path.insert(0, str(ROOT / "setup/lib"))
        sys.path.insert(0, str(ROOT / "tests"))
        import describe_service as service
        from test_describe_service import FakeConn, Profiles, readings_draft
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {
                "EXAKIT_HOME": home, "EXAKIT_WORKFLOW_ID": "wf-20261030-abcdef"}, clear=True), \
                mock.patch.dict(kit.SESSION, {}, clear=True), contextlib.redirect_stdout(io.StringIO()):
            conn = FakeConn(Profiles.COLUMNS, Profiles.rows())
            doc = readings_draft(conn)
            result = service.approve(conn, doc, comments=False)
            rows = wf.read_log("wf-20261030-abcdef")
        self.assertEqual([row["kind"] for row in rows], ["describe.draft", "describe.approve"])
        self.assertEqual(rows[-1]["descriptor_version"], result["version"])
        self.assertEqual(rows[-1]["descriptor_id"], result["id"])


class MissingRolesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / "notebook/notebooks/data-scientist/01_explore.py"
        cls.cells = ["".join(c["source"]) for c in json.loads(builder.build(path))["cells"] if c["cell_type"] == "code"]

    def test_each_missing_role_skips_only_dependent_steps_without_failing_setup(self):
        class Frame(dict):
            def pivot_table(self, **kwargs):
                return self

        for missing in [*ROLES, "all"]:
            available = set() if missing == "all" else set(ROLES) - {missing}
            def column(role):
                if role not in available:
                    raise ValueError("missing " + role + " role")
                return '"' + role.upper() + '"'
            ds = types.SimpleNamespace(
                has=lambda role: role in available, col=column,
                text_sql=lambda: column("text"), fact_table="EXAMPLE.RECORDS",
                status="approved", id="fixture", missing=[{"role": role, "reason": "no suitable column"} for role in ROLES if role not in available])
            nb = types.SimpleNamespace(workflow=mock.Mock(return_value="wf-20261030-abcdef"),
                connect=mock.Mock(), review_roles=mock.Mock(return_value=types.SimpleNamespace(dataset=lambda **kw: ds)),
                show_roles=mock.Mock(), sql=mock.Mock(return_value=Frame(DAYS=[30], TEXT_=["Synthetic description"])),
                show_sql=mock.Mock(), model_client=mock.Mock(), confirm_send=mock.Mock(),
                write_handoff=mock.Mock(return_value="fixture.json"), read_handoff=mock.Mock(return_value={
                    "descriptor":{"id":"fixture","version":1},"feature_view":{"name":"EXAMPLE.FEATURES"},
                    "input_schema":[],"label":{"column":"LABEL","positive":1},"split":{"kind":"time"}}))
            namespace = {"nb": nb}
            cells = [c for c in self.cells if c.startswith(("DATASET = ", "import os\n", "landscape = ",
                     "over_time = ", "SAMPLE = ", "SAMPLE_TEXTS = ", "handoff_path = None"))]
            output = io.StringIO()
            with self.subTest(missing=missing), mock.patch.dict(sys.modules, {"exakit.nb": nb}), \
                    contextlib.redirect_stdout(output):
                for cell in cells:
                    exec(cell.replace("import exakit.nb as nb", ""), namespace)
                self.assertIsNone(namespace["model"])
                if missing in ("entity", "category", "label", "all"):
                    self.assertIsNone(namespace["landscape"])
                if missing in ("text", "all"):
                    self.assertIsNone(namespace["text_sample"])
                self.assertIn("no suitable column", output.getvalue())
                nb.model_client.assert_not_called()
                if missing in ("date", "label", "all"):
                    nb.write_handoff.assert_not_called()


class RunnerOptInTest(unittest.TestCase):
    def test_ci_opt_in_enables_the_actual_explore_cell_without_changing_sources(self):
        source = ROOT / "notebook/notebooks/data-scientist/01_explore.py"
        before = source.read_bytes()
        normal = builder.run_document(source, None)
        opted = builder.run_document(source, None, ai_themes=True)
        code = lambda doc: "\n".join("".join(c["source"]) for c in doc["cells"] if c["cell_type"] == "code")
        self.assertIn("USE_AI_THEMES = False", code(normal))
        self.assertIn("USE_AI_THEMES = True", code(opted))
        self.assertNotIn("USE_AI_THEMES = False", code(opted))
        self.assertEqual(source.read_bytes(), before)


class RunnerApprovalTest(unittest.TestCase):
    def test_sql_approval_is_explicit_and_never_promotes_share(self):
        ask = ROOT / "notebook/notebooks/data-scientist/02_ask_your_data.py"
        share = ROOT / "notebook/notebooks/data-scientist/03_share.py"
        text = lambda doc: "\n".join("".join(c["source"]) for c in doc["cells"] if c["cell_type"] == "code")
        self.assertIn("APPROVE_SQL = False", text(builder.run_document(ask, None)))
        self.assertIn("APPROVE_SQL = True", text(builder.run_document(ask, None, approve_sql=True)))
        self.assertIn("FIGURES_CHECKED = False", text(builder.run_document(share, None, approve_sql=True)))

    def test_rust_restart_consent_is_never_implicit(self):
        rust = ROOT / "notebook/notebooks/ml-engineer/02_rust_score.py"
        text = lambda doc: "\n".join("".join(c["source"]) for c in doc["cells"] if c["cell_type"] == "code")
        self.assertIn("ALLOW_DATABASE_RESTART = False", text(builder.run_document(rust, None)))
        self.assertIn("ALLOW_DATABASE_RESTART = True", text(builder.run_document(rust, None, allow_database_restart=True)))


class EmptyBucketTest(unittest.TestCase):
    def test_empty_guest_folder_is_materialized_without_a_fake_model(self):
        from exakit_nb import checks
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            doc = {"bucket_dir": str(folder), "udf_root": "/buckets/test/default", "models": []}
            def probe(*args, **kwargs):
                return {"path": "folder" if (folder / ".exakit-bucket").exists() else "missing"}
            with mock.patch.object(checks, "model_list", return_value=doc), mock.patch.object(checks, "_probe", side_effect=probe):
                self.assertTrue(checks.check_bucket(object()))
            self.assertEqual([p.name for p in folder.iterdir()], [".exakit-bucket"])


class RustParityTest(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec("numpy") and importlib.util.find_spec("pandas"), "requires notebook numeric packages")
    def test_missing_inputs_follow_training_policy_and_non_finite_scores_fail(self):
        import numpy as np
        import pandas as pd
        from types import SimpleNamespace
        source = ROOT / "notebook/notebooks/ml-engineer/02_rust_score.py"
        cell = next("\n".join(lines) for kind, lines, tags in builder._cells(source.read_text(), source.parent)
                    if kind == "code" and any(line.startswith("arguments = ") for line in lines))
        for actual in ([0.5, 0.5], [float("nan"), 0.5]):
            frame = pd.DataFrame({"FEATURE": [None, 1.0], "RUST_P": actual})
            query = mock.Mock(return_value=frame)
            scope = {"np": np, "nb": SimpleNamespace(sql=query), "conn": object(), "features": ["FEATURE"],
                     "deployed": {"udf": "S.SCORE"}, "handoff": {"training_sql": "SELECT * FROM S.FEATURES"},
                     "TEST_ROWS": 2, "coefficients": {"coef": [[0.0]], "intercept": [0.0]},
                     "expit": lambda x: 1 / (1 + np.exp(-x))}
            if np.isnan(actual[0]):
                with self.assertRaisesRegex(AssertionError, "finite"):
                    exec(compile(cell, str(source), "exec"), scope)
            else:
                exec(compile(cell, str(source), "exec"), scope)
                self.assertEqual(scope["gap"], 0.0)
                self.assertIn("COALESCE", query.call_args.args[1])


if __name__ == "__main__":
    unittest.main()
