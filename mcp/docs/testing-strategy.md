# Testing Strategy

Status: Baseline strategy carried into Phase 4; detailed matrix to be expanded after task breakdown approval.

## Test Principles

- Design tests before implementation.
- Prefer deterministic tests over environment-coupled tests.
- Separate unit, contract, integration, and upgrade-compatibility coverage.

## Planned Test Layers

- Unit tests for core services and policy logic
- Contract tests for each client adapter
- Integration tests with mocked filesystem and mocked Exasol/MCP boundaries
- Backup/restore recovery tests
- Drift detection and repair tests
- Cross-platform path and permission tests

## Required Mocks

- Filesystem
- Database connectivity
- MCP Server process or endpoint
- AI client installations and config files
- Network interactions
- Runtime manifest
- Backup engine

## Phase Gate

Detailed test matrix and fixtures should be finalized after architecture and design are approved.

## Current QA Expansion

The detailed MCP edge-case matrix is now tracked in [qa-edge-cases.md](qa-edge-cases.md).
