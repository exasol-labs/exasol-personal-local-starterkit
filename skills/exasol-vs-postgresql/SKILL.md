---
name: exasol-vs-postgresql
description: Connect PostgreSQL to local Exasol as a virtual schema with exakit connect postgresql. Covers the inputs to collect, finding them with psql and the AWS, Azure or Google Cloud CLI, a least-privilege reader role, allowing this computer's public IP (RDS security group, Azure firewall rule), trusting the RDS or Azure CA, the unattended connect line, verifying it, and the PostgreSQL-specific failures (PKIX, domain columns, NUMERIC as text). Connector id postgresql, aliases pg, postgres and pgsql, tier GA. Triggers — "connect my Postgres to Exasol", "query PostgreSQL from Exasol", "connect RDS Postgres to Exasol", "query Aurora PostgreSQL from Exasol", "Azure Database for PostgreSQL in Exasol", "add a Postgres source", "exakit connect postgresql", "exakit connect pg", "PKIX path building failed for Postgres".
---

# PostgreSQL → local Exasol

Shared rules (credential handling, TLS and a private CA, the reader-password
recipe, exit codes, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too;
this skill adds only what is PostgreSQL's own.

## 1. When to use it

A PostgreSQL database - self-hosted, Amazon RDS or Aurora PostgreSQL, Azure
Database for PostgreSQL - whose tables should be queryable from local Exasol
without copying them. One source is one schema of one database; connect again
with another `--name` for the next schema. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `host` | yes | | host | server host name or address (never `localhost`) |
| `port` | no | 5432 | port | the server's port |
| `database` | yes | | name | the database (`dbname`) |
| `schema` | no | `public` | name | the one schema to expose; PostgreSQL folds an unquoted name to lower case |
| `user` | yes | | text | the reader account |
| `password` | yes | | secret | its password - only through `--password-file` |
| `tls` | no | `verify` | choice: `verify`, `require`, `disable` | `verify` checks certificate and host name |
| `ca` | no | | ca-file | a PEM file or bundle of a private CA (RDS, Azure, company) |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
# AWS RDS / Aurora: host, port, public flag, security groups (the region is in the host name)
aws rds describe-db-instances --output table --query "DBInstances[?contains(Engine,'postgres')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,db:DBName,public:PubliclyAccessible,sg:join(',',VpcSecurityGroups[].VpcSecurityGroupId)}"
aws rds describe-db-clusters --output table --query "DBClusters[?Engine=='aurora-postgresql'].{id:DBClusterIdentifier,writer:Endpoint,reader:ReaderEndpoint,port:Port}"
# Azure Database for PostgreSQL (flexible server)
az postgres flexible-server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName}"
# psql, as any account that can sign in: databases, schemas, the schema's tables
psql "host=<host> port=5432 dbname=<database> user=<admin>" -c '\l' -c '\dn' -c '\dt <schema>.*'
```

Aurora's reader endpoint suits a read-only source. A connection string the user
already has can stand in for several inputs: `--url
'postgres://exakit_reader@<host>:5432/<database>?currentSchema=<schema>&sslmode=verify-full'`
fills host, port, database, user, schema and tls.

## 4. Prepare a reader at the source (recommended grants; show, then run on a yes)

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

`exakit connect` shows this computer's public IP; allow that address at the
source. Fallback: the `python3` one-liner in the shared skill. Each change below
is at the source: show it and run it only after a yes.

- **RDS / Aurora**: `public` must be `True`, and a security group must allow
  TCP 5432 from the IP:
  `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port 5432 --cidr <public-ip>/32`
- **Azure**: `az postgres flexible-server firewall-rule create --resource-group <rg> --server-name <server> --name exakit --start-ip-address <public-ip> --end-ip-address <public-ip>`
- **Google Cloud SQL**: `gcloud sql instances patch <instance> --authorized-networks=<existing>,<public-ip>/32`
  - the flag replaces the whole list, so repeat the existing entries.
- **Self-hosted**: `listen_addresses` must cover the interface and
  `pg_hba.conf` must accept the address the connection comes from; the server
  log names a refused one. On this computer use host `192.168.64.1` (macOS) or
  `host.containers.internal` (Linux, WSL).

## 6. Connect

```bash
exakit connect postgresql --name sales --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader --dry-run
exakit connect postgresql --name sales --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader \
  --set ca=~/.config/exakit/rds-<region>-bundle.pem \
  --password-file ~/.config/exakit/sales.pw --yes
```

- `ca` only for a private CA. RDS: the region's bundle from
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`
  (a download: ask first). From a bundle the kit picks the certificate that
  signs the server (a verified handshake from this computer) and sends it in
  the URL, because the database's Java sandbox cannot read a file.
- The tables appear as `VS_SALES`.

## 7. Verify

```bash
exakit source check sales          # a fresh bounded read; exit 0 when ready
exakit source describe sales       # tables and columns as Exasol sees them
exakit sql "SELECT * FROM VS_SALES.ORDERS LIMIT 10"   # names arrive upper case: no quotes
```

## 8. When it fails

| Message | Fix |
|---|---|
| "PKIX path building failed" | a private CA: connect again with `--set ca=<PEM or bundle>`; never `tls=require` instead |
| "the trustAnchors parameter must be non-empty" | the loader has no CA store: the same `--set ca`, a public CA's root too |
| "the source has no schema X, but it has Y" | PostgreSQL folds unquoted names to lower case: `--set schema=Y` |
| "the account may not use schema X" | grant it USAGE on the schema and SELECT on its tables (section 4) |
| "password authentication failed" | wrong password or user; `exakit source reauth sales --password-file <file>` |
| "The connection attempt failed", "connect timed out" | security group, firewall, `public`, port (section 5) |
| "validity check failed" | the database clock is behind: `exakit stop`, then `exakit start` |

Adapter limits (measured on live sources):

- `NUMERIC` arrives as `VARCHAR`: cast it to compute,
  `CAST(RENTAL_RATE AS DECIMAL(10,2))`.
- A column of a domain type (pagila's `FILM.RELEASE_YEAR`) or an extension
  type such as `vector` fails every query that reads it (ETL-1299), and
  `BYTEA` reads as the text `bytea NOT SUPPORTED`: name the other columns
  instead of `*`.
- Array columns are missing, and a partitioned table shows only its partitions.

## 9. Keep it working

- New password: `ALTER ROLE exakit_reader PASSWORD '@PW@'` with a fresh file
  (shared recipe), then `exakit source reauth sales --password-file ~/.config/exakit/sales.pw`
  (tried first; a refused one keeps the old).
- Tables added at the source: `exakit source refresh sales`.
- Stop: `exakit source disconnect sales` or `exakit source remove sales`
  (`--dry-run` first, then ask) - see the shared skill.
