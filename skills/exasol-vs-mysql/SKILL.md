---
name: exasol-vs-mysql
description: Connect MySQL or MariaDB to local Exasol as a virtual schema with exakit connect mysql. Covers the inputs to collect, finding them with the mysql client and the AWS or Azure CLI, a SELECT-only reader, allowing this computer's public IP (RDS security group, Azure firewall rule), trusting the RDS or Azure CA, the unattended connect line, quoting MySQL's lower-case names, top-N queries, and the MySQL-specific failures. Connector id mysql, aliases mysql8 and mysql-server, tier GA. Triggers — "query MySQL from Exasol", "connect MySQL to Exasol", "connect MariaDB to Exasol", "query RDS MySQL from Exasol", "Aurora MySQL in Exasol", "Azure Database for MySQL in Exasol", "exakit connect mysql", "Communications link failure from Exasol".
---

# MySQL → local Exasol

Shared rules (credential handling, TLS and a private CA, the reader-password
recipe, the `--json` answer and failure kinds, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is MySQL's own.

## 1. When to use it

A MySQL or MariaDB database - self-hosted, Amazon RDS or Aurora MySQL, Azure
Database for MySQL - to query from local Exasol without copying it. MySQL has
no schemas below a database: one source is one database. Connector/J is
downloaded from Maven Central on this computer and never redistributed (GPL
with the FOSS exception). Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `host` | yes | | host | server host name or address (never `localhost`) |
| `port` | no | 3306 | port | the server's port |
| `database` | yes | | name | the database to expose; case-sensitive on Linux servers |
| `user` | yes | | text | the reader account |
| `password` | yes | | secret | its password - only through `--password-file` |
| `tls` | no | `verify` | choice: `verify`, `require`, `disable` | `verify` checks certificate and host name |
| `ca` | no | | ca-file | a PEM file or bundle of a private CA (RDS, Azure, company) |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
# AWS RDS / Aurora: host, port, public flag, security groups
aws rds describe-db-instances --output table --query "DBInstances[?contains(Engine,'mysql') || contains(Engine,'mariadb')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible,sg:join(',',VpcSecurityGroups[].VpcSecurityGroupId)}"
# Azure Database for MySQL (flexible server)
az mysql flexible-server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName}"
# the mysql client, as any account that can sign in
mysql -h <host> -P 3306 -u <admin> -p -e "SHOW DATABASES; SELECT @@hostname, @@port, @@version;"
mysql -h <host> -P 3306 -u <admin> -p -e "SHOW TABLES FROM \`<database>\`;"
```

A connection string fills host, port, database, user and tls:
`--url 'mysql://exakit_reader@<host>:3306/<database>?sslMode=VERIFY_IDENTITY'`
(also `jdbc:mysql://...`, or a bare `host:port/database`).

## 4. Prepare a reader at the source (recommended grants; show, then run on a yes)

`reader.sql`, filled with the shared recipe:

```sql
CREATE USER 'exakit_reader'@'%' IDENTIFIED BY '@PW@';
GRANT SELECT ON `<database>`.* TO 'exakit_reader'@'%';
```

```bash
mysql -h <host> -P 3306 -u <admin> -p < ~/.config/exakit/<name>-reader.sql   # prompts for the admin password: the user runs it
rm -f ~/.config/exakit/<name>-reader.sql
```

`'%'` accepts the account from any address; narrow it to this computer's
public IP if the user wants (`'exakit_reader'@'<public-ip>'`).

## 5. Network

`exakit connect` shows this computer's public IP; allow that address at the
source. Fallback: the `python3` one-liner in the shared skill. Each change is at
the source: show it, run it only after a yes.

- **RDS / Aurora**: `public` must be `True`; open TCP 3306 from the IP:
  `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port 3306 --cidr <public-ip>/32`
- **Azure**: `az mysql flexible-server firewall-rule create --resource-group <rg> --name <server> --rule-name exakit --start-ip-address <public-ip> --end-ip-address <public-ip>`
- **Google Cloud SQL**: `gcloud sql instances patch <instance> --authorized-networks=<existing>,<public-ip>/32`
  - the flag replaces the whole list, so repeat the existing entries.
- **Self-hosted**: `bind-address` must cover the interface. On this computer
  use host `192.168.64.1` (macOS); on Linux and WSL the address the database sees this computer at (Podman:
  `host.containers.internal`; Docker: `host.docker.internal` where the deployment
  provides it, else the bridge gateway).

## 6. Connect

```bash
exakit connect mysql --name shop --set host=<host> --set database=<database> \
  --set user=exakit_reader --dry-run
exakit connect mysql --name shop --set host=<host> --set database=<database> \
  --set user=exakit_reader --set ca=~/.config/exakit/rds-<region>-bundle.pem \
  --password-file ~/.config/exakit/shop.pw --yes --json
```

- `ca` only for a private CA. RDS: the region's bundle from
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`
  (a download: ask first). Connector/J reads trust only from a file, so the
  kit writes the bundle as a truststore for this source; Java picks the signer.
- The tables appear as `VS_SHOP`.

## 7. Verify

```bash
exakit source check shop
exakit source describe shop
exakit sql 'SELECT "first_name" FROM VS_SHOP."actor" LIMIT 10'   # names keep MySQL's spelling: quote them
```

## 8. When it fails

| Message | Fix |
|---|---|
| "Path does not chain with any of the trust anchors", "PKIX path building failed" | a private CA: connect again with `--set ca=<PEM or bundle>` |
| "the trustAnchors parameter must be non-empty" | the loader has no CA store: the same `--set ca`, a public CA's root too |
| "Communications link failure", and the kit says the certificate did not verify | the server answered over a TLS cause: as above, not the firewall |
| "Communications link failure", and the kit says the source did not answer | security group, firewall, `public`, port (section 5) |
| "Access denied for user" (`auth`) | wrong password or host part; `exakit source reauth shop --password-file <file>` |
| "SELECT command denied to user" (`privilege`) | signed in, but no SELECT on that table: `GRANT SELECT ON <database>.*` (section 4) |
| "the source has no database X, but it has Y" | MySQL database names are case-sensitive on Linux: `--set database=Y` |

Query rules (adapter 6.1.0):

- Table and column names keep MySQL's spelling: quote them exactly,
  `SELECT "first_name" FROM VS_SHOP."actor"`.
- Write top-N as `ORDER BY x DESC NULLS LAST LIMIT n`: plain `DESC LIMIT n`
  is pushed down with `NULLS FIRST`, which MySQL rejects.
- `YEAR` arrives as `DATE` (2006 reads as 2006-01-01); `TEXT` as `VARCHAR(65535)`.

## 9. Keep it working

- New password: `ALTER USER 'exakit_reader'@'%' IDENTIFIED BY '@PW@'` with a
  fresh file (shared recipe), then `exakit source reauth shop --password-file ~/.config/exakit/shop.pw`.
- Tables added at the source: `exakit source refresh shop`.
- Stop: `exakit source disconnect shop` or `exakit source remove shop`
  (`--dry-run` first, then ask) - see the shared skill.
