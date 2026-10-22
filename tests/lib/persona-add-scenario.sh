#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty, with NO key typed:
# `exakit persona add ml-engineer` on a kit set up as data-scientist. Three
# steps headed like the installer's, each the installer's own table taken with
# its defaults (UI_TABLE_AUTO) and then filled in as it works - the data, the AI
# clients, the add-ons - and one closing line.
#
# cmd_persona, cmd_data_load, cmd_mcp_setup and cmd_marketplace are the CLI's
# own (read out of setup/exakit), and the tables, menus and loops under them are
# shipping code. What is faked is everything that would reach outside: the
# database (Pharma is loaded, Banking is not), the dataset load, the AI client
# discovery and the MCP setup CLI (Claude waiting, Codex already connected), the
# add-on registry and states (the notebook installed, udf-devkit not) and the
# udf-devkit install. The answers land on lines of their own for
# tests/personas.sh: RC=, RECORDED=, LOADED=, CLIENTS=, INSTALLED=.
set -u
ROOT="$1"; W="$(mktemp -d)"; export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
unset EXAKIT_PERSONA EXAKIT_PERSONA_ACTIVE EXAKIT_DATASETS EXAKIT_DATASETS_PRESELECT EXAKIT_LOAD_SAMPLE \
      EXAKIT_DATA_FILE EXAKIT_MCP_CLIENTS EXAKIT_MCP_PRESELECT EXAKIT_SKIP_MCP EXAKIT_MARKETPLACE_ADDONS \
      EXAKIT_MARKETPLACE_ONLY EXAKIT_NOTEBOOK_FRONTENDS UI_TABLE_AUTO
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
. "$ROOT/setup/lib/persona.sh"
# Never a managed-Python download from a test.
run_python_any() { python3 "$@"; }
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
manifest_init >/dev/null 2>&1
manifest_set persona.id data-scientist
manifest_set components.exapump.profile starter-kit

# The CLI's own commands.
for _fn in cmd_persona cmd_data_load cmd_mcp_setup cmd_marketplace; do
    _range="/^$_fn() {/,/^}/p"             # assigned first: bash 3.2 brace-expands it as an argument
    sed -n "$_range" "$ROOT/setup/exakit" > "$W/$_fn.sh"
    . "$W/$_fn.sh"
done
_require_install() { :; }
exakit_init_logging() { :; }
exakit_ensure_runtime_running() { :; }

# The data: Pharma is in, Banking is still to load.
exakit_pending_datasets() { printf 'banking_complaints|Banking complaints (CFPB, ~7k complaints)\n'; }
exakit_load_dataset() {
    _sl_row="$(exakit_data_table_row "$2")"
    [ "${EXAKIT_TABLE_LIVE:-0}" = 1 ] && ui_table_set "$EXAKIT_TABLE_STATE" "$_sl_row" running 30 90 2 "loading 1 data file"
    sleep 1
    [ "${EXAKIT_TABLE_LIVE:-0}" = 1 ] && ui_table_set "$EXAKIT_TABLE_STATE" "$_sl_row" done "" "" "" "" "completed · 1 table, 7,000 rows"
    printf '%s ' "$2" >> "$W/loaded"
    return 0
}

# The AI clients: Claude waiting to be connected, Codex already connected.
exakit_mcp_discover_status() {
    printf 'claude_desktop pending\nclaude_code pending\ncodex connected\ncursor missing\n'
    printf 'vscode_copilot missing\ngemini_cli missing\nopencode missing\ncontinue missing\n'
}
exakit_configure_mcp_readonly_access() { ok "Dedicated MCP read-only access is configured and validated"; return 0; }
exakit_run_mcp_setup_cli() {
    printf '%s\n' "$1" > "$W/clients"
    sleep 1
    printf '{"status":"success","details":{"configured_clients":["claude_desktop","claude_code"],"skipped_clients":[]}}\n' > "$2"
    return 0
}
_exakit_mcp_result_states() { printf 'claude_desktop configured\nclaude_code configured\n'; }
exakit_print_mcp_setup_summary() { info "Restart Claude to load the updated MCP configuration."; }
exakit_print_mcp_ready_panel() { ok "MCP server 'exasol' - read-only, started by your AI client on demand"; }

# The add-ons: the notebook installed, udf-devkit not.
exakit_marketplace_addons() { printf 'notebook|Notebooks\nudf-devkit|Python UDFs\n'; }
_exakit_addon_offerable() { return 0; }
exakit_marketplace_addon_installed() { [ "$1" = notebook ]; }
_exakit_addon_system_present() { return 1; }
exakit_marketplace_addon_available() { return 0; }
exakit_marketplace_addon_description() { printf 'Python UDFs in the database'; }
exakit_component_available() { printf '1.0.0\n'; }
exakit_component_current() { printf '1.0.0\n'; }
exakit_install_addon_skills() { :; }
udf_devkit_install() { printf 'udf-devkit ' >> "$W/installed"; sleep 1; return 0; }

cmd_persona add ml-engineer
printf 'RC=%s\n' "$?"
printf 'RECORDED=%s|%s\n' "$(manifest_get persona.id)" "$(manifest_get persona.source)"
printf 'LOADED=%s\n' "$(cat "$W/loaded" 2>/dev/null || true)"
printf 'CLIENTS=%s\n' "$(cat "$W/clients" 2>/dev/null || true)"
printf 'INSTALLED=%s\n' "$(cat "$W/installed" 2>/dev/null || true)"
rm -rf "$W"
