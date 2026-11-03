"""Step 5 of the descriptor plan: where agents read the roles - a view in EXAKIT_SEMANTIC, one path for local and
virtual tables alike. The user's own tables are never commented or altered.

    CREATE OR REPLACE VIEW EXAKIT_SEMANTIC."BANKING__COMPLAINTS" (
      "COMPLAINT_ID" COMMENT IS 'role=key; descriptor=v3',
      "ZIP_CODE"     COMMENT IS 'role=identifier; sensitive; descriptor=v3'
    ) AS SELECT "COMPLAINT_ID", "ZIP_CODE" FROM "BANKING"."COMPLAINTS"
    COMMENT IS 'grain=one row per complaint; source=BANKING.COMPLAINTS; descriptor=v3';
    GRANT SELECT ON EXAKIT_SEMANTIC."BANKING__COMPLAINTS" TO <the kit's read-only MCP user>;

CREATE OR REPLACE drops grants, so the GRANT runs after every publish. A view's comments can only be set in CREATE
VIEW, so a republish is a full replace. Comments stop at 2,000 characters: the note is trimmed, never the role
marker. Columns are named, not *, so the view stays valid when the source gains a column. EXA_ALL_COLUMNS is read
back afterwards and every column must carry its marker.
"""

from __future__ import annotations

from typing import Any, Callable

SCHEMA = "EXAKIT_SEMANTIC"
COMMENT_LIMIT = 2000


def quoted(name: str) -> str:
    return '"' + name.replace('"', '""') + '"'


def literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def view_name(table: str) -> str:
    schema, name = table.split(".", 1)
    return f"{schema}__{name}"


def column_comment(entry: dict[str, Any], version: int) -> str:
    marker = f"role={entry['role']}" + ("; sensitive" if entry.get("sensitive") else "") + f"; descriptor=v{version}"
    note = str(entry.get("note") or "").strip()
    if not note:
        return marker
    room = COMMENT_LIMIT - len(marker) - 3
    return marker + " | " + (note if len(note) <= room else note[:max(room - 1, 0)] + "…")


def statements(doc: dict[str, Any], reader: str | None) -> list[str]:
    """The CREATE SCHEMA, CREATE OR REPLACE VIEW and GRANT that publish an approved descriptor."""
    table, version = doc["source"]["object"], doc["version"]
    schema, name = table.split(".", 1)
    columns = list(doc["columns"])
    view = f"{SCHEMA}.{quoted(view_name(table))}"
    described = ",\n  ".join(f"{quoted(c)} COMMENT IS {literal(column_comment(doc['columns'][c], version))}" for c in columns)
    about = f"grain={doc.get('grain') or ''}; source={table}; descriptor=v{version}"
    found = [f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}",
             f"CREATE OR REPLACE VIEW {view} (\n  {described}\n) AS SELECT {', '.join(quoted(c) for c in columns)} "
             f"FROM {quoted(schema)}.{quoted(name)}\nCOMMENT IS {literal(about[:COMMENT_LIMIT])}"]
    if reader:
        found.append(f"GRANT SELECT ON {view} TO {quoted(reader)}")
    return found


def publish(execute: Callable[[str], Any], rows: Callable[[str], list[dict[str, Any]]], doc: dict[str, Any],
            reader: str | None) -> dict[str, Any]:
    """Run the statements, then read the comments back; {view, columns, statements}. A column whose comment lacks
    its marker afterwards raises RuntimeError naming it."""
    sent = statements(doc, reader)
    for sql in sent:
        execute(sql)
    name = view_name(doc["source"]["object"])
    back = {str(r["COLUMN_NAME"]): str(r.get("COLUMN_COMMENT") or "") for r in rows(
        "SELECT COLUMN_NAME, COLUMN_COMMENT FROM EXA_ALL_COLUMNS "
        f"WHERE COLUMN_SCHEMA = {literal(SCHEMA)} AND COLUMN_TABLE = {literal(name)} ORDER BY COLUMN_ORDINAL_POSITION")}
    wrong = [c for c, entry in doc["columns"].items() if not back.get(c, "").startswith(f"role={entry['role']}")]
    if wrong:
        raise RuntimeError(f"the view {SCHEMA}.{name} does not carry the roles of {', '.join(wrong)}")
    return {"view": f"{SCHEMA}.{name}", "columns": len(back), "statements": len(sent)}
