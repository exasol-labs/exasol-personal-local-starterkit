---
name: exasol-semantic-reviewer
addon: semantic-views
description: Review proposed or published Exasol Semantic Views models and prepare approval-ready handoffs for data engineers and domain owners. Use when an agent must assess model scope, source evidence, entity grain, relationships, metrics, validation results, semantic diffs, acceptance queries, publication metadata, or operational feedback; coordinate human approval gates; or assemble a semantic-layer review bundle before publication or promotion.
---

> **Exasol starter kit:** Exasol's own skill, copied unchanged from [exasol-labs/exasol-semantic-views](https://github.com/exasol-labs/exasol-semantic-views) at `v0.6.1`. On this machine the `exakit` skill comes first: how to connect, how to load data and which tool to reach for.

# Exasol Semantic Reviewer

## Core Contract

Treat semantic modeling as a human-approved release process. Inspect, test, and
recommend autonomously, but never infer approval from silence and never mutate
the catalog from review feedback. Data engineers approve physical correctness
and release readiness; domain owners approve business meaning.

Use `$exasol-semantic-modeler` for authoring or remediation and
`$exasol-semantic-analyst` for governed query execution. This skill owns review,
evidence, decisions, and handoff quality.

Read [review-bundle-template.md](references/review-bundle-template.md) when
producing the final review package.

## Review States

Classify each review as one of:

- `DISCOVERY`: evidence is incomplete; do not author or approve semantics.
- `TECHNICAL_REVIEW`: inspect grain, keys, joins, cardinality, fanout, lineage,
  security, and validation.
- `SEMANTIC_REVIEW`: inspect definitions, filters, units, exclusions, naming,
  formats, synonyms, and expected business behavior.
- `RELEASE_REVIEW`: inspect the exact diff, tests, approvals, and publication
  plan.
- `POST_RELEASE_REVIEW`: triage observed requests and feedback into proposed
  changes without mutating the model.

State the current phase, decision owner, and blocked questions at the start of
the review.

## Workflow

### 1. Confirm scope and owners

Record the business domain, source schemas, intended consumers, required
questions, security boundaries, exclusions, data engineer, and domain owner.
Stop release review if either approval owner is unknown.

### 2. Build the evidence map

Inspect source table, view, and column comments before relying on names. Verify
comments against keys, constraints, types, row counts, profiles, and samples.
For every important inference record:

- source and exact object;
- proposed interpretation;
- confidence (`HIGH`, `MEDIUM`, or `LOW`);
- conflict or uncertainty;
- required reviewer.

Surface contradictions. Do not silently choose between a comment and observed
data.

### 3. Review the technical model

Verify entities, grains, unique keys, relationship mappings, cardinality,
join type, fanout policy, path ambiguity, field lineage, visibility, and role
boundaries. Treat relationship or grain changes as high impact even if formulas
are unchanged.

Query current validation issues:

```sql
SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
WHERE MODEL_NAME = '<model>'
ORDER BY SEVERITY, OBJECT_TYPE, OBJECT_NAME;
```

Require a clean `VALIDATE_MODEL` result. Validation proves structural
consistency, not business correctness.

### 4. Review semantic meaning

Create one metric card per public metric containing meaning, formula, grain,
dependencies, filters, unit, format, valid dimensions, exclusions, lineage,
certification state, evidence, and open questions. Also review dimension
descriptions, time semantics, null behavior, synonyms, and sensitive values.

Ask reviewers to mark each disputed item `ACCEPT`, `NEEDS_CHANGE`, or `REJECT`.
Do not accept a metric solely because it compiles.

### 5. Test business behavior

Compile and execute representative structured requests or Semantic SQL. Cover:

- primary business questions;
- metric/dimension compatibility;
- null, zero, empty-set, and divide-by-zero behavior;
- filters, time boundaries, and exclusions;
- reconciliation against trusted SQL or reports;
- role-based visibility;
- catalog schema, view, and column comments;
- important performance-sensitive query shapes.

Record expected and actual results plus the durable request or query-log handle.
Register only reviewed, passing scenarios as verified queries.

### 6. Produce the semantic diff

Compare the candidate with the currently approved version. Highlight additions,
removals, renames, formula and filter changes, grain and relationship changes,
visibility and certification changes, metadata changes, and affected verified
queries. Classify impact as `BREAKING`, `BEHAVIORAL`, `METADATA`, or `NONE`.

Use canonical `EXPORT SEMANTIC MODEL` output or a strict lossless Ossie/OSI
export as the machine-readable review artifact. Keep it in source control when
the workflow supports Git review.

### 7. Enforce approval gates

Require explicit decisions:

1. `SCOPE_APPROVED` by the data engineer.
2. `TECHNICALLY_APPROVED` by the data engineer after grain and join review.
3. `SEMANTICALLY_APPROVED` by the domain owner after metric review.
4. `RELEASE_APPROVED` by the accountable release owner after diff and tests.

Report `NOT_READY` if a required approval, owner, validation result, or critical
test is missing. Never publish merely because no errors were found.

### 8. Verify staged publication

After publication to a review environment, verify discovery views, role-scoped
access, verified queries, model/object descriptions, and inline view-column
comments. Record model version, validation run, artifact revision, approvers,
and smoke-test results before production promotion.

### 9. Operate the feedback loop

Attach feedback to durable `AGENT_REQUEST_ID` or `QUERY_LOG_ID` handles. Capture
the verdict, observed behavior, expected behavior, proposed change, severity,
and recurrence. Use `RECORD_AGENT_FEEDBACK` to create reviewable evidence, not
an automatic catalog update.

Group recurring feedback into one proposed remediation:

- description or synonym correction;
- agent instruction;
- verified query;
- metric or filter change;
- grain or relationship correction;
- documented rejection with rationale.

Route accepted remediation through the same technical, semantic, test, and
release gates.

## Required Output

Produce the review bundle defined in
[review-bundle-template.md](references/review-bundle-template.md). Lead with:

- overall decision: `READY`, `READY_WITH_CONDITIONS`, or `NOT_READY`;
- required approvers and recorded decisions;
- blocking findings ordered by severity;
- exact next actions with owners;
- links or identifiers for machine-readable artifacts and database evidence.

Label inference explicitly. Distinguish automated validation, agent assessment,
and human approval.

## Safety

- Never publish, certify, or mark an approval on behalf of a human reviewer.
- Never convert feedback directly into catalog mutations.
- Never hide unresolved assumptions behind a clean validation result.
- Never expose private fields or sample sensitive values in review artifacts.
- Treat destructive replacement, grain, relationship, filter, and visibility
  changes as requiring explicit impact review.
- Preserve evidence and rejected decisions for auditability.
