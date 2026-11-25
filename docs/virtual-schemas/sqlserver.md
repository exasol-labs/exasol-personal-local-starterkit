# SQL Server · Federation guide

> **Federation** lets your local Exasol query SQL Server data in place, without copying it.
> `exakit connect sqlserver` turns one schema into a virtual schema, `VS_<NAME>`, that you query with SQL.

**Works with:** SQL Server on your own server, Amazon RDS for SQL Server,
Azure SQL Database. SQL Server logins only (no Windows authentication or
Entra ID). One source is one schema of one database.

## At a glance

| You need | Where to find it |
|---|---|
| Host and port | RDS endpoint or the Azure SQL server name ([step 1](#1-host-and-port)) |
| Database and schema | `sys.databases` and `sys.schemas` ([step 2](#2-database-and-schema)) |
| A read-only SQL login | You create it ([step 3](#3-a-read-only-user)) |
| Your IP let in | Security group or firewall rule ([step 4](#4-open-the-network)) |
| A CA certificate file: root plus intermediates | Your region's RDS bundle, or the Azure CAs ([step 5](#5-the-ca-certificates)) |

Then [connect](#connect) and [query](#query) `VS_<NAME>`.

## The simplest way: ask your AI agent

**Easiest: let your AI agent do it.** The kit installs the skill
`exasol-vs-sqlserver` for your AI client; it knows this connector.

Copy this prompt, fill in the `<...>` parts, and give it to your agent:

```text
Connect the SQL Server schema <schema> of the database <database> on <host> to
my local Exasol with exakit. Use the exasol-vs-sqlserver skill. Create a
read-only SQL login for it, open the network for my IP, and get the CA
certificates for TLS verify. Write the password to a file, never into the chat.
```

**You still need, on your computer:** `sqlcmd` (or SSMS / Azure Data Studio)
as an admin, plus the AWS CLI (`aws configure`) for RDS or the Azure CLI
(`az login`) for Azure SQL.

**Prefer to do it by hand?** Prepare the source with the five steps below.

## Where to find each value: prepare the source

### 1. Host and port

- **RDS:** AWS Console → RDS → Databases → `<db>` → Connectivity & security →
  Endpoint and Port.
  ```bash
  aws rds describe-db-instances --output table --query "DBInstances[?starts_with(Engine,'sqlserver')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible}"
  ```
- **Azure SQL:** Portal → SQL databases → `<db>` → Overview → Server name
  (`<server>.database.windows.net`), port 1433.
  ```bash
  az sql server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName}"
  ```
- **A named instance** (`host\instance`): give the host and the instance's TCP
  port. SQL Server Configuration Manager → SQL Server Network Configuration →
  Protocols → TCP/IP → IP Addresses shows it.

### 2. Database and schema

```bash
sqlcmd -S <host>,1433 -U <admin> -Q "SELECT name FROM sys.databases;"
sqlcmd -S <host>,1433 -U <admin> -d <database> -Q "SELECT name FROM sys.schemas;"
```

Azure SQL: `az sql db list -g <rg> --server <server> --query "[].name" -o tsv`.

### 3. A read-only user

SQL Server and RDS:

```sql
USE master;
CREATE LOGIN exakit_reader WITH PASSWORD = '<a strong password>';
GO
USE erp;
CREATE USER exakit_reader FOR LOGIN exakit_reader;
GRANT SELECT ON SCHEMA::dbo TO exakit_reader;
GO
```

Azure SQL Database: run this in the database itself (a contained user):

```sql
CREATE USER exakit_reader WITH PASSWORD = '<a strong password>';
GRANT SELECT ON SCHEMA::dbo TO exakit_reader;
```

### 4. Open the network

Get your public IP: `curl https://checkip.amazonaws.com` (`exakit connect` prints it too).

- **RDS:** Publicly accessible must be Yes. Click the VPC security group →
  Inbound rules → Edit inbound rules → Add rule: Type MSSQL, Source `<your-ip>/32`.
  ```bash
  aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 1433 --cidr <your-ip>/32
  ```
- **Azure SQL:** SQL server `<server>` → Security → Networking → Public access:
  Selected networks → Add your client IPv4 address → Save.
  ```bash
  az sql server firewall-rule create -g <rg> -s <server> -n exakit --start-ip-address <your-ip> --end-ip-address <your-ip>
  ```
- **On-premises:** TCP/IP enabled for the instance and the port open. A server
  on this computer: host `192.168.64.1` on macOS, never `localhost`.

### 5. The CA certificates

On Exasol Personal 2.4 and later, TLS `verify` always needs a CA PEM file, even for a
public CA, because the database's loader has an empty trust store. SQL Server
needs the **root plus the intermediates** in one file. `require` encrypts with
no CA file but does not check the certificate.

- **RDS:** the region bundle holds both:
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`.
- **Azure SQL:** DigiCert Global Root G2 plus the Microsoft Azure TLS issuing
  CAs listed on Microsoft's
  [Azure Certificate Authority details](https://learn.microsoft.com/azure/security/fundamentals/azure-certificate-authority-details)
  page, converted to PEM and joined in one file:
  ```bash
  curl -fsSL https://cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem > azure-sql-ca.pem
  openssl x509 -inform der -in <intermediate>.crt >> azure-sql-ca.pem   # once per intermediate
  ```
- **Self-signed server certificate:** give that certificate itself, if its name
  matches the host.

## Connect

```bash
exakit connect sqlserver
```

1. The kit prints your public IP.
2. It asks for a connection string (hidden). Paste one, or press Enter on an
   empty line to type the fields one by one.
3. It asks for each field in [the table below](#what-exakit-connect-asks-for-reference).
4. It shows the plan and connects. The first connect enables **Federation** in
   the database: it installs Java there (one restart).

Your tables appear as `VS_ERP`.

Without prompts (put the password alone in an owner-only file):

```bash
exakit connect sqlserver --name erp --set host=erp.abc123.eu-central-1.rds.amazonaws.com \
  --set database=erp --set schema=dbo --set user=exakit_reader \
  --set ca=~/certs/eu-central-1-bundle.pem --password-file ~/.config/exakit/erp.pw --yes
exakit sql 'SELECT "OrderID" FROM VS_ERP."Orders" LIMIT 10'
```

Add `--dry-run` to see the plan first.

**Windows:** paste the connection string at the prompt rather than `--url`.
Quoted names do not survive PowerShell 5.1 arguments: pipe the statement in
(`'SELECT "OrderID" FROM VS_ERP."Orders"' | exakit sql`) or use
`exakit sql --file query.sql`.

## Query

Names keep SQL Server's spelling, spaces included, so quote them:

```bash
exakit sql 'SELECT "OrderID" FROM VS_ERP."Orders" LIMIT 10'
```

```powershell
'SELECT "OrderID" FROM VS_ERP."Orders" LIMIT 10' | exakit sql
```

- `datetime` arrives as `TIMESTAMP(3)`, `bit` as `BOOLEAN`, `money` as `DECIMAL(19,4)`.

## Troubleshooting

| Error you see | Why | Fix |
|---|---|---|
| "The TCP/IP connection to the host ... has failed" | The source does not let your IP in, or the port is wrong. | Allow your IP in the security group or firewall; check the port (a named instance has its own). |
| "PKIX path building failed", "trustAnchors parameter must be non-empty" | The CA file is missing or lacks the intermediates. | Give the root and intermediates with `--set ca=<pem>` ([step 5](#5-the-ca-certificates)). |
| "Login failed for user" | Wrong login or password. | `exakit source reauth erp`. |
| "The SELECT permission was denied on the object" | The grant is missing. | Run `GRANT SELECT ON SCHEMA::<schema>` ([step 3](#3-a-read-only-user)). |
| `host\instance` refused | The kit does not read a named instance. | Give `--set host=<host> --set port=<the instance's TCP port>`. |

## What `exakit connect` asks for (reference)

### Required

| Field | Example | Where it comes from |
|---|---|---|
| Name (alias) for this connection | `erp` | You choose it. `erp` gives the schema `VS_ERP`. |
| Host name or address | `erp.abc123.eu-central-1.rds.amazonaws.com` | The RDS endpoint or the Azure SQL server name ([step 1](#1-host-and-port)). |
| Database | `erp` | `sys.databases` ([step 2](#2-database-and-schema)). |
| Username | `exakit_reader` | The SQL login you make ([step 3](#3-a-read-only-user)). |
| Password | (hidden) | That login's password. |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| Port | `1433` | `1433` |
| Schema | `dbo` | `dbo` |
| TLS | `verify` | `verify`, `require` or `disable` |
| CA certificate file (PEM) | for `verify` (the default): required, so give one, root plus intermediates ([step 5](#5-the-ca-certificates)) | `~/certs/eu-central-1-bundle.pem` |

## Connection string you can paste (reference)

```text
jdbc:sqlserver://erp.abc123.eu-central-1.rds.amazonaws.com:1433;databaseName=erp;encrypt=true
jdbc:sqlserver://myserver.database.windows.net:1433;database=erp;user=exakit_reader;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;
erp.abc123.eu-central-1.rds.amazonaws.com:1433/erp
erp.abc123.eu-central-1.rds.amazonaws.com
```

| String | Fills |
|---|---|
| `jdbc:sqlserver://host:port;databaseName=db;encrypt=true` | host, port, database and TLS |
| The Azure portal's JDBC string | host, port, database, user and TLS |
| `host:port/db` | host, port and database |
| `host` | host |

- In a `jdbc:sqlserver://` string the kit also reads `database`, `serverName`,
  `portNumber`, `user` and `username`. It drops `hostNameInCertificate` and
  `loginTimeout` by name.
- A `password=` in the string is the credential: the kit takes it out of the
  string and does not ask again.
- A named instance (`host\instance`) is not read: give the host and the
  instance's TCP port as fields.

### Where to find the connection string

You do not build it: copy the address your provider shows.

- **Azure SQL:** Portal → SQL databases → `<db>` → Settings → Connection strings
  → JDBC. Copy it whole, then delete its `password=...` part.
- **RDS:** AWS Console → RDS → Databases → `<db>` → Connectivity & security →
  Endpoint and Port. RDS shows the parts, not a whole string. Paste
  `jdbc:sqlserver://<endpoint>:1433;databaseName=<database>;encrypt=true`.
- **A string from your team or an app config** (`jdbc:sqlserver://...`) works
  as it is.

Leave the password out of the string. The kit asks for it at a hidden prompt,
or reads it from `--password-file`. The string is optional. At the prompt,
press Enter alone and `exakit connect` asks for the fields one by one.

### Where to find each part of the string

| Part of the string | Where to find it |
|---|---|
| host | RDS: Connectivity & security → Endpoint. Azure SQL: Overview → Server name ([step 1](#1-host-and-port)). |
| port | RDS: Connectivity & security → Port. Azure SQL: `1433`. A named instance: its TCP port ([step 1](#1-host-and-port)). |
| `databaseName` | `sys.databases` ([step 2](#2-database-and-schema)). |
| `user` | The SQL login you make ([step 3](#3-a-read-only-user)). |
| `encrypt` | Keep `encrypt=true`. |
