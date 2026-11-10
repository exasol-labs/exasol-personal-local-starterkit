---
name: exasol-vs-s3
description: Connect JSON, CSV and Parquet files in an Amazon S3 bucket to local Exasol as tables with exakit connect s3. Covers the inputs to collect (bucket, region, an EDML mapping, an access key), finding them with the AWS CLI, a dedicated IAM user with s3:ListBucket and s3:GetObject on the mapped prefix only, writing its access key straight to a file, bucket policies that limit source IPs, the unattended connect line, and the S3-specific failures (access denied, wrong region, clock skew, empty globs). Connector id s3, aliases aws-s3, s3-files, s3-documents and amazon-s3, tier GA. Triggers — "query files in S3", "connect an S3 bucket", "JSON files in S3 as a table", "query Parquet in S3 from Exasol", "CSV files in S3 from Exasol", "exakit connect s3".
---

# Amazon S3 files → local Exasol

Shared rules (credential handling, the EDML mapping, the `--json` answer and
failure kinds, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is S3's own.

## 1. When to use it

JSON, JSON Lines, CSV or Parquet files in an S3 bucket to query as tables from
local Exasol without loading them. An EDML mapping (see the shared skill) says
which objects become which table. Standard regional endpoints over verified
HTTPS only: no endpoint override, path-style access or anonymous reads. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `bucket` | yes | | s3-bucket | the bucket name; no dots (its HTTPS name would not match the certificate) |
| `region` | yes | | aws-region | the bucket's region, e.g. `eu-central-1`; China regions are not reached |
| `mapping` | yes | | edml | a mapping `.json` file on this computer, or a folder of them |
| `access_key_id` | no | | aws-key-id | `AKIA...`/`ASIA...`; leave it out when the credential file holds it |
| `secret` | yes | | secret | the secret access key, or the JSON `aws iam create-access-key` or `aws sts` prints - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
aws s3api get-bucket-location --bucket <bucket>          # null means us-east-1, EU means eu-west-1
aws s3 ls s3://<bucket>/<prefix>/ --recursive | head -20  # the keys a mapping's "source" globs
aws s3api get-bucket-encryption --bucket <bucket>        # aws:kms: the key also needs kms:Decrypt
aws s3api get-bucket-policy --bucket <bucket>            # an aws:SourceIp condition needs this computer's IP
```

A URL fills bucket (and region): `--url 's3://<bucket>/<prefix>/'` or
`--url 'https://<bucket>.s3.<region>.amazonaws.com/<prefix>/'`; the path after
the bucket is not used - the mapping names the files.

## 4. Prepare a reader at the source (recommended policy; show, then run on a yes)

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

Add `kms:Decrypt` on the bucket's key for a KMS-encrypted bucket. The kit never
reads `~/.aws`; suggest this dedicated user, not the user's own keys.
Temporary credentials work too: the whole `aws sts ...` JSON (with
`SessionToken`) in the file; they expire.

## 5. Network

The adapter reaches `<bucket>.s3.<region>.amazonaws.com` over HTTPS. A bucket
policy that limits `aws:SourceIp` must include this computer's public IP
(`exakit connect` shows it; fallback: the `python3` one-liner in the shared
skill). A bucket reachable only through a VPC endpoint cannot be read from here.

## 6. Connect

```bash
exakit connect s3 --name docs --set bucket=<bucket> --set region=<region> \
  --set mapping=./mapping --dry-run
exakit connect s3 --name docs --set bucket=<bucket> --set region=<region> \
  --set mapping=./mapping --password-file ~/.config/exakit/docs-key.json --yes --json
```

- The plan lists the mapped tables; the kit checks the mapping before anything
  happens.
- With only the secret key in the file, add `--set access_key_id=AKIA...`.
- The tables appear as `VS_DOCS.<destinationTable in upper case>`.

## 7. Verify

```bash
exakit source check docs          # one row from each table (up to 25); names any that are empty
exakit source describe docs
exakit sql "SELECT * FROM VS_DOCS.ORDERS LIMIT 10"
```

## 8. When it fails

| Message | Fix |
|---|---|
| "AccessDenied ... not authorized to perform: s3:ListBucket" (`denied`) | the key works but may not list or read there: grant the action on the prefix, then `exakit source check docs` - not reauth. A bucket policy on `aws:SourceIp` answers the same: allow the public IP the fix names (section 5) |
| "must be addressed using the specified endpoint", "PermanentRedirect" | the bucket is in another region: `exakit source disconnect docs --yes`, then connect with `--set region=<the bucket's region>` (a first connect: just connect again) |
| "RequestTimeTooSkewed" | the database clock is off by more than 15 minutes: `exakit stop`, then `exakit start` |
| "NoSuchBucket" | check the bucket name; remove and connect again |
| "InvalidAccessKeyId", "signature we calculated does not match" | a wrong or deleted key: `exakit source reauth docs --password-file <new.json>` |
| "ASIA... keys are temporary and need their session token" | give the whole `aws sts` JSON through `--password-file` |
| "No rows in X" | the mapping's `source` matches no objects: check the glob |
| "E-VSD-102: Schema auto inference ... failed - caused by ..." | columns inferred at connect failed; act on the cause after "caused by" |

## 9. Keep it working

- A new key (rotation, or temporary credentials that expired):
  `exakit source reauth docs --password-file <new.json>`.
- Another bucket or region: its CONNECTION holds them inside the credential, so
  give the key again with the change: `exakit connect s3 --name docs --set
  region=<new> --password-file <key.json> --yes` (`--dry-run` first).
- A changed mapping: `exakit source remove docs`, then connect again.
- Stop: `exakit source disconnect docs` or `exakit source remove docs`
  (`--dry-run` first, then ask) - see the shared skill.
