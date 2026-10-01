---
name: exasol-exapump
description: Use exapump, the starter kit's SQL and bulk-load CLI for the local Exasol database — running one-off SQL, opening an interactive SQL shell, uploading CSV and Parquet files into tables, and managing connection profiles. Critically, it also covers the fact that the kit's starter-kit profile connects as the ADMIN user and is not sandboxed. Triggers — "run SQL against my Exasol database", "load a CSV into Exasol", "upload a Parquet file", "exapump", "open a SQL shell", "validate a query result independently", "create an exapump profile".
---

# exapump — SQL and bulk loading

`exapump` is the kit's command-line path into the local database: one-off SQL,
an interactive shell, and bulk file loading. It is installed by the kit and
lives on `PATH` (`~/.local/bin/exapump`).

## Read this before you run anything

**The `starter-kit` profile connects as the database ADMIN user (`sys`). It is
not read-only and it is not sandboxed.** It can `CREATE`, `UPDATE`, `DELETE`
and `DROP`. Nothing but you stops a destructive statement here.

This matters because the kit's *other* path — the MCP tools — runs as a
dedicated read-only user where the **database itself** rejects writes. Those
are two different trust levels through the same database:

| Path | Connects as | Writes |
|---|---|---|
| MCP tools (`mcp__exasol…`) | `mcp_readonly` | rejected **by the database** |
| `exapump -p starter-kit` | `sys` (admin) | **allowed** — only you stop them |

Two rules follow, and they are not negotiable:

- **Never reach for exapump to "work around" an MCP read-only rejection.** The
  rejection is the guardrail working. Routing the same write through exapump
  defeats the entire trust model of this kit.
- **Show the user the SQL before you run it through exapump**, every time.

## Running SQL

```bash
exakit sql 'SELECT CURRENT_TIMESTAMP'                      # prefer this
exakit sql --file ~/.exasol-starter-kit/workflows/q.sql    # a saved statement (or: exakit sql < q.sql)
exakit sql --json 'SELECT COUNT(*) AS c FROM TPCH.NATION'  # one JSON object: {"ok": true, "rows": [...]}
exapump sql -p starter-kit 'SELECT CURRENT_TIMESTAMP'      # one statement, raw
exapump sql -p starter-kit < script.sql                    # a multi-statement script
exapump interactive -p starter-kit                         # interactive shell
```

**Reach for `exakit sql` first.** It runs over the same profile, but it refuses
anything that is not a single read statement unless you pass `--write`, and — the
reason it exists — it turns a failure into its remedy. Raw exapump gives you the
engine's text and a generic hint, so `FETCH FIRST` comes back as "check your SQL
syntax" rather than "Exasol pages with `LIMIT`", and a refused connection never
mentions `exakit start`. A saved single statement reruns with `exakit sql --file
<path>` (comment lines and a trailing `;` are dropped). Drop to `exapump` only
for multi-statement scripts, bulk loads and the interactive shell.

**Parsing results.** `exakit sql --json` prints exactly one JSON object on stdout
and nothing else there: `{"ok": true, "rows": [{col: value, ...}]}` on success,
`{"ok": false, "error": "<engine text>", "remedy": "<what to do>" | null}` on
failure (exit code unchanged). Prefer it over scraping the CSV form, whose
`[1/1] ... N rows` header and `1 statement executed` footer share stdout with
the data.

**Discovering the data without MCP** (always the case in the session that ran
the install): the system tables answer in well under a second.

```sql
SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROW_COUNT FROM SYS.EXA_ALL_TABLES WHERE TABLE_SCHEMA NOT LIKE 'SYS%' ORDER BY 1, 2;
SELECT COLUMN_NAME, COLUMN_TYPE, COLUMN_COMMENT FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = 'ENERGY' AND COLUMN_TABLE = 'ENERGY_READINGS' ORDER BY COLUMN_ORDINAL_POSITION;
```

Each bundled dataset is also described in `~/.exasol-starter-kit/kit/data/data-dictionary.md`.

**Tables loaded from a file keep the file's column names as written, quoted.**
`EXAKIT_DATA_FILE=visits.csv exakit data-load` with a header `id,city,visits`
creates `STARTER_KIT.VISITS` with columns `"id"`, `"city"`, `"visits"`. An
unquoted name in SQL is upper-cased, so `SELECT SUM(VISITS)` fails with
`object VISITS not found` although the spelling was right. Quote them:
`SELECT SUM("visits") FROM STARTER_KIT.VISITS`, or `DESCRIBE` the table first
and copy the names as shown. Upper-casing the header before loading avoids the
quotes altogether.

`exakit sql` is **not** a sandbox: it is the same admin connection, and its
statement gate is a seatbelt against a typo. The enforced read-only boundary is
the MCP user.

`-p starter-kit` names the connection **profile** the kit created. Profiles
live in `~/.exapump/config.toml`; `EXAPUMP_CONFIG` overrides that path.

> `starter-kit` is a *profile* name, not a schema. The bundled datasets each
> live in their own **schema** — `TPCH`, `ENERGY`, `WEATHER` — and data the user
> uploads defaults to the `STARTER_KIT` schema. Do not conflate the two or
> "correct" one into the other.

## The one dialect trap

Exasol pages with **`LIMIT n`** (optionally `OFFSET`). It does **not** support
`FETCH FIRST` or `TOP`. If you see:

```
syntax error, unexpected FETCH_    (or unexpected TOP_)
```

rewrite with `LIMIT`. This is a mechanical fix to already-approved logic — make
it and re-run; do not go back to the user for re-approval.

Likewise `object <NAME> not found` means a wrong name or a missing schema
qualifier. Describe the object first (`DESCRIBE <schema>.<table>`, or the MCP
`describe_exasol_table_or_view` tool), then fix the query. Do not guess column
names.

## Bulk loading files

```bash
exapump upload data.csv --table STARTER_KIT.MYTABLE -p starter-kit
exapump upload data.parquet --table STARTER_KIT.MYTABLE -p starter-kit
```

exapump loads **CSV and Parquet**. It does *not* load JSON — JSON is a nested
tree, not a table. For JSON, the kit offers the **JSON Tables** add-on, which
shreds it into relational tables; `exakit data-load` offers it on the spot when
you hand it a `.json` file.

For the bundled sample data, prefer the kit's own menu over hand-rolled uploads:

```bash
exakit data-load           # bundled datasets or a local CSV/Parquet/JSON file
exakit data-load --force   # reload the bundled sample directly
```

## Profiles

```bash
exapump profile init <name>    # create or update a profile (host, port, user, password)
exapump --version
exapump --help
```

The kit creates `starter-kit` for you during install. You rarely need to make
another one — do it only when the user is connecting to a *different* database.

## Validating an AI answer — what exapump is really for

The kit's loop is **ASK → INSPECT → RUN → VALIDATE → RERUN**, and exapump is
the VALIDATE step: reproduce the number through an independent path.

```bash
exakit sql "<the exact SQL the user already approved>"
```

Matching numbers is the whole point — the AI's answer becomes the user's
*verified* answer. Two cautions:

- Issue **only** the exact approved `SELECT` here. Never DDL or DML through
  exapump or `exakit sql --write`, ever.
- Reproducing the same SQL proves it reruns and connects. To also sanity-check
  *correctness*, vary one thing — a filter, a grouping — and confirm the number
  moves the way you would expect.

## When it fails

| You see | It means | Do |
|---|---|---|
| `Failed to connect to 127.0.0.1:8563` | the database is not running | `exakit start`, confirm with `exakit status` |
| `syntax error, unexpected FETCH_` / `TOP_` | Exasol does not support those | rewrite with `LIMIT <n>` |
| `object <NAME> not found` | wrong name or missing schema | describe it first, then fix the query |

Reinstall or update exapump itself with `exakit update`. Discover every
command the kit knows with `exakit catalog` (searchable: `exakit catalog upload`).

## Guardrails

- **Admin connection — treat every statement as consequential.** Show the SQL
  first; run only `SELECT` unless the user explicitly asked for a change and
  approved the exact statement.
- **Never print or log** the password files under
  `~/.exasol-starter-kit/credentials/`.
- **Do not invent** flags, profile names, schema names or Exasol syntax. If a
  fact is unverified, check it (`exakit info`, `exapump --help`) or say so.
