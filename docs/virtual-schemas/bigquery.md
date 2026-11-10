# Google BigQuery

One BigQuery dataset, read with a service-account key file. Meant for small
results: rows come back through the adapter itself.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-bigquery` knows this connector.
>
> **You still need, on your computer:** the Google Cloud CLI (`gcloud auth login`,
> which includes `bq`), or the Google Cloud console in a browser, as someone
> who may create service accounts and grant roles.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `bq` |
| Project ID | yes | `my-project-123` |
| Dataset | yes | `sales` |
| Service-account key file (JSON) | yes | `~/.config/exakit/bq-key.json` |

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

## Connection string you can paste

```text
jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;ProjectId=my-project-123;DefaultDataset=sales
jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;OAuthType=0;ProjectId=my-project-123;DefaultDataset=sales
```

Both fill project and dataset. The key file is still given separately.

## Common problems

| Symptom | Fix |
|---|---|
| "Error getting access token for service account: 400 Bad Request" | The sign-in is dated by the database clock. If `exakit status` shows it behind: `exakit stop`, then `exakit start`. Otherwise the key was deleted or disabled. |
| "PERMISSION_DENIED: Access Denied" | Grant Job User on the project and Data Viewer on the dataset (step 2). |
| "the credential must be the service-account key file (JSON)" | `--password-file` must name the JSON key file. |
| "the key file is not a service-account key" | Use the file from Keys → Create new key → JSON, not an OAuth client file. |
