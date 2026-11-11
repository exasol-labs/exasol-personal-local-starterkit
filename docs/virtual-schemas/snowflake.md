# Snowflake

One schema of a Snowflake database, read with a programmatic access token
(PAT). TLS is always on and needs no CA file.

> **Easiest: let your AI agent do it.** The skill `exasol-vs-snowflake` knows this connector.
>
> **You still need, on your computer:** Snowsight in a browser, or the
> Snowflake CLI (`snow`) / `snowsql`, signed in with a role that may create
> users, roles and network policies (SECURITYADMIN or higher).
>
> **Prefer to do it by hand?** Follow the steps below.

## What `exakit connect` asks for

| Field | Required | Example |
|---|---|---|
| Name (alias) for this connection | yes | `sf_sales` |
| Account identifier (orgname-account) | yes | `myorg-myaccount` |
| Database | yes | `SALES` |
| Schema | no (`PUBLIC`) | `PUBLIC` |
| Warehouse | yes | `COMPUTE_WH` |
| Role | no (the user's default role) | `EXAKIT_READER` |
| Reader account | yes | `EXAKIT_READER` |
| Programmatic access token | yes | (hidden) |

The kit upper-cases database, schema and warehouse.

## Where to find each value

### 1. Account identifier

Snowsight → your user menu (bottom left) → Account → View account details →
Account identifier. Or in a worksheet:

```sql
SELECT CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME();
```

Use the dash form `orgname-account`, not `orgname.account`.

### 2. Database, schema and warehouse

Snowsight → Data → Databases → `<database>` → `<schema>`; warehouses under
Admin → Warehouses. Or:

```sql
SHOW DATABASES;
SHOW SCHEMAS IN DATABASE SALES;
SHOW WAREHOUSES;
```

### 3. A read-only user and role

Run as SECURITYADMIN (or higher):

```sql
CREATE ROLE EXAKIT_READER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE EXAKIT_READER;
GRANT USAGE ON DATABASE SALES TO ROLE EXAKIT_READER;
GRANT USAGE ON SCHEMA SALES.PUBLIC TO ROLE EXAKIT_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA SALES.PUBLIC TO ROLE EXAKIT_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA SALES.PUBLIC TO ROLE EXAKIT_READER;
GRANT SELECT ON ALL VIEWS IN SCHEMA SALES.PUBLIC TO ROLE EXAKIT_READER;
CREATE USER EXAKIT_READER TYPE = SERVICE DEFAULT_ROLE = EXAKIT_READER DEFAULT_WAREHOUSE = COMPUTE_WH;
GRANT ROLE EXAKIT_READER TO USER EXAKIT_READER;
```

### 4. Open the network (required for a PAT)

A PAT sign-in needs a **network policy on the user**. Get your public IP with
`curl https://checkip.amazonaws.com`, then:

```sql
CREATE NETWORK POLICY EXAKIT_READER_NP ALLOWED_IP_LIST = ('<your-ip>');
ALTER USER EXAKIT_READER SET NETWORK_POLICY = EXAKIT_READER_NP;
```

Snowsight: Admin → Security → Network Policies. If your account also has an
account-level policy (`SHOW PARAMETERS LIKE 'NETWORK_POLICY' IN ACCOUNT`), it
must allow your IP too. When your IP changes:
`ALTER NETWORK POLICY EXAKIT_READER_NP SET ALLOWED_IP_LIST = ('<new-ip>');`

### 5. The programmatic access token

The secret is shown once. Save it straight into an owner-only file.

```sql
ALTER USER EXAKIT_READER ADD PROGRAMMATIC ACCESS TOKEN EXAKIT
  ROLE_RESTRICTION = 'EXAKIT_READER' DAYS_TO_EXPIRY = 30;
```

Copy `token_secret` from the result into `~/.config/exakit/sf_sales.pat`
(`chmod 600`). For a person user instead of a service user: Snowsight → user
menu → Settings → Authentication → Programmatic access tokens → Generate new
token.

## Connect

```bash
exakit connect snowflake
```

The kit prints your public IP, asks for a connection string (hidden; press
Enter on an empty line to type the fields instead), then each field above. It
shows a plan and asks once. The first connect installs Java in the database
(one restart). Your tables appear as `VS_SF_SALES`.

Without prompts:

```bash
exakit connect snowflake --name sf_sales --set account=myorg-myaccount --set database=SALES \
  --set schema=PUBLIC --set warehouse=COMPUTE_WH --set role=EXAKIT_READER --set user=EXAKIT_READER \
  --password-file ~/.config/exakit/sf_sales.pat --yes
exakit sql "SELECT * FROM VS_SF_SALES.CUSTOMER LIMIT 10"
```

Add `--dry-run` to see the plan first.

**Windows:** paste the connection string at the prompt; do not use `--url` with
a string that contains `&`. For a quoted name in `exakit sql`, pipe the
statement in (`'SELECT "x" FROM VS_SF_SALES.T' | exakit sql`) or use
`exakit sql --file query.sql`.

## Connection string you can paste

```text
https://myorg-myaccount.snowflakecomputing.com
jdbc:snowflake://myorg-myaccount.snowflakecomputing.com/?db=SALES&warehouse=COMPUTE_WH&schema=PUBLIC&role=EXAKIT_READER&user=EXAKIT_READER
```

The first fills the account; the second fills account, database, schema,
warehouse, role and user. A `token=` (or else `password=`) in the string is
the programmatic access token: taken out of the string and not asked again.

## Common problems

| Symptom | Fix |
|---|---|
| The sign-in is refused for this address | Add your public IP to the user's network policy (step 4), and to the account policy if there is one. |
| "Programmatic access token is invalid", "token has expired" | Make a new token (step 5), then `exakit source reauth sf_sales`. |
| "Insufficient privileges to operate on", "does not exist or not authorized" | The role lacks USAGE or SELECT: run the grants in step 3. |
| A column reads "Number precision not supported" | `NUMBER(38,0)` is wider than Exasol allows: give the reader a view that casts it to `NUMBER(36,0)`. |
| Sign-in fails right after the computer slept | The database clock is behind: `exakit stop`, then `exakit start`. |
