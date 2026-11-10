# Iceberg on AWS Glue (lakehouse)

The Iceberg tables (and plain Hive Parquet tables) of one AWS Glue database,
read straight from S3 by an engine inside your Exasol database. Nothing runs
on Athena or a warehouse.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-lakehouse` knows this connector.
>
> **You still need, on your computer:** the AWS CLI (`aws configure`) or the
> AWS Console, as someone who may create an IAM user and its access key.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `lake` |
| AWS region of the Glue catalog and its bucket | yes | `eu-central-1` |
| Glue database (one database is one virtual schema) | yes | `sales_db` |
| Access key ID | no (if the credential file holds it) | `AKIA...` |
| Secret access key | yes | (hidden, or a file) |

## Where to find each value

### 1. Region and database

- **Console:** AWS Glue → Data Catalog → Databases (the region is top right).
  Open the database → Tables: Iceberg tables show Table format **Apache
  Iceberg**; each table's Location is its S3 path.
- **CLI:**
  ```bash
  aws glue get-databases --region eu-central-1 --query "DatabaseList[].Name" --output text
  aws glue get-tables --region eu-central-1 --database-name sales_db --output table \
    --query "TableList[].{name:Name,type:Parameters.table_type,location:StorageDescriptor.Location}"
  aws sts get-caller-identity --query Account --output text   # your account id, for the policy
  ```

The database name may not contain a dot.

### 2. A read-only access key

The key signs both Glue and S3 requests. It needs `glue:GetDatabase`,
`glue:GetTables`, `glue:GetTable`, `glue:GetPartitions`, plus `s3:ListBucket`
and `s3:GetObject` where the tables live. Save this as `exakit-glue-read.json`:

```json
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": ["glue:GetDatabase", "glue:GetTables", "glue:GetTable", "glue:GetPartitions"],
   "Resource": ["arn:aws:glue:eu-central-1:<account-id>:catalog",
                "arn:aws:glue:eu-central-1:<account-id>:database/sales_db",
                "arn:aws:glue:eu-central-1:<account-id>:table/sales_db/*"]},
  {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::my-lake-bucket"},
  {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::my-lake-bucket/sales_db/*"}]}
```

- **Console:** IAM → Users → Create user (`exakit-lake-reader`) → Attach
  policies directly → Create policy → JSON (above). Then the user → Security
  credentials → Create access key → Third-party service → download the `.csv`.
- **CLI:**
  ```bash
  aws iam create-user --user-name exakit-lake-reader
  aws iam put-user-policy --user-name exakit-lake-reader --policy-name exakit-read \
    --policy-document file://exakit-glue-read.json
  umask 077; mkdir -p ~/.config/exakit
  aws iam create-access-key --user-name exakit-lake-reader > ~/.config/exakit/lake-key.json
  ```

From the console `.csv`, put only the secret in a file and give the key ID
with `--set access_key_id=`. Lake Formation grants are not evaluated.

### 3. Network

Nothing to open by default: Glue and S3 are reached at their public regional
endpoints. A bucket policy that limits `aws:SourceIp` must include your public
IP (`curl https://checkip.amazonaws.com`).

## Connect

```bash
exakit connect lakehouse
```

The kit asks for a connection string (hidden; press Enter on an empty line to
type the fields instead), then each field above. It shows a plan and asks
once. The first lakehouse source installs the Rust language container (one
restart). Your tables appear as `VS_LAKE`.

Without prompts:

```bash
exakit connect lakehouse --name lake --set region=eu-central-1 --set database=sales_db \
  --password-file ~/.config/exakit/lake-key.json --yes
exakit sql "SELECT * FROM VS_LAKE.ORDERS LIMIT 10"
```

Add `--dry-run` to see the plan first. One Glue database is one source:
connect again with another `--name` for the next.

**Windows:** paste the ARN at the prompt rather than `--url`. For a quoted name
in `exakit sql`, pipe the statement in (`'SELECT "x" FROM VS_LAKE.T' | exakit sql`)
or use `exakit sql --file query.sql`.

## Connection string you can paste

```text
arn:aws:glue:eu-central-1:123456789012:database/sales_db
https://glue.eu-central-1.amazonaws.com
```

The ARN fills region and database; the endpoint fills the region only.

## Common problems

| Symptom | Fix |
|---|---|
| "AccessDeniedException ... not authorized to perform: glue:GetTables" | The key may not read that database, or the name is wrong (AWS answers both the same): check the name, else grant the action, then `exakit source check lake`. |
| "UnrecognizedClientException: The security token included in the request is invalid" | AWS does not know the key: make a new one, then `exakit source reauth lake --password-file <new key.json>`. |
| "x-amz-bucket-region", "incorrectly configured region" | The bucket is in another region: connect again with `--set region=<the bucket's region>`. |
| A signed request refused for the clock | The database clock is off by more than 15 minutes: `exakit stop`, then `exakit start`. |
| A table left out by name | ORC, Avro and Delta tables, views and Iceberg tables with equality deletes are not read. |

Glue's own Iceberg REST endpoint needs SigV4 signing, which the
[Iceberg REST connector](iceberg-rest.md) does not support: use this connector
for Glue.
