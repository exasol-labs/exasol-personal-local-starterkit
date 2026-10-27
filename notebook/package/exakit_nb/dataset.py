"""A dataset the notebooks run on: its descriptor read, validated by the kit's own rules, held against the database,
and the roles turned into SQL names, so one notebook runs unchanged on any dataset whose descriptor is valid.

    ds = nb.dataset(conn, "pharma_trials")             # a dataset the kit ships, by id
    ds = nb.dataset(conn, "~/data/descriptor.yaml")    # a table already in the database, described by a descriptor file
    ds = nb.dataset(conn, "~/data/sales.csv")          # your own CSV, Parquet or JSON file, its descriptor beside it
    ds.col("label"), ds.text_sql(), ds.fact_table, ds.source
    ds.version, ds.status, ds.owner, ds.created, ds.table_digest    # the descriptor's record (schema_version 2)
    ds.require_approved("training")                    # a draft stops here with how to approve it

The rules are the kit's descriptor rules (``descriptor_rules``, shipped with this package: the 0.2 kit has no Python
package to import them from). It is a copy of tools/descriptor_rules.py, which tools/dataset_check.py uses, and
tests/test_notebook_contents.py holds the two byte-identical. Nothing is guessed: a descriptor that is invalid, or
names a table or column the database lacks, stops the notebook with the reason.

Which descriptor a name resolves to, in order: a path given (a file, or a folder holding descriptor.yaml); for a
data file of your own, ``<name>.descriptor.yaml`` beside it; for an id, the approved version in the kit's store
(``~/.exasol-starter-kit/descriptors/<id>/current``, descriptor_store), then the descriptor the kit ships under
``data/datasets/<id>/``. ``ds.descriptor_path`` and ``ds.descriptor_origin`` say which one was used.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ._kit import setting

__all__ = ["DATA_FILES", "Dataset", "DescriptorNotApproved", "checked", "dataset"]

_ANSWERED = "EXAKIT_NB_COLUMNS"
DATA_FILES = (".csv", ".parquet", ".pq", ".json", ".jsonl", ".ndjson")     # what load_own_file reads


def _rules():
    """The kit's descriptor rules."""
    from . import descriptor_rules
    return descriptor_rules


class DescriptorNotApproved(Exception):
    """A step that needs an approved descriptor was given a draft; the message says how to approve it."""


ORIGINS = ("explicit", "beside", "store", "shipped")    # where a descriptor was read from, see the module docstring


def _locate(name: str) -> tuple[Path, str]:
    """(descriptor file, origin): a path that exists ("explicit"), else the approved version in the kit's store
    ("store"), else the descriptor of the kit's dataset with that id ("shipped")."""
    given = Path(name).expanduser()
    if given.is_file():
        return given, "explicit"
    rules = _rules()
    if given.is_dir() and rules.descriptor_file(given) is not None:
        return rules.descriptor_file(given), "explicit"
    if rules._ID.match(name):
        from .descriptor_store import current_descriptor

        stored = current_descriptor(name)
        if stored is not None:
            return stored, "store"
    folder = setting("EXAKIT_NB_DATASETS")
    shipped = rules.descriptor_file(Path(folder) / name) if folder and (Path(folder) / name).is_dir() else None
    if shipped is not None:
        return shipped, "shipped"
    known = sorted(p.name for p in Path(folder).iterdir() if p.is_dir() and rules.descriptor_file(p)) if folder else []
    raise ValueError(f"No descriptor for '{name}': not a file, not approved in the kit's store, and not a dataset the "
                     "kit ships" + (f" (those with a descriptor: {', '.join(known)})" if known else "") + ".")


@dataclass(frozen=True)
class Dataset:
    """A validated descriptor whose every role the database holds, with the SQL names the notebooks build queries from."""

    id: str
    path: Path
    digest: str                       # SHA-256 of the descriptor file: the exact mapping a result came from
    descriptor: Any                   # descriptor_rules.Descriptor
    descriptor_path: Path | None = None      # the file the descriptor was read from (``path`` for a descriptor file;
    descriptor_origin: str = "explicit"      # for a data file the one beside it), and where it came from (ORIGINS)

    @property
    def fact_table(self) -> str:
        """``SCHEMA.TABLE`` that one row of analysis comes from."""
        return self.descriptor.fact_table

    @property
    def source(self) -> str | None:
        """The external source's alias when the table is in a virtual schema (a live source), else None - what
        confirm_send and the quickstart ask about. ``source_ref`` is the descriptor's source as written."""
        return self.descriptor.live_source

    @property
    def source_ref(self) -> str | None:
        """The descriptor's ``source`` as written: a dataset id, ``file:<path>``, ``vs:<alias>`` (or a schema_version
        1 file's bare alias), or None."""
        return self.descriptor.source

    # --- the descriptor's record (schema_version 2; a schema_version 1 file reads as version 1, approved, by the kit)

    @property
    def version(self) -> int:
        """The descriptor's version: 1 for a first draft or a shipped file; approving writes the next."""
        return self.descriptor.version

    @property
    def status(self) -> str:
        """``draft`` (proposed, not yet confirmed) or ``approved``."""
        return self.descriptor.status

    @property
    def owner(self) -> str:
        """Who drafted or approved it (``kit`` for a shipped descriptor)."""
        return self.descriptor.owner

    @property
    def created(self) -> str | None:
        """When this version was written (ISO-8601), None for a schema_version 1 file."""
        return self.descriptor.created

    @property
    def table_digest(self) -> str | None:
        """The digest of the table the descriptor was approved on (its ``digest`` key), None until it is computed.
        ``digest`` is the descriptor file's own SHA-256."""
        return self.descriptor.digest

    @property
    def drafted_by(self) -> str:
        """``profile`` (exakit describe), ``shipped`` (the kit) or ``user`` (roles given by hand)."""
        return self.descriptor.drafted_by

    @property
    def evidence(self) -> dict[str, dict[str, Any]]:
        """Per role, the numbers that chose its column (what the profiler recorded; empty for roles given by hand)."""
        return self.descriptor.evidence

    @property
    def notes(self) -> dict[str, str]:
        """Per column, a model-written line about it (never decisive; empty without a model)."""
        return self.descriptor.notes

    @property
    def missing(self) -> tuple[dict[str, str], ...]:
        """The roles no column fits, each ``{role, reason}``; the notebooks skip what depends on them with the reason."""
        return self.descriptor.missing

    def require_approved(self, purpose: str) -> "Dataset":
        """This dataset when its descriptor is approved; a draft raises DescriptorNotApproved saying how to approve
        it. ``purpose`` names the step that needs it ("training", "the question step", ...)."""
        if self.status != "approved":
            raise DescriptorNotApproved(
                f"{purpose} needs an approved descriptor: {self.id} is a draft (v{self.version}). Approve it: in the "
                f"quickstart run approve(), or: exakit describe {self.id} --approve")
        return self

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

    def has(self, role: str) -> bool:
        """Whether a column plays ``role`` (False for one listed under ``missing``)."""
        return role in self.descriptor.roles

    def tags(self) -> dict[str, str]:
        """What a trace or an MLflow run records about the data: the dataset and the descriptor's digest (and the
        source's alias for a live source)."""
        tags = {"exasol.dataset": self.id, "exasol.descriptor": self.digest}
        if self.source:
            tags["exasol.source"] = self.source
        return tags


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


def dataset(conn, name: str | Path) -> Dataset:
    """The dataset ``name``, checked against the database: a kit dataset id, a descriptor file or its folder, or a data
    file of your own (CSV, Parquet or JSON) with its descriptor beside it, which is loaded first (load_own_file)."""
    given = Path(name).expanduser()
    if given.is_file() and given.suffix.lower() in DATA_FILES:
        from .own_file import descriptor_beside, load_own_file

        described = descriptor_beside(given)
        if described is None:
            raise ValueError(f"{given.name} has no descriptor beside it ({given.stem}.descriptor.yaml or descriptor.yaml "
                             "in its folder). Load it once with load_own_file(path, table, roles), which writes one.")
        return load_own_file(given, None, described, conn=conn)
    path, origin = _locate(str(name))
    remedy = "Load your file first (exakit data-load <file>) or correct the descriptor."
    return checked(conn, path.read_bytes(), path, remedy=None if origin == "shipped" else remedy, origin=origin)


def checked(conn, raw: bytes, path: Path, remedy: str | None = None, *, descriptor_path: Path | None = None,
            origin: str = "explicit") -> Dataset:
    """The descriptor in ``raw`` (read from, or describing, ``path``) validated by the kit's rules and held against the
    database: every role resolves, all in the fact table, which has rows and a 0/1 label. ``remedy`` is the advice for a
    role the database lacks (None: load the kit dataset). ``descriptor_path`` is the file the descriptor was read from
    when that is not ``path`` (a data file's descriptor beside it), ``origin`` one of ORIGINS."""
    rules = _rules()
    descriptor = rules.parse_descriptor(raw.decode("utf-8"), source=f"The descriptor {path}")
    problems = rules.missing_references(descriptor, _columns(conn, descriptor.schemas()))
    if problems:
        raise ValueError(f"The descriptor '{descriptor.id}' does not match the database: {'; '.join(problems)}. "
                         + (remedy or f"Load it first: exakit data-load {descriptor.id}"))
    elsewhere = [f"{role} ({ref.table})" for role, ref in descriptor.references() if ref.table != descriptor.fact_table]
    if elsewhere:
        raise ValueError(f"The notebooks read every role from the fact table {descriptor.fact_table}; these are in "
                         f"another table: {', '.join(elsewhere)}. Describe a table (or a view) that holds them all.")
    _check_rows(conn, descriptor)
    return Dataset(descriptor.id, path, hashlib.sha256(raw).hexdigest(), descriptor,
                   descriptor_path=descriptor_path if descriptor_path is not None else path, descriptor_origin=origin)


def _check_rows(conn, descriptor) -> None:
    """The fact table holds rows, and the label is 0 or 1 in every row that has one: the notebooks count and model it.
    A descriptor whose label is listed as missing has nothing to check here; the steps that need it say so."""
    if "label" not in descriptor.roles:
        return
    label = descriptor.column("label").column
    found = conn.execute(f"SELECT DISTINCT CAST({label} AS VARCHAR(100)) FROM {descriptor.fact_table} "
                         f"WHERE {label} IS NOT NULL LIMIT 3").fetchall()
    if not found:
        raise ValueError(f"{descriptor.fact_table} has no rows with a label ({label}): load the data first.")
    values = {str(row[0]).strip() for row in found}
    if not values <= {"0", "1"}:
        raise ValueError(f"The label {label} must be 0 or 1; {descriptor.fact_table} also holds "
                         f"{', '.join(sorted(values - {'0', '1'}))}. Describe a column (or a view) that is 0 or 1.")
