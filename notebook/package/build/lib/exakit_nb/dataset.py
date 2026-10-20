"""A dataset the notebooks run on: its descriptor read, validated by the kit's own rules, held against the database,
and the roles turned into SQL names, so one notebook runs unchanged on any dataset whose descriptor is valid.

    ds = exakit_nb.dataset(conn, "pharma_trials")          # a dataset the kit ships, by id
    ds = exakit_nb.dataset(conn, "~/data/descriptor.json") # or your own table, described by a descriptor file
    ds.col("label"), ds.text_sql(), ds.fact_table

The rules are the kit's descriptor rules (``descriptor_rules``, shipped with this package: the 0.2.0 kit has no Python
package to import them from; tools/dataset_check.py uses the same file). Nothing is guessed: a descriptor that is invalid, or names a table or
column the database lacks, stops the notebook with the reason.
"""

from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

__all__ = ["Dataset", "dataset"]

_ANSWERED = "EXAKIT_NB_COLUMNS"


def _rules():
    """The kit's descriptor rules."""
    from . import descriptor_rules
    return descriptor_rules


def _locate(name: str) -> Path:
    """A descriptor file: a path that exists, else the descriptor of the kit's dataset with that id."""
    given = Path(name).expanduser()
    if given.is_file():
        return given
    if given.is_dir() and (given / "descriptor.json").is_file():
        return given / "descriptor.json"
    folder = os.environ.get("EXAKIT_NB_DATASETS")
    shipped = Path(folder) / name / "descriptor.json" if folder else None
    if shipped is not None and shipped.is_file():
        return shipped
    known = sorted(p.parent.name for p in Path(folder).glob("*/descriptor.json")) if folder else []
    raise ValueError(f"No descriptor for '{name}': not a file, and not a dataset the kit ships"
                     + (f" (those with a descriptor: {', '.join(known)})" if known else "") + ".")


@dataclass(frozen=True)
class Dataset:
    """A validated descriptor whose every role the database holds, with the SQL names the notebooks build queries from."""

    id: str
    path: Path
    digest: str                       # SHA-256 of the descriptor file: the exact mapping a result came from
    descriptor: Any                   # exakit.domain.descriptor.Descriptor

    @property
    def fact_table(self) -> str:
        """``SCHEMA.TABLE`` that one row of analysis comes from."""
        return self.descriptor.fact_table

    def col(self, role: str) -> str:
        """The column of a single-column role (entity, category, date, label)."""
        return self.descriptor.column(role).column

    def text_cols(self) -> list[str]:
        """The text columns, in the descriptor's order."""
        return [ref.column for ref in self.descriptor.roles["text"]]

    def text_sql(self) -> str:
        """One SQL expression joining the text columns with a space, NULLs as empty."""
        parts = [f"COALESCE({c}, '')" for c in self.text_cols()]
        return parts[0] if len(parts) == 1 else " || ' ' || ".join(parts)

    def roles(self) -> list[tuple[str, str]]:
        """(role, SCHEMA.TABLE.COLUMN) for every role, for a table the notebook prints."""
        return [(role, ref.qualified) for role, ref in self.descriptor.references()]

    def tags(self) -> dict[str, str]:
        """What a trace records about the data: the dataset and the descriptor's digest."""
        return {"exasol.dataset": self.id, "exasol.descriptor_sha256": self.digest}


def _columns(conn, schemas: list[str]) -> set[str]:
    """Every SCHEMA.TABLE.COLUMN the database holds in those schemas; a database that does not answer is an error."""
    names = ", ".join(f"'{s}'" for s in schemas)
    result = conn.execute(f"SELECT '{_ANSWERED}' FROM DUAL UNION ALL "
                          "SELECT COLUMN_SCHEMA || '.' || COLUMN_TABLE || '.' || COLUMN_NAME FROM SYS.EXA_ALL_COLUMNS "
                          f"WHERE COLUMN_SCHEMA IN ({names})")
    found = {str(row[0]).upper() for row in result.fetchall()}
    if _ANSWERED not in found:
        raise RuntimeError("The database did not answer, so the descriptor could not be checked.")
    return found - {_ANSWERED}


def dataset(conn, name: str) -> Dataset:
    """The dataset ``name`` (a kit dataset id, or a descriptor file or its folder), checked against the database."""
    rules = _rules()
    path = _locate(name)
    raw = path.read_bytes()
    descriptor = rules.parse_descriptor(raw.decode("utf-8"), source=f"The descriptor {path}")
    problems = rules.missing_references(descriptor, _columns(conn, descriptor.schemas()))
    if problems:
        shipped = os.environ.get("EXAKIT_NB_DATASETS") and Path(os.environ["EXAKIT_NB_DATASETS"]) in path.parents
        raise ValueError(f"The descriptor '{descriptor.id}' does not match the database: {'; '.join(problems)}. "
                         + (f"Load it first: exakit data-load {descriptor.id}" if shipped
                            else "Load your file first (exakit data-load <file>) or correct the descriptor."))
    elsewhere = [f"{role} ({ref.table})" for role, ref in descriptor.references() if ref.table != descriptor.fact_table]
    if elsewhere:
        raise ValueError(f"The notebooks read every role from the fact table {descriptor.fact_table}; these are in "
                         f"another table: {', '.join(elsewhere)}. Describe a table (or a view) that holds them all.")
    _check_rows(conn, descriptor)
    return Dataset(descriptor.id, path, hashlib.sha256(raw).hexdigest(), descriptor)


def _check_rows(conn, descriptor) -> None:
    """The fact table holds rows, and the label is 0 or 1 in every row that has one: the notebooks count and model it."""
    label = descriptor.column("label").column
    found = conn.execute(f"SELECT DISTINCT CAST({label} AS VARCHAR(100)) FROM {descriptor.fact_table} "
                         f"WHERE {label} IS NOT NULL LIMIT 3").fetchall()
    if not found:
        raise ValueError(f"{descriptor.fact_table} has no rows with a label ({label}): load the data first.")
    values = {str(row[0]).strip() for row in found}
    if not values <= {"0", "1"}:
        raise ValueError(f"The label {label} must be 0 or 1; {descriptor.fact_table} also holds "
                         f"{', '.join(sorted(values - {'0', '1'}))}. Describe a column (or a view) that is 0 or 1.")
