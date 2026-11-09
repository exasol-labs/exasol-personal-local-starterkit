---
name: exasol-vs-azure-blob
description: Connect JSON, CSV and Parquet blobs in an Azure Blob Storage container to local Exasol as tables with exakit connect azure-blob. Covers the inputs to collect (storage account, container, an EDML mapping, a credential), finding them with the Azure CLI, a read-and-list container SAS with an expiry written straight to a file (and why not the account key), the storage firewall that must allow this computer's public IP, the unattended connect line, and the Azure-specific failures (AuthenticationFailed, permission mismatch, expired SAS). Connector id azure-blob, aliases azure, abs, azure-storage, azure-blob-storage and blob-storage, tier GA. Triggers — "query files in Azure Blob Storage", "connect an Azure storage container", "Azure SAS token", "query Parquet in Azure Blob from Exasol", "exakit connect azure-blob", "AuthorizationPermissionMismatch from exakit".
---

# Azure Blob Storage files → local Exasol

Shared rules (credential handling, the EDML mapping, the `--json` answer and
failure kinds, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is Azure's own.

## 1. When to use it

JSON, JSON Lines, CSV or Parquet blobs in one container to query as tables from
local Exasol without loading them. An EDML mapping (see the shared skill) says
which blobs become which table (`source` is the blob name or glob inside the
container). The public Azure cloud only: no custom domain, Azurite or
sovereign-cloud endpoint. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `account` | yes | | azure-account | the storage account name (3-24 lower-case letters and digits) |
| `container` | yes | | azure-container | the container name |
| `mapping` | yes | | edml | a mapping `.json` file on this computer, or a folder of them |
| `secret` | yes | | secret | a container SAS (read + list), the account's connection string, or its account key - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
az storage account list -o table --query "[].{name:name,rg:resourceGroup,kind:kind}"
az storage container list --account-name <account> --auth-mode login --query "[].name" -o tsv
az storage blob list --account-name <account> -c <container> --prefix <prefix>/ --auth-mode login --query "[].name" -o tsv
az storage account show -n <account> --query "{firewall:networkRuleSet.defaultAction,public:publicNetworkAccess}"
```

`--auth-mode login` needs a data role (Storage Blob Data Reader) for the
signed-in identity. A URL fills account and container:
`--url 'https://<account>.blob.core.windows.net/<container>'` or
`--url 'abfss://<container>@<account>.dfs.core.windows.net'`; the path after
the container is not used.

## 4. Prepare the credential (recommended: a container SAS; show, then run on a yes)

Read (`r`) and list (`l`) only, an expiry, HTTPS only, straight into a file:

```bash
umask 077; mkdir -p ~/.config/exakit
az storage container generate-sas --account-name <account> -n <container> --permissions rl \
  --expiry <YYYY-MM-DD> --https-only --auth-mode key -o tsv > ~/.config/exakit/<name>-sas.txt
```

Without access to the account key, a user-delegation SAS: replace
`--auth-mode key` with `--as-user --auth-mode login` (at most 7 days). The kit
checks a SAS before anything is created: read and list permission, not expired,
a container SAS (not one blob). A SAS cannot be narrowed to a folder: it opens
the whole container, so data the database must not read belongs in another
container. An account key or connection string also works, but opens every
container of the account, for writing too - the kit says so.

## 5. Network

The kit always reaches `https://<account>.blob.core.windows.net`. If
`firewall` above is `Deny`, the account must allow this computer's public IP
(`exakit connect` shows it; fallback: the `python3` one-liner in the shared
skill) - a change at the source, run only after a yes:

```bash
az storage account network-rule add --resource-group <rg> --account-name <account> --ip-address <public-ip>
```

`public` `Disabled` means no access from outside a private endpoint at all.

## 6. Connect

```bash
exakit connect azure-blob --name docs --set account=<account> --set container=<container> \
  --set mapping=./mapping --dry-run
exakit connect azure-blob --name docs --set account=<account> --set container=<container> \
  --set mapping=./mapping --password-file ~/.config/exakit/docs-sas.txt --yes --json
```

Connect prints when the SAS expires. The tables appear as
`VS_DOCS.<destinationTable in upper case>`.

## 7. Verify

```bash
exakit source check docs          # one row from each table (up to 25); names any that are empty
exakit source describe docs
exakit sql "SELECT * FROM VS_DOCS.CUSTOMERS LIMIT 10"
```

## 8. When it fails

| Message | Fix |
|---|---|
| `AuthenticationFailed` | a wrong key, an expired SAS - or a SAS made for another container (a SAS is valid only for its container, so a wrong container name reads the same): check the name, else `exakit source reauth docs --password-file <new-sas.txt>` |
| `AuthorizationPermissionMismatch` (`denied`) | the SAS lacks a permission: a new one with `rl`, then reauth |
| `AuthorizationFailure` (`denied`) | the account refused the request - the storage firewall answers so: if `firewall` is `Deny`, allow the public IP the fix names (section 5) |
| `ContainerNotFound` | no container by that name: check it, remove and connect again |
| "the SAS lacks read (r) ... permission", "the SAS expired at ...", "the SAS is for a single blob" | generate a container SAS as in section 4 |
| "a development-storage (Azurite) connection string", "endpoint suffix ... is a sovereign cloud" | not reached by this connector |
| "No rows in X" | the mapping's `source` matches no blobs: check the glob |
| "E-VSD-102: Schema auto inference ... failed - caused by ..." | act on the cause after "caused by" |
| a refusal with the database clock far off | signed requests allow 15 minutes: `exakit stop`, then `exakit start` |

## 9. Keep it working

- A SAS expires: generate a new one (section 4), then
  `exakit source reauth docs --password-file ~/.config/exakit/docs-sas.txt`
  (a refused one keeps the old).
- A changed mapping: `exakit source remove docs`, then connect again.
- Stop: `exakit source disconnect docs` or `exakit source remove docs`
  (`--dry-run` first, then ask) - see the shared skill.
