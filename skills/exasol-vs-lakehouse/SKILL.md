---
name: exasol-vs-lakehouse
description: Connect Iceberg, Delta or Parquet tables to local Exasol as a virtual schema with exakit connect lakehouse, read in place from their files by the Rust lakehouse engine with no warehouse compute. One connector, two choices - the catalog (Iceberg REST, Unity Catalog, AWS Glue, or no catalog for a Parquet folder) and the files (vended by the catalog, Amazon S3 or an S3-compatible store with an endpoint, Azure ADLS Gen2) - giving 9 valid combinations and 7 refused ones (no Google Cloud Storage). Covers the fields of each combination and where to find them, token versus OAuth client login, the two secrets (--password-file and --storage-secret-file), the adapter mapping (CATALOG_KIND, TO, NAMESPACE, the JSON keys), the Unity prerequisites (External Data Access, EXTERNAL USE SCHEMA, no Default Storage), the Glue IAM policy, when to use the databricks connector instead, unattended connect lines for bash and PowerShell, and the lakehouse failures. Connector id lakehouse; the old ids iceberg-rest and unity are removed (saved sources migrate). Tier GA. Triggers — "connect a lakehouse", "query Iceberg tables from Exasol", "read Delta tables from Exasol", "connect an AWS Glue catalog", "Athena tables from Exasol", "connect an Iceberg REST catalog", "Polaris or Lakekeeper catalog in Exasol", "read Unity Catalog tables without a warehouse", "EXTERNAL USE SCHEMA for exakit", "Iceberg on MinIO from Exasol", "Parquet folder on S3 or ADLS as a virtual schema", "Unity Catalog on Azure ADLS from Exasol", "OAuth client for an Iceberg catalog", "storage-secret-file", "exakit connect lakehouse", "exakit connect iceberg-rest", "exakit connect unity".
---

# Lakehouse (Iceberg / Delta) → local Exasol

Shared rules (credential handling, the lakehouse engine, the `--json` answer and
failure kinds, re-point, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is the lakehouse connector's own.

## 1. When to use it

Tables whose files sit in S3, an S3-compatible store or Azure ADLS Gen2, read
where they lie by exasol-labs/lakehouse-engine-rs inside the database. Nothing
runs at the source. One namespace, Unity schema, Glue database or folder is
one source. Tier GA.

The connector id is `lakehouse`. `iceberg-rest` and `unity` were separate
connectors and are removed, with no aliases: `exakit connect iceberg-rest` or
`exakit connect unity` no longer resolves, so use
`exakit connect lakehouse --set catalog=iceberg-rest` or `--set catalog=unity`.
A source saved under an old id is migrated in place to `lakehouse` the first
time it is read; `exakit source list/show/check/remove` keep working on it.

**Lakehouse or Databricks.** Both read a Unity Catalog schema.

- `databricks` (Profile C, `exasol-vs-databricks`): the SQL warehouse reads the
  files and sends rows over JDBC. Costs warehouse compute. Works for files on
  GCS, Default Storage schemas, catalog-managed tables, and needs no External
  Data Access.
- `lakehouse` (Profile D, this skill): Exasol reads the files. No Databricks
  compute, but the Unity prerequisites in section 5 must hold.

## 2. The two choices

`catalog` (who lists the tables) and `files` (how Exasol opens them):

| `catalog` | `vended` | `s3` | `azure` | GCS |
|---|---|---|---|---|
| `iceberg-rest` - Iceberg REST catalog | yes | yes | yes | no (adapter) |
| `unity` - Unity Catalog | yes | yes | yes | no (adapter) |
| `glue` - AWS Glue | no (Glue vends nothing) | yes, automatic | no (Glue is on S3) | no |
| `none` - No catalog, Parquet files in a folder | no (no catalog) | yes | yes | no (adapter) |

- 9 combinations work. With `catalog=glue` there is no files step: `files` is
  `s3`, opened with the Glue key. Do not ask the user for it.
- An invalid combination is `kind: input` (exit 2); the remedy names the valid
  `files` values for that catalog.
- GCS: the adapter (v0.57.3 and v0.58.1) has S3 and ADLS backends only and
  refuses `gs://`. For Unity tables on GCS, route to `exasol-vs-databricks`.
- Labels in panels and `source show`: "Lakehouse · <catalog label> · <files
  label>", e.g. "Lakehouse · Unity Catalog · Azure ADLS Gen2".

Ask the user which catalog first, then which files. Typical answers: Polaris,
Snowflake Open Catalog, Lakekeeper, Nessie, Gravitino or the Databricks Iceberg
endpoint are `iceberg-rest`; Databricks is `unity`; Athena, EMR or Glue jobs are
`glue`; "just Parquet files under a prefix" is `none`.

## 3. Fields

The first question, "Name (alias) for this connection", is `--name`: the tables
appear as `VS_<NAME>`. Then:

| Input | When | Required | Where to find it |
|---|---|---|---|
| `catalog` | always | yes | `iceberg-rest`, `unity`, `glue` or `none` |
| `files` | not for `glue` | yes | `vended`, `s3` or `azure` |
| `login` | `iceberg-rest`, `unity` | default `token` | `token` or `oauth` (never both) |
| `catalog_url` | `iceberg-rest` | yes | the catalog's REST base URL, path included; Databricks: `https://<workspace-host>/api/2.1/unity-catalog/iceberg-rest` |
| `warehouse` | `iceberg-rest` | yes | the warehouse the catalog knows (a name or `s3://...`); Databricks endpoint: the Unity catalog name |
| `namespace` | `iceberg-rest`, `unity` | yes | REST: the namespace (dotted when nested); Unity: `catalog.schema`, e.g. `main.sales` |
| `workspace_url` | `unity` | yes | the browser's address bar in the workspace, `https://` and host only |
| `database` | `glue` | yes | Glue > Data Catalog > Databases (no dot in the name) |
| `catalog_id` | `glue` | no | a Glue catalog in another account: its 12-digit account ID |
| `path` | `none` | yes | `s3://bucket/prefix/` or `abfss://container@account.dfs.core.windows.net/prefix/` |
| `client_id` | `login=oauth` | yes | the OAuth client (service principal) ID |
| `token_endpoint` | `login=oauth` | no | the token URL; Unity defaults to `/oidc/v1/token` |
| `scope` | `login=oauth` | no | e.g. `PRINCIPAL_ROLE:ALL` (Polaris); Unity defaults to `all-apis` |
| `region` | `glue`, `s3`; `vended` optional | yes for `glue` and `s3` | the bucket's region: S3 > the bucket > Properties, or `aws s3api get-bucket-location` (`null` is `us-east-1`); with `vended`, only when the files are on S3 (Unity's vended credentials carry no region) |
| `access_key_id` | `glue`, `s3` | yes with a catalog and `s3`; optional for `glue` and `none`+`s3` when the secret file is the JSON `aws iam create-access-key` prints | IAM > Users > the reader > Security credentials; another store: its own key |
| `endpoint` | `s3` | no | empty for Amazon S3; a non-AWS store's URL (section 4) |
| `account_name` | `azure` with a catalog | yes | Azure portal > Storage accounts; for `catalog=none` it comes from the `abfss://` path |
| `secret` | always | yes | the catalog token or client secret; for `glue` the AWS secret key; for `none` the storage secret - `--password-file` or `--password-stdin` only |
| `storage_secret` | a catalog plus `s3` or `azure` | yes | the S3 secret key, or the Azure account key or SAS - `--storage-secret-file` only |

A query string holding `sig=` and one of `sv=`, `se=` or `sp=` (any order, a
leading `?` dropped) is a SAS (`sas_token`); anything else is an account key.
Each secret file holds the value alone, not JSON - except for `glue` and
`none`+`s3`, where it may be the JSON `aws iam create-access-key` prints.

## 4. Adapter mapping and the S3 endpoint

| `catalog` | `CATALOG_KIND` | `TO` | `NAMESPACE` |
|---|---|---|---|
| `iceberg-rest` | not set (REST default; the literal `ICEBERG_REST` is refused) | `catalog_url` | `namespace` |
| `unity` | `UNITY_CATALOG` | `workspace_url` | `namespace` (`catalog.schema`) |
| `glue` | `GLUE` | `https://glue.<region>.amazonaws.com` | `database` |
| `none` | `DIRECT_STORAGE` | `path` | not set |

The CONNECTION password is JSON: `warehouse` (REST); `token`, or `client_id` +
`client_secret` with `oauth2_server_uri` and `scope` when given;
`use_vended_credentials: true` with `region` when given; `access_key`,
`secret_key`, `region`, with `endpoint` + `path_style: true` when an endpoint is
given; `account_name` with `account_key` or `sas_token`; for Glue
`access_key`, `secret_key`, `region` and `warehouse` = the catalog ID when
given. `ALLOW_HTTP=TRUE` is added when any URL is `http://`.

`endpoint` (S3 only; untested in the kit): MinIO `http://minio.local:9000`,
Ceph RGW, Cloudflare R2 `https://<account-id>.r2.cloudflarestorage.com`
(region `auto`), Wasabi `https://s3.<region>.wasabisys.com`, Backblaze B2
`https://s3.<region>.backblazeb2.com`, DigitalOcean Spaces, Linode, Scaleway,
Hetzner, IBM COS (HMAC keys), Oracle OCI (Customer Secret Keys), on-premises
appliances, and GCS S3 interoperability `https://storage.googleapis.com` (HMAC
keys; untested, a possible GCS workaround). Azure has no endpoint: the adapter
builds `<account>.dfs.core.windows.net` from the account name. The full table
is in `docs/virtual-schemas/lakehouse.md`.

## 5. Prepare the source (show, then run on a yes)

**Iceberg REST.** Read on the namespace in the catalog (list and load tables);
with storage keys, list and read on the files. Check URL, warehouse and token
with the token off the command line:

```bash
umask 077; printf 'Authorization: Bearer %s\n' "$(cat ~/.config/exakit/<name>.token)" > ~/.config/exakit/<name>.hdr
curl -sf -H @"$HOME/.config/exakit/<name>.hdr" "<catalog_url>/v1/config?warehouse=<warehouse>"
rm -f ~/.config/exakit/<name>.hdr
```

AWS Glue's Iceberg REST endpoint needs SigV4: use `catalog=glue`, not
`iceberg-rest`.

**Unity Catalog** (also for the Databricks Iceberg endpoint). All three must
hold, or Databricks refuses to hand out the files:

1. External Data Access is on for the metastore (`databricks metastores
   summary` shows `external_access_enabled: true`).
2. The schema is on external storage (`databricks schemas get <catalog>.<schema>`:
   an `s3://` or `abfss://` storage root), not Default Storage.
3. The token's user holds EXTERNAL USE SCHEMA, granted by the catalog owner:

```sql
GRANT USE CATALOG ON CATALOG <catalog> TO `<reader@example.com>`;
GRANT USE SCHEMA, EXTERNAL USE SCHEMA, SELECT ON SCHEMA <catalog>.<schema> TO `<reader@example.com>`;
```

A token, straight into a file (never print it):

```bash
umask 077; mkdir -p ~/.config/exakit
databricks tokens create --comment exakit-<name> --lifetime-seconds 2592000 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_value"])' > ~/.config/exakit/<name>.token
```

**AWS Glue.** A dedicated IAM user; the key signs Glue and S3:

```bash
cat > exakit-glue-read.json <<'JSON'
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": ["glue:GetDatabase", "glue:GetTables", "glue:GetTable", "glue:GetPartitions"],
   "Resource": ["arn:aws:glue:<region>:<account>:catalog",
                "arn:aws:glue:<region>:<account>:database/<database>",
                "arn:aws:glue:<region>:<account>:table/<database>/*"]},
  {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::<bucket>"},
  {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::<bucket>/<table-prefix>/*"}]}
JSON
aws iam create-user --user-name exakit-<name>-reader
aws iam put-user-policy --user-name exakit-<name>-reader --policy-name exakit-read \
  --policy-document file://exakit-glue-read.json
umask 077; mkdir -p ~/.config/exakit
aws iam create-access-key --user-name exakit-<name>-reader \
  --query AccessKey.SecretAccessKey --output text > ~/.config/exakit/<name>.secret   # never print it
aws iam list-access-keys --user-name exakit-<name>-reader --query "AccessKeyMetadata[].AccessKeyId" --output text
```

Lake Formation grants are not evaluated.

**Files on S3** (`s3`, `none` + `s3`): `s3:ListBucket` on the bucket and
`s3:GetObject` on the prefix. **Files on Azure**: the account key (Security +
networking > Access keys) or a SAS with Read and List. Service principals and
managed identities are not supported by the adapter.

**Network.** `https` by default; `http` only towards this computer or a private
network (macOS: `192.168.64.1`; Linux/WSL: `host.containers.internal` or
`host.docker.internal`; never `localhost`). A catalog, workspace, bucket or
storage account behind an allowlist must allow this computer's public IP
(`exakit connect` shows it).

## 6. TLS

No CA file. Catalogs and storage are reached over HTTPS and the engine checks
their certificates itself: this connector has no `tls` or `ca` input.

## 7. Connect

Two secrets at most. `--password-file` (or `--password-stdin`) carries the
catalog secret - for `glue` the AWS secret, for `none` the storage secret.
`--storage-secret-file` carries the storage secret when a catalog and `s3` or
`azure` are both used. Only one stdin exists, so the second secret is a file
(or a hidden prompt at a terminal). A pasted string (`--url`) fills only the
catalog and its address (`catalog_url`, `workspace_url`, Glue `region` and
`database`, or a folder `path`); a credential in it (`user:token@`, `?token=`,
a signature) is dropped with a warning and never used, so the secret files
are still needed. Never put a secret in `--url`.

```bash
exakit connect lakehouse --name sales_lake --set catalog=unity --set files=azure \
  --set workspace_url=https://adb-<id>.azuredatabricks.net --set namespace=main.sales \
  --set account_name=<account> --password-file ~/.config/exakit/<name>.token \
  --storage-secret-file ~/.config/exakit/<name>-az.key --dry-run
exakit connect lakehouse --name lake --set catalog=iceberg-rest --set files=vended \
  --set catalog_url=<catalog_url> --set warehouse=<warehouse> --set namespace=<namespace> \
  --password-file ~/.config/exakit/<name>.token --yes --json
exakit connect lakehouse --name lake --set catalog=iceberg-rest --set files=vended --set login=oauth \
  --set catalog_url=<catalog_url> --set warehouse=<warehouse> --set namespace=<namespace> \
  --set client_id=<client-id> --set scope=<scope> --password-file ~/.config/exakit/<name>.secret --yes --json
exakit connect lakehouse --name lake --set catalog=glue --set region=<region> --set database=<database> \
  --set access_key_id=<key-id> --password-file ~/.config/exakit/<name>.secret --yes --json
exakit connect lakehouse --name lake --set catalog=none --set files=s3 --set path=s3://<bucket>/<prefix>/ \
  --set region=<region> --set access_key_id=<key-id> --password-file ~/.config/exakit/<name>.secret --yes --json
```

Windows PowerShell 5.1, the same with `` ` `` line breaks and Windows paths:

```powershell
exakit connect lakehouse --name lake --set catalog=none --set files=azure `
  --set path=abfss://<container>@<account>.dfs.core.windows.net/<prefix>/ `
  --password-file "$HOME\.config\exakit\<name>-az.key" --yes --json
```

A SAS holds `&`: keep it in the file, never in `--set` or `--url`. Run each with
`--dry-run` first. The first lakehouse source installs the Rust language
container - at once at a terminal, with `--yes` in a script. Tell the user
first: a download and one database restart.

## 8. Verify and query

```bash
exakit source show lake        # names the combination
exakit source check lake
exakit source describe lake
exakit sql 'SELECT * FROM VS_LAKE.ORDERS LIMIT 10'
exakit sql 'SELECT EXAKIT_VS.LAKEHOUSE_VERSION()'
```

Names arrive upper case, so these need no quotes and run the same in Windows
PowerShell 5.1. A query with a quoted name loses its inner double quotes as a
PowerShell 5.1 argument: pipe it in or use a file.

```powershell
'SELECT "ORDER_ID" FROM VS_LAKE."ORDERS" LIMIT 10' | exakit sql
exakit sql --file q.sql
```

Deletes, refused formats and edge cases that differ from native Exasol are the
lakehouse engine's: see the shared skill. Table formats: Iceberg, Delta,
Parquet (`none`: Parquet only); ORC and Hudi are not read.

## 9. When it fails

| Message | Fix |
|---|---|
| `input` (exit 2) naming the valid `files` values | the combination is one of the 7 refused ones (section 2) |
| a token and an OAuth client both given | pick `login=token` or `login=oauth` |
| `gs://`, `abfs://` or `wasbs://` refused | GCS is not supported (use `exasol-vs-databricks` for Unity on GCS); Azure needs `abfss://...dfs.core.windows.net/...` |
| "request failed with HTTP 401" (any catalog: Polaris, Lakekeeper, open-source Unity, Databricks), "NotAuthorizedException", "Invalid access token", OAuth `unauthorized_client` (`auth`) | the catalog refused its login: a new token or client secret, then `exakit source reauth lake --password-file <file>` (plus `--storage-secret-file <file2>` for a two-secret combination); the remedy says "the catalog refused the ..." |
| "PermissionDenied ... caused by S3 SignatureDoesNotMatch" or "InvalidAccessKeyId" (`auth`) | the store refused the storage key, not the catalog: `exakit source reauth lake --password-file <token file> --storage-secret-file <file with the right S3 secret key>` (`catalog=none`: `--password-file` only); the remedy says "the store refused the ..." |
| "PermissionDenied ... caused by S3 AccessDenied", "request failed with HTTP 403" (`denied`) | the key or principal signs in but may not read: s3:ListBucket and s3:GetObject on the files, or the catalog's read grants (Polaris: a catalog role with TABLE_READ_DATA) |
| "Unity Catalog does not let engines outside Databricks read this schema's files" (`external`) | External Data Access and EXTERNAL USE SCHEMA (section 5); Default Storage never works: `exakit connect databricks` |
| "catalog-managed table, which this adapter version cannot read yet" (`managed`) | read it through `exakit connect databricks` |
| other `PERMISSION_DENIED` (`denied`) | USE CATALOG, USE SCHEMA, SELECT for the token's user |
| "no such namespace that this credential can see" | check `namespace` and `warehouse` (Databricks endpoint: catalog name, schema name) and grants |
| "namespace must be catalog.schema" | Unity: give both parts, e.g. `main.sales` |
| "Glue GetTables failed ... AccessDeniedException" (`denied`) | the key may not list that database, or it does not exist (AWS answers both the same): check the name, else grant the action |
| "The security token included in the request is invalid" (`auth`) | AWS does not know the key: a new one, then `exakit source reauth lake --password-file <file>` |
| "incorrectly configured region", "x-amz-bucket-region" (`region`) | connect again with `--set region=<the bucket's region>` |
| "the catalog vended S3 credentials but no region was given" ("s3..amazonaws.com" in the raw error) (`region`) | Unity or Iceberg REST with `vended` on S3 and no `region`: connect again with `--set region=<the bucket's region>`; the bucket is in the table's `s3://` storage URL (Unity: Catalog > External data > External locations), its region in S3 > the bucket > Properties or `aws s3api get-bucket-location --bucket <bucket>` (`null` is `us-east-1`) |
| "AuthenticationFailed" (Azure) | wrong key, expired SAS, or a SAS without Read and List: a new one, then `exakit source reauth lake` with both secret files (`catalog=none`: `--password-file` only) |
| "... is plain http to <host>, a public host" | use `https`; http only for this computer or a private network |
| `clock` (RequestTimeTooSkewed, "Signature expired", a 403 with the clock far off) | `exakit stop`, then `exakit start` |
| a table left out by name | ORC, Avro, Hudi, views and Iceberg tables with equality deletes are not read |
| `norust` (exit 23) | the Rust language container is missing: rerun with `--yes` after telling the user |

## 10. Keep it working

- A new secret: `exakit source reauth lake --password-file F [--storage-secret-file F2]`.
  The CONNECTION holds both secrets and the kit never stores secrets, so a
  two-secret combination (`iceberg-rest` or `unity` with `s3` or `azure`) needs
  both files, even when only one changed. One-secret combinations (`vended`,
  `glue`, `none`) need only `--password-file`.
- Another catalog URL, schema, database, folder or region: the same
  `exakit connect lakehouse --name lake ...` with the changed `--set` and the
  secret files (`--dry-run` first). `VS_LAKE` keeps its name.
- Tables added at the source: `exakit source refresh lake`.
- Stop: `exakit source disconnect lake` or `exakit source remove lake`
  (`--dry-run` first, then ask). The last lakehouse source removes the shared
  scripts.
