# Iceberg REST catalog

One namespace of any Iceberg REST catalog (Databricks Unity Catalog's Iceberg
endpoint, Apache Polaris / Snowflake Open Catalog, Lakekeeper, Nessie, a local
catalog on MinIO), read straight from storage by an engine inside your Exasol
database.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-iceberg-rest` knows this connector.
>
> **You still need, on your computer:** your catalog's console or CLI (for
> Databricks: the workspace UI or the Databricks CLI), and `curl` to test the
> URL.
>
> **Prefer to do it by hand?** Follow the steps below.

AWS Glue's Iceberg REST endpoint needs SigV4 request signing, which this
connector does not support. For Glue use the [lakehouse](lakehouse.md)
connector.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `ice` |
| Catalog URL | yes | `https://dbc-1234abcd-5678.cloud.databricks.com/api/2.1/unity-catalog/iceberg-rest` |
| Warehouse (catalog name) | yes | `main` (Databricks: the catalog name) |
| Namespace (one namespace is one virtual schema) | yes | `sales` |
| Storage endpoint (MinIO etc.) | no (Enter for AWS S3) | `https://minio.example.com:9000` |
| Storage region | no (Enter to let the catalog say) | `us-east-1` |
| Storage access key ID | no (Enter to use a catalog token) | `AKIA...` |
| Catalog token or storage secret | yes | (hidden) |

Two ways to sign in:

- **A catalog token** (leave endpoint and access key empty): the catalog hands
  out short-lived storage credentials per table. Databricks works this way.
- **Storage keys** (access key ID, secret key and region; plus the endpoint for
  MinIO and other S3-compatible stores): the catalog only names the files.

## Where to find each value

### Databricks Unity Catalog (token)

1. **Catalog URL:** `https://<workspace-host>/api/2.1/unity-catalog/iceberg-rest`.
   The workspace host is in your browser's address bar.
2. **Warehouse:** the Unity Catalog **catalog** name (Catalog → `<catalog>`).
3. **Namespace:** the **schema** name inside that catalog.
4. **Token:** a personal access token. User menu (top right) → Settings →
   Developer → Access tokens → Manage → Generate new token. Save it in an
   owner-only file such as `~/.config/exakit/ice.token`.
5. **Endpoint and access key:** leave empty. **Region:** leave empty, or give
   the region of the bucket that holds the tables.
6. **Grants and switches:** the same as for the [Unity Catalog](unity.md#2-external-data-access-and-grants)
   connector: External Data Access on the metastore, `EXTERNAL USE SCHEMA` on
   the schema, and a schema on your own cloud storage, not Default Storage.

### Other catalogs

The catalog's console or docs name its REST base URL (path included) and the
warehouse. Check them before you connect, with the token kept out of the
command line:

```bash
umask 077; printf 'Authorization: Bearer %s\n' "$(cat ~/.config/exakit/ice.token)" > ~/.config/exakit/ice.hdr
curl -sf -H @"$HOME/.config/exakit/ice.hdr" "<catalog-url>/v1/config?warehouse=<warehouse>"
rm -f ~/.config/exakit/ice.hdr
```

`/v1/config` answers when URL, warehouse and token are right. The reader needs
read on the namespace (list and load tables) and, with storage keys,
`s3:ListBucket` and `s3:GetObject` (or the store's equivalent) on the table files.

### Network

`https` by default. Plain `http` is accepted only for this computer or a
private network: on macOS a catalog on this computer is `http://192.168.64.1:<port>`,
never `localhost`. A cloud catalog or bucket behind an IP allowlist must allow
your public IP (`curl https://checkip.amazonaws.com`).

## Connect

```bash
exakit connect iceberg-rest
```

The kit asks for the catalog URL (hidden; press Enter on an empty line to type
the fields instead), then each field above. It shows a plan and asks once. The
first lakehouse source installs the Rust language container (one restart).
Your tables appear as `VS_ICE`.

Without prompts:

```bash
# Databricks, with a token
exakit connect iceberg-rest --name ice \
  --set catalog_url=https://dbc-1234abcd-5678.cloud.databricks.com/api/2.1/unity-catalog/iceberg-rest \
  --set warehouse=main --set namespace=sales --password-file ~/.config/exakit/ice.token --yes
# MinIO, with storage keys
exakit connect iceberg-rest --name ice --set catalog_url=https://catalog.example.com/api/catalog \
  --set warehouse=s3://warehouse/ --set namespace=sales --set endpoint=https://minio.example.com:9000 \
  --set region=us-east-1 --set access_key_id=<key-id> --password-file ~/.config/exakit/ice.secret --yes
exakit sql "SELECT * FROM VS_ICE.ORDERS LIMIT 10"
```

The file holds only the token or secret key, not JSON. Add `--dry-run` to see
the plan first. One namespace is one source: connect again with another
`--name` for the next.

**Windows:** paste the catalog URL at the prompt rather than `--url`. For a
quoted name in `exakit sql`, pipe the statement in (`'SELECT "x" FROM VS_ICE.T' | exakit sql`)
or use `exakit sql --file query.sql`.

## Connection string you can paste

```text
https://dbc-1234abcd-5678.cloud.databricks.com/api/2.1/unity-catalog/iceberg-rest
https://polaris.example.com/api/catalog
```

Each fills the catalog URL only; type warehouse, namespace and the rest. A
`user:secret@` or query string in the URL is never kept.

## Common problems

| Symptom | Fix |
|---|---|
| "NotAuthorizedException", "HTTP 401" | The token or keys were refused: make a new one, then `exakit source reauth ice`. |
| "no such namespace that this credential can see" | Check the namespace and warehouse (Databricks: warehouse = catalog, namespace = schema) and the grants. |
| Databricks refuses to vend credentials | Turn on External Data Access and grant `EXTERNAL USE SCHEMA` ([Unity guide](unity.md)); a Default Storage schema never works. |
| "x-amz-bucket-region", "incorrectly configured region" | Connect again with `--set region=<the bucket's region>`. |
| "region is required with an access key" | Add `--set region=` (MinIO usually answers to `us-east-1`). |
