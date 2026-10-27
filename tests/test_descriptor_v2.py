"""(run: python3 tests/test_descriptor_v2.py) Descriptor schema_version 2 (design §2.1, AC-DS2.5's gating half): the
reader takes a version-1 file as approved by the kit and a version-2 file with its record; each record key that is
missing or wrong is a problem naming the key; an unknown schema_version is one line; a Dataset resolves its
descriptor in order (a path, the kit's store under EXAKIT_HOME, the shipped file) and says which; a draft is refused
by require_approved with how to approve it; the store's versions list; save_descriptor writes version 2; and the
approve flow (AC-DS2.5 whole): a draft written by describe()+save() is refused by require_approved("training") and,
after Draft.approve(), the Dataset read back from the store is approved, with the table digest."""

from __future__ import annotations

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "notebook" / "package"))
sys.path.insert(0, str(ROOT))

import exakit_nb  # noqa: E402
from exakit_nb import descriptor_rules as rules  # noqa: E402
from exakit_nb import descriptor_store as store  # noqa: E402
from exakit_nb import own_file  # noqa: E402
from exakit_nb.dataset import Dataset, DescriptorNotApproved  # noqa: E402

ROLES = """roles:
  entity:   {table: LAB.READINGS, column: DEVICE}
  category: {table: LAB.READINGS, column: KIND}
  date:     {table: LAB.READINGS, column: TAKEN_ON}
  label:    {table: LAB.READINGS, column: ALARM}
  text:
    - {table: LAB.READINGS, column: NOTE}
"""
V1 = "schema_version: 1\nid: sensor_readings\nfact_table: LAB.READINGS\n" + ROLES
V2_HEAD = """schema_version: 2
id: sensor_readings
fact_table: LAB.READINGS
source: "file:/data/readings.csv"
version: 3
status: approved
owner: dana
created: 2026-10-27T10:12:03Z
digest: "sha256:abc123"
drafted_by: profile
"""
V2 = V2_HEAD + ROLES + """evidence:
  entity: {column: DEVICE, type: VARCHAR, null_rate: 0.0, distinct: 42, distinct_ratio: 0.21, score: 0.83, runner_up: {column: KIND, score: 0.41}}
  date:
    column: TAKEN_ON
    type: DATE
    parse_rate: 1.0
notes:
  DEVICE: "The sensor that took the reading."
missing: []
"""
COLUMNS = ["LAB.READINGS." + c for c in ("DEVICE", "KIND", "TAKEN_ON", "ALARM", "NOTE")]


class FakeResult:
    def __init__(self, rows):
        self.rows = rows

    def fetchall(self):
        return self.rows


class FakeConn:
    def __init__(self, columns=COLUMNS):
        self.columns = columns

    def execute(self, statement):
        if "EXA_ALL_COLUMNS" in statement:
            return FakeResult([("EXAKIT_NB_COLUMNS",), *[(c,) for c in self.columns]])
        return FakeResult([("0",), ("1",)])


class ReaderTest(unittest.TestCase):
    """Both schema versions read; a version-1 file is the kit's approved shape, a version-2 file its own record."""

    def test_a_version_1_file_reads_as_approved_by_the_kit(self):
        d = rules.parse_descriptor(V1)
        self.assertEqual((d.schema_version, d.version, d.status, d.owner, d.drafted_by), (1, 1, "approved", "kit", "shipped"))
        self.assertEqual((d.digest, d.created, d.evidence, d.notes, d.missing, d.source), (None, None, {}, {}, (), None))
        self.assertTrue(d.approved)

    def test_a_version_1_source_is_a_live_sources_alias(self):
        d = rules.parse_descriptor(V1 + "source: crm\n")
        self.assertEqual((d.source, d.live_source), ("crm", "crm"))

    def test_the_shipped_descriptors_are_version_2_approved_by_the_kit(self):
        for name in ("pharma_trials", "banking_complaints"):
            with self.subTest(dataset=name):
                d = rules.read_descriptor(ROOT / "data" / "datasets" / name)
                self.assertEqual((d.schema_version, d.version, d.status, d.owner, d.drafted_by, d.source),
                                 (2, 1, "approved", "kit", "shipped", name))
                self.assertEqual((d.digest, d.created, d.live_source), (None, "2026-10-27T00:00:00Z", None))

    def test_a_valid_version_2_file_carries_its_record(self):
        d = rules.parse_descriptor(V2)
        self.assertEqual((d.version, d.status, d.owner, d.created, d.digest, d.drafted_by),
                         (3, "approved", "dana", "2026-10-27T10:12:03Z", "sha256:abc123", "profile"))
        self.assertEqual((d.source, d.live_source), ("file:/data/readings.csv", None))
        self.assertEqual(d.evidence["entity"]["runner_up"], {"column": "KIND", "score": 0.41})
        self.assertEqual((d.evidence["entity"]["null_rate"], d.evidence["date"]["parse_rate"]), (0.0, 1.0))
        self.assertEqual(d.notes, {"DEVICE": "The sensor that took the reading."})
        self.assertEqual(d.missing, ())
        self.assertEqual(d.column("label").column, "ALARM")

    def test_a_version_2_source_names_what_the_data_is(self):
        for source, live in (("vs:SALES_DB", "SALES_DB"), ("pharma_trials", None), ('"file:/x/y.csv"', None)):
            with self.subTest(source=source):
                d = rules.parse_descriptor(V2.replace('source: "file:/data/readings.csv"', f"source: {source}"))
                self.assertEqual(d.live_source, live)
        without = rules.parse_descriptor(V2.replace('source: "file:/data/readings.csv"\n', ""))
        self.assertIsNone(without.source)

    def test_the_optional_keys_may_be_absent(self):
        d = rules.parse_descriptor(V2_HEAD.replace('digest: "sha256:abc123"\n', "").replace("drafted_by: profile\n", "") + ROLES)
        self.assertEqual((d.digest, d.drafted_by, d.evidence, d.notes, d.missing), (None, "user", {}, {}, ()))

    def test_a_json_version_2_descriptor_reads(self):
        doc = rules.load_yaml(V2)
        self.assertEqual(rules.parse_descriptor(json.dumps(doc)), rules.parse_descriptor(V2))

    def test_an_unknown_schema_version_is_one_line(self):
        for version in ("3", "0", "two", "true"):
            with self.subTest(schema_version=version):
                self.assertEqual(rules.validate_descriptor(rules.load_yaml(V2.replace("schema_version: 2", f"schema_version: {version}"))),
                                 ["schema_version must be 1 or 2"])

    def test_each_missing_record_key_is_named(self):
        for key in ("version", "status", "owner", "created"):
            with self.subTest(key=key):
                text = "\n".join(line for line in V2.splitlines() if not line.startswith(f"{key}:")) + "\n"
                problems = rules.validate_descriptor(rules.load_yaml(text))
                self.assertEqual(len(problems), 1, problems)
                self.assertTrue(problems[0].startswith(f"{key} must be"), problems)

    def test_each_wrong_record_key_is_named(self):
        cases = {"version: 3": ("version: 0", "version: three", "version: true"),
                 "status: approved": ("status: maybe", "status: 1"),
                 "owner: dana": ("owner: ''", "owner: 7"),
                 "created: 2026-10-27T10:12:03Z": ("created: yesterday", "created: 20261027", "created: 7"),
                 'digest: "sha256:abc123"': ("digest: 5", "digest: ''"),
                 "drafted_by: profile": ("drafted_by: bot", "drafted_by: 1")}
        for good, bads in cases.items():
            for bad in bads:
                with self.subTest(line=bad):
                    problems = rules.validate_descriptor(rules.load_yaml(V2.replace(good, bad)))
                    self.assertEqual(len(problems), 1, problems)
                    self.assertTrue(problems[0].startswith(f"{bad.split(':')[0]} must be"), problems)

    def test_evidence_notes_and_missing_must_have_their_shape(self):
        head = V2_HEAD + ROLES
        for text, key in ((head + "evidence: [1]\n", "evidence"), (head + "evidence:\n  entity: VARCHAR\n", "evidence"),
                          (head + "notes: yes\n", "notes"), (head + "notes:\n  DEVICE: {a: b}\n", "notes"),
                          (head + "missing: {role: date}\n", "missing"), (head + "missing:\n  - {role: when, reason: x}\n", "missing"),
                          (head + "missing:\n  - {role: date}\n", "missing")):
            with self.subTest(text=text.splitlines()[-1]):
                problems = rules.validate_descriptor(rules.load_yaml(text))
                self.assertEqual(len(problems), 1, problems)
                self.assertTrue(problems[0].startswith(key), problems)

    def test_a_role_listed_as_missing_may_be_absent_and_says_why(self):
        roles = "\n".join(line for line in ROLES.splitlines() if "date:" not in line) + "\n"
        text = V2_HEAD + roles + 'missing:\n  - {role: date, reason: "no column has >=95% parseable dates"}\n'
        d = rules.parse_descriptor(text)
        self.assertEqual(d.missing, ({"role": "date", "reason": "no column has >=95% parseable dates"},))
        self.assertNotIn("date", d.roles)
        with self.assertRaises(rules.BadInput) as caught:
            d.column("date")
        self.assertIn("no column has >=95% parseable dates", str(caught.exception))
        self.assertEqual(rules.validate_descriptor(rules.load_yaml(V2_HEAD + roles)), ["the 'date' role is missing"])
        both = V2_HEAD + ROLES + "missing:\n  - {role: date, reason: x}\n"
        self.assertEqual(rules.validate_descriptor(rules.load_yaml(both)), ["the 'date' role is both assigned and listed under missing"])

    def test_the_record_keys_need_schema_version_2(self):
        problems = rules.validate_descriptor(rules.load_yaml(V1 + "status: draft\nversion: 2\n"))
        self.assertEqual(problems, ["unknown keys: status, version (the record keys need schema_version: 2)"])

    def test_the_reader_is_one_file_in_two_places(self):
        self.assertEqual((ROOT / "notebook" / "package" / "exakit_nb" / "descriptor_rules.py").read_bytes(),
                         (ROOT / "tools" / "descriptor_rules.py").read_bytes())


class ResolutionTest(unittest.TestCase):
    """Dataset(...) by id: the kit's store (EXAKIT_HOME) before the shipped file; a path given wins; it says which."""

    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        patcher = mock.patch.dict(os.environ, {"EXAKIT_HOME": self.home.name, "EXAKIT_NB_DATASETS": str(ROOT / "data" / "datasets")})
        patcher.start()
        self.addCleanup(patcher.stop)
        self.pharma = ["PHARMA.PHARMA_TRIALS." + c for c in ("LEAD_SPONSOR", "PHASE", "START_DATE", "TERMINATED", "BRIEF_SUMMARY",
                                                           "ELIGIBILITY_CRITERIA", "NCT_ID")]

    def store(self, id: str, versions: dict[int, str], current: int | None) -> Path:
        folder = store.descriptor_store_dir(id)
        folder.mkdir(parents=True)
        for n, text in versions.items():
            (folder / f"v{n}.yaml").write_text(text, encoding="utf-8")
        if current is not None:
            (folder / "current").write_text(f"{current}\n", encoding="utf-8")
        return folder

    def shipped_as(self, version: int, status: str, entity: str = "LEAD_SPONSOR") -> str:
        text = (ROOT / "data" / "datasets" / "pharma_trials" / "descriptor.yaml").read_text(encoding="utf-8")
        return text.replace("version: 1", f"version: {version}").replace("status: approved", f"status: {status}") \
                   .replace("owner: kit", "owner: dana").replace("column: LEAD_SPONSOR", f"column: {entity}")

    def test_the_store_lives_under_exakit_home(self):
        self.assertEqual(store.kit_home(), Path(self.home.name))
        self.assertEqual(store.descriptor_store_dir("pharma_trials"), Path(self.home.name) / "descriptors" / "pharma_trials")
        with self.assertRaises(ValueError):
            store.descriptor_store_dir("../etc")
        with mock.patch.dict(os.environ, {"EXAKIT_HOME": ""}):
            self.assertEqual(store.kit_home(), Path.home() / ".exasol-starter-kit")

    def test_nothing_stored_falls_back_to_the_shipped_file(self):
        ds = exakit_nb.dataset(FakeConn(self.pharma), "pharma_trials")
        self.assertEqual(ds.descriptor_origin, "shipped")
        self.assertEqual(ds.descriptor_path, ROOT / "data" / "datasets" / "pharma_trials" / "descriptor.yaml")
        self.assertEqual((ds.version, ds.status, ds.owner), (1, "approved", "kit"))
        self.assertEqual(store.list_versions("pharma_trials"), [])
        self.assertIsNone(store.current_version("pharma_trials"))

    def test_the_stores_current_version_wins_over_the_shipped_file(self):
        folder = self.store("pharma_trials", {1: self.shipped_as(1, "approved"), 2: self.shipped_as(2, "approved", "NCT_ID"),
                                              3: self.shipped_as(3, "draft")}, current=2)
        ds = exakit_nb.dataset(FakeConn(self.pharma), "pharma_trials")
        self.assertEqual((ds.descriptor_origin, ds.descriptor_path), ("store", folder / "v2.yaml"))
        self.assertEqual((ds.version, ds.owner, ds.col("entity")), (2, "dana", "NCT_ID"))
        self.assertEqual(store.list_versions("pharma_trials"), [1, 2, 3])
        self.assertEqual(store.current_version("pharma_trials"), 2)
        self.assertEqual(store.current_descriptor("pharma_trials"), folder / "v2.yaml")

    def test_a_store_without_current_or_with_a_gone_version_is_skipped(self):
        folder = self.store("pharma_trials", {1: self.shipped_as(1, "approved")}, current=None)
        self.assertEqual(exakit_nb.dataset(FakeConn(self.pharma), "pharma_trials").descriptor_origin, "shipped")
        (folder / "current").write_text("7\n", encoding="utf-8")
        self.assertIsNone(store.current_descriptor("pharma_trials"))
        self.assertEqual(exakit_nb.dataset(FakeConn(self.pharma), "pharma_trials").descriptor_origin, "shipped")
        (folder / "current").write_text("latest\n", encoding="utf-8")
        self.assertIsNone(store.current_version("pharma_trials"))
        self.assertEqual(store.list_versions("pharma_trials"), [1])

    def test_a_path_given_wins_over_the_store(self):
        self.store("sensor_readings", {1: V2}, current=1)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "mine.yaml"
            path.write_text(V2.replace("owner: dana", "owner: sam"), encoding="utf-8")
            ds = exakit_nb.dataset(FakeConn(), str(path))
            self.assertEqual((ds.descriptor_origin, ds.descriptor_path, ds.owner), ("explicit", path, "sam"))
            (Path(tmp) / "descriptor.yaml").write_text(V2, encoding="utf-8")
            folder = exakit_nb.dataset(FakeConn(), tmp)
            self.assertEqual((folder.descriptor_origin, folder.descriptor_path), ("explicit", Path(tmp) / "descriptor.yaml"))
        stored = exakit_nb.dataset(FakeConn(), "sensor_readings")
        self.assertEqual((stored.descriptor_origin, stored.owner), ("store", "dana"))

    def test_an_unknown_id_names_the_three_places(self):
        with self.assertRaises(ValueError) as caught:
            exakit_nb.dataset(FakeConn(), "no_such_set")
        self.assertIn("not approved in the kit's store", str(caught.exception))
        self.assertIn("pharma_trials", str(caught.exception))

    def test_a_data_file_reads_the_descriptor_beside_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = Path(tmp) / "readings.csv"
            data.write_text("DEVICE,KIND,TAKEN_ON,ALARM,NOTE\nd1,a,2024-01-01,0,x\n", encoding="utf-8")
            beside = Path(tmp) / "readings.descriptor.yaml"
            beside.write_text(V2.replace("status: approved", "status: draft"), encoding="utf-8")
            mark = f"{own_file.MARK}{own_file._digest(data)} file={data.name}"

            class Loaded(FakeConn):
                def execute(self, statement):
                    if "EXA_ALL_TABLES" in statement:
                        return FakeResult([(mark,)])
                    return super().execute(statement)

            ds = exakit_nb.dataset(Loaded(), str(data))
            self.assertEqual((ds.descriptor_origin, ds.descriptor_path, ds.path), ("beside", beside, data))
            self.assertEqual((ds.status, ds.source_ref, ds.source), ("draft", "file:/data/readings.csv", None))


class GatingTest(unittest.TestCase):
    """AC-DS2.5 (the gating half): a draft is refused by the steps that need an approved descriptor, with the fix."""

    def dataset(self, text: str) -> Dataset:
        return Dataset("sensor_readings", Path("d"), "0" * 64, rules.parse_descriptor(text))

    def test_an_approved_descriptor_passes_and_is_returned(self):
        ds = self.dataset(V2)
        self.assertIs(ds.require_approved("training"), ds)
        v1 = self.dataset(V1)
        self.assertIs(v1.require_approved("training"), v1, "a schema_version 1 file is approved")

    def test_a_draft_is_refused_with_how_to_approve_it(self):
        ds = self.dataset(V2.replace("status: approved", "status: draft"))
        with self.assertRaises(DescriptorNotApproved) as caught:
            ds.require_approved("training")
        self.assertEqual(str(caught.exception),
                         "training needs an approved descriptor: sensor_readings is a draft (v3). Approve it: in the "
                         "quickstart run approve(), or: exakit describe sensor_readings --approve")
        self.assertTrue(issubclass(DescriptorNotApproved, Exception))
        self.assertFalse(issubclass(DescriptorNotApproved, ValueError))

    def test_the_record_is_on_the_dataset(self):
        ds = self.dataset(V2)
        self.assertEqual((ds.version, ds.status, ds.owner, ds.created, ds.table_digest, ds.drafted_by),
                         (3, "approved", "dana", "2026-10-27T10:12:03Z", "sha256:abc123", "profile"))
        self.assertEqual(ds.digest, "0" * 64, "digest stays the descriptor file's SHA-256 (trace tags, show_roles)")
        self.assertEqual((ds.notes, ds.missing, ds.evidence["date"]["type"]), ({"DEVICE": "The sensor that took the reading."}, (), "DATE"))
        self.assertTrue(ds.has("date"))

    def test_a_missing_role_is_skipped_with_its_reason(self):
        roles = "\n".join(line for line in ROLES.splitlines() if "date:" not in line) + "\n"
        ds = self.dataset(V2_HEAD + roles + "missing:\n  - {role: date, reason: no dates}\n")
        self.assertFalse(ds.has("date"))
        self.assertEqual(ds.missing, ({"role": "date", "reason": "no dates"},))
        with self.assertRaises(rules.BadInput):
            ds.col("date")

    def test_a_live_source_is_only_a_vs_source(self):
        live = self.dataset(V2.replace('source: "file:/data/readings.csv"', "source: vs:CRM"))
        self.assertEqual((live.source, live.source_ref, live.tags()["exasol.source"]), ("CRM", "vs:CRM", "CRM"))
        with redirect_stdout(io.StringIO()):
            self.assertFalse(exakit_nb.confirm_send(live, 3, answer="n"))
        loaded = self.dataset(V2)
        self.assertNotIn("exasol.source", loaded.tags())
        self.assertTrue(exakit_nb.confirm_send(loaded, 3))


class ApproveFlowTest(unittest.TestCase):
    """AC-DS2.5 end to end in a notebook: describe() -> save() is a draft the training step refuses; approve() writes
    the store's version 1 and hands back an approved Dataset."""

    class FlowConn:
        """The service's fake (the profile, the digest, the comments) behind the Dataset's own two statements."""

        def __init__(self, inner):
            self.inner = inner

        def execute(self, statement):
            if statement.startswith("SELECT 'EXAKIT_NB_COLUMNS'"):
                return FakeResult([("EXAKIT_NB_COLUMNS",), *[(f"LAB.READINGS.{n}",) for n, _t in self.inner.columns]])
            if statement.startswith("SELECT DISTINCT CAST("):
                return FakeResult([("0",), ("1",)])
            return self.inner.execute(statement)

        def close(self):
            pass

    def test_a_draft_is_refused_until_approve_and_then_accepted(self):
        from tests.test_describe_service import FakeConn, Profiles

        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {
                "EXAKIT_HOME": home, "EXAKIT_DESCRIPTOR_OWNER": "dana", "EXAKIT_NB_MODEL": "", "OPENAI_BASE_URL": ""}):
            conn = self.FlowConn(FakeConn(Profiles.COLUMNS, Profiles.rows()))
            draft = exakit_nb.describe("LAB.READINGS", conn=conn, id="readings")
            path = draft.save(Path(home) / "readings.yaml")
            ds = exakit_nb.dataset(conn, path)
            self.assertEqual((ds.status, ds.version, ds.descriptor_origin, ds.table_digest), ("draft", 1, "explicit", None))
            with self.assertRaises(DescriptorNotApproved) as caught:
                ds.require_approved("training")
            self.assertEqual(str(caught.exception), "training needs an approved descriptor: readings is a draft (v1). Approve it: in the "
                                                    "quickstart run approve(), or: exakit describe readings --approve")
            self.assertEqual(store.list_versions("readings"), [])
            out = io.StringIO()
            with redirect_stdout(out):
                approved = draft.approve(conn=conn)
            self.assertIsInstance(approved, Dataset)
            self.assertEqual((approved.status, approved.version, approved.owner, approved.descriptor_origin, approved.id),
                             ("approved", 1, "dana", "store", "readings"))
            self.assertIs(approved.require_approved("training"), approved)
            self.assertRegex(approved.table_digest, r"^sha256:[0-9a-f]{64}$")
            self.assertEqual(approved.current_table_digest(conn), approved.table_digest)
            self.assertEqual((store.list_versions("readings"), store.current_version("readings")), ([1], 1))
            self.assertEqual(approved.descriptor_path, store.current_descriptor("readings"))
            self.assertEqual(approved.evidence["entity"]["column"], "NAME", "the draft's evidence travels into the approved version")
            self.assertIn("Approved readings v1 (owner dana, digest sha256:", out.getvalue())
            self.assertIn('COMMENT ON COLUMN "LAB"."READINGS"."NAME" IS \'role: entity (starter kit, descriptor readings v1)\'', conn.inner.statements)
            self.assertEqual((draft.doc["status"], draft.doc["version"]), ("approved", 1))
            self.assertEqual(exakit_nb.dataset(conn, "readings").status, "approved", "the id now resolves to the store")
            self.assertEqual(exakit_nb.dataset(conn, path).status, "draft", "the file written by save() stays a draft")
            with redirect_stdout(out):
                again = draft.approve(conn=conn)
            self.assertEqual((again.version, store.list_versions("readings")), (1, [1]))
            self.assertIn("v1 is already approved with these roles", out.getvalue())
            changed = conn.inner.rows[3]
            changed["KIND"] = "steam"
            self.assertNotEqual(approved.current_table_digest(conn), approved.table_digest, "a changed row changes the digest")

    def test_save_keeps_a_number_like_value_a_string(self):
        doc = {"schema_version": 2, "id": "readings", "fact_table": "LAB.READINGS", "version": 1, "status": "draft", "owner": "dana",
               "created": "2026-10-27T10:12:03Z", "drafted_by": "profile", "digest": None,
               "roles": {"entity": {"table": "LAB.READINGS", "column": "DEVICE"}, "category": {"table": "LAB.READINGS", "column": "KIND"},
                         "date": {"table": "LAB.READINGS", "column": "TAKEN_ON"}, "label": {"table": "LAB.READINGS", "column": "ALARM"},
                         "text": [{"table": "LAB.READINGS", "column": "NOTE"}]},
               "evidence": {"label": {"column": "ALARM", "top": [{"value": "0", "share": 0.8}, {"value": "1", "share": 0.2}], "score": 1.0}}}
        with tempfile.TemporaryDirectory() as folder:
            path = exakit_nb.Draft(doc).save(Path(folder) / "d.yaml")
            text = path.read_text(encoding="utf-8")
        self.assertIn('top: [{value: "0", share: 0.8}, {value: "1", share: 0.2}]', text)
        self.assertEqual(rules.load_yaml(text)["evidence"]["label"]["top"][0]["value"], "0")
        self.assertEqual(rules.parse_descriptor(text).evidence["label"]["top"][1], {"value": "1", "share": 0.2})


class WriterTest(unittest.TestCase):
    """save_descriptor writes schema_version 2: a draft by the user unless told otherwise, read back the same."""

    def setUp(self):
        patcher = mock.patch.dict(os.environ, {"EXAKIT_DESCRIPTOR_OWNER": "tester"})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_roles_given_by_hand_become_a_draft_with_the_file_as_source(self):
        doc = own_file._descriptor_doc({"entity": "ID", "category": "CAT", "date": "D", "label": "L", "text": ["MEMO"]},
                                       "MY_DATA.T", Path("/data/t.csv"))
        self.assertEqual((doc["schema_version"], doc["version"], doc["status"], doc["owner"], doc["drafted_by"], doc["source"]),
                         (2, 1, "draft", "tester", "user", "file:/data/t.csv"))
        self.assertIsNone(doc["digest"])
        self.assertIsNotNone(rules._timestamp(doc["created"]))
        with tempfile.TemporaryDirectory() as tmp:
            path = own_file.save_descriptor(doc, Path(tmp) / "t.descriptor.yaml", "a test")
            lines = path.read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines[:4], ["# a test", "schema_version: 2", "id: t", "fact_table: MY_DATA.T"])
            self.assertEqual([l.split(":")[0] for l in lines[4:11]],
                             ["source", "version", "status", "owner", "created", "drafted_by", "digest"])
            d = rules.read_descriptor(path)
            self.assertEqual((d.status, d.owner, d.version, d.drafted_by, d.source, d.live_source, d.digest),
                             ("draft", "tester", 1, "user", "file:/data/t.csv", None, None))
            self.assertEqual(d.created, doc["created"])

    def test_told_approved_and_the_owner_from_the_environment_or_the_os_user(self):
        doc = own_file._descriptor_doc({"entity": "ID", "category": "CAT", "date": "D", "label": "L", "text": "MEMO"}, "S.T")
        with tempfile.TemporaryDirectory() as tmp:
            d = rules.read_descriptor(own_file.save_descriptor(doc, Path(tmp) / "a.yaml", status="approved", source="vs:CRM"))
            self.assertEqual((d.status, d.source, d.live_source), ("approved", "vs:CRM", "CRM"))
            with self.assertRaises(ValueError):
                own_file.save_descriptor(doc, Path(tmp) / "b.yaml", status="final")
        with mock.patch.dict(os.environ, {"EXAKIT_DESCRIPTOR_OWNER": ""}), mock.patch("getpass.getuser", return_value="osuser"):
            self.assertEqual(own_file.descriptor_owner(), "osuser")
        with mock.patch.dict(os.environ, {"EXAKIT_DESCRIPTOR_OWNER": ""}), mock.patch("getpass.getuser", side_effect=OSError):
            self.assertEqual(own_file.descriptor_owner(), "unknown")

    def test_a_version_1_document_is_written_as_version_2(self):
        doc = rules.load_yaml(V1 + "source: crm\n")
        with tempfile.TemporaryDirectory() as tmp:
            d = rules.read_descriptor(own_file.save_descriptor(doc, Path(tmp) / "old.yaml"))
            self.assertEqual((d.schema_version, d.version, d.status, d.owner, d.source, d.live_source),
                             (2, 1, "draft", "tester", "vs:crm", "crm"))

    def test_a_version_2_document_keeps_its_record_evidence_notes_and_missing(self):
        doc = rules.load_yaml(V2)
        doc["roles"].pop("date")
        doc["missing"] = [{"role": "date", "reason": "no column has >=95% parseable dates"}]
        with tempfile.TemporaryDirectory() as tmp:
            path = own_file.save_descriptor(doc, Path(tmp) / "v.yaml")
            again = rules.parse_descriptor(path.read_text(encoding="utf-8"))
            expect = rules.parse_descriptor(json.dumps(doc))
            self.assertEqual(again, expect)
            self.assertEqual((again.version, again.status, again.owner, again.created, again.digest, again.drafted_by),
                             (3, "approved", "dana", "2026-10-27T10:12:03Z", "sha256:abc123", "profile"))


if __name__ == "__main__":
    unittest.main()
