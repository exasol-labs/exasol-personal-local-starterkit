# Azure Blob Storage files

JSON, JSON Lines, CSV or Parquet files in an Azure Blob container, read as
tables. An EDML mapping file on your computer says which files become which
table. Public Azure cloud only.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-azure-blob` knows this connector.
>
> **You still need, on your computer:** the Azure CLI (`az login`) or the Azure
> portal, as someone who may create a SAS for the container.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `azdocs` |
| Storage account name | yes | `mystorageacct` |
| Container name | yes | `docs` |
| EDML mapping on this computer: a .json file, or a folder of them | yes | `./mapping` |
| SAS token (read + list), connection string or account key | yes | (hidden, or a file) |

## Where to find each value

### 1. Storage account and container

- **Portal:** Storage accounts → `<account>` → Data storage → Containers.
- **CLI:**
  ```bash
  az storage account list -o table --query "[].{name:name,rg:resourceGroup}"
  az storage container list --account-name mystorageacct --auth-mode login --query "[].name" -o tsv
  ```

### 2. The mapping

One `.json` file per table, or a folder of them (at most 50). `source` is the
blob name or glob inside the container:

```json
{"$schema": "https://schemas.exasol.com/edml-2.1.0.json",
 "source": "orders/*.parquet", "destinationTable": "ORDERS"}
```

CSV and Parquet may leave out `mapping` and have their columns inferred; JSON
needs its fields (see the [S3 guide](s3.md#2-the-mapping) for an example).

### 3. A read-only SAS token (recommended)

Read (`r`) and list (`l`) only, with an expiry, HTTPS only.

- **Portal:** `<account>` → Containers → `<container>` → Shared access tokens →
  Permissions: Read, List → set Expiry → Allowed protocols: HTTPS only →
  Generate SAS token and URL → copy the **Blob SAS token**.
- **CLI:**
  ```bash
  umask 077; mkdir -p ~/.config/exakit
  az storage container generate-sas --account-name mystorageacct -n docs --permissions rl \
    --expiry 2027-01-31 --https-only --auth-mode key -o tsv > ~/.config/exakit/azdocs-sas.txt
  ```

A SAS opens the whole container (it cannot be narrowed to a folder). An
account key or connection string also works but opens every container, for
writing too.

### 4. Open the network

Get your public IP: `curl https://checkip.amazonaws.com`. If the account's
firewall is on (`<account>` → Security + networking → Networking → Public
network access: Enabled from selected networks), add it under Firewall →
Address range → Save.

```bash
az storage account network-rule add -g <rg> --account-name mystorageacct --ip-address <your-ip>
```

Public network access Disabled means no access from outside a private endpoint.

## Connect

```bash
exakit connect azure-blob
```

The kit asks for a connection string (hidden; press Enter on an empty line to
type the fields instead), then each field above. It checks the SAS and the
mapping, shows a plan and asks once, and tells you when the SAS expires. The
first connect installs Java in the database (one restart). Your tables appear
as `VS_AZDOCS.ORDERS`.

Without prompts:

```bash
exakit connect azure-blob --name azdocs --set account=mystorageacct --set container=docs \
  --set mapping=./mapping --password-file ~/.config/exakit/azdocs-sas.txt --yes
exakit sql "SELECT * FROM VS_AZDOCS.ORDERS LIMIT 10"
```

Add `--dry-run` to see the plan first.

**Windows:** paste the URL or connection string at the prompt rather than
`--url`: a SAS contains `&`. For a quoted name in `exakit sql`, pipe the
statement in (`'SELECT "x" FROM VS_AZDOCS.T' | exakit sql`) or use
`exakit sql --file query.sql`.

## Connection string you can paste

```text
https://mystorageacct.blob.core.windows.net/docs
abfss://docs@mystorageacct.dfs.core.windows.net
```

Both fill account and container. A storage connection string
(`DefaultEndpointsProtocol=https;AccountName=mystorageacct;...`) fills the
account only; its key is never taken from the string.

## Common problems

| Symptom | Fix |
|---|---|
| `AuthenticationFailed` | An expired SAS, a wrong key, or a SAS made for another container: check the container name, else `exakit source reauth azdocs --password-file <new sas>`. |
| `AuthorizationPermissionMismatch` | The SAS lacks read or list: make one with `rl` (step 3), then reauth. |
| `AuthorizationFailure` | The storage firewall refused you: allow your IP (step 4). |
| "the SAS is for a single blob", "the SAS expired" | Generate a container SAS (step 3). |
| A refusal with the database clock far off | `exakit stop`, then `exakit start`. |
