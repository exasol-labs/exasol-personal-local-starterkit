"""Working across sources: which system a table lives in, what a table links to in other tables, and the one query
that reads them together - no copy, no pipeline.

    nb.systems(["VS_SALES.ORDERS", "MY_DATA.TARGETS"])   # {"VS_SALES.ORDERS": "Snowflake", "MY_DATA.TARGETS": "this database"}
    nb.read_from(sql)                                     # ["Snowflake", "MongoDB"]: the systems a query reads, live
    nb.linked_groups(dataset)                             # groups of the tables this one links to (saved in your data map)
    nb.across_sql(dataset, group)                         # rows of this table per group of a linked table, in one query

Everything here reads the kit's own records - the sources `exakit connect` keeps and the links saved in your data
map - never the database. With one source, or no saved link, the lists are empty and nothing changes.
"""

from __future__ import annotations

import re
from typing import Any

__all__ = ["across_sql", "linked_groups", "read_from", "systems"]

HERE = "this database"


def _service():
    from .describe import describe_service

    return describe_service()


def _origins() -> dict[str, dict[str, str]]:
    try:
        return dict(_service().publishing.source_origins())
    except Exception:
        return {}


def _plain(table: str) -> str:
    return str(table).replace('"', "").upper()


def systems(tables: list[str]) -> dict[str, str]:
    """{SCHEMA.TABLE: the system it lives in}: a connected source's own name (Snowflake, MongoDB, PostgreSQL, Amazon
    S3 ...) for a table read live, else "this database"."""
    origins = _origins()
    return {t: (origins.get(_plain(t).split(".", 1)[0]) or {}).get("connector_name") or HERE for t in tables}


def read_from(sql: str) -> list[str]:
    """The systems a query reads, in the order it names them: every SCHEMA.TABLE after FROM or JOIN, looked up in the
    kit's record of connected sources. A query over one local table gives ["this database"]."""
    found = re.findall(r'(?:FROM|JOIN)\s+"?([A-Za-z_][A-Za-z0-9_]*)"?\s*\.\s*"?([A-Za-z_][A-Za-z0-9_$]*)"?', str(sql), flags=re.I)
    named = systems([f"{schema}.{table}" for schema, table in found])
    return list(dict.fromkeys(named.values()))


def _links(table: str) -> list[dict[str, str]]:
    """The saved links that start at ``table``: {column, to, key}, from the data map over all your data and the
    table's own schema map."""
    try:
        publishing = _service().publishing
    except Exception:
        return []
    schema = _plain(table).split(".", 1)[0]
    out: list[dict[str, str]] = []
    for model in ("all_data", schema):
        spec = (publishing.kept(model) or {}).get("spec") or {}
        names = {e["name"]: f"{e['schema']}.{e['table']}" for e in spec.get("entities") or []}
        for r in spec.get("relationships") or []:
            if _plain(names.get(r["from"], "")) != _plain(table):
                continue
            link = {"column": r["from_column"], "to": names.get(r["to"], ""), "key": r["to_column"]}
            if link["to"] and link not in out:
                out.append(link)
    return out


def linked_groups(dataset: Any) -> list[dict[str, str]]:
    """The groups this table can be compared by that live in another table: for every saved link from the dataset's
    table, each category or flag column of the table it points at (never a personal-data one). Each is {value, label,
    table, column, link_column, key, system}; ``value`` goes to nb.across_sql. [] when no link is saved."""
    from .descriptor_store import approved_datasets

    table = str(dataset.fact_table)
    try:
        service = _service()
        approved = {_plain(a["table"]) for a in approved_datasets()}
    except Exception:
        return []
    out = []
    for link in _links(table):
        if _plain(link["to"]) not in approved:
            continue
        try:
            doc = service.flow.load(service.store.current(link["to"]))
        except Exception:
            continue
        where = systems([link["to"]])[link["to"]]
        for column, entry in (doc.get("columns") or {}).items():
            if entry.get("role") in ("category", "flag") and not entry.get("sensitive"):
                short = link["to"].split(".", 1)[1]
                out.append({"value": f"{link['to']}::{column}", "label": f"{column} · from {short} ({where})",
                            "table": link["to"], "column": column, "link_column": link["column"], "key": link["key"],
                            "system": where})
    return out


def across_sql(dataset: Any, group: str | dict[str, str], *, limit: int = 15) -> str:
    """Rows of the dataset's table per group of a linked table, in one query: the join the saved link says, each
    table read where it lives. ``group`` is one of nb.linked_groups(dataset) (or its ``value``)."""
    from .readout import count_name, name

    if not isinstance(group, dict):
        group = next((g for g in linked_groups(dataset) if g["value"] == group), None)
        if group is None:
            raise ValueError("That group is not one of nb.linked_groups(dataset): save the link between the two tables first.")
    header, count = name(group["column"]), count_name(dataset)
    rate = ""
    if dataset.has("label"):
        label = dataset.col("label")
        rate = f',\n       ROUND(100 * AVG(a.{label}), 1) AS {name(label, "PCT")}'
    return (f'SELECT b."{group["column"]}" AS {header},\n       COUNT(*) AS {count}{rate}\n'
            f'FROM {dataset.fact_table} a\nJOIN {group["table"]} b ON a."{group["link_column"]}" = b."{group["key"]}"\n'
            f"GROUP BY 1\nORDER BY {count} DESC\nLIMIT {int(limit)}")
