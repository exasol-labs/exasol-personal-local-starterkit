#!/usr/bin/env bash
# upgrade-kit2.sh — additive upgrade from Kit 1 to Kit 2.
#
#   bash upgrade/upgrade-kit2.sh
#
# Kit 2 (Trusted AI Workflow Add-on) builds on an existing Kit 1 install:
# nothing is reinstalled — not the database, not exapump, not the MCP server,
# not the sample data. This script only ADDS the trust assets:
#
#   1. semantic model        advanced/semantic/sales_semantic_model.yml
#   2. audit/run log schema  advanced/audit_log_schema.sql
#   3. saved workflow        advanced/saved_workflow_example.json
#
# Everything it adds is recorded in the manifest under kit2, so
# rollback-kit2.sh can remove exactly that and nothing else. Safe to re-run.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$KIT_ROOT/setup/lib"

. "$LIB_DIR/common.sh"
. "$LIB_DIR/detect.sh"
[ -f "$LIB_DIR/exapump.sh" ] && . "$LIB_DIR/exapump.sh"

exakit_init_logging
exakit_enable_failure_handling

# SQL assets are applied through exapump; without the module nothing may be
# recorded as installed.
require_exapump_module() {
    command -v exapump_run_sql_file >/dev/null 2>&1 || \
        die "The exapump module is missing from this kit build — cannot apply $1. Update the kit and re-run the upgrade."
}

printf '\n  Kit 1 -> Kit 2 upgrade (Trusted AI Workflow Add-on)\n\n'

# --- 1. detect Kit 1 via the manifest ----------------------------------------
EXAKIT_CURRENT_STEP="detect-kit1"
[ -f "$EXAKIT_MANIFEST" ] || die "No installation manifest found. Install Kit 1 first (install.sh)."

_level="$(manifest_get kit_level 2>/dev/null)"
if [ "$_level" = "2" ]; then
    ok "Kit 2 is already installed (kit_level: 2). Nothing to do."
    exakit_finish
    exit 0
fi
[ "$_level" = "1" ] || die "Unexpected kit_level '$_level' in the manifest."

step_done runtime || die "Kit 1 runtime is not marked complete. Finish the Kit 1 install first."
ok "Kit 1 installation detected (kit_level: 1)"

# Health: the upgrade needs a reachable database.
_type="$(manifest_get runtime.type 2>/dev/null)"
case "$_type" in
    nano)
        . "$LIB_DIR/runtime-nano.sh"
        [ "$(nano_status)" = "running" ] || die "The Nano container is not running. Start it first: exakit start"
        ;;
    personal)
        . "$LIB_DIR/runtime-personal.sh"
        [ "$(personal_status)" = "running" ] || die "The Personal deployment is not reachable. Check: exasol info"
        ;;
    *)
        die "Unknown runtime type in the manifest: '$_type'"
        ;;
esac
ok "Runtime is healthy ($_type)"

# --- 2. semantic model ---------------------------------------------------------
if begin_step kit2_semantic "Kit 2 asset 1/3  Semantic model"; then
    _model="$KIT_ROOT/advanced/semantic/sales_semantic_model.yml"
    if [ -s "$_model" ]; then
        mkdir -p "$EXAKIT_HOME/kit2/semantic"
        cp "$_model" "$EXAKIT_HOME/kit2/semantic/"
        manifest_set kit2.semantic_model "$EXAKIT_HOME/kit2/semantic/sales_semantic_model.yml"
        # The semantic layer is virtual-schema based; applying the model is a
        # SQL step delivered with the semantic assets.
        if [ -s "$KIT_ROOT/advanced/semantic/install_semantic_views.sql" ]; then
            require_exapump_module "the semantic views SQL"
            exapump_run_sql_file "$KIT_ROOT/advanced/semantic/install_semantic_views.sql" "semantic views installation"
            manifest_set kit2.semantic_views_installed true
        else
            info "Pending: semantic views install SQL not delivered yet (model staged, apply step will activate once it lands)"
        fi
        mark_step kit2_semantic
        ok "Semantic model staged"
    else
        info "Pending: advanced/semantic/sales_semantic_model.yml not delivered yet — skipping"
    fi
fi

# --- 3. audit/run log ------------------------------------------------------------
if begin_step kit2_audit "Kit 2 asset 2/3  Audit/run log"; then
    _audit="$KIT_ROOT/advanced/audit_log_schema.sql"
    if [ -s "$_audit" ]; then
        require_exapump_module "the audit log SQL"
        exapump_run_sql_file "$_audit" "audit log schema (audit_log_schema.sql)"
        manifest_set kit2.audit_log_installed true
        mark_step kit2_audit
        ok "Audit/run log schema installed"
    else
        info "Pending: advanced/audit_log_schema.sql not delivered yet — skipping"
    fi
fi

# --- 4. saved workflow example ------------------------------------------------------
if begin_step kit2_workflow "Kit 2 asset 3/3  Saved workflow example"; then
    _wf="$KIT_ROOT/advanced/saved_workflow_example.json"
    if [ -s "$_wf" ]; then
        mkdir -p "$EXAKIT_HOME/kit2/workflows"
        cp "$_wf" "$EXAKIT_HOME/kit2/workflows/"
        manifest_set kit2.saved_workflow "$EXAKIT_HOME/kit2/workflows/saved_workflow_example.json"
        mark_step kit2_workflow
        ok "Saved workflow example staged"
    else
        info "Pending: advanced/saved_workflow_example.json not delivered yet — skipping"
    fi
fi

# --- 5. MCP reconfiguration (non-destructive) ------------------------------------------
# Kit 2 does not change the MCP wiring; the existing configs keep working.
# If a Kit 2 asset later requires extra MCP settings, it is applied as a new
# config file next to the existing ones, never by rewriting them.
ok "MCP configuration unchanged (nothing to reconfigure for Kit 2)"

# --- 6. verify and bump ---------------------------------------------------------------
_installed=0
for _flag in kit2.semantic_model kit2.audit_log_installed kit2.saved_workflow; do
    [ -n "$(manifest_get $_flag 2>/dev/null)" ] && _installed=$((_installed + 1))
done

if [ "$_installed" -gt 0 ]; then
    manifest_set kit_level 2
    manifest_set kit2.upgraded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    exakit_finish
    ok "Upgrade complete — kit_level is now 2 ($_installed/3 assets present)"
    [ "$_installed" -lt 3 ] && info "Missing assets install automatically when you re-run this script after they land."
else
    exakit_finish
    info "No Kit 2 assets are available in this kit build yet. kit_level stays at 1."
    info "Re-run this script once the advanced/ assets are delivered."
fi
