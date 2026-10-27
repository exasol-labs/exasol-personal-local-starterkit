"""exakit_nb.handoff: the handoff explore writes for the ML Engineer (DS-3 -> ML-3, design 4).

    python3 -m unittest tests.test_handoff

What it pins, on a fake connection and a temporary EXAKIT_HOME: the record's shape (design 4's keys); the feature
view SQL built from the roles with every identifier double-quoted - category one-hot over the top-20 values plus
OTHER (values from one query, quotes escaped), date parts and days since the first date, entity frequency, text
LENGTH only (TF-IDF deferred and recorded as such); the training SQL's reproducible window split; the label's
positive class from the evidence, from one query when there is none, or the value given; a missing date role turns a
time split random with the reason; the file's path and mode (0600 in a 0700 folder) and that it holds no credential;
read_handoff by path, by <id>-v<n> and by id (highest version); staleness on the version, on the digest and on the
data; the workflow log's handoff line when a workflow is active and no line without one.
"""

from __future__ import annotations

import io
import json
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))

import importlib  # noqa: E402

import exakit_nb  # noqa: E402
from exakit_nb import _kit, descriptor_rules as rules  # noqa: E402
from exakit_nb.dataset import Dataset  # noqa: E402

handoff = importlib.import_module("exakit_nb.handoff")
wf = importlib.import_module("exakit_nb.workflow")

SYNTHETIC = """schema_version: 2
id: sensor_readings
fact_table: LAB.READINGS
version: 3
status: approved
owner: tester
created: 2026-10-27T10:00:00Z
roles:
  entity:   {table: LAB.READINGS, column: DEVICE}
  category: {table: LAB.READINGS, column: KIND}
  date:     {table: LAB.READINGS, column: TAKEN_ON}
  label:    {table: LAB.READINGS, column: ALARM}
  text:
    - {table: LAB.READINGS, column: NOTE}
    - {table: LAB.READINGS, column: OPERATOR_COMMENT}
"""

NO_DATE = """schema_version: 2
id: sensor_readings
fact_table: LAB.READINGS
version: 1
status: approved
owner: tester
created: 2026-10-27T10:00:00Z
roles:
  entity:   {table: LAB.READINGS, column: DEVICE}
  category: {table: LAB.READINGS, column: KIND}
  label:    {table: LAB.READINGS, column: ALARM}
  text:
    - {table: LAB.READINGS, column: NOTE}
missing:
  - {role: date, reason: "no column parses as a date"}
"""

WITH_EVIDENCE = SYNTHETIC + """evidence:
  label: {column: ALARM, top: [{value: "0", share: 0.9}, {value: "1", share: 0.1}]}
"""


class FakeResult:
    def __init__(self, rows):
        self.rows = rows

    def fetchall(self):
        return self.rows


class FakeConn:
    """Answers the three statements the handoff runs: the top category values, the COUNT/MIN/MAX summary and the label
    shares - by the shape of the statement, so the SQL itself is pinned here too."""

    def __init__(self, categories=("temp", "O'Neil", "humidity"), rows=120, date_min="2026-01-01", date_max="2026-03-31",
                 labels=((" 1", 10), ("0", 110))):
        self.categories, self.rows, self.date_min, self.date_max, self.labels = list(categories), rows, date_min, date_max, list(labels)
        self.statements = []

    def session_id(self):
        return 42

    def execute(self, statement, params=None):
        self.statements.append(statement)
        if "GROUP BY 1 ORDER BY N DESC" in statement:
            return FakeResult([(value, 100 - n) for n, value in enumerate(self.categories)])
        if statement.startswith("SELECT COUNT(*), MIN("):
            return FakeResult([(self.rows, self.date_min, self.date_max)])
        if statement.startswith("SELECT COUNT(*), NULL"):
            return FakeResult([(self.rows, None, None)])
        if "ORDER BY 2, 1" in statement:
            return FakeResult(self.labels)
        if "CURRENT_STATEMENT" in statement:
            return mock.Mock(fetchval=lambda: 7)
        raise AssertionError(f"unexpected statement: {statement}")


def _ds(text: str = SYNTHETIC, file_digest: str = "a" * 64, table_digest: str | None = None) -> Dataset:
    descriptor = rules.parse_descriptor(text)
    if table_digest is not None:
        descriptor = rules.Descriptor(**{**{f: getattr(descriptor, f) for f in descriptor.__slots__}, "digest": table_digest})
    return Dataset(descriptor.id, Path("descriptor.yaml"), file_digest, descriptor)


class HandoffCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / "kit"
        self.env = mock.patch.dict(os.environ, {"EXAKIT_HOME": str(self.home)})
        self.env.start()
        os.environ.pop(wf.ENV_VARIABLE, None)
        _kit.SESSION.clear()

    def tearDown(self):
        self.env.stop()
        _kit.SESSION.clear()
        self.tmp.cleanup()


class RecordTest(HandoffCase):
    def test_the_record_has_the_keys_of_design_4(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        for key in ("workflow_id", "descriptor", "data_digest", "written_at", "written_by", "feature_view", "label", "split",
                    "training_sql", "input_schema", "output_schema"):
            self.assertIn(key, record)
        self.assertEqual(record["descriptor"], {"id": "sensor_readings", "version": 3, "digest": "sha256:" + "a" * 64,
                                                "digest_kind": "file", "source": None, "status": "approved",
                                                "fact_table": "LAB.READINGS"})
        self.assertEqual(record["feature_view"]["name"], "STARTER_KIT.SENSOR_READINGS_FEATURES_V3")
        self.assertEqual(record["written_by"], "01_explore")
        self.assertIsNone(record["workflow_id"])
        self.assertEqual(record["output_schema"], [{"name": "label", "type": "BOOLEAN"}, {"name": "p", "type": "DOUBLE"}])
        self.assertEqual([f["name"] for f in record["input_schema"]],
                         ["DATE_YEAR", "DATE_MONTH", "DATE_DOW", "DATE_DAYS_SINCE_MIN", "CAT_TEMP", "CAT_O_NEIL", "CAT_HUMIDITY",
                          "CAT_OTHER", "ENTITY_FREQ", "TEXT_LEN_NOTE", "TEXT_LEN_OPERATOR_COMMENT"])
        self.assertTrue(all(f["type"] == "DECIMAL(18,0)" for f in record["input_schema"]))
        self.assertEqual(record["rows"], 120)
        self.assertEqual(record["data_digest_kind"], "rowcount+date_span")
        self.assertRegex(record["data_digest"], r"^sha256:[0-9a-f]{64}$")

    def test_the_table_digest_is_used_when_the_descriptor_has_one(self):
        """The descriptor's digest is the one it was approved on; the data digest is the table's as it is now
        (Dataset.current_table_digest, when the package has it), else that same approval-time digest."""
        with mock.patch.object(Dataset, "current_table_digest", create=True, return_value="sha256:" + "e" * 64) as now:
            record = handoff.handoff_from(FakeConn(), _ds(table_digest="sha256:" + "b" * 64))
        self.assertEqual((record["descriptor"]["digest"], record["descriptor"]["digest_kind"]), ("sha256:" + "b" * 64, "table"))
        self.assertEqual((record["data_digest"], record["data_digest_kind"]), ("sha256:" + "e" * 64, "table"))
        self.assertEqual(now.call_count, 1)
        with mock.patch.object(Dataset, "current_table_digest", create=True, side_effect=RuntimeError("no service")):
            record = handoff.handoff_from(FakeConn(), _ds(table_digest="sha256:" + "b" * 64))
        self.assertEqual((record["data_digest"], record["data_digest_kind"]), ("sha256:" + "b" * 64, "table"))

    def test_the_data_digest_follows_rows_and_dates(self):
        one = handoff.handoff_from(FakeConn(rows=120), _ds())["data_digest"]
        same = handoff.handoff_from(FakeConn(rows=120), _ds())["data_digest"]
        more = handoff.handoff_from(FakeConn(rows=121), _ds())["data_digest"]
        later = handoff.handoff_from(FakeConn(date_max="2026-04-01"), _ds())["data_digest"]
        self.assertEqual(one, same)
        self.assertNotEqual(one, more)
        self.assertNotEqual(one, later)


class FeatureViewTest(HandoffCase):
    def test_the_view_sql_is_built_from_the_roles_with_every_identifier_quoted(self):
        conn = FakeConn()
        view = handoff.handoff_from(conn, _ds())["feature_view"]
        sql = view["sql"]
        self.assertTrue(sql.startswith('CREATE OR REPLACE VIEW "STARTER_KIT"."SENSOR_READINGS_FEATURES_V3" AS\nSELECT\n'))
        self.assertTrue(sql.endswith('\nFROM "LAB"."READINGS"'))
        self.assertIn('    "TAKEN_ON",\n    "ALARM",\n', sql)
        self.assertIn('EXTRACT(YEAR FROM "TAKEN_ON") AS "DATE_YEAR"', sql)
        self.assertIn('EXTRACT(MONTH FROM "TAKEN_ON") AS "DATE_MONTH"', sql)
        self.assertIn('TO_NUMBER(TO_CHAR("TAKEN_ON", \'ID\')) AS "DATE_DOW"', sql)
        self.assertIn('DAYS_BETWEEN("TAKEN_ON", DATE \'2026-01-01\') AS "DATE_DAYS_SINCE_MIN"', sql)
        self.assertIn('CASE WHEN CAST("KIND" AS VARCHAR(2000)) = \'temp\' THEN 1 ELSE 0 END AS "CAT_TEMP"', sql)
        self.assertIn("= 'O''Neil' THEN 1 ELSE 0 END AS \"CAT_O_NEIL\"", sql, "a quote in a value is doubled")
        self.assertIn('NOT IN (\'temp\', \'O\'\'Neil\', \'humidity\') THEN 1 ELSE 0 END AS "CAT_OTHER"', sql)
        self.assertIn('COUNT(*) OVER (PARTITION BY "DEVICE") AS "ENTITY_FREQ"', sql)
        self.assertIn('LENGTH(COALESCE("NOTE", \'\')) AS "TEXT_LEN_NOTE"', sql)
        self.assertIn('LENGTH(COALESCE("OPERATOR_COMMENT", \'\')) AS "TEXT_LEN_OPERATOR_COMMENT"', sql)
        for name in ("DEVICE", "KIND", "TAKEN_ON", "ALARM", "NOTE", "OPERATOR_COMMENT", "LAB", "READINGS"):
            with self.subTest(identifier=name):
                self.assertNotRegex(sql, rf"(?<![\"A-Z_]){name}(?![\"A-Z_])", f"{name} appears unquoted")
        self.assertNotIn("TFIDF", sql.upper().replace("-", ""))
        self.assertEqual(view["categories"], [{"value": "temp", "column": "CAT_TEMP"}, {"value": "O'Neil", "column": "CAT_O_NEIL"},
                                              {"value": "humidity", "column": "CAT_HUMIDITY"}])
        self.assertEqual(view["date_min"], "2026-01-01")
        self.assertTrue(any("token flags" in line for line in view["deferred"]), "the SQL token flags are recorded as deferred")
        top = next(s for s in conn.statements if "GROUP BY 1 ORDER BY N DESC" in s)
        self.assertEqual(top, 'SELECT CAST("KIND" AS VARCHAR(2000)) AS VALUE_, COUNT(*) AS N FROM "LAB"."READINGS" '
                              'WHERE "KIND" IS NOT NULL GROUP BY 1 ORDER BY N DESC, 1 LIMIT 20')
        self.assertEqual(view["category_values_sql"], top)

    def test_the_top_values_are_capped_at_twenty_and_names_never_collide(self):
        values = [f"v{n}" for n in range(25)]
        view = handoff.handoff_from(FakeConn(categories=values), _ds())["feature_view"]
        self.assertEqual(len(view["categories"]), 25, "the fake answered 25; the query itself carries LIMIT 20")
        self.assertIn("LIMIT 20", view["category_values_sql"])
        view = handoff.handoff_from(FakeConn(categories=("a b", "a_b", "A-B")), _ds())["feature_view"]
        self.assertEqual([c["column"] for c in view["categories"]], ["CAT_A_B", "CAT_A_B_2", "CAT_A_B_3"])

    def test_the_training_sql_splits_by_a_window_over_the_date(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        self.assertEqual(record["training_sql"],
                         'SELECT F.*,\n       CASE WHEN PERCENT_RANK() OVER (ORDER BY "TAKEN_ON") < 0.8 THEN \'train\' ELSE \'test\' '
                         'END AS "SPLIT_"\nFROM "STARTER_KIT"."SENSOR_READINGS_FEATURES_V3" F\nWHERE "ALARM" IS NOT NULL\n'
                         'ORDER BY "TAKEN_ON"')
        self.assertEqual(record["split"]["kind"], "time")
        self.assertEqual(record["split"]["date_column"], "TAKEN_ON")
        self.assertEqual(record["split"]["train_share"], 0.8)
        self.assertIn("0.7 THEN", handoff.handoff_from(FakeConn(), _ds(), train_share=0.7)["training_sql"])

    def test_a_missing_date_role_makes_the_split_random_with_the_reason(self):
        record = handoff.handoff_from(FakeConn(), _ds(NO_DATE))
        split = record["split"]
        self.assertEqual(split["kind"], "random")
        self.assertIn("no column parses as a date", split["reason"])
        self.assertIsNone(split["date_column"])
        self.assertIn('PERCENT_RANK() OVER (ORDER BY HASH_MD5(', record["training_sql"])
        self.assertIn('COALESCE(CAST("DEVICE" AS VARCHAR(2000)), \'\')', record["training_sql"])
        names = [f["name"] for f in record["input_schema"]]
        self.assertFalse(any(n.startswith("DATE_") for n in names), names)
        self.assertNotIn("TAKEN_ON", record["feature_view"]["sql"])
        self.assertEqual(record["data_digest_kind"], "rowcount")

    def test_an_explicit_random_split_is_kept(self):
        split = handoff.handoff_from(FakeConn(), _ds(), split="random")["split"]
        self.assertEqual(split["kind"], "random")
        self.assertNotIn("reason", split)
        with self.assertRaises(ValueError):
            handoff.handoff_from(FakeConn(), _ds(), split="stratified")
        with self.assertRaises(ValueError):
            handoff.handoff_from(FakeConn(), _ds(), train_share=1.5)


class LabelTest(HandoffCase):
    def test_the_positive_class_is_the_minority_from_the_evidence(self):
        label = handoff.handoff_from(FakeConn(), _ds(WITH_EVIDENCE))["label"]
        self.assertEqual(label, {"column": "ALARM", "positive": "1", "positive_from": "evidence"})

    def test_without_evidence_one_query_finds_the_minority_class(self):
        conn = FakeConn(labels=((" 1", 10), ("0", 110)))
        label = handoff.handoff_from(conn, _ds())["label"]
        self.assertEqual(label, {"column": "ALARM", "positive": "1", "positive_from": "query"})
        self.assertTrue(any(s.startswith('SELECT CAST("ALARM" AS VARCHAR(100)), COUNT(*) FROM "LAB"."READINGS"') for s in conn.statements))

    def test_the_default_is_true_and_a_given_value_wins(self):
        self.assertEqual(handoff.handoff_from(FakeConn(labels=()), _ds())["label"]["positive"], "true")
        label = handoff.handoff_from(FakeConn(), _ds(WITH_EVIDENCE), label="0")["label"]
        self.assertEqual((label["positive"], label["positive_from"]), ("0", "given"))


class FileTest(HandoffCase):
    def test_write_handoff_writes_the_file_0600_in_a_0700_folder_under_the_kit_home(self):
        path = handoff.write_handoff(FakeConn(), _ds())
        self.assertEqual(path, self.home / "handoffs" / "sensor_readings-v3.json")
        self.assertTrue(path.is_file())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        record = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(record["descriptor"]["version"], 3)
        self.assertEqual([p.name for p in path.parent.iterdir()], ["sensor_readings-v3.json"], "no temporary file is left")

    def test_the_file_holds_no_address_and_no_credential(self):
        path = handoff.write_handoff(FakeConn(), _ds())
        text = path.read_text(encoding="utf-8")
        for needle in ("127.0.0.1", "localhost", ":8563", "password", "dsn=", "://", "LANGFUSE_SECRET"):
            with self.subTest(needle=needle):
                self.assertNotIn(needle, text)
        source = (ROOT / "notebook" / "package" / "exakit_nb" / "handoff.py").read_text(encoding="utf-8")
        for needle in ("127.0.0.1", "localhost", ":8563", "password=", "dsn="):
            with self.subTest(file="handoff.py", needle=needle):
                self.assertNotIn(needle, source)

    def test_read_handoff_by_path_by_version_and_by_id(self):
        handoff.write_handoff(FakeConn(), _ds(SYNTHETIC.replace("version: 3", "version: 2")))
        path = handoff.write_handoff(FakeConn(), _ds())
        self.assertEqual(handoff.read_handoff(path)["descriptor"]["version"], 3)
        self.assertEqual(handoff.read_handoff(str(path))["descriptor"]["version"], 3)
        self.assertEqual(handoff.read_handoff("sensor_readings-v2")["descriptor"]["version"], 2)
        self.assertEqual(handoff.read_handoff("sensor_readings")["descriptor"]["version"], 3, "the highest version")
        self.assertEqual(exakit_nb.read_handoff("sensor_readings")["feature_view"]["name"], "STARTER_KIT.SENSOR_READINGS_FEATURES_V3")

    def test_a_missing_handoff_says_how_to_make_one(self):
        with self.assertRaises(FileNotFoundError) as caught:
            handoff.read_handoff("pharma_trials")
        self.assertIn("handoff_from", str(caught.exception))
        with self.assertRaises(FileNotFoundError):
            handoff.read_handoff("pharma_trials-v9")
        with self.assertRaises(FileNotFoundError):
            handoff.read_handoff(self.home / "nowhere.json")
        bad = self.home / "bad.json"
        bad.parent.mkdir(parents=True, exist_ok=True)
        bad.write_text('{"descriptor": {}}', encoding="utf-8")
        with self.assertRaises(ValueError):
            handoff.read_handoff(bad)

    def test_rewriting_replaces_the_file_whole(self):
        first = handoff.write_handoff(FakeConn(rows=120), _ds())
        second = handoff.write_handoff(FakeConn(rows=200), _ds())
        self.assertEqual(first, second)
        self.assertEqual(json.loads(second.read_text(encoding="utf-8"))["rows"], 200)


class StaleTest(HandoffCase):
    def test_a_fresh_handoff_is_not_stale(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        self.assertIsNone(handoff.handoff_is_stale(FakeConn(), record, _ds()))
        self.assertIsNone(handoff.handoff_is_stale(None, record, _ds()), "without a connection the data is not checked")

    def test_a_new_descriptor_version_is_stale_with_the_fix(self):
        record = handoff.handoff_from(FakeConn(), _ds(SYNTHETIC.replace("version: 3", "version: 2")))
        reason = handoff.handoff_is_stale(FakeConn(), record, _ds())
        self.assertEqual(reason, "descriptor sensor_readings changed since the handoff (v2 → v3): re-run 01_explore or build "
                                 "the handoff: handoff = exakit.nb.handoff_from(ds)")

    def test_a_changed_descriptor_digest_at_the_same_version_is_stale(self):
        record = handoff.handoff_from(FakeConn(), _ds(file_digest="a" * 64))
        reason = handoff.handoff_is_stale(FakeConn(), record, _ds(file_digest="c" * 64))
        self.assertIn("descriptor sensor_readings changed since the handoff (v3, its file digest differs)", reason)
        self.assertIn("exakit.nb.handoff_from(ds)", reason)
        with mock.patch.object(Dataset, "current_table_digest", create=True, return_value="sha256:" + "b" * 64):
            record = handoff.handoff_from(FakeConn(), _ds(table_digest="sha256:" + "b" * 64))
            self.assertIsNone(handoff.handoff_is_stale(FakeConn(), record, _ds(table_digest="sha256:" + "b" * 64)))
            self.assertIn("table digest differs", handoff.handoff_is_stale(FakeConn(), record, _ds(table_digest="sha256:" + "d" * 64)))
        with mock.patch.object(Dataset, "current_table_digest", create=True, return_value="sha256:" + "f" * 64):
            reason = handoff.handoff_is_stale(FakeConn(), record, _ds(table_digest="sha256:" + "b" * 64))
        self.assertIn("the data of LAB.READINGS changed since the handoff", reason, "the table's digest now differs from the handoff's")

    def test_changed_data_is_stale(self):
        record = handoff.handoff_from(FakeConn(rows=120), _ds())
        reason = handoff.handoff_is_stale(FakeConn(rows=121), record, _ds())
        self.assertIn("the data of LAB.READINGS changed since the handoff", reason)

    def test_another_descriptors_handoff_is_stale(self):
        record = handoff.handoff_from(FakeConn(), _ds())
        reason = handoff.handoff_is_stale(FakeConn(), record, _ds(SYNTHETIC.replace("id: sensor_readings", "id: other_readings")))
        self.assertIn("is for descriptor sensor_readings, not other_readings", reason)


class WorkflowLogTest(HandoffCase):
    def test_an_active_workflow_gets_a_handoff_line(self):
        with redirect_stdout(io.StringIO()):
            wid = wf.workflow("handoff-test")
        path = handoff.write_handoff(FakeConn(), _ds())
        events = wf.read_log(wid)
        lines = [e for e in events if e["kind"] == wf.HANDOFF]
        self.assertEqual(len(lines), 1)
        line = lines[0]
        self.assertEqual((line["path"], line["descriptor_id"], line["descriptor_version"], line["feature_view"]),
                         (str(path), "sensor_readings", 3, "STARTER_KIT.SENSOR_READINGS_FEATURES_V3"))
        self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["workflow_id"], wid)

    def test_a_given_workflow_id_is_recorded_as_is(self):
        record = handoff.handoff_from(FakeConn(), _ds(), workflow_id="wf-20261027-abc123")
        self.assertEqual(record["workflow_id"], "wf-20261027-abc123")

    def test_nothing_is_logged_without_a_workflow(self):
        handoff.write_handoff(FakeConn(), _ds())
        self.assertFalse((self.home / "workflows").exists())


class ExportTest(unittest.TestCase):
    def test_the_package_exports_the_four_calls(self):
        for name in ("write_handoff", "read_handoff", "handoff_from", "handoff_is_stale"):
            self.assertIn(name, exakit_nb.__all__)
            self.assertTrue(callable(getattr(exakit_nb, name)))
        self.assertEqual(exakit_nb.__all__, sorted(exakit_nb.__all__, key=str.lower), "__all__ stays alphabetical")


if __name__ == "__main__":
    unittest.main()
