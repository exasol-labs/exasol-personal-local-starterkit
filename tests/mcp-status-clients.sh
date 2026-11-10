#!/usr/bin/env bash
# Guard `exakit mcp-status`: it answers "what is connected?", per client.
#
# The screen used to reuse the generic MCP operation summary, which answers a
# different question. With no client named the selection is every client the kit
# SUPPORTS, so all eight printed whether one was configured or eight, and the
# per-client records were reduced to "Tracked 4 managed artifact(s)". A reader
# asking about their own Claude got the kit's capabilities and a count.
#
# The trap for a future change is that the data was always there - _status
# returns the artifacts - so a regression looks like a rendering tidy-up and
# reads as harmless. These checks are on the OUTPUT for that reason.
#
#   bash tests/mcp-status-clients.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kh"; mkdir -p "$EXAKIT_HOME"

. "$ROOT/setup/lib/common.sh" 2>/dev/null || {
    printf 'FAIL could not source common.sh\n'; exit 1
}

# A status result shaped like the real one: two configured clients, one present
# but unconfigured, one absent. Written by hand so this suite needs no MCP
# runtime, no client on the machine, and no network.
cat > "$WORK/status.json" <<'JSON'
{
  "operation": "status",
  "status": "success",
  "summary": "Tracked 2 managed artifact(s).",
  "backup_reference": "72c3ba74-eccf-407c-8770-35f692bc801d",
  "selected_clients": ["claude_desktop", "claude_code", "cursor", "codex"],
  "details": {
    "clients": [
      {"client": "claude_desktop", "state": "configured", "path": "/home/u/Library/Application Support/Claude/claude_desktop_config.json"},
      {"client": "claude_code", "state": "configured", "path": "/home/u/.claude.json"},
      {"client": "cursor", "state": "not_set_up", "path": null},
      {"client": "codex", "state": "not_installed", "path": null}
    ]
  }
}
JSON

out="$(exakit_print_mcp_operation_summary "$WORK/status.json" 2>&1)"

# 1. Every CONFIGURED client gets its own row, named the way a human knows it.
#    Per-client rows are the whole point -- the screen this replaced collapsed
#    them into "Tracked 4 managed artifact(s)", which section 4 still guards.
for pair in "Claude|claude_desktop" "Claude Code (CLI)|claude_code"; do
    label="${pair%%|*}"
    case "$out" in
        *"$label"*) pass "$label has a row" ;;
        *)          fail "$label has no row - status is not per client" ;;
    esac
done

# 2. The table lists WORKING connections, so a client that is not configured is
#    left out -- whether it is absent from the machine (codex) or installed but
#    never set up (cursor). The screen answers "what is connected", not "what
#    does this kit support": the roll-call of all eight supported clients is
#    what made the old screen unreadable.
for label in "Cursor" "Codex"; do
    case "$out" in
        *"$label"*) fail "$label is listed although it is not configured" ;;
        *)          pass "$label is filtered out - it is not configured" ;;
    esac
done
case "$out" in
    *"configured"*) pass "a configured client says so" ;;
    *)              fail "the state \"configured\" never appears" ;;
esac
for gone in "not set up" "not installed"; do
    case "$out" in
        *"$gone"*) fail "\"$gone\" reached the screen - the filter is not applied" ;;
        *)         pass "\"$gone\" never reaches the screen" ;;
    esac
done

# 2b. The next step did not disappear with those rows, it MOVED. With nothing
#     configured there is no row to carry it, so the table says so once and names
#     the command -- otherwise a fresh machine gets an empty box with a heading
#     and no way out of it. This is the hole the filter opens, so it is guarded
#     here rather than left to be discovered on a first install.
cat > "$WORK/none.json" <<'JSON'
{"operation":"status","summary":"Tracked 0 managed artifact(s).",
 "selected_clients":["cursor","codex"],
 "details":{"clients":[
   {"client":"cursor","state":"not_set_up","path":null},
   {"client":"codex","state":"not_installed","path":null}]}}
JSON
none="$(exakit_print_mcp_operation_summary "$WORK/none.json" 2>&1)"
case "$none" in
    *"Nothing configured yet"*) pass "an all-unconfigured result says nothing is set up" ;;
    *) fail "an all-unconfigured result prints an empty table" ;;
esac
case "$none" in
    *"exakit mcp-setup"*) pass "...and names the command that fixes it" ;;
    *) fail "an all-unconfigured result offers no next step" ;;
esac

# 3. The config path is shown for a configured client: "is it set up?" is only
#    half answered without WHERE, which is the file to look at when it is wrong.
case "$out" in
    *".claude.json"*) pass "a configured client shows its config file" ;;
    *) fail "a configured client does not show its config path" ;;
esac

# 4. The old summary's two misleading lines are gone from THIS screen.
case "$out" in
    *"Tracked 2 managed artifact"*) fail "still reports a bare artifact count instead of clients" ;;
    *) pass "no bare artifact count" ;;
esac
case "$out" in
    *"Snapshot:"*) fail "a read-only status screen still prints a backup id" ;;
    *) pass "no snapshot id on a read-only screen" ;;
esac

# 5. Rows fit a terminal. A real path is long enough on its own to push the row
#    past 80, and a wrapped row loses the alignment the table exists for.
widest="$(printf '%s\n' "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
if [ "$widest" -le 80 ]; then
    pass "every row fits 80 columns (widest $widest)"
else
    fail "a row is $widest columns wide - the table wraps and loses its alignment"
fi

# 6. Every OTHER operation keeps the operation summary: this is a status-only
#    change, and a repair or uninstall still needs its status, summary and the
#    snapshot it can be rolled back from.
sed 's/"operation": "status"/"operation": "repair"/' "$WORK/status.json" > "$WORK/repair.json"
rep="$(exakit_print_mcp_operation_summary "$WORK/repair.json" 2>&1)"
case "$rep" in
    *"MCP operation summary"*) pass "a non-status operation keeps the operation summary" ;;
    *) fail "the operation summary is gone for operations that still need it" ;;
esac
case "$rep" in
    *"Snapshot:"*) pass "and keeps the snapshot it can be rolled back from" ;;
    *) fail "a repair no longer reports its snapshot" ;;
esac

# 7. A result with no per-client detail must fall back, not print an empty table
#    (an older kit's result, or a runtime that could not detect anything).
printf '{"operation":"status","status":"success","summary":"Tracked 0 managed artifact(s)."}\n' > "$WORK/bare.json"
bare="$(exakit_print_mcp_operation_summary "$WORK/bare.json" 2>&1)"
case "$bare" in
    *"MCP operation summary"*) pass "a result without client detail falls back to the summary" ;;
    *) fail "a result without client detail prints neither a table nor a summary" ;;
esac

# 8. The PowerShell twin decides the same way; it cannot be executed here.
PS="$ROOT/setup/lib/mcp.ps1"
if grep -q 'operation -eq "status"' "$PS" && grep -q "MCP clients" "$PS"; then
    pass "the PowerShell twin renders a client table for status"
else
    fail "the PowerShell twin has no status client table - Windows keeps the old screen"
fi
if grep -q 'not_set_up' "$PS" && grep -q 'not_installed' "$PS"; then
    pass "the PowerShell twin knows both not-configured states, to filter them"
else
    fail "the PowerShell twin cannot tell which clients to filter out"
fi

# 9. A server that does not start says what it said. This is the AI-bridge
#    step: a user whose assistant cannot see the database starts here, and the
#    launcher's own words for the failure (an image that would not pull, a
#    container that keeps crashing) are in this process's hands. Both halves
#    quote them and name the next step on screen, never "see log". The behaviour
#    itself is driven in tests/mcp-sidecar.sh and tests/mcp-sidecar-ps.ps1.
MCP_SH="$(cat "$ROOT/setup/lib/mcp.sh")"
MCP_PS="$(cat "$ROOT/setup/lib/mcp.ps1")"
case "$MCP_SH" in
    *'_mcp_sidecar_field "$_msa_status" detail'*) pass "the shell half quotes the launcher's reason" ;;
    *) fail "the shell half drops the launcher's reason for a server that did not start" ;;
esac
case "$MCP_SH" in
    *'Fix: exakit mcp-doctor'*) pass "...and names the next step" ;;
    *) fail "the shell half leaves the reader with no next step" ;;
esac
case "$MCP_PS" in
    *'Get-McpSidecarStatusDetail'*) pass "the PowerShell twin quotes the launcher's reason" ;;
    *) fail "the PowerShell twin drops the launcher's reason" ;;
esac
case "$MCP_PS" in
    *'"Fix: $Fix"'*'"exakit mcp-doctor"'*) pass "...and names the next step" ;;
    *) fail "the PowerShell twin leaves the reader with no next step" ;;
esac
# The sidecar's own failures, on the shell side (the module is that and little else).
case "$MCP_SH" in
    *"(see log)"*) fail "a failure still sends the reader to the log" ;;
    *) pass "no failure answers with (see log)" ;;
esac


# ---------------------------------------------------------------------------
# ZERO OF ZERO IS NOT SUCCESS.
#
# The client menu counts "pending" rows - clients installed but not connected -
# and when there are none it reports that everything is already wired up. On a
# machine with no AI client on it at all every row is "not installed", the
# pending count is also zero, and a fresh Windows install was told "All AI
# clients found on this machine are already connected over MCP" over configs
# the kit had never touched. The two cases have to be told apart before that
# line is printed.
# ---------------------------------------------------------------------------
MCP_SH_SRC="$(cat "$ROOT/setup/lib/common.sh")"
MCP_PS_SRC="$(cat "$ROOT/setup/lib/mcp.ps1")"
for _half in sh ps; do
    case "$_half" in
        sh) _src="$MCP_SH_SRC"; _name="the shell half" ;;
        *)  _src="$MCP_PS_SRC"; _name="the PowerShell twin" ;;
    esac
    case "$_src" in
        *"No AI client was found on this machine"*)
            pass "$_name says so when nothing is installed" ;;
        *) fail "$_name still claims every client is connected when none exists" ;;
    esac
    case "$_src" in
        *"_connected_count"*|*'$connectedCount'*)
            pass "$_name counts what is actually connected, not just what is pending" ;;
        *) fail "$_name decides the message from the pending count alone" ;;
    esac
    case "$_src" in
        *"exakit mcp-setup'."*|*"exakit mcp-setup'.\""*)
            pass "$_name names the command that connects one later" ;;
        *) fail "$_name leaves the reader with no next step" ;;
    esac
done

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
