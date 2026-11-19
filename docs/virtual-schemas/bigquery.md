# Google BigQuery · Federation guide

> **Federation** lets your local Exasol query BigQuery data in place, without copying it.
> `exakit connect bigquery` makes it a virtual schema, `VS_<NAME>`, that you query with SQL.

One BigQuery dataset, read with a service-account key file. Meant for small
results: rows come back through the adapter itself.

## At a glance

| You need | Where to find it |
|---|---|
| Project ID and dataset | The console's project picker; BigQuery → Studio → Explorer ([step 1](#1-project-id-and-dataset)) |
| A read-only service account | IAM & Admin → Service Accounts ([step 2](#2-a-read-only-service-account)) |
| Its key file (JSON), owner-only | Service account → Keys → Create new key ([step 3](#3-the-key-file)) |
| Network | Nothing to open, unless a VPC Service Controls perimeter ([step 4](#4-network)) |

## The simplest way: ask your AI agent

**Easiest: let your AI agent do it.** The kit installs the skill
`exasol-vs-bigquery` for your AI client; it knows this connector.

Copy this prompt, fill in the `<...>` parts, and give it to your agent:

```text
Connect the BigQuery dataset <dataset> in the project <project-id> to my local
Exasol with exakit. Use the exasol-vs-bigquery skill. Create a read-only
service account for it and save its key file on this computer, never in the
chat.
```

**You still need, on your computer:** the Google Cloud CLI (`gcloud auth login`,
which includes `bq`), or the Google Cloud console in a browser, as someone
who may create service accounts and grant roles.

**Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

### Required

| Field | Example |
|---|---|
| Name (alias) for this connection | `bq` (gives the schema `VS_BQ`) |
| Project ID | `my-project-123` (the ID, not the name) |
| Dataset | `sales` |
| Service-account key file (JSON) | `~/.config/exakit/bq-key.json` |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| (none) | Every field is required. | |

## Where to find each value

Prepare the source in this order. Every step is a one-time setup.

### 1. Project ID and dataset

- **Console:** the project picker at the top shows the project **ID** (not its
  name). BigQuery → Studio → Explorer → `<project>` → `<dataset>`; Dataset info
  shows its location.
- **CLI:**
  ```bash
  gcloud config get-value project
  bq ls --project_id <project>
  bq show <project>:<dataset>
  ```

### 2. A read-only service account

It needs **BigQuery Job User** on the project and **BigQuery Data Viewer** on
the dataset, nothing more.

- **Console:**
  1. IAM & Admin → Service Accounts → Create service account (`exakit-reader`).
  2. IAM & Admin → IAM → Grant access → the service account → role BigQuery
     Job User.
  3. BigQuery → `<dataset>` → Share → Manage permissions → Add principal → the
     service account → role BigQuery Data Viewer.
- **CLI:**
  ```bash
  gcloud iam service-accounts create exakit-reader --project=<project>
  gcloud projects add-iam-policy-binding <project> \
    --member=serviceAccount:exakit-reader@<project>.iam.gserviceaccount.com --role=roles/bigquery.jobUser
  bq query --use_legacy_sql=false --project_id=<project> --location=<location> \
    'GRANT `roles/bigquery.dataViewer` ON SCHEMA `<project>`.<dataset> TO "serviceAccount:exakit-reader@<project>.iam.gserviceaccount.com"'
  ```

### 3. The key file

- **Console:** IAM & Admin → Service Accounts → `exakit-reader` → Keys → Add
  key → Create new key → JSON. Move the download to `~/.config/exakit/` and
  `chmod 600` it.
- **CLI:**
  ```bash
  umask 077; mkdir -p ~/.config/exakit
  gcloud iam service-accounts keys create ~/.config/exakit/bq-key.json \
    --iam-account=exakit-reader@<project>.iam.gserviceaccount.com
  ```

If key creation is blocked (`iam.disableServiceAccountKeyCreation`), your
organisation's admin decides.

### 4. Network

Nothing to open: the adapter reaches `www.googleapis.com` over HTTPS. Only a
VPC Service Controls perimeter around the project must allow your public IP
(`curl https://checkip.amazonaws.com`).

**Where the key lives:** the driver reads the key only from a file, so the kit
writes it to BucketFS as this source's own file. Any database user who may
create scripts can read it; on a fresh kit that is nobody but SYS, and
`exakit connect` names anyone else.

## Connect

```bash
exakit connect bigquery
```

1. The kit asks for a connection string (hidden). Press Enter on an empty line
   to type the fields instead.
2. It shows a plan, then connects.
3. The first connect enables Federation: it installs Java in the database
   (one restart).

Your tables appear as `VS_BQ`.

Without prompts:

```bash
exakit connect bigquery --name bq --set project=my-project-123 --set dataset=sales \
  --password-file ~/.config/exakit/bq-key.json --yes
```

Add `--dry-run` to see the plan first.

**Windows:** paste the connection string at the prompt rather than `--url`.
Quoted names do not survive PowerShell 5.1 arguments: pipe the statement in
(`'SELECT "customer_id" FROM VS_BQ."orders"' | exakit sql`) or use
`exakit sql --file query.sql`.

## Query

Names keep BigQuery's spelling: quote them.

```bash
exakit sql 'SELECT "customer_id" FROM VS_BQ."orders" LIMIT 10'
```

```powershell
'SELECT "customer_id" FROM VS_BQ."orders" LIMIT 10' | exakit sql
```

- `INT64` arrives as `DECIMAL(19,0)` and `FLOAT64` as `DOUBLE`.
- An `ARRAY` or `STRUCT` column arrives as BigQuery's raw JSON text
  (`{"v": ...}`).
- Keep results small: the adapter returns the rows itself (upstream warns at a
  few thousand rows).

## Troubleshooting

| Error you see | Why | Fix |
|---|---|---|
| "Error getting access token for service account: 400 Bad Request" | The sign-in is dated by the database clock, or the key was deleted or disabled. | If `exakit status` shows the clock behind: `exakit stop`, then `exakit start`. Otherwise make a new key (step 3). |
| "PERMISSION_DENIED: Access Denied" | The service account lacks a role. | Grant Job User on the project and Data Viewer on the dataset (step 2). |
| "the credential must be the service-account key file (JSON)" | `--password-file` names another file. | Name the JSON key file. |
| "the key file is not a service-account key" | It is an OAuth client file. | Use the file from Keys → Create new key → JSON. |

## Connection string you can paste

Reference. The string is optional: at the prompt, press Enter alone and
`exakit connect` asks for the fields one by one.

```text
jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=my-project-123;DefaultDataset=sales
jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;OAuthType=0;ProjectId=my-project-123;DefaultDataset=sales
```

| String | Fills |
|---|---|
| `jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=...;DefaultDataset=...` | project and dataset |

The endpoint before the first `;` is not read, and `OAuthType` is dropped. The
key file is never part of the string: give it separately.

### Where to find the connection string

There is none to copy: the Google Cloud console shows no connection string
for BigQuery. You have two choices:

- Press Enter alone at the prompt and type the project ID and the dataset.
  This is the simpler way.
- Or write the string from those two values:
  `jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=<project-id>;DefaultDataset=<dataset>`.

### Where to find each part of the string

| Part of the string | Where to find it |
|---|---|
| `ProjectId` | The console's project picker: the project **ID**, or `gcloud config get-value project` ([step 1](#1-project-id-and-dataset)). |
| `DefaultDataset` | BigQuery → Studio → Explorer → `<project>`, or `bq ls --project_id <project>` ([step 1](#1-project-id-and-dataset)). |

### `--set` keys

`project`, `dataset`. Give the key file with `--password-file`.
