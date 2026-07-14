# Exasol Personal Local Starter Kit

This context defines the product language for the local starter-kit lifecycle. It is a glossary only; implementation details live in the docs and scripts.

## Language

**Starter Kit**:
A local package that installs and manages a private Exasol database, data-loading tool, and AI-client bridge on a user's machine.
_Avoid_: installer repo, local bundle

**Runtime**:
The installed database environment managed by the Starter Kit.
_Avoid_: deployment, instance

**Exasol Nano Runtime**:
A container-based Runtime that stores database state in a persistent local volume.
_Avoid_: Docker database, container install

**Exasol Personal Runtime**:
A local Exasol Personal Runtime used by the macOS path.
_Avoid_: native database, Personal install

**Component**:
A separately versioned part of the Starter Kit experience, such as the kit scripts, Runtime image, exapump, or MCP server.
_Avoid_: dependency, package

**Desired Version**:
The version the Starter Kit resolved or was explicitly asked to install for a Component.
_Avoid_: target version, pinned version

**Snapshot**:
A recoverability record for Starter Kit managed runtime or client state before a mutating operation.
_Avoid_: backup, copy

**Backup**:
A restorable copy of state with enough content to recover from a destructive or major-version operation.
_Avoid_: snapshot

**MCP Client Setup**:
The flow that prepares supported AI clients to connect to the local Exasol MCP server.
_Avoid_: AI setup, client install
