# Databricks (SQL warehouse)

One Unity Catalog schema, queried through a Databricks SQL warehouse with a
personal access token (PAT). The warehouse runs the queries. To read the
table files directly instead, with no warehouse, see [Unity Catalog](unity.md).

> **Easiest: let your AI agent do it.** The skill `exasol-vs-databricks` knows this connector.
>
> **You still need, on your computer:** the Databricks workspace in a browser,
> or the Databricks CLI (`databricks auth login --host https://<workspace-host>`).
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `lake` |
| Workspace host name | yes | `dbc-1234abcd-5678.cloud.databricks.com` |
| SQL warehouse HTTP path | yes | `/sql/1.0/warehouses/abc123def456ghi7` |
| Unity Catalog catalog | yes | `main` |
| Schema | yes | `sales` |
| Personal access token | yes | (hidden) |

The account name is fixed (`token`): there is no user field.

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

## Connection string you can paste

```text
jdbc:databricks://dbc-1234abcd-5678.cloud.databricks.com:443/default;transportMode=http;ssl=1;AuthMech=3;httpPath=/sql/1.0/warehouses/abc123def456ghi7;ConnCatalog=main;ConnSchema=sales
dbc-1234abcd-5678.cloud.databricks.com
```

The first fills host, HTTP path, catalog and schema (without `ConnCatalog` and
`ConnSchema` you type those two). The second fills the host only.

## Common problems

| Symptom | Fix |
|---|---|
| "HTTP 403: Invalid access token" | The token is wrong, expired or revoked: make a new one (step 4), then `exakit source reauth lake`. |
| "SCHEMA_DOES_NOT_EXIST", "CATALOG_DOES_NOT_EXIST" | A wrong name, or the token's user lacks the grants in step 3. |
| "for iterator ... (table expected, got nil)" | That is the `samples` catalog: use a catalog your workspace owns. |
| "certificate verify failed" | The database clock is behind (the computer slept): `exakit stop`, then `exakit start`. |
| The source does not answer, and the workspace has IP access lists | Ask the workspace admin to add your public IP (step 5). |
