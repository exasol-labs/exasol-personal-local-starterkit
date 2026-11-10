---
name: exasol-vs-mysql
description: Connect MySQL or MariaDB to local Exasol as a virtual schema with exakit connect mysql. Covers the inputs and where each is in the AWS or Azure console, the connection-string forms, a SELECT-only reader, allowing this computer's public IP, the CA PEM that tls=verify always needs on Exasol Personal 2.4 ("Could not load trustJKS keystore from null"), the unattended connect line, quoting MySQL's lower-case names in bash and Windows PowerShell, top-N queries, and the MySQL-specific failures. Connector id mysql, aliases mysql8 and mysql-server, tier GA. Triggers — "query MySQL from Exasol", "connect MySQL to Exasol", "connect MariaDB to Exasol", "query RDS MySQL from Exasol", "Aurora MySQL in Exasol", "Azure Database for MySQL in Exasol", "exakit connect mysql", "Communications link failure from Exasol", "Could not load trustJKS keystore".
---

# MySQL → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds, the
reader-password recipe, re-point, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is MySQL's own.

## 1. When to use it

A MySQL or MariaDB database - self-hosted, Amazon RDS or Aurora MySQL, Azure
Database for MySQL, Google Cloud SQL - to query from local Exasol without
copying it. MySQL has no schemas below a database: one source is one database.
Adapter 6.1.0 with Connector/J 26.7.0, which is downloaded from Maven Central on
this computer and never redistributed (GPL with the FOSS exception).

## 2. The fields and where to find them

The form first asks "Name (alias) for this connection" (`--name`, lower case,
e.g. `shop`): the tables appear as `VS_SHOP`.

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `host` | yes | | RDS: console > RDS > Databases > *db* > Connectivity & security > Endpoint. Azure: portal > Azure Database for MySQL flexible server > Overview > Server name. Never `localhost` (section 5) |
| `port` | no | 3306 | the same page |
| `database` | yes | | `SHOW DATABASES`; case-sensitive on Linux servers |
| `user` | yes | | the reader account (section 4) |
| `password` | yes | | its password - only through `--password-file` or `--password-stdin` |
| `tls` | no | `verify` | `verify`, `require` or `disable` (section 6) |
| `ca` | no | | a PEM file or bundle - required in practice with `verify` (section 6) |

Read-only discovery with a CLI:

```bash
aws rds describe-db-instances --output table --query "DBInstances[?contains(Engine,'mysql') || contains(Engine,'mariadb')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible,sg:join(',',VpcSecurityGroups[].VpcSecurityGroupId)}"
az mysql flexible-server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName}"
mysql -h <host> -P 3306 -u <admin> -p -e "SHOW DATABASES; SELECT @@hostname, @@port, @@version;"
```

## 3. Connection-string forms

The form's first question, and `--url '<string>'`, read:

- `jdbc:mysql://host:3306/db`
- `mysql://user@host:3306/db`
- `host[:port][/database]`

`user` fills `user`; `sslMode` fills `tls` (`VERIFY_IDENTITY` and `VERIFY_CA`
are `verify`; `REQUIRED` and `PREFERRED` are `require`; `DISABLED`), and
`useSSL=false` is `disable`. A password in the string is dropped and asked for
separately. `--set` wins over the string.

On Windows an `&` inside `--url` is split by cmd.exe (through `exakit.cmd`):
paste a string with two parameters at the form's hidden prompt, or use `--set`.

## 4. Prepare a reader at the source (show, then run on a yes)

`reader.sql`, filled with the shared recipe:

```sql
CREATE USER 'exakit_reader'@'%' IDENTIFIED BY '@PW@';
GRANT SELECT ON `<database>`.* TO 'exakit_reader'@'%';
```

```bash
mysql -h <host> -P 3306 -u <admin> -p < ~/.config/exakit/<name>-reader.sql   # prompts for the admin password: the user runs it
rm -f ~/.config/exakit/<name>-reader.sql
```

`'%'` accepts the account from any address; narrow it to this computer's public
IP if the user wants (`'exakit_reader'@'<public-ip>'`).

## 5. Network

`exakit connect` names this computer's public IP; allow it at the source. Each
change is at the source: show it, run it only after a yes.

- **RDS / Aurora**: Publicly accessible must be Yes; a security group must allow TCP 3306:
  `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port 3306 --cidr <public-ip>/32`
- **Azure** (portal > server > Networking > Firewall rules):
  `az mysql flexible-server firewall-rule create --resource-group <rg> --name <server> --rule-name exakit --start-ip-address <public-ip> --end-ip-address <public-ip>`
- **Cloud SQL** (Connections > Networking > Authorized networks):
  `gcloud sql instances patch <instance> --authorized-networks=<existing>,<public-ip>/32` -
  the flag replaces the whole list, so repeat the existing entries.
- **On this computer**: `localhost` is refused. Use `192.168.64.1` on macOS; on
  Linux and WSL with Podman `host.containers.internal`; with Docker
  `host.docker.internal` (192.168.65.254 inside the database on Docker Desktop).
  `bind-address` must cover that interface.

## 6. TLS and the CA file

- **`verify` always needs `ca` on Exasol Personal 2.4**, even for a public CA:
  the database's JDBC loader has an empty Java trust store. MySQL then fails
  with "Could not load trustJKS keystore from null". The form's CA prompt says
  "Enter to skip"; with `verify` do not skip it.
- What to give: RDS / Aurora, the region's bundle
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`; Azure,
  the root CA its TLS documentation names; a public CA, its root (Let's Encrypt:
  ISRG Root X1). A download: ask first.
- Connector/J reads trust only from a file, so the kit writes the bundle as a
  JKS truststore staged for this source; Java picks the signer from it.
- `require` encrypts without checking the certificate: no PEM, but weaker - only
  when the user accepts that. `disable` sends the password in clear.

## 7. Connect

```bash
exakit connect mysql --name shop --set host=<host> --set database=<database> \
  --set user=exakit_reader --set ca=~/.config/exakit/rds-<region>-bundle.pem --dry-run
exakit connect mysql --name shop --set host=<host> --set database=<database> \
  --set user=exakit_reader --set ca=~/.config/exakit/rds-<region>-bundle.pem \
  --password-file ~/.config/exakit/shop.pw --yes --json
```

PowerShell takes the same line on one line, with `$HOME\.config\exakit\...` paths.

## 8. Verify and query

```bash
exakit source check shop
exakit source describe shop
```

Names keep MySQL's spelling, so they are double-quoted. bash and zsh:

```bash
exakit sql 'SELECT "first_name", "last_name" FROM VS_SHOP."actor" LIMIT 10'
exakit sql 'SELECT "rating", COUNT(*) AS N FROM VS_SHOP."film" GROUP BY "rating"'
exakit sql 'SELECT "title", "length" FROM VS_SHOP."film" ORDER BY "length" DESC NULLS LAST LIMIT 5'
```

Windows PowerShell 5.1 drops the inner double quotes of an argument: pipe the
query, or use `--file`.

```powershell
'SELECT "first_name", "last_name" FROM VS_SHOP."actor" LIMIT 10' | exakit sql
exakit sql --file .\top-films.sql
```

## 9. Names and types

- Table and column names keep MySQL's spelling: quote them exactly.
- Write top-N as `ORDER BY x DESC NULLS LAST LIMIT n`: adapter 6.1.0 pushes plain
  `DESC LIMIT n` down with `NULLS FIRST`, which MySQL rejects.
- `YEAR` arrives as `DATE` (2006 reads as 2006-01-01); `TEXT` as `VARCHAR(65535)`.

## 10. When it fails

| Message | Fix |
|---|---|
| "Could not load trustJKS keystore from null" | `tls=verify` without a CA: connect again with `--set ca=<PEM>`, a public CA's root too (section 6) |
| "Path does not chain with any of the trust anchors", "PKIX path building failed" | the PEM does not sign this server: the right root or the RDS region bundle |
| "Communications link failure", and the kit says the certificate did not verify | a TLS cause: as above, not the firewall |
| "Communications link failure", and the kit says the source did not answer (`unreachable`) | security group, firewall, Publicly accessible, port, the `localhost` trap (section 5) |
| "validity check failed", "not yet valid" | the database clock is behind (the laptop slept): `exakit stop`, then `exakit start` |
| "Access denied for user" (`auth`) | wrong password or host part; later: `exakit source reauth shop --password-file <file>` |
| "SELECT command denied to user" (`privilege`) | signed in, but no SELECT: `GRANT SELECT ON <database>.*` (section 4) |
| "the source has no database X, but it has Y" | database names are case-sensitive on Linux: `--set database=Y` |

## 11. Keep it working

- New password: `ALTER USER 'exakit_reader'@'%' IDENTIFIED BY '@PW@'` with a fresh
  file, then `exakit source reauth shop --password-file ~/.config/exakit/shop.pw`.
- The server moved: `exakit connect mysql --name shop --set host=<new host>
  --password-file ~/.config/exakit/shop.pw --yes` (`--dry-run` first). `VS_SHOP`
  keeps its name; the password is asked for again; the recorded CA is kept. A new
  CA or TLS level: `exakit source disconnect shop --yes`, then connect again.
- Tables added at the source: `exakit source refresh shop`.
- Stop: `exakit source disconnect shop` or `exakit source remove shop`
  (`--dry-run` first, then ask).
