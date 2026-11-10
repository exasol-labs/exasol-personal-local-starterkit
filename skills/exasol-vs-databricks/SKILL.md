---
name: exasol-vs-databricks
description: Connect a Databricks Unity Catalog schema to local Exasol as a virtual schema through a SQL warehouse with exakit connect databricks. Covers the inputs to collect (workspace host, the warehouse's HTTP path, catalog, schema, a personal access token), finding them with the Databricks CLI or the warehouse's Connection details, the Unity Catalog grants and CAN USE on the warehouse, creating the token straight into a file, workspace IP access lists, the unattended connect line, what the kit adds to the adapter (certificate checks, no join pushdown), and the Databricks-specific failures. Connector id databricks, aliases dbx and databricks-sql, tier GA. Triggers — "connect Databricks", "query Databricks from Exasol", "Databricks personal access token", "Databricks SQL warehouse to Exasol", "exakit connect databricks", "E-VSDAB-5 Invalid access token".
---

# Databricks (SQL warehouse) → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds,
disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is Databricks' own.

## 1. When to use it

Any Unity Catalog schema, read through a SQL warehouse: each query runs on the
warehouse (it costs compute and starts a stopped one - seconds when serverless,
minutes for a classic one). One source is one catalog schema. To read tables on
your own storage without a warehouse, see `exasol-vs-unity`. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `host` | yes | | host | the workspace host, e.g. `dbc-1234abcd-5678.cloud.databricks.com` |
| `http_path` | yes | | databricks-http-path | the warehouse's HTTP path, e.g. `/sql/1.0/warehouses/abc123def456ghi7` |
| `catalog` | yes | | databricks-name | the Unity Catalog catalog |
| `schema` | yes | | databricks-name | the schema to expose |
| `password` | yes | | secret | a personal access token - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`. The account
name is fixed (`token`): there is no user input.

## 3. Find each value (read-only)

```bash
databricks warehouses list
databricks warehouses get <warehouse-id> -o json \
  | python3 -c 'import json,sys; p = json.load(sys.stdin)["odbc_params"]; print(p["hostname"], p["path"])'
databricks catalogs list
databricks schemas list <catalog>
databricks tables list <catalog> <schema>
```

In the console: SQL Warehouses > the warehouse > Connection details (server
hostname, HTTP path, JDBC URL). The JDBC URL fills host, http_path, catalog and
schema: `--url 'jdbc:databricks://<host>:443/default;transportMode=http;ssl=1;AuthMech=3;httpPath=<path>;ConnCatalog=<catalog>;ConnSchema=<schema>'`.

## 4. Prepare a reader at the source (recommended grants; show, then run on a yes)

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

## 5. Network

Only when the workspace uses IP access lists (Enterprise tier) must it allow
this computer's public IP (`exakit connect` shows it; fallback: the `python3`
one-liner in the shared skill):

```bash
databricks workspace-conf get-status enableIpAccessLists
databricks ip-access-lists list
databricks ip-access-lists create --json '{"label": "exakit", "list_type": "ALLOW", "ip_addresses": ["<public-ip>/32"]}'
```

Once any ALLOW list exists, every other address is blocked: adding the first
one belongs to the workspace admin. Run a change only after a yes.

## 6. Connect

```bash
exakit connect databricks --name lake --set host=<host> --set http_path=<path> \
  --set catalog=<catalog> --set schema=<schema> --dry-run
exakit connect databricks --name lake --set host=<host> --set http_path=<path> \
  --set catalog=<catalog> --set schema=<schema> --password-file ~/.config/exakit/<name>.pat --yes --json
```

- **What the kit adds - say it if asked about security.** Upstream adapter
  1.0.2 calls the Unity Catalog REST API with certificate checks off. The kit
  keeps upstream's file and appends a check: the chain against a pinned
  Mozilla CA bundle and the host name, before the token is sent. Rows come
  over JDBC with full TLS checks (the loader trusts the language container's
  CA store through the kit's loader class).
- **Joins run in Exasol**: adapter 1.0.2 writes a three-table join Databricks
  refuses, so join pushdown is off. Filters, aggregates, `ORDER BY` and
  `LIMIT` on one table still go down.
- The tables appear as `VS_LAKE`.

## 7. Verify

```bash
exakit source check lake
exakit source describe lake        # from the local catalog: does not wake the warehouse
exakit sql "SELECT * FROM VS_LAKE.ORDERS LIMIT 10"   # names arrive upper case: no quotes
```

## 8. When it fails

| Message | Fix |
|---|---|
| "E-VSDAB-5: the REST API answered HTTP 403: Invalid access token" | the token is wrong, expired or revoked: a new one, then `exakit source reauth lake --password-file <file>` |
| "DatabricksSQLException: HTTP 403: Invalid access token" (on reauth) | the same, from the JDBC driver: the old token was kept |
| "SCHEMA_DOES_NOT_EXIST", "CATALOG_DOES_NOT_EXIST" | no such name - or the token's user may not see it: names and grants |
| "for iterator ... (table expected, got nil)" | Unity Catalog answered without columns - the built-in `samples` catalog does this: use a catalog the workspace owns |
| "certificate verify failed: ..." (`tls-failed`) | the kit's check refused the REST API's certificate; expired by the database's clock: restart the database. Otherwise do not work around it |

Types: `STRING` arrives as `VARCHAR(2000000)`, `BIGINT` as `DECIMAL(19,0)`.

## 9. Keep it working

- The token expires at the lifetime it was made with: a new one, then
  `exakit source reauth lake --password-file ~/.config/exakit/<name>.pat`.
- Tables added at the source: `exakit source refresh lake`.
- Stop: `exakit source disconnect lake` or `exakit source remove lake`
  (`--dry-run` first, then ask) - see the shared skill.
