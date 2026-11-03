"""Role review and no-descriptor file loading (python3 -m unittest tests.test_role_picker).

What it pins, with fakes and no database: corrections approve without a file; two columns cannot claim one role; the
picker's labels carry each column's evidence and the role's runner-up; the headless rule (EXAKIT_NB_AUTO_APPROVE=1
approves nothing new - equal roles are used as approved, different ones stay a draft that dataset() hands on; force
approves the proposal); the Jupyter picker's shape; the Marimo review is a mo.ui.dictionary of dropdowns with a run
button whose dataset() stops cleanly until the click and approves on it; a draft and an approval are lines in the
active workflow's log; review_roles given a name opens a described dataset as it is and loads, profiles and drafts a
data file with no descriptor beside it.
"""
from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import types
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook/package"))
from exakit_nb import _kit  # noqa: E402
from exakit_nb.describe import Draft  # noqa: E402
from exakit_nb.own_file import LoadedTable, load_own_file  # noqa: E402
from exakit_nb import role_picker  # noqa: E402
from exakit_nb.role_picker import RoleReview, marimo_review, review_roles  # noqa: E402

TABLE = "S.T"


def draft():
    """A draft over columns A, B, C, D: entity A, category B in their slots, no time (C is text-like, D one value)."""
    doc = {"descriptor": 1, "dataset": "example", "source": {"kind": "local", "object": TABLE, "schema_digest": "sha256:ab",
                                                              "profiled_rows": 1000},
           "version": 1, "status": "draft", "grain": "",
           "slots": {"key": None, "time": None, "text": None, "target": None, "category": "B", "entity": "A"},
           "slot_evidence": {"key": "no single unique column", "time": "no dates", "text": "no text column",
                             "target": "set by the user; never drafted"},
           "columns": {"A": {"role": "category", "confidence": "low", "evidence": "120 distinct, 12% of rows"},
                       "B": {"role": "category", "confidence": "high", "evidence": "4 distinct"},
                       "C": {"role": "other", "confidence": "low", "evidence": "VARCHAR(2000), no rule fits"},
                       "D": {"role": "category", "confidence": "high", "evidence": "1 distinct"}}}
    profile = {"source": {"profiled_rows": 1000}, "statements": [],
               "columns": [{"column": "A", "type": "VARCHAR(40)", "approx_distinct": 120},
                           {"column": "B", "type": "VARCHAR(10)", "approx_distinct": 4},
                           {"column": "C", "type": "VARCHAR(2000)", "approx_distinct": 900, "avg_length": 140.5},
                           {"column": "D", "type": "DECIMAL(18,0)", "approx_distinct": 1}]}
    return Draft(doc, profile)


def approve_as_dict(this, **kwargs):
    """A Draft.approve stand-in: the corrected document, as the tests inspect it."""
    return this.to_dict()


class ReviewTest(unittest.TestCase):
    def test_the_review_explains_its_source_and_the_human_decision(self):
        review = RoleReview(draft(), object())
        guide = review.guide()
        self.assertIn("column names and measured values", guide)
        self.assertIn("prediction target", guide)
        self.assertIn("not a probability", guide)
        self.assertIn("entity", guide)
        self.assertIn("category", guide)
        self.assertIn("leave", guide)
        explanation = review.explanations()
        self.assertIn("120 distinct", explanation["A"])
        self.assertIn("4 distinct", explanation["B"])
        self.assertIn("No notebook role: the rules call it category (1 distinct)", explanation["D"])

    def test_low_confidence_and_sensitive_columns_are_marked_for_review(self):
        proposal = draft()
        self.assertIn("Low confidence", RoleReview(proposal, object()).explanations()["A"])
        self.assertNotIn("Low confidence", RoleReview(proposal, object()).explanations()["B"])
        proposal.doc["columns"]["C"].update(role="identifier", sensitive=True)
        self.assertIn("never charted, grouped or sent to a model", RoleReview(proposal, object()).explanations()["C"])

    def test_corrections_approve_without_editing_a_file(self):
        review = RoleReview(draft(), object())
        self.assertEqual(review.suggestions(), {"A": "entity", "B": "category", "C": None, "D": None})
        with self.assertRaisesRegex(RuntimeError, "Approve descriptor"):
            review.dataset()
        with mock.patch.object(Draft, "approve", autospec=True, side_effect=approve_as_dict):
            result = review.approve({"A": "entity", "B": None, "C": "text", "D": None})
        self.assertEqual((result["slots"]["text"], result["slots"]["entity"], result["slots"]["category"]), ("C", "A", None))
        self.assertEqual("no single unique column", result["slot_evidence"]["key"])
        self.assertIn("category", result["slot_evidence"])
        self.assertIs(review.dataset(), result)

    def test_two_columns_cannot_claim_a_single_role(self):
        with self.assertRaisesRegex(ValueError, "category role has two columns"):
            RoleReview(draft(), object()).approve({"A": "category", "B": "category"})

    def test_labels_carry_the_type_role_confidence_and_evidence(self):
        proposal = draft()
        proposal.doc["columns"]["B"]["note"] = "The product line as filed."
        labels = RoleReview(proposal, object()).labels()
        self.assertEqual(labels["A"], ("VARCHAR(40), category (low confidence): 120 distinct, 12% of rows", ""))
        self.assertEqual(labels["B"], ("VARCHAR(10), category (high confidence): 4 distinct", "The product line as filed."))
        self.assertEqual(labels["C"], ("VARCHAR(2000), other (low confidence): VARCHAR(2000), no rule fits", ""))
        self.assertEqual(role_picker.evidence_summary({"type": "DATE", "null_rate": 0.1, "span_days": 400, "distinct": 9}),
                         "DATE, null 10.0%, span 400 d")

    def test_the_jupyter_picker_is_a_dropdown_per_column_with_its_evidence_under_it(self):
        made = []

        class Widget:
            def __init__(self, *args, **kwargs):
                self.args, self.kwargs, self.value = args, kwargs, kwargs.get("value")
                made.append((type(self).__name__, kwargs))

            def on_click(self, handler):
                self.handler = handler

        widgets = types.SimpleNamespace(**{name: type(name, (Widget,), {}) for name in ("Dropdown", "HTML", "VBox", "Button", "Output")})
        box = RoleReview(draft(), object()).build_jupyter_picker(widgets)
        dropdowns = [kw for name, kw in made if name == "Dropdown"]
        self.assertEqual([kw["description"] for kw in dropdowns], ["A", "B", "C", "D"])
        self.assertEqual([kw["value"] for kw in dropdowns], ["entity", "category", None, None])
        self.assertEqual(dropdowns[0]["options"][0], ("—", None))
        html = [w for w in box.args[0] if type(w).__name__ == "VBox"]
        self.assertEqual(len(html), 4, "every column has its note under the dropdown")
        self.assertIn("category (low confidence): 120 distinct", html[0].args[0][1].args[0])
        self.assertEqual(type(box.args[0][-2]).__name__, "Button")


class HeadlessRuleTest(unittest.TestCase):
    """EXAKIT_NB_AUTO_APPROVE: 1 writes nothing new; force approves the proposal."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.home.name})
        env.start()
        self.addCleanup(env.stop)
        self.approve = mock.patch.object(Draft, "approve", autospec=True, side_effect=approve_as_dict)
        self.approve.start()
        self.addCleanup(self.approve.stop)
        self.opened = mock.patch.object(role_picker, "dataset", return_value="the approved dataset")
        self.opened.start()
        self.addCleanup(self.opened.stop)
        self.checked = mock.patch.object(role_picker, "checked", return_value="the draft as a dataset")
        self.checked.start()
        self.addCleanup(self.checked.stop)

    def show(self, review, mode):
        with mock.patch.dict(os.environ, {"EXAKIT_NB_AUTO_APPROVE": mode}), redirect_stdout(io.StringIO()) as out:
            self.assertIs(review.show(), review)
        return out.getvalue()

    def test_equal_roles_are_used_as_approved_and_nothing_is_written(self):
        review = RoleReview(draft(), object())
        with mock.patch.object(role_picker, "approved_roles", return_value=({"entity": "A", "category": "B"}, 1)):
            out = self.show(review, "1")
        self.assertEqual(review.headless, "unchanged")
        self.assertIn("v1, already approved with these roles: nothing is written", out)
        Draft.approve.assert_not_called()
        self.assertEqual(review.dataset(), "the approved dataset")

    def test_different_roles_stay_a_draft_that_the_next_cell_gets(self):
        review = RoleReview(draft(), object())
        with mock.patch.object(role_picker, "approved_roles", return_value=({"entity": "A", "category": "C"}, 2)):
            out = self.show(review, "1")
        self.assertEqual(review.headless, "draft")
        self.assertIn("leaves example a draft: its roles differ from the approved v2 (category: C -> B)", out)
        self.assertIn("EXAKIT_NB_AUTO_APPROVE=force", out)
        Draft.approve.assert_not_called()
        self.assertEqual(review.dataset(), "the draft as a dataset")
        raw = json.loads(role_picker.checked.call_args.args[1])
        self.assertEqual((raw["status"], raw["slots"]["category"]), ("draft", "B"))

    def test_nothing_approved_yet_stays_a_draft(self):
        review = RoleReview(draft(), object())
        with mock.patch.object(role_picker, "approved_roles", return_value=(None, None)):
            out = self.show(review, "1")
        self.assertIn("nothing is approved for it yet", out)
        Draft.approve.assert_not_called()

    def test_force_approves_the_proposal(self):
        review = RoleReview(draft(), object())
        with mock.patch.object(role_picker, "approved_roles", return_value=({"entity": "A", "category": "C"}, 2)):
            out = self.show(review, "force")
        self.assertEqual(review.headless, "approved")
        self.assertIn("force: the headless run approves", out)
        Draft.approve.assert_called_once()
        self.assertEqual(review.dataset()["slots"]["entity"], "A")

    def test_approved_roles_reads_the_store_then_the_shipped_descriptor(self):
        with mock.patch.dict(os.environ, {"EXAKIT_NB_DATASETS": str(ROOT / "data" / "datasets")}):
            roles, version = role_picker.approved_roles("esophageal_posts")
            self.assertEqual((roles["entity"], roles["label"], version), ("SOURCE_DOMAIN", "IS_NEGATIVE", 1))
            self.assertEqual(role_picker.approved_roles("no_such_set"), (None, None))


class FakeMarimo:
    """What role_picker uses of marimo: mo.ui.dictionary (a base class with a settable value), dropdown, run_button,
    mo.stop (raises), mo.md, mo.output.append, running_in_notebook."""

    class Stop(BaseException):
        pass

    def __init__(self):
        fake = self

        class Element:
            def __init__(self, *args, **kwargs):
                self.args, self.kwargs = args, kwargs

        class Dictionary(Element):
            def __init__(self, elements, *, label="", on_change=None):
                super().__init__(elements, label=label)
                self.elements = elements
                self.value = {key: (value.value if isinstance(value, Dictionary) else value.kwargs.get("value"))
                              for key, value in elements.items()}

        class RunButton(Element):
            pass

        self.ui = types.SimpleNamespace(dictionary=Dictionary, dropdown=Element, run_button=RunButton)
        self.output = types.SimpleNamespace(append=lambda element: fake.shown.append(element))
        self.shown, self.stopped = [], []

    def md(self, text):
        return text

    def stop(self, predicate, output=None):
        if predicate:
            self.stopped.append(output)
            raise FakeMarimo.Stop(output)

    def running_in_notebook(self):
        return True


class MarimoTest(unittest.TestCase):
    def test_the_review_is_a_dictionary_of_dropdowns_with_a_run_button(self):
        mo = FakeMarimo()
        with redirect_stdout(io.StringIO()):
            review = marimo_review(mo, draft(), object()).show()
        self.assertIsInstance(review, mo.ui.dictionary)
        self.assertIs(mo.shown[0], review, "the element is the cell's output")
        roles, button = review.elements["roles"], review.elements["approve"]
        self.assertEqual(list(roles.elements), ["A", "B", "C", "D"])
        self.assertEqual([d.kwargs["value"] for d in roles.elements.values()], ["entity", "category", "—", "—"])
        self.assertIn("category (low confidence)", roles.elements["A"].kwargs["label"])
        self.assertEqual(roles.elements["A"].kwargs["options"]["—"], None)
        self.assertEqual(button.kwargs["label"], "Approve descriptor")

    def test_dataset_stops_cleanly_until_the_click_then_approves_the_choices(self):
        mo = FakeMarimo()
        with redirect_stdout(io.StringIO()):
            review = marimo_review(mo, draft(), object()).show()
        with self.assertRaises(FakeMarimo.Stop):
            review.dataset()
        self.assertIn("Approve descriptor", mo.stopped[0])
        review.value = {"roles": {"A": "entity", "B": None, "C": "text", "D": None}, "approve": True}
        with mock.patch.object(Draft, "approve", autospec=True, side_effect=approve_as_dict):
            result = review.dataset()
        self.assertEqual(result["slots"]["text"], "C")
        self.assertIsNone(result["slots"]["category"])
        review.value = {"roles": {"A": "entity", "B": None, "C": "text", "D": None}, "approve": False}
        self.assertIs(review.dataset(), result, "a later change of a dropdown keeps the approval")

    def test_headless_in_marimo_follows_the_same_rule(self):
        mo = FakeMarimo()
        with mock.patch.dict(os.environ, {"EXAKIT_NB_AUTO_APPROVE": "1"}), \
                mock.patch.object(role_picker, "approved_roles", return_value=(None, None)), redirect_stdout(io.StringIO()):
            review = marimo_review(mo, draft(), object()).show()
        self.assertEqual((review.headless, mo.shown), ("draft", []))

    @unittest.skipUnless(__import__("importlib").util.find_spec("marimo"), "marimo is not installed in this Python")
    def test_the_real_marimo_element_builds_outside_a_notebook(self):
        import marimo as mo
        with redirect_stdout(io.StringIO()):
            review = marimo_review(mo, draft(), object())
        self.assertIsInstance(review, mo.ui.dictionary)
        self.assertEqual(set(review.value), {"roles", "approve"})
        self.assertEqual(review.value["roles"], {"A": "entity", "B": "category", "C": None, "D": None})


class WorkflowLogTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        env = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.home.name}, clear=False)
        env.start()
        self.addCleanup(env.stop)
        os.environ.pop("EXAKIT_WORKFLOW_ID", None)
        _kit.SESSION.pop("workflow_id", None)
        self.addCleanup(lambda: (_kit.SESSION.pop("workflow_id", None), os.environ.pop("EXAKIT_WORKFLOW_ID", None)))

    def events(self, workflow_id):
        path = Path(self.home.name) / "workflows" / f"{workflow_id}.jsonl"
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]

    def test_a_draft_and_an_approval_are_lines_in_the_active_workflow(self):
        wf = __import__("importlib").import_module("exakit_nb.workflow")   # the package exports workflow() under the module's name
        with redirect_stdout(io.StringIO()):
            wid = wf.workflow("test")
            with mock.patch.object(role_picker, "describe", return_value=draft()), \
                    mock.patch.object(role_picker, "_marimo", return_value=None), \
                    mock.patch.object(Draft, "approve", autospec=True, side_effect=approve_as_dict):
                review = review_roles(object(), LoadedTable("example", TABLE, Path("not-a-file")))
                review.approve()
        kinds = [e["kind"] for e in self.events(wid)]
        self.assertEqual(kinds, ["start", "describe.draft"])             # the approval line is Draft.approve's own
        drafted = self.events(wid)[1]
        self.assertEqual((drafted["descriptor_id"], drafted["roles"]["entity"]), ("example", "A"))
        self.assertEqual(["date", "label", "text"], drafted["missing"])


class OpenByNameTest(unittest.TestCase):
    """review_roles(conn, "<one assignment>"): a described dataset is opened as it is; a data file with no descriptor
    beside it is loaded into MY_DATA.<STEM>, profiled and its draft saved beside it."""

    def test_an_approved_dataset_is_settled_with_nothing_to_review(self):
        ds = types.SimpleNamespace(id="esophageal_posts", fact_table="ESOPHAGEAL.ESOPHAGEAL_POSTS", status="approved", version=1)
        with mock.patch.object(role_picker, "dataset", return_value=ds), mock.patch.object(role_picker, "describe") as profiled, \
                redirect_stdout(io.StringIO()) as out:
            review = review_roles(object(), "esophageal_posts")
        profiled.assert_not_called()
        self.assertIn("v1 is approved: nothing to review", out.getvalue())
        self.assertIs(review.dataset(), ds)

    def test_a_described_draft_is_handed_on_with_the_way_to_approve_it(self):
        ds = types.SimpleNamespace(id="my_data_sales", fact_table="MY_DATA.SALES", status="draft", version=1)
        with mock.patch.object(role_picker, "dataset", return_value=ds), redirect_stdout(io.StringIO()) as out:
            review = review_roles(object(), "sales.descriptor.yaml")
        self.assertIn("exakit describe my_data_sales --approve", out.getvalue())
        self.assertIn("OWN_FILE", out.getvalue())
        self.assertIs(review.dataset(draft_ok=True), ds)

    def test_a_file_without_roles_is_loaded_profiled_and_its_draft_saved_beside_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "new sales-2026.csv"
            source.write_text("A,B,C,D\n1,2,3,4\n", encoding="utf-8")
            loaded = LoadedTable("my_data_new_sales_2026", "MY_DATA.NEW_SALES_2026", source)
            with mock.patch("exakit_nb.own_file.load_own_file", return_value=loaded) as load, \
                    mock.patch.object(role_picker, "describe", return_value=draft()) as profiled, \
                    mock.patch.object(role_picker, "_marimo", return_value=None), \
                    mock.patch.object(Draft, "save", autospec=True, side_effect=lambda this, path: Path(path).write_text("x")) as save, \
                    redirect_stdout(io.StringIO()) as out:
                review = review_roles(object(), str(source))
            self.assertEqual(load.call_args.args[:2], (source, "MY_DATA.NEW_SALES_2026"))
            self.assertEqual(profiled.call_args.kwargs["id"], "my_data_new_sales_2026")
            self.assertEqual(save.call_args.args[1], source.parent / "new sales-2026.descriptor.yaml")
            self.assertIn("Proposed roles (a draft) saved beside", out.getvalue())
            self.assertIn("OWN_FILE", out.getvalue())
            self.assertEqual(review.file, source)
            with mock.patch.object(role_picker, "dataset", return_value="opened by the file") as opened:
                self.assertEqual(review.dataset(draft_ok=True), "opened by the file")
            self.assertEqual(opened.call_args.args[1], source)

    def test_the_default_table_is_a_plain_sql_name(self):
        self.assertEqual(role_picker._default_table(Path("~/x/2026 sales.csv")), "MY_DATA.T_2026_SALES")
        self.assertEqual(role_picker._default_table(Path("transactions.parquet")), "MY_DATA.TRANSACTIONS")


class FileWithoutRolesTest(unittest.TestCase):
    def test_loads_file_then_returns_table_for_profiler(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "new-data.csv"
            source.write_text("A,B\n1,2\n", encoding="utf-8")
            with mock.patch("exakit_nb.own_file._comment", return_value=None), \
                    mock.patch("exakit_nb.own_file._read", return_value=object()), \
                    mock.patch("exakit_nb.own_file._prepare", return_value=[("A", "DECIMAL(18,0)")]) as prepare, \
                    mock.patch("exakit_nb.own_file._load"):
                loaded = load_own_file(source, "S.T", conn=object())
            self.assertIsInstance(loaded, LoadedTable)
            self.assertEqual((loaded.id, loaded.fact_table), ("s_t", "S.T"))
            self.assertIsNone(prepare.call_args.args[1])

    def test_approval_writes_descriptor_beside_own_file_for_reopen(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "my-data.csv"
            source.write_text("A,B\n1,2\n", encoding="utf-8")
            review = RoleReview(draft(), object(), source)
            with mock.patch.object(Draft, "approve", autospec=True, return_value=object()), \
                    mock.patch.object(Draft, "save", autospec=True) as save, redirect_stdout(io.StringIO()):
                review.approve()
            self.assertEqual(save.call_args.args[1], source.parent / "my-data.descriptor.yaml")


if __name__ == "__main__":
    unittest.main()
