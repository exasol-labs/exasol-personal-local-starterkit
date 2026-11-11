---
name: exasol-vs-lakehouse
description: Connect Iceberg tables in an AWS Glue database to local Exasol as a virtual schema with exakit connect lakehouse, read in place from S3 by the lakehouse engine. Covers the inputs to collect (region, Glue database, an access key) and where each is in the AWS console, the Glue ARN and endpoint forms, a dedicated IAM user with only the Glue and S3 reads it needs, writing its access key straight to a file, the unattended connect line, example queries on macOS, Linux and Windows, the database clock that breaks signed requests after a laptop sleeps, and the Glue-specific failures. Connector id lakehouse, aliases glue, aws-glue and lakehouse-iceberg, tier GA. Triggers — "connect an AWS Glue catalog", "Athena tables from Exasol", "query Iceberg tables in Glue from Exasol", "Glue database as a virtual schema", "exakit connect lakehouse", "glue:GetTables AccessDeniedException from exakit", "Glue Iceberg REST endpoint with exakit".
---

# Iceberg on AWS Glue → local Exasol

Shared rules (credential handling, the lakehouse engine, the `--json` answer and
failure kinds, re-point, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is the Glue route's own.

## 1. When to use it

The Iceberg tables of one AWS Glue database - written by Athena, Spark, EMR or
Glue jobs - read where they lie in S3, with no compute at the source. Plain
Hive Parquet tables of the database are read too. One Glue database is one
source. Tier GA.

Use this connector for Glue, not `iceberg-rest`: the Glue Iceberg REST endpoint
needs AWS SigV4 request signing, which the `iceberg-rest` connector does not
support. Other routes: `exasol-vs-iceberg-rest` (any other REST catalog),
`exasol-vs-unity` (Unity Catalog).

## 2. Fields

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `region` | yes | | AWS console > Glue > Data Catalog: the region selector; the bucket must be in it too (S3 > the bucket > Properties > AWS Region) |
| `database` | yes | | AWS console > Glue > Data Catalog > Databases (letters, digits, `_`, `-`; no dot) |
| `access_key_id` | no | | IAM > Users > the reader > Security credentials (`AKIA...`/`ASIA...`); leave it out when the credential file holds it |
| `secret` | yes | | the secret access key, or the JSON `aws iam create-access-key` prints - only through `--password-file` |

The first question, "Name (alias) for this connection", is `--name`: the tables
appear as `VS_<NAME>`. Tables in Glue: Data Catalog > Tables, filtered by the
database; an Iceberg table shows table type `ICEBERG`.

The same with the AWS CLI (read-only):

```bash
aws glue get-databases --region <region> --query "DatabaseList[].Name" --output text
aws glue get-tables --region <region> --database-name <database> --output table \
  --query "TableList[].{name:Name,type:Parameters.table_type,location:StorageDescriptor.Location}"
aws s3api get-bucket-location --bucket <bucket-of-those-locations>   # null means us-east-1
aws sts get-caller-identity --query Account --output text            # the account id, for the policy
```

## 3. Connection-string forms

`--url` (or the first, hidden prompt at a terminal) reads:

- `arn:aws:glue:<region>:<account>:database/<name>` - fills `region` and `database`
- `https://glue.<region>.amazonaws.com` - fills `region`

A table ARN (`...:table/<database>/<table>`) fills the same two. `--set` wins
over what the string names. Neither form carries a key or an `&`, so both paste
the same on Windows; the secret always comes from `--password-file`.

## 4. Prepare the source (recommended policy; show, then run on a yes)

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

- Glue actions on a table need the catalog ARN as well as the database and
  table ARNs. Lake Formation grants are not evaluated.
- The key signs both the Glue and the S3 requests; the kit stores it in the
  CONNECTION's password as JSON.
- **Network.** The engine reaches Glue and S3 at their public regional
  endpoints over HTTPS. A bucket policy that limits `aws:SourceIp` must include
  this computer's public IP (`exakit connect` shows it; fallback: the
  `python3` one-liner in the shared skill).

## 5. TLS

No CA file. Glue and S3 are reached over HTTPS, and the engine checks their
certificates itself: this connector has no `tls` or `ca` input.

## 6. Connect

```bash
exakit connect lakehouse --name lake --set region=<region> --set database=<database> --dry-run
exakit connect lakehouse --name lake --set region=<region> --set database=<database> \
  --password-file ~/.config/exakit/<name>-key.json --yes --json
```

PowerShell is the same line, with `` ` `` for a line break. The first
lakehouse source installs the Rust language container - at once at a terminal,
with `--yes` in a script. Tell the user first: a download and one database
restart. The tables appear as `VS_LAKE`.

## 7. Verify and query

```bash
exakit source check lake
exakit source describe lake
exakit sql 'SELECT * FROM VS_LAKE.ORDERS LIMIT 10'
exakit sql 'SELECT STATUS, COUNT(*) AS N FROM VS_LAKE.ORDERS GROUP BY STATUS ORDER BY N DESC'
exakit sql 'SELECT EXAKIT_VS.LAKEHOUSE_VERSION()'     # the engine build
```

Names arrive upper case, so these need no quotes and run the same in Windows
PowerShell 5.1. A query with a quoted name loses its inner double quotes as a
PowerShell 5.1 argument: pipe it in or use a file there.

```powershell
'SELECT "ORDER_ID", "STATUS" FROM VS_LAKE."ORDERS" LIMIT 10' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

Table and column names arrive upper case (`ORDERS`, `ORDER_ID`). Deletes,
refused formats and the results that differ from native Exasol in edge cases
are the lakehouse engine's: see the shared skill.

## 9. When it fails

| Message | Fix |
|---|---|
| "Glue GetTables failed ... AccessDeniedException ... not authorized to perform: glue:GetTables" (`denied`) | the key may not list that database - or, under a policy scoped to named databases, it does not exist (AWS answers both the same way): check the name, else grant what the message names, then `exakit source check lake` |
| "The security token included in the request is invalid" (`auth`) | AWS does not know the key (deleted, or a typo): a new key, then `exakit source reauth lake --password-file <new.json>` |
| `clock`, or "PermissionDenied ... status: 403" with the clock far off | the database clock is behind (after the laptop slept): S3 and Glue refuse a request signed more than 15 minutes off, and the engine can report it as a 403. `exakit stop`, then `exakit start` |
| "incorrectly configured region", "x-amz-bucket-region" (`region`) | the bucket is in another region: connect again with `--set region=<the bucket's region>` and the key |
| `input` (exit 2) for the database | a dotted name: the engine refuses one |
| a table left out by name | ORC, Avro and Delta tables, views and tables with partition projection are not read; an Iceberg table with equality deletes is refused |
| `norust` (exit 23) | the Rust language container is missing: rerun with `--yes` after telling the user |

`exakit connect` shows the clock first: "Database clock: in sync with this
computer.", or a warning that offers the restart at a terminal.

## 10. Keep it working

- A new key: `exakit source reauth lake --password-file <new.json>`
  (temporary `ASIA...` credentials expire; give new ones the same way).
- Another region or Glue database:
  `exakit connect lakehouse --name lake --set database=<new> --password-file <key.json> --yes`
  (`--dry-run` first). `VS_LAKE` keeps its name; the key is asked for again.
- Tables added in Glue: `exakit source refresh lake`.
- Stop: `exakit source disconnect lake` or `exakit source remove lake`
  (`--dry-run` first, then ask). The last lakehouse source of any route
  removes the shared scripts.
