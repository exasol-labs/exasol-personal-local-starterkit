---
name: exasol-vs-unity
description: Connect a Unity Catalog schema (Databricks or OSS) to local Exasol with exakit connect unity, its tables read straight from your own cloud storage by the lakehouse engine with no warehouse. Covers the inputs to collect (workspace URL, catalog.schema, the bucket's region, a personal access token) and where each is in the Databricks workspace, the three prerequisites (External Data Access on the metastore, the EXTERNAL USE SCHEMA grant, a schema on external storage rather than Default Storage), when to use the databricks or iceberg-rest connector instead, the unattended connect line, example queries on macOS, Linux and Windows, and the Unity-specific failures. Connector id unity, aliases uc and oss-unity-catalog, tier GA. Triggers — "read Unity Catalog tables without a warehouse", "Unity Catalog external data access for Exasol", "EXTERNAL USE SCHEMA for exakit", "query Unity Catalog tables from storage in Exasol", "Default Storage schema from Exasol", "exakit connect unity".
---

# Unity Catalog via the lakehouse engine → local Exasol

Shared rules (credential handling, the lakehouse engine, the `--json` answer and
failure kinds, re-point, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is the Unity route's own.

## 1. When to use it

A Unity Catalog schema whose tables sit on the user's own cloud storage, read
by the same pinned engine and scripts as the Glue route, inside this database:
nothing runs on Databricks compute. One schema is one source. Tier GA.

It works only when all three hold (measured live):

1. **External Data Access** is switched on for the metastore.
2. The token's user holds **EXTERNAL USE SCHEMA** on the schema.
3. The schema is on **external storage** (a managed or external location in
   the user's bucket). Databricks Default Storage cannot be read by outside
   engines.

Use `exasol-vs-databricks` (through a SQL warehouse) instead when any of them
cannot be met, or for Databricks catalog-managed tables, which this adapter
version cannot read. Databricks' Iceberg REST endpoint is a third route,
through `exasol-vs-iceberg-rest`, with the same three prerequisites.

## 2. Fields

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `workspace_url` | yes | | the browser's address bar in the workspace, `https://...` only, e.g. `https://dbc-1234.cloud.databricks.com` |
| `namespace` | yes | | Workspace > Catalog > the catalog > the schema, given as `catalog.schema` (e.g. `main.sales`) |
| `region` | yes | | the AWS region of the bucket that holds the tables: Catalog > the schema > Details > storage location, then S3 > that bucket > Properties > AWS Region |
| `secret` | yes | | a personal access token: Settings > Developer > Access tokens - only through `--password-file` |

The first question, "Name (alias) for this connection", is `--name`: the tables
appear as `VS_<NAME>`. Unity's temporary storage credentials carry no region,
so the region is asked for, not guessed.

The same with the CLIs (read-only):

```bash
databricks catalogs list
databricks schemas list <catalog>
databricks schemas get <catalog>.<schema>      # storage_root / storage_location: where its tables live
databricks tables list <catalog> <schema>
databricks metastores summary                   # external_access_enabled must be true
aws s3api get-bucket-location --bucket <bucket-from-storage_location>   # the region; null means us-east-1
```

## 3. Connection-string forms

`--url` (or the first, hidden prompt at a terminal) reads one form,
`https://<workspace-host>`, and fills `workspace_url`. A `user:secret@` or a
query string in it is taken as a credential and never kept. The form has no
`&`, so it pastes the same on Windows.

## 4. Prepare the source (recommended grants; show, then run on a yes)

A metastore admin switches External Data Access on for the metastore
(Catalog > the metastore's settings). The schema must have a managed location
on external storage. Then, as the catalog's owner (only it may grant EXTERNAL
USE SCHEMA, and it must be granted explicitly), for the token's user:

```sql
GRANT USE CATALOG ON CATALOG <catalog> TO `<reader@example.com>`;
GRANT USE SCHEMA, EXTERNAL USE SCHEMA, SELECT ON SCHEMA <catalog>.<schema> TO `<reader@example.com>`;
```

The token, signed in to the CLI as that reader, straight into a file (never
print it):

```bash
umask 077; mkdir -p ~/.config/exakit
databricks tokens create --comment exakit-<name> --lifetime-seconds 2592000 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_value"])' > ~/.config/exakit/<name>.pat
```

**Network.** A workspace with IP access lists must allow this computer's
public IP (`exakit connect` shows it; fallback: the `python3` one-liner in the
shared skill). See `exasol-vs-databricks` for the commands and the first-list
caution.

## 5. TLS

No CA file. The workspace URL is `https` only, and the engine checks the
workspace's and the storage's certificates itself: this connector has no `tls`
or `ca` input.

## 6. Connect

```bash
exakit connect unity --name uc_sales --set workspace_url=https://<workspace-host> \
  --set namespace=<catalog>.<schema> --set region=<region> --dry-run
exakit connect unity --name uc_sales --set workspace_url=https://<workspace-host> \
  --set namespace=<catalog>.<schema> --set region=<region> \
  --password-file ~/.config/exakit/<name>.pat --yes --json
```

PowerShell is the same line, with `` ` `` for a line break. The first
lakehouse source installs the Rust language container - at once at a terminal,
with `--yes` in a script. Tell the user first: a download and one database
restart. The tables appear as `VS_UC_SALES`.

## 7. Verify and query

```bash
exakit source check uc_sales
exakit source describe uc_sales
exakit sql 'SELECT * FROM VS_UC_SALES.ORDERS LIMIT 10'
exakit sql 'SELECT COUNT(*) AS N FROM VS_UC_SALES.ORDERS'
```

Names arrive upper case, so these need no quotes and run the same in Windows
PowerShell 5.1. A query with a quoted name loses its inner double quotes as a
PowerShell 5.1 argument: pipe it in or use a file there.

```powershell
'SELECT "ORDER_ID" FROM VS_UC_SALES."ORDERS" LIMIT 10' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

Table and column names arrive upper case (`ORDERS`, `ORDER_ID`). Deletes,
refused formats and the edge cases that differ from native Exasol are the
lakehouse engine's: see the shared skill.

## 9. When it fails

| Message | Fix |
|---|---|
| "Unity Catalog does not let engines outside Databricks read this schema's files" (EXTERNAL USE SCHEMA, External Data Access, EXTERNAL_ACCESS_DISABLED) (`external`) | switch External Data Access on and grant EXTERNAL USE SCHEMA (section 4); a schema on Default Storage never works: use `exakit connect databricks` |
| any other `PERMISSION_DENIED` (`denied`) | grant the token's user what it names: USE CATALOG, USE SCHEMA, SELECT (section 4); behind an IP access list, the public IP the fix names |
| "catalog-managed table, which this adapter version cannot read yet" (`managed`) | read it through the SQL warehouse: `exakit connect databricks` |
| "no such namespace" (SCHEMA_DOES_NOT_EXIST, CATALOG_DOES_NOT_EXIST) | check `catalog.schema` and the user's grants |
| "namespace must be catalog.schema" | give both parts, e.g. `main.sales` |
| "workspace_url must use https" | the token never crosses the network unencrypted |
| "Invalid access token", "REST API answered HTTP 401" (`auth`) | a new token, then `exakit source reauth uc_sales --password-file <file>` |
| "incorrectly configured region", "x-amz-bucket-region" (`region`) | connect again with `--set region=<the bucket's region>` |
| `clock` (RequestTimeTooSkewed, "Signature expired") | the database clock is behind (after the laptop slept): `exakit stop`, then `exakit start` |
| `norust` (exit 23) | the Rust language container is missing: rerun with `--yes` after telling the user |

`exakit connect` shows the clock first: "Database clock: in sync with this
computer.", or a warning that offers the restart at a terminal.

## 10. Keep it working

- A Databricks token stops working on its expiry date: a new one, then
  `exakit source reauth uc_sales --password-file ~/.config/exakit/<name>.pat`.
- Another workspace, schema or region:
  `exakit connect unity --name uc_sales --set namespace=<catalog>.<schema> --password-file <pat> --yes`
  (`--dry-run` first). `VS_UC_SALES` keeps its name; the token is asked for again.
- Tables added to the schema: `exakit source refresh uc_sales`.
- Stop: `exakit source disconnect uc_sales` or `exakit source remove uc_sales`
  (`--dry-run` first, then ask) - see the shared skill.
