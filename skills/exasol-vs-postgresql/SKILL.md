---
name: exasol-vs-postgresql
description: Connect PostgreSQL to local Exasol as a virtual schema with exakit connect postgresql. Covers the inputs and where each is in the AWS, Azure or Google Cloud console, the connection-string forms, a least-privilege reader role, allowing this computer's public IP, the CA PEM that tls=verify always needs on Exasol Personal 2.4 (RDS bundle, Azure root, a public root such as ISRG Root X1), the unattended connect line, queries for bash and Windows PowerShell, and the PostgreSQL-specific failures (trustAnchors, PKIX, domain columns, NUMERIC as text). Connector id postgresql, aliases pg, postgres and pgsql, tier GA. Triggers — "connect my Postgres to Exasol", "query PostgreSQL from Exasol", "connect RDS Postgres to Exasol", "query Aurora PostgreSQL from Exasol", "Azure Database for PostgreSQL in Exasol", "add a Postgres source", "exakit connect postgresql", "exakit connect pg", "PKIX path building failed for Postgres".
---

# PostgreSQL → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds, the
reader-password recipe, re-point, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is PostgreSQL's own.

## 1. When to use it

A PostgreSQL database - self-hosted, Amazon RDS or Aurora PostgreSQL, Azure
Database for PostgreSQL, Google Cloud SQL - whose tables should be queryable
from local Exasol without copying them. One source is one schema of one
database; connect again with another `--name` for the next schema. Adapter
4.1.0 with pgJDBC 42.7.14.

## 2. The fields and where to find them

The form first asks "Name (alias) for this connection" (`--name`, lower case,
e.g. `sales`): the tables appear as `VS_SALES`.

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `host` | yes | | RDS: console > RDS > Databases > *db* > Connectivity & security > Endpoint. Azure: portal > Azure Database for PostgreSQL flexible server > Overview > Server name. Cloud SQL: console > SQL > *instance* > Overview > Public IP address. Never `localhost` (section 5) |
| `port` | no | 5432 | the same page (RDS: Port) |
| `database` | yes | | RDS: Configuration > DB name (often `postgres`); `psql -c '\l'` lists them |
| `schema` | no | `public` | `psql -c '\dn'`; PostgreSQL folds an unquoted name to lower case |
| `user` | yes | | the reader account (section 4) |
| `password` | yes | | its password - only through `--password-file` or `--password-stdin` |
| `tls` | no | `verify` | `verify`, `require` or `disable` (section 6) |
| `ca` | no | | a PEM file or bundle - required in practice with `verify` (section 6) |

Read-only discovery with a CLI:

```bash
aws rds describe-db-instances --output table --query "DBInstances[?contains(Engine,'postgres')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,db:DBName,public:PubliclyAccessible,sg:join(',',VpcSecurityGroups[].VpcSecurityGroupId)}"
aws rds describe-db-clusters --output table --query "DBClusters[?Engine=='aurora-postgresql'].{id:DBClusterIdentifier,writer:Endpoint,reader:ReaderEndpoint,port:Port}"
az postgres flexible-server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName}"
psql "host=<host> port=5432 dbname=<database> user=<admin>" -c '\l' -c '\dn' -c '\dt <schema>.*'
```

Aurora's reader endpoint suits a read-only source.

## 3. Connection-string forms

The form's first question, and `--url '<string>'`, read:

- `jdbc:postgresql://host:5432/db`
- `postgres://user@host:5432/db` (also `postgresql://`)
- `host[:port][/database]`

`currentSchema` fills `schema`, `user` fills `user`, `sslmode` fills `tls`
(`verify-full` and `verify-ca` are `verify`; `require` and `prefer` are
`require`; `disable`). A password in the string is dropped and asked for
separately. `--set` wins over the string.

On Windows an `&` inside `--url` is split by cmd.exe (through `exakit.cmd`), so
a string with two parameters breaks there: paste it at the form's hidden prompt,
or give the fields with `--set`.

## 4. Prepare a reader at the source (show, then run on a yes)

`reader.sql`, filled with the shared recipe (`@PW@` becomes the generated password):

```sql
CREATE ROLE exakit_reader LOGIN PASSWORD '@PW@';
GRANT CONNECT ON DATABASE <database> TO exakit_reader;
GRANT USAGE ON SCHEMA <schema> TO exakit_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA <schema> TO exakit_reader;
-- tables the admin running this creates later:
ALTER DEFAULT PRIVILEGES IN SCHEMA <schema> GRANT SELECT ON TABLES TO exakit_reader;
```

```bash
psql "host=<host> dbname=<database> user=<admin>" -v ON_ERROR_STOP=1 -f ~/.config/exakit/<name>-reader.sql
rm -f ~/.config/exakit/<name>-reader.sql
```

## 5. Network

`exakit connect` names this computer's public IP; allow it at the source. Each
change is at the source: show it, run it only after a yes.

- **RDS / Aurora**: Publicly accessible must be Yes, and a security group
  (Connectivity & security > VPC security groups) must allow TCP 5432 from the IP:
  `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port 5432 --cidr <public-ip>/32`
- **Azure** (portal > server > Networking > Firewall rules):
  `az postgres flexible-server firewall-rule create --resource-group <rg> --name <server> --rule-name exakit --start-ip-address <public-ip> --end-ip-address <public-ip>`
- **Cloud SQL** (Connections > Networking > Authorized networks):
  `gcloud sql instances patch <instance> --authorized-networks=<existing>,<public-ip>/32` -
  the flag replaces the whole list, so repeat the existing entries.
- **On this computer**: `localhost` is refused (inside the database it is the
  database). Use `192.168.64.1` on macOS; on Linux and WSL with Podman
  `host.containers.internal`; with Docker `host.docker.internal` (192.168.65.254
  inside the database on Docker Desktop). `listen_addresses` must cover that
  interface and `pg_hba.conf` must accept the address the connection comes from.

## 6. TLS and the CA file

- **`verify` always needs `ca` on Exasol Personal 2.4**, even for a public CA:
  the database's JDBC loader has an empty Java trust store, and the connect fails
  with "the trustAnchors parameter must be non-empty". The form's CA prompt says
  "Enter to skip"; with `verify` do not skip it.
- What to give: RDS / Aurora, the region's bundle
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`; Azure,
  the root CA its TLS documentation names; a public CA, its root (Let's Encrypt:
  ISRG Root X1); a company CA, its root. A download: ask first.
- From a bundle the kit picks the one certificate that signs the server (a
  verified handshake from this computer, host name checked) and sends it inside
  the JDBC URL (`SingleCertValidatingFactory`), because the loader's Java sandbox
  cannot read a file.
- `require` encrypts without checking the certificate: no PEM, but weaker - only
  when the user accepts that. `disable` sends the password in clear. `ca` with a
  level other than `verify` is refused.

## 7. Connect

```bash
exakit connect postgresql --name sales --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader --set ca=~/.config/exakit/rds-<region>-bundle.pem --dry-run
exakit connect postgresql --name sales --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader --set ca=~/.config/exakit/rds-<region>-bundle.pem \
  --password-file ~/.config/exakit/sales.pw --yes --json
```

PowerShell takes the same line on one line, with `--password-file
$HOME\.config\exakit\sales.pw` and `--set ca=$HOME\.config\exakit\<ca>.pem`.

## 8. Verify and query

```bash
exakit source check sales          # a fresh bounded read; exit 0 when ready
exakit source describe sales       # tables and columns as Exasol sees them
```

Names arrive in upper case, so most queries need no quotes and run the same on
every shell:

```bash
exakit sql 'SELECT * FROM VS_SALES.ORDERS LIMIT 10'
exakit sql 'SELECT STATUS, COUNT(*) AS N FROM VS_SALES.ORDERS GROUP BY STATUS'
```

A query with a double-quoted name, in Windows PowerShell 5.1 (it drops the
inner double quotes of an argument): pipe it, or use `--file`.

```powershell
'SELECT "ORDER_ID", CAST("AMOUNT" AS DECIMAL(10,2)) FROM VS_SALES."ORDERS" LIMIT 10' | exakit sql
exakit sql --file .\orders.sql
```

## 9. Names and types

- Names arrive in upper case (`FILM`, `TITLE`): query them without quotes.
- `NUMERIC` arrives as `VARCHAR`: cast it to compute,
  `CAST(RENTAL_RATE AS DECIMAL(10,2))`.
- A column of a domain type (pagila's `FILM.RELEASE_YEAR`) or an extension type
  such as `vector` fails every query that reads it (ETL-1299), and `BYTEA` reads
  as the text `bytea NOT SUPPORTED`: name the other columns instead of `*`.
- Array columns are missing, and a partitioned table shows only its partitions.

## 10. When it fails

| Message | Fix |
|---|---|
| "the trustAnchors parameter must be non-empty" | `tls=verify` without a CA: connect again with `--set ca=<PEM>`, a public CA's root too (section 6) |
| "PKIX path building failed" | the PEM does not sign this server: give the right root or the RDS region bundle; never `tls=require` instead |
| "validity check failed", "not yet valid" | the database clock is behind (the laptop slept): `exakit stop`, then `exakit start` |
| "the source has no schema X, but it has Y" | PostgreSQL folds unquoted names to lower case: `--set schema=Y` |
| "permission denied for table X" (or `schema`, `database`) (`privilege`) | grant CONNECT, USAGE and SELECT (section 4), then `exakit source check sales` |
| "password authentication failed" (`auth`) | wrong user or password; later: `exakit source reauth sales --password-file <file>` |
| "The connection attempt failed", "connect timed out" (`unreachable`) | security group, firewall, Publicly accessible, port, the `localhost` trap (section 5) |

## 11. Keep it working

- New password: `ALTER ROLE exakit_reader PASSWORD '@PW@'` with a fresh file
  (shared recipe), then `exakit source reauth sales --password-file ~/.config/exakit/sales.pw`
  (tried first; a refused one keeps the old).
- The server moved (failover, RDS restore, migration):
  `exakit connect postgresql --name sales --set host=<new host> --password-file ~/.config/exakit/sales.pw --yes`
  (`--dry-run` first). `VS_SALES` keeps its name; the password is asked for again,
  every time; the recorded CA is kept. A new CA or TLS level cannot change in place:
  `exakit source disconnect sales --yes`, then connect again with them.
- Tables added at the source: `exakit source refresh sales`.
- Stop: `exakit source disconnect sales` or `exakit source remove sales`
  (`--dry-run` first, then ask).
