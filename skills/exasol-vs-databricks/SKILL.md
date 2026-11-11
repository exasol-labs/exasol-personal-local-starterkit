---
name: exasol-vs-databricks
description: Connect a Databricks Unity Catalog schema to local Exasol as a virtual schema through a SQL warehouse with exakit connect databricks. Covers the inputs to collect (workspace host, the warehouse's HTTP path, catalog, schema, a personal access token) and where the warehouse's Connection details show them, the connection-string forms, the Unity Catalog grants and CAN USE on the warehouse, creating the token straight into a file, workspace IP access lists, why no CA file is needed, the unattended connect line, example queries for bash and Windows PowerShell, what the kit adds to the adapter (certificate checks, no join pushdown), and the Databricks-specific failures. Connector id databricks, aliases dbx and databricks-sql, tier GA. Triggers — "connect Databricks", "query Databricks from Exasol", "Databricks personal access token", "Databricks SQL warehouse to Exasol", "exakit connect databricks", "E-VSDAB-5 Invalid access token".
---

# Databricks (SQL warehouse) → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds, the
database clock, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is Databricks' own.

## 1. When to use it

Any Unity Catalog schema, read through a SQL warehouse: each query runs on the
warehouse (it costs compute and starts a stopped one - seconds when serverless,
minutes for a classic one). One source is one catalog schema. Because the
warehouse reads the data, this route needs **no** External Data Access on the
metastore and works for a schema on Databricks Default Storage. To read tables
from their storage without a warehouse, see `exasol-vs-unity`. Tier GA.

## 2. Fields

The first prompt, "Name (alias) for this connection", is the source name
(`--name`): `lake` becomes schema `VS_LAKE`. The account name is fixed
(`token`): there is no user input.

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `host` | yes | | SQL Warehouses > `<warehouse>` > Connection details > Server hostname (`<workspace>.cloud.databricks.com`) |
| `http_path` | yes | | the same tab > HTTP path (`/sql/1.0/warehouses/<id>`) |
| `catalog` | yes | | Catalog Explorer > the catalog |
| `schema` | yes | | Catalog Explorer > `<catalog>` > the schema |
| `password` | yes | | a personal access token (section 4) - only through `--password-file` or `--password-stdin` |

From the CLI (read-only):

```bash
databricks warehouses list
databricks warehouses get <warehouse-id> -o json \
  | python3 -c 'import json,sys; p = json.load(sys.stdin)["odbc_params"]; print(p["hostname"], p["path"])'
databricks schemas list <catalog>
```

## 3. Connection-string forms

`--url` (or the hidden paste prompt) reads the warehouse's JDBC URL:

- `jdbc:databricks://<host>:443/default;httpPath=...;ConnCatalog=...;ConnSchema=...`
  - fills `host`, `http_path`, `catalog`, `schema`
- `jdbc:spark://<host>:443/default;httpPath=...`
- a bare `<host>`

The `;` separators pass through Windows unharmed. A token in the string
(`PWD=`, else `password=` or `token=`) is the credential: taken out of the
string (never stored, logged or shown) and not asked again.

## 4. Prepare the source (show every statement, run on a yes)

The token carries its user's rights: use a dedicated user, not an admin. In
Databricks SQL, as the catalog's owner:

```sql
GRANT USE CATALOG ON CATALOG <catalog> TO `<reader@example.com>`;
GRANT USE SCHEMA, SELECT ON SCHEMA <catalog>.<schema> TO `<reader@example.com>`;
```

```bash
databricks permissions update warehouses <warehouse-id> \
  --json '{"access_control_list": [{"user_name": "<reader@example.com>", "permission_level": "CAN_USE"}]}'
```

The token, signed in to the CLI as that reader, straight into a file (never
print it) - or the reader makes it in Settings > Developer > Access tokens:

```bash
umask 077; mkdir -p ~/.config/exakit
databricks tokens create --comment exakit-<name> --lifetime-seconds 2592000 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_value"])' > ~/.config/exakit/<name>.pat
```

OAuth M2M is not offered: the adapter would need the client secret inside the
JDBC URL.

**Network.** Only when the workspace uses IP access lists must it allow this
computer's public IP (`exakit connect` shows it; fallback in the shared skill):

```bash
databricks workspace-conf get-status enableIpAccessLists
databricks ip-access-lists list
databricks ip-access-lists create --json '{"label": "exakit", "list_type": "ALLOW", "ip_addresses": ["<public-ip>/32"]}'
```

Once any ALLOW list exists, every other address is blocked: adding the first
one belongs to the workspace admin.

## 5. TLS

No CA file and no `tls` input. Rows come over JDBC with full certificate
checks: the loader's main class (`exakit.loader.TrustStoreDriver`) points the
loader at the language container's CA store, because the JDBC loader on
Exasol Personal has none. Metadata comes from the Unity Catalog REST API.
Upstream adapter 1.0.2 turns certificate checks off there; the kit adds a
check against a pinned Mozilla CA bundle and the host name, before the token
is sent.

## 6. Connect

```bash
exakit connect databricks --name lake --set host=<workspace>.cloud.databricks.com --set http_path=<path> \
  --set catalog=<catalog> --set schema=<schema> --dry-run
exakit connect databricks --name lake --set host=<workspace>.cloud.databricks.com --set http_path=<path> \
  --set catalog=<catalog> --set schema=<schema> --password-file ~/.config/exakit/<name>.pat --yes --json
```

PowerShell: the same on one line, `--password-file $HOME\.config\exakit\<name>.pat`.

**Joins run in Exasol**: adapter 1.0.2 writes a three-table join Databricks
refuses, so join pushdown is off. Filters, aggregates, `ORDER BY` and `LIMIT`
on one table still go down.

## 7. Verify and query

```bash
exakit source check lake
exakit source describe lake        # from the local catalog: does not wake the warehouse
exakit sql 'SELECT C_NAME, C_ACCTBAL FROM VS_LAKE.CUSTOMER ORDER BY C_ACCTBAL DESC LIMIT 10'
exakit sql 'SELECT O_ORDERSTATUS, COUNT(*) FROM VS_LAKE.ORDERS GROUP BY O_ORDERSTATUS'
```

Names arrive upper case, so these run as written in Windows PowerShell 5.1
too. A query with a "quoted" name loses its inner double quotes as a
PowerShell 5.1 argument: pipe it or use a file there.

```powershell
'SELECT "C_NAME" FROM VS_LAKE."CUSTOMER" LIMIT 10' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

- Names arrive in upper case (`CUSTOMER`, `C_NAME`): no quotes needed.
- `STRING` arrives as `VARCHAR(2000000)`, `BIGINT` as `DECIMAL(19,0)`.

## 9. When it fails

| Message | Fix |
|---|---|
| "E-VSDAB-5: the REST API answered HTTP 403: Invalid access token" (`auth`) | the token is wrong, expired or revoked: a new one, then `exakit source reauth lake --password-file <file>` |
| "DatabricksSQLException: HTTP 403: Invalid access token" (on reauth) | the same, from the JDBC driver: the old token was kept |
| "SCHEMA_DOES_NOT_EXIST", "CATALOG_DOES_NOT_EXIST" (`schema_missing`) | no such name - or the token's user may not see it: names and grants (section 4) |
| "for iterator ... (table expected, got nil)" | Unity Catalog answered without columns - the built-in `samples` catalog does this: use a catalog the workspace owns |
| refused for this address | a workspace IP access list lacks this computer's public IP (section 4) |
| "certificate verify failed: certificate has expired or is not yet valid" (`tls-failed`) | usually the database clock, behind after the laptop slept: `exakit connect` shows "Database clock: in sync with this computer." or a warning with a restart offer. `exakit stop`, then `exakit start` |
| "certificate verify failed: ..." (another reason) | the kit's check refused the REST API's certificate: do not work around it |

## 10. Keep it working

- The token expires at the lifetime it was made with: a new one, then
  `exakit source reauth lake --password-file ~/.config/exakit/<name>.pat`.
- Another workspace host or SQL warehouse: `exakit connect databricks --name lake
  --set host=<new host> --set http_path=<new path> --password-file ~/.config/exakit/<name>.pat --yes`
  (`--dry-run` first). `VS_LAKE` keeps its name and the token is asked for
  again - see the shared skill.
- Tables added at the source: `exakit source refresh lake`.
- Stop: `exakit source disconnect lake` or `exakit source remove lake`
  (`--dry-run` first, then ask) - see the shared skill.
