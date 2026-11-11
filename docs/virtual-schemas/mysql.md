# MySQL

Self-hosted MySQL or MariaDB, Amazon RDS or Aurora MySQL, Azure Database for
MySQL. One source is one database (MySQL has no schemas below it).

> **Easiest: let your AI agent do it.** The skill `exasol-vs-mysql` knows this connector.
>
> **You still need, on your computer:** the `mysql` client (or any SQL client)
> as an admin, plus the AWS CLI (`aws configure`) for RDS/Aurora or the Azure
> CLI (`az login`) for Azure.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `shop` |
| Host name or address | yes | `shop.abc123.eu-central-1.rds.amazonaws.com` |
| Port | no (3306) | `3306` |
| Database | yes | `shop` |
| Reader account | yes | `exakit_reader` |
| Password | yes | (hidden) |
| TLS | no (`verify`) | `verify`, `require` or `disable` |
| CA certificate file (PEM) | for `verify` | `~/certs/eu-central-1-bundle.pem` |

## Where to find each value

### 1. Host and port

- **RDS / Aurora:** AWS Console → RDS → Databases → `<db>` → Connectivity &
  security → Endpoint and Port (Aurora: the **Reader** endpoint).
  ```bash
  aws rds describe-db-instances --output table --query "DBInstances[?contains(Engine,'mysql') || contains(Engine,'mariadb')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,public:PubliclyAccessible}"
  ```
- **Azure:** Portal → Azure Database for MySQL flexible servers → `<server>` →
  Overview → Server name.
  ```bash
  az mysql flexible-server list -o table --query "[].{name:name,rg:resourceGroup,host:fullyQualifiedDomainName}"
  ```

### 2. Database

```bash
mysql -h <host> -u <admin> -p -e "SHOW DATABASES;"
```

Database names are case-sensitive on Linux servers.

### 3. A read-only user

```sql
CREATE USER 'exakit_reader'@'%' IDENTIFIED BY '<a strong password>';
GRANT SELECT ON `shop`.* TO 'exakit_reader'@'%';
```

Replace `'%'` with `'<your-ip>'` to accept the account from your address only.

### 4. Open the network

Get your public IP: `curl https://checkip.amazonaws.com` (`exakit connect` prints it too).

- **RDS / Aurora:** Publicly accessible must be Yes. Click the VPC security
  group → Inbound rules → Edit inbound rules → Add rule: Type MySQL/Aurora,
  Source `<your-ip>/32`.
  ```bash
  aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 3306 --cidr <your-ip>/32
  ```
- **Azure:** `<server>` → Settings → Networking → Firewall rules → Add your
  client IP address → Save.
  ```bash
  az mysql flexible-server firewall-rule create -g <rg> --name <server> --rule-name exakit --start-ip-address <your-ip> --end-ip-address <your-ip>
  ```
- **Self-hosted:** `bind-address` must cover the interface. A server on this
  computer: host `192.168.64.1` on macOS, never `localhost`.

### 5. The CA certificate

On Exasol Personal 2.4, TLS `verify` always needs a CA PEM file, even for a
public CA, because the database's loader has an empty trust store. Give the
root CA that signs the server. `require` encrypts with no CA file but does not
check the certificate.

- **RDS / Aurora:** `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`.
- **Azure:** DigiCert Global Root CA, DigiCert Global Root G2 and Microsoft RSA
  Root Certificate Authority 2017 in one file:
  ```bash
  curl -fsSL https://cacerts.digicert.com/DigiCertGlobalRootCA.crt.pem > azure-ca.pem
  curl -fsSL https://cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem >> azure-ca.pem
  curl -fsSL "https://www.microsoft.com/pkiops/certs/Microsoft%20RSA%20Root%20Certificate%20Authority%202017.crt" | openssl x509 -inform der >> azure-ca.pem
  ```
- **A public CA:** see who issued the chain, then download that root from the CA:
  ```bash
  openssl s_client -starttls mysql -connect <host>:3306 -showcerts </dev/null | grep -E '^ *[si]:'
  ```

## Connect

```bash
exakit connect mysql
```

The kit prints your public IP, asks for a connection string (hidden; press
Enter on an empty line to type the fields instead), then each field above. It
shows a plan and asks once. The first connect installs Java in the database
(one restart) and downloads MySQL Connector/J. Your tables appear as `VS_SHOP`.

Without prompts (put the password alone in an owner-only file):

```bash
exakit connect mysql --name shop --set host=shop.abc123.eu-central-1.rds.amazonaws.com \
  --set database=shop --set user=exakit_reader --set ca=~/certs/eu-central-1-bundle.pem \
  --password-file ~/.config/exakit/shop.pw --yes
exakit sql 'SELECT "first_name" FROM VS_SHOP."actor" LIMIT 10'
```

Names keep MySQL's spelling, so quote them. Add `--dry-run` to see the plan first.

**Windows:** paste the connection string at the prompt; do not use `--url` with
a string that contains `&`. Quoted names do not survive PowerShell 5.1
arguments: pipe the statement in (`'SELECT "first_name" FROM VS_SHOP."actor"' | exakit sql`)
or use `exakit sql --file query.sql`.

## Connection string you can paste

```text
mysql://exakit_reader@shop.abc123.eu-central-1.rds.amazonaws.com:3306/shop?sslMode=VERIFY_IDENTITY
jdbc:mysql://shop.abc123.eu-central-1.rds.amazonaws.com:3306/shop
```

The first fills host, port, database, user and TLS; the second fills host,
port and database. A bare `host:port/database` works too. A password in the
string (`user:password@` or `password=`) is the credential: taken out of the
string and not asked again.

## Common problems

| Symptom | Fix |
|---|---|
| "Communications link failure" and the source did not answer | Allow your IP in the security group or firewall; on RDS, Publicly accessible = Yes. |
| "PKIX path building failed", "Path does not chain with any of the trust anchors" | Give the CA with `--set ca=<pem>` (step 5). |
| "Access denied for user" | Wrong password, or the account's host part does not match: `exakit source reauth shop`. |
| "SELECT command denied to user" | Run the grant in step 3. |
| "the source has no database X, but it has Y" | Names are case-sensitive: `--set database=Y`. |
