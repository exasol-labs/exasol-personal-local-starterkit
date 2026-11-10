# Oracle

Oracle Database on your own server, Amazon RDS for Oracle or Oracle Cloud,
through the Java thin driver (no Oracle Client install). One source is one
schema (owner).

> **Easiest: let your AI agent do it.** The skill `exasol-vs-oracle` knows this connector.
>
> **You still need, on your computer:** SQLcl (`sql`) or SQL*Plus as an admin,
> plus the AWS CLI (`aws configure`) for RDS, or the Oracle Cloud Console for
> Autonomous Database.
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `hr` |
| Host name or address | yes | `hr.abc123.eu-central-1.rds.amazonaws.com` |
| Port | no (1521) | `2484` for TCPS |
| Service name | yes | `ORCL` |
| Schema (owner) | yes | `HR` |
| Reader account | yes | `EXAKIT_READER` |
| Password | yes | (hidden) |
| TLS | no (`verify`) | `verify` or `disable` |
| CA certificate file (PEM) | for `verify` | `~/certs/eu-central-1-bundle.pem` |

`verify` is TCPS with the certificate's host name checked. Oracle has no
`require` level here; `disable` is plain TCP and sends the password in clear.

## Where to find each value

### 1. Host, port and service

- **RDS:** AWS Console → RDS → Databases → `<db>` → Connectivity & security →
  Endpoint. The service name is the DB name on the Configuration tab
  (default `ORCL`).
  ```bash
  aws rds describe-db-instances --output table --query "DBInstances[?starts_with(Engine,'oracle')].{id:DBInstanceIdentifier,host:Endpoint.Address,db:DBName,public:PubliclyAccessible,og:join(',',OptionGroupMemberships[].OptionGroupName)}"
  ```
- **RDS TCPS port:** TCPS needs the **SSL** option. RDS → Option groups →
  `<group>` → Add option → SSL, port 2484 → apply it to the instance (Modify →
  Option group). Check:
  ```bash
  aws rds describe-option-groups --option-group-name <og> --query "OptionGroupsList[0].Options[?OptionName=='SSL'].Port"
  ```
- **Oracle Cloud Autonomous Database:** Console → Oracle Database → Autonomous
  Database → `<db>` → Database connection → TLS connection strings. Set
  Mutual TLS (mTLS) authentication to Not required first.
- **Self-hosted:** as an admin, `SELECT value FROM v$parameter WHERE name = 'service_names';`.

Use the host name the certificate carries, never an IP address.

### 2. Schema

```sql
SELECT username FROM all_users ORDER BY 1;
```

Oracle stores names in upper case: `HR`, not `hr`.

### 3. A read-only user

```sql
CREATE USER exakit_reader IDENTIFIED BY "<a strong password>";
GRANT CREATE SESSION TO exakit_reader;
-- Oracle 23ai: one grant covers the schema
-- GRANT READ ANY TABLE ON SCHEMA HR TO exakit_reader;
-- Before 23ai: one READ grant per table
BEGIN
  FOR t IN (SELECT table_name FROM all_tables WHERE owner = 'HR') LOOP
    EXECUTE IMMEDIATE 'GRANT READ ON "HR"."' || t.table_name || '" TO exakit_reader';
  END LOOP;
END;
/
```

### 4. Open the network

Get your public IP: `curl https://checkip.amazonaws.com` (`exakit connect` prints it too).

- **RDS:** Publicly accessible must be Yes. Click the VPC security group →
  Inbound rules → Edit inbound rules → Add rule: Custom TCP, port 2484, Source
  `<your-ip>/32`.
  ```bash
  aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 2484 --cidr <your-ip>/32
  ```
- **Autonomous Database:** `<db>` → Network → Access control list → Edit → add
  your IP.
- **Self-hosted:** the listener accepts TCPS on its port and the firewall
  passes it. A server on this computer: host `192.168.64.1` on macOS.

### 5. The CA certificate

On Exasol Personal 2.4, TLS `verify` always needs a CA PEM file, even for a
public CA. Give the root CA that signs the listener.

- **RDS:** `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`.
- **Any TCPS listener:** see who issued the chain, then download that root from the CA:
  ```bash
  openssl s_client -connect <host>:2484 -showcerts </dev/null | grep -E '^ *[si]:'
  ```

## Connect

```bash
exakit connect oracle
```

The kit prints your public IP, asks for a connection string (hidden; press
Enter on an empty line to type the fields instead), then each field above. It
shows a plan and asks once. The first connect installs Java in the database
(one restart). Your tables appear as `VS_HR`.

Without prompts (put the password alone in an owner-only file):

```bash
exakit connect oracle --name hr --set host=hr.abc123.eu-central-1.rds.amazonaws.com \
  --set port=2484 --set service=ORCL --set schema=HR --set user=EXAKIT_READER \
  --set ca=~/certs/eu-central-1-bundle.pem --password-file ~/.config/exakit/hr.pw --yes
exakit sql "SELECT * FROM VS_HR.EMPLOYEES LIMIT 10"
```

Add `--dry-run` to see the plan first.

**Windows:** paste the connection string at the prompt rather than `--url`.
For a quoted name in `exakit sql`, pipe the statement in
(`'SELECT "x" FROM VS_HR.T' | exakit sql`) or use `exakit sql --file query.sql`.

## Connection string you can paste

```text
jdbc:oracle:thin:@tcps://hr.abc123.eu-central-1.rds.amazonaws.com:2484/ORCL
hr.abc123.eu-central-1.rds.amazonaws.com:1521/ORCL
```

Both fill host, port and service; the first also sets TLS to `verify`. The
second is plain TCP: TLS stays at `verify`, so change the port to the TCPS one
or set TLS to `disable`. A SID (`host:port:SID`) and a TNS descriptor
`(DESCRIPTION=...)` are not read: type the fields.

## Common problems

| Symptom | Fix |
|---|---|
| "ORA-12170", "ORA-12541" | No listener there, or a firewall drops it: host, port, security group. |
| "IO Error: The Network Adapter", "Got minus one from a read call" | Wrong port for TCPS: `verify` needs the TCPS port (often 2484). |
| "PKIX path building failed", "ORA-17965" | Give the CA with `--set ca=<pem>` and use the certificate's host name, not an IP. |
| "ORA-01017" | Wrong user or password: `exakit source reauth hr`. |
| "ORA-01031", "ORA-00942" | A missing grant: CREATE SESSION and READ on each table (step 3). |
