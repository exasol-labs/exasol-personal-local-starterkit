---
name: exasol-virtual-schemas
description: The shared rules for querying an external source from the local Exasol database through a virtual schema with exakit connect and exakit source, and the index of the thirteen connector skills (exasol-vs-<connector>) that hold each source's inputs, preparation and fixes. Covers the unattended command shape and its one JSON answer (ok, kind, remedy, command), passing the credential safely (a file or a closed pipe, never an argument), the "localhost inside the database is not this computer" trap, TLS and the CA PEM the four JDBC databases always need with verify, the database clock after a laptop sleeps, Windows PowerShell quoting, this computer's public IP for a cloud source, making a least-privilege reader without seeing its password, the language containers a first connect installs, exit codes and failure kinds (denied, privilege, missing_or_denied), query rules, reauth and refresh, re-pointing a source that moved to a new host, port or database (the same connect, with the credential again), disconnect versus remove, the EDML mapping S3 and Azure share, and the engine the three lakehouse routes share. Triggers — "virtual schema", "federate a remote database", "exakit connect", "exakit source", "which sources can exakit connect", "my source password changed", "the virtual schema stopped working", "my database moved to a new host", "re-point a source", "change the host of a connected source", "the source says permission denied", "remove a connected source", "join local tables with a remote database", "query Iceberg tables", "Unity Catalog", "lakehouse", "EDML mapping".
---

# Virtual schemas — the shared rules

A virtual schema exposes a remote source's tables in the local Exasol database. The data
stays at the source: each query fetches what it needs, so remote tables join local ones.
The database runs every query, even after `exakit` exits. Load the connector's own skill
below for its inputs, preparation and fixes; this one holds what they all share.

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
| `iceberg-rest` | [exasol-vs-iceberg-rest](../exasol-vs-iceberg-rest/SKILL.md) | GA | an Iceberg REST catalog |
| `unity` | [exasol-vs-unity](../exasol-vs-unity/SKILL.md) | GA | Unity Catalog, read from storage |
| `mongodb` | [exasol-vs-mongodb](../exasol-vs-mongodb/SKILL.md) | GA | one MongoDB collection |

Every connector is `candidate`: tested against a simulated database, not yet qualified
against every real server.
`exakit source catalog` is the live list. `iceberg` asks between Glue (`lakehouse`) and a
REST catalog (`iceberg-rest`); `unity-catalog` between the SQL warehouse (`databricks`)
and the engine reading storage (`unity`).

## Connect — the unattended shape

```bash
exakit connect <id> --name <name> --set key=value ... --dry-run    # the plan; changes nothing
exakit connect <id> --name <name> --set key=value ... --password-file <file> --yes --json
exakit source check <name> --json                                   # later: a fresh bounded read
```

- **Show the plan first**: its downloads, its warnings, and the **exposure** line - the
  kit's MCP read-only user can read every table of the new `VS_<NAME>`.
  `--dry-run --json` gives it as one object (`downloads`, `warnings`, `exposure`, `public_ip`).
- `--yes` consents to installing a missing Java (about 250 MiB) or Rust language
  container: a download and one database restart. Tell the user before you add it.
- **`--json` prints exactly one JSON object on stdout, on every path**, and asks nothing;
  the exit code is the one it has without `--json`. Judge the run by both. Success:
  `ok: true`, `name`, `objects`, `tables`, `example` (a first query on a real table),
  `public_ip`. Failure: `ok: false`, `error` (what happened), `kind` (its class, below),
  `remedy` (the fix, a sentence), `command` (one runnable exakit command, or null),
  `public_ip` (null when not known); `choices` for an ambiguous connector,
  `rejected: true` when the kit refused before the engine ran.
  `exakit source ... --json` fails in the same shape; `check` adds `status`. A connect's
  result has `action`: `connected`, `reconnected`, `repointed` or `unchanged` (below).
- **Act on a failure**: when `command` is not null, run it once the user agrees
  (`exakit source reauth <name>` also takes `--password-file <file>`). When it is null,
  follow `remedy` - a sentence, never something to execute. A failed first connect
  leaves nothing behind: correct the input and run the same connect again.
- **The credential** comes from `--password-file` - a pipe works too,
  `--password-file <(pass show db)` - or from a stdin pipe closed once it is written
  (`printf '%s' "$PW" | exakit connect ... --json`). Without `--password-file`, `--json`
  reads stdin to its end: a stdin left open waits forever, so add `< /dev/null` when there
  is no credential to give. `--password-stdin` (PowerShell too) reads all of stdin, terminal or not.
- Give every input with `--set`; under `--json` a missing one is `kind: input` (exit 2).
  `--url '<string>'` fills what a connection string names (JDBC URL, `postgres://`,
  `mongodb+srv://`, `s3://`, an Azure blob URL, a Glue ARN), checked like `--set`, which
  wins over it. A password in it is never used, unread parameters are dropped by name;
  prefer one without a password: other local users can read the command line.
- **Name**: the form asks "Name (alias) for this connection" (`--name`): lower case
  letters, digits and `_`, a letter first, at most 40 (`sales`). The tables appear
  as `VS_SALES`, the credential in the CONNECTION `EXAKIT_SRC_SALES`.
- `exakit connect` alone, at a terminal, opens a menu and a panel per source. An agent
  never lands in it; suggest it to a user who connects several sources by hand.
  The form marks each required field with a red `*` (a plain `*` without colour), and its
  first question takes a pasted connection string, read hidden (nothing shows while it is
  pasted; the hint lists the forms the connector reads, one per line). It is then shown
  back with every credential masked (`Read: postgres://reader:****@host/db`, `password=****`):
  Enter uses it, `e` pastes it again, Esc or `n` types the fields instead. A password in
  the string is dropped and asked for separately, hidden. A language container or
  restart the source needs is made without a question there: picking it was the permission.
  Above the menu it names the database clock: "Database clock: in sync with this
  computer.", or a warning and, at a terminal, an offer to restart the database.

## Rules that are not negotiable

- **The credential never goes on the command line.** `--password=…`, `--secret…` and
  `--token…` are refused (exit 2). Never invent, guess, echo or `cat` a credential.
- **`localhost` / `127.0.0.1` means the database itself** and is refused, with
  advice. A source on this computer is `192.168.64.1` on macOS (the launcher VM's
  gateway; `host.containers.internal` there is the VM). On Linux and WSL it is the
  address the database sees this computer at (Podman: `host.containers.internal`;
  Docker: `host.docker.internal`, which resolves inside the database to
  192.168.65.254 on Docker Desktop; a plain Docker Engine has no such name, so use
  the bridge gateway); the refusal names the one for this deployment's engine. The source must listen on
  that interface, not only on 127.0.0.1. A VPN client can still drop that traffic.
- **TLS verifies the certificate and host name by default** (`tls=verify` where a
  connector has the input). `require` only encrypts; `disable` sends credentials in
  clear. Lower it only when the user says so, and say the cost.
- **PostgreSQL, MySQL, SQL Server and Oracle always need a CA PEM with `tls=verify`**
  on Exasol Personal 2.4, even for a public CA (Let's Encrypt, DigiCert): the
  database's JDBC loader has an empty Java trust store. Without one the connect
  fails with "the trustAnchors parameter must be non-empty" (PostgreSQL, SQL Server,
  Oracle) or "Could not load trustJKS keystore from null" (MySQL). Give
  `--set ca=<PEM file or bundle>`: a public CA's root (ISRG Root X1 for Let's
  Encrypt), the RDS region bundle, a company root. SQL Server on Linux sends only its
  leaf certificate, so its PEM holds the root plus the intermediates. The plan warns
  when `verify` has no CA: do not connect past that warning.
- **"PKIX path building failed"** (MySQL: "Path does not chain with any of the trust
  anchors"): the PEM given does not sign the server - give the right one. Never answer
  it with `tls=require`: `require` encrypts without checking the certificate, so it
  needs no PEM, but it is weaker; use it only when the user accepts that. Oracle has
  no `require`. The other nine connectors need no CA file.
- **The database clock.** After a laptop sleeps, the database clock can fall behind.
  TLS then fails with "not yet valid" ("validity check failed"), and S3 and Azure (and
  Glue) signatures fail past 15 minutes of skew (kind `clock`). `connect` and `check`
  warn ("The database clock is 33 min behind this computer"). The fix: `exakit stop`,
  then `exakit start`.

## Windows PowerShell 5.1

- An argument loses its inner double quotes before exakit runs, so a query with
  quoted names must be piped or read from a file:
  `'SELECT "first_name" FROM VS_SHOP."actor"' | exakit sql`, or `exakit sql --file q.sql`.
  A query without double quotes runs as an argument, as in bash. PowerShell 7 keeps them.
- An `&` inside `--url` is split by cmd.exe (through `exakit.cmd`): paste such a
  connection string at the form's hidden prompt, or give the fields with `--set`.
  A `;` (SQL Server JDBC) is fine.
- PowerShell 5.1 pipes only ASCII to a command: give a non-ASCII credential with
  `--password-file`.

## Prepare the source

**Network.** Allow this computer's public IP at the source (security group, firewall
rule, access list, network policy - each connector skill names its own). Two
filters are easy to miss: a Snowflake login with a programmatic access token
requires a network policy on the user, and MongoDB Atlas has a project IP access
list. the database's
traffic leaves through this computer. For a source on the internet the plan says "This
computer's public IP is <ip>: <host> must allow it if it filters by address (security
group, firewall or IP access list)", `--json` carries it as `public_ip`, and the fix of
an `unreachable` or `denied` failure (connect and `check`) names it. A `privilege` or
`missing_or_denied` fix never does: the database answered, so the address was let in.
`EXAKIT_NO_IP_LOOKUP=1` skips the lookup (one HTTPS request to checkip.amazonaws.com, at
most 3 seconds). Fallback, when the IP is missing:

```bash
python3 -c "import urllib.request;print(urllib.request.urlopen('https://checkip.amazonaws.com',timeout=5).read().decode().strip())"
```

**A reader account without seeing its password.** Show the user every statement first;
run it only after they say yes. The admin sign-in is theirs (a `~/.pgpass`, a CLI
profile, a cloud login): if the client would prompt, hand them the command to run.
Generate the password straight into an owner-only file, fill it into the SQL without
printing it, and delete the filled copy:

```bash
umask 077; mkdir -p ~/.config/exakit
python3 -c 'import secrets; print("Ex1-" + secrets.token_urlsafe(18))' > ~/.config/exakit/<name>.pw
# reader.sql (from the connector skill) carries @PW@ where the password goes
python3 -c 'import sys; pw = open(sys.argv[1]).read().strip(); sys.stdout.write(open(sys.argv[2]).read().replace("@PW@", pw))' \
  ~/.config/exakit/<name>.pw reader.sql > ~/.config/exakit/<name>-reader.sql
# ... run it with the source's client (see the connector skill), then:
rm -f ~/.config/exakit/<name>-reader.sql
```

The password (28 characters: upper, lower, digit, symbol, a letter first) suits SQL
Server's and Oracle's rules, and the same file is the `--password-file`. After the
connect the database holds the credential; keep the file owner-only, or delete it -
reconnecting after a disconnect asks for it again.

## Query it

`exakit sql "SELECT * FROM VS_SALES.ORDERS LIMIT 10"`. PostgreSQL, Oracle, Snowflake,
Databricks and the lakehouse routes arrive in upper case: no quotes. MySQL, SQL Server,
BigQuery and MongoDB fields keep the source's spelling: quote them exactly
(`VS_SHOP."orders"`). `exakit source describe <name>` shows the exact names. `LIMIT`
does not guarantee the source does little work: keep remote queries selective.

## When something fails

| `kind` (exit) | Meaning | Do |
|---|---|---|
| `input` (2) | bad or missing input, named in `error` | fix that input, run the same command |
| `conflict` (3) | the name is another connector's source, or an object is taken | another name, or `exakit source remove <name>` first |
| `missing` (4) / `gated` (5) | no source by that name / the connector is not available yet | `command`: `exakit source list` / `exakit source catalog` |
| `declined` (5) | `disconnect` / `remove`, or a re-point, without `--yes`: nothing changed | ask the user; `command` is the `--yes --json` form |
| `nojava` / `norust` (21 / 23) | the Java / Rust language container is missing and was not installed | tell the user (download, one restart), then rerun with `--yes` |
| `unreachable_db` (22) | the local database does not answer | `command`: `exakit start` |
| `auth` (1) | the source rejected the credential | first connect: correct it; later: `exakit source reauth <name> --password-file <file>` |
| `tls` (1) | certificate or host name did not verify | PKIX: `--set ca`; validity: restart the database |
| `unreachable` (1) | no answer from inside the database | host, port, firewall, VPN, the `localhost` trap; allow the public IP |
| `nohost` (1) | no such host name | check the spelling (a private name may need a VPN) |
| `denied` (1) | a cloud API refused the request (an address filter answers the same) | grant what the message names; if the source filters by address, allow the IP the fix names |
| `privilege` (1) | a database took the credential, then refused a statement for a missing grant | grant the connector's minimum rights, which the fix names; then `exakit source check <name>` |
| `missing_or_denied` (1) | Oracle, Snowflake: the object does not exist for this account | the name as the source spells it (dropped or renamed since: `exakit source refresh <name>`), or grant the rights the fix names |
| `internal` (1) | a fault in the kit | `exakit logs`; report it with that |

The other kinds (`region`, `nobucket`, `clock`, `schema_missing`, `external`, `managed`,
`dns`, `setup`, `error`) are connector-specific: `remedy` says the fix, and the connector
skills name the ones they meet. The kit repairs Java without a DNS resolver (exit 20)
itself and retries once; on a Docker deployment that repair takes one database restart,
made at once for a person at a terminal and by `--yes` in a script. `exakit source list` and `issues` show a failing source's status
instead: `auth-failed`, `tls-failed`, `unreachable`, `dns-failed`, `access-denied`
(`denied`, `privilege`, `external`) or `failed`.

## Keep it working

```bash
exakit source list                 # every source and its last known state
exakit source issues               # only the failing ones, each with its fix
exakit source check <name>         # a fresh bounded read now (--all for every source)
exakit source reauth <name> --password-file <file>   # tried first; a refused one keeps the old
exakit source refresh <name>       # after tables were added or changed at the source
exakit source describe <name> [table] [--ddl --schema LOCAL]   # tables and columns, no call to the source
```

`check` is one shot, not monitoring. After `exakit update`, run `exakit source check
--all`: it moves sources to the adapter the update pins (one it could not refresh is
named, with `exakit source refresh <name>`). A tester on a staging build: `exakit
update` does not pull a staging change published at the same version; re-run the
install command instead.

## Re-point a source that moved

When a source moves to a new host, port or database, run the same connect with the
source's name, only what changed, and its credential - not `remove` and connect again:

```bash
exakit connect <id> --name <name> --set host=<new host> [--set port=...] [--set database=...] --dry-run --json
exakit connect <id> --name <name> --set host=<new host> --password-file <file> --yes --json
```

- The recorded inputs stand; what is given replaces them. A recorded CA is kept. The plan (`action: repoint`)
  lists `changes`, each `{input, from, to}`, and `credential: required`. Show it to the user.
- **The credential is always given again**, as for a first connect (a hidden prompt on a
  terminal, `--password-file` or `--password-stdin` unattended): the database never
  returns a stored one, and changing a CONNECTION's address clears it (measured on
  Exasol 2026.2). Without it: exit 2, `kind: input`, nothing changed. Never try to read
  it back out of the database.
- `VS_<NAME>` keeps its name, so saved queries and views keep working; it is refreshed in
  place for the new address's tables.
- **Tried first**: the new address is checked from inside the database, then the new
  address and credential are tried on a pending connection, before the source changes.
  Then the source's CONNECTION is swapped (the old one kept aside until the re-point is
  verified). Any failure (`unreachable`, `nohost`, `tls`, `auth`, `privilege`, ...) puts
  everything back, the CONNECTION first - the `remedy` says "nothing was changed". If
  something cannot be put back, the source is marked `failed`, and the next command on it
  (`exakit source check <name>`) tries again; so does one after a re-point interrupted
  part way (a plan then has `interrupted: true`).
- Unattended it needs `--yes`: without it `--json` changes nothing (exit 5, `kind:
  declined`; `command` is the `--yes` form when a credential flag was given, else null).
  A terminal asks, No by default.
- The same inputs and no credential: `action: unchanged`, exit 0 - or exit 1 with the
  source's own fix when it is not `ready`. A credential and nothing else: only the
  credential is replaced (as `exakit source reauth` does).
- Refused, nothing changed (exit 2): `localhost` (the rule above), a mapping, CA or TLS
  level (disconnect and connect again with them), a BigQuery source (its key is a file
  staged for it: remove and connect again), and a credential given with `--set`. A name
  another connector holds is a `conflict` (exit 3), and so is a source another command
  changed while this one ran (run it again).

## Disconnect versus remove

```bash
exakit source disconnect <name> --dry-run   # drops ONLY the CONNECTION; VS_<NAME> stays, queries fail
exakit connect <id> --name <name> --password-file <file>   # reconnects; the recorded inputs are reused
exakit source remove <name> --dry-run       # drops VS_<NAME>, its adapter and CONNECTION, and
                                            # downloaded files no other source still uses
```

Unattended: preview with `--dry-run --json`, ask the user, then run `--yes --json`.
Without `--yes` nothing changes: the answer is `kind: declined` (exit 5), its `command`
the `--yes` form. Neither touches remote data or revokes anything at the source. Ask
before removing: queries and views on `VS_<NAME>` stop working.

## The EDML mapping (S3 and Azure Blob Storage)

A file source has no tables of its own: an EDML mapping says which objects become which
table. One `.json` file per table, or a folder of them (at most 50):

```json
{"$schema": "https://schemas.exasol.com/edml-2.1.0.json",
 "source": "data/orders/*.jsonl", "destinationTable": "ORDERS",
 "mapping": {"fields": {"order_id": {"toDecimalMapping": {"decimalPrecision": 10, "decimalScale": 0}},
                        "status": {"toVarcharMapping": {"varcharColumnSize": 20}}}}}
```

- `source` is the key or glob inside the bucket or container (no `s3://`); the type comes
  from the extension: `.json` (one document per file), `.jsonl`, `.csv`, `.parquet`. CSV
  and Parquet may omit `mapping` and have columns inferred (a CSV date then arrives as
  `VARCHAR(2000000)`); JSON needs fields.
- A nested list becomes a second table (`toTableMapping`, e.g. `ORDERS_ITEMS` keyed by
  `ORDERS_ORDER_ID`); `"addSourceReferenceColumn": true` adds the object key as
  `SOURCE_REFERENCE`, and `WHERE SOURCE_REFERENCE = '...'` reads one file. The kit checks
  the mapping before anything happens.
- A glob that matches nothing is an empty table, not an error: connect and check name it
  ("No rows in EVENTS"). To change the mapping: `exakit source remove <name>`, then
  connect again.

## The lakehouse engine (lakehouse, iceberg-rest, unity)

All three routes run exasol-labs' lakehouse-engine-rs (Apache DataFusion) inside the
database. First use installs the Rust language container (the one MongoDB uses), at once
at a terminal and with `--yes` in a script: pinned per CPU, checksum-verified, one restart. Four scripts are shared by every
lakehouse source (`EXAKIT_VS.LAKEHOUSE_ADAPTER`, `LAKEHOUSE_SCAN`,
`LAKEHOUSE_DISTRIBUTE_FILES`, `LAKEHOUSE_VERSION`); the last lakehouse source of any route
removes them. `SELECT EXAKIT_VS.LAKEHOUSE_VERSION()` names the build.

- Iceberg deletes are applied (positional and deletion vectors); equality deletes, ORC
  and Avro are refused by name.
- A few results differ from native Exasol in edge cases: upper/lower case of non-ASCII
  text (`UPPER('straße')` is `STRASSE`), dates outside Exasol's range, `TO_DATE`/
  `TO_TIMESTAMP` with a format are stricter, `STDDEV`/`VARIANCE` precision. Mention them
  if a user compares results.
- **Unity Catalog** (the `unity` route, and Databricks' Iceberg REST endpoint) needs
  External Data Access on the metastore, EXTERNAL USE SCHEMA for the principal, and a
  schema on external storage: Default Storage cannot be read by outside engines.
  `iceberg-rest` works against Databricks' `https://<workspace>/api/2.1/unity-catalog/iceberg-rest`
  with a personal access token as the bearer and vended credentials.
- AWS Glue's Iceberg REST endpoint needs SigV4 signing, which `iceberg-rest` does not
  support: read Glue through `lakehouse`.
- `Fingerprint mismatch`: the Rust language container is not the version the engine was
  built for. `exakit connect` installs the pinned one; do not swap it by hand.
