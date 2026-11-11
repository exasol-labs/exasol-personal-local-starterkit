---
name: exasol-vs-snowflake
description: Connect a Snowflake schema to local Exasol as a virtual schema with exakit connect snowflake. Covers the inputs to collect (account identifier, database, schema, warehouse, role) and where Snowsight shows each, a read-only role and service user, a programmatic access token as the credential written straight to a file, the network policy a PAT login requires on the user, the connection-string forms, why no CA file is needed, the unattended connect line, example queries for bash and Windows PowerShell, and the Snowflake-specific failures such as NUMBER(38,0). Connector id snowflake, aliases sf and snow, tier GA. Triggers — "connect Snowflake to Exasol", "query Snowflake from Exasol", "Snowflake programmatic access token for exakit", "Snowflake network policy for Exasol", "add a Snowflake source", "exakit connect snowflake".
---

# Snowflake → local Exasol

Shared rules (credential handling, the `--json` answer and failure kinds, the
database clock, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too; this
skill adds only what is Snowflake's own.

## 1. When to use it

A Snowflake schema to query from local Exasol without copying it. One source is
one schema of one database, run on one warehouse (queries use its credits).
The credential is a programmatic access token (PAT) used as the password.
Tier GA.

## 2. Fields

The first prompt, "Name (alias) for this connection", is the source name
(`--name`): `sf_sales` becomes schema `VS_SF_SALES`.

| Input | Required | Default | Where to find it |
|---|---|---|---|
| `account` | yes | | Snowsight > account menu (bottom left) > View account details > Account identifier, `orgname-account` |
| `database` | yes | | Snowsight > Data > Databases (upper-cased by the kit) |
| `schema` | no | `PUBLIC` | Snowsight > Data > Databases > `<DB>` (upper-cased) |
| `warehouse` | yes | | Snowsight > Admin > Warehouses (upper-cased) |
| `role` | no | the user's default role | Snowsight > Admin > Users & Roles > Roles |
| `user` | yes | | the reader user (section 4) |
| `password` | yes | | the PAT (section 4) - only through `--password-file` or `--password-stdin` |

From the CLI (`snow`, or SnowSQL `snowsql -q`):

```bash
snow sql -q "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS ACCOUNT, CURRENT_ROLE(), CURRENT_WAREHOUSE()"
snow sql -q "SHOW WAREHOUSES"
snow sql -q "SHOW SCHEMAS IN DATABASE <DB>"
snow sql -q "SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT"
```

## 3. Connection-string forms

`--url` (or the hidden paste prompt) reads:

- `jdbc:snowflake://<account>.snowflakecomputing.com/?db=...&warehouse=...` -
  fills `account`, and `db`/`database`, `warehouse`, `schema`, `role`, `user`
- `https://<account>.snowflakecomputing.com` - fills `account`
- a bare `<account>`

A `token=` (else `password=`) in the string is the programmatic access token:
taken out of the string (never stored, logged or shown) and not asked again.

On Windows an `&` inside `--url` is split by cmd.exe (through `exakit.cmd`):
there, paste the string at the hidden prompt of `exakit connect`, or give the
fields with `--set`.

## 4. Prepare the source (show every statement, run on a yes)

Run as a role that may create users, roles and network policies (SECURITYADMIN
or higher). `reader.sql` - no secret in it:

```sql
CREATE ROLE EXAKIT_READER;
GRANT USAGE ON WAREHOUSE <WH> TO ROLE EXAKIT_READER;
GRANT USAGE ON DATABASE <DB> TO ROLE EXAKIT_READER;
GRANT USAGE ON SCHEMA <DB>.<SCHEMA> TO ROLE EXAKIT_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA <DB>.<SCHEMA> TO ROLE EXAKIT_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA <DB>.<SCHEMA> TO ROLE EXAKIT_READER;
GRANT SELECT ON ALL VIEWS IN SCHEMA <DB>.<SCHEMA> TO ROLE EXAKIT_READER;
CREATE USER EXAKIT_READER TYPE = SERVICE DEFAULT_ROLE = EXAKIT_READER DEFAULT_WAREHOUSE = <WH>;
GRANT ROLE EXAKIT_READER TO USER EXAKIT_READER;
CREATE NETWORK POLICY EXAKIT_READER_NP ALLOWED_IP_LIST = ('<public-ip>');
ALTER USER EXAKIT_READER SET NETWORK_POLICY = EXAKIT_READER_NP;
```

```bash
snow sql -f reader.sql
```

**A PAT login requires a network policy on the user**: without one Snowflake
refuses to create or accept the token. The policy is an IP filter, so it must
list this computer's public IP (`exakit connect` names it; fallback in the
shared skill). An account-level policy (section 2) must allow it too. When the
address changes: `ALTER NETWORK POLICY EXAKIT_READER_NP SET ALLOWED_IP_LIST = ('<ip>')`.

Then the token, straight into an owner-only file (its secret is shown once,
in this command's output only - never print it):

```bash
umask 077; mkdir -p ~/.config/exakit
snow sql --format JSON -q "ALTER USER EXAKIT_READER ADD PROGRAMMATIC ACCESS TOKEN EXAKIT ROLE_RESTRICTION = 'EXAKIT_READER' DAYS_TO_EXPIRY = 30" \
  | python3 -c 'import json,sys; print(next(v for r in json.load(sys.stdin) for k, v in r.items() if k.lower() == "token_secret"))' \
  > ~/.config/exakit/<name>.pat
```

A service user's token needs `ROLE_RESTRICTION`. If the pipe fails, the secret
is gone: add a token under another name. Snowsight alternative: Admin > Users &
Roles > `<user>` > Programmatic access tokens > Generate.

## 5. TLS

No CA file and no `tls` input: TLS with certificate, host name and revocation
checks is always on. The database's JDBC loader has an empty Java trust store,
so the kit's loader class (`exakit.loader.TrustStoreDriver`) points it at the
language container's CA store. Nothing is disabled.

## 6. Connect

```bash
exakit connect snowflake --name sf_sales --set account=<orgname-account> --set database=<DB> \
  --set schema=<SCHEMA> --set warehouse=<WH> --set role=EXAKIT_READER --set user=EXAKIT_READER --dry-run
exakit connect snowflake --name sf_sales --set account=<orgname-account> --set database=<DB> \
  --set schema=<SCHEMA> --set warehouse=<WH> --set role=EXAKIT_READER --set user=EXAKIT_READER \
  --password-file ~/.config/exakit/<name>.pat --yes --json
```

PowerShell: the same line on one line, the file as
`--password-file $HOME\.config\exakit\<name>.pat`.

## 7. Verify and query

```bash
exakit source check sf_sales
exakit source describe sf_sales
exakit sql 'SELECT C_NAME, C_ACCTBAL FROM VS_SF_SALES.CUSTOMER ORDER BY C_ACCTBAL DESC LIMIT 10'
exakit sql 'SELECT COUNT(*) FROM VS_SF_SALES.ORDERS'
```

Names arrive upper case, so most queries need no quotes and run as written in
Windows PowerShell 5.1 too. A query with a "quoted" name loses its inner double
quotes as a PowerShell 5.1 argument: pipe it or use a file there.

```powershell
'SELECT "C_NAME" FROM VS_SF_SALES."CUSTOMER" LIMIT 10' | exakit sql
exakit sql --file q.sql
```

## 8. Names and types

- Names arrive in upper case (`CUSTOMER`, `C_NAME`): no quotes needed.
- `NUMBER(38,0)`, Snowflake's default for integer columns, is wider than
  Exasol's `DECIMAL(36)` and reads as the text "Number precision not
  supported". Give the reader a view at the source that casts it to
  `NUMBER(36,0)`.

## 9. When it fails

| Message | Fix |
|---|---|
| "Programmatic access token is invalid", "JWT token is invalid", "token has expired" (`auth`) | a new token (section 4), then `exakit source reauth sf_sales --password-file <file>` |
| the sign-in is refused for this address | the user's network policy lacks this computer's public IP (section 4) |
| "the source has no schema X that this account can see" | the name, or USAGE on database and schema for the role |
| "SQL access control error", "Insufficient privileges to operate on" (`privilege`) | the role lacks USAGE on the warehouse, database or schema, or SELECT (section 4) |
| "Object '...' does not exist or not authorized" (`missing_or_denied`) | Snowflake says this for an object the role may not see too: dropped or renamed, `exakit source refresh sf_sales`; else grant the role SELECT on it |
| a column reads as "Number precision not supported" | `NUMBER(38,0)`: a casting view (section 8) |
| "not yet valid" or "validity check failed" | the database clock fell behind after the laptop slept; `exakit connect` shows "Database clock: in sync with this computer." or a warning with a restart offer. `exakit stop`, then `exakit start` |

## 10. Keep it working

- The token expires (`DAYS_TO_EXPIRY`): add a new one (section 4), then
  `exakit source reauth sf_sales --password-file ~/.config/exakit/<name>.pat`.
- Another account, database or warehouse: `exakit connect snowflake --name sf_sales
  --set database=<new> --password-file ~/.config/exakit/<name>.pat --yes`
  (`--dry-run` first). `VS_SF_SALES` keeps its name, the token is asked for
  again, and the change is tried before anything changes - see the shared skill.
- Tables added at the source: `exakit source refresh sf_sales`.
- Stop: `exakit source disconnect sf_sales` or `exakit source remove sf_sales`
  (`--dry-run` first, then ask) - see the shared skill.
