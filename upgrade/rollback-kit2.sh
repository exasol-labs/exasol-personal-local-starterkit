#!/usr/bin/env bash
# rollback-kit2.sh — clean revert from Kit 2 back to Kit 1.
#
#   bash upgrade/rollback-kit2.sh
#
# Removes exactly what upgrade-kit2.sh added (recorded in the manifest under
# kit2) and nothing else: Kit 1 — database, exapump, MCP server, sample
# data — is left untouched.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$KIT_ROOT/setup/lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
[ -f "$LIB_DIR/exapump.sh" ] && . "$LIB_DIR/exapump.sh"

# Rollback SQL runs through exapump; degrade to manual guidance without it.
can_run_sql() {
    command -v exapump_run_sql_file >/dev/null 2>&1
}

exakit_init_logging

printf '\n  Kit 2 -> Kit 1 rollback\n\n'

[ -f "$EXAKIT_MANIFEST" ] || die "No installation manifest found."
_level="$(manifest_get kit_level 2>/dev/null)"
if [ "$_level" != "2" ]; then
    ok "Kit 2 is not installed (kit_level: ${_level:-none}). Nothing to roll back."
    exit 0
fi

warn "This removes the Kit 2 trust assets (semantic model, audit log, saved workflows)."
warn "Kit 1 (database, exapump, MCP, sample data) stays untouched."
confirm "Continue with the rollback?" n || { info "Rollback cancelled"; exit 0; }

# --- semantic model -----------------------------------------------------------
if [ -n "$(manifest_get kit2.semantic_views_installed 2>/dev/null)" ]; then
    _drop="$KIT_ROOT/advanced/semantic/uninstall_semantic_views.sql"
    if [ -s "$_drop" ] && can_run_sql; then
        exapump_run_sql_file "$_drop" "semantic views removal"
    else
        warn "Cannot run the semantic views uninstall SQL (missing SQL file or exapump module) — remove them manually if needed"
    fi
fi
if [ -d "$EXAKIT_HOME/kit2/semantic" ]; then
    rm -rf "$EXAKIT_HOME/kit2/semantic"
    ok "Semantic model removed"
fi

# --- audit log ------------------------------------------------------------------
if [ -n "$(manifest_get kit2.audit_log_installed 2>/dev/null)" ]; then
    _drop="$KIT_ROOT/advanced/audit_log_drop.sql"
    if [ -s "$_drop" ] && can_run_sql; then
        exapump_run_sql_file "$_drop" "audit log schema removal"
    else
        warn "Cannot run the audit log drop SQL (missing SQL file or exapump module) — remove it manually if needed"
    fi
fi

# --- saved workflows ----------------------------------------------------------------
if [ -d "$EXAKIT_HOME/kit2/workflows" ]; then
    rm -rf "$EXAKIT_HOME/kit2/workflows"
    ok "Saved workflow examples removed"
fi
rmdir "$EXAKIT_HOME/kit2" 2>/dev/null

# --- manifest: back to Kit 1 ----------------------------------------------------------
require_python3
python3 - "$EXAKIT_MANIFEST" <<'PY' || die "Could not update the manifest"
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
doc["kit_level"] = 1
doc.pop("kit2", None)
doc["steps_completed"] = [s for s in doc.get("steps_completed", []) if not s.startswith("kit2_")]
with open(sys.argv[1], "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
PY

ok "Rollback complete — kit_level is back to 1"
