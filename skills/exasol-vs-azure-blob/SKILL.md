---
name: exasol-vs-azure-blob
description: Connect JSON, CSV and Parquet blobs in an Azure Blob Storage container to local Exasol as tables with exakit connect azure-blob. Covers the inputs to collect (storage account, container, an EDML mapping, a credential) and where each is in the Azure portal, a read-and-list container SAS with an expiry written straight to a file (and why not the account key), the storage firewall that must allow this computer's public IP, the unattended connect line, queries in the bash and PowerShell forms, and the Azure-specific failures (AuthenticationFailed, permission mismatch, expired SAS, a database clock behind after sleep). Connector id azure-blob, aliases azure, abs, azure-storage, azure-blob-storage and blob-storage, tier GA. Triggers — "query files in Azure Blob Storage", "connect an Azure storage container", "Azure SAS token", "query Parquet in Azure Blob from Exasol", "exakit connect azure-blob", "AuthorizationPermissionMismatch from exakit".
---

# Azure Blob Storage files → local Exasol

Shared rules (credential handling, the EDML mapping, the `--json` answer and
failure kinds, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is Azure's own.

## 1. When to use it

JSON, JSON Lines, CSV or Parquet blobs in one container, queried as tables from
local Exasol without loading them. An EDML mapping says which blobs become
which table (`source` is the blob name or glob inside the container). The
public Azure cloud only: no custom domain, Azurite or sovereign-cloud endpoint.
Tier GA.

## 2. Fields

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `account` | yes | | Azure portal > Storage accounts: the name (3-24 lower-case letters and digits) |
| `container` | yes | | Azure portal > Storage account > Data storage > Containers |
| `mapping` | no | drafted | a mapping `.json` file on this computer, or a folder of them (at most 50); see the shared skill. Empty (or `auto`, or `auto:<folder>/ for one folder`): the kit drafts it from the container after the SAS - one table per folder and file type, JSON fields typed from a 64 KiB sample, CSV and Parquet inferred by the adapter - into `~/.exasol-starter-kit/sources/<name>/edml/` |
| `secret` | yes | | a container SAS (read + list), the account's connection string, or its account key (Storage account > Security + networking > Access keys) - only through `--password-file` or a closed stdin pipe |

The first question, "Name (alias) for this connection", is the source name
(`docs`): its tables appear in schema `VS_DOCS`.

Read-only discovery with the CLI (`--auth-mode login` needs a data role such as
Storage Blob Data Reader for the signed-in identity):

```bash
az storage account list -o table --query "[].{name:name,rg:resourceGroup,kind:kind}"
az storage container list --account-name <account> --auth-mode login --query "[].name" -o tsv
az storage blob list --account-name <account> -c <container> --prefix <prefix>/ --auth-mode login --query "[].name" -o tsv
az storage account show -n <account> --query "{firewall:networkRuleSet.defaultAction,public:publicNetworkAccess}"
```

## 3. Connection-string forms

`--url` (or the hidden paste prompt) reads:

- `https://<account>.blob.core.windows.net/<container>` - fills `account` and `container`;
- `abfss://<container>@<account>.dfs.core.windows.net` - the same;
- `AccountName=...;AccountKey=...` - fills `account`.

The path after the container is not used. A credential in the string is the
connector's: the URL's SAS query (`?sv=...&sig=...`), else the connection
string's `SharedAccessSignature`, else its `AccountKey`. It is taken out of the
string (never stored, logged or shown) and not asked again - paste it at the
hidden prompt; `--password-file` or `--password-stdin` given too wins. A SAS
carries `&`, so never give it in an argument: on Windows cmd.exe splits an
argument at `&` on its way through `exakit.cmd`. The `;` of a connection string
is fine.

## 4. Prepare the source (recommended: a container SAS; show, then run on a yes)

Read (`r`) and list (`l`) only, an expiry, HTTPS only, straight into a file
(portal: Container > Shared access tokens):

```bash
umask 077; mkdir -p ~/.config/exakit
az storage container generate-sas --account-name <account> -n <container> --permissions rl \
  --expiry <YYYY-MM-DD> --https-only --auth-mode key -o tsv > ~/.config/exakit/<name>-sas.txt
```

- Without the account key, a user-delegation SAS: replace `--auth-mode key`
  with `--as-user --auth-mode login` (at most 7 days).
- The kit checks a SAS on this computer before anything is created: a signature,
  read and list permission, not expired, HTTPS allowed, a container SAS (`sr=c`,
  not one blob or directory).
- A SAS cannot be narrowed to a folder: it opens the whole container. Keep data
  the database must not read in another container.
- An account key or connection string also works, but opens every container of
  the account, for writing too - the kit says so.

**Network.** The kit always reaches `https://<account>.blob.core.windows.net`.
If `firewall` above is `Deny` (portal: Storage account > Security + networking >
Networking), the account must allow this computer's public IP, which
`exakit connect` shows. A change at the source, run only after a yes:

```bash
az storage account network-rule add --resource-group <rg> --account-name <account> --ip-address <public-ip>
```

`public` `Disabled` means no access from outside a private endpoint at all.

## 5. TLS

No CA file and no TLS input: the connection is always verified HTTPS to Azure.

**The clock matters.** After a laptop sleeps, the database clock can fall
behind. Azure refuses a request signed with a key or SAS more than 15 minutes
off, and the failure is kind `clock`. `exakit connect` shows "Database clock:
in sync with this computer." or a warning with an offer to restart. The fix is
`exakit stop`, then `exakit start`.

## 6. Connect

```bash
exakit connect azure-blob --name docs --set account=<account> --set container=<container> \
  --set mapping=./mapping --dry-run
exakit connect azure-blob --name docs --set account=<account> --set container=<container> \
  --set mapping=./mapping --password-file ~/.config/exakit/docs-sas.txt --yes --json
```

PowerShell takes the same line on one row, with
`$HOME\.config\exakit\docs-sas.txt` as the file. Connect prints when the SAS
expires. First use installs the Java language container (`--yes`, one
restart): tell the user first.

No mapping yet: leave out `--set mapping` and the connect drafts one from the
container and prints its tables (Table, Files, Format, Columns); a SAS without
list (l) cannot. The draft lives in `~/.exasol-starter-kit/sources/<name>/edml/`;
to change it later, copy the folder elsewhere first (remove deletes it with the
source), edit, then remove and connect again with `--set mapping=<the copy>`.

## 7. Verify and query

```bash
exakit source check docs          # one row from each table (up to 25); names any that are empty
exakit source describe docs
exakit sql 'SELECT * FROM VS_DOCS.CUSTOMERS LIMIT 10'
exakit sql 'SELECT COUNTRY, COUNT(*) FROM VS_DOCS.CUSTOMERS GROUP BY COUNTRY'
```

Windows PowerShell 5.1 drops the inner double quotes of an argument. A query
with a quoted name is piped in, or saved to a file:

```powershell
'SELECT "SOURCE_REFERENCE", COUNT(*) FROM VS_DOCS.CUSTOMERS GROUP BY 1' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

- Tables are the mapping's `destinationTable` in upper case; columns are named
  by the mapping. A nested list becomes a child table.
- A CSV mapping without fields has its columns inferred, and a date then arrives
  as `VARCHAR(2000000)`: name the fields and their types to get typed columns.
- JSON needs explicit fields. The file type comes from the extension (`.json`,
  `.jsonl`, `.csv`, `.parquet`). The mapping format is in the shared skill.

## 9. When it fails

| Message (`kind`) | Fix |
|---|---|
| `AuthenticationFailed` (`auth`) | a wrong key, an expired SAS - or a SAS made for another container (a wrong container name reads the same): check the name, else `exakit source reauth docs --password-file <new-sas.txt>` |
| `AuthorizationPermissionMismatch` (`denied`) | the SAS lacks a permission: a new one with `rl`, then reauth |
| `AuthorizationFailure` (`denied`) | the account refused the request - the storage firewall answers so: allow the public IP the fix names (section 4) |
| `ContainerNotFound` (`nobucket`) | no container by that name: check it, remove and connect again |
| "Signature not yet current", "Signature expired" (`clock`) | the database clock is off by more than 15 minutes: `exakit stop`, then `exakit start`, then `exakit source check docs` |
| "the SAS lacks ... permission", "the SAS expired at ...", "the SAS is for a single blob or directory" | generate a container SAS as in section 4 |
| "a development-storage (Azurite) connection string", "endpoint suffix ... is a sovereign cloud" | not reached by this connector |
| "No rows in X" | the mapping's `source` matches no blobs, or they are empty: check the glob |
| "E-VSD-102: Schema auto inference ... failed - caused by ..." | act on the cause after "caused by" |

## 10. Keep it working

- A SAS expires: generate a new one (section 4), then
  `exakit source reauth docs --password-file ~/.config/exakit/docs-sas.txt`.
  It is tried first; a refused one keeps the old.
- Another account or container: `exakit connect azure-blob --name docs --set
  container=<new> --password-file <file> --yes` (`--dry-run` first). `VS_DOCS`
  keeps its name, and the credential is asked for again, as for every re-point.
- A changed mapping cannot be re-pointed in place: `exakit source remove docs`,
  then connect again.
- Stop: `exakit source disconnect docs` or `exakit source remove docs`
  (`--dry-run` first, then ask) - see the shared skill.
