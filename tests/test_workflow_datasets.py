"""The GitHub workflows parse, and none of them falls behind the reference datasets (Sprint 1 #18).

A reference dataset is a folder of data/datasets with a manifest.json. When one is added, every place a workflow lists
the reference datasets has to name it too, or CI keeps proving the old set and nobody notices. So: every string in a
workflow (a run script, an env value) that names two or more reference datasets names all of them, and the live job
(reference-datasets-live.yml) names them all in REFERENCE_DATASETS, which its script checks against the folders
again. Offline: the YAML is read with PyYAML, else Ruby's Psych (both ship on the hosted runners), else skipped.

    python3 tests/test_workflow_datasets.py
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Iterator
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
DATASETS = ROOT / "data" / "datasets"
LIVE = WORKFLOWS / "reference-datasets-live.yml"
LIVE_SCRIPT = ROOT / "tests" / "integration" / "reference_datasets_live.py"


def reference_ids() -> list[str]:
    """The reference datasets: those that ship a descriptor (tools/dataset_check.py's definition). A dataset with only
    a manifest and no descriptor would download the same way but is not one."""
    return sorted(p.parent.name for p in DATASETS.glob("*/descriptor.yaml"))


def load_yaml(path: Path) -> Any:
    """The workflow as Python data: PyYAML, else Ruby's Psych through JSON; SkipTest when neither is there."""
    try:
        import yaml
    except ImportError:
        yaml = None
    if yaml is not None:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    ruby = shutil.which("ruby")
    if ruby is None:
        raise unittest.SkipTest("neither PyYAML nor ruby is installed to read the workflows")
    done = subprocess.run([ruby, "-ryaml", "-rjson", "-e",
                           "puts JSON.generate(YAML.safe_load(File.read(ARGV[0]), aliases: true))", str(path)],
                          capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise ValueError(f"{path.name} does not parse: {done.stderr.strip()[-400:]}")
    return json.loads(done.stdout)


def strings(value: Any) -> Iterator[str]:
    """Every string in the document, keys included."""
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(key, str):
                yield key
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, str):
        yield value


def named(text: str, ids: list[str]) -> set[str]:
    return {i for i in ids if re.search(r"(?<![A-Za-z0-9_])" + re.escape(i) + r"(?![A-Za-z0-9_])", text)}


def triggers(doc: dict[Any, Any]) -> Any:
    """The `on:` block (YAML 1.1 readers turn the key into True)."""
    for key in ("on", True, "true"):
        if key in doc:
            return doc[key]
    return None


class WorkflowDatasetsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.ids = reference_ids()
        cls.docs = {p.name: load_yaml(p) for p in sorted(WORKFLOWS.glob("*.yml"))}

    def test_the_reference_datasets_are_found(self) -> None:
        self.assertGreaterEqual(len(self.ids), 2, self.ids)
        self.assertLessEqual({"amazon_sales", "fraud_transactions"}, set(self.ids), self.ids)
        for dataset in self.ids:
            for name in ("dataset.conf", "descriptor.yaml", "03_verify_setup.sql"):
                self.assertTrue((DATASETS / dataset / name).is_file(), f"{dataset} has no {name}")

    def test_every_workflow_parses_with_jobs_and_triggers(self) -> None:
        self.assertIn("reference-datasets-live.yml", self.docs)
        for name, doc in self.docs.items():
            with self.subTest(workflow=name):
                self.assertIsInstance(doc, dict, f"{name} is not a mapping")
                self.assertIsNotNone(triggers(doc), f"{name} has no on: block")
                jobs = doc.get("jobs")
                self.assertIsInstance(jobs, dict, f"{name} has no jobs")
                for job, body in jobs.items():
                    self.assertIn("runs-on", body, f"{name}: job {job} has no runs-on")
                    self.assertIsInstance(body.get("steps"), list, f"{name}: job {job} has no steps")

    def test_a_list_of_reference_datasets_names_them_all(self) -> None:
        listing = 0
        for name, doc in self.docs.items():
            for text in strings(doc):
                found = named(text, self.ids)
                if len(found) >= 2:
                    listing += 1
                    with self.subTest(workflow=name, text=text.strip().splitlines()[0][:80]):
                        self.assertEqual(sorted(found), self.ids,
                                         f"{name} lists {sorted(found)} but not {sorted(set(self.ids) - found)}")
        self.assertGreaterEqual(listing, 3, "the workflows no longer list the reference datasets anywhere")

    def test_the_live_job_names_every_reference_dataset(self) -> None:
        doc = self.docs["reference-datasets-live.yml"]
        job = doc["jobs"]["reference-datasets-live"]
        self.assertEqual(sorted(job["env"]["REFERENCE_DATASETS"].split()), self.ids)
        runs = "\n".join(step.get("run", "") for step in job["steps"])
        self.assertIn("reference_datasets_live.py datasets $REFERENCE_DATASETS", runs)
        self.assertIn("reference_datasets_live.py own-file", runs)
        self.assertIn("reference_datasets_live.py no-secrets", runs)
        self.assertEqual(named(runs, self.ids), set(self.ids), "the notebook loop must run on every reference dataset")
        install = next(s for s in job["steps"] if "install.sh" in s.get("run", ""))
        # The ML Engineer is disabled for now ("visible": false): the Data Scientist installs, and the add-on the ML
        # Engineer's notebooks need is named beside the persona's own.
        self.assertEqual(install["env"]["EXAKIT_PERSONA"], "data-scientist")
        self.assertIn("udf-devkit", install["env"]["EXAKIT_MARKETPLACE_ADDONS"].split(","))
        self.assertIn("EXAKIT_LOCAL_KIT", install["env"])
        self.assertNotIn("EXAKIT_DATASETS", install["env"], "the personas' own dataset list is what has to load")
        on = triggers(doc)
        self.assertIn("workflow_dispatch", on)
        for path in on["push"]["paths"]:
            if not any(ch in path for ch in "*?["):
                self.assertTrue((ROOT / path).exists(), f"push.paths names {path}, which is not in the tree")

    def test_the_personas_load_the_reference_datasets(self) -> None:
        """A persona the kit offers loads every reference dataset; any persona names only datasets the kit has (a folder
        with a dataset.conf). A disabled one ("visible": false, the ML Engineer for now) keeps the set it had."""
        for persona in ("data-scientist", "ml-engineer"):
            doc = json.loads((ROOT / "personas" / f"{persona}.json").read_text(encoding="utf-8"))
            if doc.get("visible", True):
                self.assertLessEqual(set(self.ids), set(doc["datasets"]), f"{persona}.json")
            for extra in set(doc["datasets"]) - set(self.ids):
                self.assertTrue((DATASETS / extra / "dataset.conf").is_file(), f"{persona}.json names {extra}")

    def test_every_notebook_and_script_a_workflow_runs_is_there(self) -> None:
        for name, doc in self.docs.items():
            for text in strings(doc):
                for path in re.findall(r"(?:notebook/notebooks|tests|tools)/[A-Za-z0-9_./-]+\.(?:py|sh)\b", text):
                    with self.subTest(workflow=name, path=path):
                        self.assertTrue((ROOT / path).is_file(), f"{name} runs {path}, which is not in the tree")

    def test_the_live_script_refuses_a_list_that_fell_behind(self) -> None:
        live = self._live()
        self.assertEqual(live.reference_ids(), self.ids)
        with tempfile.TemporaryDirectory() as home, \
                mock.patch.dict(os.environ, {"EXAKIT_HOME": home, "EXAKIT_REQUIRE_DB": "", "EXAKIT_REQUIRE_ALL": ""}):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(live.cmd_datasets(self.ids[:-1]), 1)
            self.assertIn(self.ids[-1], out.getvalue())
            with contextlib.redirect_stdout(io.StringIO()) as out:
                self.assertEqual(live.cmd_datasets(self.ids), 0)                 # no kit here: a skip
            self.assertIn("SKIP", out.getvalue())
            with mock.patch.dict(os.environ, {"EXAKIT_REQUIRE_DB": "1"}), contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(live.cmd_datasets(self.ids), 3)                 # ... a failure where CI insists

    def test_the_live_draft_check_passes_the_shipped_draft_and_names_a_changed_type(self) -> None:
        """check_draft against `exakit describe --json` stood in by the offline draft of the fraud transactions (the very
        code the service runs, on the CSV): no failure; then one live type changed - the digest check fails and names
        it."""
        live = self._live()
        sys.path.insert(0, str(ROOT / "tools"))
        import descriptor_draft
        from descriptor import draft, profile
        import csv
        dataset = "fraud_transactions"
        folder = DATASETS / dataset
        schema, found = descriptor_draft.tables((folder / "01_create_schema.sql").read_text(encoding="utf-8"))
        shipped = live.read_yaml(folder / "descriptor.yaml")
        table = shipped["source"]["object"]
        columns = found[table.split(".", 1)[1]]
        with (folder / "data" / f"{table.split('.', 1)[1].lower()}.csv").open(encoding="utf-8", newline="") as handle:
            reader = csv.reader(handle)
            next(reader)
            profiled = profile.profile_rows(columns, reader, table)

        def answer(doc):
            return lambda *args: (0, json.dumps({"status": "draft", "doc": doc, "changed": [], "previous": None}), "")

        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"EXAKIT_HOME": home}):
            checks = live.Checks()
            with mock.patch.object(live, "run_exakit", answer(draft.draft(profiled, dataset))), \
                    contextlib.redirect_stdout(io.StringIO()) as out:
                live.check_draft(checks, dataset, shipped)
            self.assertEqual(checks.failed, 0, out.getvalue())
            # One live type different from the shipped one: the label widened from DECIMAL(1,0).
            changed = [(n, "DECIMAL(2,0)" if n == "FRAUDULENT" else t) for n, t in columns]
            self.assertNotEqual(changed, columns)
            altered = profile.profile_rows(changed, [], table)
            store = Path(home) / "descriptors" / table
            store.mkdir(parents=True)
            (store / "profile.json").write_text(json.dumps(altered), encoding="utf-8")
            doc = draft.draft(profiled, dataset)
            doc["source"]["schema_digest"] = altered["source"]["schema_digest"]
            checks = live.Checks()
            with mock.patch.object(live, "run_exakit", answer(doc)), contextlib.redirect_stdout(io.StringIO()) as out:
                live.check_draft(checks, dataset, shipped)
            self.assertEqual(checks.failed, 1, out.getvalue())
            self.assertIn("schema_digest", out.getvalue())
            self.assertIn("FRAUDULENT: declared DECIMAL(1,0), EXA_ALL_COLUMNS DECIMAL(2,0)", out.getvalue())

    def _live(self):
        sys.path.insert(0, str(LIVE_SCRIPT.parent))
        try:
            import reference_datasets_live as live
        finally:
            sys.path.remove(str(LIVE_SCRIPT.parent))
        return live

    def test_the_live_script_finds_a_password_by_file_and_never_prints_it(self) -> None:
        live = self._live()
        secret = "Not-A-Real-Password-4711"
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            (home / "credentials").mkdir()
            (home / "credentials" / "personal_sys_password").write_text(secret + "\n", encoding="utf-8")
            (home / "manifest.json").write_text("{}", encoding="utf-8")
            (home / "workflows").mkdir()
            (home / "workflows" / "wf-1.jsonl").write_text('{"kind": "sql"}\n', encoding="utf-8")
            with mock.patch.dict(os.environ, {"EXAKIT_HOME": folder}):
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(live.cmd_no_secrets([]), 0)
                (home / "descriptors" / "S.T").mkdir(parents=True)
                (home / "descriptors" / "S.T" / "draft.yaml").write_text(f"owner: {secret}\n", encoding="utf-8")
                with contextlib.redirect_stdout(io.StringIO()) as out:
                    self.assertEqual(live.cmd_no_secrets([]), 1)
            self.assertIn("draft.yaml", out.getvalue())
            self.assertNotIn(secret, out.getvalue())


if __name__ == "__main__":
    unittest.main()
