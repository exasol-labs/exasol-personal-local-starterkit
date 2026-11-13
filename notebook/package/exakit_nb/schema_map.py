"""Several tables: the schema around a dataset, and one wide view along its links.

A table's column map says what its columns are; the schema map says how the schema's tables fit together - every
table with its rows and key, and every many-to-one link between them, declared by the database or found (a column
that names another table's key and whose every value is in it), each with its evidence. The kit's describe service
does the work (setup/lib/descriptor/schema.py); this module shows it in a notebook and turns it into a dataset:

    schema_map = nb.describe_schema(connection, dataset)        # the tables and the links, as found now
    joined = schema_map.joined_view(dataset)                    # the main table with every table its links reach
    dataset = joined.create(connection)                         # approves the map, creates the view, its column map

Nothing is written before create(): the proposal shows every join and the exact SQL. Then the schema map is approved
(its links become relationships of the schema's Exasol Semantic Views model, for agents), the view goes into EXAKIT_PREPARED and gets
its own approved column map - the main table's roles carried over - so every later step reads the joined data.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from html import escape
from typing import Any


def _service():
    from .describe import describe_service

    service = describe_service()
    if service is None:
        raise RuntimeError("The kit's describe service was not found (no kit copy beside this Python); describe the "
                           "schema on the command line: exakit describe --schema <SCHEMA>")
    return service


def _schema_of(dataset_or_schema: Any) -> str:
    table = getattr(dataset_or_schema, "fact_table", None)
    return (table.split(".")[0] if table else str(dataset_or_schema)).strip('"')


@dataclass
class SchemaMap:
    """The schema as found (a draft) or as approved: ``doc`` holds its tables and links."""
    doc: dict[str, Any] | None
    approved_version: int | None = None
    note: str | None = None

    @property
    def schema(self) -> str:
        return self.doc["schema"] if self.doc else ""

    @property
    def links(self) -> list[dict[str, Any]]:
        return list((self.doc or {}).get("relations") or [])

    def link(self, source: str, target: str) -> "SchemaMap":
        """Add a link the search missed: ``link("ORDERS.CUSTOMER_REF", "CUSTOMERS.ID")``."""
        self.doc = _service().edit_links(self.doc, links=[f"{source}={target}"])
        return self

    def unlink(self, source: str) -> "SchemaMap":
        """Remove a link that is wrong, by the column it starts from: ``unlink("ORDERS.O_CLERK")``."""
        self.doc = _service().edit_links(self.doc, unlinks=[source])
        return self

    def approve(self, connection) -> "SchemaMap":
        """Approve this map (the next version in the store; the schema's semantic model rebuilt with its links)."""
        if self.doc is None:
            return self
        result = _service().approve_schema(connection, self.schema, doc=self.doc)
        print(result.get("message") or f"Approved {result['schema']} v{result['version']} ({result['relations']} links): "
              f"{result['path']}" + (f"; published as {result['published']}" if result.get("published") else ""))
        self.doc = {**self.doc, "status": "approved", "version": result["version"]}
        self.approved_version = result["version"]
        return self

    def joined_view(self, main: Any) -> "JoinedView":
        """The proposal: ``main`` (a dataset, or a table name) with every table its links reach."""
        if self.doc is None:
            return JoinedView(self, None, getattr(main, "fact_table", str(main)), {"joins": []}, getattr(main, "id", None),
                              main if hasattr(main, "fact_table") else None)
        table = getattr(main, "fact_table", str(main))
        built = _service().schema_map.joined_sql(self.doc, table)
        return JoinedView(self, built["view"], built["main"], built, getattr(main, "id", None),
                          main if hasattr(main, "fact_table") else None)

    def _summary(self) -> list[str]:
        if self.doc is None:
            return [self.note or "No schema map."]
        state = (f"approved v{self.approved_version}" if self.doc.get("status") == "approved"
                 else f"a draft (v{self.approved_version} is approved)" if self.approved_version else "a draft")
        tables, links = len(self.doc["tables"]), len(self.links)
        return [f"{self.schema}: {tables} table{'s' * (tables != 1)}, {links} link{'s' * (links != 1)} - {state}"]

    def __str__(self) -> str:
        if self.doc is None:
            return "\n".join(self._summary())
        return _service().schema_text(self.doc)

    __repr__ = __str__                                  # a text-only front end shows the summary, not the fields

    def _repr_html_(self) -> str:
        html = [f"<p><b>{escape(self._summary()[0])}</b></p>"]
        if self.doc:
            rows = "".join(f"<tr><td><code>{escape(t)}</code></td><td style=\"text-align:right\">{int(i.get('rows') or 0):,}</td>"
                           f"<td><code>{escape(', '.join(i.get('key') or []) or '-')}</code></td><td>{escape(str(i.get('key_evidence')))}</td></tr>"
                           for t, i in self.doc["tables"].items())
            html.append("<table><tr><th>Table</th><th>Rows</th><th>Key</th><th>Why</th></tr>" + rows + "</table>")
            if self.links:
                rows = "".join(f"<tr><td><code>{escape(l['from'])}</code></td><td><code>{escape(l['to'])}</code></td>"
                               f"<td>{escape(str(l['evidence']))}</td></tr>" for l in self.links)
                html.append("<table><tr><th>Link from</th><th>To</th><th>Evidence</th></tr>" + rows + "</table>")
            else:
                html.append("<p>No links: every table stands on its own.</p>")
        return "\n".join(html)


@dataclass
class JoinedView:
    """The proposal for one wide view. ``joins`` lists each table it adds and how; ``sql`` is what create() runs."""
    schema_map: SchemaMap
    view: str | None
    main: str
    built: dict[str, Any] = field(default_factory=dict)
    source_id: str | None = None
    source: Any = None
    created: Any = None

    @property
    def joins(self) -> list[dict[str, str]]:
        return list(self.built.get("joins") or [])

    @property
    def needed(self) -> bool:
        """Whether the main table has links to follow at all."""
        return bool(self.joins)

    @property
    def sql(self) -> str:
        if not self.needed:
            return ""
        comment = f"The main table {self.main} with the tables its approved links reach, created by the starter kit"
        return f"CREATE OR REPLACE VIEW {self.view} AS\n{self.built['sql']}\nCOMMENT IS '{comment}'"

    def _state(self) -> str:
        if self.created is not None:
            return f"Created {self.view} and approved its column map: the steps below read it."
        if not self.needed:
            return f"{self.main} links to no other table: there is nothing to join."
        return "Not created yet: nothing has run. To use it, set USE_JOINED = True in the first cell (or call create)."

    def __str__(self) -> str:
        lines = [f"Joined view of {self.main}" + (f" -> {self.view}" if self.needed else "")]
        lines += [f"  + {j['table']} along {j['via']}" for j in self.joins]
        lines.append(self._state())
        if self.needed:
            lines += ["", self.sql]
        return "\n".join(lines)

    __repr__ = __str__                                  # a text-only front end shows the summary, not the fields

    def _repr_html_(self) -> str:
        html = [f"<p><b>Joined view of</b> <code>{escape(self.main)}</code>"
                + (f" &rarr; <code>{escape(self.view)}</code>" if self.needed else "") + "</p>"]
        if self.joins:
            html.append("<ul>" + "".join(f"<li>adds <code>{escape(j['table'])}</code> along <code>{escape(j['via'])}</code></li>"
                                         for j in self.joins) + "</ul>")
        html.append(f"<p>{escape(self._state())}</p>")
        if self.needed:
            html.append(f"<pre style=\"white-space: pre-wrap\">{escape(self.sql)}</pre>")
        return "\n".join(html)

    def create(self, connection) -> Any:
        """Approve the schema map (when it is a draft), create the view, describe it with the main table's roles
        carried over and approve that; returns the view's dataset. With nothing to join, the dataset as it was."""
        if not self.needed:
            print(self._state())
            return self.source
        from . import describe as describe_table
        from .dataset import remember_dataset
        from .workflow import log_sql

        if self.schema_map.doc.get("status") != "approved":
            self.schema_map.approve(connection)
        for statement in ("CREATE SCHEMA IF NOT EXISTS EXAKIT_PREPARED", self.sql):
            connection.execute(statement)
            log_sql(connection, statement, None)
        schema, name = self.view.split(".", 1)
        base = (self.source_id or self.main.split(".")[-1].lower()).removesuffix("_joined")
        draft = describe_table(f"{schema}.{name.strip(chr(34))}", conn=connection, id=f"{base}_joined", force=True)
        if self.source is not None:
            columns = dict(getattr(self.source.descriptor, "columns", {}) or {})
            draft.set(**{c: e["role"] for c, e in columns.items() if e.get("role") and c in draft.doc["columns"]})
            slots = dict(getattr(self.source.descriptor, "slots", {}) or {})
            draft.slot(**{slot: None for slot in slots})
            draft.slot(**{slot: (c[0] if isinstance(c, list) else c) for slot, c in slots.items()
                          if c and (c[0] if isinstance(c, list) else c) in draft.doc["columns"]})
        self.created = draft.approve(conn=connection)
        remember_dataset(self.created)
        print(self._state())
        return self.created


def describe_schema(connection, dataset_or_schema: Any) -> SchemaMap:
    """The schema of ``dataset_or_schema`` (a dataset, or a schema name) as found now: its tables, rows and keys, and
    every many-to-one link between them with its evidence. A live source's schema is not surveyed (its tables are
    queried in place, every count a round trip)."""
    if getattr(dataset_or_schema, "source", None):
        return SchemaMap(None, note=f"{dataset_or_schema.fact_table} is a live source: its schema is not surveyed.")
    service = _service()
    found = service.describe_schema(connection, _schema_of(dataset_or_schema))
    return SchemaMap(found["doc"], found["approved"])
