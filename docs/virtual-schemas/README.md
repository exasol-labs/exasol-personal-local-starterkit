# Connect a source: virtual-schema guides

`exakit connect <connector>` makes another database, warehouse or bucket
queryable from your local Exasol database. The data stays at the source; each
query fetches what it needs, and the tables appear as `VS_<NAME>`.

Each guide below tells you where to find every value `exakit connect` asks for.

| Connector | Guide | What you need | CA file needed? |
|---|---|---|---|
| `postgresql` | [PostgreSQL](postgresql.md) | host, database, a reader account and its password | Yes, for `tls=verify` |
| `mysql` | [MySQL](mysql.md) | host, database, a reader account and its password | Yes, for `tls=verify` |
| `sqlserver` | [SQL Server](sqlserver.md) | host, database, schema, a SQL login and its password | Yes, for `tls=verify` (root plus intermediates) |
| `oracle` | [Oracle](oracle.md) | host, TCPS port, service name, schema, a reader account | Yes, for `tls=verify` |
| `snowflake` | [Snowflake](snowflake.md) | account identifier, database, warehouse, a user and its programmatic access token | No |
| `bigquery` | [BigQuery](bigquery.md) | project ID, dataset, a service-account key file (JSON) | No |
| `s3` | [Amazon S3 files](s3.md) | bucket, region, an EDML mapping, an IAM access key | No |
| `azure-blob` | [Azure Blob files](azure-blob.md) | storage account, container, an EDML mapping, a SAS token | No |
| `databricks` | [Databricks (SQL warehouse)](databricks.md) | workspace host, warehouse HTTP path, catalog, schema, a personal access token | No |
| `lakehouse` | [Iceberg on AWS Glue](lakehouse.md) | region, Glue database, an IAM access key | No |
| `iceberg-rest` | [Iceberg REST catalog](iceberg-rest.md) | catalog URL, warehouse, namespace, a catalog token or storage keys | No |
| `unity` | [Unity Catalog (from storage)](unity.md) | workspace URL, `catalog.schema`, bucket region, a personal access token | No |
| `mongodb` | [MongoDB](mongodb.md) | URI, database, collection, a reader account and its password | No |

## Before you start

- **Your public IP.** A source on the internet must allow the address your
  computer goes out from. `exakit connect` prints it; `curl https://checkip.amazonaws.com`
  shows it too.
- **The credential never goes on the command line.** Type it at the hidden
  prompt, or put it alone in an owner-only file (`chmod 600`) and pass
  `--password-file <file>`.
- **A source on this computer** is not `localhost` (inside the database that is
  the database itself). On macOS use `192.168.64.1`.
- **Name (alias).** Lower case letters, digits and `_`, a letter first, at most
  40 characters. `sales` gives the schema `VS_SALES`.

## After you connect

```bash
exakit source list                 # every source and its state
exakit source check <name>         # a fresh test read
exakit source describe <name>      # tables and columns as Exasol sees them
exakit source reauth <name>        # a new password or token
exakit source refresh <name>       # tables added at the source
exakit source remove <name> --dry-run
```

## Easiest: let your AI agent do it

Each connector has a skill, `exasol-vs-<connector>` (for example
`exasol-vs-postgresql`), installed with the kit. Ask your agent "connect my
Postgres to Exasol" and it collects the values, prepares a reader and runs the
connect with you.
