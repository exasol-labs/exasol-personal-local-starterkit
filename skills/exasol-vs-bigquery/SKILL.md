---
name: exasol-vs-bigquery
description: Connect a Google BigQuery dataset to local Exasol as a virtual schema with exakit connect bigquery. Covers the inputs to collect (project, dataset, a service-account key file), finding them with bq and gcloud, a dedicated service account with BigQuery Job User and Data Viewer only, creating its key straight into a file, how the kit keeps that key and who could read it, the unattended connect line, quoting BigQuery's names, and the BigQuery-specific failures. Connector id bigquery, aliases bq, gbq and google-bigquery, tier GA. Triggers — "connect BigQuery", "query BigQuery from Exasol", "BigQuery service account key", "add a BigQuery dataset to Exasol", "exakit connect bigquery", "Error getting access token for service account".
---

# BigQuery → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds,
disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is BigQuery's own.

## 1. When to use it

A BigQuery dataset to query from local Exasol without copying it - for small
results: rows come back as `VALUES` from the adapter itself (upstream warns at
a few thousand rows). One source is one dataset. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `project` | yes | | name | the Google Cloud project ID that holds the dataset |
| `dataset` | yes | | name | the dataset to expose |
| `key_file` | yes | | secret-file | the service-account key file (JSON) - given as `--password-file <path>`, never as a `--set` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
gcloud config get-value project                              # the current project ID
bq ls --format=prettyjson --project_id <project>             # its datasets
bq show --format=prettyjson <project>:<dataset>              # the dataset, with its location
bq ls --format=prettyjson <project>:<dataset>                # its tables
gcloud iam service-accounts list --project=<project>         # existing service accounts
```

A connection string fills project and dataset:
`--url 'jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=<project>;DefaultDataset=<dataset>'`.

## 4. Prepare a reader at the source (recommended roles; show, then run on a yes)

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

An organization policy can forbid key creation
(`iam.disableServiceAccountKeyCreation`); then the user's admin decides.

## 5. Network

The adapter reaches `www.googleapis.com` over HTTPS; no address needs allowing
unless a VPC Service Controls perimeter guards the project - its access level
must then include this computer's public IP (`exakit connect` shows it;
fallback: the `python3` one-liner in the shared skill).

## 6. Connect

```bash
exakit connect bigquery --name bq --set project=<project> --set dataset=<dataset> --dry-run
exakit connect bigquery --name bq --set project=<project> --set dataset=<dataset> \
  --password-file ~/.config/exakit/<name>-key.json --yes --json
```

- **Where the key lives - tell the user.** BigQuery's driver reads the key only
  from a file (measured: in the CONNECTION's password it is refused), so the
  kit writes it to BucketFS as this source's own file, owner-only on this
  computer, and the CONNECTION names only its path. Unlike every other
  connector's credential, **any database user who may create scripts can read
  that file**. On a fresh kit that is nobody but SYS; `connect` and `check`
  name anyone else, and the fix is to revoke their `CREATE SCRIPT`.
- The tables appear as `VS_BQ`.

## 7. Verify

```bash
exakit source check bq
exakit source describe bq
exakit sql 'SELECT "customer_id" FROM VS_BQ."orders" LIMIT 10'   # names keep BigQuery's spelling: quote them
```

## 8. When it fails

| Message | Fix |
|---|---|
| "Error getting access token for service account: 400 Bad Request" | a refused key - or the database clock: the sign-in token is dated by it. If `exakit status` shows it behind, `exakit stop`, `exakit start`; else the key may be deleted or disabled |
| "the credential must be the service-account key file (JSON)" | `--password-file` must name the key JSON |
| "the key file is not a service-account key", "has no usable client_email", "has no private key" | not the file `gcloud iam service-accounts keys create` wrote |
| "Required Connection Key(s)" | a configuration fault, not the network: `exakit logs` |
| "PERMISSION_DENIED: Access Denied: ... User does not have permission" (`denied`) | Job User on the project, Data Viewer on the dataset (section 4); behind a VPC Service Controls perimeter, also the public IP the fix names (section 5) |

Types: `INT64` arrives as `DECIMAL(19,0)`, `FLOAT64` as `DOUBLE`; an `ARRAY` or
`STRUCT` column arrives as BigQuery's raw JSON text (`{"v": ...}`).

## 9. Keep it working

- A new key: create it (section 4), then
  `exakit source reauth bq --password-file ~/.config/exakit/<name>-key.json`;
  a refused one keeps the previous key. Then delete the old key:
  `gcloud iam service-accounts keys delete <key-id> --iam-account=exakit-reader@<project>.iam.gserviceaccount.com`.
- Another project or dataset: not re-pointed in place - its key is a file staged for
  the source. `exakit source remove bq --yes`, then connect again with the new values
  and the key file (`VS_BQ` comes back under the same name).
- Tables added at the source: `exakit source refresh bq`.
- `disconnect` and `remove` delete the key file from BucketFS
  (`--dry-run` first, then ask) - see the shared skill.
