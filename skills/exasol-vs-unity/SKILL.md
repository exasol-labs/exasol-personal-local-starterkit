---
name: exasol-vs-unity
description: Connect a Unity Catalog schema (Databricks or OSS) to local Exasol with exakit connect unity, its tables read straight from your own cloud storage by the lakehouse engine with no warehouse - Beta, not yet run against a live Unity Catalog. Covers the inputs to collect (workspace URL, catalog.schema, the bucket's region, a personal access token), finding them with the Databricks CLI, External Data Access and the EXTERNAL USE SCHEMA grant, when to use the databricks connector instead, the unattended connect line, and the Unity-specific failures. Connector id unity, aliases uc and oss-unity-catalog, tier Beta. Triggers — "read Unity Catalog tables without a warehouse", "Unity Catalog external data access for Exasol", "EXTERNAL USE SCHEMA for exakit", "query Unity Catalog tables from storage in Exasol", "exakit connect unity".
---

# Unity Catalog via the lakehouse engine → local Exasol (Beta)

Shared rules (credential handling, the lakehouse engine, exit codes, disconnect
versus remove) live in [exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md).
Load it too; this skill adds only what is the Unity route's own.

## 1. When to use it

A Unity Catalog schema whose tables sit on the user's own cloud storage, read
by the same pinned engine and scripts as the Glue route, inside this database:
nothing runs on Databricks compute. One schema is one source. **Beta: this route
has not been run against a live Unity Catalog yet - tell the user.**

Use `exasol-vs-databricks` (through a SQL warehouse) instead when the schema is
on Databricks Default Storage (never readable from outside), when External Data
Access cannot be switched on, or for Databricks catalog-managed tables, which
this adapter version cannot read.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `workspace_url` | yes | | https-url | the workspace URL, `https://...` only, e.g. `https://dbc-1234.cloud.databricks.com` |
| `namespace` | yes | | unity-namespace | the schema as `catalog.schema`, e.g. `main.sales` |
| `region` | yes | | aws-region | the AWS region of the bucket that holds the tables, e.g. `us-east-2` |
| `secret` | yes | | secret | a Databricks personal access token - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`. Unity's
temporary storage credentials carry no region, so the region is asked for,
not guessed.

## 3. Find each value (read-only)

```bash
databricks catalogs list
databricks schemas list <catalog>
databricks schemas get <catalog>.<schema>      # storage_root / storage_location: where its tables live
databricks tables list <catalog> <schema>
databricks metastores summary                   # external_access_enabled must be true
aws s3api get-bucket-location --bucket <bucket-from-storage_location>   # the region; null means us-east-1
```

`--url 'https://<workspace-host>'` fills `workspace_url`.

## 4. Prepare a reader at the source (recommended grants; show, then run on a yes)

A metastore admin switches External Data Access on for the metastore. Then, as
the catalog's owner (only it may grant EXTERNAL USE SCHEMA, and it must be
granted explicitly), for the token's user:

```sql
GRANT USE CATALOG ON CATALOG <catalog> TO `<reader@example.com>`;
GRANT USE SCHEMA, EXTERNAL USE SCHEMA, SELECT ON SCHEMA <catalog>.<schema> TO `<reader@example.com>`;
```

The token, signed in to the CLI as that reader, straight into a file (never
print it) - or the reader makes it in Settings > Developer > Access tokens:

```bash
umask 077; mkdir -p ~/.config/exakit
databricks tokens create --comment exakit-<name> --lifetime-seconds 2592000 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_value"])' > ~/.config/exakit/<name>.pat
```

## 5. Network

The workspace URL is `https` only. A workspace with IP access lists must allow
this computer's public IP (`exakit connect` shows it; fallback: the `python3`
one-liner in the shared skill) - see `exasol-vs-databricks` section 5 for the
commands and the first-list caution.

## 6. Connect

```bash
exakit connect unity --name uc_sales --set workspace_url=https://<workspace-host> \
  --set namespace=<catalog>.<schema> --set region=<region> --dry-run
exakit connect unity --name uc_sales --set workspace_url=https://<workspace-host> \
  --set namespace=<catalog>.<schema> --set region=<region> \
  --password-file ~/.config/exakit/<name>.pat --yes
```

The first lakehouse source installs the Rust language container after asking
(`--yes` consents: tell the user - one restart). The tables appear as
`VS_UC_SALES`.

## 7. Verify

```bash
exakit source check uc_sales
exakit source describe uc_sales
exakit sql "SELECT * FROM VS_UC_SALES.ORDERS LIMIT 10"   # names arrive upper case: no quotes
```

## 8. When it fails

| Message | Fix |
|---|---|
| "Unity Catalog does not let engines outside Databricks read this schema's files" (EXTERNAL USE SCHEMA, External Data Access, EXTERNAL_ACCESS_DISABLED) | switch External Data Access on and grant EXTERNAL USE SCHEMA (section 4) - Default Storage never works: use `exakit connect databricks` |
| "catalog-managed table, which this adapter version cannot read yet" | read it through the SQL warehouse: `exakit connect databricks` |
| "no such namespace" (SCHEMA_DOES_NOT_EXIST) | check `catalog.schema` and the user's grants |
| "namespace must be catalog.schema" | give both parts, e.g. `main.sales` |
| "workspace_url must use https" | the token never crosses the network unencrypted |
| "Invalid access token", "REST API answered HTTP 401" | a new token, then `exakit source reauth uc_sales --password-file <file>` |
| "incorrectly configured region", "x-amz-bucket-region" | connect again with `--set region=<the bucket's region>` |
| exit 23 | the Rust language container is missing: rerun with `--yes` after telling the user |

## 9. Keep it working

- A Databricks token stops working on its expiry date: a new one, then
  `exakit source reauth uc_sales --password-file ~/.config/exakit/<name>.pat`.
- Tables added to the schema: `exakit source refresh uc_sales`.
- Stop: `exakit source disconnect uc_sales` or `exakit source remove uc_sales`
  (`--dry-run` first, then ask) - see the shared skill.
