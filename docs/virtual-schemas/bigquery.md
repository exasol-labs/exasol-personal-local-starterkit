# Google BigQuery

One BigQuery dataset, read with a service-account key file. Meant for small
results: rows come back through the adapter itself.

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

| Field | Example | Where it comes from |
|---|---|---|
| Name (alias) for this connection | `bq` | You choose it. `bq` gives the schema `VS_BQ`. |
| Project ID | `my-project-123` | The console's project picker (the ID, not the name) ([step 1](#1-project-id-and-dataset)). |
| Dataset | `sales` | BigQuery → Studio → Explorer ([step 1](#1-project-id-and-dataset)). |
| Service-account key file (JSON) | `~/.config/exakit/bq-key.json` | The key of the service account you make ([step 3](#3-the-key-file)). |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| (none) | Every field is required. | |

## Connection string you can paste

```text
jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=my-project-123;DefaultDataset=sales
jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;OAuthType=0;ProjectId=my-project-123;DefaultDataset=sales
```

| String | Fills |
|---|---|
| `jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=...;DefaultDataset=...` | project and dataset |

The endpoint before the first `;` is not read, and `OAuthType` is dropped. The
key file is still given separately.

### Where to find the connection string

There is none to copy: the Google Cloud console shows no connection string
for BigQuery. You have two choices:

- Press Enter alone at the prompt and type the project ID and the dataset.
  This is the simpler way.
- Or write the string from those two values:
  `jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=<project-id>;DefaultDataset=<dataset>`.

The key file is never part of the string. The string is optional. At the prompt, press Enter alone and `exakit connect` asks for the fields one by one.

### Where to find each part of the string

| Part of the string | Where to find it |
|---|---|
| `ProjectId` | The console's project picker: the project **ID**, or `gcloud config get-value project` ([step 1](#1-project-id-and-dataset)). |
| `DefaultDataset` | BigQuery → Studio → Explorer → `<project>`, or `bq ls --project_id <project>` ([step 1](#1-project-id-and-dataset)). |

## Where to find each value

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

- **Console:** IAM & Admin → Service Accounts → Create service account
  (`exakit-reader`). Then IAM & Admin → IAM → Grant access → the service
  account → role BigQuery Job User. Then BigQuery → `<dataset>` → Share →
  Manage permissions → Add principal → the service account → role BigQuery
  Data Viewer.
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

The kit asks for a connection string (hidden; press Enter on an empty line to
type the fields instead), then each field above. It shows a plan and asks
once. The first connect installs Java in the database (one restart). Your
tables appear as `VS_BQ`.

Without prompts:

```bash
exakit connect bigquery --name bq --set project=my-project-123 --set dataset=sales \
  --password-file ~/.config/exakit/bq-key.json --yes
exakit sql 'SELECT "customer_id" FROM VS_BQ."orders" LIMIT 10'
```

Names keep BigQuery's spelling: quote them. Add `--dry-run` to see the plan first.

**Windows:** paste the connection string at the prompt rather than `--url`.
Quoted names do not survive PowerShell 5.1 arguments: pipe the statement in
(`'SELECT "customer_id" FROM VS_BQ."orders"' | exakit sql`) or use
`exakit sql --file query.sql`.

## Common problems

| Symptom or error text | Fix |
|---|---|
| "Error getting access token for service account: 400 Bad Request" | The sign-in is dated by the database clock. If `exakit status` shows it behind: `exakit stop`, then `exakit start`. Otherwise the key was deleted or disabled. |
| "PERMISSION_DENIED: Access Denied" | Grant Job User on the project and Data Viewer on the dataset (step 2). |
| "the credential must be the service-account key file (JSON)" | `--password-file` must name the JSON key file. |
| "the key file is not a service-account key" | Use the file from Keys → Create new key → JSON, not an OAuth client file. |
