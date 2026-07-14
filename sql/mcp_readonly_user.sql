-- Reference baseline for the dedicated MCP-safe database user.
-- The installer provisions and posture-checks this user automatically
-- (exakit_configure_mcp_readonly_access in setup/lib/common.sh); this file
-- documents the equivalent grants for manual setups.
-- For manual use, replace {{MCP_PASSWORD}} with your own strong password token.
-- The user gets database-wide READ: USE ANY SCHEMA + SELECT ANY TABLE let it
-- query every schema and table (bundled datasets, your own uploads, and
-- anything created later) with no per-schema grant, while still being unable
-- to write. SELECT ANY DICTIONARY is intentionally NOT granted, so system
-- dictionaries (audit logs, sessions, other users) stay private.
CREATE USER mcp_readonly IDENTIFIED BY {{MCP_PASSWORD}};
GRANT CREATE SESSION TO mcp_readonly;
GRANT USE ANY SCHEMA TO mcp_readonly;
GRANT SELECT ANY TABLE TO mcp_readonly;
