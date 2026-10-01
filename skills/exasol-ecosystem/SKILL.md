---
name: exasol-ecosystem
description: Catalog and routing guide for the public Exasol tool ecosystem BEYOND this kit — which repository, driver, connector, virtual-schema adapter, extension or integration to reach for, which GitHub organization owns it, and which ones are archived and must not be recommended. Use it to answer "is there an Exasol X" and to pick between several tools that overlap; for the tools this kit already installs (exapump loading, the kit MCP bridge, pyexasol) use their own skills. Triggers — "how do I connect Exasol to another tool", "is there an Exasol connector for", "which virtual schema adapter", "stream Kafka or Kinesis into Exasol", "load from S3 or cloud storage", "what Exasol drivers exist", "Exasol dbt/Power BI/Tableau/Grafana/Metabase/n8n", "extend Exasol with a UDF", "what is exasol-labs", "is this Exasol project still maintained".
---

# The Exasol ecosystem — what exists, and which one to reach for

This is a lookup table, not a tutorial. Use it to find the right repository,
then read that repository's own README for install and configuration steps.

**Rows marked "already installed" are on this machine already.** The starter kit
ships exapump, the kit's MCP server and pyexasol, so for those the answer is a
command the user can run now, not a repository to go and find. Route the request
to that tool's own skill (`exasol-exapump`, `exasol-mcp`, `exasol-pyexasol`) and
mention the GitHub project only if the user asks about the upstream source.

## Two organizations, two support levels

State which one a recommendation comes from — they do not carry the same
promise.

| Org | What it means |
|---|---|
| [`github.com/exasol`](https://github.com/exasol) | Product and maintained integrations. |
| [`github.com/exasol-labs`](https://github.com/exasol-labs) | Labs: prototypes, demos and community-supported work. Useful, but do not present as supported product. |

**Before quoting a version, release date or support status, open the
repository.** This catalog records what exists and what it is for; it does not
track releases, and a stale version number is worse than no version number.

**Archived repositories are listed at the bottom.** Check there before
recommending anything that sounds plausible but that you have not confirmed —
several well-known Exasol projects have been archived and are still widely
cited.

## Run Exasol somewhere

| Want | Reach for |
|---|---|
| Managed cloud | Exasol SaaS — [docs.exasol.com](https://docs.exasol.com/db/latest/home.htm); manage resources with `exasol-labs/saas-cli`, script it with `exasol/saas-api-python` |
| Self-hosted, own infrastructure | `exasol/exasol-personal` |
| Local database for an agent/AI workflow | `exasol-labs/exasol-personal-local-starterkit` (this kit) |
| Disposable database for tests, CI, demos | `exasol/docker-db` |
| Full v8 database packaged for evaluation | `exasol-labs/exasol-labs-community-edition` |
| Local runtime images | `exasol/exasol-local-vm` |
| Warehouse-as-code | `exasol-labs/terraform-provider-exasol` |
| Configuration management | `exasol/ansible-collection`, `exasol/ansible-runner-wrapper` |
| Scheduled SQL jobs, in-database | `exasol-labs/exasol-scheduler` |
| Custom UDF runtimes | `exasol/script-languages`, `exasol/script-languages-release`, `exasol/script-languages-container-tool` |
| A Rust UDF runtime | `exasol-labs/language-container-rs` |

## Get data in, or query it where it lives

**Federate rather than copy** — Virtual Schemas expose an external system as
SQL with optimizer pushdown: `exasol/virtual-schemas` is the umbrella.

| Source | Adapter |
|---|---|
| Another Exasol | `exasol/exasol-virtual-schema` (Lua variant: `exasol/exasol-virtual-schema-lua`) |
| Any JDBC source | `exasol/virtual-schema-common-jdbc` |
| PostgreSQL / MySQL / Oracle / SQL Server | `exasol/postgresql-virtual-schema`, `mysql-`, `oracle-`, `sqlserver-virtual-schema` |
| DB2 / Sybase ASE / SAP HANA | `exasol/db2-virtual-schema`, `sybase-`, `hana-virtual-schema` |
| Snowflake / BigQuery / Redshift / Databricks / Athena | `exasol/snowflake-virtual-schema`, `bigquery-`, `redshift-`, `databricks-`, `athena-virtual-schema` |
| Hive / Impala | `exasol/hive-virtual-schema`, `exasol/impala-virtual-schema` |
| Elasticsearch / DynamoDB | `exasol/elasticsearch-virtual-schema`, `exasol/dynamodb-virtual-schema` |
| Salesforce | `exasol-labs/salesforce-virtual-schema` |
| Vector / semantic search over Qdrant | `exasol-labs/exasol-qdrant-adapter` |
| Document files on S3 / Azure Blob / ADLS Gen2 / GCS / BucketFS | `exasol/s3-document-files-virtual-schema`, `azure-blob-storage-`, `azure-data-lake-storage-gen2-`, `google-cloud-storage-`, `bucketfs-document-files-virtual-schema` |

**Copy it in** when federation is not what you want:

| Want | Reach for |
|---|---|
| Parquet, Avro, ORC, CSV from object storage | `exasol/cloud-storage-extension` |
| CLI import/export, CSV and Parquet | `exasol-labs/exapump` — **already installed** by this kit and on `PATH`; see the `exasol-exapump` skill |
| JSON / NDJSON shredded into tables | `exasol-labs/exasol-json-tables` |
| Arrow / ADBC / high-throughput movement | `exasol-labs/exarrow-rs` |
| Kafka / Kinesis streams | `exasol/kafka-connector-extension`, `exasol/kinesis-connector-extension` |
| Spark | `exasol/spark-connector` |
| Iceberg / Delta Lake in place | `exasol-labs/lakehouse-engine-rs` |
| Migrating off another database | `exasol/database-migration` |
| BucketFS file transfer | `exasol/bucketfs-client` (Java: `bucketfs-java`, Python: `bucketfs-python`) |
| EDML for Parquet document files | `exasol/parquet-edml-generator` |

## Explore, analyze and visualize

| Want | Reach for |
|---|---|
| An AI client that can query the database | `exasol/mcp-server` — **already installed** and configured by this kit (`exakit mcp-setup`, `exakit mcp-doctor`); see the `exasol-mcp` skill |
| Notebooks and worked AI/ML examples | `exasol/ai-lab`, `exasol/notebook-connector` |
| SQL in the editor | Exasol for VS Code (marketplace add-on in this kit) |
| Governed business-facing views | `exasol-labs/exasol-semantic-views` |
| dbt | `exasol/dbt-exasol` (macros: `exasol/dbt-exasol-utils`; example project: `exasol-labs/exa-jaffle-shop`) |
| Power BI | `exasol/powerbi-exasol` |
| Tableau | `exasol/tableau-connector` |
| Grafana | `exasol-labs/grafana-datasource` |
| Metabase | `exasol/metabase-driver` |
| Low-code apps | `exasol/power-apps-connector` |
| Workflow automation | `exasol/n8n-nodes` |
| Data catalog | `exasol/OpenMetadata` (fork with Exasol support) |

Other BI and catalog tools (Qlik, Looker, MicroStrategy, Cognos, Superset,
Collibra, Alation and so on) connect through JDBC/ODBC rather than a
dedicated Exasol repository — see the
[ecosystem overview](https://docs.exasol.com/db/latest/connect_exasol/ecosystem_overview.htm).

## AI, ML, UDFs and agents

| Want | Reach for |
|---|---|
| Agent access to the database over MCP | `exasol/mcp-server` — **already installed** and configured by this kit; see the `exasol-mcp` skill |
| Skills that teach an agent to drive Exasol | `exasol-labs/exasol-agent-skills` |
| Reference agentic workloads | `exasol-labs/agentic-solutions` |
| Hugging Face model inference in-database | `exasol/transformers-extension` |
| Building complex analytics algorithms | `exasol/advanced-analytics-framework` |
| MLflow | `exasol/mlflow-plugin`, `exasol-labs/exasol-labs-mlflow-server` |
| Writing UDFs | `exasol/udf-api-java`, `exasol/udf-mock-python`, `exasol/udf-debugging-java` |
| Agent-built dashboards on the local kit | `exasol-labs/dash-server` |
| Applied demonstrators | `exasol-labs/exasol-labs-ai-process-mining`, `exasol-labs/metadata-agent` |

**Text AI and Lakehouse Turbo are product capabilities, not public
repositories.** Point at [docs.exasol.com](https://docs.exasol.com/) for them
rather than inventing a GitHub link.

## Connect an application

| Language / interface | Driver |
|---|---|
| Python | `exasol/pyexasol` — **already installed** by this kit in `~/.exasol-starter-kit/pyexasol-venv`; see the `exasol-pyexasol` skill (SQLAlchemy: `exasol/sqlalchemy-exasol`) |
| Java / JVM | JDBC — [downloads.exasol.com](https://downloads.exasol.com/) |
| Go | `exasol/exasol-driver-go` |
| TypeScript / JavaScript | `exasol/exasol-driver-ts` |
| R | `exasol/r-exasol` |
| Lua | `exasol/exasol-driver-lua` |
| Swift (macOS) | `exasol-labs/exa-connector-for-swift-on-macos` |
| REST | `exasol/exasol-rest-api` |
| Raw protocol | `exasol/websocket-api` |
| PostgreSQL wire protocol | `exasol-labs/exa-postgres-interface` |

## Operate, govern and test

| Want | Reach for |
|---|---|
| Row-level security | `exasol/row-level-security-lua` |
| Metrics into CloudWatch | `exasol/cloudwatch-adapter`, `exasol/cloudwatch-dashboard-examples` |
| Telemetry | `exasol/telemetry-java`, `exasol/telemetry-client-python` |
| Administration API | `exasol/exaoperation-xmlrpc` |
| Integration testing | `exasol/integration-test-docker-environment`, `exasol/exasol-test-setup-abstraction-java` |
| pytest fixtures | `exasol/pytest-backend`, `exasol/pytest-extension`, `exasol/pytest-slc` |
| Benchmarking | `exasol/benchkit` |
| Client/ETL compatibility | `exasol/compatibility-test-suite` |
| Sample data to start from | `exasol-labs/sample-data` |
| SQL functions Exasol lacks built-in | `exasol-labs/more-functions` |
| Learning material | `exasol/tutorials`, `exasol/exasol-java-tutorial`, `exasol/developer-documentation` |

## Archived — do not recommend these

Confirmed archived on GitHub. They still appear in older write-ups and search
results, so say they are archived rather than silently offering an alternative.

| Archived | Instead |
|---|---|
| `exasol/extension-manager` | Install extensions per the target extension's own README. |
| `exasol/sagemaker-extension` | No maintained replacement — treat SageMaker integration as a custom UDF/API job. |
| `exasol/redis-virtual-schema` | No maintained replacement. |
| `exasol-labs/exasol-labs-text2sql-mcp-server` | `exasol/mcp-server`. |

And two names that are frequently cited but **do not exist**:

- `exasol/generic-jdbc-virtual-schema` — the real one is
  `exasol/virtual-schema-common-jdbc`.
- `exasol/aws-glue-exasol-connector` — no such repository. For Glue, use the
  JDBC driver, or `exasol/spark-connector` where Spark is available.

## When nothing here fits

Search the orgs directly rather than guessing a URL — a plausible-looking
GitHub link that 404s is worse than saying you did not find one:

```bash
gh search repos --owner exasol --owner exasol-labs <keyword>
```
