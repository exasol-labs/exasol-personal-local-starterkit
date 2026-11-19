# Azure Blob Storage · Federation guide

> **Federation** lets your local Exasol query JSON, JSON Lines, CSV and Parquet
> files in an Azure Blob container in place, without copying them.
> `exakit connect azure-blob` makes them a virtual schema, `VS_<NAME>`, that
> you query with SQL. An EDML mapping file says which files become which table;
> leave it empty and the kit drafts one from the container. Public Azure cloud
> only.

> **Easiest: let your AI agent do it.** The kit installs the skill
> `exasol-vs-azure-blob` for your AI client; it knows this connector. A ready-to-use prompt is in
> [Ask your AI agent](#ask-your-ai-agent).
>
> **You still need, on your computer:** the Azure CLI (`az login`) or the Azure
> portal, as someone who may create a SAS for the container.

## At a glance

| You need | Where to find it |
|---|---|
| The storage account and container | Portal → Storage accounts → Containers ([step 1](#1-storage-account-and-container)) |
| A mapping (optional) | One `.json` file per table, or let the kit draft it ([step 2](#2-the-mapping)) |
| A read-only SAS token | The container → Shared access tokens, Read + List ([step 3](#3-a-read-only-sas-token-recommended)) |
| Network access | Only if the storage firewall is on ([step 4](#4-open-the-network)) |

## Ask your AI agent

Copy this prompt, fill in the `<...>` parts, and give it to your agent:

```text
Connect the files in the Azure Blob container <container> of the storage account
<account> to my local Exasol with exakit. Use the exasol-vs-azure-blob skill.
Create a read-only SAS for the container, draft the mapping from the files,
and write the SAS to a file, never into the chat.
```

Prefer to do it by hand? Follow the steps below.

## What `exakit connect` asks for

### Required

| Field | Example | Where it comes from |
|---|---|---|
| Name (alias) for this connection | `azdocs` | You choose it. `azdocs` gives the schema `VS_AZDOCS`. |
| Storage account name | `mystorageacct` | Portal → Storage accounts ([step 1](#1-storage-account-and-container)). |
| Container name | `docs` | The account → Data storage → Containers ([step 1](#1-storage-account-and-container)). |
| SAS token (read + list), connection string or account key | (hidden, or a file) | A read-only SAS you make ([step 3](#3-a-read-only-sas-token-recommended)). |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| EDML mapping (a .json file or a folder of them) | the kit drafts one from the container ([step 2](#2-the-mapping)) | `./mapping` |

## Connection string you can paste

```text
https://mystorageacct.blob.core.windows.net/docs
abfss://docs@mystorageacct.dfs.core.windows.net
DefaultEndpointsProtocol=https;AccountName=mystorageacct;EndpointSuffix=core.windows.net
```

| String | Fills |
|---|---|
| `https://<account>.blob.core.windows.net/<container>` | account and container |
| `abfss://<container>@<account>.dfs.core.windows.net` | account and container |
| A storage connection string (`AccountName=...;...`) | account |

- A credential in the string is taken out and used as the connector's
  credential, and not asked again: the URL's SAS query (`?sv=...&sig=...`),
  else the connection string's `SharedAccessSignature`, else its `AccountKey`.
- Better: paste the plain URL without a SAS query, and give the SAS token at
  the hidden prompt or with `--password-file`.
- The string is optional: press Enter alone at the prompt and
  `exakit connect` asks for the fields one by one.

**Where to copy it from.** You do not build the string: Storage accounts →
`<account>` → Data storage → Containers → the container's More button
(**...**) → Container properties → URL. That gives
`https://<account>.blob.core.windows.net/<container>` and fills the account and
the container. A path after the container is not used: the mapping names the
files.

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

CSV and Parquet may leave out `mapping`; their columns are inferred. JSON needs
its fields (the [S3 guide](s3.md#2-the-mapping) has an example).

**Or let the kit draft it.** Leave the mapping empty, or give
`--set mapping=auto`. After you give the SAS token, the kit lists the container
and makes one table per folder and file type. JSON fields are typed from a
sample; CSV and Parquet are left to the adapter, as the
[S3 guide](s3.md#2-the-mapping) describes.

The draft goes to `~/.exasol-starter-kit/sources/<name>/edml/`. At the terminal
you see the tables: press Enter to use them, `e` to edit them first, or `n` to
give a mapping instead. `--set mapping=auto:<folder>/` drafts from one folder
only.

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

- A SAS opens the whole container: it cannot be narrowed to a folder. Keep data
  the database must not read in another container.
- An account key or connection string also works, but it opens every
  container, for writing too.

### 4. Open the network

Get your public IP: `curl https://checkip.amazonaws.com`. If the account's
firewall is on (`<account>` → Security + networking → Networking → Public
network access: Enabled from selected networks), add the IP under Firewall →
Address range → Save.

```bash
az storage account network-rule add -g <rg> --account-name mystorageacct --ip-address <your-ip>
```

Public network access Disabled means no access from outside a private endpoint.

## Connect

```bash
exakit connect azure-blob
```

1. Pick **Azure Blob Storage** in the Federation picker.
2. Paste a connection string (hidden), or press Enter on an empty line to type
   the fields instead. Then answer each field above.
3. The kit checks the SAS and the mapping (or drafts it after the SAS), shows a
   plan, connects, and tells you when the SAS expires.
4. The first connect also runs **Enabling Federation**: it installs Java in the
   database (one restart).

Your tables appear as `VS_AZDOCS.ORDERS`.

**Without prompts** (scripts and AI agents):

```bash
exakit connect azure-blob --name azdocs --set account=mystorageacct --set container=docs \
  --set mapping=./mapping --password-file ~/.config/exakit/azdocs-sas.txt --yes
```

- Add `--dry-run` to see the plan first.
- Leave out `--set mapping=...` and the mapping is drafted from the container;
  the connect prints its tables.

**Windows:** paste the URL or connection string at the prompt rather than
`--url`: a SAS contains `&`. For a quoted name in `exakit sql`, pipe the
statement in, or use `exakit sql --file query.sql`.

## Query

```bash
exakit sql "SELECT * FROM VS_AZDOCS.ORDERS LIMIT 10"
```

```powershell
# Windows PowerShell: pipe a statement that has quoted names
'SELECT "x" FROM VS_AZDOCS.T' | exakit sql
```

## Troubleshooting

| Error you see | Why | Fix |
|---|---|---|
| `AuthenticationFailed` | An expired SAS, a wrong key, or a SAS made for another container. | Check the container name, else `exakit source reauth azdocs --password-file <new sas>`. |
| `AuthorizationPermissionMismatch` | The SAS lacks read or list. | Make one with `rl` ([step 3](#3-a-read-only-sas-token-recommended)), then reauth. |
| `AuthorizationFailure` | The storage firewall refused you. | Allow your IP ([step 4](#4-open-the-network)). |
| "the SAS is for a single blob", "the SAS expired" | The SAS is not a valid container SAS. | Generate a container SAS ([step 3](#3-a-read-only-sas-token-recommended)). |
| A refusal with the database clock far off | The database clock drifted (after the laptop slept). | `exakit stop`, then `exakit start`. |

## Reference

**`--set` keys:** `account`, `container`, `mapping` (a path, `auto` or
`auto:<folder>/`). The SAS token, connection string or account key comes from
`--password-file` or the hidden prompt, never an argument.

**Mapping format:** EDML 2.1.0, one table per file: `source` (blob name or glob
in the container), `destinationTable`, and `mapping.fields` for JSON. See
[step 2](#2-the-mapping).

**After you connect:** `exakit source check azdocs`, `exakit source reauth
azdocs`, `exakit source remove azdocs`. A change to the mapping needs a new
connect.
