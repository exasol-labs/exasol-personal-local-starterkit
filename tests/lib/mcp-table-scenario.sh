#!/usr/bin/env bash
# The MCP client step's whole life under a real pty: the selection made in the
# table, and then the SAME table as the progress display. Driven by
# tests/lib/tty-replay.py, which types the keystrokes and replays the escape
# codes the way a terminal would.
#
# The keys the replay sends are 'jj \r' — down, down, Space, Enter. Two rows
# down from Claude is Gemini CLI ONLY because the cursor steps over the two rows
# in between, which this machine cannot offer; a build that let it rest on them
# unticks something else, and the finished table says so.
set -u
ROOT="$1"; W="$(mktemp -d)"
export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
EXAKIT_LOG_FILE="$W/log"; : > "$EXAKIT_LOG_FILE"
unset EXAKIT_MCP_CLIENTS

# No database, no MCP python package, no client config files: what is under test
# is the SCREEN, so everything around the table is stubbed at the seams the real
# setup function already goes through.
exakit_ensure_runtime_running() { return 0; }
# Cursor and Continue are not installed here and Copilot is already connected:
# three rows that must be DRAWN (with the reason) and must never be pickable.
exakit_mcp_discover_status() {
    printf 'claude_desktop pending\nclaude_code pending\ncodex pending\n'
    printf 'cursor missing\nvscode_copilot connected\ngemini_cli pending\n'
    printf 'opencode pending\ncontinue missing\n'
}
# The real one narrates as it works. That is why it runs before the table is
# drawn, and this keeps its lines so the replay can see where they land.
exakit_configure_mcp_readonly_access() {
    info "Creating the dedicated MCP read-only database user (mcp_readonly)"
    ok "Dedicated MCP read-only access is configured and validated"
    return 0
}
# One process for every selected client, as the real CLI is — it takes a moment
# and then reports per client.
exakit_run_mcp_setup_cli() {
    sleep 1
    cat > "$2" <<'JSONEOF'
{"status":"success",
 "selected_clients":["claude_desktop","claude_code","codex","opencode"],
 "details":{"configured_clients":["claude_desktop","claude_code","codex","opencode"],
            "skipped_clients":[]}}
JSONEOF
    return 0
}
# The real reader needs python; the mapping from these lines to the rows is what
# is under test here, not the JSON parse.
_exakit_mcp_result_states() {
    printf 'claude_desktop configured\nclaude_code configured\n'
    printf 'codex configured\nopencode configured\n'
}
exakit_print_mcp_setup_summary() {
    info "Restart Claude to load the updated MCP configuration."
    info "Config file paths and per-client state: exakit mcp-status"
}
exakit_print_mcp_ready_panel() {
    ok "MCP server 'exasol' — read-only, started by your AI client on demand"
}

exakit_mcp_setup
rm -rf "$W"
