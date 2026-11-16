# Databricks (SQL warehouse)

One Unity Catalog schema, queried through a Databricks SQL warehouse with a
personal access token (PAT). The warehouse runs the queries. To read the
table files directly instead, with no warehouse, see [Lakehouse (Iceberg / Delta)](lakehouse.md).

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

| Field | Example | Where it comes from |
|---|---|---|
| Name (alias) for this connection | `lake` | You choose it. `lake` gives the schema `VS_LAKE`. |
| Workspace host name | `dbc-1234abcd-5678.cloud.databricks.com` | SQL Warehouses → `<warehouse>` → Connection details → Server hostname ([step 1](#1-host-and-http-path)). |
| SQL warehouse HTTP path | `/sql/1.0/warehouses/abc123def456ghi7` | The same tab → HTTP path ([step 1](#1-host-and-http-path)). |
| Catalog (Unity Catalog) | `main` | Catalog Explorer ([step 2](#2-catalog-and-schema)). |
| Schema | `sales` | Catalog Explorer ([step 2](#2-catalog-and-schema)). |
| Personal access token | (hidden) | The token of the read-only user ([step 4](#4-the-personal-access-token)). |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| (none) | Every field is required. | |

The account name is fixed (`token`): there is no user field.

## Connection string you can paste

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

Without `ConnCatalog` and `ConnSchema` you type those two. `transportMode`,
`ssl`, `AuthMech` and `UID` are dropped. A `PWD=` (or `password=`, `token=`) in
the string is the personal access token: taken out of the string and not asked
again.

### Where to find the connection string

You do not build it: copy the address the workspace shows.

- **Workspace:** SQL Warehouses → `<warehouse>` → Connection details → copy the
  **JDBC URL**. It fills host and HTTP path. Add
  `;ConnCatalog=<catalog>;ConnSchema=<schema>` to fill those two as well, or
  type them.
- If the copied URL has a `PWD=` part, delete it.

Leave the token out of the string. The kit asks for it at a hidden prompt, or reads it from `--password-file`. The string is optional. At the prompt, press Enter alone and `exakit connect` asks for the fields one by one.

### Where to find each part of the string

| Part of the string | Where to find it |
|---|---|
| host | Connection details → Server hostname ([step 1](#1-host-and-http-path)). |
| `httpPath` | Connection details → HTTP path ([step 1](#1-host-and-http-path)). |
| `ConnCatalog`, `ConnSchema` | Catalog Explorer, or `databricks schemas list <catalog>` ([step 2](#2-catalog-and-schema)). |

## Where to find each value

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

The kit asks for a connection string (hidden; press Enter on an empty line to
type the fields instead), then each field above. It shows a plan and asks
once. The adapter is Lua, built into the database: no language container to
install. Your tables appear as `VS_LAKE`.

Without prompts:

```bash
exakit connect databricks --name lake --set host=dbc-1234abcd-5678.cloud.databricks.com \
  --set http_path=/sql/1.0/warehouses/abc123def456ghi7 --set catalog=main --set schema=sales \
  --password-file ~/.config/exakit/lake.pat --yes
exakit sql "SELECT * FROM VS_LAKE.CUSTOMER LIMIT 10"
```

Add `--dry-run` to see the plan first. Joins run in Exasol; filters,
aggregates and `LIMIT` on one table go to Databricks.

**Windows:** paste the JDBC URL at the prompt rather than `--url`. For a quoted
name in `exakit sql`, pipe the statement in (`'SELECT "x" FROM VS_LAKE.T' | exakit sql`)
or use `exakit sql --file query.sql`.

## Common problems

| Symptom or error text | Fix |
|---|---|
| "HTTP 403: Invalid access token" | The token is wrong, expired or revoked: make a new one (step 4), then `exakit source reauth lake`. |
| "SCHEMA_DOES_NOT_EXIST", "CATALOG_DOES_NOT_EXIST" | A wrong name, or the token's user lacks the grants in step 3. |
| "for iterator ... (table expected, got nil)" | That is the `samples` catalog: use a catalog your workspace owns. |
| "certificate verify failed" | The database clock is behind (the computer slept): `exakit stop`, then `exakit start`. |
| The source does not answer, and the workspace has IP access lists | Ask the workspace admin to add your public IP (step 5). |
