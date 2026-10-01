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

# 9. A handshake that fails says what it said. This is the AI-bridge step: a
#    user whose assistant cannot see the database starts here, and the answer
#    ("authentication failed", a bad DSN, a package that would not install) is
#    in this process's own hands when it happens. It used to be spent on "see
#    log", which sends the reader into a different program to look for
#    something this run already knew.
#
#    The trap for a future change is that the log line still exists, so losing
#    the SCREEN line looks like tidying. These checks are on the rendered
#    output for that reason, and on the twin's source, which cannot run here.
. "$ROOT/setup/lib/mcp.sh" 2>/dev/null || fail "could not source mcp.sh"

EXAKIT_LOG_FILE="$WORK/handshake.log"
cat > "$EXAKIT_LOG_FILE" <<'HANDSHAKELOG'
INFO  a step that ran long before this validation
CMD   uvx exasol-mcp-server@1.10.1 --help
uvx: building the environment
uvx: resolved 41 packages
uvx: installed exasol-mcp-server

Traceback (most recent call last):
  File "/opt/mcp/exasol/driver.py", line 88, in connect
    connect(dsn="127.0.0.1:8563", user="mcp_readonly", password="SUPERSECRET123")
pyexasol.exceptions.ExaAuthError: [08004] Connection exception - authentication failed
  during handling of the above exception another occurred
  raise ExaAuthError(message)
no initialize result in server output
HANDSHAKELOG
# What mcp_validate sets before it starts: where in the log this validation's
# own output begins, and the password the server was handed.
_mcp_handshake_log_mark=2
_password="SUPERSECRET123"
detail="$(mcp_print_handshake_detail 2>&1)"

case "$detail" in
    *"authentication failed"*) pass "the failure shows what the handshake said" ;;
    *) fail "the handshake's own reason never reaches the screen" ;;
esac
case "$detail" in
    *"no initialize result in server output"*) pass "...including its last word" ;;
    *) fail "the last line of the handshake is not shown" ;;
esac
# The password is in the server's environment and a driver traceback can echo
# its connection arguments back out. Redaction is not optional here.
case "$detail" in
    *"SUPERSECRET123"*) fail "the database password was printed to the screen" ;;
    *) pass "the password is not printed" ;;
esac
case "$detail" in
    *"<redacted>"*) pass "...it is redacted in place, so the line still reads" ;;
    *) fail "the secret's line was dropped instead of redacted" ;;
esac
# Only the tail of the slice: uvx narrates its own environment build first and
# the reason is always last.
case "$detail" in
    *"uvx: building the environment"*) fail "the whole slice is dumped, not its tail" ;;
    *) pass "only the tail of the slice is shown" ;;
esac
shown="$(printf '%s\n' "$detail" | grep -c .)"
if [ "$shown" -le 8 ]; then
    pass "the detail is capped at a few lines ($shown)"
else
    fail "$shown lines were printed - a failure must not dump a screenful"
fi

# Only this validation's slice of the log, from the mark taken before the first
# attempt: an earlier step's noise must never be presented as this failure's
# cause. The mark earns its keep exactly when this validation said LITTLE - a
# tail taken over the whole file then reaches back into the step before it and
# quotes that instead, which is why the fixture here is short on purpose.
EXAKIT_LOG_FILE="$WORK/handshake-short.log"
cat > "$EXAKIT_LOG_FILE" <<'SHORTLOG'
OK    an earlier step, long since finished
OK    a second earlier step
OK    a third earlier step
OK    a fourth earlier step
OK    a fifth earlier step
OK    a sixth earlier step
uvx: nothing to install
handshake timed out
SHORTLOG
_mcp_handshake_log_mark=6
short="$(mcp_print_handshake_detail 2>&1)"
case "$short" in
    *"handshake timed out"*) pass "a short slice is shown whole" ;;
    *) fail "a short slice is not shown at all" ;;
esac
case "$short" in
    *"an earlier step, long since finished"*)
        fail "the tail reached back into a previous step and quoted it as the reason" ;;
    *) pass "the tail never reaches back into a previous step" ;;
esac
# The detail is only half of it: the reassurance and the deeper check travel
# with the reason, or a red block is all the reader gets.
MCP_SH="$(cat "$ROOT/setup/lib/mcp.sh")"
case "$MCP_SH" in
    *"        mcp_print_handshake_detail"*) pass "mcp_validate prints the detail when it fails" ;;
    *) fail "mcp_validate no longer prints the handshake detail" ;;
esac
case "$MCP_SH" in
    *"For a deeper check, run: exakit mcp-doctor"*)
        pass "the failure says the database and configs are unchanged, and names the deeper check" ;;
    *) fail "the failure leaves the reader with no next step" ;;
esac
case "$MCP_SH" in
    *"MCP stdio validation failed (see log)"*) fail "the shell still sends the reader to the log" ;;
    *) pass "the shell no longer answers with (see log)" ;;
esac

# 10. The PowerShell twin decides the same way; it cannot be executed here.
#     Windows is where the server is most likely not to start at all, so the
#     side that CI cannot run is the side that had kept the "(see log)" answer.
MCP_PS="$(cat "$ROOT/setup/lib/mcp.ps1")"
case "$MCP_PS" in
    *"function Show-McpHandshakeDetail"*) pass "the PowerShell twin has the handshake-detail printer" ;;
    *) fail "the PowerShell twin has no handshake-detail printer - Windows keeps (see log)" ;;
esac
case "$MCP_PS" in
    *'$handshakeDetail = "$_"'*) pass "the twin keeps what the handshake said, not just the log line" ;;
    *) fail "the twin throws the reason away and only logs it" ;;
esac
case "$MCP_PS" in
    *'Show-McpHandshakeDetail -Text $handshakeDetail'*) pass "...and prints it on the failure path" ;;
    *) fail "the twin captures the reason and never shows it" ;;
esac
case "$MCP_PS" in
    *'ConvertTo-McpRedactedText -Text $Text -Secrets @($Password)'*)
        pass "the twin redacts the password before printing" ;;
    *) fail "the twin can print the database password to the screen" ;;
esac
case "$MCP_PS" in
    *"MCP stdio validation failed (see log)"*) fail "the twin still sends the reader to the log" ;;
    *) pass "the twin no longer answers with (see log)" ;;
esac
case "$MCP_PS" in
    *"For a deeper check, run: exakit mcp-doctor"*)
        pass "the twin says the database and configs are unchanged, and names the deeper check" ;;
    *) fail "the twin leaves the reader with no next step" ;;
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
