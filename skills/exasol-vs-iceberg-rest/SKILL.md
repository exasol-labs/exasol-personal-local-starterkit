---
name: exasol-vs-iceberg-rest
description: Connect Iceberg tables behind an Iceberg REST catalog (Polaris, Lakekeeper, Nessie, Gravitino) to local Exasol as a virtual schema with exakit connect iceberg-rest, read in place from storage by the lakehouse engine - Beta, not yet run against a live catalog. Covers the inputs to collect (catalog URL, warehouse, namespace, and either a catalog token or storage keys with region and endpoint), checking them against the catalog's REST API, least-privilege reads, https versus http, the unattended connect line, and the REST-specific failures. Connector id iceberg-rest, aliases rest, rest-catalog and iceberg-rest-catalog, tier Beta. Triggers — "connect an Iceberg REST catalog", "query a Polaris catalog from Exasol", "Lakekeeper or Nessie catalog in Exasol", "Iceberg on MinIO from Exasol", "exakit connect iceberg-rest", "NoSuchNamespaceException from exakit".
---

# Iceberg REST catalog → local Exasol (Beta)

Shared rules (credential handling, the lakehouse engine, the `--json` answer and
failure kinds, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is the REST route's own.

## 1. When to use it

The Iceberg tables of one namespace in an Iceberg REST catalog, read where they
lie in storage by the same pinned engine and scripts as the Glue route
(`exasol-vs-lakehouse`). One namespace is one source. **Beta: this route has
not been run against a live Iceberg REST catalog yet - tell the user.** For AWS
Glue use `exasol-vs-lakehouse`; for Databricks Unity Catalog, `exasol-vs-unity`
or `exasol-vs-databricks`.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `catalog_url` | yes | | catalog-url | the catalog's REST base URL, path included (`https://host[:port][/path]`) |
| `warehouse` | yes | | warehouse | the warehouse the catalog knows it by (e.g. `s3://warehouse/` or a catalog name) |
| `namespace` | yes | | iceberg-namespace | the namespace to expose (dotted for nested levels) |
| `endpoint` | no | | endpoint-url | an S3-compatible store's endpoint (MinIO...), only with storage keys; scheme, host and port, no path |
| `region` | no | | storage-region | with storage keys: the bucket's region (required then); with a token: leave it to the catalog |
| `access_key_id` | no | | access-key | the storage access key ID; leave it out to use a catalog token |
| `secret` | yes | | secret | the storage secret key, or the catalog token - the value itself, not JSON - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

Two credential modes:

- **A catalog token** (no `access_key_id`, no `endpoint`): the catalog vends
  short-lived storage credentials per table.
- **Storage keys** (`access_key_id` + the secret key + `region`, and
  `endpoint` for MinIO and other S3-compatible stores, path-style): the catalog
  only names the files.

## 3. Find each value (read-only)

The catalog's own docs or console name its REST base URL and warehouse. Check
them against the REST API, the token kept out of the command line:

```bash
umask 077; printf 'Authorization: Bearer %s\n' "$(cat ~/.config/exakit/<name>.token)" > ~/.config/exakit/<name>.hdr
curl -sf -H @"$HOME/.config/exakit/<name>.hdr" "<catalog_url>/v1/config?warehouse=<warehouse>"
curl -sf -H @"$HOME/.config/exakit/<name>.hdr" "<catalog_url>/v1/<prefix>/namespaces"
rm -f ~/.config/exakit/<name>.hdr
```

`/v1/config` answers when the URL, warehouse and token are right; namespaces
and their tables live under `/v1/{prefix}/namespaces` and
`/v1/{prefix}/namespaces/{namespace}/tables` (the prefix as the catalog
defines it). `--url '<catalog_url>'` fills `catalog_url`; a `user:secret@` or a
query string in it is never kept.

## 4. Prepare a reader at the source (show, then run on a yes)

What the source must grant: read on the namespace in the catalog (list and load
its tables) and, with storage keys, list and read on the table files
(`s3:ListBucket`, `s3:GetObject` or the store's equivalent). How is the
catalog's own business (principal roles, policies). Put the token or secret key
straight into an owner-only file, e.g. `~/.config/exakit/<name>.token`; never
print it.

## 5. Network

The catalog URL and the storage must be reachable from inside the database.
`https` by default; plain `http` is accepted only when typed, and only towards
this computer (`192.168.64.1` on macOS, `host.containers.internal` on Linux and
WSL) or a private network - the virtual schema then carries `ALLOW_HTTP`.
`localhost` is refused. A cloud catalog or bucket behind an allowlist must
allow this computer's public IP (`exakit connect` shows it; fallback: the
`python3` one-liner in the shared skill).

## 6. Connect

```bash
# a catalog token
exakit connect iceberg-rest --name lake --set catalog_url=<catalog_url> --set warehouse=<warehouse> \
  --set namespace=<namespace> --password-file ~/.config/exakit/<name>.token --yes --json
# storage keys on MinIO
exakit connect iceberg-rest --name lake --set catalog_url=<catalog_url> --set warehouse=<warehouse> \
  --set namespace=<namespace> --set endpoint=https://minio.example.com:9000 --set region=us-east-1 \
  --set access_key_id=<key-id> --password-file ~/.config/exakit/<name>.secret --yes --json
```

Run each with `--dry-run` instead of `--yes --json` first. The first lakehouse source
installs the Rust language container after asking (`--yes` consents: tell the
user - one restart). The tables appear as `VS_LAKE`; connect again with another
`--name` for the next namespace.

## 7. Verify

```bash
exakit source check lake
exakit source describe lake
exakit sql "SELECT * FROM VS_LAKE.ORDERS LIMIT 10"   # names arrive upper case: no quotes
```

## 8. When it fails

| Message | Fix |
|---|---|
| "NotAuthorizedException" | the catalog refused the token or keys: a new one, then `exakit source reauth lake --password-file <file>` |
| "the catalog has no such namespace that this credential can see" (NoSuchNamespaceException, NoSuchWarehouseException) | check the namespace and the warehouse |
| "region is required with an access key" | add `--set region=` (MinIO usually answers to `us-east-1`) |
| "a storage endpoint goes with an access key" | drop `endpoint`, or use storage keys |
| "... is plain http to <host>, a public host" | use `https`; http only for this computer or a private network |
| "... carries credentials (user:password@)" | take them out of the URL; the secret goes in `--password-file` |
| "give the token itself, not JSON" | the file holds only the token or secret key |
| "incorrectly configured region", "x-amz-bucket-region" | connect again with `--set region=<the bucket's region>` |
| `norust` (exit 23) | the Rust language container is missing: rerun with `--yes` after telling the user |

## 9. Keep it working

- A new token or key: `exakit source reauth lake --password-file <file>`.
- Tables added to the namespace: `exakit source refresh lake`.
- Stop: `exakit source disconnect lake` or `exakit source remove lake`
  (`--dry-run` first, then ask) - see the shared skill.
