#!/usr/bin/env python3
"""The reference datasets and the role-per-column descriptor on a live database (Sprint 1 #18; DS-2, DS-5, DS2.3).
Run by .github/workflows/reference-datasets-live.yml after the kit was installed from the checkout with both
personas; a maintainer can run it after the same install by hand.

    python3 tests/integration/reference_datasets_live.py datasets [<id> ...]
        every reference dataset (a folder of data/datasets with a manifest.json): the ids given must be exactly those,
        so a workflow that names them cannot fall behind a new folder. For each:
          (a) exakit status lists it loaded; 03_verify_setup.sql answers OK on every row; every table holds the rows
              its manifest lists (6,435 Walmart store weeks, 128,975 Amazon order lines);
          (b) `exakit describe <SCHEMA.TABLE> --id <id> --json` drafts the role (and sensitive flag) of every column,
              the key, time and text slots and source.schema_digest that data/datasets/<id>/descriptor.yaml ships - the
              digest is the live proof that the declared types are the ones EXA_ALL_COLUMNS reports; on a mismatch the
              columns whose live type differs from the CREATE TABLE are named;
          (c) `exakit describe <id> --approve --role target=<the shipped target> --json` writes v1 and current.yaml,
              publishes EXAKIT_SEMANTIC.<SCHEMA>__<TABLE> whose every column comment starts with role=<its role>,
              leaves the dataset's own table without a role= comment, grants the view to the read-only MCP user, and
              approving again writes nothing.
    <kit notebook python> tests/integration/reference_datasets_live.py own-file <path.csv>
        (d, first half) a synthetic CSV written to <path.csv>, loaded with exakit_nb.load_own_file into MY_DATA.TICKETS,
        described (an e-mail column identifier and sensitive, in no slot), its target set, approved and published; the
        notebooks then run on its id, my_data_tickets (tests/notebooks-run.sh).
    python3 tests/integration/reference_datasets_live.py no-secrets [<extra folder> ...]
        (e) no database password in any file under the kit's notebooks, descriptors and workflows folders (and the
        folders given): file names are printed, never a password.

Without an installed kit and a database that answers, each command SKIPs (exit 0); EXAKIT_REQUIRE_DB=1 makes that a
failure (exit 3), as in tests/notebooks-run.sh. Exit 1: a check failed. Passwords are read from their files and never
printed; the queries run through exapump with the kit's profile (EXAKIT_EXAPUMP_PROFILE, default starter-kit).
"""

from __future__ import annotations

import csv
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
DATASETS = ROOT / "data" / "datasets"
for folder in (ROOT / "tools", ROOT / "setup" / "lib"):
    if str(folder) not in sys.path:
        sys.path.insert(0, str(folder))

SEMANTIC = "EXAKIT_SEMANTIC"
OWN_TABLE = "MY_DATA.TICKETS"
OWN_ID = "my_data_tickets"
OWN_ROLES = {"TICKET_ID": "key", "OPENED_ON": "time", "CHANNEL": "category", "CUSTOMER_EMAIL": "identifier",
             "ESCALATED": "flag", "BODY": "text"}
OWN_SLOTS = {"key": "TICKET_ID", "time": "OPENED_ON", "text": "BODY", "category": "CHANNEL"}
COMPARED_SLOTS = ("key", "time", "text")
MIN_SECRET = 8                       # a shorter value would match by chance; the kit's passwords are far longer


def home() -> Path:
    given = os.environ.get("EXAKIT_HOME")
    return Path(given).expanduser() if given else Path.home() / ".exasol-starter-kit"


def reference_ids() -> list[str]:
    """Every dataset folder with a descriptor.yaml: the reference datasets (tools/dataset_check.py's definition)."""
    return sorted(p.parent.name for p in DATASETS.glob("*/descriptor.yaml"))


class Checks:
    """ok/fail lines and a count of failures."""

    def __init__(self) -> None:
        self.failed = 0

    def ok(self, text: str) -> None:
        print(f"ok   {text}", flush=True)

    def fail(self, text: str) -> None:
        self.failed += 1
        print(f"FAIL {text}", flush=True)

    def check(self, passed: bool, text: str, why: str = "") -> bool:
        if passed:
            self.ok(text)
        else:
            self.fail(text + (f": {why}" if why else ""))
        return passed


def skip(reason: str) -> int:
    if os.environ.get("EXAKIT_REQUIRE_DB") == "1" or os.environ.get("EXAKIT_REQUIRE_ALL") == "1":
        print(f"FAIL {reason}", file=sys.stderr)
        print("This environment declared EXAKIT_REQUIRE_DB=1, so a missing prerequisite is a failure, not a skip.",
              file=sys.stderr)
        return 3
    print(f"SKIP {reason}\n  (set EXAKIT_REQUIRE_DB=1 to make this a failure instead)")
    return 0


def manifest() -> dict[str, Any]:
    return json.loads((home() / "manifest.json").read_text(encoding="utf-8"))


def exakit() -> str | None:
    found = shutil.which("exakit")
    if found:
        return found
    local = Path.home() / ".local" / "bin" / "exakit"
    return str(local) if local.is_file() else None


def run_exakit(*args: str) -> tuple[int, str, str]:
    done = subprocess.run([exakit() or "exakit", *args], capture_output=True, text=True, timeout=1800, check=False)
    return done.returncode, done.stdout, done.stderr


def first_json(text: str) -> Any:
    """The first JSON object in a command's stdout."""
    start = text.find("{")
    if start < 0:
        raise ValueError(f"no JSON object in the output: {text.strip()[:300]}")
    return json.JSONDecoder().raw_decode(text[start:])[0]


def read_yaml(path: Path) -> dict[str, Any]:
    import descriptor_rules
    return descriptor_rules.load_yaml(path.read_text(encoding="utf-8"))


def literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


# --- (a) loaded, verified, counted ------------------------------------------------------------------------------------

def _pump():
    """The kit writes its profile to <kit home>/exapump/config.toml and exports EXAPUMP_CONFIG only inside exakit; a
    maintainer's shell does not have it, so the kit's file is named here unless the environment names another."""
    from dataset_live import Pump
    kit_config = home() / "exapump" / "config.toml"
    if not os.environ.get("EXAPUMP_CONFIG") and kit_config.is_file():
        os.environ["EXAPUMP_CONFIG"] = str(kit_config)
    return Pump(os.environ.get("EXAKIT_EXAPUMP_PROFILE") or "starter-kit")


def check_loaded(c: Checks, pump, ids: list[str]) -> None:
    code, out, err = run_exakit("status", "--json")
    try:
        status = first_json(out)
    except ValueError as broken:
        c.fail(f"exakit status --json (exit {code}): {broken} {err.strip()[:200]}")
        return
    loaded = set(status.get("datasets_loaded") or [])
    c.check(set(ids) <= loaded, f"exakit status lists {', '.join(ids)} loaded ({status.get('datasets_source')})",
            f"missing {', '.join(sorted(set(ids) - loaded))}; loaded: {', '.join(sorted(loaded)) or 'none'}")
    for dataset in ids:
        folder = DATASETS / dataset
        conf = dict(line.split("=", 1) for line in (folder / "dataset.conf").read_text(encoding="utf-8").splitlines()
                    if "=" in line and not line.lstrip().startswith("#"))
        schema = conf.get("schema", dataset.upper()).strip()
        verify = folder / "03_verify_setup.sql"
        try:
            rows = list(csv.reader(io.StringIO(pump.sql(verify.read_text(encoding="utf-8-sig"), f"{dataset} 03_verify_setup.sql"))))
            states = [r for r in rows if len(r) > 1 and r[1].strip().upper() in ("OK", "FAIL")]
            failed = [",".join(r) for r in states if r[1].strip().upper() == "FAIL"]
            c.check(bool(states) and not failed, f"{dataset}: 03_verify_setup.sql answers OK on all {len(states)} checks",
                    "; ".join(failed) or "no OK/FAIL row came back")
        except Exception as broken:                                  # noqa: BLE001 - exapump's reason is the message
            c.fail(f"{dataset}: 03_verify_setup.sql did not run: {broken}")
        files = json.loads((folder / "manifest.json").read_text(encoding="utf-8")).get("files") or {}
        for name, entry in sorted(files.items()):
            table = f"{schema}.{Path(name).stem.upper()}"
            try:
                found = int(pump.rows(f"SELECT COUNT(*) AS N FROM {table}", f"counting {table}")[0]["N"])
            except Exception as broken:                              # noqa: BLE001
                c.fail(f"{dataset}: {table} could not be counted: {broken}")
                continue
            c.check(found == int(entry["rows"]), f"{dataset}: {table} holds {found:,} rows (manifest {int(entry['rows']):,})")


# --- (b) the draft against the shipped descriptor ---------------------------------------------------------------------

def _type_lines(dataset: str, table: str) -> tuple[dict[str, str], dict[str, str]]:
    """{column: declared type as EXA_ALL_COLUMNS writes it} from 01_create_schema.sql, and {column: live type} from the
    profile the draft came from (the store's profile.json)."""
    import descriptor_draft
    _schema, tables = descriptor_draft.tables((DATASETS / dataset / "01_create_schema.sql").read_text(encoding="utf-8"))
    declared = dict(tables.get(table.split(".", 1)[1], []))
    profile = home() / "descriptors" / table / "profile.json"
    live = {}
    if profile.is_file():
        live = {c["column"]: c.get("type") for c in json.loads(profile.read_text(encoding="utf-8")).get("columns", [])}
    return declared, live


def check_draft(c: Checks, dataset: str, shipped: dict[str, Any]) -> bool:
    table = shipped["source"]["object"]
    code, out, err = run_exakit("describe", table, "--id", dataset, "--json")
    if code != 0:
        c.fail(f"{dataset}: exakit describe {table} --id {dataset} --json exited {code}: {err.strip()[-400:]}")
        return False
    try:
        found = first_json(out)
    except ValueError as broken:
        c.fail(f"{dataset}: exakit describe printed no JSON: {broken}")
        return False
    doc = found["doc"]
    c.check(found.get("status") == "draft" and doc.get("dataset") == dataset,
            f"{dataset}: describe drafted '{doc.get('dataset')}' v{doc.get('version')} ({found.get('status')})",
            "expected a draft of this id on a fresh install")
    want = {name: (e["role"], bool(e.get("sensitive"))) for name, e in shipped["columns"].items()}
    got = {name: (e["role"], bool(e.get("sensitive"))) for name, e in doc["columns"].items()}
    differ = [f"{n}: shipped {want.get(n)}, drafted {got.get(n)}" for n in list(want) + [n for n in got if n not in want]
              if want.get(n) != got.get(n)]
    c.check(list(want) == list(doc["columns"]) and not differ,
            f"{dataset}: the draft gives all {len(got)} columns the roles descriptor.yaml ships, in table order",
            "; ".join(differ) or f"column order {list(doc['columns'])}")
    for slot in COMPARED_SLOTS:
        c.check(doc["slots"].get(slot) == shipped["slots"].get(slot),
                f"{dataset}: slot {slot} = {doc['slots'].get(slot)}",
                f"descriptor.yaml ships {shipped['slots'].get(slot)} ({(doc.get('slot_evidence') or {}).get(slot, '')})")
    for slot in ("category", "entity"):                              # drafted from approximate counts: a note, not a gate
        if doc["slots"].get(slot) != shipped["slots"].get(slot):
            print(f"note {dataset}: slot {slot} drafted {doc['slots'].get(slot)}, shipped {shipped['slots'].get(slot)}")
    c.check(doc["slots"].get("target") is None, f"{dataset}: target is not drafted",
            f"drafted {doc['slots'].get('target')}")
    live, ship = doc["source"].get("schema_digest"), shipped["source"].get("schema_digest")
    if not c.check(live == ship, f"{dataset}: source.schema_digest {live} is the shipped one",
                   f"shipped {ship} (computed from the CREATE TABLE types)"):
        declared, types = _type_lines(dataset, table)
        for name in declared.keys() | types.keys():
            if declared.get(name) != types.get(name):
                print(f"     {table}.{name}: declared {declared.get(name)}, EXA_ALL_COLUMNS {types.get(name)}")
    return True


# --- (c) approve and publish ------------------------------------------------------------------------------------------

def check_approve(c: Checks, pump, dataset: str, shipped: dict[str, Any]) -> None:
    table = shipped["source"]["object"]
    target = shipped["slots"].get("target")
    if not target:
        c.fail(f"{dataset}: descriptor.yaml ships no target to approve with")
        return
    code, out, err = run_exakit("describe", dataset, "--approve", "--role", f"target={target}", "--json")
    if code != 0:
        c.fail(f"{dataset}: exakit describe {dataset} --approve --role target={target} exited {code}: {err.strip()[-400:]}")
        return
    result = first_json(out)
    schema, name = table.split(".", 1)
    view = f"{SEMANTIC}.{schema}__{name}"
    c.check(result.get("status") == "approved" and result.get("version") == 1,
            f"{dataset}: approved v{result.get('version')} with target {target}", f"status {result.get('status')}: "
            f"{result.get('reason') or result.get('message') or ''}")
    c.check(result.get("published") == view, f"{dataset}: published as {view}",
            f"published {result.get('published')!r}, reason {result.get('reason')!r}")
    store = home() / "descriptors" / table
    c.check(all((store / f).is_file() for f in ("v1.yaml", "current.yaml", "v1.profile.json")) and not (store / "draft.yaml").exists(),
            f"{dataset}: the store holds v1.yaml, current.yaml and v1.profile.json, and no draft",
            ", ".join(sorted(p.name for p in store.iterdir())) if store.is_dir() else f"no folder {store}")
    current = read_yaml(store / "current.yaml") if (store / "current.yaml").is_file() else {}
    c.check(current.get("status") == "approved" and (current.get("slots") or {}).get("target") == target,
            f"{dataset}: current.yaml is approved with target {target}")
    rows = pump.rows("SELECT COLUMN_NAME, COLUMN_COMMENT FROM SYS.EXA_ALL_COLUMNS "
                     f"WHERE COLUMN_SCHEMA = {literal(SEMANTIC)} AND COLUMN_TABLE = {literal(f'{schema}__{name}')} "
                     "ORDER BY COLUMN_ORDINAL_POSITION", f"reading the comments of {view}")
    roles = {n: e["role"] for n, e in (current.get("columns") or {}).items()}
    wrong = [r["COLUMN_NAME"] for r in rows if not (r.get("COLUMN_COMMENT") or "").startswith(f"role={roles.get(r['COLUMN_NAME'])}")]
    c.check(bool(rows) and [r["COLUMN_NAME"] for r in rows] == list(roles) and not wrong,
            f"{dataset}: all {len(rows)} columns of {view} carry role=<their role> as their comment",
            f"without it: {', '.join(wrong)}" if wrong else f"columns {[r['COLUMN_NAME'] for r in rows]}")
    marked = pump.rows("SELECT COUNT(*) AS N FROM SYS.EXA_ALL_COLUMNS "
                       f"WHERE COLUMN_SCHEMA = {literal(schema)} AND COLUMN_TABLE = {literal(name)} "
                       "AND COLUMN_COMMENT LIKE 'role=%'", f"reading the comments of {table}")
    c.check(marked and marked[0]["N"] == "0", f"{dataset}: {table} itself carries no role= comment")
    reader_count(c, dataset, view, int(shipped["source"]["profiled_rows"]))
    code, out, err = run_exakit("describe", dataset, "--approve", "--role", f"target={target}", "--json")
    again = first_json(out) if code == 0 and "{" in out else {}
    c.check(again.get("status") == "unchanged" and not (store / "v2.yaml").exists(),
            f"{dataset}: approving the same again writes nothing", f"exit {code}, status {again.get('status')}")


def reader_count(c: Checks, dataset: str, view: str, rows: int) -> None:
    """The view is granted to the read-only MCP user: it counts the rows as that user (an exapump profile in a
    temporary HOME, the password copied from its file into a 0600 file there and never printed)."""
    connection = (((manifest().get("components") or {}).get("mcp_server") or {}).get("connection") or {})
    user, pwfile = connection.get("user"), connection.get("password_file")
    dsn = (manifest().get("runtime") or {}).get("dsn") or "127.0.0.1:8563"
    if not user or not pwfile or not Path(pwfile).is_file():
        c.fail(f"{dataset}: no read-only MCP user in the manifest to read {view} as")
        return
    host, _, port = dsn.rpartition(":")
    with tempfile.TemporaryDirectory(prefix="exakit-reader-") as folder:
        config = Path(folder) / ".exapump" / "config.toml"
        config.parent.mkdir()
        config.touch(mode=0o600)
        password = Path(pwfile).read_text(encoding="utf-8").strip()
        config.write_text(f'[reader]\nhost = {json.dumps(host or "127.0.0.1")}\nport = {int(port or 8563)}\n'
                          f'user = {json.dumps(user)}\npassword = {json.dumps(password)}\ntls = true\n'
                          'validate_certificate = false\n', encoding="utf-8")
        del password
        schema, name = view.split(".", 1)
        done = subprocess.run([shutil.which("exapump") or str(Path.home() / ".local" / "bin" / "exapump"), "sql", "-p", "reader"],
                              input=f'SELECT COUNT(*) AS N FROM {schema}."{name}";\n', capture_output=True, text=True,
                              env={**os.environ, "HOME": folder, "EXAPUMP_CONFIG": str(config)}, timeout=600, check=False)
    lines = [line.strip().strip('"') for line in done.stdout.splitlines() if line.strip()]
    c.check(done.returncode == 0 and str(rows) in lines, f"{dataset}: {user} reads {view} ({rows:,} rows)",
            f"exit {done.returncode}: {(done.stderr or done.stdout).strip()[-300:]}")


def cmd_datasets(named: list[str]) -> int:
    ids = reference_ids()
    c = Checks()
    if named and sorted(named) != ids:
        c.fail(f"the datasets named ({', '.join(sorted(named))}) are not the reference datasets with a manifest.json "
               f"({', '.join(ids)}): add the missing ones where they are listed")
        return 1
    if not (home() / "manifest.json").is_file() or exakit() is None:
        return skip(f"no installed kit (no {home() / 'manifest.json'} or exakit)")
    try:
        pump = _pump()
        pump.sql("SELECT 1 FROM DUAL;", "the probe")
    except Exception as broken:                                      # noqa: BLE001
        return skip(f"the database does not answer through exapump: {broken}")
    print(f"reference datasets: {', '.join(ids)}")
    check_loaded(c, pump, ids)
    for dataset in ids:
        shipped = read_yaml(DATASETS / dataset / "descriptor.yaml")
        try:
            if check_draft(c, dataset, shipped):
                check_approve(c, pump, dataset, shipped)
        except Exception as broken:                                  # noqa: BLE001 - one dataset's break, the rest go on
            c.fail(f"{dataset}: the checks stopped ({type(broken).__name__}: {str(broken)[:400]})")
    print(f"{'PASS' if not c.failed else 'FAIL'} reference datasets: {c.failed} check(s) failed")
    return 1 if c.failed else 0


# --- (d) a file of your own -------------------------------------------------------------------------------------------

def write_tickets(path: Path) -> None:
    """1,500 tickets: a key, a date, a 3-value channel, an e-mail (sensitive), a 0/1 outcome and a text (runbook A7)."""
    import datetime as dt
    import random
    rng = random.Random(1)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        out = csv.writer(handle)
        out.writerow(["TICKET_ID", "OPENED_ON", "CHANNEL", "CUSTOMER_EMAIL", "ESCALATED", "BODY"])
        for i in range(1500):
            out.writerow([1000 + i, (dt.date(2025, 1, 1) + dt.timedelta(days=i % 300)).isoformat(),
                          ["web", "phone", "mail"][i % 3], f"customer{i % 400}@example.org", int(rng.random() < 0.1),
                          f"Ticket {i}: the {['invoice', 'delivery', 'password', 'refund'][i % 4]} problem is still open "
                          f"after {i % 9} days"])


def _scalar(conn, sql: str) -> Any:
    row = conn.execute(sql).fetchone()
    return list(row.values())[0] if isinstance(row, dict) else row[0]


def cmd_own_file(path: Path) -> int:
    try:
        import exakit_nb as nb
    except ImportError as broken:
        return skip(f"exakit_nb does not import with {sys.executable} ({broken}): run this with the kit's notebook Python")
    c = Checks()
    write_tickets(path)
    c.ok(f"wrote {path.name} (1,500 rows)")
    conn = nb.connect()
    try:
        nb.load_own_file(path, OWN_TABLE, conn=conn)
        c.check(int(_scalar(conn, f"SELECT COUNT(*) FROM {OWN_TABLE}")) == 1500, f"load_own_file loaded {OWN_TABLE} (1,500 rows)")
        d = nb.describe(OWN_TABLE, conn=conn)
        d.show()
        c.check(d.id == OWN_ID, f"the draft's id is {d.id}", f"expected {OWN_ID}")
        roles = {name: entry["role"] for name, entry in d.doc["columns"].items()}
        c.check(roles == OWN_ROLES, "every column has the role it should", f"drafted {roles}")
        c.check(bool(d.doc["columns"].get("CUSTOMER_EMAIL", {}).get("sensitive")), "CUSTOMER_EMAIL is sensitive")
        c.check("CUSTOMER_EMAIL" not in d.slots.values(), "a sensitive column sits in no slot", f"slots {d.slots}")
        for slot, column in OWN_SLOTS.items():
            c.check(d.slots.get(slot) == column, f"slot {slot} = {d.slots.get(slot)}", f"expected {column}")
        if d.status == "draft":
            c.check(d.slots.get("target") is None, "the target is not drafted", f"drafted {d.slots.get('target')}")
        d.slot(target="ESCALATED")
        ds = d.approve(conn=conn)
        c.check(d.status == "approved" and d.slots.get("target") == "ESCALATED" and ds.id == OWN_ID,
                f"approved {OWN_TABLE} v{d.version} with target ESCALATED; the notebooks open it as {ds.id}")
        view = OWN_TABLE.replace(".", "__")
        comments = conn.execute("SELECT COLUMN_NAME, COLUMN_COMMENT FROM SYS.EXA_ALL_COLUMNS "
                                f"WHERE COLUMN_SCHEMA = {literal(SEMANTIC)} AND COLUMN_TABLE = {literal(view)}").fetchall()
        pairs = [tuple(r.values()) if isinstance(r, dict) else tuple(r) for r in comments]
        wrong = [n for n, text in pairs if not str(text or "").startswith(f"role={OWN_ROLES.get(n)}")]
        c.check(len(pairs) == len(OWN_ROLES) and not wrong, f"published as {SEMANTIC}.{view}, every column comment role=...",
                f"{len(pairs)} columns, without the marker: {', '.join(wrong)}")
    finally:
        conn.close()
    print(f"{'PASS' if not c.failed else 'FAIL'} own file: {c.failed} check(s) failed")
    return 1 if c.failed else 0


# --- (e) no password in what the kit wrote ----------------------------------------------------------------------------

def secrets() -> list[tuple[str, bytes]]:
    """(label, value) of every database password the kit keeps: the admin's, the read-only user's, and every
    *password* file in its credentials folder."""
    files: dict[str, Path] = {}
    try:
        data = manifest()
        admin = (data.get("runtime") or {}).get("password_file")
        reader = (((data.get("components") or {}).get("mcp_server") or {}).get("connection") or {}).get("password_file")
        for label, value in (("admin", admin), ("read-only", reader)):
            if value:
                files[label] = Path(value)
    except (OSError, ValueError):
        pass
    credentials = home() / "credentials"
    if credentials.is_dir():
        for path in sorted(credentials.iterdir()):
            if path.is_file() and "password" in path.name.lower():
                files.setdefault(path.name, path)
    found = []
    for label, path in files.items():
        try:
            value = path.read_text(encoding="utf-8").strip().encode("utf-8")
        except OSError:
            continue
        if len(value) >= MIN_SECRET:
            found.append((label, value))
    return found


def cmd_no_secrets(extra: list[str]) -> int:
    values = secrets()
    if not values:
        return skip(f"no database password file under {home()} to search for")
    folders = [home() / name for name in ("notebooks", "descriptors", "workflows")] + [Path(p) for p in extra]
    c = Checks()
    searched = 0
    for folder in folders:
        if not folder.is_dir():
            print(f"note {folder} is not there")
            continue
        for path in sorted(p for p in folder.rglob("*") if p.is_file() and not p.is_symlink()):
            searched += 1
            try:
                content = path.read_bytes()
            except OSError:
                continue
            for label, value in values:
                if value in content:
                    c.fail(f"the {label} password is in {path}")
    c.check(searched > 0, f"no database password ({len(values)} searched for) in {searched} files under "
            + ", ".join(str(f) for f in folders), "nothing was searched")
    print(f"{'PASS' if not c.failed else 'FAIL'} no secrets: {c.failed} check(s) failed")
    return 1 if c.failed else 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    command, rest = argv[0], argv[1:]
    if command == "datasets":
        return cmd_datasets(rest)
    if command == "own-file" and len(rest) == 1:
        return cmd_own_file(Path(rest[0]).expanduser())
    if command == "no-secrets":
        return cmd_no_secrets(rest)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
