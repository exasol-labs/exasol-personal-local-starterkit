# Authoring Workflows

Use these examples when building or maintaining an Exasol Semantic Views model.
All `SEMANTIC_ADMIN` calls require `EXECUTE SCRIPT`.

## Inspect the Physical Schema

```sql
SELECT TABLE_NAME, TABLE_COMMENT, TABLE_ROW_COUNT
FROM EXA_ALL_TABLES
WHERE TABLE_SCHEMA = 'MART'
ORDER BY TABLE_NAME;
```

```sql
SELECT VIEW_NAME, VIEW_COMMENT
FROM EXA_ALL_VIEWS
WHERE VIEW_SCHEMA = 'MART'
ORDER BY VIEW_NAME;
```

```sql
SELECT COLUMN_TABLE, COLUMN_NAME, COLUMN_TYPE, COLUMN_IS_NULLABLE, COLUMN_COMMENT
FROM EXA_ALL_COLUMNS
WHERE COLUMN_SCHEMA = 'MART'
ORDER BY COLUMN_TABLE, COLUMN_ORDINAL_POSITION;
```

Read non-null comments before sampling. Carry verified table/view meaning into
model, entity, grain, and semantic-object descriptions; carry verified column
meaning into fact and dimension descriptions. Enrich rather than merely copy:
record units, aggregation behavior, filters, exclusions, and sensitivity when
the source comment omits them. If comments conflict with data or constraints,
flag the conflict for review.

If the source schema already has reporting traffic, mine historical workload
queries before finalizing the semantic shape. Once a semantic layer is
published, `SYS_SEMANTIC.QUERY_LOG` can refine naming and coverage.

The most useful Exasol history sources are:

1. `EXA_DBA_AUDIT_SQL` for executed SQL, statement class, duration, and
   resource usage.
2. `EXA_DBA_AUDIT_SESSIONS` and `EXA_DBA_SESSIONS_LAST_DAY` for user, client,
   driver, host, login/logout, and success/failure context.
3. `EXA_DBA_PROFILE_LAST_DAY` and `EXA_USER_PROFILE_LAST_DAY` for operator-
   level evidence, touched objects, row counts, and `REMARKS` that often name
   join and filter columns.
4. `EXA_USAGE_LAST_DAY`, `EXA_USAGE_HOURLY`, `EXA_USAGE_DAILY`, and
   `EXA_USAGE_MONTHLY` for aggregate load trends when fine-grained history is
   not available.

Most DBA-prefixed history tables require `SELECT ANY DICTIONARY`. Use the
richest source available for the workload you are studying.

Useful usage-shape queries:

```sql
SELECT HANDLE_TYPE, MODEL_NAME, USER_NAME, CLIENT_NAME, STATUS, REQUEST_TIME
FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT
WHERE MODEL_NAME = 'sales'
ORDER BY REQUEST_TIME DESC;
```

```sql
SELECT REQUESTED_METRICS, REQUESTED_DIMENSIONS, COUNT(*) AS QUERY_COUNT
FROM SYS_SEMANTIC.QUERY_LOG
WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales')
  AND STATUS = 'OK'
GROUP BY REQUESTED_METRICS, REQUESTED_DIMENSIONS
ORDER BY QUERY_COUNT DESC;
```

```sql
SELECT ERROR_CODE, COUNT(*) AS ERROR_COUNT
FROM SYS_SEMANTIC.QUERY_LOG
WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales')
  AND STATUS <> 'OK'
GROUP BY ERROR_CODE
ORDER BY ERROR_COUNT DESC;
```

Treat historical query shape as evidence for prioritization, not as a source of
truth for grain or relationships. The schema, comments, and constraints still
win when they disagree with usage patterns.

When translating history into semantic candidates:

- Repeated `GROUP BY` columns become candidate dimensions.
- Repeated `WHERE` predicates become candidate filter dimensions or filtered
  metrics.
- Repeated `SUM`, `COUNT`, `MIN`, `MAX`, `AVG`, and `COUNT DISTINCT` patterns
  become candidate metrics.
- Repeated arithmetic over aggregates becomes a derived or ratio metric.
- Columns repeatedly seen in joins or in profiling `REMARKS` become relationship
  or fact candidates.
- Repeated labels, aliases, and business phrases become synonym candidates.

Use these rules as a ranking mechanism, not as an automatic generator. The
physical schema still decides grain and relationship truth.

To find likely foreign key columns (columns whose names end in `_ID` or `_KEY`
and appear in more than one table):

```sql
SELECT COLUMN_NAME, COUNT(DISTINCT COLUMN_TABLE) AS TABLE_COUNT
FROM EXA_ALL_COLUMNS
WHERE COLUMN_SCHEMA = 'MART'
  AND (COLUMN_NAME LIKE '%_ID' OR COLUMN_NAME LIKE '%_KEY')
GROUP BY COLUMN_NAME
HAVING COUNT(DISTINCT COLUMN_TABLE) > 1
ORDER BY TABLE_COUNT DESC, COLUMN_NAME;
```

This query produces candidates, not a relationship list. Prefer one canonical
path between two entities. Do not add a direct edge for a denormalized foreign
key when an existing path already expresses the same business relationship;
parallel paths can make metric-to-dimension compilation ambiguous. Keep a
shortcut only when it has distinct role semantics and path selection remains
unambiguous.

## Create the Model

Create the model before registering any entities. `PUBLISHED_SCHEMA` is the
schema where published semantic views will be created; use `NULL` when no
owner role is required.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(
  'sales',
  'SEMANTIC_SALES',
  'Sales domain semantic model',
  NULL
);
```

## Register Entities

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'order_line',
  'MART',
  'ORDER_LINES',
  'ol',
  'CAST(ol.order_id AS VARCHAR(36)) || ''-'' || CAST(ol.line_id AS VARCHAR(36))',
  'One row per order line',
  'One row per order line item'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'order',
  'MART',
  'ORDERS',
  'o',
  'o.order_id',
  'One row per order',
  'One row per customer order'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'customer',
  'MART',
  'CUSTOMERS',
  'c',
  'c.customer_id',
  'One row per customer',
  'One row per customer account'
);
```

Entity aliases are emitted as regular SQL identifiers. Keep them short and
unique, and do not use words marked `RESERVED` in `SYS.EXA_SQL_KEYWORDS`.

## Register Equivalent Representations

Use F1 representations only when each source has the same grain, identity,
stable alias, and semantic/key columns. `ADD_ENTITY` already created the
`primary` representation. Declare its structured unique key before adding an
alternate; validation queries every source to prove key uniqueness and exact
key-set equality, then promotion can proceed:

Before `ADD_ENTITY_REPRESENTATION`, compare exact `EXA_ALL_COLUMNS.COLUMN_NAME`
values for the primary-key expression, unique-key columns, relationship key
mappings, join-condition columns, and representation-blind metric filters.
Set `QUERY_TIMEOUT=60` before adding or validating any alternate. The guard
applies to every multi-representation key probe because a local view may hide a
Virtual Schema dependency and local scans can also be expensive.
F2 binds only dimensions and facts; it cannot remap identity or join SQL. Case
differences in quoted identifiers are physical differences. If a source uses
`"customer_id"` where the model requires `CUSTOMER_ID`, normalize it first:

```sql
CREATE VIEW MART.CUSTOMERS_CANONICAL AS
SELECT
  "customer_id" AS CUSTOMER_ID,
  "loyalty_tier" AS LOYALTY_TIER
FROM SRC_MONGO_CUSTOMERS."CUSTOMERS";
```

Register the canonicalizing view when relationship or filter columns differ.
For a scalar entity key alone, the F5 identity workflow below can bind a
source-local key without changing the source.

```sql
ALTER SESSION SET QUERY_TIMEOUT=60;

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION(
  'sales', 'order', 'lakehouse', 'VIRTUAL_SCHEMA',
  'VS_LAKEHOUSE', 'ORDERS', 20, 'MANUAL'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');

EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION(
  'sales', 'order', 'lakehouse'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
```

A clean current validation is necessary evidence, but promotion additionally
checks the prospective primary contract before mutation. The target must expose
every physical unique-key column. Where an F5.1 identity anchors a traversed
scalar relationship key, its target binding must be a bare `DIRECT` reference
to that key. A cast or source-local expression may remain an alternate binding,
but promotion rejects it with `SEMANTIC_ADMIN_058` instead of invalidating the
model. For recovery from an older trapped promotion, restore a canonical target;
the gate accepts the last zero-error run after it was marked `STALE` only when
the current primary fails the canonical-anchor checks.

Promotion is manual/static unless F2 attribute bindings are present. To remove
a representation, first remove its attribute bindings and promote another one
if it is primary. Validation probe failures are blocking, so run it as a user
that can query every source. Do not leave temporal partitions modeled as F1
equivalents; configure every active representation through the F3 coverage
workflow below. Use F4 for row reconciliation and F5 when those sources need a
certified cross-system identity mapping.
Resolve local catalog errors before retrying validation. Remote equivalence
probes are deferred while those errors exist, then run in full once metadata is
clean; every representation's key cardinality is scanned once per declared key.

Promotion gives explicit target bindings precedence. Compatibility defaults
move only for attributes without an explicit target binding; otherwise they
remain on the outgoing representation. After promotion, inspect
`SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS` and verify there is at most one active
binding per attribute and representation. Older F2 installs could create stale
default/explicit collisions and block rollback. Re-running
`SET_PRIMARY_REPRESENTATION` toward the intended recovery source now repairs
those collisions before applying the validation gate. It also rejects targets
that cannot prospectively anchor canonical unique and relationship keys.

### Bind Dimensions and Facts Per Representation

`ADD_DIMENSION` and `ADD_FACT` create a preferred binding on `primary`
automatically. On an entity with complete F3 coverage, they also seed the same
governed expression on every active partition before validation. Missing
partition bindings block certification with `SEMANTIC_MODEL_052`. When an
equivalent representation uses different physical columns, create the
attribute and all representation bindings atomically. `BINDINGS_JSON` must
contain exactly one entry for every active non-partitioned alternate. Do not
include the primary or F3 partitions because the top-level expression supplies
all of them:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION_WITH_BINDINGS(
  'sales', 'customers', 'customer', 'customer_name',
  'c.customer_name', 'VARCHAR(200)', 'Customer name', NULL, NULL, TRUE,
  '[
    {"representation_name":"mdm","source_expression":"c.canonical_name","binding_role":"PREFER","binding_priority":1},
    {"representation_name":"salesforce","source_expression":"c.account_name","binding_role":"FALLBACK","binding_priority":1}
  ]'
);
```

Use `ADD_FACT_WITH_BINDINGS` with the same JSON shape for facts. An alternate
that genuinely lacks the concept must declare
`"source_expression":"NULL"`; never synthesize that fallback silently.
`ADD_ATTRIBUTE_BINDING` remains a repair operation for an existing attribute,
not the initial heterogeneous-attribute workflow.

Smoke-test each expression against its target representation before adding the
binding. A compiled request uses one representation per entity; that source
must provide bindings for every requested dimension and transitive metric fact.
`PREFER` outranks `FALLBACK`, followed by lower binding priority, the current
`PRIMARY` role, lower representation priority, and representation ID. F2 does
not coalesce rows or values across sources. Inspect
`plan_json.selected_representations[].selected_bindings` to verify the choice.

### Reconcile Overlapping Attribute Values

F4 applies to overlapping representations that pass unique-grain and exact
canonical key-set proofs through F1 or F5. Give one source semantic authority, classify the
others, and then choose a policy per dimension or fact:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(
  'customer_360', 'customer', 'mdm', 'AUTHORITATIVE'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(
  'customer_360', 'customer', 'crm', 'SUPPLEMENTAL'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY(
  'customer_360', 'DIMENSION', 'customer_name', 'RECONCILE'
);
```

Use `PREFER` for ordinary F2 single-source selection. Use `COALESCE` for null
fallback only when every overlapping non-null value agrees; validation reports
conflicts as blocking `SEMANTIC_MODEL_045`. Use `RECONCILE` when exactly one
bound representation is `AUTHORITATIVE` and its value should win; observed
conflicts remain visible as `SEMANTIC_MODEL_046` warnings.

Before validation, require bindings on at least two representations, either one
shared physical-column unique key or the complete F5 identity graph below, and
`QUERY_TIMEOUT` between 1 and 60 seconds. Do not configure F3 coverage on the
same entity. After compiling representative requests,
inspect `selected_bindings[].fusion_contributors` for ordered authority,
binding IDs, sources, expressions, and identity mapping IDs.
F4 bypasses aggregate materializations. Reconciled dimensions may group a
grain-proven multi-fact plan; the compiler applies their key-preserving joins in
every fact branch. Reconciled facts remain unsupported in multi-fact plans and
fail with `SEMANTIC_REQUEST_074`; use a canonical pre-reconciled measure source
for that execution shape.

### Map Cross-System Entity Identity

Use F5 only for deterministic scalar identity. Identity names are unique within
the model, and an entity can have one active semantic identity. On a published
multi-representation model, add the identity, every binding, and any mapping
relations as one validated candidate:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY_WITH_BINDINGS(
  'customer_360', 'customer', 'customer_identity', 'GLOBAL',
  'DECIMAL(18,0)', 'Certified customer identity',
  '[
    {"representation_name":"primary","source_expression":"c.customer_id","binding_kind":"DIRECT"},
    {"representation_name":"crm","source_expression":"c.account_id","binding_kind":"MAPPED",
     "mapping":{"source_schema":"IDENTITY_MAP","source_object":"CUSTOMER_XREF",
                "source_local_column":"ACCOUNT_ID","semantic_key_column":"CUSTOMER_ID",
                "certification_status":"CERTIFIED"}}
  ]'
);
```

The compound call requires exactly one binding for every active representation
and rolls the entire candidate back if published validation fails. The separate
`ADD_SEMANTIC_IDENTITY`, `ADD_IDENTITY_BINDING`, and
`ADD_IDENTITY_MAPPING_RELATION` calls remain suitable while building a draft.

If the published entity already has the identity and the new source uses a
different physical key, register the representation and binding atomically:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING(
  'customer_360', 'customer', 'mongo', 'VIRTUAL_SCHEMA',
  'SRC_MONGO_CUSTOMERS', 'CUSTOMERS', 20, 'MANUAL',
  'customer_identity', 'CAST(c."customer_id" AS DECIMAL(18,0))',
  'DIRECT', NULL
);
```

For `MAPPED`, pass `MAPPING_JSON` with `source_schema`, `source_object`,
`source_local_column`, `semantic_key_column`, and `certification_status`.
The compound call seeds explicit dimension and fact bindings from the governed
expressions. Smoke-test those expressions against the new source first. The
call normalizes representation identity but does not accept custom F2 attribute
remapping: if canonical attributes are renamed, nested, or split across child
relations, expose them through a canonicalizing view before registration.

On a draft, inspect the returned `GENERATED_BINDING_ISSUE_COUNT` and
`GENERATED_BINDING_ISSUES`. Replace each generated expression that cannot
resolve before continuing:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING(
  'customer_360', 'DIMENSION', 'customer_plan', 'mongo',
  'NULL', 'FALLBACK', 2
);
```

Replacement is prospective: it can remove existing draft errors, while a
candidate that introduces a new error is restored automatically. Do not call
`ADD_ATTRIBUTE_BINDING` for a generated row; `_024` directs duplicate callers
to replacement or explicit removal.

The mapping relation must be queryable by the validating user and contain one
non-null semantic key for every source-local key, with no duplicate local or
semantic key. Set `QUERY_TIMEOUT=60`; `VALIDATE_MODEL` proves local uniqueness,
mapping totality and bijection, and bidirectional canonical key-set equality.
Treat `_047`, `_048`, and `_049` as blocking identity failures. Do not use
probabilistic matches, confidence thresholds, or an uncertified crosswalk.

F5 supplies the join key for F4 `COALESCE` and `RECONCILE`. Verify
`semantic_identity_id`, `identity_binding_id`, and `identity_mapping_id` in each
fusion contributor. F5 does not rewrite relationship endpoint mappings,
free-form filters, composite identities, partitioned F3 plans, or multi-fact
reconciliation. F5.1 is the narrow relationship exception: a structured scalar
endpoint matching a declared unique key can use an alternate `DIRECT` identity
expression when the primary `DIRECT` binding is exactly that key. No new DDL is
needed. Compile a traversing request and inspect `relationship_identity_remaps`.
`MAPPED`, role-key, composite, and expression endpoint shapes still require a
governed canonical view. `_050` and `relationship_candidate_rejections` identify
alternates excluded only for joined requests; `_080` names the relationship
when none remain.

To retract an identity experiment or move the entity to F3, unwind F5 in this
order:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_MAPPING_RELATION(
  'customer_360', 'customer_identity', 'crm'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING(
  'customer_360', 'customer_identity', 'crm'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING(
  'customer_360', 'customer_identity', 'primary'
);
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY(
  'customer_360', 'customer', 'customer_identity'
);
```

Each API refuses active dependents. `REMOVE_ENTITY_REPRESENTATION` likewise
refuses active identity bindings rather than deleting them implicitly. Complete
all removals before validation because intermediate states intentionally fail
the complete-identity rule. Once the identity is gone, declare F3 coverage and
validate again with a bounded `QUERY_TIMEOUT`.

When several columns are renamed, add all required bindings one at a time
before the final `VALIDATE_MODEL`. Intermediate validation errors for the
remaining unbound attributes are expected. `ADD_ATTRIBUTE_BINDING` treats each
call as a repair: it accepts a binding that removes errors without introducing
new ones, but rolls back malformed bindings. Publication remains blocked until
the complete representation validates cleanly.

### Fuse Hot and Cold Partitions

F3 `UNION` fusion applies only to metric-leaf entities and mergeable `SUM` or
`COUNT` states — `AVG` on a partitioned entity is refused when it is defined
(`SEMANTIC_MODEL_057`).

Register the partition and its coverage as **one** candidate with
`ADD_ENTITY_REPRESENTATION_WITH_COVERAGE`. Temporal partitions intentionally
have different key sets, so a partition registered without coverage is
validated as an F1 *equivalent* and fails on key cardinality
(`SEMANTIC_MODEL_038`); on a draft that failure is not raised at registration
but blocks every later authoring call on the model until coverage exists. If
you do register separately on a draft, call
`SET_REPRESENTATION_COVERAGE_BATCH` immediately afterwards, before adding any
dimension or fact to that entity.

Before declaring coverage, verify the entity is the base of an active metric:

```sql
SELECT METRIC_NAME, BASE_ENTITY_NAME
FROM SEMANTIC_CATALOG.METRICS
WHERE UPPER(MODEL_NAME) = UPPER('sales')
  AND UPPER(BASE_ENTITY_NAME) = UPPER('order');
```

If this returns no rows, stop. F3 cannot fuse that entity when it is used only
as a joined dimension, and validation will fail with `SEMANTIC_MODEL_043`.

Declare a certified SQL predicate and half-open interval for every active
representation:

```sql
ALTER SESSION SET QUERY_TIMEOUT=60;

EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH(
  'sales', 'order',
  '[{"representation_name":"lakehouse",'
  || '"coverage_predicate":"o.order_ts < TIMESTAMP ''''2026-01-01 00:00:00''''",'
  || '"valid_from":null,"valid_to":"2026-01-01 00:00:00"},'
  || '{"representation_name":"primary",'
  || '"coverage_predicate":"o.order_ts >= TIMESTAMP ''''2026-01-01 00:00:00''''",'
  || '"valid_from":"2026-01-01 00:00:00","valid_to":null}]'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
```

The batch must name every active representation exactly once. It updates the
whole set before one validation and restores the whole previous set on failure.
This is mandatory when initializing, clearing, or repartitioning F3 on a
published model; the first sequential declaration is necessarily incomplete.

If the new partition itself is not registered on a published model, combine
registration with that same complete JSON set:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE(
  'sales', 'order', 'lakehouse', 'RELATION',
  'ARCHIVE', 'ORDERS', 20, 'DAILY',
  '[{"representation_name":"lakehouse",'
  || '"coverage_predicate":"o.order_ts < TIMESTAMP ''''2026-01-01 00:00:00''''",'
  || '"valid_from":null,"valid_to":"2026-01-01 00:00:00"},'
  || '{"representation_name":"primary",'
  || '"coverage_predicate":"o.order_ts >= TIMESTAMP ''''2026-01-01 00:00:00''''",'
  || '"valid_from":"2026-01-01 00:00:00","valid_to":null}]'
);
```

The compound call seeds explicit bindings from existing dimension and fact
expressions, then validates the complete F3 candidate. If the new source uses
different physical expressions, expose canonical columns through a view first;
do not accept generated bindings that fail source validation.

The first partition must have no `VALID_FROM`, the last no `VALID_TO`, and each
adjacent boundary must match exactly. Each predicate must be canonical half-open
SQL over one qualified temporal column: `column >= VALID_FROM` and
`column < VALID_TO`, omitting comparisons for `NULL` bounds. Its timestamp
literals must exactly match the metadata. Validation rejects partial,
overlapping, gapped, free-form, or mismatched coverage. Clear coverage by
passing `NULL` for the predicate and both bounds on every representation.

Compile representative requests and inspect
`selected_representations[].partitions` plus
`logical_plan.physical_plan.fusion_plan.partitions`. Confirm that each source,
binding, predicate, and boundary is present and that generated SQL aggregates
each partition before `UNION ALL`. Stop if the entity is only a joined dimension
or the metric uses distinct, window, or another non-mergeable aggregate.
Compiler refusals identify the affected metric/aggregate (`_070`), joined
dimension or filter and entity (`_074`), or missing attribute and partition
(`_080`). For `_080`, add the named binding with `ADD_ATTRIBUTE_BINDING`; do not
remove temporal coverage to force single-source compilation.

## Rebuild an Existing Model

### Published Model Maintenance Boundary

Publication does not fork an immutable draft. Admin scripts mutate the active
version that the published preprocessor compiles. Representation additions,
attribute-binding removals, unique-key mutations, and coverage changes validate
prospectively on published models. On error they restore the prior catalog and
clean validation before returning `SEMANTIC_ADMIN_094` (`SEMANTIC_ADMIN_059`
for coverage), leaving the published surface queryable. This does not create a
general draft, and publish history is audit metadata rather than a queryable
catalog snapshot.
Use `SET_REPRESENTATION_COVERAGE_BATCH` for a complete F3 transition; it avoids
the invalid intermediate state created by sequential declarations.
Every published mutator revalidates before returning. Valid standalone changes
therefore remain queryable without a manual `VALIDATE_MODEL`. Use the compound
F3, key, representation, and identity operations where the standalone first
step would be invalid; prospectively guarded operations reject and restore an
incomplete candidate rather than persisting it.

For an existing published model, assemble and smoke-test the full change set
before the maintenance window. Apply sequential representation, binding,
coverage, authority, and metric operations without pausing, run
`VALIDATE_MODEL`, resolve every error, and republish when the visible contract
changes. If uninterrupted consumers are required, build and validate a separate
model/schema and cut clients over externally; in-place zero-downtime drafts are
not supported yet.

Bootstrap scripts are not idempotent. Prefer incremental add/replace operations
for maintenance. For an intentional full rebuild, inspect and export anything
that must survive, then remove only the target model:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
EXPORT SEMANTIC MODEL sales;

EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('sales');
```

The drop removes model-owned metadata and its exclusively referenced published
schema, but leaves physical source schemas such as `MART` intact. Re-run
`CREATE_MODEL` and the remaining bootstrap steps only after `DROP_MODEL`
succeeds. Do not use installer `--reset` for a single-model rebuild; reset is a
database-wide extension reinstall that removes unrelated semantic models too.

## Declare Grain Proofs

Declare each unique key before its columns. Composite key columns must use
contiguous ordinals starting at 1. Use either `COLUMN_NAME` or `EXPRESSION` for
each component, never both. `COLUMN_NAME` preserves supplied source casing and
falls back to uppercase for ordinary unquoted identifiers; document-source
columns beginning with `_`, such as `_id` and `_parent`, are supported. Use
`EXPRESSION` for computed keys or explicitly quoted references such as
`li."order_id"`.

```sql

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY(
  'sales', 'order_line', 'order_line_pk', 'PRIMARY',
  'Order-line row grain', 'NATIVE'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN(
  'sales', 'order_line', 'order_line_pk', 'order_id', NULL, 1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN(
  'sales', 'order_line', 'order_line_pk', 'line_id', NULL, 2
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY(
  'sales', 'order', 'order_pk', 'PRIMARY',
  'Order row grain', 'NATIVE'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN(
  'sales', 'order', 'order_pk', 'order_id', NULL, 1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY(
  'sales', 'customer', 'customer_pk', 'PRIMARY',
  'Customer row grain', 'NATIVE'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN(
  'sales', 'customer', 'customer_pk', 'customer_id', NULL, 1
);
```

For a new key on a published model, avoid the invalid empty-key intermediate:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS(
  'sales', 'order_line', 'order_line_pk', 'PRIMARY',
  'Order-line row grain', 'NATIVE',
  '[{"ordinal_position":1,"column_name":"order_id"},'
  || '{"ordinal_position":2,"column_name":"line_id"}]'
);
```

The complete key is validated once and is removed automatically if validation
fails. Use the sequential key calls only while the model is still a draft or
when updating an already valid key.

Remove a mistaken declaration from a draft in reverse dependency order:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_COLUMN(
  'sales', 'customer', 'customer_pk', 1
);
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY(
  'sales', 'customer', 'customer_pk'
);
```

`REMOVE_UNIQUE_KEY` refuses while columns remain. On a published model, this
sequential removal is unreachable because the final column would leave an empty key.
Remove the complete published declaration instead:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_WITH_COLUMNS(
  'sales', 'customer', 'customer_pk'
);
```

The complete inverse validates before deleting rows and restores the key when
another declaration still depends on it.

## Register Semantic Object

```sql

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(
  'sales',
  'SALES',
  'order_line',
  'Sales metrics and dimensions'
);
```

## Register Relationships

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales',
  'order_line_to_order',
  'order_line',
  'order',
  'ol.order_id = o.order_id',
  'MANY_TO_ONE',
  'INNER',
  NULL
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING(
  'sales', 'order_line_to_order',
  'order_id', NULL,
  'order_id', NULL,
  1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales',
  'order_to_customer',
  'order',
  'customer',
  'o.customer_id = c.customer_id',
  'MANY_TO_ONE',
  'LEFT',
  NULL
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING(
  'sales', 'order_to_customer',
  'customer_id', NULL,
  'customer_id', NULL,
  1
);
```

For `MANY_TO_ONE`, the ordered `to` mappings must exactly match a declared
unique key; reverse this requirement for `ONE_TO_MANY`, and satisfy it on both
ends for `ONE_TO_ONE`. Add all required unique keys and key columns before any
mapping. Relationship key mappings must use columns: typed grain proofs do not
support `FROM_EXPRESSION` or `TO_EXPRESSION`. Normalize casts and other key
expressions into a source view, then map the projected column. If
`SEMANTIC_MODEL_033` occurs, use these direct admin scripts to
repair the metadata and rerun `VALIDATE_MODEL`; `APPLY_SEMANTIC_DEFINITION`
cannot apply metric edits while the model has a blocking validation error.

Pass physical column names as catalog values without SQL identifier quotes.
Names that require quoting in SQL are supported, including JSON Tables markers:

```sql
-- Join SQL: c."profile|object" = p."_id"
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING(
  'customer_360', 'customer_to_profile',
  'profile|object', NULL,
  '_id', NULL,
  1
);
```

Resolve both endpoint columns through `EXA_ALL_COLUMNS` before registration.
`SEMANTIC_MODEL_051` rejects simple equalities across incompatible type
families and names both resolved types. To remove a relationship, call
`REMOVE_RELATIONSHIP_KEY_MAPPING` from the highest ordinal down, then call
`REMOVE_RELATIONSHIP`; both operations protect published validation state.

## Add Facts

Smoke-test each row-level expression against its owning source entity before
calling `ADD_FACT`:

```sql
SELECT ol.quantity * ol.net_unit_price
FROM MART.ORDER_LINES ol
LIMIT 1;
```

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'net_revenue',
  'ol.quantity * ol.net_unit_price',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Net Revenue',
  'Net revenue per order line before tax',
  FALSE,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'net_cost',
  'ol.quantity * ol.unit_cost',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Net Cost',
  'Cost of goods per order line',
  FALSE,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'gross_margin',
  'ol.quantity * ol.net_unit_price - ol.quantity * ol.unit_cost',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Gross Margin',
  'Revenue minus cost per order line',
  FALSE,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'quantity',
  'ol.quantity',
  'DECIMAL(18,3)',
  'ADDITIVE',
  'Quantity',
  'Units sold per line',
  FALSE,
  TRUE
);
```

## Add Dimensions

Semantic DDL is the shorter and more readable form, and one block validates and
rolls back as a unit:

```sql
ALTER SEMANTIC VIEW sales.SALES
REPLACE DIMENSIONS (
  DIMENSION order_status
    ON ENTITY "order"
    AS o.order_status
    RETURNS VARCHAR(32)
    DISPLAY 'Order Status'
    COMMENT 'Fulfilment status of the order'
    CERTIFIED,

  DIMENSION customer_region
    ON ENTITY customer
    AS c.region
    RETURNS VARCHAR(100)
    DISPLAY 'Customer Region'
    COMMENT 'Geographic region of the customer'
    CERTIFIED
);
```

`REPLACE DIMENSIONS` decides the object's dimension membership, so anything left
out of the block leaves the object — use it for bootstrap and deliberate resets.
For one dimension without disturbing the others, use the single form:

```sql
ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE DIMENSION order_status
  ON ENTITY "order"
  AS o.order_status
  RETURNS VARCHAR(32)
  DISPLAY 'Order Status'
  COMMENT 'Fulfilment status of the order'
  CERTIFIED;
```

Quote an entity whose name collides with a SQL keyword (`ON ENTITY "order"`).
`PRIVATE` maps to the catalog's `IS_HIDDEN`. Dry-run through
`APPLY_SEMANTIC_DEFINITION(..., TRUE)` before applying.

The equivalent through the admin script, which is still the surface for removing
one dimension (`REMOVE_DIMENSION`) or for per-representation bindings
(`ADD_DIMENSION_WITH_BINDINGS`):

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_status',
  'o.order_status',
  'VARCHAR(32)',
  'Order Status',
  'Fulfilment status of the order',
  NULL,
  1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'customer',
  'customer_region',
  'c.region',
  'VARCHAR(100)',
  'Customer Region',
  'Geographic region of the customer',
  NULL,
  1
);
```

Time dimensions from a single date column (one per grain):

```sql
SELECT YEAR(o.order_date),
       CAST(YEAR(o.order_date) AS VARCHAR(4)) || '-Q' || TO_CHAR(o.order_date, 'Q'),
       DATE_TRUNC('MONTH', o.order_date)
FROM MART.ORDERS o
LIMIT 1;
```

Run this smoke test before declaring the dimension, whichever surface you use.
It verifies executable Exasol SQL and the returned types; `VALIDATE_MODEL` does
not compile every expression, so an invalid dialect expression can pass
validation and fail at query time.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_year',
  'YEAR(o.order_date)',
  'DECIMAL(4,0)',
  'Order Year',
  'Calendar year of the order',
  'year',
  1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_quarter',
  'CAST(YEAR(o.order_date) AS VARCHAR(4)) || ''-Q'' || TO_CHAR(o.order_date, ''Q'')',
  'VARCHAR(7)',
  'Order Quarter',
  'Calendar quarter of the order',
  'quarter',
  1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_month',
  'DATE_TRUNC(''MONTH'', o.order_date)',
  'DATE',
  'Order Month',
  'First day of the calendar month',
  'month',
  1
);
```

## Author Metrics

Enable Semantic SQL for the session before using DDL form:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

Additive metric (dry-run then apply):

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC total_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT ''currency_usd''
  DISPLAY ''Total Revenue''
  COMMENT ''Sum of net revenue across all order lines''
  ADDITIVE PUBLIC CERTIFIED',
  TRUE   -- dry-run
);

EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC total_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT ''currency_usd''
  DISPLAY ''Total Revenue''
  COMMENT ''Sum of net revenue across all order lines''
  ADDITIVE PUBLIC CERTIFIED',
  FALSE  -- apply
);
```

The `TRUE` call simulates the mutation and validates the resulting model before
restoring the original catalog state. Continue to the `FALSE` call only when it
returns `DRY_RUN`; an `ERROR` result contains the blocking rule and object.

Filtered metric:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC completed_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FILTER (WHERE order_status = ''COMPLETE'')
  FORMAT ''currency_usd''
  DISPLAY ''Completed Revenue''
  COMMENT ''Net revenue restricted to orders with status COMPLETE''
  ADDITIVE PUBLIC CERTIFIED',
  FALSE
);
```

Ratio metric. A `RATIO` divides two *metrics*, so declare the numerator as a
metric first — this one aggregates the `gross_margin` fact created above. Naming
it `total_gross_margin` rather than reusing `gross_margin` keeps the fact and the
metric distinct; a metric that aggregates a fact of the same name is fine, but a
metric that references *itself* fails with `SEMANTIC_MODEL_012: cyclic metric
dependency`.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC total_gross_margin
  AS SUM(gross_margin)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT ''currency''
  DISPLAY ''Gross Margin''
  COMMENT ''Net revenue minus cost of goods''
  ADDITIVE PUBLIC CERTIFIED',
  FALSE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC gross_margin_pct
  AS total_gross_margin / NULLIF(total_revenue, 0)
  ON ENTITY order_line
  RETURNS DOUBLE
  FORMAT ''percent''
  DISPLAY ''Gross Margin %''
  COMMENT ''Gross margin as a percentage of net revenue''
  PUBLIC CERTIFIED',
  FALSE
);
```

Referencing a name that is not an active metric fails with `SEMANTIC_MODEL_011`,
which names what it could not resolve. Before this fix the ratio above referenced
`total_gross_margin` without ever declaring it, so following this file top to
bottom hit exactly that error.

> These examples build **this file's** model, which is not the shipped `sales`
> demo: it declares a `gross_margin` fact, where the demo derives
> `gross_margin` from `total_revenue - total_cost`. Replaying an example here
> against the demo model can therefore fail for reasons that have nothing to do
> with the example.

Rename a metric while preserving its identity and old name as a compatibility
synonym:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
RENAME METRIC total_revenue TO gross_merchandise_value',
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
RENAME METRIC total_revenue TO gross_merchandise_value',
  FALSE
);
```

Remove a metric from an object:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES DROP METRIC obsolete_metric',
  TRUE
);
```

Apply with `FALSE` after reviewing the dry-run. The drop deactivates a metric
only after its last object membership is removed, and validation rejects the
change while another active metric depends on it. Every `REPLACE ...` block
changes visible object membership but does not delete the omitted catalog
definitions.

One statement may carry `REPLACE DIMENSIONS`, `REPLACE FACTS` and `REPLACE
METRICS` together — the whole interior of a semantic object, validated once and
rolled back as one unit. That is also the only way to restore an object's column
*order*: each block clears its kind first and the apply re-adds dimensions,
facts, then metrics, each taking the next ordinal, so a combined statement
numbers the object from 1 in that order while separate statements interleave.
OSI export carries those ordinals into the imported model.

## Import a Databricks UCMV

Use this path when the source model is a Databricks Unity Catalog Metric View
YAML. Dry-run first to inspect `GENERATED_DDL` and `DIAGNOSTICS_JSON`:

Do not transfer Boolean conventions between APIs:
`APPLY_SEMANTIC_DEFINITION(..., TRUE)` is a dry-run (`DRY_RUN`), whereas
`IMPORT_DATABRICKS_METRIC_VIEW(..., FALSE)` is a dry-run (`APPLY_IMPORT`).

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  '<metric view YAML>',
  'sales_dbx',
  'SEMANTIC_SALES_DBX',
  FALSE
);
```

Apply after review:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  '<metric view YAML>',
  'sales_dbx',
  'SEMANTIC_SALES_DBX',
  TRUE
);
```

The host helper reads the YAML file and calls the same in-database importer:

```sh
python3 tools/import_databricks.py sql/examples/sales_databricks_metric_view.yaml \
  --model sales_dbx --schema SEMANTIC_SALES_DBX --apply
```

Supported imports include plain table/view sources, star and snowflake joins,
fields, aggregate measures, filtered measures, and derived/ratio measures using
`MEASURE()`. Review any `DBX_IMPORT_*` diagnostics before treating the imported
model as production-ready.

## Validate and Publish

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
```

Inspect all current issues:

```sql
SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
WHERE MODEL_NAME = 'sales'
ORDER BY SEVERITY, OBJECT_TYPE, OBJECT_NAME;
```

Inspect agent-visible blocking errors:

```sql
SELECT OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT
WHERE MODEL_NAME = 'sales';
```

Publish when clean:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales');
```

Verify that semantic context is visible after publication:

```sql
SELECT SCHEMA_NAME, SCHEMA_COMMENT
FROM EXA_ALL_SCHEMAS
WHERE SCHEMA_NAME = 'SEMANTIC_SALES';

SELECT VIEW_NAME, VIEW_COMMENT
FROM EXA_ALL_VIEWS
WHERE VIEW_SCHEMA = 'SEMANTIC_SALES';

SELECT FIELD_KIND, FIELD_NAME, DESCRIPTION
FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES'
ORDER BY FIELD_KIND, FIELD_NAME;
```

## Add Agent Instructions

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'MODEL',
  'sales',
  'GENERAL',
  'All revenue metrics are reported in USD. Do not convert currencies.',
  NULL,
  10
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'METRIC',
  'completed_revenue',
  'DEFINITION',
  'Counts only orders with status COMPLETE. Excludes PENDING, CANCELLED, and RETURNED.',
  NULL,
  10
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'MODEL',
  'sales',
  'SAFETY',
  'Do not answer questions about individual customer PII. Aggregate to region or segment level only.',
  NULL,
  1
);
```

## Add Verified Queries

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY(
  'sales',
  'SALES',
  'Revenue by region this year',
  'What is total revenue by customer region this year?',
  '{"model":"sales","object":"SALES","metrics":["total_revenue"],"dimensions":["customer_region"],"filters":[{"field":"order_year","op":"=","value":2026}],"order_by":[{"field":"total_revenue","direction":"desc"}]}',
  '{"columns":["customer_region","total_revenue"],"grain":"one row per customer_region"}',
  TRUE
);
```

## Add Synonyms

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  'sales', 'METRIC', 'total_revenue', 'revenue', 'MANUAL'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  'sales', 'METRIC', 'gross_margin_pct', 'margin rate', 'MANUAL'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  'sales', 'DIMENSION', 'customer_region', 'region', 'MANUAL'
);
```

The object type must match the named object's catalog type. Valid values are
`SEMANTIC_OBJECT`, `ENTITY`, `DIMENSION`, `FACT`, and `METRIC`; passing
`METRIC` for `customer_region`, for example, searches only metrics and fails.

## Introspect the Model

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

SHOW SEMANTIC VIEWS;

SHOW SEMANTIC METRICS IN sales.SALES;

DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue;

SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue;

EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct;

EXPORT SEMANTIC METRIC sales.SALES.completed_revenue;

EXPORT SEMANTIC MODEL sales;
```

## Review Validation Run History

```sql
SELECT VALIDATION_RUN_ID, MODEL_NAME, STATUS, STARTED_AT, ISSUE_COUNT
FROM SEMANTIC_CATALOG.VALIDATION_RUNS
WHERE MODEL_NAME = 'sales'
ORDER BY STARTED_AT DESC
LIMIT 10;
```
