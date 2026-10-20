"""Check a dataset folder before the kit offers it: its files, then a real load into the database - everything the
loader, the notebooks and the tests rely on.

Adding a bundled dataset is three steps and no code (data/datasets/README.md):

    1. put the folder in data/datasets/<id>/ (dataset.conf, 01_create_schema.sql, data/*.csv, ...)
    2. python3 tools/dataset_check.py data/datasets/<id>        # checks the files, then loads it and checks the load
    3. nothing else: the kit discovers every folder with a dataset.conf (data/datasets/README.md)

    python3 tools/dataset_check.py <folder>... [--offline] [--profile NAME] [--replace] [--keep] [--manifest]
    python3 tools/dataset_check.py --all --offline               # every folder, files only, as the tests do

First the files, offline: dataset.conf, the CREATE TABLEs against every CSV (UTF-8, no BOM, the header's columns in
order, every row as wide as the header, no empty NOT NULL value, no duplicate primary key), Exasol's reserved words,
the verify script, and for a reference dataset (descriptor.json) the descriptor, the manifest's digests, the README and
the examples. Then, unless --offline, the load (tools/dataset_live.py): the scripts and the CSVs through exapump as
the kit loads them, the verification, the markers, the descriptor's roles and every example query - into the
dataset's own schema, which must not exist yet (--replace reloads it and leaves it) and is dropped again afterwards
(--keep leaves it loaded).

Exit 0 when everything passes, 1 with one line per problem, 2 for a bad command line.
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parents[1]
DATASETS = ROOT / "data" / "datasets"
RESERVED = {w.strip().upper() for w in (Path(__file__).parent / "exasol_reserved_words.txt").read_text(encoding="utf-8").splitlines()
            if w.strip() and not w.startswith("#")}
CREATE_TABLE = re.compile(r"CREATE OR REPLACE TABLE\s+(\w+)\s*\((.*?)\n\);", re.IGNORECASE | re.DOTALL)
NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,127}$")
MIN_EXAMPLES = 10


def conf(folder: Path) -> dict[str, str]:
    """dataset.conf as a dict (empty when the file is missing)."""
    path = folder / "dataset.conf"
    if not path.is_file():
        return {}
    return {k.strip(): v.strip() for k, _, v in (line.partition("=") for line in path.read_text(encoding="utf-8").splitlines())
            if v and not k.startswith("#")}


def tables(folder: Path) -> dict[str, list[str]]:
    """{TABLE: [COLUMN, ...]} from the CREATE TABLE statements of 01_create_schema.sql, upper-cased, in order."""
    path = folder / "01_create_schema.sql"
    found: dict[str, list[str]] = {}
    for match in CREATE_TABLE.finditer(path.read_text(encoding="utf-8") if path.is_file() else ""):
        found[match.group(1).upper()] = [line.strip().rstrip(",").split()[0].upper() for line in match.group(2).splitlines()
                                         if line.strip() and not line.strip().upper().startswith(("CONSTRAINT", "--"))]
    return found


def offered() -> list[str]:
    """The dataset ids the kit offers: every folder under data/datasets with a dataset.conf (the 0.2.0 kit discovers
    them; there is no list to keep)."""
    return sorted(p.parent.name for p in DATASETS.glob("*/dataset.conf"))


def _conf_problems(folder: Path, fields: dict[str, str], schema_tables: dict[str, list[str]]) -> list[str]:
    problems = []
    if not fields:
        return ["dataset.conf is missing or empty"]
    if fields.get("id") != folder.name:
        problems.append(f"dataset.conf: id must be the folder name '{folder.name}'")
    for key in ("label", "markers"):
        if not fields.get(key):
            problems.append(f"dataset.conf: '{key}' is missing")
    schema = (fields.get("schema") or folder.name).upper()
    if not NAME.match(schema) or schema in RESERVED:
        problems.append(f"dataset.conf: schema '{schema}' is not a plain, unreserved SQL name")
    script = (folder / "01_create_schema.sql").read_text(encoding="utf-8") if (folder / "01_create_schema.sql").is_file() else ""
    created = {s.upper() for s in re.findall(r"CREATE\s+SCHEMA\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)", script, re.IGNORECASE)}
    if created != {schema}:
        problems.append(f"01_create_schema.sql must create exactly the schema {schema} (it creates {sorted(created) or 'none'})")
    for marker in filter(None, (m.strip().upper() for m in fields.get("markers", "").split(","))):
        if marker not in schema_tables:
            problems.append(f"dataset.conf: marker {marker} is not a table in 01_create_schema.sql")
    return problems


def _constraints(body: str) -> tuple[list[str], list[str]]:
    """(primary key columns, NOT NULL columns) of one CREATE TABLE body, upper-cased."""
    key = re.search(r"PRIMARY\s+KEY\s*\(([^)]*)\)", body, re.IGNORECASE)
    pk = [c.strip().upper() for c in key.group(1).split(",")] if key else []
    required = [line.strip().split()[0].upper() for line in body.splitlines()
                if re.search(r"\bNOT\s+NULL\b", line.split("--")[0], re.IGNORECASE) and not line.strip().upper().startswith("CONSTRAINT")]
    return pk, required


def _csv_problems(path: Path, columns: list[str], pk: list[str], required: list[str]) -> list[str]:
    """One CSV against its table: encoding, header, row widths, empty NOT NULL values and duplicate keys."""
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        return [f"data/{path.name} starts with a byte-order mark: save it as UTF-8 without BOM"]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as err:
        return [f"data/{path.name} is not UTF-8 (byte {err.start}): save it as UTF-8"]
    reader = csv.reader(io.StringIO(text, newline=""))
    header = [c.strip().upper() for c in next(reader, [])]
    if len(set(header)) != len(header):
        return [f"data/{path.name}: the header names a column twice"]
    if header != columns:
        return [f"data/{path.name}: its header differs from CREATE TABLE {path.stem.upper()} (names and order)"]
    problems, seen = [], set()
    at_pk, at_required = [header.index(c) for c in pk if c in header], [header.index(c) for c in required if c in header]
    for line, row in enumerate(reader, 2):
        if len(row) != len(header):
            problems.append(f"data/{path.name} row {line}: {len(row)} fields, the header has {len(header)}")
        elif empty := [header[i] for i in at_required if not row[i].strip()]:
            problems.append(f"data/{path.name} row {line}: empty NOT NULL {', '.join(empty)}")
        elif at_pk and (key := tuple(row[i] for i in at_pk)) in seen:
            problems.append(f"data/{path.name} row {line}: primary key {key} repeats an earlier row")
        else:
            seen.add(tuple(row[i] for i in at_pk))
        if len(problems) >= 5:
            return [*problems, f"data/{path.name}: stopped after 5 problems"]
    return problems


def _table_problems(folder: Path, schema_tables: dict[str, list[str]]) -> list[str]:
    problems = []
    if not schema_tables:
        return ["01_create_schema.sql has no CREATE OR REPLACE TABLE"]
    text = (folder / "01_create_schema.sql").read_text(encoding="utf-8")
    for match in CREATE_TABLE.finditer(text):
        if "PRIMARY KEY" not in match.group(2).upper():
            problems.append(f"{match.group(1).upper()} has no primary key")
    for table, columns in schema_tables.items():
        problems += [f"{table}.{c} is a reserved word in Exasol: rename it" for c in [table, *columns] if c in RESERVED]
    bodies = {m.group(1).upper(): m.group(2) for m in CREATE_TABLE.finditer(text)}
    csvs = sorted((folder / "data").glob("*.csv"))
    if not csvs and not (folder / "02_load_data.sql").is_file():
        problems.append("no data/*.csv and no 02_load_data.sql: nothing would load")
    for path in csvs:
        table = path.stem.upper()
        if table not in schema_tables:
            problems.append(f"data/{path.name} has no CREATE TABLE {table}")
        else:
            problems += _csv_problems(path, schema_tables[table], *_constraints(bodies[table]))
    verify = folder / "03_verify_setup.sql"
    if verify.is_file():
        said = verify.read_text(encoding="utf-8").upper()
        problems += [f"03_verify_setup.sql does not check {t}" for t in schema_tables if t not in said]
    return problems


def _descriptor_problems(folder: Path, schema: str, schema_tables: dict[str, list[str]]) -> list[str]:
    """A dataset with descriptor.json is a reference dataset: valid descriptor, a manifest that matches, a README and
    at least ten read-only example queries on its own schema (docs/design.md D68)."""
    path = folder / "descriptor.json"
    if not path.is_file():
        return []
    from descriptor_rules import BadInput, parse_descriptor
    try:
        descriptor = parse_descriptor(path.read_text(encoding="utf-8"), "descriptor.json")
    except BadInput as err:
        return [str(err)]
    problems = [] if descriptor.id == folder.name else [f"descriptor.json: id must be '{folder.name}'"]
    known = {f"{schema}.{t}": cols for t, cols in schema_tables.items()}
    for role, ref in descriptor.references():
        if ref.column not in known.get(ref.table, []):
            problems.append(f"descriptor.json: {role} names {ref.table}.{ref.column}, not in 01_create_schema.sql")
    problems += _manifest_problems(folder)
    if not (folder / "README.md").is_file():
        problems.append("README.md is missing (source, terms and the data dictionary)")
    examples = folder / "examples.sql"
    statements = [s for s in re.sub(r"--[^\n]*", "", examples.read_text(encoding="utf-8")).split(";") if s.strip()] if examples.is_file() else []
    if len(statements) < MIN_EXAMPLES:
        problems.append(f"examples.sql has {len(statements)} queries; a reference dataset has at least {MIN_EXAMPLES}")
    problems += [f"examples.sql: query {n} is not a SELECT on {schema}" for n, s in enumerate(statements, 1)
                 if not s.lstrip().upper().startswith(("SELECT", "WITH")) or f"{schema}." not in s.upper()]
    return problems


def file_entries(folder: Path) -> dict[str, dict]:
    """{data/<name>.csv: {rows, sha256}} for every CSV of the folder."""
    entries = {}
    for path in sorted((folder / "data").glob("*.csv")):
        with path.open(newline="", encoding="utf-8") as handle:
            rows = sum(1 for _ in csv.reader(handle)) - 1
        entries[f"data/{path.name}"] = {"rows": rows, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return entries


def _manifest_problems(folder: Path) -> list[str]:
    path = folder / "manifest.json"
    if not path.is_file():
        return ["manifest.json is missing (run with --manifest, then fill in source and terms)"]
    manifest = json.loads(path.read_text(encoding="utf-8"))
    problems = [f"manifest.json: '{k}' is missing" for k in ("source", "terms", "snapshot") if not manifest.get(k)]
    if manifest.get("files") != file_entries(folder):
        problems.append("manifest.json: files do not match the CSVs (rows or SHA-256); run with --manifest")
    return problems


def check(folder: Path) -> list[str]:
    """Every problem with the dataset folder; an empty list means the kit can offer it."""
    fields = conf(folder)
    schema_tables = tables(folder)
    problems = _conf_problems(folder, fields, schema_tables) + _table_problems(folder, schema_tables)
    problems += _descriptor_problems(folder, (fields.get("schema") or folder.name).upper(), schema_tables)
    return problems


def write_manifest(folder: Path) -> None:
    """Set manifest.json's files to what the CSVs hold now; source, terms and snapshot are left as they are."""
    path = folder / "manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else \
        {"id": folder.name, "source": {}, "terms": {"confirmed": False}, "snapshot": ""}
    manifest["files"] = file_entries(folder)
    path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def _options(argv: list[str]) -> tuple[list[Path], dict[str, object]]:
    """(folders, options) from the command line; ValueError for anything it does not know."""
    flags = {"--all", "--offline", "--replace", "--keep", "--manifest"}
    options: dict[str, object] = {"profile": _profile()}
    folders: list[Path] = []
    args = iter(argv)
    for arg in args:
        if arg == "--profile":
            options["profile"] = next(args, "")
        elif arg in flags:
            options[arg.lstrip("-")] = True
        elif arg.startswith("--"):
            raise ValueError(f"unknown option {arg}")
        else:
            folders.append(Path(arg))
    if options.get("all"):
        folders = sorted(p.parent for p in DATASETS.glob("*/dataset.conf"))
    if not folders or not options["profile"]:
        raise ValueError("name a dataset folder (or --all), and a profile after --profile")
    missing = [str(f) for f in folders if not f.is_dir()]
    if missing:
        raise ValueError(f"not a folder: {', '.join(missing)}")
    return folders, options


def _profile() -> str:
    """The kit's exapump profile: EXAKIT_EXAPUMP_PROFILE, else starter-kit (as setup/lib/exapump.sh)."""
    import os
    return os.environ.get("EXAKIT_EXAPUMP_PROFILE") or "starter-kit"


def _check_one(folder: Path, options: dict[str, object]) -> bool:
    """Print the folder's result; True when it passes."""
    if options.get("manifest"):
        write_manifest(folder)
    problems = check(folder)
    for problem in problems:
        print(f"{folder.name}: {problem}")
    if not problems and not options.get("offline"):
        from dataset_live import LiveError, live_check
        fields = conf(folder)
        markers = [m.strip().upper() for m in fields.get("markers", "").split(",") if m.strip()]
        try:
            report = live_check(folder, (fields.get("schema") or folder.name).upper(), markers, profile=str(options["profile"]),
                                replace=bool(options.get("replace")), keep=bool(options.get("keep")))
        except LiveError as err:
            problems = [str(err)]
        else:
            print("\n".join(f"{folder.name}: ok - {line}" for line in report.passed))
            problems = report.problems
        for problem in problems:
            print(f"{folder.name}: {problem}")
    print(f"{folder.name}: {'PASS' if not problems else f'FAIL ({len(problems)} problem(s))'}")
    return not problems


def main(argv: list[str]) -> int:
    try:
        folders, options = _options(argv)
    except ValueError as err:
        print(f"{err}\n\n{__doc__}")
        return 2
    results = [_check_one(folder.resolve(), options) for folder in folders]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
