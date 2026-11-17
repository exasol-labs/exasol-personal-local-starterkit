# Databricks · Federation guide

> **Federation** lets your local Exasol query Databricks data in place, without copying it.
> `exakit connect databricks` makes it a virtual schema, `VS_<NAME>`, that you query with SQL.

One Unity Catalog schema, queried through a Databricks SQL warehouse with a
personal access token (PAT). The warehouse runs the queries. To read the
table files directly instead, with no warehouse, see
[Lakehouse (Iceberg / Delta)](lakehouse.md).

## At a glance

| You need | Where to find it |
|---|---|
| Workspace host name and the warehouse's HTTP path | SQL Warehouses → Connection details ([step 1](#1-host-and-http-path)) |
| Catalog and schema | Catalog Explorer ([step 2](#2-catalog-and-schema)) |
| A read-only user with grants on the catalog and warehouse | SQL you run as the catalog's owner ([step 3](#3-a-read-only-user)) |
| That user's personal access token, in a file | Settings → Developer → Access tokens ([step 4](#4-the-personal-access-token)) |
| Your IP in the workspace's IP access list | Only with IP access lists, Enterprise tier ([step 5](#5-network)) |

## The simplest way: ask your AI agent

**Easiest: let your AI agent do it.** The kit installs the skill
`exasol-vs-databricks` for your AI client; it knows this connector.

Copy this prompt, fill in the `<...>` parts, and give it to your agent:

```text
Connect the Databricks schema <catalog>.<schema> to my local Exasol with exakit
through the SQL warehouse <warehouse>. Use the exasol-vs-databricks skill.
Workspace: <workspace-host>. Grant a read-only user what it needs, and write
its personal access token to a file, never into the chat.
```

**You still need, on your computer:** the Databricks workspace in a browser,
or the Databricks CLI (`databricks auth login --host https://<workspace-host>`),
as someone who may grant on the catalog and the warehouse.

**Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

### Required

| Field | Example |
|---|---|
| Name (alias) for this connection | `lake` (gives the schema `VS_LAKE`) |
| Workspace host name | `dbc-1234abcd-5678.cloud.databricks.com` |
| SQL warehouse HTTP path | `/sql/1.0/warehouses/abc123def456ghi7` |
| Catalog (Unity Catalog) | `main` |
| Schema | `sales` |
| Personal access token | (hidden) |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| (none) | Every field is required. | |

There is no Username field: the account name is fixed (`token`).

## Where to find each value

Prepare the source in this order. Every step is a one-time setup.

### 1. Host and HTTP path

Workspace → SQL Warehouses → `<warehouse>` → Connection details: **Server
hostname** and **HTTP path**. The **JDBC URL** there holds both: paste it.

```bash
databricks warehouses list
databricks warehouses get <warehouse-id> -o json | python3 -c 'import json,sys; p=json.load(sys.stdin)["odbc_params"]; print(p["hostname"], p["path"])'
```

### 2. Catalog and schema

Workspace → Catalog → `<catalog>` → `<schema>`.

```bash
databricks catalogs list
databricks schemas list <catalog>
```

The built-in `samples` catalog cannot be read: use a catalog your workspace owns.

### 3. A read-only user

The token carries its user's rights: use a dedicated user, not an admin. As
the catalog's owner, in a SQL editor:

```sql
GRANT USE CATALOG ON CATALOG main TO `reader@example.com`;
GRANT USE SCHEMA, SELECT ON SCHEMA main.sales TO `reader@example.com`;
```

Then SQL Warehouses → `<warehouse>` → Permissions → add the user with **Can use**.

### 4. The personal access token

Signed in as that user: your user menu (top right) → Settings → Developer →
Access tokens → Manage → Generate new token. Copy it into an owner-only file
such as `~/.config/exakit/lake.pat`.

```bash
umask 077; mkdir -p ~/.config/exakit
databricks tokens create --comment exakit-lake --lifetime-seconds 2592000 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_value"])' > ~/.config/exakit/lake.pat
```

### 5. Network

Nothing to open, unless the workspace uses IP access lists (Enterprise tier).
Then a workspace admin adds your public IP (`curl https://checkip.amazonaws.com`):

```bash
databricks ip-access-lists create --json '{"label": "exakit", "list_type": "ALLOW", "ip_addresses": ["<your-ip>/32"]}'
```

The first ALLOW list blocks every other address: leave that to the admin.

## Connect

```bash
exakit connect databricks
```

1. The kit asks for a connection string (hidden). Press Enter on an empty line
   to type the fields instead.
2. It shows a plan, then connects.
3. The adapter is Lua, built into the database: no language container to
   install.

Your tables appear as `VS_LAKE`.

Without prompts:

```bash
exakit connect databricks --name lake --set host=dbc-1234abcd-5678.cloud.databricks.com \
  --set http_path=/sql/1.0/warehouses/abc123def456ghi7 --set catalog=main --set schema=sales \
  --password-file ~/.config/exakit/lake.pat --yes
```

Add `--dry-run` to see the plan first.

**Windows:** paste the JDBC URL at the prompt rather than `--url`. For a quoted
name in `exakit sql`, pipe the statement in (`'SELECT "x" FROM VS_LAKE.T' | exakit sql`)
or use `exakit sql --file query.sql`.

## Query

```bash
exakit sql "SELECT * FROM VS_LAKE.CUSTOMER LIMIT 10"
```

```powershell
'SELECT * FROM VS_LAKE.CUSTOMER LIMIT 10' | exakit sql
```

- Names arrive in upper case (`CUSTOMER`, `C_NAME`): no quotes needed.
- `STRING` arrives as `VARCHAR(2000000)`, `BIGINT` as `DECIMAL(19,0)`.
- Joins run in Exasol. Filters, aggregates and `LIMIT` on one table go to
  Databricks.

## Troubleshooting

| Error you see | Why | Fix |
|---|---|---|
| "HTTP 403: Invalid access token" | The token is wrong, expired or revoked. | Make a new one (step 4), then `exakit source reauth lake`. |
| "SCHEMA_DOES_NOT_EXIST", "CATALOG_DOES_NOT_EXIST" | A wrong name, or the token's user lacks the grants. | Check the names; run the grants in step 3. |
| "for iterator ... (table expected, got nil)" | That is the `samples` catalog: its answer has no columns. | Use a catalog your workspace owns. |
| "certificate verify failed" | The database clock is behind (the computer slept). | `exakit stop`, then `exakit start`. |
| The source does not answer, and the workspace has IP access lists | Your public IP is not on the list. | Ask the workspace admin to add it (step 5). |

## Connection string you can paste

Reference. The string is optional: at the prompt, press Enter alone and
`exakit connect` asks for the fields one by one.

```text
jdbc:databricks://dbc-1234abcd-5678.cloud.databricks.com:443/default;transportMode=http;ssl=1;AuthMech=3;httpPath=/sql/1.0/warehouses/abc123def456ghi7;ConnCatalog=main;ConnSchema=sales
jdbc:spark://dbc-1234abcd-5678.cloud.databricks.com:443/default;transportMode=http;ssl=1;AuthMech=3;httpPath=/sql/1.0/warehouses/abc123def456ghi7
dbc-1234abcd-5678.cloud.databricks.com
```

| String | Fills |
|---|---|
| `jdbc:databricks://<host>:443/default;httpPath=...;ConnCatalog=...;ConnSchema=...` | host, HTTP path, catalog and schema |
| `jdbc:spark://<host>:443/default;httpPath=...` (the older driver's URL) | host and HTTP path |
| `<host>` | host |

- Without `ConnCatalog` and `ConnSchema` you type those two.
- `transportMode`, `ssl`, `AuthMech` and `UID` are dropped.
- A `PWD=` (or `password=`, `token=`) in the string is the personal access
  token: the kit takes it out of the string and does not ask again.

Leave the token out of the string. The kit asks for it at a hidden prompt, or
reads it from `--password-file`.

### Where to find the connection string

You do not build it: copy the address the workspace shows.

- **Workspace:** SQL Warehouses → `<warehouse>` → Connection details → copy the
  **JDBC URL**. It fills host and HTTP path. Add
  `;ConnCatalog=<catalog>;ConnSchema=<schema>` to fill those two as well, or
  type them.
- If the copied URL has a `PWD=` part, delete it.

### Where to find each part of the string

| Part of the string | Where to find it |
|---|---|
| host | Connection details → Server hostname ([step 1](#1-host-and-http-path)). |
| `httpPath` | Connection details → HTTP path ([step 1](#1-host-and-http-path)). |
| `ConnCatalog`, `ConnSchema` | Catalog Explorer, or `databricks schemas list <catalog>` ([step 2](#2-catalog-and-schema)). |

### `--set` keys

`host`, `http_path`, `catalog`, `schema`. Give the token with
`--password-file` (or `--password-stdin`), never on the command line.
