# Semantic Review Bundle

Use this template for a complete data-engineer handoff. Omit sections only when
they are explicitly out of scope, and state why.

## 1. Decision Summary

```text
Model:
Candidate version:
Current published version:
Review phase:
Decision: READY | READY_WITH_CONDITIONS | NOT_READY
Data engineer:
Domain owner:
Release owner:
Blocking findings:
Conditions:
Next action and owner:
```

## 2. Approval Record

| Gate | Owner | Decision | Timestamp | Evidence or conditions |
|---|---|---|---|---|
| Scope | Data engineer | Pending | | |
| Technical | Data engineer | Pending | | |
| Semantic | Domain owner | Pending | | |
| Release | Release owner | Pending | | |

Use explicit decisions. Do not translate a meeting, message, or absence of
objections into approval unless it clearly records the gate and candidate
version.

## 3. Scope

Record:

- business domain and intended consumers;
- source schemas and objects;
- required questions and KPIs;
- security and privacy boundaries;
- included and excluded use cases;
- freshness and performance expectations.

## 4. Source Evidence

| Finding | Source | Evidence | Proposed interpretation | Confidence | Reviewer |
|---|---|---|---|---|---|
| | | Comment, constraint, profile, sample, or report | | HIGH/MEDIUM/LOW | |

Add a conflict entry whenever comments, names, data, or existing reports
disagree. Redact sensitive sample values.

## 5. Technical Model

For each entity record source, alias, grain, key, row-level evidence, and owner.
For each relationship record endpoints, key mapping, cardinality, join type,
fanout policy, path priority, and validation evidence.

Call out:

- missing or inferred keys;
- many-to-many paths;
- ambiguous relationship paths;
- nullable or non-unique join columns;
- cross-role or sensitive lineage;
- changes that alter result grain.

Include a compact entity-relationship diagram when practical.

## 6. Field Dictionary

| Field | Kind | Source lineage | Data type | Description | Visibility | Confidence |
|---|---|---|---|---|---|---|
| | Dimension/Fact | | | | Public/Private | |

Check that useful descriptions reach `FIELDS_FOR_AGENT` and published column
comments.

## 7. Metric Cards

Create one card per public metric:

```text
Name:
Display name:
Business meaning:
Formula:
Metric kind and dependencies:
Base entity and grain:
Filters and exclusions:
Unit and format:
Null and zero behavior:
Valid dimensions:
Source lineage:
Visibility and certification:
Evidence and confidence:
Open questions:
Reviewer decision: ACCEPT | NEEDS_CHANGE | REJECT | PENDING
```

## 8. Assumptions And Risks

| Severity | Assumption or risk | Impact | Evidence | Owner | Resolution |
|---|---|---|---|---|---|
| Critical/High/Medium/Low | | | | | |

Separate confirmed defects from uncertain semantics. A clean validator does not
close business risks.

## 9. Semantic Diff

| Object | Change | Impact | Downstream effect | Approval required |
|---|---|---|---|---|
| | Added/Changed/Removed | BREAKING/BEHAVIORAL/METADATA/NONE | | |

Always highlight changes to grain, relationship cardinality, formulas, filters,
visibility, certification, units, and removed or renamed fields.

Attach canonical Semantic SQL or strict lossless Ossie/OSI output. Record its
path, commit, or artifact identifier.

## 10. Validation

Record:

```text
VALIDATE_MODEL status:
Validation run ID:
Errors:
Warnings:
Metric/dimension matrix summary:
Exceptions accepted by:
```

Include unresolved warnings even when publication permits them.

## 11. Acceptance Tests

| Question or scenario | Expected behavior | Actual behavior | Handle | Status |
|---|---|---|---|---|
| | | | AGENT_REQUEST_ID/QUERY_LOG_ID | Pass/Fail |

Cover representative questions, trusted-query reconciliation, incompatible
dimensions, null and zero behavior, time boundaries, filters, role visibility,
catalog comments, and material performance risks.

## 12. Publication Verification

Record:

- target environment and published schema;
- model and validation version;
- schema and view comments;
- column-comment coverage;
- discovery-view visibility;
- role-based smoke tests;
- verified-query status;
- rollback reference.

## 13. Feedback Backlog

| Feedback ID | Request handle | Verdict | Theme | Severity | Recurrence | Proposed remediation | Owner |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

Do not apply proposed remediation from this table. Route accepted items into a
new reviewed candidate version.

## 14. Action List

| Priority | Action | Owner | Due or gate | Completion evidence |
|---|---|---|---|---|
| | | | | |
