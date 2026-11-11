# PostgreSQL

Self-hosted PostgreSQL, Amazon RDS or Aurora PostgreSQL, Azure Database for
PostgreSQL. One source is one schema of one database.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-postgresql` knows this connector.
>
> **You still need, on your computer:** `psql` (or any SQL client) as an admin of
> the database, plus the AWS CLI (`aws configure`) for RDS/Aurora or the Azure
> CLI (`az login`) for Azure.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `sales` |
| Host name or address | yes | `mydb.abc123.eu-central-1.rds.amazonaws.com` |
| Port | no (5432) | `5432` |
| Database | yes | `sales` |
| Schema | no (`public`) | `public` |
| Reader account | yes | `exakit_reader` |
| Password | yes | (hidden) |
| TLS | no (`verify`) | `verify`, `require` or `disable` |
| CA certificate file (PEM) | for `verify` | `~/certs/eu-central-1-bundle.pem` |

## Where to find each value

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

The kit prints your public IP, asks for a connection string (hidden; press
Enter on an empty line to type the fields instead), then each field above. It
shows a plan and asks once. The first connect installs Java in the database
(one restart). Your tables appear as `VS_SALES`.

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

## Connection string you can paste

```text
postgres://exakit_reader@mydb.abc123.eu-central-1.rds.amazonaws.com:5432/sales?currentSchema=public&sslmode=verify-full
mydb.abc123.eu-central-1.rds.amazonaws.com:5432/sales
```

The first fills host, port, database, schema, user and TLS; the second fills
host, port and database. `jdbc:postgresql://...` works too. A password in the
string (`user:password@` or `password=`) is the credential: taken out of the
string and not asked again.

## Common problems

| Symptom | Fix |
|---|---|
| "connect timed out", "The connection attempt failed" | Allow your IP in the security group or firewall; on RDS, Publicly accessible = Yes. |
| "PKIX path building failed", "trustAnchors parameter must be non-empty" | Give the CA with `--set ca=<pem>` (step 5). Do not switch to `require` to hide it. |
| "password authentication failed" | Wrong user or password: `exakit source reauth sales`. |
| "permission denied for table" or "for schema" | Run the grants in step 3. |
| "validity check failed" | The database clock is behind (the computer slept): `exakit stop`, then `exakit start`. |
