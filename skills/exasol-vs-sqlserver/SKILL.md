---
name: exasol-vs-sqlserver
description: Connect Microsoft SQL Server to local Exasol as a virtual schema with exakit connect sqlserver. Covers the inputs to collect, finding them with sqlcmd and the AWS or Azure CLI, a schema-scoped SQL login as the reader, allowing this computer's public IP (RDS security group, Azure SQL firewall rule), verified TLS with a CA, named instances, the unattended connect line, quoting SQL Server's mixed-case names, and the SQL Server-specific failures. Connector id sqlserver, aliases mssql, sql-server and microsoft-sql-server, tier GA. Triggers — "connect SQL Server to Exasol", "query SQL Server from Exasol", "connect Azure SQL Database to Exasol", "query RDS SQL Server from Exasol", "connect MSSQL to Exasol", "exakit connect sqlserver", "exakit connect mssql", "SQL Server named instance in exakit".
---

# SQL Server → local Exasol

Shared rules (credential handling, TLS and a private CA, the reader-password
recipe, the `--json` answer and failure kinds, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is SQL Server's own.

## 1. When to use it

A SQL Server database - on-premises, Amazon RDS for SQL Server, Azure SQL
Database or Managed Instance - to query from local Exasol without copying it.
One source is one schema of one database. A SQL Server login only: Windows
authentication and Entra ID are not part of this connector. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `host` | yes | | host | server host name or address (never `localhost`) |
| `port` | no | 1433 | port | the TCP port; a named instance has its own |
| `database` | yes | | name | the database |
| `schema` | no | `dbo` | name | the one schema to expose |
| `user` | yes | | text | the reader's SQL login |
| `password` | yes | | secret | its password - only through `--password-file` |
| `tls` | no | `verify` | choice: `verify`, `require`, `disable` | `verify` checks certificate and host name |
| `ca` | no | | ca-file | a PEM file or bundle the server's certificate chains to |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
# AWS RDS for SQL Server
aws rds describe-db-instances --output table --query "DBInstances[?starts_with(Engine,'sqlserver')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible,sg:join(',',VpcSecurityGroups[].VpcSecurityGroupId)}"
# Azure SQL: servers, then a server's databases
az sql server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName,public:publicNetworkAccess}"
az sql db list --resource-group <rg> --server <server> --query "[].name" -o tsv
# sqlcmd, as any login that can sign in (it reads the password from SQLCMDPASSWORD, which the user sets)
sqlcmd -S <host>,1433 -U <admin> -d <database> -Q "SELECT DB_NAME(); SELECT name FROM sys.schemas ORDER BY name;"
```

A named instance (`host\instance`) is not read: give the host and the
instance's TCP port. SQL Server Configuration Manager shows it, or as an admin
on the instance: `SELECT local_tcp_port FROM sys.dm_exec_connections WHERE session_id = @@SPID`.
A connection string fills host, port, database and user:
`--url 'jdbc:sqlserver://<host>:1433;databaseName=<database>;encrypt=true'`.

## 4. Prepare a reader at the source (recommended grants; show, then run on a yes)

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

Azure SQL Database has no `USE`: run a contained user in the database itself,

```sql
CREATE USER exakit_reader WITH PASSWORD = '@PW@';
GRANT SELECT ON SCHEMA::<schema> TO exakit_reader;
```

```bash
sqlcmd -S <host>,1433 -U <admin> -d master -i ~/.config/exakit/<name>-reader.sql   # Azure SQL: -d <database>
rm -f ~/.config/exakit/<name>-reader.sql
```

## 5. Network

`exakit connect` shows this computer's public IP; allow that address at the
source. Fallback: the `python3` one-liner in the shared skill. Each change is at
the source: show it, run it only after a yes.

- **RDS**: `public` must be `True`; open TCP 1433 from the IP:
  `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port 1433 --cidr <public-ip>/32`
- **Azure SQL**: public network access must be enabled (`public` above), then
  `az sql server firewall-rule create -g <rg> -s <server> -n exakit --start-ip-address <public-ip> --end-ip-address <public-ip>`
- **On-premises**: TCP/IP enabled for the instance and the port open. On this
  computer use host `192.168.64.1` (macOS); on Linux and WSL the address the database sees this computer at (Podman:
  `host.containers.internal`; Docker: `host.docker.internal` where the deployment
  provides it, else the bridge gateway).

## 6. Connect

```bash
exakit connect sqlserver --name erp --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader --dry-run
exakit connect sqlserver --name erp --set host=<host> --set database=<database> \
  --set schema=<schema> --set user=exakit_reader --set ca=~/.config/exakit/<ca>.pem \
  --password-file ~/.config/exakit/erp.pw --yes --json
```

- On Exasol Personal `verify` needs `ca` even for a public CA: the loader's own
  CA store is empty. Give the root that signs the server (Azure SQL: its public
  root; RDS: the region's bundle from
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`, a
  download: ask first). The kit's TLS helper trusts exactly those certificates
  and checks the host name.
- A self-signed server certificate: give that certificate as `ca` when its name
  matches the host; `tls=require` encrypts without checking identity - only if
  the user accepts that.
- The tables appear as `VS_ERP`.

## 7. Verify

```bash
exakit source check erp
exakit source describe erp
exakit sql 'SELECT "OrderID" FROM VS_ERP."Orders" LIMIT 10'   # names keep their spelling, spaces too: quote them
```

## 8. When it fails

| Message | Fix |
|---|---|
| "PKIX path building failed" | the CA is not trusted: connect again with `--set ca=<PEM or bundle>` |
| "the trustAnchors parameter must be non-empty" | the loader has no CA store: `--set ca` with the server's root |
| "Login failed for user" | wrong login or password; `exakit source reauth erp --password-file <file>` |
| "The TCP/IP connection to the host ... has failed" | firewall, security group, port, a named instance's port |
| "unexpected pre-login response" | the far end is not SQL Server on that port: check the port |
| "the source has no schema X that this account can see" | check the name, and `GRANT SELECT ON SCHEMA::X` (section 4) |
| "The SELECT permission was denied on the object" (`privilege`) | the login's database user lacks SELECT: `GRANT SELECT ON SCHEMA::X` (section 4) |
| `host\instance` refused in `--url` | give `--set host=` and the instance's TCP port |

Types: `datetime` arrives as `TIMESTAMP(3)`, `bit` as `BOOLEAN`, `money` as
`DECIMAL(19,4)`. Names keep SQL Server's spelling: `VS_ERP."Order Details"`.

## 9. Keep it working

- New password: `ALTER LOGIN exakit_reader WITH PASSWORD = '@PW@'` (Azure SQL:
  `ALTER USER exakit_reader WITH PASSWORD = '@PW@'`) with a fresh file, then
  `exakit source reauth erp --password-file ~/.config/exakit/erp.pw`.
- The server moved (a new host, port or database): `exakit connect sqlserver --name erp
  --set host=<new host> --yes` (`--dry-run` first). The credential and `VS_ERP` are
  kept; the new address is tried before anything changes - see the shared skill.
- Tables added at the source: `exakit source refresh erp`.
- Stop: `exakit source disconnect erp` or `exakit source remove erp`
  (`--dry-run` first, then ask) - see the shared skill.
