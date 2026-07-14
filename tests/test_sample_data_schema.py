"""Offline consistency checks for the sample dataset schema and load pipeline.

No database connection required — these guard against the kind of drift a
live smoke test cannot catch quickly: sql/01_create_schema.sql silently
falling out of sync with data/*.csv (column renamed, reordered, or a table
dropped from one side but not the other), or a table losing verification
coverage in sql/03_verify_setup.sql.

Run with: python3 -m unittest discover -s tests -p 'test_*.py'
"""

from __future__ import annotations

import csv
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data" / "datasets" / "tpch" / "data"
SCHEMA_SQL = ROOT / "data" / "datasets" / "tpch" / "01_create_schema.sql"
LOAD_SQL = ROOT / "data" / "datasets" / "tpch" / "02_load_data.sql"
VERIFY_SQL = ROOT / "data" / "datasets" / "tpch" / "03_verify_setup.sql"
EXAPUMP_LIB = ROOT / "setup" / "lib" / "exapump.sh"
EXAPUMP_PS1 = ROOT / "setup" / "lib" / "exapump.ps1"
COMMON_LIB = ROOT / "setup" / "lib" / "common.sh"
LOAD_DATA_SH = ROOT / "setup" / "load-data.sh"
EXAKIT_CLI = ROOT / "setup" / "exakit"

# Fixed row counts at TPC-H scale factor 0.02, per data/README.md and
# data/data-dictionary.md. lineitem is generator-dependent (~120K) and is
# checked separately with a bound rather than an exact count.
EXPECTED_ROW_COUNTS = {
    "region": 5,
    "nation": 25,
    "customer": 3000,
    "supplier": 200,
    "part": 4000,
    "partsupp": 16000,
    "orders": 30000,
}

CREATE_TABLE_RE = re.compile(
    r"CREATE OR REPLACE TABLE\s+(\w+)\s*\((.*?)\n\);",
    re.IGNORECASE | re.DOTALL,
)


def _parse_schema_columns() -> dict[str, list[str]]:
    """table_name (lowercase) -> ordered list of column names (lowercase)."""
    sql = SCHEMA_SQL.read_text(encoding="utf-8")
    tables: dict[str, list[str]] = {}
    for match in CREATE_TABLE_RE.finditer(sql):
        table_name = match.group(1).lower()
        body = match.group(2)
        columns = []
        for line in body.splitlines():
            line = line.strip().rstrip(",")
            if not line or line.upper().startswith("CONSTRAINT"):
                continue
            columns.append(line.split()[0].lower())
        tables[table_name] = columns
    return tables


def _csv_header(table_name: str) -> list[str]:
    csv_path = DATA_DIR / f"{table_name}.csv"
    with csv_path.open(newline="", encoding="utf-8") as handle:
        return next(csv.reader(handle))


def _function_block(text: str, function_name: str, end_marker: str | None = None) -> str:
    start = text.index(function_name)
    if end_marker is not None:
        next_function = text.find(end_marker, start + len(function_name))
    else:
        next_function = text.find("\nfunction ", start + len(function_name))
    if next_function == -1:
        next_function = len(text)
    return text[start:next_function]


class SchemaMatchesCsvTests(unittest.TestCase):
    """sql/01_create_schema.sql must declare exactly the columns each CSV has, in order."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.schema_tables = _parse_schema_columns()

    def test_schema_file_declares_every_dataset_table(self) -> None:
        expected_tables = {p.stem for p in DATA_DIR.glob("*.csv")}
        self.assertTrue(expected_tables, "No CSV files found under data/ — dataset missing.")
        missing = expected_tables - set(self.schema_tables)
        self.assertFalse(
            missing,
            f"sql/01_create_schema.sql is missing CREATE TABLE statements for: {sorted(missing)}",
        )

    def test_schema_columns_match_csv_header_order(self) -> None:
        for table_name, schema_columns in self.schema_tables.items():
            csv_path = DATA_DIR / f"{table_name}.csv"
            if not csv_path.exists():
                continue
            with self.subTest(table=table_name):
                csv_columns = [c.lower() for c in _csv_header(table_name)]
                self.assertEqual(
                    schema_columns,
                    csv_columns,
                    f"Column order/names for {table_name} differ between "
                    "sql/01_create_schema.sql and data/{table_name}.csv "
                    "(exapump loads positionally, so this must match exactly).",
                )

    def test_every_table_has_a_primary_key(self) -> None:
        sql = SCHEMA_SQL.read_text(encoding="utf-8").upper()
        for table_name in self.schema_tables:
            with self.subTest(table=table_name):
                self.assertIn(
                    f"{table_name.upper()}_PK",
                    sql,
                    f"Table {table_name} has no PRIMARY KEY constraint declared.",
                )


class RowCountRegressionTests(unittest.TestCase):
    """Catch a truncated or partially-regenerated CSV before it reaches the database."""

    def test_fixed_size_tables_match_expected_row_counts(self) -> None:
        for table_name, expected in EXPECTED_ROW_COUNTS.items():
            csv_path = DATA_DIR / f"{table_name}.csv"
            with self.subTest(table=table_name):
                self.assertTrue(csv_path.exists(), f"{csv_path} is missing.")
                with csv_path.open(newline="", encoding="utf-8") as handle:
                    row_count = sum(1 for _ in handle) - 1  # minus header
                self.assertEqual(
                    row_count,
                    expected,
                    f"{csv_path.name} has {row_count} data rows, expected {expected}.",
                )

    def test_lineitem_row_count_is_within_expected_bounds(self) -> None:
        csv_path = DATA_DIR / "lineitem.csv"
        with csv_path.open(newline="", encoding="utf-8") as handle:
            row_count = sum(1 for _ in handle) - 1
        # 1-7 line items per order, 30000 orders.
        self.assertGreaterEqual(row_count, 30000)
        self.assertLessEqual(row_count, 210000)


class LoadPipelineFilesTests(unittest.TestCase):
    """setup/load-data.sh's three consumed SQL files must exist, be non-empty,
    and 03_verify_setup.sql must not silently drop coverage for a table."""

    def test_all_pipeline_sql_files_exist_and_are_non_empty(self) -> None:
        for path in (SCHEMA_SQL, LOAD_SQL, VERIFY_SQL):
            with self.subTest(path=path):
                self.assertTrue(path.exists(), f"{path} is missing.")
                self.assertGreater(path.stat().st_size, 0, f"{path} is empty.")

    def test_verify_script_checks_every_table(self) -> None:
        verify_sql = VERIFY_SQL.read_text(encoding="utf-8").upper()
        schema_tables = _parse_schema_columns()
        for table_name in schema_tables:
            with self.subTest(table=table_name):
                self.assertIn(
                    table_name.upper(),
                    verify_sql,
                    f"sql/03_verify_setup.sql does not mention table {table_name.upper()} "
                    "— it was likely added to the schema without adding verification coverage.",
                )


class LoadWiringTests(unittest.TestCase):
    """Lock in the interactive-load wiring so it cannot silently regress:
    one shared pipeline, invoked from all three entry points, with the kit's
    assets copied where the post-install commands expect them."""

    def test_shared_pipeline_function_is_defined_once(self) -> None:
        exapump = EXAPUMP_LIB.read_text(encoding="utf-8")
        self.assertIn(
            "exakit_load_sample_data()",
            exapump,
            "setup/lib/exapump.sh must define the shared exakit_load_sample_data pipeline.",
        )

    def test_load_data_script_delegates_and_does_not_duplicate_pipeline(self) -> None:
        load_sh = LOAD_DATA_SH.read_text(encoding="utf-8")
        self.assertIn(
            "exakit_load_sample_data",
            load_sh,
            "setup/load-data.sh should call the shared function, not reimplement the load.",
        )
        # The load pipeline must live in exactly one place — the script must
        # not carry its own copy of the upload/verify/manifest steps.
        for reimplemented in ("exapump_upload ", "manifest_set data.loaded"):
            self.assertNotIn(
                reimplemented,
                load_sh,
                f"setup/load-data.sh re-implements '{reimplemented.strip()}' instead of "
                "delegating to exakit_load_sample_data.",
            )

    def test_installer_offers_load_and_copies_assets(self) -> None:
        common = COMMON_LIB.read_text(encoding="utf-8")
        self.assertIn(
            "exakit_maybe_offer_data_load",
            common,
            "kit_shared_steps must offer the interactive sample-data load during install.",
        )
        # data/ and load-data.sh must be copied into the kit home so the
        # documented post-install commands keep working after the checkout
        # is gone (mcp/ and sql/ are copied for the same reason).
        self.assertIn('cp -R "$_kit_root/data"', common)
        self.assertIn("load-data.sh", common)

    def test_exakit_cli_exposes_load_data_command(self) -> None:
        cli = EXAKIT_CLI.read_text(encoding="utf-8")
        self.assertIn("data-load)", cli, "exakit must dispatch the single 'data-load' subcommand.")
        self.assertNotIn("load-data)", cli, "exakit must not expose a duplicate 'load-data' subcommand.")
        self.assertNotIn("mcp-configs)", cli, "exakit must not expose a temporary MCP config command.")
        self.assertIn("cmd_data_load", cli)

    def test_guided_data_load_menu_is_focused(self) -> None:
        """Both data menus route through ONE dynamic selector: bundled datasets
        that are not loaded yet (discovered from data/datasets/*/dataset.conf),
        a local-file option, and a mutually exclusive opt-out."""
        bash = EXAPUMP_LIB.read_text(encoding="utf-8")
        ps1 = EXAPUMP_PS1.read_text(encoding="utf-8")
        # Standalone menus delegate to the shared selector with a plain Cancel.
        self.assertIn('exakit_data_load_select "Cancel (load nothing)"', bash)
        self.assertIn('Select-ExakitDataLoad -FinalLabel "Cancel (load nothing)"', ps1)
        # The selector offers the local-file source on both platforms.
        for text, name in ((bash, "exapump.sh"), (ps1, "exapump.ps1")):
            with self.subTest(menu=name):
                self.assertIn("A local CSV/Parquet file", text)
                for removed_option in (
                    "Remote CSV/Text File",
                    "Import from Another Database",
                    "Import from Another Exasol",
                    "SQL Script",
                ):
                    self.assertNotIn(
                        removed_option,
                        text,
                        f"Guided data-load menu should not show advanced option: {removed_option}",
                    )

    def test_bundled_datasets_are_discovered_from_conf_files(self) -> None:
        """Dataset labels live in data/datasets/<id>/dataset.conf — nothing is
        hardcoded in the menus, so adding a dataset is dropping in a folder."""
        datasets_dir = ROOT / "data" / "datasets"
        confs = sorted(datasets_dir.glob("*/dataset.conf"))
        ids = set()
        for conf in confs:
            kv = dict(
                line.split("=", 1)
                for line in conf.read_text(encoding="utf-8").splitlines()
                if "=" in line
            )
            self.assertIn("id", kv, f"{conf} is missing id=")
            self.assertIn("label", kv, f"{conf} is missing label=")
            self.assertIn("markers", kv, f"{conf} is missing markers=")
            ids.add(kv["id"])
        self.assertIn("tpch", ids, "TPC-H must be a folder dataset like the others.")
        self.assertGreaterEqual(len(ids), 3, "The kit ships at least three bundled datasets.")
        # TPC-H keeps its historical manifest flag so existing installs stay recognized.
        tpch_conf = (datasets_dir / "tpch" / "dataset.conf").read_text(encoding="utf-8")
        self.assertIn("flag=data.loaded", tpch_conf)

    def test_tpch_dataset_folder_is_complete(self) -> None:
        tpch = ROOT / "data" / "datasets" / "tpch"
        for required in ("dataset.conf", "01_create_schema.sql", "02_load_data.sql", "03_verify_setup.sql"):
            self.assertTrue((tpch / required).is_file(), f"missing {required} in data/datasets/tpch/")
        csvs = {p.name for p in (tpch / "data").glob("*.csv")}
        self.assertEqual(
            csvs,
            {
                "customer.csv", "lineitem.csv", "nation.csv", "orders.csv",
                "part.csv", "partsupp.csv", "region.csv", "supplier.csv",
            },
        )

    def test_install_offer_uses_skip_wording(self) -> None:
        """The installer's data step uses the same dynamic selector, but its
        opt-out reads 'Skip for now' (install mode) rather than 'Cancel'."""
        common = COMMON_LIB.read_text(encoding="utf-8")
        exapump_ps1 = EXAPUMP_PS1.read_text(encoding="utf-8")
        self.assertIn('exakit_data_load_select "Skip for now (no data loading)"', common)
        self.assertIn('Select-ExakitDataLoad -FinalLabel "Skip for now (no data loading)"', exapump_ps1)

    def test_local_file_data_load_can_return_to_menu(self) -> None:
        local_file_blocks = (
            (
                EXAPUMP_LIB.name,
                _function_block(
                    EXAPUMP_LIB.read_text(encoding="utf-8"),
                    "exakit_load_local_file()",
                    "\nexakit_load_remote_file()",
                ),
            ),
            (EXAPUMP_PS1.name, _function_block(EXAPUMP_PS1.read_text(encoding="utf-8"), "function Import-ExakitLocalFile")),
        )
        for menu_name, local_file_flow in local_file_blocks:
            with self.subTest(menu=menu_name):
                self.assertIn("type back to return", local_file_flow)
                self.assertIn("Please enter a local CSV/Parquet file path", local_file_flow)
                self.assertIn("back to return", local_file_flow)
                self.assertIn("Returning to data loading options.", local_file_flow)


class DatabaseReadinessTests(unittest.TestCase):
    """Lock in the first-boot readiness fix so it cannot silently regress.

    Right after first boot the Nano database answers SELECT 1 while still
    stabilizing, and in that window it can ACK a DDL batch ("0 failed") without
    durably persisting it — the schema-creation step "succeeds" but the next
    upload fails with "schema not found". Two guards must stay in place and in
    sync across the bash and PowerShell paths: (1) a DDL write-readback probe
    gating connection validation, and (2) a verify-after-create step in the
    sample-data pipeline."""

    def test_bash_gates_connection_on_ddl_roundtrip(self) -> None:
        text = EXAPUMP_LIB.read_text(encoding="utf-8")
        self.assertIn("exapump_ddl_roundtrip()", text)
        self.assertIn("exapump_confirm_database_ready()", text)
        # The probe must round-trip a written value through a fresh connection,
        # not merely run a statement (a bare CREATE would not catch the bug).
        self.assertIn("EXAKIT_READY_PROBE", text)
        self.assertIn("EXAKIT_DDL[42]", text)
        # confirm_database_ready must be defined AND called (>= 2 occurrences);
        # its only caller is exapump_validate_connection.
        self.assertGreaterEqual(text.count("exapump_confirm_database_ready"), 2)

    def test_powershell_gates_connection_on_ddl_roundtrip(self) -> None:
        text = EXAPUMP_PS1.read_text(encoding="utf-8")
        self.assertIn("function Test-ExapumpDdlRoundtrip", text)
        self.assertIn("function Confirm-ExapumpDatabaseReady", text)
        self.assertIn("EXAKIT_READY_PROBE", text)
        # The PowerShell probe no longer scrapes a rendered-grid token (exapump
        # omits the grid when stdout is a pipe — see Test-ExapumpDdlRoundtrip);
        # it must still write a value and read it back from a fresh connection.
        self.assertIn("INSERT INTO $probe.READY_PROBE VALUES (42)", text)
        self.assertIn("WHERE n = 42", text)
        self.assertGreaterEqual(text.count("Confirm-ExapumpDatabaseReady"), 2)

    def test_sample_data_pipeline_verifies_schema_after_creation(self) -> None:
        # Both pipelines must confirm the schema really landed (from a fresh
        # connection) after running 01_create_schema.sql, rather than trusting
        # exapump's "0 failed" and marching into doomed uploads.
        bash = EXAPUMP_LIB.read_text(encoding="utf-8")
        self.assertIn("exakit_schema_present()", bash)
        self.assertIn("is not present after creation", bash)
        ps1 = EXAPUMP_PS1.read_text(encoding="utf-8")
        self.assertIn("function Test-ExapumpSchemaPresent", ps1)
        self.assertIn("is not present after creation", ps1)


if __name__ == "__main__":
    unittest.main()
