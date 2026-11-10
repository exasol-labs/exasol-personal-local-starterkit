---
name: exasol-vs-s3
description: Connect JSON, CSV and Parquet files in an Amazon S3 bucket to local Exasol as tables with exakit connect s3. Covers the inputs to collect (bucket, region, an EDML mapping, an access key) and where each is in the AWS console, a dedicated IAM user with s3:ListBucket and s3:GetObject on the mapped prefix only, writing its access key straight to a file, bucket policies that limit source IPs, the unattended connect line, queries in the bash and PowerShell forms, and the S3-specific failures (access denied, wrong region, a database clock behind after sleep, empty globs). Connector id s3, aliases aws-s3, s3-files, s3-documents and amazon-s3, tier GA. Triggers — "query files in S3", "connect an S3 bucket", "JSON files in S3 as a table", "query Parquet in S3 from Exasol", "CSV files in S3 from Exasol", "exakit connect s3", "RequestTimeTooSkewed from exakit".
---

# Amazon S3 files → local Exasol

Shared rules (credential handling, the EDML mapping, the `--json` answer and
failure kinds, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is S3's own.

## 1. When to use it

JSON, JSON Lines, CSV or Parquet files in one S3 bucket, queried as tables from
local Exasol without loading them. An EDML mapping says which objects become
which table. Standard regional endpoints over verified HTTPS only: no endpoint
override, path-style access or anonymous reads. Tier GA.

## 2. Fields

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `bucket` | yes | | AWS console > S3 > Buckets: the name. No dots: its HTTPS name would not match the S3 certificate |
| `region` | yes | | AWS console > S3 > bucket > Properties > AWS Region (code, e.g. `eu-central-1`). China (`cn-`) regions are refused |
| `mapping` | yes | | a mapping `.json` file on this computer, or a folder of them (at most 50); see the shared skill |
| `access_key_id` | no | | IAM > Users > user > Security credentials > Access keys (`AKIA...`/`ASIA...`). Leave it out when the credential file holds it |
| `secret` | yes | | the secret access key, or the JSON `aws iam create-access-key` or `aws sts` prints - only through `--password-file` or a closed stdin pipe |

The first question, "Name (alias) for this connection", is the source name
(`docs`): its tables appear in schema `VS_DOCS`.

Read-only discovery with the CLI:

```bash
aws s3api get-bucket-location --bucket <bucket>          # null means us-east-1, EU means eu-west-1
aws s3 ls s3://<bucket>/<prefix>/ --recursive | head -20  # the keys a mapping's "source" globs
aws s3api get-bucket-encryption --bucket <bucket>        # aws:kms: the key also needs kms:Decrypt
aws s3api get-bucket-policy --bucket <bucket>            # an aws:SourceIp condition needs this computer's IP
```

## 3. Connection-string forms

`--url` (or the hidden paste prompt) reads:

- `s3://<bucket>/...` (also `s3a://`, `s3n://`) - fills `bucket`;
- `https://<bucket>.s3.<region>.amazonaws.com/...` - fills `bucket` and `region`.

The path after the bucket is not used: the mapping names the files. A query
string (a presigned URL) is treated as a credential and dropped.

## 4. Prepare the source (recommended policy; show, then run on a yes)

```bash
cat > exakit-s3-read.json <<'JSON'
{"Version": "2012-10-17", "Statement": [
  {"Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::<bucket>",
   "Condition": {"StringLike": {"s3:prefix": ["<prefix>/*"]}}},
  {"Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::<bucket>/<prefix>/*"}]}
JSON
aws iam create-user --user-name exakit-<name>-reader
aws iam put-user-policy --user-name exakit-<name>-reader --policy-name exakit-read \
  --policy-document file://exakit-s3-read.json
umask 077; mkdir -p ~/.config/exakit
aws iam create-access-key --user-name exakit-<name>-reader > ~/.config/exakit/<name>-key.json   # never print it
```

- Add `kms:Decrypt` on the bucket's key for a KMS-encrypted bucket.
- The kit never reads `~/.aws`. Suggest this dedicated user, not the user's own keys.
- Temporary credentials work: the whole `aws sts ...` JSON, with `SessionToken`,
  in the file. They expire.

**Network.** The adapter reaches `<bucket>.s3.<region>.amazonaws.com` over
HTTPS. A bucket policy that limits `aws:SourceIp` must include this computer's
public IP: `exakit connect` shows it. A bucket reachable only through a VPC
endpoint cannot be read from here.

## 5. TLS

No CA file and no TLS input: the connection is always verified HTTPS to AWS.

**The clock matters.** After a laptop sleeps, the database clock can fall
behind. S3 refuses a request signed more than 15 minutes off its own clock, and
the failure is kind `clock`. `exakit connect` shows "Database clock: in sync
with this computer." or a warning with an offer to restart. The fix is
`exakit stop`, then `exakit start`.

## 6. Connect

```bash
exakit connect s3 --name docs --set bucket=<bucket> --set region=<region> \
  --set mapping=./mapping --dry-run
exakit connect s3 --name docs --set bucket=<bucket> --set region=<region> \
  --set mapping=./mapping --password-file ~/.config/exakit/docs-key.json --yes --json
```

PowerShell takes the same line on one row (or with backtick continuations), with
`$HOME\.config\exakit\docs-key.json` as the file.

- The plan lists the mapped tables; the kit checks the mapping before anything happens.
- With only the secret key in the file, add `--set access_key_id=AKIA...`.
- First use installs the Java language container (`--yes`, one restart): tell the user first.

## 7. Verify and query

```bash
exakit source check docs          # one row from each table (up to 25); names any that are empty
exakit source describe docs
exakit sql 'SELECT * FROM VS_DOCS.ORDERS LIMIT 10'
exakit sql 'SELECT STATUS, COUNT(*) FROM VS_DOCS.ORDERS GROUP BY STATUS'
exakit sql 'SELECT * FROM VS_DOCS.ORDERS_ITEMS WHERE ORDERS_ORDER_ID = 1001'
```

Windows PowerShell 5.1 drops the inner double quotes of an argument. These
queries have none, so they run as written there. A query with a quoted name is
piped in, or saved to a file:

```powershell
'SELECT "SOURCE_REFERENCE", COUNT(*) FROM VS_DOCS.ORDERS GROUP BY 1' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

- Tables are the mapping's `destinationTable` in upper case; columns are named
  by the mapping. A nested list becomes a child table (`ORDERS_ITEMS`).
- A CSV mapping without fields has its columns inferred, and a date then arrives
  as `VARCHAR(2000000)`: name the fields and their types to get typed columns.
- JSON needs explicit fields. The file type comes from the extension (`.json`,
  `.jsonl`, `.csv`, `.parquet`). The mapping format is in the shared skill.

## 9. When it fails

| Message (`kind`) | Fix |
|---|---|
| "AccessDenied ... not authorized to perform: s3:ListBucket" (`denied`) | the key may not list or read there: grant the action on the prefix, then `exakit source check docs` - not reauth. A bucket policy on `aws:SourceIp` answers the same: allow the public IP the fix names |
| "must be addressed using the specified endpoint", "PermanentRedirect" (`region`) | the bucket is in another region: `exakit source disconnect docs --yes`, then connect with `--set region=<the bucket's region>` and the key (a first connect: connect again) |
| "RequestTimeTooSkewed", "Signature not yet current" (`clock`) | the database clock is off by more than 15 minutes: `exakit stop`, then `exakit start`, then `exakit source check docs` |
| "NoSuchBucket" (`nobucket`) | check the bucket name; remove and connect again |
| "InvalidAccessKeyId", "signature we calculated does not match" (`auth`) | a wrong or deleted key: `exakit source reauth docs --password-file <new.json>` |
| "ASIA... keys are temporary and need their session token" | give the whole `aws sts` JSON through `--password-file` |
| "bucket X has dots" | not reachable over verified HTTPS: use a bucket without dots |
| "No rows in X" | the mapping's `source` matches no objects, or they are empty: check the glob |
| "E-VSD-102: Schema auto inference ... failed - caused by ..." | inferred columns failed: act on the cause after "caused by" |

## 10. Keep it working

- A new key (rotation, or expired temporary credentials):
  `exakit source reauth docs --password-file <new.json>`. It is tried first; a
  refused one keeps the old.
- Another bucket or region: `exakit connect s3 --name docs --set bucket=<new>
  --password-file <key.json> --yes` (`--dry-run` first). `VS_DOCS` keeps its
  name, and the key is asked for again, as for every re-point.
- A changed mapping cannot be re-pointed in place: `exakit source remove docs`,
  then connect again.
- Stop: `exakit source disconnect docs` or `exakit source remove docs`
  (`--dry-run` first, then ask) - see the shared skill.
