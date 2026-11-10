# SQL Server

SQL Server on your own server, Amazon RDS for SQL Server, Azure SQL Database.
SQL Server logins only (no Windows authentication or Entra ID). One source is
one schema of one database.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-sqlserver` knows this connector.
>
> **You still need, on your computer:** `sqlcmd` (or SSMS / Azure Data Studio)
> as an admin, plus the AWS CLI (`aws configure`) for RDS or the Azure CLI
> (`az login`) for Azure SQL.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `erp` |
| Host name or address | yes | `erp.abc123.eu-central-1.rds.amazonaws.com` |
| Port | no (1433) | `1433` |
| Database | yes | `erp` |
| Schema | no (`dbo`) | `dbo` |
| Reader account | yes | `exakit_reader` |
| Password | yes | (hidden) |
| TLS | no (`verify`) | `verify`, `require` or `disable` |
| CA certificate file (PEM) | for `verify` | `~/certs/eu-central-1-bundle.pem` |

## Where to find each value

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

On Exasol Personal 2.4, TLS `verify` always needs a CA PEM file, even for a
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

The kit prints your public IP, asks for a connection string (hidden; press
Enter on an empty line to type the fields instead), then each field above. It
shows a plan and asks once. The first connect installs Java in the database
(one restart). Your tables appear as `VS_ERP`.

Without prompts (put the password alone in an owner-only file):

```bash
exakit connect sqlserver --name erp --set host=erp.abc123.eu-central-1.rds.amazonaws.com \
  --set database=erp --set schema=dbo --set user=exakit_reader \
  --set ca=~/certs/eu-central-1-bundle.pem --password-file ~/.config/exakit/erp.pw --yes
exakit sql 'SELECT "OrderID" FROM VS_ERP."Orders" LIMIT 10'
```

Names keep SQL Server's spelling, spaces included: quote them. Add `--dry-run`
to see the plan first.

**Windows:** paste the connection string at the prompt rather than `--url`.
Quoted names do not survive PowerShell 5.1 arguments: pipe the statement in
(`'SELECT "OrderID" FROM VS_ERP."Orders"' | exakit sql`) or use
`exakit sql --file query.sql`.

## Connection string you can paste

```text
jdbc:sqlserver://erp.abc123.eu-central-1.rds.amazonaws.com:1433;databaseName=erp;encrypt=true
jdbc:sqlserver://myserver.database.windows.net:1433;database=erp;user=exakit_reader;encrypt=true;trustServerCertificate=false;hostNameInCertificate=*.database.windows.net;loginTimeout=30;
```

The first fills host, port, database and TLS. The second (Azure portal →
`<db>` → Connection strings → JDBC) also fills the user; the kit drops
`hostNameInCertificate` and `loginTimeout` by name. A password in the string
is never used.

## Common problems

| Symptom | Fix |
|---|---|
| "The TCP/IP connection to the host ... has failed" | Allow your IP in the security group or firewall; check the port (a named instance has its own). |
| "PKIX path building failed", "trustAnchors parameter must be non-empty" | Give the root and intermediates with `--set ca=<pem>` (step 5). |
| "Login failed for user" | Wrong login or password: `exakit source reauth erp`. |
| "The SELECT permission was denied on the object" | Run `GRANT SELECT ON SCHEMA::<schema>` (step 3). |
| `host\instance` refused | Give `--set host=<host> --set port=<the instance's TCP port>`. |
