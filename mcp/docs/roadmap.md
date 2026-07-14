# Roadmap

Status: Phase-gated delivery plan.

## Delivery Sequence

1. Phase 1: Requirements Analysis
   Output: `mcp/AGENT.md`, `mcp/docs/requirements.md`, `mcp/docs/assumptions.md`, initial ADRs, roadmap, baseline risk/security/ops/test docs
   Gate: explicit approval required

2. Phase 2: Architecture
   Output: `mcp/docs/architecture.md`, refined `mcp/docs/integration.md`, refined `mcp/docs/security.md`
   Gate: explicit approval required

3. Phase 3: Detailed Design
   Output: `mcp/docs/design.md`, manifest schema draft, adapter contract draft, backup/restore flow drafts
   Gate: explicit approval required

4. Phase 4: Task Breakdown
   Output: `mcp/docs/tasks.md`
   Gate: explicit approval required

5. Phase 5: API Design
   Output: `mcp/docs/api-design.md`, refined integration contract, and contract ADRs
   Gate: explicit approval required

6. Phase 6: Review And Refinement
   Output: consistency pass across all docs
   Gate: explicit approval required

7. Phase 7: Implementation
   Output: code, one component at a time
   Gate: explicit approval required

8. Phase 8: Testing
   Output: executed test suite and evidence

9. Phase 9: Integration
   Output: installer integration proof and runtime validation

10. Phase 10: Final Review
    Output: release-ready review package

## Current Position

- Current phase: Phase 5
- Next phase: Phase 6 Review And Refinement
- Stop condition: wait for approval after Phase 5 review
