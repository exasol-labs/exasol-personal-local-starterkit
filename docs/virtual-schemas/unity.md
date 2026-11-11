# Unity Catalog (read from storage)

One Unity Catalog schema on Databricks (AWS), read straight from its S3
storage by an engine inside your Exasol database. Nothing runs on Databricks
compute. To query through a SQL warehouse instead, see [Databricks](databricks.md).

> **Easiest: let your AI agent do it.** The skill `exasol-vs-unity` knows this connector.
>
> **You still need, on your computer:** the Databricks workspace in a browser
> or the Databricks CLI (`databricks auth login --host https://<workspace-host>`),
> plus the AWS CLI (`aws configure`) or AWS Console to look up the bucket's region.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `uc_sales` |
| Workspace URL | yes | `https://dbc-1234abcd-5678.cloud.databricks.com` |
| Schema as catalog.schema | yes | `main.sales` |
| AWS region (data bucket) | yes | `us-east-2` |
| Personal access token | yes | (hidden) |

## Where to find each value

### 1. Workspace URL and schema

- **Workspace URL:** your browser's address bar, `https://` and the host only.
- **Schema:** Catalog → `<catalog>` → `<schema>`; give it as `catalog.schema`.
  ```bash
  databricks catalogs list
  databricks schemas list <catalog>
  ```

### 2. External Data Access and grants

Three things must be true, or Databricks refuses to hand out the files:

1. **External Data Access is on for the metastore.** A metastore admin:
   Catalog → gear icon → Metastore → External data access → Enable. Check:
   `databricks metastores summary` shows `external_access_enabled: true`.
2. **The schema sits on your own cloud storage, not Default Storage.** Catalog
   → `<schema>` → Details → Storage location must be an `s3://...` path.
   A schema on Databricks Default Storage cannot be read from outside: use
   [Databricks](databricks.md) for it, or create a schema with
   `MANAGED LOCATION 's3://...'` on an external location you own.
3. **The token's user has the grants**, including `EXTERNAL USE SCHEMA`, which
   only the catalog's owner can grant and which is never implied:
   ```sql
   GRANT USE CATALOG ON CATALOG main TO `reader@example.com`;
   GRANT USE SCHEMA, EXTERNAL USE SCHEMA, SELECT ON SCHEMA main.sales TO `reader@example.com`;
   ```

Databricks catalog-managed tables cannot be read by this adapter version:
read those through [Databricks](databricks.md).

### 3. Region of the bucket

Unity's temporary storage credentials carry no region, so the kit asks for it.
Take the bucket from the schema's Storage location, then:

- **Console:** S3 → Buckets → the AWS Region column.
- **CLI:** `aws s3api get-bucket-location --bucket <bucket>` (`null` means `us-east-1`).

### 4. The personal access token

Signed in as the reader: user menu (top right) → Settings → Developer → Access
tokens → Manage → Generate new token. Save it in an owner-only file such as
`~/.config/exakit/uc_sales.pat`.

```bash
umask 077; mkdir -p ~/.config/exakit
databricks tokens create --comment exakit-uc_sales --lifetime-seconds 2592000 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["token_value"])' > ~/.config/exakit/uc_sales.pat
```

### 5. Network

Nothing to open, unless the workspace uses IP access lists; then a workspace
admin adds your public IP (`curl https://checkip.amazonaws.com`), as in the
[Databricks guide](databricks.md#5-network).

## Connect

```bash
exakit connect unity
```

The kit asks for the workspace URL (hidden; press Enter on an empty line to
type the fields instead), then each field above. It shows a plan and asks
once. The first lakehouse source installs the Rust language container (one
restart). Your tables appear as `VS_UC_SALES`.

Without prompts:

```bash
exakit connect unity --name uc_sales --set workspace_url=https://dbc-1234abcd-5678.cloud.databricks.com \
  --set namespace=main.sales --set region=us-east-2 --password-file ~/.config/exakit/uc_sales.pat --yes
exakit sql "SELECT * FROM VS_UC_SALES.ORDERS LIMIT 10"
```

Add `--dry-run` to see the plan first. One schema is one source: connect again
with another `--name` for the next.

**Windows:** paste the workspace URL at the prompt rather than `--url`. For a
quoted name in `exakit sql`, pipe the statement in
(`'SELECT "x" FROM VS_UC_SALES.T' | exakit sql`) or use `exakit sql --file query.sql`.

## Connection string you can paste

```text
https://dbc-1234abcd-5678.cloud.databricks.com
```

It fills the workspace URL only; type the schema, region and token.

## Common problems

| Symptom | Fix |
|---|---|
| "Unity Catalog does not let engines outside Databricks read this schema's files" | Turn on External Data Access and grant `EXTERNAL USE SCHEMA` (step 2). On Default Storage, use `exakit connect databricks`. |
| `PERMISSION_DENIED` | Grant USE CATALOG, USE SCHEMA and SELECT (step 2). |
| "catalog-managed table, which this adapter version cannot read yet" | Read it with `exakit connect databricks`. |
| "x-amz-bucket-region", "incorrectly configured region" | Connect again with `--set region=<the bucket's region>`. |
| "Invalid access token", "HTTP 401" | Make a new token (step 4), then `exakit source reauth uc_sales`. |
