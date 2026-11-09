---
name: exasol-virtual-schemas
description: The shared rules for querying an external source from the local Exasol database through a virtual schema with exakit connect and exakit source, and the index of the thirteen connector skills (exasol-vs-<connector>) that hold each source's inputs, preparation and fixes. Covers the unattended command shape, passing the credential safely (never as an argument), the "localhost inside the database is not this computer" trap, TLS and a private CA, this computer's public IP for a cloud source, making a least-privilege reader without seeing its password, the language containers a first connect installs, exit codes and failure classes, query rules, reauth and refresh, disconnect versus remove, the EDML mapping S3 and Azure share, and the engine the three lakehouse routes share. Triggers — "virtual schema", "federate a remote database", "exakit connect", "exakit source", "which sources can exakit connect", "my source password changed", "the virtual schema stopped working", "remove a connected source", "join local tables with a remote database", "query Iceberg tables", "Unity Catalog", "lakehouse", "EDML mapping".
---

# Virtual schemas — the shared rules

A virtual schema exposes a remote source's tables in the local Exasol database.
The data stays at the source: each query fetches what it needs, so remote
tables join local ones. The kit sets the connection up; the database runs every
query, even after `exakit` exits. Load the connector's own skill below for its
inputs, preparation and fixes; this one holds what they all share.

## The connector skills

| Connector id | Skill | Tier | Source |
|---|---|---|---|
| `postgresql` | [exasol-vs-postgresql](../exasol-vs-postgresql/SKILL.md) | GA | PostgreSQL, RDS/Aurora, Azure |
| `mysql` | [exasol-vs-mysql](../exasol-vs-mysql/SKILL.md) | GA | MySQL or MariaDB |
| `sqlserver` | [exasol-vs-sqlserver](../exasol-vs-sqlserver/SKILL.md) | GA | SQL Server, Azure SQL, RDS |
| `oracle` | [exasol-vs-oracle](../exasol-vs-oracle/SKILL.md) | GA | Oracle (thin driver) |
| `snowflake` | [exasol-vs-snowflake](../exasol-vs-snowflake/SKILL.md) | GA | a Snowflake schema |
| `bigquery` | [exasol-vs-bigquery](../exasol-vs-bigquery/SKILL.md) | GA | a BigQuery dataset |
| `s3` | [exasol-vs-s3](../exasol-vs-s3/SKILL.md) | GA | JSON, CSV, Parquet files in a bucket |
| `azure-blob` | [exasol-vs-azure-blob](../exasol-vs-azure-blob/SKILL.md) | GA | the same, in an Azure container |
| `databricks` | [exasol-vs-databricks](../exasol-vs-databricks/SKILL.md) | GA | a Unity Catalog schema, via a SQL warehouse |
| `lakehouse` | [exasol-vs-lakehouse](../exasol-vs-lakehouse/SKILL.md) | GA | Iceberg tables in AWS Glue |
| `iceberg-rest` | [exasol-vs-iceberg-rest](../exasol-vs-iceberg-rest/SKILL.md) | Beta | an Iceberg REST catalog |
| `unity` | [exasol-vs-unity](../exasol-vs-unity/SKILL.md) | Beta | Unity Catalog, read from storage |
| `mongodb` | [exasol-vs-mongodb](../exasol-vs-mongodb/SKILL.md) | GA | one MongoDB collection |

Every connector is `candidate`: defined and tested against a simulated
database, not yet qualified against every real server. Beta means not yet run
against a live source. `exakit source catalog` is the live list. `iceberg`
asks whether Glue (`lakehouse`) or a REST catalog (`iceberg-rest`) is meant;
`unity-catalog` asks between the SQL warehouse (`databricks`) and the engine
reading storage (`unity`).

## Connect — the unattended shape

```bash
exakit connect <id> --name <name> --set key=value ... --dry-run   # the plan; changes nothing
exakit connect <id> --name <name> --set key=value ... --password-file <file> --yes
exakit source check <name> --json                                  # did it work: one JSON object
```

- **Show the plan first**: what it downloads, its warnings, and the
  **exposure** line - the kit's MCP read-only user can read every table of the
  new `VS_<NAME>`.
- `--yes` answers "Connect now?" and also consents to installing a missing
  Java (about 250 MiB) or Rust language container: a download and one
  database restart. Say that to the user before you add it.
- Judge a connect by its exit code (0 done; the table below) and then
  `exakit source check <name>`. `exakit connect` prints lines (`OK`, `INFO`,
  `WARN`, errors) and ends with "Query it like any schema: SELECT ..." on a
  real table; `--json` on `exakit connect` does not give a JSON document today.
  `exakit source list`, `show <name>` and `check <name>` take `--json` and
  print one object.
- Give every input with `--set`. Where the agent's shell has a terminal, an
  input left out is asked for there.
- `--url '<string>'` fills the inputs a connection string names (JDBC URL,
  `postgres://`, `mongodb+srv://`, `s3://`, an Azure blob URL, a Glue ARN),
  each checked like a `--set`; an explicit `--set` wins. A password in it is
  never used, and parameters the kit does not read are dropped by name. Prefer
  a string without a password: the command line is visible to other local
  users.
- **Name**: lower case letters, digits and `_`, a letter first, at most 40
  (`sales`). The tables appear as `VS_SALES`; the credential lives in the
  database's CONNECTION `EXAKIT_SRC_SALES`.
- On Windows PowerShell the flags are the same; give the credential with
  `--password-file` (the credential is never read from standard input there).
- A person at a terminal can type `exakit connect` alone: a menu of the
  connectors (Space ticks several), one panel per source with each answer
  checked as it is typed, a review, then one table that follows every source
  to `VS_<NAME>`. It needs a terminal on standard input, so an agent never
  lands in it; suggest it to a user who connects several sources by hand.

## Rules that are not negotiable

- **The credential never goes on the command line.** `--password=…`,
  `--secret…` and `--token…` are refused (exit 2). Use `--password-file`
  (or standard input on macOS and Linux). Never invent, guess, echo or `cat`
  a credential.
- **`localhost` / `127.0.0.1` means the database itself** and is refused. A
  source on this computer is reached at `192.168.64.1` on macOS (the launcher
  VM's gateway; `host.containers.internal` there is the VM) and at
  `host.containers.internal` on Linux and WSL, and must listen on that
  interface, not only on 127.0.0.1. A VPN client can still drop that traffic.
- **TLS verifies the certificate and host name by default** (`tls=verify`
  where a connector has the input). `require` only encrypts; `disable` sends
  credentials in clear. Lower it only when the user says so, and say the cost.
- **A private CA is trusted, not skipped.** RDS, Azure and company servers
  sign with a CA Java does not hold: "PKIX path building failed" (MySQL: "Path
  does not chain with any of the trust anchors"). PostgreSQL, MySQL, SQL Server
  and Oracle take `--set ca=<PEM file or bundle>`; for RDS the region's bundle,
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`.
  "the trustAnchors parameter must be non-empty" is Exasol Personal's JDBC
  loader having no CA store: the same `--set ca` fixes it, a public CA's root
  too. Never answer a PKIX error with `tls=require`.
- **"validity check failed"** with a certificate in date means the database
  clock is behind (after the laptop slept). `connect` and `check` warn ("The
  database clock is 33 min behind this computer"). `exakit stop`, then
  `exakit start`. Signed requests (S3, Glue, Azure) are refused past 15
  minutes of skew; the kit then names the clock as the cause.

## Prepare the source

**Network.** `exakit connect` shows this computer's public IP; allow that
address at the source (security group, firewall rule, access list, network
policy - each connector skill names its own). The database's traffic leaves
through this computer, so that is the address a source on the internet sees.
For such a source the plan (`--dry-run` too) prints "This computer's public IP
is <ip>: <host> must allow it if it filters by address (security group,
firewall or IP access list)", and the fix of an `unreachable` or
`access-denied` failure (connect and `exakit source check`) names the same
address. `EXAKIT_NO_IP_LOOKUP=1` skips the lookup (one HTTPS request to
checkip.amazonaws.com, at most 3 seconds). Fallback, when the line is missing:

```bash
python3 -c "import urllib.request;print(urllib.request.urlopen('https://checkip.amazonaws.com',timeout=5).read().decode().strip())"
```

**A reader account without seeing its password.** Show the user every
statement first; run it only after they say yes. The admin sign-in is theirs
(a `~/.pgpass`, a CLI profile, a cloud login): if the client would prompt,
hand them the command to run. Generate the password straight into an
owner-only file, fill it into the SQL without printing it, and delete the
filled copy:

```bash
umask 077; mkdir -p ~/.config/exakit
python3 -c 'import secrets; print("Ex1-" + secrets.token_urlsafe(18))' > ~/.config/exakit/<name>.pw
# reader.sql (from the connector skill) carries @PW@ where the password goes
python3 -c 'import sys; pw = open(sys.argv[1]).read().strip(); sys.stdout.write(open(sys.argv[2]).read().replace("@PW@", pw))' \
  ~/.config/exakit/<name>.pw reader.sql > ~/.config/exakit/<name>-reader.sql
# ... run it with the source's client (see the connector skill), then:
rm -f ~/.config/exakit/<name>-reader.sql
```

The password (28 characters: upper, lower, digit, symbol, a letter first) suits
SQL Server's and Oracle's rules. The same file is the `--password-file`. After
the connect the database holds the credential; keep the file owner-only, or
delete it - reconnecting after a disconnect asks for it again.

## Query it

```bash
exakit sql "SELECT * FROM VS_SALES.ORDERS LIMIT 10"
```

PostgreSQL, Oracle, Snowflake, Databricks and the lakehouse routes arrive in
upper case: no quotes. MySQL, SQL Server, BigQuery and MongoDB fields keep the
source's spelling: quote them exactly (`VS_SHOP."orders"`). `exakit source
describe <name>` shows the exact names. `LIMIT` does not guarantee the source
does little work: keep remote queries selective.

## When something fails

| Exit / status | Meaning | Do |
|---|---|---|
| 2 | bad input (named) | fix that input |
| 3 | name or object conflict | another name, or `exakit source remove <name>` first |
| 4 | no source by that name | `exakit source list` |
| 5 | gated, or not confirmed (`disconnect`/`remove` without `--yes`) | nothing changed: ask the user, then `--yes` |
| 21 / 23 | the Java / Rust language container is missing and was not installed | tell the user (download, one restart), then rerun with `--yes` |
| 22 | the local database does not answer | `exakit start` |
| `auth-failed` | the source rejected the credential | `exakit source reauth <name> --password-file <file>` |
| `tls-failed` | certificate or host name did not verify | PKIX: `--set ca`; validity: restart the database |
| `unreachable` | no answer from inside the database | host, port, firewall, VPN, the `localhost` trap; the fix names the public IP to allow |
| "does not resolve" | no such host name | check the spelling (a private name may need a VPN) |
| `access-denied` | signed in, may not read (the message names the action) | grant it, then `exakit source check <name>` |

A failed **first** connect leaves nothing behind: rerun it with corrected
input. The kit repairs Java without a DNS resolver (exit 20) itself and
retries once.

## Keep it working

```bash
exakit source list                 # every source and its last known state
exakit source issues               # only the failing ones, each with its fix
exakit source check <name>         # a fresh bounded read now (--all for every source)
exakit source reauth <name> --password-file <file>   # tried first; a refused one keeps the old
exakit source refresh <name>       # after tables were added or changed at the source
exakit source describe <name> [table] [--ddl --schema LOCAL]   # tables and columns, no call to the source
```

`check` is one shot, not monitoring. After `exakit update`, run `exakit source
check --all`: it moves sources to the adapter the update pins (one it could not
refresh is named, with `exakit source refresh <name>`).

## Disconnect versus remove

```bash
exakit source disconnect <name> --dry-run   # drops ONLY the CONNECTION; VS_<NAME> stays, queries fail
exakit connect <id> --name <name> --password-file <file>   # reconnects; the recorded inputs are reused
exakit source remove <name> --dry-run       # drops VS_<NAME>, its adapter and CONNECTION, and
                                            # downloaded files no other source still uses
```

Both preview, then ask; `--yes` answers for a script the user told to. Neither
touches remote data or revokes anything at the source. Ask before removing:
queries and views on `VS_<NAME>` stop working.

## The EDML mapping (S3 and Azure Blob Storage)

A file source has no tables of its own: an EDML mapping says which objects
become which table. One `.json` file per table, or a folder of them (at most 50):

```json
{"$schema": "https://schemas.exasol.com/edml-2.1.0.json",
 "source": "data/orders/*.jsonl", "destinationTable": "ORDERS",
 "mapping": {"fields": {"order_id": {"toDecimalMapping": {"decimalPrecision": 10, "decimalScale": 0}},
                        "status": {"toVarcharMapping": {"varcharColumnSize": 20}}}}}
```

- `source` is the key or glob inside the bucket or container (no `s3://`); the
  type comes from the extension: `.json` (one document per file), `.jsonl`,
  `.csv`, `.parquet`. CSV and Parquet may omit `mapping` and have columns
  inferred (a CSV date then arrives as `VARCHAR(2000000)`); JSON needs fields.
- A nested list becomes a second table (`toTableMapping`, e.g. `ORDERS_ITEMS`
  keyed by `ORDERS_ORDER_ID`); `"addSourceReferenceColumn": true` adds the
  object key as `SOURCE_REFERENCE`, and `WHERE SOURCE_REFERENCE = '...'` reads
  one file. The kit checks the mapping before anything happens.
- A glob that matches nothing is an empty table, not an error: connect and
  check name it ("No rows in EVENTS").
- To change the mapping: `exakit source remove <name>`, then connect again.

## The lakehouse engine (lakehouse, iceberg-rest, unity)

All three routes run exasol-labs' lakehouse-engine-rs (Apache DataFusion)
inside the database. First use installs the Rust language container (the one
MongoDB uses) after asking: pinned per CPU, checksum-verified, one restart.
Four scripts are shared by every lakehouse source (`EXAKIT_VS.LAKEHOUSE_ADAPTER`,
`LAKEHOUSE_SCAN`, `LAKEHOUSE_DISTRIBUTE_FILES`, `LAKEHOUSE_VERSION`); the last
lakehouse source of any route removes them. `SELECT EXAKIT_VS.LAKEHOUSE_VERSION()`
names the build.

- Iceberg deletes are applied (positional and deletion vectors); equality
  deletes, ORC and Avro are refused by name.
- A few results differ from native Exasol in edge cases: upper/lower case of
  non-ASCII text (`UPPER('straße')` is `STRASSE`), dates outside Exasol's
  range, `TO_DATE`/`TO_TIMESTAMP` with a format are stricter, and
  `STDDEV`/`VARIANCE` precision. Mention them if a user compares results.
- `Fingerprint mismatch`: the Rust language container is not the version the
  engine was built for. `exakit connect` installs the pinned one; do not swap
  the container by hand.
