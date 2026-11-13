---
name: exasol-semantic-modeler
addon: semantic-views
description: Use when an autonomous agent needs to create, bootstrap, import, or maintain an Exasol Semantic Views model. Covers schema and catalog-comment inspection, historical query-log analysis, autonomous metric derivation from physical tables, Databricks UCMV import, entity and relationship modelling, fact and dimension authoring, SQL-native metric DDL, model validation, publication, and governance configuration.
---

> **Exasol starter kit:** Exasol's own skill, copied unchanged from [exasol-labs/exasol-semantic-views](https://github.com/exasol-labs/exasol-semantic-views) at `v0.6.1`. On this machine the `exakit` skill comes first: how to connect, how to load data and which tool to reach for.

# Exasol Semantic Modeler

## Core Rule

The semantic layer encodes what the physical schema means. Before writing any
metric definition, understand the physical data — its grain, its relationships,
and the columns that carry business meaning. If workload history exists, use it
to reflect how people already ask for the data.
A well-derived model makes every downstream agent query deterministic and
governed. A poorly derived model propagates ambiguity into every answer.

Prefer this order:

1. Inspect physical structure, table/view comments, and column comments; then
   identify entities, relationships, and candidate facts.
2. Create the model and register entities, relationships, and dimensions.
3. Author metrics in order of dependency: additive first, then ratio/derived.
4. Validate and inspect issues after every structural change.
5. Publish when validation is clean; add governance metadata after publication.

If the source is a Databricks Unity Catalog Metric View YAML, use the dedicated
Databricks import path instead of manually rebuilding the model.

Read [authoring-workflows.md](references/authoring-workflows.md) for copyable
SQL and script examples.

If a consumer requires JSON-format nested or document-shaped output, keep that
shape outside metric definitions. Model and validate the dimensions and stable
parent keys needed by each result grain; after semantic compilation,
[Exasol JSON Tables structured results](https://github.com/exasol-labs/exasol-json-tables/blob/main/docs/structured-results.md)
can optionally materialize the flat governed results as a root/child family and
emit recursive JSON with `TO_JSON(*)`.

## Connection Requirements

All `SEMANTIC_ADMIN` scripts must be called with `EXECUTE SCRIPT`, not
`SELECT`. A full-privilege SQL connection (not a SELECT-only tool) is required
for all authoring, validation, and publication operations.

Discovery views in `SEMANTIC_AGENT` and `SEMANTIC_CATALOG` can be read with a
SELECT-only tool, but schema inspection (`EXA_ALL_COLUMNS`, `EXA_ALL_TABLES`)
also requires only SELECT.

## Historical Evidence Sources

Exasol keeps several kinds of historical information in system tables. Use the
most detailed source available:

1. `EXA_DBA_AUDIT_SQL` records executed SQL, statement class, duration,
   timing, CPU, and memory/I/O peaks.
2. `EXA_DBA_AUDIT_SESSIONS` and `EXA_DBA_SESSIONS_LAST_DAY` show who connected,
   from where, with what client/driver, and whether the session succeeded.
3. `EXA_DBA_PROFILE_LAST_DAY` and `EXA_USER_PROFILE_LAST_DAY` show operators,
   touched objects, row counts, and `REMARKS` for join/filter clues.
4. `EXA_USAGE_LAST_DAY`, `EXA_USAGE_HOURLY`, `EXA_USAGE_DAILY`, and
   `EXA_USAGE_MONTHLY` provide aggregate load trends.
5. `EXA_DBA_IMPERSONATION_LAST_DAY` and `EXA_DBA_AUDIT_IMPERSONATION` show
   effective-user access patterns.

Most DBA-prefixed history tables require `SELECT ANY DICTIONARY`. Audit and
profiling data are periodic, so use the richest source you have for the
workload.

## Autonomous Model Derivation

When building a model from scratch, derive the semantic structure from the
physical schema rather than asking the user to specify every field. Follow this
reasoning process:

### Step 1 — Inventory the physical schema

Query the target schema's tables and columns:

```sql
SELECT TABLE_NAME, TABLE_COMMENT, TABLE_ROW_COUNT
FROM EXA_ALL_TABLES
WHERE TABLE_SCHEMA = 'MART'
ORDER BY TABLE_NAME;

SELECT COLUMN_TABLE, COLUMN_NAME, COLUMN_TYPE, COLUMN_COMMENT
FROM EXA_ALL_COLUMNS
WHERE COLUMN_SCHEMA = 'MART'
ORDER BY COLUMN_TABLE, COLUMN_ORDINAL_POSITION;
```

Also inventory commented source views when they are in scope:

```sql
SELECT VIEW_NAME, VIEW_COMMENT
FROM EXA_ALL_VIEWS
WHERE VIEW_SCHEMA = 'MART'
ORDER BY VIEW_NAME;
```

Treat comments as first-class business evidence before inferring meaning from
names or samples. Use table/view comments to seed model, entity, grain, and
semantic-object descriptions. Use column comments to seed fact and dimension
descriptions and to detect units, currencies, time semantics, exclusions, and
sensitivity. Preserve useful wording, but do not copy contradictory or stale
comments blindly: verify grain, keys, cardinality, and formulas from constraints,
profiles, and sample data. Surface conflicts for review instead of silently
choosing one interpretation.

Sample a few rows from each candidate table to understand actual values:

```sql
SELECT * FROM MART.ORDERS LIMIT 5;
```

### Step 1b — Mine historical usage

When you are bootstrapping a model, review historical workload queries against
the source schema before you lock in dimensions, metric names, synonyms, and
default shapes. If the semantic layer already exists, `SYS_SEMANTIC.QUERY_LOG`
can refine naming and coverage.

Prefer the richest available source of historical evidence:

```sql
SELECT SESSION_ID, STMT_ID, COMMAND_NAME, COMMAND_CLASS, START_TIME, STOP_TIME, DURATION, SQL_TEXT
FROM EXA_DBA_AUDIT_SQL
ORDER BY START_TIME DESC;
```

```sql
SELECT SESSION_ID, USER_NAME, CLIENT, DRIVER, HOST, LOGIN_TIME, LOGOUT_TIME, SUCCESS
FROM EXA_DBA_AUDIT_SESSIONS
ORDER BY LOGIN_TIME DESC;
```

```sql
SELECT SESSION_ID, STMT_ID, PART_ID, PART_NAME, OBJECT_SCHEMA, OBJECT_NAME,
       OUT_ROWS, DURATION, CPU, TEMP_DB_RAM_PEAK, HDD_READ, REMARKS, SQL_TEXT
FROM EXA_DBA_PROFILE_LAST_DAY
ORDER BY DURATION DESC;
```

Use `SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT` for the curated agent view, and
`SYS_SEMANTIC.QUERY_LOG` only after publication:

```sql
SELECT HANDLE_TYPE, MODEL_NAME, USER_NAME, CLIENT_NAME, STATUS, REQUEST_TIME, REQUEST_TEXT
FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT
WHERE MODEL_NAME = 'sales'
ORDER BY REQUEST_TIME DESC;
```

For post-publish refinement, read `SYS_SEMANTIC.QUERY_LOG` directly:

```sql
SELECT REQUESTED_METRICS, REQUESTED_DIMENSIONS, COUNT(*) AS QUERY_COUNT
FROM SYS_SEMANTIC.QUERY_LOG
WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales')
  AND STATUS = 'OK'
GROUP BY REQUESTED_METRICS, REQUESTED_DIMENSIONS
ORDER BY QUERY_COUNT DESC;
```

The strongest query-log signals are:

- `REQUESTED_METRICS` and `REQUESTED_DIMENSIONS` show the governed shape people
  ask for most often.
- `ORIGINAL_SQL` shows ad hoc SQL field names, filters, sort orders, and join
  paths that users reach for when they are not using the semantic contract.
- `MATERIALIZATION_USED` and `RUNTIME_MS` expose hot paths worth optimizing or
  surfacing more directly.
- `STATUS`, `ERROR_CODE`, and `ERROR_MESSAGE` show where users hit ambiguity,
  missing fields, or unsupported shapes.

Use that evidence to prioritize metrics and dimensions, add synonyms, promote
repeated group-by or filter columns, create filtered metrics, and register
verified queries from real usage.

Treat query history as prioritization and naming evidence, not as a substitute
for physical grain, key, or relationship proof. If it conflicts with the
schema or validated comments, the physical schema wins.

### Step 2 — Identify entities and their grain

An entity is a physical table with a clear, unique business grain. Signals:

- A column ending in `_ID`, `_KEY`, or `_CODE` that is unique — this is the
  primary key and defines the grain.
- Tables named as business nouns in plural (`ORDERS`, `ORDER_LINES`,
  `CUSTOMERS`, `PRODUCTS`) are strong entity candidates.
- Large row-count tables with numeric measure columns are **fact entities**
  (grain: one row = one transaction or event).
- Smaller tables with mostly categorical attributes are **dimension entities**
  (grain: one row = one entity instance such as a customer or product).

Historical query patterns can refine the order in which you expose entities,
but they should not change the entity grain itself.

Choose a short, lowercase alias for each entity that matches the table's
business role: `ol` for order_line, `o` for order, `c` for customer.

When metrics originate on fact branches at different grains, generally add a
semantic object rooted at each metric base entity, even if consumers only query
the cross-source object. Without that root, validation can reject the branch
with `NO_SAFE_JOIN_PATH`; otherwise remove the metric from that object.

### Step 3 — Identify relationships

Scan for columns that appear in more than one table with matching names and
types. These are join columns. Common patterns:

- A column named `ORDER_ID` in `ORDER_LINES` that matches the primary key
  `ORDER_ID` in `ORDERS` → many-to-one from order_line to order.
- A column named `CUSTOMER_ID` in `ORDERS` matching `CUSTOMER_ID` in
  `CUSTOMERS` → many-to-one from order to customer.

Do not register every matching column as a relationship. Choose one canonical
path between entities and treat denormalized foreign-key copies as evidence,
not extra joins. For example, if `order_line -> order -> customer` is the
canonical path, do not also add `order_line -> customer` merely because the
line table repeats `CUSTOMER_ID`; multiple paths make metric-to-dimension joins
ambiguous. Add a shortcut only when it represents distinct business semantics,
name that role explicitly, and verify the compiler selects an unambiguous path.

Determine cardinality:
- Fact-to-dimension join: almost always `MANY_TO_ONE` (many transactions per
  customer, many lines per order).
- Dimension-to-dimension join: `ONE_TO_ONE` or `MANY_TO_ONE` depending on
  hierarchy.
- `MANY_TO_MANY` requires an explicit fanout policy and should be used only
  when unavoidable.

Declare proof metadata in this order:

1. Call `ADD_UNIQUE_KEY` for each proven unique endpoint.
2. Call `ADD_UNIQUE_KEY_COLUMN` for every key component in contiguous order.
3. Call `ADD_RELATIONSHIP`.
4. Call `ADD_RELATIONSHIP_KEY_MAPPING` for every endpoint pair in the same
   order as the matching unique key.

`MANY_TO_ONE` requires the mapped `to` endpoint to match a declared unique
key; `ONE_TO_MANY` requires this on `from`; `ONE_TO_ONE` requires both. Never
add mappings before the required key is complete: partial mappings trigger
`SEMANTIC_MODEL_033` and block validation-gated metric edits. Repair proof
metadata with the direct admin scripts, then run `VALIDATE_MODEL` before
continuing. If uniqueness cannot be proven, do not invent a key or mapping;
retain `SEMANTIC_MODEL_031` for legacy single-branch compilation and surface it
for review.

To withdraw an incorrect declaration from a draft, call
`REMOVE_UNIQUE_KEY_COLUMN` for each component before `REMOVE_UNIQUE_KEY`. On a
published model, call `REMOVE_UNIQUE_KEY_WITH_COLUMNS` so the complete key is
validated as one removal candidate. Do not edit `SYS_SEMANTIC` directly.
Published removals that would invalidate relationship grain proofs are rejected
and restored with `SEMANTIC_ADMIN_094`.

Every published mutation that returns successfully also revalidates. A valid
standalone add, update, or remove leaves the published surface queryable without
a separate `VALIDATE_MODEL` call. Use `ADD_SEMANTIC_IDENTITY_WITH_BINDINGS` for
F5 setup on an already published multi-representation entity; the standalone
identity call is rejected because the required bindings do not exist yet.
When an existing published F5 entity gains a heterogeneous representation, use
`ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING`; ordinary representation
registration validates before its required binding can be added. The compound
call seeds dimension and fact bindings from the governed expressions. It can
normalize a differently named or typed identity key, but the alternate must
still expose canonical attribute columns; use a canonicalizing view for nested
or otherwise different source shapes.

### Step 4 — Derive facts from numeric columns

A fact is a row-level expression that can be meaningfully aggregated. For each
numeric column (`DECIMAL`, `FLOAT`, `INTEGER`):

| Column name pattern | Derived fact expression | Suggested metric |
|---------------------|------------------------|------------------|
| `*_amount`, `*_price`, `*_cost`, `*_revenue`, `*_value` | `alias.column` | `SUM(fact)` → ADDITIVE metric |
| `*_quantity`, `*_units`, `*_qty` | `alias.column` | `SUM(fact)` → ADDITIVE metric |
| Numeric ID (order_id, line_id) | `alias.column` | `COUNT(DISTINCT fact)` → use as ADDITIVE COUNT metric |

Compound facts (e.g. gross margin = revenue − cost) should be expressed as a
row-level fact expression (`ol.net_amount - ol.cost_amount`) so that multiple
metrics can reuse the same row-level value.

Do not create ratio facts. Ratios (margin rate, conversion rate, AOV) should
be **RATIO metrics** referencing two additive metrics, not facts.

### Step 5 — Derive dimensions from categorical and temporal columns

| Column type | Pattern | Dimension |
|-------------|---------|-----------|
| `VARCHAR`/`CHAR` low-cardinality | `status`, `type`, `category`, `region`, `country` | Categorical dimension |
| `DATE`/`TIMESTAMP` | `*_date`, `*_at`, `*_time` | Time dimension — create one per grain: year, quarter, month, week, day using documented Exasol date functions |
| `VARCHAR` high-cardinality ID | `customer_id`, `product_id` | Generally **not** a dimension — too many values; use the human-readable name column instead |

For time columns, derive multiple dimensions from a single date column:

```
order_year    → YEAR(o.order_date)
order_quarter → CAST(YEAR(o.order_date) AS VARCHAR(4)) || '-Q' || TO_CHAR(o.order_date, 'Q')
order_month   → DATE_TRUNC('MONTH', o.order_date)
order_week    → DATE_TRUNC('WEEK', o.order_date)
```

Exasol accepts `EXTRACT(YEAR FROM value)`, with an unquoted field, but does not
support `QUARTER` as an `EXTRACT` field. Prefer the forms above. Include the year
in quarter labels so quarters from different years do not collapse together.

### Step 6 — Propose metrics in dependency order

Build metrics in this order to satisfy dependency resolution:

1. **ADDITIVE** (`SUM`, `COUNT`, `MAX`, `MIN`) — no dependencies.
2. **FILTERED** (`SUM … FILTER WHERE`) — depends on a filtered subset.
3. **RATIO** (`additive / NULLIF(additive, 0)`) — depends on two additives.
4. **DERIVED** (arithmetic over existing metrics) — depends on prior metrics.
5. **WINDOW** (`LAG`, `RANK`, period-over-period) — derived from additive +
   time dimension.

Propose names in `snake_case`. Write a business `COMMENT` for every metric.
Reuse verified source-comment terminology and add aggregation, filter, unit,
and exclusion semantics that are not explicit upstream.
If query history shows a heavily repeated business subset or roll-up pattern,
author the relevant filtered or derived metric early so agents do not have to
reconstruct it in every query.

### Step 6b — Convert history into semantic candidates

Use historical SQL and profiling evidence to derive candidate objects:

- Repeated `GROUP BY` columns become candidate dimensions.
- Repeated `WHERE` predicates become candidate filter dimensions or filtered
  metrics.
- Repeated `SUM`, `COUNT`, `MIN`, `MAX`, `AVG`, and `COUNT DISTINCT` patterns
  become candidate metrics.
- Repeated arithmetic expressions over aggregated values become derived or
  ratio metrics.
- Columns that appear in join predicates, or are named in profiling `REMARKS`
  as join/filter columns, become relationship or fact candidates.
- Repeated aliases, output labels, and business terms in SQL comments or query
  text become synonym candidates.


### Step 7 — Validate and iterate

Before every `ADD_FACT` or `ADD_DIMENSION`, execute the expression against its
owning source entity with the same alias:

```sql
SELECT <expression>
FROM <source_schema>.<source_object> <entity_alias>
LIMIT 1;
```

Do not register or certify the expression unless this query succeeds and its
result type matches the declared semantic type. This execution check is
mandatory: model validation checks known function names and structural rules,
but does not parse or compile every expression as Exasol SQL.

After each structural change:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('<model>');
```

Inspect issues:

```sql
SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
WHERE MODEL_NAME = '<model>'
ORDER BY SEVERITY, OBJECT_TYPE, OBJECT_NAME;
```

Fix errors before adding further definitions. Warnings can be deferred but
should be resolved before publication.
Use query history again after validation to confirm the final model covers the
dominant request shapes and that the semantic naming matches the terms users
already rely on.

## Bootstrap Sequence

When starting from zero, create objects in this order. Each step requires the
previous to succeed.

```
1. CREATE_MODEL (name, published schema, description, owner role)
2. ADD_ENTITY (per semantic entity; creates its primary physical representation)
3. ADD_UNIQUE_KEY, then ADD_UNIQUE_KEY_COLUMN (per proven entity key)
4. Optional ADD_ENTITY_REPRESENTATION (F1 equivalent representations only)
5. Optional ADD_ENTITY_REPRESENTATION_WITH_COVERAGE (F3 temporal partitions —
   register and cover in one candidate; see the F3 note below)
6. ADD_SEMANTIC_OBJECT (per published object — root entity must exist)
7. ADD_RELATIONSHIP, then ADD_RELATIONSHIP_KEY_MAPPING (per proven join)
8. ADD_FACT or ADD_FACT_WITH_BINDINGS (per row-level expression)
9. ADD_DIMENSION, or one ALTER SEMANTIC VIEW ... REPLACE DIMENSIONS block for
   all of them; ADD_DIMENSION_WITH_BINDINGS when a representation computes it
   differently
10. Optional ADD_ATTRIBUTE_BINDING (repair an existing draft attribute)
11. Optional SET_REPRESENTATION_AUTHORITY, then SET_ATTRIBUTE_FUSION_POLICY
    (overlapping F4 Customer 360 sources; do not combine with F3 coverage)
12. Optional ADD_SEMANTIC_IDENTITY, ADD_IDENTITY_BINDING for every representation,
    then ADD_IDENTITY_MAPPING_RELATION for each MAPPED binding
    -- or declare 4, 5, 11 and 12 as one fusion document with
    APPLY_FUSION_DECLARATION, which is the only workable route on a *published*
    model (see Fusion Declaration Document below)
13. ADD OR REPLACE METRIC (per aggregate — facts must exist for ADDITIVE;
   metrics must exist for RATIO/DERIVED). One statement may carry REPLACE
   DIMENSIONS, REPLACE FACTS and REPLACE METRICS together: one validation pass,
   one rollback unit.
14. VALIDATE_MODEL
15. PUBLISH_MODEL
```

**F3 partitions are declared with coverage, not after it.** A partition
without coverage is validated as an F1 *equivalent* representation, and
hot/cold key sets are disjoint by construction, so the candidate fails on key
cardinality (`SEMANTIC_MODEL_038`). Use
`ADD_ENTITY_REPRESENTATION_WITH_COVERAGE` (step 5), which validates the
representation and every coverage declaration as one candidate, seeds
compatibility bindings, and works whether or not the object already has
dimensions, facts, and metrics. If you register the representation separately
on a draft, call `SET_REPRESENTATION_COVERAGE_BATCH` *immediately* afterwards,
before adding any dimension or fact to that entity: anything authored in
between fails on the incomplete representation rather than on itself.

See [authoring-workflows.md](references/authoring-workflows.md) for the full
script syntax.

## Iterating on an Existing Model

Do not rerun the bootstrap sequence against an existing model: `CREATE_MODEL`
and structural `ADD_*` calls reject duplicate names. Inspect the current model
first and choose one path:

**Published models have no general isolated draft in this release.** Admin
changes target the same active version used by published semantic views.
Representation additions, attribute-binding removals, unique-key mutations,
and coverage changes validate prospectively on published models. Invalid
candidates restore the prior catalog and certification before returning
`SEMANTIC_ADMIN_094` (`SEMANTIC_ADMIN_059` for coverage), so these experiments
do not produce `SEMANTIC_QUERY_010`. A partial multi-step transition can still
be invalid. For F3, use `SET_REPRESENTATION_COVERAGE_BATCH` so every active
representation is validated as one candidate; sequential coverage calls cannot
initialize or clear a published partition set.
Schedule a maintenance window, prepare and smoke-test all other statements first,
apply them consecutively, then validate immediately. Never work around the
outage by retaining an older validation row: it did not certify the changed
catalog.

- For incremental maintenance, export or inspect the model, apply supported
  add/replace operations, validate, and republish.
- For a full rebuild, export any definition or history that must be retained,
  obtain explicit confirmation, then drop only that model:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('<model>');
```

`DROP_MODEL` deletes the model's catalog, validation, cache, query-log,
governance, feedback, and materialization metadata. It also drops the published
schema when no other model references it and it is not a protected managed
schema. It does not drop physical source schemas or tables. After it succeeds,
run the bootstrap sequence from step 1.

Use `tools/install.py --reset` only to reinstall the entire extension. It drops
all catalogued published-model schemas and all fixed managed schemas, affecting
unrelated models as well.

## Databricks UCMV Import

When migrating a Databricks Unity Catalog Metric View, use
`SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW` or the thin host helper
`tools/import_databricks.py`. Dry-run first by passing `FALSE` as the apply
flag so the generated native DDL and diagnostics can be reviewed:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  '<metric view YAML>',
  '<target_model>',
  '<published_schema_or_null>',
  FALSE
);
```

Apply with the same script and `TRUE` after review. Apply creates the model,
validates it, and publishes the generated semantic object. The importer handles
plain table/view sources, star and snowflake joins, fields, aggregate measures,
filtered measures, and derived/ratio measures that reference `MEASURE()`.
Unsupported or partial constructs return `DBX_IMPORT_*` diagnostics. Databricks
SQL query compatibility (`MEASURE(metric)`, `agg(metric)`, `GROUP BY ALL`) is
handled by the semantic SQL compiler/preprocessor after publication.

**Boolean safety warning:** these APIs have opposite final-argument semantics.
`APPLY_SEMANTIC_DEFINITION(..., TRUE)` is a dry-run because the parameter is
`DRY_RUN`; `IMPORT_DATABRICKS_METRIC_VIEW(..., FALSE)` is a dry-run because the
parameter is `APPLY_IMPORT`. Never reuse one API's safe value for the other.

## Entity and Relationship Management

Register entities with `ADD_ENTITY`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  '<model>',
  '<entity_name>',
  '<source_schema>',
  '<source_object>',
  '<source_alias>',
  '<pk_expr>',
  '<grain_description>',
  '<description>'
);
```

When several relations are equivalent at the same grain and identity, register
alternates with `ADD_ENTITY_REPRESENTATION`. Declare the entity key first:
validation proves key uniqueness on every representation and exact key-set
equality with the primary. Probe failures and duplicate grain are blocking.
This F1 equality rule does not apply after every active representation has a
valid F3 temporal coverage contract; F3 proves grain within each partition.
Fix local validation errors before rerunning validation: remote key scans are
deferred until catalog metadata is clean but remain mandatory before publish.
Before adding or validating any alternate, run `ALTER SESSION SET
QUERY_TIMEOUT=60`. Validation requires the bound for every multi-representation
key probe; it deliberately does not trust `SOURCE_KIND` or try to classify views
that may hide Virtual Schema dependencies. The setting must precede `EXECUTE
SCRIPT` because an Exasol script cannot change its own active timeout.
If the setting is absent or outside 1 to 60 seconds, `_041` returns blocking
severity `PRECONDITION`, which identifies the session rather than the model as
the problem. Apply the instruction and rerun validation.

Without an F5 semantic identity, require the
alternate to expose the same case-sensitive physical names used by the entity
primary-key expression, every `UNIQUE_KEY_COLUMN`, relationship key mapping,
relationship join condition, and representation-blind metric filter. A quoted
lowercase `"customer_id"` is not the same physical column as `CUSTOMER_ID`. If
any differ, do not register the raw source: create a relation or Virtual Schema
view that aliases them to the canonical names, or use F5 for a scalar entity
key. F5 does not remap relationship joins or filter columns.
Structured relationship mappings accept physical names that require SQL
quoting, such as `_parent` and `profile|object`; pass the raw catalog name
without surrounding double quotes.

For different physical dimension or fact expressions, create the attribute
atomically with `ADD_DIMENSION_WITH_BINDINGS` or `ADD_FACT_WITH_BINDINGS`.
Supply exactly one JSON binding for every active non-partitioned alternate; the
top-level expression binds the primary and every F3 partition automatically.
Do not include the primary or F3 partitions in the JSON. Mark authoritative
expressions `PREFER` and ordered substitutes `FALLBACK`. Use an explicit
`source_expression` of `NULL` when an alternate genuinely lacks the concept.
Do not use create-then-bind on a published model: validation correctly rejects
that incomplete intermediate state. Use `REPLACE_ATTRIBUTE_BINDING` when a
generated binding already exists; `ADD_ATTRIBUTE_BINDING` is only for an
unbound representation.
By default, the compiler chooses one representation that covers every required
attribute for the entity. It ranks binding role, binding priority, current
`PRIMARY` role, representation priority, then ID. Verify the choice and each expression in
`plan_json.selected_representations[].selected_bindings`. If no complete source
exists, compilation returns `SEMANTIC_REQUEST_080`; do not invent a cross-source
join or silently revert to a partial representation.

For an existing draft attribute, bindings may still be repaired sequentially.
Intermediate errors for attributes not yet bound do not reject a repairing
binding, but the model cannot be published until validation is clean. On a
published model, use the compound creation APIs so readers never observe an
invalid intermediate state.

Before `SET_PRIMARY_REPRESENTATION`, validate that every differing attribute
has an explicit binding on the target. Promotion preserves those explicit
bindings and leaves their compatibility defaults on the outgoing source; it
must not create two bindings for the same attribute and target representation.
Also verify that the target physically exposes every declared unique-key
column. If a traversed scalar relationship key uses F5.1, the target identity
binding must be a bare `DIRECT` reference to that canonical key; an alternate
binding such as `CAST(c."customer_id" AS DECIMAL(18,0))` is valid for routing
but cannot become the primary anchor. `SET_PRIMARY_REPRESENTATION` enforces
these prospective checks before changing roles and returns
`SEMANTIC_ADMIN_058` when the target can only remain an alternate.
If upgrading a model trapped by the older behavior, call
`SET_PRIMARY_REPRESENTATION` for the desired recovery target: the script repairs
stale default/explicit collisions and accepts the last clean validation run
after promotion marked it `STALE` only when the current primary fails the same
canonical-anchor checks. It still refuses targets with no clean validation
history or unrelated stale evidence.

For hot/cold data, use F3 `UNION` fusion only on a metric-leaf entity with
mergeable `SUM` or `COUNT` metrics — `AVG` on a partitioned entity is rejected
when it is defined (`SEMANTIC_MODEL_057`). Register the partition with
`ADD_ENTITY_REPRESENTATION_WITH_COVERAGE` on a draft and on a published model
alike: ordinary registration validates as F1 first and rejects the expected
partition key-set difference, so on a draft it leaves the model invalid and
blocks unrelated authoring until coverage is declared. If you do register
separately on a draft, call `SET_REPRESENTATION_COVERAGE_BATCH` immediately
afterwards, before adding any dimension or fact to that entity. The compound
call seeds compatibility bindings and validates the new representation plus
every coverage declaration as one candidate. Declare contiguous half-open
`[VALID_FROM, VALID_TO)` intervals:
the cold edge is open at the start, the hot edge is open at the end, and their
boundary timestamps are identical. Use exactly one qualified temporal column
and canonical predicates: `column >= VALID_FROM` and `column < VALID_TO`,
omitting the comparison for each `NULL` bound. Predicate timestamp literals
must exactly match the metadata; free-form coverage SQL is rejected. Set
`QUERY_TIMEOUT=60` before validating any partitioned entity, regardless of the
declared source kinds or whether a local view wraps a Virtual Schema.

After complete F3 coverage exists, `ADD_DIMENSION`, `ADD_FACT`, dimension
upsert, and the Semantic DDL `REPLACE DIMENSIONS` / `REPLACE FACTS` blocks seed
the governed expression on every active partition before validation. `SEMANTIC_MODEL_052` blocks certification
and lists every missing attribute/partition binding left by older or direct
catalog state.

To leave F3 when only one alternate remains, call
`REMOVE_ENTITY_REPRESENTATION` for that alternate. It removes the
representation-local attribute bindings and clears coverage on the surviving
primary as one validated candidate. Do not clear coverage first: genuine
partitions usually fail F1 key-set equality without coverage.
Before declaring coverage, confirm the entity appears as `BASE_ENTITY_NAME` for
an active metric in `SEMANTIC_CATALOG.METRICS`. `VALIDATE_MODEL` rejects
partitioning an entity used only as a joined dimension with
`SEMANTIC_MODEL_043`.

Do not use F3 for a partitioned entity that is only joined to supply dimensions,
for overlapping snapshots, or for non-additive/distinct/window metrics. Inspect
`plan_json.selected_representations[].partitions` and
`logical_plan.physical_plan.fusion_plan` to verify every physical source and
coverage predicate before publication.

Act on F3 compiler diagnostics directly: `_070` names the non-mergeable metric
and aggregate, `_074` names the unsupported partitioned joined dimension or
filter, and `_080` names the attribute and partition requiring
`ADD_ATTRIBUTE_BINDING`. Do not work around these refusals by removing coverage.

For overlapping Customer 360 sources with the same proven canonical key set, use F4
attribute fusion. Declare at most one representation `AUTHORITATIVE`; use
`PREFER` or `SUPPLEMENTAL` for the others. Set an attribute policy to
`COALESCE` only when overlapping non-null values must agree. Validation blocks
conflicts with `SEMANTIC_MODEL_045`. Use `RECONCILE` when the authoritative
source is allowed to win; conflicts are surfaced as `SEMANTIC_MODEL_046`
warnings and must be reviewed before publication.

F4 requires bindings on two representations and either a shared physical-column
unique key or a complete F5 semantic identity. It does not support F3 coverage
on the same entity. Keep `QUERY_TIMEOUT` bounded because validation compares
values across the sources. Inspect each selected binding's `fusion_strategy`
and `fusion_contributors`; confirm authority, source expressions, and F5
identity provenance.
F4 does not use aggregate materializations. Reconciled dimensions can group
grain-proven multi-fact plans because reconciliation runs inside every fact
branch. Reconciled facts cannot participate in multi-fact plans and fail with
`SEMANTIC_REQUEST_074`; model a canonical pre-reconciled measure source instead.

For F5, declare one semantic identity per entity and bind every active
representation. Use `DIRECT` when its expression already returns the semantic
key. Use `MAPPED` only with a certified two-column relation from the source-local
key to the semantic key. On a draft, use the separate calls below; on a
published model use the compound call documented in
`references/authoring-workflows.md`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY(
  '<model>', '<entity>', '<identity>', 'GLOBAL', '<data_type>', '<description>'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING(
  '<model>', '<identity>', '<primary_representation>', '<alias>.<key>', 'DIRECT'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING(
  '<model>', '<identity>', '<alternate_representation>', '<alias>.<local_key>', 'MAPPED'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_MAPPING_RELATION(
  '<model>', '<identity>', '<alternate_representation>',
  '<mapping_schema>', '<mapping_relation>', '<local_key_column>',
  '<semantic_key_column>', 'CERTIFIED'
);
```

Smoke-test local expressions and mapping joins first. Then set
`QUERY_TIMEOUT=60` and validate. Do not publish unless `_049` proves each local
key non-null and unique, every mapping total and one-to-one, and every canonical
key set equal to the primary. Never infer or fuzzy-match identities at runtime.
Composite identities, uncertified mappings, general relationship remapping, and
F3 plus F5 on one entity are unsupported; use a governed canonical view instead.
The anchored scalar `DIRECT` exception is described below.

F5.1 supports joined entities when the missing relationship endpoint is the
same scalar unique key anchored by the primary `DIRECT` identity binding and
the alternate also uses `DIRECT`. No extra relationship declaration is needed.
Compile a representative joined request and verify
`relationship_identity_remaps` names the relationship, side, representation,
unique key, and identity binding. `_050` means some representations remain
usable only for non-traversing requests; inspect `relationship_candidate_rejections`.
If `_080` says the relationship eliminated the last candidate, use a canonical
view or add a valid anchored `DIRECT` binding. `MAPPED`, composite, role-key,
and expression-valued relationship endpoints remain unsupported.

To abandon F5 or switch the entity to F3, remove declarations in dependency
order: `REMOVE_IDENTITY_MAPPING_RELATION` for every mapped binding,
`REMOVE_IDENTITY_BINDING` for every representation, then
`REMOVE_SEMANTIC_IDENTITY`. Do not edit catalog tables or remove a
representation first; representation removal refuses active identity bindings.
Apply the complete transition in one maintenance window and validate afterward.

Register relationships with `ADD_RELATIONSHIP`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  '<model>',
  '<rel_name>',
  '<from_entity>',
  '<to_entity>',
  '<join_condition>',  -- e.g. 'ol.order_id = o.order_id'
  '<cardinality>',     -- MANY_TO_ONE | ONE_TO_ONE | ONE_TO_MANY | MANY_TO_MANY
  '<join_type>',       -- INNER | LEFT
  '<fanout_policy>'    -- usually NULL unless explicitly required
);
```

Before adding a relationship, compare resolved endpoint types in
`EXA_ALL_COLUMNS`; do not rely on implicit casts. Validation blocks simple
equality joins across incompatible type families with `SEMANTIC_MODEL_051`.
To withdraw a relationship, call `REMOVE_RELATIONSHIP_KEY_MAPPING` for each
mapping in descending ordinal order, then `REMOVE_RELATIONSHIP`.

## Dimension Maintenance

Semantic DDL authors dimensions. A dimension takes the same clauses as a fact —
`ON ENTITY`, `AS`, `RETURNS`, and optionally `DISPLAY`, `COMMENT`, `FORMAT`,
`CERTIFIED`, `PRIVATE`. The object comes from the statement header.

```sql
ALTER SEMANTIC VIEW <model>.<object>
ADD OR REPLACE DIMENSION <dim_name>
  ON ENTITY <entity_alias>
  AS <expression>
  RETURNS <data_type>
  FORMAT '<format_hint>'
  DISPLAY '<display_name>'
  COMMENT '<business definition>'
  [PRIVATE] [CERTIFIED];
```

Set-level replacement, which decides the object's dimension membership:

```sql
ALTER SEMANTIC VIEW <model>.<object>
REPLACE DIMENSIONS (
  DIMENSION <name> ON ENTITY <entity> AS <expr> RETURNS <type> CERTIFIED,
  DIMENSION <name> ON ENTITY <entity> AS <expr> RETURNS <type> CERTIFIED
);
```

`PRIVATE` maps to the catalog's `IS_HIDDEN` — the column `DIMENSIONS` uses for
what `FACTS` calls `IS_PRIVATE`. Dry-run through `APPLY_SEMANTIC_DEFINITION`
first, as for any other definition.

Use the Lua admin scripts when DDL cannot express what you need:

- **removing one dimension** — `REMOVE_DIMENSION`; there is no single `DROP
  DIMENSION` form. A `REPLACE DIMENSIONS` block removes by omission, which is a
  different and blunter operation.
- **per-representation bindings** — `ADD_DIMENSION_WITH_BINDINGS` when the
  dimension is computed differently on, or absent from, an alternate
  representation.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  '<model>', '<object>', '<entity_alias>',
  '<dim_name>', '<expression>',
  '<data_type>', '<display_name>', '<description>',
  '<format_hint>', <is_certified>
);
```

## Metric Authoring

Use SQL-native DDL for metric authoring. Enable Semantic SQL for the session
first if using the DDL form:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

Single-metric add or replace:

```sql
ALTER SEMANTIC VIEW <model>.<object>
ADD OR REPLACE METRIC <metric_name>
  AS <aggregate-expression>
  ON ENTITY <base_entity>
  RETURNS <data_type>
  FORMAT '<format_hint>'
  DISPLAY '<display_name>'
  COMMENT '<business definition>'
  [ADDITIVE] [PUBLIC | PRIVATE] [CERTIFIED];
```

Filtered metric:

```sql
ALTER SEMANTIC VIEW <model>.<object>
ADD OR REPLACE METRIC <metric_name>
  AS SUM(<fact>)
  ON ENTITY <base_entity>
  RETURNS DECIMAL(18,2)
  FILTER (WHERE <dimension_name> = '<value>')
  FORMAT 'currency'
  DISPLAY '<display_name>'
  COMMENT '<definition>'
  ADDITIVE PUBLIC CERTIFIED;
```

Ratio metric:

```sql
ALTER SEMANTIC VIEW <model>.<object>
ADD OR REPLACE METRIC <metric_name>
  AS <numerator_metric> / NULLIF(<denominator_metric>, 0)
  ON ENTITY <base_entity>
  RETURNS DOUBLE
  FORMAT 'percent'
  DISPLAY '<display_name>'
  COMMENT '<definition>'
  PUBLIC CERTIFIED;
```

Apply without session preprocessing using `APPLY_SEMANTIC_DEFINITION`. Always
dry-run first (`TRUE`), then apply (`FALSE`):

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('<semantic-sql>', TRUE);
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('<semantic-sql>', FALSE);
```

Dry-run simulates the same catalog changes, runs `VALIDATE_MODEL`, and restores
the original model before returning. Proceed only when status is `DRY_RUN`;
`ERROR` includes the blocking validation rule and object. Validation history is
recorded, but no proposed fact, metric, membership, synonym, drop, or rename is
committed.

`REPLACE METRICS (...)` replaces the semantic object's visible metric
membership; it does not delete omitted metric definitions from the model
catalog. It may atomically move a synonym by assigning it to its new metric;
requested synonyms are released from prior metric owners before the block is
applied. Assigning one synonym to multiple metrics in the same block fails
validation. Use replacement for bootstrap or deliberate surface resets, not
metric removal.

Remove or rename one metric, or remove one fact, through Semantic DDL. Dry-run
each statement before applying it:

```sql
ALTER SEMANTIC VIEW <model>.<object> DROP METRIC <metric_name>;

ALTER SEMANTIC VIEW <model>.<object> DROP FACT <fact_name>;

ALTER SEMANTIC VIEW <model>.<object>
RENAME METRIC <old_name> TO <new_name>;
```

`DROP METRIC` removes membership from the named object and deactivates the
metric when no other object uses it. It is rejected and rolled back when active
metrics still depend on it. `DROP FACT` retires the fact from the model, since a
fact belongs to its entity, and is refused while any metric is built on it. `RENAME METRIC` preserves the metric ID, rewrites
dependent metric expressions, and retains the old name as a synonym, so verified
requests, structured requests and Semantic SQL that ask for the old name keep
working, and their output column keeps the name they asked for. On a published
model the apply republishes, so the published view lists the new column.

## Fusion Declaration Document

The whole tier-2 fusion layer of a model in one JSON document, applied
atomically with a dry run, and exportable back for review or Git:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION('<model>', '<json>', TRUE);
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION('<model>', '<json>', FALSE);
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION('<model>', NULL);
```

**Prefer this over the individual F1-F5 scripts on a published model, where they
do not work at all.** Given an entity that already has an F5 identity, each of
`ADD_ENTITY_REPRESENTATION`, `ADD_IDENTITY_BINDING`,
`ADD_IDENTITY_MAPPING_RELATION` and `SET_REPRESENTATION_AUTHORITY` is refused on
its own, because each alone leaves the model invalid. The document is the unit
the database actually requires.

```json
{"entities": {
  "customer": {
    "identity": {"name": "cid", "kind": "GLOBAL", "data_type": "DECIMAL(18,0)"},
    "representations": [
      {"name": "crm", "source_kind": "RELATION",
       "source_schema": "CRM", "source_object": "CUSTOMERS_CRM",
       "priority": 20, "authority": "AUTHORITATIVE",
       "identity_binding": {"source_expression": "c.account_id",
                            "binding_kind": "MAPPED",
                            "mapping": {"source_schema": "CRM",
                                        "source_object": "CUSTOMER_XREF",
                                        "source_local_column": "ACCOUNT_ID",
                                        "semantic_key_column": "CUSTOMER_ID",
                                        "certification_status": "CERTIFIED"}}}],
    "attribute_bindings": [
      {"attribute_type": "DIMENSION", "attribute_name": "customer_name",
       "representation": "crm", "source_expression": "c.display_name",
       "binding_role": "PREFER", "binding_priority": 1}],
    "attribute_policies": [
      {"attribute_type": "DIMENSION", "attribute_name": "customer_name",
       "strategy": "RECONCILE"}]}}}
```

**A supplemental source that does not carry every column the primary's
dimensions reference declares its bindings inside the representation.** This is
the ordinary Customer-360 case — a CRM extract has `LOYALTY_TIER` and no
`REGION` — and entity-level `attribute_bindings` are too late on a published
model, because the representation is registered and validated before that phase
runs:

```json
{"entities": {"customer": {"representations": [
  {"name": "crm", "source_schema": "CRM", "source_object": "CUSTOMER_CRM",
   "priority": 20, "authority": "AUTHORITATIVE",
   "attribute_bindings": [
     {"attribute_type": "DIMENSION", "attribute_name": "customer_region",
      "source_expression": "CAST(NULL AS VARCHAR(20))",
      "binding_role": "FALLBACK", "binding_priority": 2}]}]}}}
```

Omit `representation` inside a representation-scoped binding — the enclosing
object is the representation. `ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS`
accepts the same list as a fourth declaration kind, so the single call and the
document reach equally far. Do not pre-join the source into a widened view for
this; the null-cast `FALLBACK` binding is what replaced that workaround.

Rules to work by:

- Run `ALTER SESSION SET QUERY_TIMEOUT=60` first. Multi-representation key probes
  require it (`SEMANTIC_MODEL_041`) and it is the first thing an unset session
  hits.
- Dry-run every document before applying it. Fusion validation runs data probes
  against possibly remote sources, so "would this validate?" is worth asking
  without mutating anything.
- A refusal arrives as `STATUS = 'ERROR'` in the result row, not as an
  exception — check the column, including for a malformed document.
- Re-applying an exported document is a no-op (`APPLIED_COUNT = 0`). Export is
  the way to review what fusion a model actually carries, and it returns exactly
  one row — the whole layer as one document, with `model` always set, so it can
  be re-applied without merging anything.
- It is an upsert: the document declares what it contains and does not remove
  what it omits. Use `REMOVE_ENTITY_REPRESENTATION`, `REMOVE_IDENTITY_BINDING`
  and friends to take a declaration away.
- Unknown keys are refused by name (`SEMANTIC_FUSION_011`). Do not guess key
  names; export an existing fused model to see the exact shape.
- A representation binding that names an attribute the entity does not have is
  refused with `SEMANTIC_ADMIN_217`, and nothing is registered.

## Validation and Publication

Validate after every structural change:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('<model>');
```

Publish when validation is clean:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('<model>');
```

`PUBLISH_MODEL` validates internally and aborts if any errors remain.
Publishing creates the guarded views in `SEMANTIC_<MODEL>` schema.
It also publishes model and semantic-object descriptions as schema/view
comments and field descriptions as inline view-column comments. Exasol does
not support assigning view-column comments independently after creation, so
update semantic descriptions and republish instead. Keep using
`SEMANTIC_AGENT.FIELDS_FOR_AGENT` as the richer field discovery surface. After
publishing, verify both catalog comments and agent metadata:

```sql
SELECT VIEW_NAME, VIEW_COMMENT
FROM EXA_ALL_VIEWS
WHERE VIEW_SCHEMA = 'SEMANTIC_<MODEL>';

SELECT COLUMN_TABLE, COLUMN_NAME, COLUMN_COMMENT
FROM EXA_ALL_COLUMNS
WHERE COLUMN_SCHEMA = 'SEMANTIC_<MODEL>';

SELECT FIELD_KIND, FIELD_NAME, DESCRIPTION
FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
WHERE MODEL_NAME = '<model>' AND OBJECT_NAME = '<object>';
```

During maintenance, re-read source comments and compare them with semantic
descriptions. Treat changed comments as drift requiring review; update the
semantic catalog deliberately and republish rather than mutating generated
view comments directly.

## Propose Model Evolution

Do not apply inferred model changes directly. Record one typed F7 proposal for
each new concept, identity, representation equivalence, authority change, or
drift repair:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION(
  '<model>',
  '<NEW_CONCEPT|NEW_IDENTITY|REPRESENTATION_EQUIVALENCE|AUTHORITY_CHANGE|DRIFT_REPAIR>',
  '<object_type>',
  '<object_name>',
  '<proposed_change_json>',
  '<evidence_and_rationale>'
);
```

Use an existing `ENTITY` target for identity, representation-equivalence, and
authority proposals. `NEW_CONCEPT` may target a proposed `SEMANTIC_OBJECT`,
`ENTITY`, `RELATIONSHIP`, `DIMENSION`, `FACT`, or `METRIC`. Put executable DDL,
source evidence, expected validation effects, and rollback notes in the JSON;
never put ambiguous runtime matching instructions there.

Review pending work through
`SEMANTIC_AGENT.MODEL_EVOLUTION_REVIEW_QUEUE`. Only a human reviewer certifies:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION(
  <suggestion_id>, '<CERTIFIED|REJECTED>', '<review_note>'
);
```

Certification returns `NO_CATALOG_MUTATION`. After certification, apply the
reviewed change with the existing admin scripts, smoke-test expressions,
validate, and publish. Re-propose if the suggestion is stale; do not bypass the
version guard or edit `SYS_SEMANTIC` directly.

## Governance Metadata

Add agent instructions after publication:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  '<model>',
  '<scope_type>',   -- MODEL | SEMANTIC_OBJECT | METRIC | DIMENSION | ENTITY | FACT
  '<scope_name>',
  '<kind>',         -- GENERAL | DEFINITION | AMBIGUITY | POLICY | PRECONDITION | PREFERENCE | SAFETY | STYLE
  '<instruction_text>',
  '<applies_to_role>',  -- NULL for all roles
  <priority>
);
```

Register verified queries:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY(
  '<model>', '<object>',
  '<query_name>',
  '<natural_language_question>',
  '<request_json>',
  '<expected_result_shape_or_null>',
  <is_onboarding_example>
);
```

Add synonyms so agents can discover metrics by alternative names:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  '<model>', '<object_type>', '<canonical_name>', '<synonym>', '<source>'
);
```

`<object_type>` must match the canonical object's catalog type exactly:
`SEMANTIC_OBJECT`, `ENTITY`, `DIMENSION`, `FACT`, or `METRIC`. For example,
use `DIMENSION` rather than `METRIC` when adding a synonym for a dimension.

## Introspection

After enabling Semantic SQL for the session:

```sql
SHOW SEMANTIC VIEWS;
SHOW SEMANTIC METRICS IN <model>.<object>;
DESCRIBE SEMANTIC METRIC <model>.<object>.<metric>;
SHOW SEMANTIC DIMENSIONS FOR METRIC <model>.<object>.<metric>;
EXPLAIN SEMANTIC METRIC <model>.<object>.<metric>;
EXPORT SEMANTIC METRIC <model>.<object>.<metric>;
EXPORT SEMANTIC VIEW <model>.<object>;
EXPORT SEMANTIC MODEL <model>;
```

## Safety

- Do not expose private metrics or hidden fields outside role-scoped views.
- Validate before publishing. Never call `PUBLISH_MODEL` without a clean
  `VALIDATE_MODEL` pass.
- Every `REPLACE ...` block replaces visible membership only; omitted catalog
  definitions remain. Use `DROP METRIC`, `DROP FACT` or `REMOVE_DIMENSION` for intentional
  removal, and the `ADD OR REPLACE` forms for incremental changes.
- A `REPLACE` block renumbers the object's columns. One statement carrying all
  three blocks numbers them dimensions, facts, then metrics from 1; separate
  statements interleave. OSI export carries these ordinals to the imported
  model, so it is a published column order — restore a model with one combined
  statement, not several.
- Do not hardcode physical table column references in metric expressions when
  a fact exists — reuse the fact layer.
- Do not let historical SQL override physical grain, relationship, or comment
  evidence; use it to prioritize and name the model, not to invent semantics.
- Dry-run every `APPLY_SEMANTIC_DEFINITION` call before the live apply.
