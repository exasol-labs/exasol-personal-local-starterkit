---
name: exasol-vs-snowflake
description: Connect a Snowflake schema to local Exasol as a virtual schema with exakit connect snowflake. Covers the inputs to collect (account identifier, database, schema, warehouse, role), finding them with the Snowflake CLI (snow) or SnowSQL, a read-only role and service user, a programmatic access token as the credential written straight to a file, the network policy that must allow this computer's public IP, the unattended connect line, and the Snowflake-specific failures such as NUMBER(38,0). Connector id snowflake, aliases sf and snow, tier GA. Triggers — "connect Snowflake to Exasol", "query Snowflake from Exasol", "Snowflake programmatic access token for exakit", "Snowflake network policy for Exasol", "add a Snowflake source", "exakit connect snowflake".
---

# Snowflake → local Exasol

Shared rules (credential handling, exit codes, disconnect versus remove) live in
[exasol-virtual-schemas](../exasol-virtual-schemas/SKILL.md). Load it too;
this skill adds only what is Snowflake's own.

## 1. When to use it

A Snowflake schema to query from local Exasol without copying it. One source is
one schema of one database, run on one warehouse (queries use its credits).
The credential is a programmatic access token (PAT) as the password. TLS with
certificate, host name and revocation checks is always on: there is no `tls`
or `ca` input. Tier GA.

## 2. What to get from the user

| Input | Required | Default | Kind | Meaning |
|---|---|---|---|---|
| `account` | yes | | account | the account identifier, `orgname-account` |
| `database` | yes | | name | the database (upper-cased by the kit) |
| `schema` | no | `PUBLIC` | name | the one schema to expose (upper-cased) |
| `warehouse` | yes | | name | the warehouse the queries run on (upper-cased) |
| `role` | no | the user's default role | name | the role to use |
| `user` | yes | | text | the reader user |
| `password` | yes | | secret | its programmatic access token - only through `--password-file` |

Plus `--name`: the source name, which becomes schema `VS_<NAME>`.

## 3. Find each value (read-only)

```bash
snow connection test                       # the CLI is signed in (SnowSQL: snowsql -q "...")
snow sql -q "SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS ACCOUNT, CURRENT_ROLE(), CURRENT_WAREHOUSE()"
snow sql -q "SHOW WAREHOUSES"
snow sql -q "SHOW DATABASES"
snow sql -q "SHOW SCHEMAS IN DATABASE <DATABASE>"
snow sql -q "SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT"   # an account policy must allow this computer
```

The account URL `https://<orgname>-<account>.snowflakecomputing.com` also works:
`--url 'https://<orgname>-<account>.snowflakecomputing.com'` fills `account`;
a `jdbc:snowflake://...?db=...&warehouse=...&schema=...&role=...&user=...`
string fills those too.

## 4. Prepare a reader at the source (recommended grants; show, then run on a yes)

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

Then the token, straight into an owner-only file (its secret is shown once,
in this command's output only - never print it):

```bash
umask 077; mkdir -p ~/.config/exakit
snow sql --format JSON -q "ALTER USER EXAKIT_READER ADD PROGRAMMATIC ACCESS TOKEN EXAKIT ROLE_RESTRICTION = 'EXAKIT_READER' DAYS_TO_EXPIRY = 30" \
  | python3 -c 'import json,sys; print(next(v for r in json.load(sys.stdin) for k, v in r.items() if k.lower() == "token_secret"))' \
  > ~/.config/exakit/<name>.pat
```

A service user may only create or use a token while a network policy applies to
it, and its token needs `ROLE_RESTRICTION`. If the pipe fails, the secret is
gone: add a token under another name.

## 5. Network

`exakit connect` shows this computer's public IP; allow that address at the
source. Fallback: the `python3` one-liner in the shared skill. The user's
network policy above does it; an account-level policy (section 3) must allow
the address too. A policy change is at the source: show it, run it only after a
yes (`ALTER NETWORK POLICY EXAKIT_READER_NP SET ALLOWED_IP_LIST = ('<ip>')`
when the address changes).

## 6. Connect

```bash
exakit connect snowflake --name sf_sales --set account=<orgname-account> --set database=<DB> \
  --set schema=<SCHEMA> --set warehouse=<WH> --set role=EXAKIT_READER --set user=EXAKIT_READER --dry-run
exakit connect snowflake --name sf_sales --set account=<orgname-account> --set database=<DB> \
  --set schema=<SCHEMA> --set warehouse=<WH> --set role=EXAKIT_READER --set user=EXAKIT_READER \
  --password-file ~/.config/exakit/<name>.pat --yes
```

- The JDBC loader on Exasol Personal has no CA store of its own; the kit's
  loader class points it at the language container's CA store. Nothing is
  disabled.
- The tables appear as `VS_SF_SALES`.

## 7. Verify

```bash
exakit source check sf_sales
exakit source describe sf_sales
exakit sql "SELECT * FROM VS_SF_SALES.CUSTOMER LIMIT 10"   # names arrive upper case: no quotes
```

## 8. When it fails

| Message | Fix |
|---|---|
| "Programmatic access token is invalid", "JWT token is invalid", "token has expired" | a new token (section 4), then `exakit source reauth sf_sales --password-file <file>` |
| the sign-in is refused for this address | the network policy lacks this computer's public IP (section 5) |
| "the source has no schema X that this account can see" | the name, or USAGE on database and schema for the role |
| a column reads as the text "Number precision not supported" | `NUMBER(38,0)` is wider than Exasol's `DECIMAL(36)`: give the reader a view that casts it to `NUMBER(36,0)` |

## 9. Keep it working

- The token expires (`DAYS_TO_EXPIRY`): add a new one (section 4), then
  `exakit source reauth sf_sales --password-file ~/.config/exakit/<name>.pat`.
- Tables added at the source: `exakit source refresh sf_sales`.
- Stop: `exakit source disconnect sf_sales` or `exakit source remove sf_sales`
  (`--dry-run` first, then ask) - see the shared skill.
