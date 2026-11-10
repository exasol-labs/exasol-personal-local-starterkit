---
name: exasol-vs-sqlserver
description: Connect Microsoft SQL Server to local Exasol as a virtual schema with exakit connect sqlserver. Covers the inputs and where each is in the AWS or Azure console, the JDBC connection-string form, a schema-scoped SQL login as the reader, allowing this computer's public IP, the CA PEM that tls=verify always needs on Exasol Personal 2.4 (root plus intermediates for SQL Server on Linux), named instances, the unattended connect line, quoting SQL Server's mixed-case names in bash and Windows PowerShell, and the SQL Server-specific failures. Connector id sqlserver, aliases mssql, sql-server and microsoft-sql-server, tier GA. Triggers — "connect SQL Server to Exasol", "query SQL Server from Exasol", "connect Azure SQL Database to Exasol", "query RDS SQL Server from Exasol", "connect MSSQL to Exasol", "exakit connect sqlserver", "exakit connect mssql", "SQL Server named instance in exakit".
---

# SQL Server → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds, the
reader-password recipe, re-point, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is SQL Server's own.

## 1. When to use it

A SQL Server database - on-premises (Windows or Linux), Amazon RDS for SQL
Server, Azure SQL Database or Managed Instance - to query from local Exasol
without copying it. One source is one schema of one database. A SQL Server login
only: Windows authentication and Entra ID are not part of this connector.
Adapter 3.0.1 with mssql-jdbc 13.4.0 (jre8 build, on the Java 17 container).

## 2. The fields and where to find them

The form first asks "Name (alias) for this connection" (`--name`, lower case,
e.g. `erp`): the tables appear as `VS_ERP`.

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `host` | yes | | RDS: console > RDS > Databases > *db* > Connectivity & security > Endpoint. Azure SQL: portal > SQL databases > *db* > Overview > Server name. Never `localhost` (section 5) |
| `port` | no | 1433 | the same page; a named instance has its own TCP port |
| `database` | yes | | Azure: the database's name; `SELECT name FROM sys.databases` |
| `schema` | no | `dbo` | `SELECT name FROM sys.schemas` |
| `user` | yes | | the reader's SQL login (section 4) |
| `password` | yes | | its password - only through `--password-file` or `--password-stdin` |
| `tls` | no | `verify` | `verify`, `require` or `disable` (section 6) |
| `ca` | no | | a PEM file the server's certificate chains to - required in practice with `verify` (section 6) |

Read-only discovery with a CLI:

```bash
aws rds describe-db-instances --output table --query "DBInstances[?starts_with(Engine,'sqlserver')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible,sg:join(',',VpcSecurityGroups[].VpcSecurityGroupId)}"
az sql server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName,public:publicNetworkAccess}"
az sql db list --resource-group <rg> --server <server> --query "[].name" -o tsv
# sqlcmd reads the password from SQLCMDPASSWORD, which the user sets
sqlcmd -S <host>,1433 -U <admin> -d <database> -Q "SELECT DB_NAME(); SELECT name FROM sys.schemas ORDER BY name;"
```

A named instance (`host\instance`) is not read: give the host and the
instance's TCP port. SQL Server Configuration Manager shows it, or as an admin
on the instance: `SELECT local_tcp_port FROM sys.dm_exec_connections WHERE session_id = @@SPID`.

## 3. Connection-string forms

The form's first question, and `--url '<string>'`, read:

- `jdbc:sqlserver://host:1433;databaseName=db;encrypt=true`
- `host[:port][/database]`

`databaseName` (or `database`), `serverName`, `portNumber` and `user` fill their
inputs. `encrypt` and `trustServerCertificate` together set `tls`:
`encrypt=false` is `disable`, `encrypt=strict` is `verify`, `encrypt=true` with
`trustServerCertificate=true` is `require`, `encrypt=true` alone is `verify`.
A password in the string is dropped and asked for separately. The `;`
separators pass through Windows unharmed.

## 4. Prepare a reader at the source (show, then run on a yes)

`reader.sql` for SQL Server and RDS, filled with the shared recipe:

```sql
USE master;
CREATE LOGIN exakit_reader WITH PASSWORD = '@PW@';
GO
USE <database>;
CREATE USER exakit_reader FOR LOGIN exakit_reader;
GRANT SELECT ON SCHEMA::<schema> TO exakit_reader;
GO
```

Azure SQL Database has no `USE`: create a contained user in the database itself,

```sql
CREATE USER exakit_reader WITH PASSWORD = '@PW@';
GRANT SELECT ON SCHEMA::<schema> TO exakit_reader;
```

```bash
sqlcmd -S <host>,1433 -U <admin> -d master -i ~/.config/exakit/<name>-reader.sql   # Azure SQL: -d <database>
rm -f ~/.config/exakit/<name>-reader.sql
```

## 5. Network

`exakit connect` names this computer's public IP; allow it at the source. Each
change is at the source: show it, run it only after a yes.

- **RDS**: Publicly accessible must be Yes; a security group must allow TCP 1433:
  `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port 1433 --cidr <public-ip>/32`
- **Azure SQL** (portal > SQL server > Security > Networking): public network
  access enabled, then
  `az sql server firewall-rule create -g <rg> -s <server> -n exakit --start-ip-address <public-ip> --end-ip-address <public-ip>`
- **On-premises**: TCP/IP enabled for the instance and the port open.
- **On this computer**: `localhost` is refused. Use `192.168.64.1` on macOS; on
  Linux and WSL with Podman `host.containers.internal`; with Docker
  `host.docker.internal` (192.168.65.254 inside the database on Docker Desktop).

## 6. TLS and the CA file

- **`verify` always needs `ca` on Exasol Personal 2.4**, even for a public CA:
  the database's JDBC loader has an empty Java trust store, and the connect fails
  with "the trustAnchors parameter must be non-empty". The form's CA prompt says
  "Enter to skip"; with `verify` do not skip it.
- What to give: RDS, the region's bundle
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`; Azure
  SQL, the root CA its TLS documentation names; a public CA, its root. A
  download: ask first.
- **SQL Server on Linux sends only its leaf certificate**, not the chain: the
  PEM must hold the root and every intermediate, concatenated in one file.
- A self-signed server certificate: give that certificate as `ca` when its name
  matches the host.
- The kit's TLS helper class (`exakit.tls.PemTrustManager`, named in the URL)
  trusts exactly the given certificates and checks the host name: mssql-jdbc
  reads trust only from a file, and no path on Exasol Personal reaches both the
  adapter and the loader.
- `require` encrypts without checking the certificate: no PEM, but weaker - only
  when the user accepts that. `disable` sends the password in clear.

## 7. Connect

```bash
exakit connect sqlserver --name erp --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader --set ca=~/.config/exakit/<ca>.pem --dry-run
exakit connect sqlserver --name erp --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader --set ca=~/.config/exakit/<ca>.pem \
  --password-file ~/.config/exakit/erp.pw --yes --json
```

PowerShell takes the same line on one line, with `$HOME\.config\exakit\...` paths.
A `jdbc:sqlserver://...;...` string works in `--url` on Windows too.

## 8. Verify and query

```bash
exakit source check erp
exakit source describe erp
```

Names keep SQL Server's spelling, spaces too, so they are double-quoted. bash and zsh:

```bash
exakit sql 'SELECT "OrderID", "OrderDate" FROM VS_ERP."Orders" LIMIT 10'
exakit sql 'SELECT "ProductID", SUM("Quantity") AS QTY FROM VS_ERP."Order Details" GROUP BY "ProductID"'
```

Windows PowerShell 5.1 drops the inner double quotes of an argument: pipe the
query, or use `--file`.

```powershell
'SELECT "OrderID", "OrderDate" FROM VS_ERP."Orders" LIMIT 10' | exakit sql
exakit sql --file .\order-details.sql
```

## 9. Names and types

- Names keep SQL Server's spelling, spaces included: quote them exactly.
- `datetime` arrives as `TIMESTAMP(3)`, `bit` as `BOOLEAN`, `money` as `DECIMAL(19,4)`.

## 10. When it fails

| Message | Fix |
|---|---|
| "the trustAnchors parameter must be non-empty" | `tls=verify` without a CA: connect again with `--set ca=<PEM>`, a public CA's root too (section 6) |
| "PKIX path building failed" | the PEM does not chain the server's certificate: on Linux add the intermediates to the root |
| "validity check failed", "not yet valid" | the database clock is behind (the laptop slept): `exakit stop`, then `exakit start` |
| "Login failed for user" (`auth`) | wrong login or password; later: `exakit source reauth erp --password-file <file>` |
| "The TCP/IP connection to the host ... has failed" (`unreachable`) | firewall, security group, port, a named instance's port, the `localhost` trap |
| "unexpected pre-login response" | the far end is not SQL Server on that port: check the port |
| "the source has no schema X that this account can see" | check the name, and `GRANT SELECT ON SCHEMA::X` (section 4) |
| "The SELECT permission was denied on the object" (`privilege`) | the login's database user lacks SELECT: `GRANT SELECT ON SCHEMA::X` |
| `host\instance` refused in `--url` | give `--set host=` and the instance's TCP port |

## 11. Keep it working

- New password: `ALTER LOGIN exakit_reader WITH PASSWORD = '@PW@'` (Azure SQL:
  `ALTER USER exakit_reader WITH PASSWORD = '@PW@'`) with a fresh file, then
  `exakit source reauth erp --password-file ~/.config/exakit/erp.pw`.
- The server moved: `exakit connect sqlserver --name erp --set host=<new host>
  --password-file ~/.config/exakit/erp.pw --yes` (`--dry-run` first). `VS_ERP`
  keeps its name; the password is asked for again; the recorded CA is kept. A new
  CA or TLS level: `exakit source disconnect erp --yes`, then connect again.
- Tables added at the source: `exakit source refresh erp`.
- Stop: `exakit source disconnect erp` or `exakit source remove erp`
  (`--dry-run` first, then ask).
