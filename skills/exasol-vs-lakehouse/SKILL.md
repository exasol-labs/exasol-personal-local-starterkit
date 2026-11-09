---
name: exasol-vs-lakehouse
description: Connect Iceberg tables in an AWS Glue database to local Exasol as a virtual schema with exakit connect lakehouse, read in place from S3 by the lakehouse engine. Covers the inputs to collect (region, Glue database, an access key), finding them with the AWS CLI (Glue databases, Iceberg tables, their S3 locations), a dedicated IAM user with only the Glue and S3 reads it needs, writing its access key straight to a file, the unattended connect line, and the lakehouse-specific failures. Connector id lakehouse, aliases glue, aws-glue and lakehouse-iceberg, tier GA. Triggers — "connect an AWS Glue catalog", "Athena tables from Exasol", "query Iceberg tables in Glue from Exasol", "Glue database as a virtual schema", "exakit connect lakehouse", "glue:GetTables AccessDeniedException from exakit".
---

# Iceberg on AWS Glue → local Exasol

Shared rules (credential handling, the lakehouse engine, exit codes, disconnect
versus remove) live in [exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md).
Load it too; this skill adds only what is the Glue route's own.

## 1. When to use it

The Iceberg tables of one AWS Glue database - written by Athena, Spark, EMR or
Glue jobs - read where they lie in S3, with no compute at the source. Plain
Hive Parquet tables of the database are read too. One Glue database is one
source. The other lakehouse routes: `exasol-vs-iceberg-rest`,
`exasol-vs-unity`. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `region` | yes | | aws-region | the region of the Glue catalog and its bucket, e.g. `eu-central-1` |
| `database` | yes | | glue-database | the Glue database (letters, digits, `_`, `-`; no dot) |
| `access_key_id` | no | | aws-key-id | `AKIA...`/`ASIA...`; leave it out when the credential file holds it |
| `secret` | yes | | secret | the secret access key, or the JSON `aws iam create-access-key` prints - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
aws glue get-databases --region <region> --query "DatabaseList[].Name" --output text
aws glue get-tables --region <region> --database-name <database> --output table \
  --query "TableList[].{name:Name,type:Parameters.table_type,location:StorageDescriptor.Location}"
aws s3api get-bucket-location --bucket <bucket-of-those-locations>   # null means us-east-1
aws sts get-caller-identity --query Account --output text            # the account id, for the policy
```

Iceberg tables carry `table_type` `ICEBERG` (compare without case). A Glue ARN
or endpoint fills the inputs: `--url 'arn:aws:glue:<region>:<account>:database/<database>'`
(region and database) or `--url 'https://glue.<region>.amazonaws.com'` (region).

## 4. Prepare a reader at the source (recommended policy; show, then run on a yes)

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
aws iam create-access-key --user-name exakit-<name>-reader > ~/.config/exakit/<name>-key.json   # never print it
```

Glue actions on a table need the catalog ARN as well as the database and table
ARNs. Lake Formation grants are not evaluated. The key signs both Glue and S3
requests; it goes into the CONNECTION's password as JSON.

## 5. Network

The engine reaches Glue and S3 at their public regional endpoints over HTTPS.
A bucket policy that limits `aws:SourceIp` must include this computer's public
IP (`exakit connect` shows it; fallback: the `python3` one-liner in the shared
skill).

## 6. Connect

```bash
exakit connect lakehouse --name lake --set region=<region> --set database=<database> --dry-run
exakit connect lakehouse --name lake --set region=<region> --set database=<database> \
  --password-file ~/.config/exakit/<name>-key.json --yes
```

The first lakehouse source installs the Rust language container after asking
(`--yes` consents: tell the user first - one database restart). The tables
appear as `VS_LAKE`.

## 7. Verify

```bash
exakit source check lake
exakit source describe lake
exakit sql "SELECT * FROM VS_LAKE.ORDERS LIMIT 10"   # names arrive upper case: no quotes
exakit sql "SELECT EXAKIT_VS.LAKEHOUSE_VERSION()"    # the engine build
```

## 8. When it fails

| Message | Fix |
|---|---|
| "Glue GetTables failed ... AccessDeniedException ... not authorized to perform: glue:GetTables" (`access-denied`) | the key may not list that database - or, under a policy scoped to named databases, it does not exist (AWS answers both the same way): check the name, else grant what the message names, then `exakit source check lake` |
| "UnrecognizedClientException: The security token included in the request is invalid" | AWS does not know the key (deleted, or a typo): a new key, then `exakit source reauth lake --password-file <new.json>` |
| a refusal that the kit files as the clock | signed requests allow 15 minutes: `exakit stop`, then `exakit start` |
| "incorrectly configured region", "x-amz-bucket-region" | the bucket is in another region: connect again with `--set region=<the bucket's region>` |
| exit 2 for the database | a dotted name: the engine refuses one |
| a table left out by name | ORC, Avro and Delta tables, views and tables with partition projection are not read; an Iceberg table with equality deletes is refused |
| exit 23 | the Rust language container is missing: rerun with `--yes` after telling the user |

## 9. Keep it working

- A new key: `exakit source reauth lake --password-file <new.json>`
  (temporary credentials expire; give new ones the same way).
- Tables added in Glue: `exakit source refresh lake`.
- Stop: `exakit source disconnect lake` or `exakit source remove lake`
  (`--dry-run` first, then ask) - the last lakehouse source of any route
  removes the shared scripts. See the shared skill.
