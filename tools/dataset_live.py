"""The live half of tools/dataset_check.py: load a dataset folder into the database the way the kit does, prove it
works, and leave the database as it was.

The steps mirror ``exakit data-load``: 01_create_schema.sql, every CSV through ``exapump upload`` (its imported row
count compared with the file's), 02_load_data.sql, 03_verify_setup.sql (every row must read OK), the markers hold rows,
then - for a reference dataset - the descriptor's roles against the database's columns, a 0/1 label and every query of
examples.sql. Each step is timed; a load slower than LOAD_BUDGET seconds is reported.

Safety: the dataset's schema must not exist yet - the check never touches data it did not load - unless ``replace`` is
given, which reloads it (as ``exakit data-load --force`` does) and leaves it loaded. A schema the check created is
dropped again at the end - on success, on failure and on Ctrl-C - unless ``keep`` is given.
"""

from __future__ import annotations

import csv
import io
import json
import re
import shutil
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path

LOAD_BUDGET = 300                 # seconds: the PRD's "loads in under five minutes" on a laptop
SQL_TIMEOUT = 1800
_SUMMARY = re.compile(r"(\d+) statements? executed, (\d+) failed")
_IMPORTED = re.compile(r"Imported (\d+) rows")


class LiveError(RuntimeError):
    """A step that cannot go on: the database or exapump is missing, or a step failed."""


@dataclass
class Report:
    """What the live check found: one line per step that passed, one per problem, the seconds each step took."""

    passed: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    seconds: dict[str, float] = field(default_factory=dict)


class Pump:
    """exapump with one profile: SQL scripts and uploads, failures turned into LiveError with exapump's own reason."""

    def __init__(self, profile: str, binary: str | None = None) -> None:
        self.bin = binary or shutil.which("exapump")
        if not self.bin:
            raise LiveError("exapump is not on PATH; the kit installs it (exakit update), or use --offline")
        self.profile = profile

    def _run(self, args: list[str], stdin: str | None = None) -> subprocess.CompletedProcess:
        try:
            return subprocess.run([self.bin, *args, "-p", self.profile], input=stdin, capture_output=True, text=True,
                                  timeout=SQL_TIMEOUT, check=False)
        except subprocess.TimeoutExpired as err:
            raise LiveError(f"exapump took longer than {SQL_TIMEOUT}s") from err

    def sql(self, text: str, what: str) -> str:
        """Run a script; its rows (stdout) when every statement succeeded, else LiveError naming the failed one."""
        done = self._run(["sql"], text.rstrip() + "\n")
        summary = _SUMMARY.search(done.stderr)
        if done.returncode != 0 or (summary and summary.group(2) != "0"):
            raise LiveError(f"{what}: {_reason(done.stderr)}")
        return done.stdout

    def upload(self, path: Path, table: str) -> int:
        """Upload one CSV into an existing table; the rows exapump says it imported."""
        done = subprocess.run([self.bin, "upload", str(path), "--table", table, "-p", self.profile], capture_output=True,
                              text=True, timeout=SQL_TIMEOUT, check=False)
        found = _IMPORTED.search(done.stdout + done.stderr)
        if done.returncode != 0 or not found:
            raise LiveError(f"upload of data/{path.name}: {_reason(done.stderr or done.stdout)}")
        return int(found.group(1))

    def rows(self, query: str, what: str) -> list[dict[str, str]]:
        """A query's result as dicts (exapump prints CSV with a header)."""
        return list(csv.DictReader(io.StringIO(self.sql(query, what))))


def _reason(text: str) -> str:
    """exapump's last error line, without the session id; the whole tail when it printed none."""
    errors = [line.strip() for line in text.splitlines() if line.strip().startswith(("Error", "Query execution failed"))]
    line = errors[-1] if errors else (text.strip().splitlines() or ["no output"])[-1]
    return re.sub(r"\s*\(Session: \d+\)", "", line)[:400]


def schema_exists(pump: Pump, schema: str) -> bool:
    found = pump.rows(f"SELECT COUNT(*) AS N FROM SYS.EXA_SCHEMAS WHERE SCHEMA_NAME = '{schema}'", "checking the schema")
    return bool(found) and found[0]["N"] != "0"


def _timed(report: Report, step: str, action):
    started = time.monotonic()
    try:
        return action()
    finally:
        report.seconds[step] = round(time.monotonic() - started, 1)


def _load(pump: Pump, folder: Path, schema: str, report: Report) -> None:
    """01, the CSVs, 02 - stopping at the first failure, which names its step."""
    _timed(report, "create", lambda: pump.sql((folder / "01_create_schema.sql").read_text(encoding="utf-8-sig"), "01_create_schema.sql"))
    report.passed.append("01_create_schema.sql ran")
    for path in sorted((folder / "data").glob("*.csv")):
        with path.open(newline="", encoding="utf-8-sig") as handle:
            expected = sum(1 for _ in csv.reader(handle)) - 1
        if expected <= 0:
            report.passed.append(f"data/{path.name} is empty; skipped as the kit does")
            continue
        got = _timed(report, f"upload {path.name}", lambda p=path: pump.upload(p, f"{schema}.{p.stem.upper()}"))
        if got != expected:
            report.problems.append(f"data/{path.name}: {expected} rows in the file, {got} imported")
        else:
            report.passed.append(f"data/{path.name}: {got} rows imported")
    if (folder / "02_load_data.sql").is_file():
        _timed(report, "load", lambda: pump.sql((folder / "02_load_data.sql").read_text(encoding="utf-8-sig"), "02_load_data.sql"))
        report.passed.append("02_load_data.sql ran")


def _verify(pump: Pump, folder: Path, schema: str, markers: list[str], report: Report) -> None:
    """03_verify_setup.sql must answer OK on every row; every marker table must hold rows."""
    verify = folder / "03_verify_setup.sql"
    if verify.is_file():
        rows = _timed(report, "verify", lambda: list(csv.reader(io.StringIO(pump.sql(verify.read_text(encoding="utf-8-sig"), "03_verify_setup.sql")))))
        failed = [",".join(r) for r in rows if len(r) > 1 and r[1].strip().upper() == "FAIL"]
        report.problems += [f"03_verify_setup.sql: {r}" for r in failed]
        if not failed:
            report.passed.append(f"03_verify_setup.sql: {sum(1 for r in rows if len(r) > 1 and r[1].strip().upper() == 'OK')} checks OK")
    for marker in markers:
        found = pump.rows(f"SELECT COUNT(*) AS N FROM {schema}.{marker}", f"counting {marker}")
        if not found or found[0]["N"] == "0":
            report.problems.append(f"marker {marker} is empty after the load: the kit would never call it loaded")


def _check_reference(pump: Pump, folder: Path, report: Report) -> None:
    """A reference dataset: the descriptor's roles in the database, a 0/1 label, rows with text, and every example."""
    from descriptor_rules import descriptor_file, read_descriptor
    descriptor = read_descriptor(descriptor_file(folder))
    refs = [(role, {"table": ref.table, "column": ref.column}) for role, ref in descriptor.references()]
    schemas = descriptor.schemas()
    names = ", ".join(f"'{s}'" for s in schemas)
    columns = {f"{r['T']}.{r['C']}" for r in pump.rows(
        f"SELECT COLUMN_SCHEMA || '.' || COLUMN_TABLE AS T, COLUMN_NAME AS C FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA IN ({names})",
        "reading the columns")}
    missing = [f"{role} -> {r['table']}.{r['column']}" for role, r in refs if f"{r['table'].upper()}.{r['column'].upper()}" not in columns]
    report.problems += [f"descriptor: the database has no column for {m}" for m in missing]
    if missing:
        return
    fact, label = descriptor.fact_table, descriptor.column("label").column
    values = {r["V"] for r in pump.rows(f"SELECT DISTINCT CAST({label} AS VARCHAR(100)) AS V FROM {fact} WHERE {label} IS NOT NULL", "reading the label")}
    if not values or not values <= {"0", "1"}:
        report.problems.append(f"descriptor: the label {label} must be 0 or 1, found {sorted(values)[:5] or 'no values'}")
    text = " || ".join(f"COALESCE(CAST({r['column']} AS VARCHAR(2000000)), '')" for role, r in refs if role == "text")
    with_text = pump.rows(f"SELECT COUNT(*) AS N FROM {fact} WHERE LENGTH(TRIM({text})) > 0", "reading the text")
    if not with_text or with_text[0]["N"] == "0":
        report.problems.append("descriptor: no row has any text in the text columns")
    report.passed.append("descriptor: every role resolves in the database")
    _run_examples(pump, folder, report)


def _run_examples(pump: Pump, folder: Path, report: Report) -> None:
    """Every query of examples.sql, as dataset_check counts them; each must run and return at least one row (a
    reference answer that comes back empty is not one)."""
    from dataset_check import example_questions
    examples = folder / "examples.sql"
    if not examples.is_file():
        return
    statements = [sql for _question, sql in example_questions(examples.read_text(encoding="utf-8-sig"))]
    failed = 0
    for number, statement in enumerate(statements, 1):
        try:
            rows = pump.rows(statement + ";", f"examples.sql query {number}")
        except LiveError as err:
            failed += 1
            report.problems.append(str(err))
            continue
        if not rows:
            failed += 1
            report.problems.append(f"examples.sql query {number}: returned no rows")
    if not failed:
        report.passed.append(f"examples.sql: all {len(statements)} queries ran and returned rows")


def live_check(folder: Path, schema: str, markers: list[str], *, profile: str, replace: bool = False, keep: bool = False) -> Report:
    """Load the folder into ``schema``, check it, and drop the schema again unless ``keep``; a Report either way."""
    report = Report()
    pump = Pump(profile)
    pump.sql("SELECT 1;", "connecting with the exapump profile '" + profile + "'")
    existed = schema_exists(pump, schema)
    if existed and not replace:
        raise LiveError(f"schema {schema} already exists; the check loads into it and drops it afterwards, so it stops "
                        "here. Drop it, or pass --replace to reload it (its contents are replaced)")
    started = time.monotonic()
    try:
        _load(pump, folder, schema, report)
        total = round(time.monotonic() - started, 1)
        report.seconds["total load"] = total
        (report.problems if total > LOAD_BUDGET else report.passed).append(
            f"loaded in {total}s" + (f", over the {LOAD_BUDGET}s budget" if total > LOAD_BUDGET else ""))
        _verify(pump, folder, schema, markers, report)
        from descriptor_rules import descriptor_file
        if descriptor_file(folder) is not None:
            _check_reference(pump, folder, report)
    except LiveError as err:
        report.problems.append(str(err))
    finally:
        if not keep and not existed:
            try:
                pump.sql(f"DROP SCHEMA IF EXISTS {schema} CASCADE;", f"dropping {schema}")
                report.passed.append(f"schema {schema} dropped again (--keep leaves it loaded)")
            except LiveError as err:
                report.problems.append(f"could not drop {schema}: {err} - drop it by hand")
    return report
