---
name: exasol-vs-bigquery
description: Connect a Google BigQuery dataset to local Exasol as a virtual schema with exakit connect bigquery. Covers the inputs to collect (project, dataset, a service-account key file) and where the Google Cloud console shows each, a dedicated service account with BigQuery Job User and Data Viewer only, creating its key straight into a file, how the kit keeps that key and who could read it, the connection-string form, why no CA file is needed, the unattended connect line, quoting BigQuery's names in bash and Windows PowerShell, why a BigQuery source is not re-pointed in place, and the BigQuery-specific failures. Connector id bigquery, aliases bq, gbq and google-bigquery, tier GA. Triggers — "connect BigQuery", "query BigQuery from Exasol", "BigQuery service account key", "add a BigQuery dataset to Exasol", "exakit connect bigquery", "Error getting access token for service account".
---

# BigQuery → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds, the
database clock, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is BigQuery's own.

## 1. When to use it

A BigQuery dataset to query from local Exasol without copying it - for small
results: rows come back as `VALUES` from the adapter itself (upstream warns at
a few thousand rows). One source is one dataset. Tier GA.

## 2. Fields

The first prompt, "Name (alias) for this connection", is the source name
(`--name`): `bq` becomes schema `VS_BQ`.

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `project` | yes | | Google Cloud console > project picker (top bar) > the ID column, not the name |
| `dataset` | yes | | BigQuery Studio > Explorer > `<project>` > the dataset |
| `key_file` | yes | | the service-account key JSON (section 4) - given as `--password-file <path>`, never as a `--set` |

From the CLI (read-only):

```bash
gcloud config get-value project
bq ls --format=prettyjson --project_id <project>        # its datasets
bq show --format=prettyjson <project>:<dataset>         # the dataset and its location
gcloud iam service-accounts list --project=<project>
```

## 3. Connection-string form

`--url` (or the hidden paste prompt) reads
`jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=...;DefaultDataset=...`
and fills `project` and `dataset`; the endpoint before the first `;` is not
read. `;` passes through Windows unharmed. The key never travels in a string.

## 4. Prepare the source (show every command, run on a yes)

A dedicated service account with BigQuery Job User on the project and BigQuery
Data Viewer on the dataset only:

```bash
gcloud iam service-accounts create exakit-reader --project=<project> --display-name="Exasol starter kit reader"
gcloud projects add-iam-policy-binding <project> \
  --member=serviceAccount:exakit-reader@<project>.iam.gserviceaccount.com --role=roles/bigquery.jobUser
bq query --use_legacy_sql=false --project_id=<project> --location=<location> \
  'GRANT `roles/bigquery.dataViewer` ON SCHEMA `<project>`.<dataset> TO "serviceAccount:exakit-reader@<project>.iam.gserviceaccount.com"'
```

Then its key, straight into an owner-only file (never print it):

```bash
umask 077; mkdir -p ~/.config/exakit
gcloud iam service-accounts keys create ~/.config/exakit/<name>-key.json \
  --iam-account=exakit-reader@<project>.iam.gserviceaccount.com
```

Console alternative: IAM & Admin > Service Accounts > `<account>` > Keys > Add
key > JSON. An organization policy can forbid key creation
(`iam.disableServiceAccountKeyCreation`); then the user's admin decides.

**Network.** The adapter reaches `www.googleapis.com` over HTTPS. No address
needs allowing unless a VPC Service Controls perimeter guards the project: its
access level must then include this computer's public IP (`exakit connect`
shows it; fallback in the shared skill).

## 5. TLS

No CA file and no `tls` input: the connection to Google is HTTPS, always
verified.

## 6. Connect

```bash
exakit connect bigquery --name bq --set project=<project> --set dataset=<dataset> --dry-run
exakit connect bigquery --name bq --set project=<project> --set dataset=<dataset> \
  --password-file ~/.config/exakit/<name>-key.json --yes --json
```

PowerShell: the same on one line, `--password-file $HOME\.config\exakit\<name>-key.json`.

**Where the key lives - tell the user.** The driver reads the key only from a
file (a key in the CONNECTION's password is refused), so the kit writes it to
BucketFS as this source's own file, owner-only on this computer, and the
CONNECTION names only its path. Unlike every other connector's credential,
**any database user who may create scripts can read that file**. On a fresh
kit that is nobody but administrators; `connect` and `check` name anyone else.
The fix is to revoke their `CREATE SCRIPT`.

## 7. Verify and query

```bash
exakit source check bq
exakit source describe bq
exakit sql 'SELECT "customer_id", "status" FROM VS_BQ."orders" LIMIT 10'
exakit sql 'SELECT "status", COUNT(*) FROM VS_BQ."orders" GROUP BY "status"'
```

Windows PowerShell 5.1 drops the inner double quotes of an argument, and every
BigQuery name is quoted. Pipe the query or use a file there:

```powershell
'SELECT "customer_id", "status" FROM VS_BQ."orders" LIMIT 10' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

- Names keep BigQuery's spelling (`orders`, `customer_id`): quote them exactly.
- `INT64` arrives as `DECIMAL(19,0)`, `FLOAT64` as `DOUBLE`; an `ARRAY` or
  `STRUCT` column arrives as BigQuery's raw JSON text (`{"v": ...}`).

## 9. When it fails

| Message | Fix |
|---|---|
| "Error getting access token for service account: 400 Bad Request" (`auth`) | a refused key - or the database clock: the sign-in token is dated by it. `exakit connect` shows "Database clock: in sync with this computer." or a warning; if behind, `exakit stop`, then `exakit start`. Else the key may be deleted or disabled |
| "the credential must be the service-account key file (JSON) Google Cloud created" | `--password-file` must name the key JSON |
| "the key file is not a service-account key", "has no usable client_email", "has no private key" | not the file `gcloud iam service-accounts keys create` wrote |
| "Required Connection Key(s)" | a configuration fault, not the network: `exakit logs` |
| "PERMISSION_DENIED: Access Denied: ... User does not have permission" (`denied`) | Job User on the project, Data Viewer on the dataset (section 4); behind a VPC Service Controls perimeter, also the public IP the fix names |

## 10. Keep it working

- A new key: create it (section 4), then
  `exakit source reauth bq --password-file ~/.config/exakit/<name>-key.json`;
  a refused one keeps the previous key. Then delete the old key:
  `gcloud iam service-accounts keys delete <key-id> --iam-account=exakit-reader@<project>.iam.gserviceaccount.com`.
- Another project or dataset: **not re-pointed in place** - unlike the other
  connectors, `exakit connect bigquery --name bq --set ...` is refused (exit 2,
  nothing changed), because its key is a file staged for the source.
  `exakit source remove bq --yes`, then connect again with the new values and
  the key file (`VS_BQ` comes back under the same name).
- Tables added at the source: `exakit source refresh bq`.
- `disconnect` and `remove` delete the key file from BucketFS
  (`--dry-run` first, then ask) - see the shared skill.
