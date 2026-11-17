# Lakehouse (Iceberg / Delta) · Federation guide

> **Federation** lets your local Exasol query Iceberg, Delta and Parquet tables
> in place, read straight from their files by an engine inside your Exasol
> database. Nothing runs on a warehouse, Athena or Databricks compute.
> `exakit connect lakehouse` makes them a virtual schema, `VS_<NAME>`, that you
> query with SQL. One connector covers every catalog the engine knows: you pick
> where the table list is kept (the **catalog**), then how Exasol opens the
> files (the **files**).

> **Easiest: let your AI agent do it.** The kit installs the skill
> `exasol-vs-lakehouse` for your AI client; it knows this connector. A ready-to-use prompt is in
> [Ask your AI agent](#ask-your-ai-agent).
>
> **You still need, on your computer:** the console or CLI of your catalog and
> your storage (AWS CLI, Databricks CLI or workspace, Azure portal or `az`), to
> look up the values and make a read-only login.

## At a glance

Pick a catalog (row) and the files (column). ✓ works, ✗ is refused.

| Catalog \ Files | `vended` (the catalog gives access) | `s3` (Amazon S3 / S3-compatible) | `azure` (Azure ADLS Gen2) |
|---|---|---|---|
| `iceberg-rest` (Iceberg REST catalog) | ✓ | ✓ | ✓ |
| `unity` (Unity Catalog) | ✓ | ✓ | ✓ |
| `glue` (AWS Glue) | ✗ | ✓ automatic | ✗ |
| `none` (Parquet files in a folder) | ✗ | ✓ | ✓ |

- That is 9 combinations that work.
- Google Cloud Storage is refused for every catalog (4 more), which makes 7
  refused combinations in all. [Why](#why-7-combinations-are-refused).
- A combination shows as "Lakehouse · <catalog label> · <files label>" in
  panels and in `exakit source show`, for example "Lakehouse · Unity Catalog ·
  Azure ADLS Gen2".

The connector id is `lakehouse`. The old ids `iceberg-rest` and `unity` are
gone and have no aliases. A source saved with one of them is moved to
`lakehouse` (with its catalog and files) the first time the kit reads it, so
`exakit source list`, `show`, `check` and `remove` keep working.

## Ask your AI agent

Copy this prompt, fill in the `<...>` parts, and give it to your agent:

```text
Connect the lakehouse tables in <namespace or catalog.schema> to my local Exasol
with exakit. Use the exasol-vs-lakehouse skill. Catalog: <iceberg-rest, unity,
glue or none>, at <catalog URL, workspace URL or Glue region>. Files: <vended,
s3 or azure>. Set up a read-only login for the catalog and the files, and
write each secret to a file, never into the chat.
```

Prefer to do it by hand? Follow the steps below.

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

- Use [Databricks](databricks.md) for files on GCS, a schema on Default
  Storage, catalog-managed tables, or when you cannot get the Unity grants.
- Use Lakehouse when you want no Databricks compute, or the catalog is not
  Databricks.

## Catalogs and files

The **catalog** answers "where are my tables?":

| `catalog` | Label | Typical use |
|---|---|---|
| `iceberg-rest` | Iceberg REST catalog | Polaris, Snowflake Open Catalog, Lakekeeper, Nessie, Gravitino, the Databricks Iceberg endpoint |
| `unity` | Unity Catalog | Databricks on AWS, Azure or GCP |
| `glue` | AWS Glue | tables written by Athena, EMR, Spark or Glue jobs |
| `none` | No catalog - Parquet files in a folder | Parquet files under one prefix, no catalog at all |

The **files** say how Exasol opens the data files:

| `files` | Label | What Exasol uses |
|---|---|---|
| `vended` | Let the catalog give access | the catalog hands out short-lived storage access per table |
| `s3` | Amazon S3 / S3-compatible | your S3 access key, plus an endpoint for a non-AWS store |
| `azure` | Azure ADLS Gen2 | your storage account key or a SAS |
| (none) | Google Cloud Storage - not supported yet | not shown in the menu, cannot be picked |

### Why 7 combinations are refused

- **Any catalog + Google Cloud Storage (4).** The engine has two storage
  backends, S3 and ADLS, and refuses `gs://` paths. For Unity tables on GCS,
  use the [Databricks](databricks.md) connector.
- **Glue + vended.** Glue does not hand out file access.
- **Glue + Azure.** Glue tables live on S3. With `catalog=glue` there is no
  files question: the files are S3, opened with the same AWS key.
- **No catalog + vended.** There is no catalog to hand out access.

A combination that is not valid stops the connect with kind `input`. The remedy
names the `files` values that work for that catalog.

## What `exakit connect` asks for

`*` marks a field the combination requires. A hidden field is typed without
echo. The `--set` key is in brackets.

### Required

| Field | Example | Where it comes from |
|---|---|---|
| Name (alias) for this connection (`--name`) | `sales_lake` | You choose it. `sales_lake` gives the schema `VS_SALES_LAKE`. |
| `iceberg-rest`: Catalog URL * (`catalog_url`) | `https://polaris.example.com/api/catalog` | The catalog's console or docs ([Iceberg REST](#iceberg-rest-catalog)). |
| `iceberg-rest`: Warehouse (catalog name) * (`warehouse`) | `analytics` | The catalog's console. |
| `iceberg-rest`: Namespace * (`namespace`) | `sales` | The catalog's console. |
| `unity`: Workspace URL * (`workspace_url`) | `https://dbc-1234abcd-5678.cloud.databricks.com` | Your browser's address bar ([Unity](#unity-catalog)). |
| `unity`: Catalog.schema * (`namespace`) | `main.sales` | Catalog Explorer ([Unity](#unity-catalog)). |
| `glue`: AWS region * (`region`) | `eu-central-1` | AWS Glue → Data Catalog → Databases ([Glue](#aws-glue)). |
| `glue`: Glue database * (`database`) | `sales_db` | The same page ([Glue](#aws-glue)). |
| `glue`: Secret access key (hidden) * (`secret`, `--password-file`) | | The read-only key ([Glue](#aws-glue)). |
| `none`: Folder path * (`path`) | `s3://sales-lake/orders/` or `abfss://lake@saleslake.dfs.core.windows.net/orders/` | The folder of Parquet files. |
| `login=token`: Catalog token (hidden) * (`secret`, `--password-file`); for Unity "Databricks token" | | The catalog's token page ([Unity](#unity-catalog): step 6). |
| `login=oauth`: Client ID * (`client_id`) and Client secret (hidden) * (`secret`, `--password-file`) | `exakit-reader` | The catalog's OAuth client. |
| `files=s3`: AWS region * (`region`) | `eu-central-1` | S3 → Buckets ([Files on S3](#files-on-s3)). |
| `files=s3` with a catalog: Access key ID * (`access_key_id`) | `AKIA...` | Your IAM key ([Files on S3](#files-on-s3)). |
| `files=s3`: Secret access key (hidden) * (`storage_secret`, `--storage-secret-file`; with `catalog=none`, `--password-file`) | | Your IAM key ([Files on S3](#files-on-s3)). |
| `files=azure`: Azure storage account * (`account_name`) | `saleslake` | Azure portal → Storage accounts ([Files on Azure](#files-on-azure-adls-gen2)). |
| `files=azure`: Account key or SAS (hidden) * (`storage_secret`, `--storage-secret-file`; with `catalog=none`, `--password-file`) | | The account's Access keys, or a SAS ([Files on Azure](#files-on-azure-adls-gen2)). |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| `glue`: Access key ID (`access_key_id`) | read from the secret file, when it is the JSON `aws iam create-access-key` prints | `AKIA...` |
| `glue`: Glue catalog ID (`catalog_id`) | this account's catalog | `123456789012` |
| `login=oauth`: Token endpoint (`token_endpoint`) | Unity: `/oidc/v1/token` | `https://polaris.example.com/api/catalog/v1/oauth/tokens` |
| `login=oauth`: Scope (`scope`) | none | `PRINCIPAL_ROLE:ALL` |
| `files=vended`: AWS region (`region`) | none: the catalog's own | `us-east-2` |
| `files=s3`: Endpoint (`endpoint`) | Amazon S3 | an S3-compatible store's URL |
| `catalog=none`, `files=s3`: Access key ID (`access_key_id`) | read from the secret file, when it is the AWS credential JSON | `AKIA...` |

### Catalog login (`iceberg-rest` and `unity` only)

| `login` | Fields |
|---|---|
| `token` (default) | Catalog token (hidden) * (`secret`, `--password-file`). For Unity the label is "Databricks token". |
| `oauth` | Client ID * (`client_id`), Client secret (hidden) * (`secret`, `--password-file`), Token endpoint (`token_endpoint`, optional), Scope (`scope`, optional) |

- Pick one. A token and an OAuth client together are refused.
- Glue signs its requests with the AWS key, and `none` has no catalog, so
  neither asks for a login.

### Notes on the files fields

- **Region with vended files.** Leave it empty on Azure. On S3, give the
  bucket's region when the catalog does not send one: Unity's vended
  credentials carry no region. Without it, the connect fails with kind
  `region` and names the bucket.
- **Account key or SAS.** A query string (a leading `?` is dropped) that holds
  `sig=` and at least one of `sv=`, `se=` or `sp=`, in any order, is a SAS.
  Anything else is taken as the account key.
- **No catalog on Azure.** The storage account comes from the `abfss://` path,
  so it is not asked.

## Two secrets

A connection can carry two secrets:

- the **catalog secret**: a token or an OAuth client secret;
- the **storage secret**: an S3 secret key, or an Azure key or SAS.

Neither ever goes on the command line.

| Combination | `secret`: `--password-file F` or `--password-stdin` | `storage_secret`: `--storage-secret-file F` |
|---|---|---|
| `iceberg-rest` or `unity` + `vended` | the catalog secret | not used |
| `iceberg-rest` or `unity` + `s3` or `azure` | the catalog secret | the storage secret |
| `glue` | the AWS secret access key | not used |
| `none` + `s3` or `azure` | the storage secret | not used |

There is only one stdin, so the second secret comes from a file, or from a
hidden prompt at a terminal. Each file holds the secret alone, not JSON, and
should be readable by you only.

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

## Connection string you can paste

```text
https://polaris.example.com/api/catalog
https://dbc-1234abcd-5678.cloud.databricks.com/api/2.1/unity-catalog/iceberg-rest
https://dbc-1234abcd-5678.cloud.databricks.com
arn:aws:glue:eu-central-1:123456789012:database/sales_db
https://glue.eu-central-1.amazonaws.com
s3://my-lake-bucket/sales/orders/
abfss://lake@mystorageacct.dfs.core.windows.net/sales/orders/
```

| String | Catalog | Fills |
|---|---|---|
| `https://<catalog-host>[:port][/path]` | Iceberg REST | `catalog=iceberg-rest` and `catalog_url` |
| `https://<workspace-host>/api/2.1/unity-catalog/iceberg-rest` | Iceberg REST (the Databricks Iceberg endpoint) | `catalog=iceberg-rest` and `catalog_url` |
| `https://<workspace-host>` (`.databricks.com`, `.azuredatabricks.net`) | Unity Catalog | `catalog=unity` and `workspace_url` |
| `arn:aws:glue:<region>:<account-id>:database/<name>` | AWS Glue | `catalog=glue`, `region` and `database` |
| `https://glue.<region>.amazonaws.com` | AWS Glue | `catalog=glue` and `region` |
| `s3://<bucket>/<prefix>/` | No catalog, files on S3 | `catalog=none` and `path` |
| `abfss://<container>@<account>.dfs.core.windows.net/<prefix>/` | No catalog, files on ADLS Gen2 | `catalog=none` and `path` |

- The string (`--url`, or the first question of the form) fills the catalog
  and its address, never a secret.
- A credential inside the string is taken out and not used, and a warning says
  so: a `user:token@`, a `?token=` or any other query string, a presigned or
  SAS signature. The secret is still asked at a hidden prompt, or comes from
  `--password-file` (or `--password-stdin`); the storage secret from
  `--storage-secret-file`. See [Two secrets](#two-secrets).
- The string is optional: press Enter alone at the prompt and
  `exakit connect` asks for the fields one by one.

**Where to copy it from.** You do not build most of them:

- **Iceberg REST catalog** (Polaris, Snowflake Open Catalog, Lakekeeper,
  Nessie, Gravitino): the catalog's console or docs name its REST base URL.
  Copy it with its path.
- **Databricks Iceberg endpoint:** your workspace host plus
  `/api/2.1/unity-catalog/iceberg-rest`.
- **Unity Catalog:** your browser's address bar when the workspace is open,
  `https://` and the host only.
- **AWS Glue:** no console page shows the ARN whole. Write
  `arn:aws:glue:<region>:<account-id>:database/<database>` from the region, the
  12-digit account ID (the account menu, top right of the AWS console, or
  `aws sts get-caller-identity`) and the database name (AWS Glue → Data Catalog
  → Databases).
- **A Parquet folder on S3:** S3 → Buckets → `<bucket>` → select the folder →
  Copy S3 URI.
- **A Parquet folder on ADLS Gen2:** write
  `abfss://<container>@<account>.dfs.core.windows.net/<folder>/` from the
  storage account and container names (Azure portal → Storage accounts →
  `<account>` → Containers).

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
5. **Grants** for the token's user, from the catalog's owner. Only the owner
   may grant `EXTERNAL USE SCHEMA`, and it is never implied:

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
  the table prefix. For another store, its own access key and the Endpoint
  ([S3-compatible stores](#s3-compatible-stores-the-endpoint-field)).

### Files on Azure ADLS Gen2

- **Storage account:** Azure portal → Storage accounts. The account needs a
  hierarchical namespace (ADLS Gen2).
- **Account key:** the account → Security + networking → Access keys.
- **Or a SAS:** the account → Shared access signature, with Read and List; or
  a container SAS with Read and List. Use the token itself (`sv=...&sig=...`),
  not the full URL.
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

1. Pick **Lakehouse (Iceberg / Delta)** in the Federation picker, then its
   catalog and its files in the tree under it.
2. For Iceberg REST and Unity, choose the catalog login (Token or OAuth
   client) with the arrow keys.
3. Answer only the fields of that combination. The kit shows a plan and
   connects.
4. The first lakehouse source also runs **Enabling Federation**: it installs
   the Rust language container (a download and one database restart).

**Windows:** put every secret in a file, never in `--url` or `--set` (a SAS
contains `&`), and pipe a query with quoted names into `exakit sql`.

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
```

- Add `--dry-run` to see the plan first.
- One namespace, schema, Glue database or folder is one source: connect again
  with another `--name` for the next.

## Query

Names arrive in upper case (`ORDERS`, `ORDER_ID`), so no quotes are needed.

```bash
exakit sql "SELECT * FROM VS_SALES_LAKE.ORDERS LIMIT 10"
exakit sql "SELECT EXAKIT_VS.LAKEHOUSE_VERSION()"
```

```powershell
exakit sql "SELECT * FROM VS_SALES_LAKE.ORDERS LIMIT 10"
'SELECT "ORDER_ID" FROM VS_SALES_LAKE."ORDERS" LIMIT 10' | exakit sql
```

In PowerShell 5.1 an argument loses its inner double quotes: pipe a query with
quoted names, or use `exakit sql --file query.sql`.

## After you connect

```bash
exakit source show sales_lake          # "Lakehouse · Unity Catalog · Azure ADLS Gen2"
exakit source check sales_lake
exakit source refresh sales_lake       # tables added at the source
exakit source reauth sales_lake --password-file ~/.config/exakit/uc.token \
  --storage-secret-file ~/.config/exakit/azkey.txt
```

`exakit source reauth <name> --password-file F [--storage-secret-file F2]`
replaces the credential. The CONNECTION holds every secret of the source and
the kit never stores secrets, so a reauth gives all of them again:

| Combination | `reauth` needs |
|---|---|
| `iceberg-rest` or `unity` + `s3` or `azure` (two secrets) | `--password-file` and `--storage-secret-file`, even if only one changed |
| `vended`, `glue`, `none` (one secret) | `--password-file` only |

## Troubleshooting

| Error you see | Why | Fix |
|---|---|---|
| kind `input`: the combination is not valid | That catalog does not take those files. | The remedy names the `files` values for that catalog. Glue takes S3 only; no catalog takes `s3` or `azure`. |
| Both a token and an OAuth client given | Only one catalog login is allowed. | Pick `login=token` or `login=oauth`, not both. |
| A `gs://` path, or `abfs://` / `wasbs://`, refused | GCS is not supported; Azure needs ADLS Gen2 over `abfss://`. | Use `abfss://...dfs.core.windows.net/...`. For Unity tables on GCS use `exakit connect databricks`. |
| kind `auth`: "request failed with HTTP 401" (Polaris, Lakekeeper, open-source Unity Catalog, Databricks), "NotAuthorizedException", "Invalid access token", OAuth `unauthorized_client` | The catalog refused the token or client. The remedy starts "the catalog refused the ...". | Make a new one, then `exakit source reauth <name> --password-file F` (add `--storage-secret-file F2` for a two-secret combination). |
| kind `auth`: "PermissionDenied (persistent) at read - caused by S3 SignatureDoesNotMatch" or "InvalidAccessKeyId" | The store refused the S3 key, not the catalog. The remedy starts "the store refused the ...". | `exakit source reauth <name> --password-file F --storage-secret-file F2`, F2 holding the right secret access key (`catalog=none`: `--password-file` only). |
| kind `denied`: "caused by S3 AccessDenied", or "request failed with HTTP 403" from the catalog | The key or principal signs in but may not read. | Grant `s3:ListBucket` and `s3:GetObject` on the files, or the catalog's read grants. |
| "Unity Catalog does not let engines outside Databricks read this schema's files" | External Data Access is off, or `EXTERNAL USE SCHEMA` is missing. | Turn on External Data Access and grant `EXTERNAL USE SCHEMA`. A Default Storage schema never works: use `exakit connect databricks`. |
| "catalog-managed table, which this adapter version cannot read yet" | The adapter cannot read catalog-managed tables. | Read it with `exakit connect databricks`. |
| `PERMISSION_DENIED` (Unity) | The grants are missing. | Grant USE CATALOG, USE SCHEMA and SELECT. |
| "no such namespace that this credential can see" | Wrong namespace or warehouse, or missing grants. | Check the namespace and warehouse (Databricks Iceberg endpoint: warehouse = catalog, namespace = schema) and the grants. |
| "AccessDeniedException ... not authorized to perform: glue:GetTables" | The key may not read that database, or the name is wrong (AWS answers both the same). | Check the name, else grant the action. |
| "The security token included in the request is invalid" | AWS does not know the key. | Make a new one, then `exakit source reauth <name> --password-file F`. |
| "x-amz-bucket-region", "incorrectly configured region" | The bucket is in another region. | Connect again with `--set region=<the bucket's region>`. |
| "the catalog vended S3 credentials but no region was given" (kind `region`; the raw error names "s3..amazonaws.com") | Unity or Iceberg REST with `files=vended` on S3 and no `region`. | Connect again with `--set region=<the bucket's region>`. The bucket is in the table's `s3://` storage URL (for Unity: Catalog > External data > External locations); its region is in the AWS console under S3 > the bucket > Properties, or `aws s3api get-bucket-location --bucket <bucket>` (`null` means `us-east-1`). |
| "AuthenticationFailed" (Azure) | A wrong key, an expired SAS, or a SAS without Read and List. | Make a new one, then `exakit source reauth <name>` with both secret files (with `catalog=none`, `--password-file` only). |
| Every bucket answers "NoSuchBucket" on a non-AWS store | The endpoint is missing. | Give the store's endpoint with `--set endpoint=`; the kit adds `path_style`. Leave it empty for Amazon S3. |
| A signed request refused for the clock | The database clock is off by more than 15 minutes (after the laptop slept). | `exakit stop`, then `exakit start`. |
| "... is plain http to <host>, a public host" | `http` works only for this computer or a private network. | Use `https`. |
| A table left out by name | ORC, Avro, Hudi, views and Iceberg tables with equality deletes are not read. | Read those tables another way. |
| `norust` (exit 23) | The Rust language container is missing. | Run the connect again with `--yes`. |

## Reference

### What the adapter receives

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

### S3-compatible stores: the Endpoint field

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
