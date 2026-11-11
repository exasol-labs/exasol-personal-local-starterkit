# Lakehouse (Iceberg / Delta)

Iceberg, Delta and Parquet tables, read straight from their files by an engine
inside your Exasol database. Nothing runs on a warehouse, Athena or Databricks
compute. One connector covers every catalog the engine knows: you pick where
the table list is kept (the catalog), then how Exasol opens the files.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-lakehouse` knows this connector.
>
> **You still need, on your computer:** the console or CLI of your catalog and
> your storage (AWS CLI, Databricks CLI or workspace, Azure portal or `az`), to
> look up the values and make a read-only login.
>
> **Prefer to do it by hand?** Follow the steps below.

The connector id is `lakehouse`. The old ids `iceberg-rest` and `unity` are
gone and have no aliases. A source you saved with one of them is moved to
`lakehouse` (with its catalog and files) the first time the kit reads it, so
`exakit source list`, `show`, `check` and `remove` keep working.

## Databricks or Lakehouse?

Both can read a Databricks Unity Catalog schema. They work differently.

| | `databricks` (Profile C) | `lakehouse` (Profile D) |
|---|---|---|
| Who reads the files | the Databricks SQL warehouse | Exasol, with the Rust lakehouse engine |
| What travels to Exasol | answer rows over JDBC | the table files themselves |
| Databricks compute | yes, every query (it starts a stopped warehouse) | none |
| Where the files may be | anywhere Databricks can read (S3, ADLS, GCS) | S3, S3-compatible or Azure ADLS Gen2 |
| Unity prerequisites | a token and `CAN USE` on the warehouse | External Data Access, `EXTERNAL USE SCHEMA`, a schema on your own storage |
| Default Storage schemas | yes | no |
| Catalogs | Unity Catalog only | Iceberg REST, Unity Catalog, AWS Glue, or no catalog |

Use [Databricks](databricks.md) for files on GCS, for a schema on Default
Storage, for catalog-managed tables, or when you cannot get the Unity grants.
Use Lakehouse when you want no Databricks compute, or the catalog is not
Databricks.

## Catalogs and files

The first choice is the **catalog**: who answers "where are my tables?".

| `catalog` | Label | Typical use |
|---|---|---|
| `iceberg-rest` | Iceberg REST catalog | Polaris, Snowflake Open Catalog, Lakekeeper, Nessie, Gravitino, the Databricks Iceberg endpoint |
| `unity` | Unity Catalog | Databricks on AWS, Azure or GCP |
| `glue` | AWS Glue | tables written by Athena, EMR, Spark or Glue jobs |
| `none` | No catalog - Parquet files in a folder | Parquet files under one prefix, no catalog at all |

The second choice is the **files**: how Exasol opens the data files.

| `files` | Label | What Exasol uses |
|---|---|---|
| `vended` | Let the catalog give access | the catalog hands out short-lived storage access per table |
| `s3` | Amazon S3 / S3-compatible | your S3 access key, plus an endpoint for a non-AWS store |
| `azure` | Azure ADLS Gen2 | your storage account key or a SAS |
| (none) | Google Cloud Storage - not supported yet | shown in the menu, cannot be picked |

### The 9 combinations that work

| Catalog \ Files | `vended` | `s3` | `azure` | Google Cloud Storage |
|---|---|---|---|---|
| `iceberg-rest` | yes | yes | yes | no (adapter) |
| `unity` | yes | yes | yes | no (adapter) |
| `glue` | no | yes, automatic | no | no |
| `none` | no | yes | yes | no (adapter) |

A combination is shown as "Lakehouse · <catalog label> · <files label>" in
panels and in `exakit source show`, for example "Lakehouse · Unity Catalog ·
Azure ADLS Gen2".

Why the other 7 are not possible:

- **Any catalog + Google Cloud Storage (4).** The engine has two storage
  backends, S3 and ADLS, and refuses `gs://` paths. For Unity tables on GCS, use
  the [Databricks](databricks.md) connector.
- **Glue + vended.** Glue does not hand out file access.
- **Glue + Azure.** Glue tables live on S3. With `catalog=glue` there is no
  files question: the files are S3, opened with the same AWS key.
- **No catalog + vended.** There is no catalog to hand out access.

A combination that is not valid stops the connect with kind `input`, and the
remedy names the `files` values that work for that catalog.

## What `exakit connect` asks for

`*` is required. A hidden field is typed without echo. Every combination starts
with **Name (alias) for this connection** (`--name`): `sales_lake` gives the
schema `VS_SALES_LAKE`.

### Catalog fields

| Catalog | Field | `--set` key | Example |
|---|---|---|---|
| `iceberg-rest` | Catalog URL * | `catalog_url` | `https://polaris.example.com/api/catalog` |
| | Warehouse (catalog name) * | `warehouse` | `analytics` |
| | Namespace * | `namespace` | `sales` |
| `unity` | Workspace URL * | `workspace_url` | `https://dbc-1234abcd-5678.cloud.databricks.com` |
| | Catalog.schema * | `namespace` | `main.sales` |
| `glue` | AWS region * | `region` | `eu-central-1` |
| | Glue database * | `database` | `sales_db` |
| | Access key ID * | `access_key_id` | `AKIA...` |
| | Secret access key (hidden) * | `secret` (`--password-file`) | |
| | Glue catalog ID | `catalog_id` | `123456789012` (optional) |
| `none` | Folder path * | `path` | `s3://sales-lake/orders/` or `abfss://lake@saleslake.dfs.core.windows.net/orders/` |

### Catalog login (`iceberg-rest` and `unity` only)

| `login` | Fields |
|---|---|
| `token` (default) | Catalog token (hidden) * (`secret`, `--password-file`). For Unity the label is "Databricks token". |
| `oauth` | Client ID * (`client_id`), Client secret (hidden) * (`secret`, `--password-file`), Token endpoint (`token_endpoint`, optional), Scope (`scope`, optional) |

Pick one. A token and an OAuth client together are refused. Glue signs its
requests with the AWS key, and `none` has no catalog, so neither asks for a
login.

### Files fields

| `files` | Field | `--set` key | Example |
|---|---|---|---|
| `vended` | AWS region (only if the files are on S3) | `region` | `us-east-2` |
| `s3` | AWS region * | `region` | `eu-central-1` |
| | Access key ID * | `access_key_id` | `AKIA...` |
| | Secret access key (hidden) * | `storage_secret` (`--storage-secret-file`; with `catalog=none`, `--password-file`) | |
| | Endpoint (S3-compatible store) | `endpoint` | empty for Amazon S3 |
| `azure` | Azure storage account * | `account_name` | `saleslake` |
| | Account key or SAS (hidden) * | `storage_secret` (`--storage-secret-file`; with `catalog=none`, `--password-file`) | |

- **Region with vended files.** Leave it empty on Azure. On S3, give the
  bucket's region when the catalog does not send one: Unity's vended
  credentials carry no region.
- **Account key or SAS.** A value that starts with `sv=` or `?sv=` is a SAS;
  anything else is taken as the account key.
- **No catalog on Azure.** The storage account comes from the `abfss://` path,
  so it is not asked.

## Two secrets

A connection can carry two secrets: the **catalog secret** (a token or an OAuth
client secret) and the **storage secret** (an S3 secret key or an Azure key or
SAS). Neither ever goes on the command line.

| Combination | `secret`: `--password-file F` or `--password-stdin` | `storage_secret`: `--storage-secret-file F` |
|---|---|---|
| `iceberg-rest` or `unity` + `vended` | the catalog secret | not used |
| `iceberg-rest` or `unity` + `s3` or `azure` | the catalog secret | the storage secret |
| `glue` | the AWS secret access key | not used |
| `none` + `s3` or `azure` | the storage secret | not used |

There is only one stdin, so the second secret comes from a file, or from a
hidden prompt at a terminal. Each file holds the secret alone, not JSON, and
should be readable by you only. A credential inside a pasted connection string
is used and not asked again.

Write a secret to a file without it showing on screen or in the history:

```bash
umask 077; mkdir -p ~/.config/exakit
read -rs -p 'Secret: ' S; printf '%s' "$S" > ~/.config/exakit/lake.token; unset S; echo
```

```powershell
New-Item -ItemType Directory -Force "$HOME\.config\exakit" | Out-Null
$s = [Net.NetworkCredential]::new("", (Read-Host "Secret" -AsSecureString)).Password
[IO.File]::WriteAllText("$HOME\.config\exakit\lake.token", $s); Remove-Variable s
```

## What the adapter receives

All four catalogs run the same adapter, exasol-labs/lakehouse-engine-rs, as the
shared script `EXAKIT_VS.LAKEHOUSE_ADAPTER`. The kit turns your answers into
its properties:

| `catalog` | `CATALOG_KIND` | Connection `TO` | `NAMESPACE` |
|---|---|---|---|
| `iceberg-rest` | not set (REST is the default) | the catalog URL | the namespace |
| `unity` | `UNITY_CATALOG` | the workspace URL | `catalog.schema` |
| `glue` | `GLUE` | `https://glue.<region>.amazonaws.com` | the Glue database |
| `none` | `DIRECT_STORAGE` | the folder path | not set |

The connection's password is a JSON object with these keys:

| Part | JSON keys |
|---|---|
| `iceberg-rest` | `warehouse` |
| `login=token` | `token` |
| `login=oauth` | `client_id`, `client_secret`, and `oauth2_server_uri` and `scope` when given |
| `files=vended` | `use_vended_credentials: true`, and `region` when given |
| `files=s3` | `access_key`, `secret_key`, `region`, and `endpoint` plus `path_style: true` when an endpoint is given |
| `files=azure` | `account_name`, and `account_key` or `sas_token` |
| `glue` | `access_key`, `secret_key`, `region`, and `warehouse` = the catalog ID when given |

When any URL is `http://`, the virtual schema also gets `ALLOW_HTTP=TRUE`.

## S3-compatible stores: the Endpoint field

Leave Endpoint empty for Amazon S3. Fill it for any other store that speaks
the S3 API; the kit then sends `endpoint` and `path_style: true`. These stores
are not tested in the kit yet.

| Store | Endpoint example | Notes |
|---|---|---|
| Amazon S3 | (leave empty) | region only |
| MinIO | `http://minio.local:9000` | `http` adds `ALLOW_HTTP=TRUE` |
| Ceph Object Gateway (RGW) | `https://rgw.example.com` | |
| Cloudflare R2 | `https://<account-id>.r2.cloudflarestorage.com` | region `auto` |
| Wasabi | `https://s3.<region>.wasabisys.com` | |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | |
| DigitalOcean Spaces | `https://<region>.digitaloceanspaces.com` | |
| Akamai / Linode Object Storage | `https://<region>.linodeobjects.com` | |
| Scaleway Object Storage | `https://s3.<region>.scw.cloud` | |
| Hetzner Object Storage | `https://<region>.your-objectstorage.com` | |
| IBM Cloud Object Storage | `https://s3.<region>.cloud-object-storage.appdomain.cloud` | HMAC keys |
| Oracle OCI Object Storage | `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com` | Customer Secret Keys |
| Dell ECS, NetApp StorageGRID, Pure FlashBlade, Cloudian, Hitachi HCP | the vendor's S3 URL | on-premises appliances |
| Google Cloud Storage (S3 interoperability) | `https://storage.googleapis.com` | HMAC keys; untested, not the native `gs://` path |

**Azure needs no endpoint.** The adapter builds the address from the storage
account name (`<account>.dfs.core.windows.net`), so Azure asks only for the
account and the key or SAS.

**Google Cloud Storage is not supported.** The adapter (v0.57.3, and v0.58.1)
has no GCS backend and refuses `gs://`. The S3 interoperability row above is a
possible workaround, untested. When the adapter adds a storage or a catalog,
the kit adds one choice to the menu, not a new connector.

## Where to find each value

### Iceberg REST catalog

- **Catalog URL and warehouse:** the catalog's console or docs name its REST
  base URL (path included) and the warehouse.
- **Databricks Iceberg endpoint:** Catalog URL
  `https://<workspace-host>/api/2.1/unity-catalog/iceberg-rest`, warehouse =
  the Unity catalog name, namespace = the schema name, a personal access token,
  files `vended`. The Unity prerequisites below apply.
- **AWS Glue:** use `catalog=glue`. Glue's own Iceberg REST endpoint needs SigV4
  request signing, which the REST route does not do.
- **Check the values** before you connect, with the token kept off the command
  line:

  ```bash
  umask 077; printf 'Authorization: Bearer %s\n' "$(cat ~/.config/exakit/lake.token)" > ~/.config/exakit/lake.hdr
  curl -sf -H @"$HOME/.config/exakit/lake.hdr" "<catalog-url>/v1/config?warehouse=<warehouse>"
  rm -f ~/.config/exakit/lake.hdr
  ```

  `/v1/config` answers when the URL, warehouse and token are right.

### Unity Catalog

1. **Workspace URL:** your browser's address bar, `https://` and the host only.
2. **Catalog.schema:** Catalog → `<catalog>` → `<schema>`, given as
   `main.sales` (`databricks schemas list <catalog>`).
3. **External Data Access** is on for the metastore. A metastore admin:
   Catalog → gear icon → Metastore → External data access → Enable.
   `databricks metastores summary` shows `external_access_enabled: true`.
4. **The schema is on your own storage**, not Default Storage: Catalog →
   `<schema>` → Details → Storage location is an `s3://` or `abfss://` path.
5. **Grants** for the token's user, from the catalog's owner (only the owner may
   grant `EXTERNAL USE SCHEMA`, and it is never implied):

   ```sql
   GRANT USE CATALOG ON CATALOG main TO `reader@example.com`;
   GRANT USE SCHEMA, EXTERNAL USE SCHEMA, SELECT ON SCHEMA main.sales TO `reader@example.com`;
   ```

6. **Token:** signed in as the reader, user menu → Settings → Developer →
   Access tokens → Generate new token. Or an OAuth client: a service principal
   with an OAuth secret (`login=oauth`; the token endpoint defaults to
   `/oidc/v1/token`).

Catalog-managed tables cannot be read by this adapter version: read those
through [Databricks](databricks.md).

### AWS Glue

- **Region and database:** AWS Glue → Data Catalog → Databases (the region is
  top right). The database name may not contain a dot.

  ```bash
  aws glue get-databases --region eu-central-1 --query "DatabaseList[].Name" --output text
  aws glue get-tables --region eu-central-1 --database-name sales_db --output table \
    --query "TableList[].{name:Name,type:Parameters.table_type,location:StorageDescriptor.Location}"
  ```

- **A read-only key.** It signs both the Glue and the S3 requests, so it needs
  `glue:GetDatabase`, `glue:GetTables`, `glue:GetTable`, `glue:GetPartitions`
  on the catalog, database and tables, plus `s3:ListBucket` and `s3:GetObject`
  where the tables live:

  ```json
  {"Version": "2012-10-17", "Statement": [
    {"Effect": "Allow", "Action": ["glue:GetDatabase", "glue:GetTables", "glue:GetTable", "glue:GetPartitions"],
     "Resource": ["arn:aws:glue:eu-central-1:<account-id>:catalog",
                  "arn:aws:glue:eu-central-1:<account-id>:database/sales_db",
                  "arn:aws:glue:eu-central-1:<account-id>:table/sales_db/*"]},
    {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::my-lake-bucket"},
    {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::my-lake-bucket/sales_db/*"}]}
  ```

  IAM → Users → Create user → attach the policy → Security credentials →
  Create access key. Lake Formation grants are not evaluated.
- **Glue catalog ID:** only for a catalog in another account; it is the
  12-digit account ID.

### Files on S3

- **Region:** S3 → Buckets → the AWS Region column, or
  `aws s3api get-bucket-location --bucket <bucket>` (`null` means `us-east-1`).
- **Key:** an IAM user with `s3:ListBucket` on the bucket and `s3:GetObject` on
  the table prefix. For another store, its own access key and the Endpoint.

### Files on Azure ADLS Gen2

- **Storage account:** Azure portal → Storage accounts. The account needs a
  hierarchical namespace (ADLS Gen2).
- **Account key:** the account → Security + networking → Access keys.
- **Or a SAS:** the account → Shared access signature, with Read and List; or
  a container SAS with Read and List. Use the token that starts with `sv=`.
- Service principals and managed identities are not supported by the adapter.

### Network

`https` by default. Plain `http` is accepted only for this computer or a
private network; on macOS this computer is `192.168.64.1`, never `localhost`.
A catalog, workspace, bucket or storage account behind an IP allowlist must
allow your public IP (`curl https://checkip.amazonaws.com`).

## Connect

```bash
exakit connect lakehouse
```

The kit asks for the catalog, then the files, then only the fields of that
combination. It shows a plan and asks once. The first lakehouse source
installs the Rust language container (a download and one database restart).

### Without prompts: bash (macOS, Linux)

```bash
# Unity Catalog, files on Azure: two secrets
exakit connect lakehouse --name sales_lake --set catalog=unity --set files=azure \
  --set workspace_url=https://adb-1234567890123456.7.azuredatabricks.net --set namespace=main.sales \
  --set account_name=saleslake \
  --password-file ~/.config/exakit/uc.token --storage-secret-file ~/.config/exakit/azkey.txt --yes

# Iceberg REST catalog, vended files, OAuth client
exakit connect lakehouse --name ice --set catalog=iceberg-rest --set files=vended --set login=oauth \
  --set catalog_url=https://polaris.example.com/api/catalog --set warehouse=analytics \
  --set namespace=sales --set client_id=exakit-reader --set scope=PRINCIPAL_ROLE:ALL \
  --password-file ~/.config/exakit/ice.secret --yes

# Iceberg REST catalog on MinIO
exakit connect lakehouse --name minio_lake --set catalog=iceberg-rest --set files=s3 \
  --set catalog_url=http://192.168.64.1:8181 --set warehouse=lake --set namespace=sales \
  --set region=us-east-1 --set access_key_id=minioadmin --set endpoint=http://192.168.64.1:9000 \
  --password-file ~/.config/exakit/ice.token --storage-secret-file ~/.config/exakit/minio.secret --yes

# AWS Glue (files are S3, no files question)
exakit connect lakehouse --name glue_lake --set catalog=glue --set region=eu-central-1 \
  --set database=sales_db --set access_key_id=AKIAIOSFODNN7EXAMPLE \
  --password-file ~/.config/exakit/glue.secret --yes

# No catalog: Parquet files in an S3 folder
exakit connect lakehouse --name orders_files --set catalog=none --set files=s3 \
  --set path=s3://sales-lake/orders/ --set region=eu-central-1 --set access_key_id=AKIAIOSFODNN7EXAMPLE \
  --password-file ~/.config/exakit/s3.secret --yes

exakit sql "SELECT * FROM VS_SALES_LAKE.ORDERS LIMIT 10"
```

### Without prompts: Windows PowerShell

```powershell
# Unity Catalog, files on Azure: two secrets
exakit connect lakehouse --name sales_lake --set catalog=unity --set files=azure `
  --set workspace_url=https://adb-1234567890123456.7.azuredatabricks.net --set namespace=main.sales `
  --set account_name=saleslake `
  --password-file "$HOME\.config\exakit\uc.token" --storage-secret-file "$HOME\.config\exakit\azkey.txt" --yes

# No catalog: Parquet files in an ADLS folder (the account comes from the path)
exakit connect lakehouse --name orders_files --set catalog=none --set files=azure `
  --set path=abfss://lake@saleslake.dfs.core.windows.net/orders/ `
  --password-file "$HOME\.config\exakit\azkey.txt" --yes

exakit sql "SELECT * FROM VS_SALES_LAKE.ORDERS LIMIT 10"
'SELECT "ORDER_ID" FROM VS_SALES_LAKE."ORDERS" LIMIT 10' | exakit sql
```

In PowerShell 5.1 an argument loses its inner double quotes: pipe a query with
quoted names, or use `exakit sql --file query.sql`. A SAS contains `&`: put it
in the secret file, never in `--url` or `--set`.

Add `--dry-run` to see the plan first. One namespace, schema, Glue database or
folder is one source: connect again with another `--name` for the next.

## After you connect

```bash
exakit source show sales_lake          # "Lakehouse · Unity Catalog · Azure ADLS Gen2"
exakit source check sales_lake
exakit source refresh sales_lake       # tables added at the source
exakit source reauth sales_lake --password-file ~/.config/exakit/uc.token \
  --storage-secret-file ~/.config/exakit/azkey.txt
exakit sql "SELECT EXAKIT_VS.LAKEHOUSE_VERSION()"
```

`exakit source reauth <name> --password-file F [--storage-secret-file F2]`
replaces the credential. The CONNECTION holds every secret of the source and
the kit never stores secrets, so a reauth gives all of them again:

| Combination | `reauth` needs |
|---|---|
| `iceberg-rest` or `unity` + `s3` or `azure` (two secrets) | `--password-file` and `--storage-secret-file`, even if only one changed |
| `vended`, `glue`, `none` (one secret) | `--password-file` only |

## Common problems

| Symptom | Fix |
|---|---|
| kind `input`: the combination is not valid | The remedy names the `files` values for that catalog. Glue takes S3 only; no catalog takes `s3` or `azure`. |
| Both a token and an OAuth client given | Pick `login=token` or `login=oauth`, not both. |
| A `gs://` path, or `abfs://` / `wasbs://`, refused | GCS is not supported; Azure needs `abfss://...dfs.core.windows.net/...`. For Unity tables on GCS use `exakit connect databricks`. |
| "NotAuthorizedException", "HTTP 401", "Invalid access token" | The catalog refused the token or client: make a new one, then `exakit source reauth <name> --password-file F` (add `--storage-secret-file F2` for a two-secret combination). |
| "Unity Catalog does not let engines outside Databricks read this schema's files" | Turn on External Data Access and grant `EXTERNAL USE SCHEMA`. A Default Storage schema never works: use `exakit connect databricks`. |
| "catalog-managed table, which this adapter version cannot read yet" | Read it with `exakit connect databricks`. |
| `PERMISSION_DENIED` (Unity) | Grant USE CATALOG, USE SCHEMA and SELECT. |
| "no such namespace that this credential can see" | Check the namespace and warehouse (Databricks Iceberg endpoint: warehouse = catalog, namespace = schema) and the grants. |
| "AccessDeniedException ... not authorized to perform: glue:GetTables" | The key may not read that database, or the name is wrong (AWS answers both the same). Check the name, else grant the action. |
| "The security token included in the request is invalid" | AWS does not know the key: make a new one, then `exakit source reauth <name> --password-file F`. |
| "x-amz-bucket-region", "incorrectly configured region" | The bucket is in another region: connect again with `--set region=<the bucket's region>`. |
| "AuthenticationFailed" (Azure) | A wrong key, an expired SAS, or a SAS without Read and List: make a new one, then `exakit source reauth <name>` with both secret files (with `catalog=none`, `--password-file` only). |
| Every bucket answers "NoSuchBucket" on a non-AWS store | Give the store's endpoint with `--set endpoint=`; the kit adds `path_style`. Leave it empty for Amazon S3. |
| A signed request refused for the clock | The database clock is off by more than 15 minutes (after the laptop slept): `exakit stop`, then `exakit start`. |
| "... is plain http to <host>, a public host" | Use `https`. `http` works only for this computer or a private network. |
| A table left out by name | ORC, Avro, Hudi, views and Iceberg tables with equality deletes are not read. |
| `norust` (exit 23) | The Rust language container is missing: run the connect again with `--yes`. |
