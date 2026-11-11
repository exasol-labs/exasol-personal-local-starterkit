---
name: exasol-vs-iceberg-rest
description: Connect Iceberg tables behind an Iceberg REST catalog (Polaris, Lakekeeper, Nessie, Gravitino, Databricks Unity Catalog's Iceberg endpoint) to local Exasol as a virtual schema with exakit connect iceberg-rest, read in place from storage by the lakehouse engine. Covers the inputs to collect (catalog URL, warehouse, namespace, and either a catalog token or storage keys with region and endpoint), checking them against the catalog's REST API, the Databricks endpoint with a personal access token and vended credentials, why AWS Glue's REST endpoint needs the lakehouse connector instead, https versus http, example queries on macOS, Linux and Windows, and the REST-specific failures. Connector id iceberg-rest, aliases rest, rest-catalog and iceberg-rest-catalog, tier GA. Triggers — "connect an Iceberg REST catalog", "query a Polaris catalog from Exasol", "Lakekeeper or Nessie catalog in Exasol", "Iceberg on MinIO from Exasol", "Databricks Iceberg REST endpoint in Exasol", "exakit connect iceberg-rest", "NoSuchNamespaceException from exakit".
---

# Iceberg REST catalog → local Exasol

Shared rules (credential handling, the lakehouse engine, the `--json` answer and
failure kinds, re-point, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is the REST route's own.

## 1. When to use it

The Iceberg tables of one namespace in an Iceberg REST catalog, read where they
lie in storage by the same pinned engine and scripts as the Glue route. One
namespace is one source. Tier GA.

- **Databricks Unity Catalog** works through its Iceberg endpoint (section 3),
  with the same prerequisites as `exasol-vs-unity`.
- **AWS Glue**: use `exasol-vs-lakehouse`. Glue's Iceberg REST endpoint needs
  AWS SigV4 request signing, which this connector does not support.

## 2. Fields

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `catalog_url` | yes | | the catalog's REST base URL, path included (`https://host[:port][/path]`): its console or docs; Databricks: section 3 |
| `warehouse` | yes | | the warehouse the catalog knows it by (`s3://warehouse/` or a catalog name): the catalog's console; Databricks: Catalog Explorer > the catalog's name |
| `namespace` | yes | | the namespace to expose, dotted for nested levels; Databricks: the schema name |
| `endpoint` | no | | storage keys only: an S3-compatible store's endpoint (MinIO...), scheme, host and port, no path |
| `region` | no | | storage keys: the bucket's region (required then); with a token: leave it to the catalog |
| `access_key_id` | no | | the storage access key ID; leave it out to use a catalog token |
| `secret` | yes | | the storage secret key, or the catalog token - the value itself, not JSON - only through `--password-file` |

The first question, "Name (alias) for this connection", is `--name`: the tables
appear as `VS_<NAME>`.

Two credential modes:

- **A catalog token** (no `access_key_id`, no `endpoint`): the kit asks the
  catalog for vended credentials, short-lived storage credentials per table.
- **Storage keys** (`access_key_id` + the secret key + `region`, and
  `endpoint` for MinIO and other S3-compatible stores, path-style): the catalog
  only names the files.

Check the values against the REST API, the token kept off the command line:

```bash
umask 077; printf 'Authorization: Bearer %s\n' "$(cat ~/.config/exakit/<name>.token)" > ~/.config/exakit/<name>.hdr
curl -sf -H @"$HOME/.config/exakit/<name>.hdr" "<catalog_url>/v1/config?warehouse=<warehouse>"
curl -sf -H @"$HOME/.config/exakit/<name>.hdr" "<catalog_url>/v1/<prefix>/namespaces"
rm -f ~/.config/exakit/<name>.hdr
```

`/v1/config` answers when the URL, warehouse and token are right; namespaces
and their tables live under `/v1/{prefix}/namespaces` and
`/v1/{prefix}/namespaces/{namespace}/tables` (the prefix as the catalog
defines it).

## 3. Connection-string forms

`--url` (or the first, hidden prompt at a terminal) reads one form,
`https://<catalog-host>[:port][/path]`, and fills `catalog_url`. A
`user:secret@` or a query string in it is taken as a credential and never kept.
The form has no `&`, so it pastes the same on Windows.

**Databricks Unity Catalog** (measured live):

- `catalog_url`: `https://<workspace-host>/api/2.1/unity-catalog/iceberg-rest`
- `warehouse`: the Unity catalog name; `namespace`: the schema name
- `secret`: a personal access token (Settings > Developer > Access tokens), as
  the bearer token. Leave out `access_key_id` and `endpoint`: the token mode
  uses vended credentials.
- The metastore needs External Data Access switched on, the token's user
  EXTERNAL USE SCHEMA on the schema, and the schema must be on external
  storage. Default Storage cannot be read by outside engines. Grants: see
  `exasol-vs-unity` section 4.

## 4. Prepare the source (show, then run on a yes)

- **Grants**: read on the namespace in the catalog (list and load its tables)
  and, with storage keys, list and read on the table files (`s3:ListBucket`,
  `s3:GetObject` or the store's equivalent). How is the catalog's own business
  (principal roles, policies). Put the token or secret key straight into an
  owner-only file, e.g. `~/.config/exakit/<name>.token`; never print it.
- **Network**: the catalog URL and the storage must be reachable from inside the
  database. `https` by default. Plain `http` is accepted only when typed, and
  only towards this computer or a private network; the virtual schema then
  carries `ALLOW_HTTP`. This computer is `192.168.64.1` on macOS; on Linux and
  WSL it is `host.containers.internal` (Podman) or `host.docker.internal`
  (Docker, where the deployment provides it; `192.168.65.254` on Docker
  Desktop). `localhost` is refused: inside the database it is the database
  itself. A cloud catalog or bucket behind an allowlist must allow this
  computer's public IP (`exakit connect` shows it).

## 5. TLS

No CA file. The catalog and the storage are reached over HTTPS, and the engine
checks their certificates itself: this connector has no `tls` or `ca` input.

## 6. Connect

```bash
# a catalog token (Databricks: the PAT)
exakit connect iceberg-rest --name lake --set catalog_url=<catalog_url> --set warehouse=<warehouse> \
  --set namespace=<namespace> --password-file ~/.config/exakit/<name>.token --yes --json
# storage keys on MinIO
exakit connect iceberg-rest --name lake --set catalog_url=<catalog_url> --set warehouse=<warehouse> \
  --set namespace=<namespace> --set endpoint=https://<minio-host>:9000 --set region=us-east-1 \
  --set access_key_id=<key-id> --password-file ~/.config/exakit/<name>.secret --yes --json
```

Run each with `--dry-run` instead of `--yes --json` first. PowerShell is the
same line, with `` ` `` for a line break. The first lakehouse source installs
the Rust language container - at once at a terminal, with `--yes` in a script.
Tell the user first: a download and one database restart. The tables appear as
`VS_LAKE`; connect again with another `--name` for the next namespace.

## 7. Verify and query

```bash
exakit source check lake
exakit source describe lake
exakit sql 'SELECT * FROM VS_LAKE.ORDERS LIMIT 10'
exakit sql 'SELECT COUNT(*) AS N FROM VS_LAKE.ORDERS'
```

Names arrive upper case, so these need no quotes and run the same in Windows
PowerShell 5.1. A query with a quoted name loses its inner double quotes as a
PowerShell 5.1 argument: pipe it in or use a file there.

```powershell
'SELECT "ORDER_ID" FROM VS_LAKE."ORDERS" LIMIT 10' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

Table and column names arrive upper case (`ORDERS`, `ORDER_ID`). Deletes,
refused formats and the edge cases that differ from native Exasol are the
lakehouse engine's: see the shared skill.

## 9. When it fails

| Message | Fix |
|---|---|
| "NotAuthorizedException" (`auth`) | the catalog refused the token or keys: a new one, then `exakit source reauth lake --password-file <file>` |
| "the catalog has no such namespace that this credential can see" (NoSuchNamespaceException, NoSuchWarehouseException, SCHEMA_DOES_NOT_EXIST) | check the namespace and the warehouse (Databricks: catalog name and schema name) |
| "Unity Catalog does not let engines outside Databricks read this schema's files" (`external`) | Databricks endpoint: External Data Access and EXTERNAL USE SCHEMA (section 3) |
| "region is required with an access key" | add `--set region=` (MinIO usually answers to `us-east-1`) |
| "a storage endpoint goes with an access key" | drop `endpoint`, or use storage keys |
| "... is plain http to <host>, a public host" | use `https`; http only for this computer or a private network |
| "... carries credentials (user:password@)" | take them out of the URL; the secret goes in `--password-file` |
| "give the token itself, not JSON" | the file holds only the token or secret key |
| "incorrectly configured region", "x-amz-bucket-region" (`region`) | connect again with `--set region=<the bucket's region>` |
| `clock` (RequestTimeTooSkewed, "Signature expired") | the database clock is behind (after the laptop slept): `exakit stop`, then `exakit start` |
| `norust` (exit 23) | the Rust language container is missing: rerun with `--yes` after telling the user |

`exakit connect` shows the clock first: "Database clock: in sync with this
computer.", or a warning that offers the restart at a terminal.

## 10. Keep it working

- A new token or key: `exakit source reauth lake --password-file <file>`.
- The catalog moved:
  `exakit connect iceberg-rest --name lake --set catalog_url=<new> --password-file <file> --yes`
  (`--dry-run` first). `VS_LAKE` keeps its name; the token or key is asked for again.
- Tables added to the namespace: `exakit source refresh lake`.
- Stop: `exakit source disconnect lake` or `exakit source remove lake`
  (`--dry-run` first, then ask) - see the shared skill.
