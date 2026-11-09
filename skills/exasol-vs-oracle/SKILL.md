---
name: exasol-vs-oracle
description: Connect an Oracle database to local Exasol as a virtual schema with exakit connect oracle. Covers the inputs to collect (service name, schema owner), finding them with SQLcl or SQL*Plus and the AWS CLI, a read-only reader account, allowing this computer's public IP, TCPS on port 2484 with the RDS CA, SIDs and TNS descriptors, the unattended connect line, and the ORA- errors that matter. Connector id oracle, aliases oracle-db and ora, tier GA. Triggers — "connect Oracle to Exasol", "query Oracle from Exasol", "query RDS Oracle from Exasol", "Oracle TCPS from exakit", "Oracle service name for exakit", "exakit connect oracle", "ORA-01017 from exakit".
---

# Oracle → local Exasol

Shared rules (credential handling, TLS and a private CA, the reader-password
recipe, exit codes, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too;
this skill adds only what is Oracle's own.

## 1. When to use it

An Oracle database - self-hosted, Amazon RDS for Oracle - to query from local
Exasol without copying it. One source is one schema (owner). The Java-only thin
driver: no Oracle Client install. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `host` | yes | | host | the listener's host name - the name in its certificate, not an IP |
| `port` | no | 1521 | port | the listener port; TCPS is often 2484 |
| `service` | yes | | name | the service name (not a SID) |
| `schema` | yes | | name | the owner whose tables to expose, as Oracle stores it (upper case) |
| `user` | yes | | text | the reader account |
| `password` | yes | | secret | its password - only through `--password-file` |
| `tls` | no | `verify` | choice: `verify`, `disable` | `verify` is TCPS with the certificate's name checked; `disable` is plain TCP |
| `ca` | no | | ca-file | a PEM file or bundle of the CA that signs the listener |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
# AWS RDS for Oracle: host, port, option groups (TCPS needs the SSL option, port 2484 by default)
aws rds describe-db-instances --output table --query "DBInstances[?starts_with(Engine,'oracle')].{id:DBInstanceIdentifier,host:Endpoint.Address,port:Endpoint.Port,db:DBName,public:PubliclyAccessible,sg:join(',',VpcSecurityGroups[].VpcSecurityGroupId),og:join(',',OptionGroupMemberships[].OptionGroupName)}"
aws rds describe-option-groups --option-group-name <og> --query "OptionGroupsList[0].Options[?OptionName=='SSL'].{port:Port}"
```

Signed in with SQLcl (`sql`) or SQL*Plus (`sqlplus <admin>@//<host>:1521/<service>`):

```sql
SELECT sys_context('USERENV', 'SERVICE_NAME') FROM dual;   -- the service of this session
SELECT username FROM all_users ORDER BY 1;                   -- schema owners
SELECT table_name FROM all_tables WHERE owner = 'HR';        -- an owner's tables
```

A connection string fills host, port, service and tls:
`--url 'jdbc:oracle:thin:@tcps://<host>:2484/<service>'` (TCPS sets
`tls=verify`; `//host:1521/service` keeps it at verify too, with a note). A SID
(`host:port:SID`) and a TNS descriptor `(DESCRIPTION=...)` are refused: give
host, port and service with `--set` (`SELECT value FROM v$parameter WHERE name = 'service_names'`
lists the services).

## 4. Prepare a reader at the source (recommended grants; show, then run on a yes)

`reader.sql`, filled with the shared recipe (the password suits Oracle's
30-character limit and starts with a letter):

```sql
CREATE USER exakit_reader IDENTIFIED BY "@PW@";
GRANT CREATE SESSION TO exakit_reader;
-- Oracle 23ai: one grant covers the schema, later tables included
-- GRANT READ ANY TABLE ON SCHEMA HR TO exakit_reader;
-- 12.1.0.2 and later: one READ grant per table (repeat for tables added later)
BEGIN
  FOR t IN (SELECT table_name FROM all_tables WHERE owner = 'HR') LOOP
    EXECUTE IMMEDIATE 'GRANT READ ON "HR"."' || t.table_name || '" TO exakit_reader';
  END LOOP;
END;
/
EXIT
```

```bash
sql <admin>@//<host>:<port>/<service> @"$HOME/.config/exakit/<name>-reader.sql"   # or sqlplus; it prompts: the user runs it
rm -f ~/.config/exakit/<name>-reader.sql
```

## 5. Network

`exakit connect` shows this computer's public IP; allow that address at the
source. Fallback: the `python3` one-liner in the shared skill. Each change is at
the source: show it, run it only after a yes.

- **RDS**: `public` must be `True`; open the listener port (2484 for TCPS) from the IP:
  `aws ec2 authorize-security-group-ingress --group-id <sg> --protocol tcp --port 2484 --cidr <public-ip>/32`
- **Self-hosted**: the listener must accept TCPS on its port (or plain TCP for
  `tls=disable`) and the firewall must pass it. On this computer use host
  `192.168.64.1` (macOS) or `host.containers.internal` (Linux, WSL).

## 6. Connect

```bash
exakit connect oracle --name hr --set host=<host> --set port=2484 --set service=<service> \
  --set schema=HR --set user=EXAKIT_READER --dry-run
exakit connect oracle --name hr --set host=<host> --set port=2484 --set service=<service> \
  --set schema=HR --set user=EXAKIT_READER --set ca=~/.config/exakit/rds-<region>-bundle.pem \
  --password-file ~/.config/exakit/hr.pw --yes
```

- `verify` is TCPS: set the TCPS port. The CA travels inside the URL as a
  trust-only wallet, so the loader's empty CA store does not matter. RDS: the
  region's bundle from `https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`
  (a download: ask first). Verified against RDS Oracle 19c over TCPS 2484.
- `tls=disable` (plain TCP, often 1521) sends the password in clear: only when
  the user says so.
- The tables appear as `VS_HR`.

## 7. Verify

```bash
exakit source check hr
exakit source describe hr
exakit sql "SELECT * FROM VS_HR.EMPLOYEES LIMIT 10"   # names arrive as Oracle stores them, normally upper case
```

## 8. When it fails

| Message | Fix |
|---|---|
| "ORA-01017" (invalid username/password) | wrong user or password: `exakit source reauth hr --password-file <file>` |
| "ORA-12541", "ORA-12170" | no listener there, or a firewall drops it: host, port, security group |
| "ORA-17800", "ORA-17002", "IO Error: The Network Adapter", "Got minus one from a read call" | the far end answered, but not as Oracle: a wrong port, or a proxy that drops the protocol; `verify` needs the TCPS port |
| "PKIX path building failed", "ssl_server_dn_match" | the CA or the name does not match: `--set ca=<bundle>`, and the host name the certificate carries |
| "ORA-17965" | connected by IP: ojdbc checks the host name - use the certificate's host name |
| "the source has no schema hr, but it has HR" | Oracle stores names in upper case unless created quoted: `--set schema=HR` |
| a SID or TNS descriptor refused | give host, port and service with `--set` (section 3) |

Types: Oracle `DATE` carries a time of day, so it arrives as `TIMESTAMP(0)`.

## 9. Keep it working

- New password: `ALTER USER exakit_reader IDENTIFIED BY "@PW@"` with a fresh
  file, then `exakit source reauth hr --password-file ~/.config/exakit/hr.pw`.
- Tables added at the source: grant `READ` on them (before 23ai), then
  `exakit source refresh hr`.
- Stop: `exakit source disconnect hr` or `exakit source remove hr`
  (`--dry-run` first, then ask) - see the shared skill.
