# PostgreSQL · Federation guide

> **Federation** lets your local Exasol query PostgreSQL data in place, without copying it.
> `exakit connect postgresql` turns one schema into a virtual schema, `VS_<NAME>`, that you query with SQL.

**Works with:** self-hosted PostgreSQL, Amazon RDS and Aurora PostgreSQL,
Azure Database for PostgreSQL. One source is one schema of one database.

## At a glance

| You need | Where to find it |
|---|---|
| Host and port | RDS endpoint, Aurora **Reader** endpoint or Azure server name ([step 1](#1-host-and-port)) |
| Database and schema | `\l` and `\dn` in `psql` ([step 2](#2-database-and-schema)) |
| A read-only user | You create it ([step 3](#3-a-read-only-user)) |
| Your IP let in | Security group or firewall rule ([step 4](#4-open-the-network)) |
| A CA certificate file | Your region's RDS bundle, or the root that signs the server ([step 5](#5-the-ca-certificate)) |

Then [connect](#connect) and [query](#query) `VS_<NAME>`.

## The simplest way: ask your AI agent

**Easiest: let your AI agent do it.** The kit installs the skill
`exasol-vs-postgresql` for your AI client; it knows this connector.

Copy this prompt, fill in the `<...>` parts, and give it to your agent:

```text
Connect the PostgreSQL schema <schema> of the database <database> on <host> to
my local Exasol with exakit. Use the exasol-vs-postgresql skill. Create a
read-only user for it, open the network for my IP, and get the CA certificate
for TLS verify. Write the password to a file, never into the chat.
```

**You still need, on your computer:** `psql` (or any SQL client) as an admin of
the database, plus the AWS CLI (`aws configure`) for RDS/Aurora or the Azure
CLI (`az login`) for Azure.

**Prefer to do it by hand?** Prepare the source with the five steps below.

## Where to find each value: prepare the source

### 1. Host and port

- **RDS:** AWS Console → RDS → Databases → `<db>` → Connectivity & security →
  Endpoint and Port.
  ```bash
  aws rds describe-db-instances --output table --query "DBInstances[?contains(Engine,'postgres')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible}"
  ```
- **Aurora:** RDS → Databases → `<cluster>` → Connectivity & security → use the
  **Reader** endpoint.
- **Azure:** Portal → Azure Database for PostgreSQL flexible servers → `<server>`
  → Overview → Server name.
  ```bash
  az postgres flexible-server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName}"
  ```

### 2. Database and schema

RDS shows the initial database under Configuration → DB name. To list them all:

```bash
psql "host=<host> dbname=postgres user=<admin>" -c '\l' -c '\dn'
```

PostgreSQL folds unquoted names to lower case: use `public`, not `PUBLIC`.

### 3. A read-only user

Run as an admin, in the database:

```sql
CREATE ROLE exakit_reader LOGIN PASSWORD '<a strong password>';
GRANT CONNECT ON DATABASE sales TO exakit_reader;
GRANT USAGE ON SCHEMA public TO exakit_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO exakit_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO exakit_reader;
```

### 4. Open the network

Get your public IP: `curl https://checkip.amazonaws.com` (`exakit connect` prints it too).

- **RDS / Aurora:** Connectivity & security → **Publicly accessible** must be
  Yes. Click the VPC security group → Inbound rules → Edit inbound rules → Add
  rule: Type PostgreSQL, Source `<your-ip>/32`.
  ```bash
  aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 5432 --cidr <your-ip>/32
  ```
- **Azure:** `<server>` → Settings → Networking → Firewall rules → Add your
  client IP address → Save.
  ```bash
  az postgres flexible-server firewall-rule create -g <rg> --server-name <server> --name exakit --start-ip-address <your-ip> --end-ip-address <your-ip>
  ```
- **Self-hosted:** `listen_addresses` and `pg_hba.conf` must accept your IP. A
  server on this computer: host `192.168.64.1` on macOS, never `localhost`.

### 5. The CA certificate

On Exasol Personal 2.4, TLS `verify` always needs a CA PEM file, even for a
public CA, because the database's loader has an empty trust store. Give the
root CA that signs the server. `require` encrypts with no CA file but does not
check the certificate.

- **RDS / Aurora:** download your region's bundle:
  `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`.
  The kit picks the certificate that signs your server.
- **Azure:** put DigiCert Global Root G2 and Microsoft RSA Root Certificate
  Authority 2017 in one file:
  ```bash
  curl -fsSL https://cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem > azure-ca.pem
  curl -fsSL "https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt" | openssl x509 -inform der >> azure-ca.pem
  ```
- **A public CA (Let's Encrypt and others):** see who issued the chain, then
  download that root from the CA (Let's Encrypt: `https://letsencrypt.org/certs/isrgrootx1.pem`):
  ```bash
  openssl s_client -starttls postgres -connect <host>:5432 -showcerts </dev/null | grep -E '^ *[si]:'
  ```

## Connect

```bash
exakit connect postgresql
```

1. The kit prints your public IP.
2. It asks for a connection string (hidden). Paste one, or press Enter on an
   empty line to type the fields one by one.
3. It asks for each field in [the table below](#what-exakit-connect-asks-for-reference).
4. It shows the plan and connects. The first connect enables **Federation** in
   the database: it installs Java there (one restart).

Your tables appear as `VS_SALES`.

Without prompts (put the password alone in an owner-only file):

```bash
exakit connect postgresql --name sales --set host=mydb.abc123.eu-central-1.rds.amazonaws.com \
  --set database=sales --set schema=public --set user=exakit_reader \
  --set ca=~/certs/eu-central-1-bundle.pem --password-file ~/.config/exakit/sales.pw --yes
exakit sql "SELECT * FROM VS_SALES.ORDERS LIMIT 10"
```

Add `--dry-run` to see the plan without changing anything.

**Windows:** paste the connection string at the prompt; do not use `--url` with
a string that contains `&`. For a quoted name in `exakit sql`, pipe the
statement in (`'SELECT "x" FROM VS_SALES.T' | exakit sql`) or use
`exakit sql --file query.sql`.

## Query

Names arrive in upper case, so query them without quotes:

```bash
exakit sql "SELECT * FROM VS_SALES.ORDERS LIMIT 10"
exakit sql "SELECT CAST(RENTAL_RATE AS DECIMAL(10,2)) FROM VS_SALES.FILM LIMIT 10"
```

- `NUMERIC` columns arrive as `VARCHAR`: cast them to compute, as above.
- A column of a domain type (pagila's `FILM.RELEASE_YEAR`) or an extension type
  such as `vector` cannot be read, and `BYTEA` reads as the text
  `'bytea NOT SUPPORTED'`: leave such columns out of the `SELECT` list.

## Troubleshooting

| Error you see | Why | Fix |
|---|---|---|
| "connect timed out", "The connection attempt failed" | The source does not let your IP in. | Allow your IP in the security group or firewall; on RDS, Publicly accessible = Yes ([step 4](#4-open-the-network)). |
| "PKIX path building failed", "trustAnchors parameter must be non-empty" | `verify` has no CA file to check the server with. | Give the CA with `--set ca=<pem>` ([step 5](#5-the-ca-certificate)). Do not switch to `require` to hide it. |
| "password authentication failed" | Wrong user or password. | `exakit source reauth sales`. |
| "permission denied for table" or "for schema" | A grant is missing. | Run the grants in [step 3](#3-a-read-only-user). |
| "validity check failed" | The database clock is behind (the computer slept). | `exakit stop`, then `exakit start`. |

## What `exakit connect` asks for (reference)

### Required

| Field | Example | Where it comes from |
|---|---|---|
| Name (alias) for this connection | `sales` | You choose it. `sales` gives the schema `VS_SALES`. |
| Host name or address | `mydb.abc123.eu-central-1.rds.amazonaws.com` | The RDS endpoint or Azure server name ([step 1](#1-host-and-port)). |
| Database | `sales` | RDS: Configuration → DB name ([step 2](#2-database-and-schema)). |
| Username | `exakit_reader` | The read-only user you make ([step 3](#3-a-read-only-user)). |
| Password | (hidden) | That user's password. |

### Optional

| Field | Default if left out | Example |
|---|---|---|
| Port | `5432` | `5432` |
| Schema | `public` | `public` |
| TLS | `verify` | `verify`, `require` or `disable` |
| CA certificate file (PEM) | for `verify` (the default): required, so give one ([step 5](#5-the-ca-certificate)) | `~/certs/eu-central-1-bundle.pem` |

## Connection string you can paste (reference)

```text
postgres://exakit_reader@mydb.abc123.eu-central-1.rds.amazonaws.com:5432/sales?currentSchema=public&sslmode=verify-full
jdbc:postgresql://mydb.abc123.eu-central-1.rds.amazonaws.com:5432/sales
mydb.abc123.eu-central-1.rds.amazonaws.com:5432/sales
mydb.abc123.eu-central-1.rds.amazonaws.com
```

| String | Fills |
|---|---|
| `postgres://user@host:port/db?currentSchema=...&sslmode=...` (or `postgresql://`) | host, port, database, user, schema and TLS |
| `jdbc:postgresql://host:port/db` | host, port and database (and `user`, `currentSchema`, `sslmode` when given) |
| `host:port/db` | host, port and database |
| `host` | host |

**TLS modes:** `sslmode` sets TLS. `verify-full` and `verify-ca` give `verify`;
`require` and `prefer` give `require`; `disable` gives `disable`.

**A password in the string** (`user:password@` or `password=`) is the
credential: the kit takes it out of the string and does not ask again. Better:
leave it out. The kit asks for it at a hidden prompt, or reads it from
`--password-file`.

### Where to find the connection string

You do not build it: copy the address your provider shows.

- **RDS:** AWS Console → RDS → Databases → `<db>` → Connectivity & security →
  Endpoint and Port. RDS shows the parts, not a whole string. Paste
  `<endpoint>:5432/<database>`.
- **Aurora:** the same tab, the **Reader** endpoint.
- **Azure:** Azure Database for PostgreSQL flexible servers → `<server>` →
  Overview → Server name. Paste `<server>.postgres.database.azure.com:5432/<database>`.
- **A string from your team or an app config** (`postgres://...`,
  `jdbc:postgresql://...`) works as it is.

The string is optional. At the prompt, press Enter alone and `exakit connect`
asks for the fields one by one.

### Where to find each part of the string

| Part of the string | Where to find it |
|---|---|
| host | RDS: Connectivity & security → Endpoint. Azure: Overview → Server name ([step 1](#1-host-and-port)). |
| port | RDS: Connectivity & security → Port. Default `5432`. |
| database | RDS: Configuration → DB name, or `\l` in `psql` ([step 2](#2-database-and-schema)). |
| `currentSchema` | `\dn` in `psql` ([step 2](#2-database-and-schema)). Default `public`. |
| user | The read-only user you make ([step 3](#3-a-read-only-user)). |
| `sslmode` | Your choice. Leave it out for `verify`. |
