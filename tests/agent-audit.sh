#!/usr/bin/env bash
# agent-audit.sh — the findings of the 2026-09-03/04 agent-operability audits (round 1: twelve, round 2: ten, round 3: seven, round 4: seven),
# each pinned so it cannot come back. The audit drove the kit the way an agent
# with no TTY does: unattended install and uninstall, the sql path, the state
# queries, deliberate breakage. Every check here is the shape of one of those
# findings. Sandboxed kit home, no network, no database.
#
#   bash tests/agent-audit.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}
has() { case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac; }

if ! command -v python3 >/dev/null 2>&1; then echo "SKIP: python3 is needed"; exit 0; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
HOME="$WORK/fake-home"
export EXAKIT_HOME EXAKIT_BIN_DIR EXAKIT_MANIFEST HOME
export NO_COLOR=1 EXAKIT_NO_FANCY=1 EXAKIT_NO_UPDATE_NOTICE=1
export EXAKIT_VERSIONS_URL="https://offline.invalid/versions.json"
mkdir -p "$EXAKIT_HOME/cache" "$EXAKIT_BIN_DIR" "$HOME"
# No real kit may answer for the sandbox: the machine running this may have a
# live database on 8563 and an `exasol` launcher on PATH, and the runtime probe
# would read them as this sandbox's. Scrub the user's bin dir from PATH.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/\.local/bin$' | tr '\n' ':' | sed 's/:$//')"
export PATH
cp "$ROOT/versions.json" "$EXAKIT_HOME/cache/versions.json"
EXAKIT_VERSIONS_CACHE="$EXAKIT_HOME/cache/versions.json"; export EXAKIT_VERSIONS_CACHE
# A minimal install record: a kit, no runtime, nothing running.
cat > "$EXAKIT_MANIFEST" <<JSON
{"manifest_version": 1, "kit_level": 1, "installed_at": "2026-09-03T10:00:00Z",
 "kit": {"version": "0.2.1", "source": "example/kit@main"},
 "runtime": {"type": "personal", "dsn": "127.0.0.1:8563"},
 "components": {}, "steps_completed": ["launcher", "runtime"]}
JSON
CLI="$ROOT/setup/exakit"
. "$ROOT/setup/lib/common.sh"

echo "1. EXAKIT_MCP_CLIENTS=all means the clients detected on this machine:"
_all="$( (
    exakit_mcp_discover_status() { printf 'claude_desktop missing\nclaude_code pending\ncursor missing\ncodex connected\nvscode_copilot missing\ngemini_cli missing\nopencode missing\ncontinue missing\n'; }
    exakit_mcp_detected_clients ) )"
check "detected set, canonical order" "claude_code,codex" "$_all"
check "the parser itself still knows every client (doctor and uninstall use it)" \
    "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" "$(exakit_parse_mcp_client_selection all)"
has "the env path narrows all to the detected set" 'all|ALL|All)' "$(sed -n '/^exakit_mcp_setup()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "...and says which were skipped" "not installed here, skipped" "$(cat "$ROOT/setup/lib/common.sh")"
has "the twin narrows it too" 'Get-McpClientStates' "$(sed -n '/EXAKIT_MCP_CLIENTS -match .*all/,/Configuring MCP clients from EXAKIT_MCP_CLIENTS/p' "$ROOT/setup/lib/mcp.ps1")"
has "AGENTS.md defines all" "every client detected on this machine" "$(cat "$ROOT/AGENTS.md")"

echo "2. the exakit command exists before step 1, and status says installing:"
for _f in setup/setup-macos.sh setup/setup-linux.sh; do
    _early="$(grep -n 'exakit_install_helper_early\|begin_step launcher' "$ROOT/$_f" | head -2 | cut -d: -f2 | tr '\n' ' ')"
    has "$_f installs the helper before the launcher step" "exakit_install_helper_early" "$(printf '%s' "$_early" | awk '{print $1}')"
done
has "the Windows installer writes the shim early too" 'Set-ExakitCmdShim -PsTarget $earlyPs1' "$(cat "$ROOT/setup/setup-windows.ps1")"
mkdir -p "$WORK/kitsrc"; printf '#!/bin/sh\necho stub\n' > "$WORK/kitsrc/exakit"
( exakit_install_helper_early "$WORK/kitsrc" >/dev/null 2>&1 )
check "the helper is installed executable" "yes" "$( [ -x "$EXAKIT_BIN_DIR/exakit" ] && echo yes || echo no )"
# A live install: the step marker plus a lock naming a LIVE pid.
manifest_set install.current_step runtime >/dev/null 2>&1
printf '%s' "$$" > "$EXAKIT_HOME/.install.lock"
_st="$(bash "$CLI" status --json 2>/dev/null)"; _rc="$(bash "$CLI" status --json >/dev/null 2>&1; echo $?)"
check "status --json says installing" "installing" "$(printf '%s' "$_st" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')"
check "...with the step" "runtime" "$(printf '%s' "$_st" | python3 -c 'import json,sys; print(json.load(sys.stdin)["install_step"])')"
has "...and a remedy that says to wait" "installer is still running" "$_st"
check "...exit 3, never 0, while installing" "3" "$_rc"
has "the human screen says so too" "in progress" "$(bash "$CLI" status 2>&1)"
# A dead pid is not an install in progress (a crashed run must not read as one).
printf '%s' "999999" > "$EXAKIT_HOME/.install.lock"
check "a stale lock is not installing" "false" "$(bash "$CLI" status --json 2>/dev/null | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["installing"]).lower())')"
rm -f "$EXAKIT_HOME/.install.lock"; manifest_del install.current_step >/dev/null 2>&1
has "begin_step records the step" 'manifest_set install.current_step' "$(sed -n '/^begin_step()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "exakit_finish clears it" 'manifest_del install.current_step' "$(sed -n '/^exakit_finish()/,/^}/p' "$ROOT/setup/lib/common.sh")"

echo "3. a busy port is a conflict, not a running database:"
_conf="$( (
    . "$ROOT/setup/lib/detect.sh" 2>/dev/null
    . "$ROOT/setup/lib/runtime-personal.sh"
    mkdir -p "$WORK/stub-exasol"; EXAKIT_PERSONAL_BIN="$WORK/stub-exasol/exasol"; printf '#!/bin/sh\nexit 0\n' > "$EXAKIT_PERSONAL_BIN"; chmod +x "$EXAKIT_PERSONAL_BIN"
    personal_deployment_exists() { return 0; }
    port_in_use() { return 0; }
    personal_db_answers() { return 1; }
    personal_status
    personal_deployment_running && echo running || echo not-running ) 2>&1 | tr '\n' ' ')"
check "status is conflict, and the start probe says not running" "conflict not-running " "$_conf"
has "cmd_start refuses on conflict with the remedy" "held by another process" "$(sed -n '/^cmd_start()/,/^}/p' "$CLI")"
has "status --json names the conflict remedy" "another process is listening on the database port" "$(cat "$CLI")"

echo "4. info --json carries the contract keys:"
_info="$(bash "$CLI" info --json 2>/dev/null)"; _irc="$(bash "$CLI" info --json >/dev/null 2>&1; echo $?)"
# One word per state across all five queries - "stopped", the same value
# status --json uses. This used to expect "database not running", which was
# info's and mcp-doctor's private spelling of the state status called
# "stopped", so `d["status"] == "stopped"` was right for one command and
# silently false for the other two.
check "installed/status/remedy present" "True stopped exakit start" \
    "$(printf '%s' "$_info" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["installed"], d["status"], d["remedy"])')"
check "the record is still the manifest" "0.2.1" "$(printf '%s' "$_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kit"]["version"])')"
check "exit 3 with the database down" "3" "$_irc"

echo "5. unattended data-load of a loaded dataset is a no-op, exit 0:"
has "the named-dataset branch exists without --force" 'elif [ -n "${EXAKIT_DATASETS:-}" ] && [ -z "${EXAKIT_DATA_FILE:-}" ]; then' "$(cat "$CLI")"
has "...and says already loaded" "is already loaded — nothing to do" "$(cat "$CLI")"
has "the twin has the branch" 'elseif ($env:EXAKIT_DATASETS -and -not $env:EXAKIT_DATA_FILE)' "$(cat "$ROOT/setup/exakit.ps1")"

echo "6. uninstall keeps the client-config snapshots and never deletes VS Code's file:"
has "snapshots are moved beside the kit home before it goes" '-backups-$(date' "$(sed -n '/^exakit_uninstall_run()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "...and the twin does the same" 'backups-$(Get-Date' "$(cat "$ROOT/setup/exakit.ps1")"
has "the VS Code adapter never removes the file" "remove_file=False" "$(sed -n '/def render_removal/,/def validate_render/p' "$ROOT/mcp/adapters/vscode_copilot.py")"

echo "7. sql remedies come first, on stdout, without the generic hint:"
has "the remedy is data" "exakit_db_error_remedy()" "$(cat "$ROOT/setup/lib/common.sh")"
check "FETCH FIRST names LIMIT" "yes" "$(exakit_db_error_remedy 'syntax error, unexpected FETCH_' | grep -q 'LIMIT' && echo yes || echo no)"
_sqlbody="$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"
has "cmd_sql prints the remedy before the output" '_sql_remedy="$(exakit_db_error_remedy' "$_sqlbody"
has "...and drops exapump's generic hint" "grep -v '^[[:space:]]*Hint: '" "$_sqlbody"
lacks "...and no longer warns to stderr after the output" 'exakit_explain_db_error "$_sql_out"' "$_sqlbody"

echo "8. doctor derives client state from health:"
has "the service builds details.clients" 'details["clients"] = client_states' "$(cat "$ROOT/mcp/service.py")"
has "...with the five states" "configured_client_missing" "$(cat "$ROOT/mcp/service.py")"
has "the shell renders that map for doctor" 'if doc.get("operation") == "doctor" and client_states:' "$(cat "$ROOT/setup/lib/common.sh")"
has "the twin renders it too" 'configured_client_missing = "configured, not installed"' "$(cat "$ROOT/setup/lib/mcp.ps1")"
has "remedy comes from a warning or error only" 'RANK = {"critical": 0, "error": 1, "warning": 2}' "$(cat "$ROOT/setup/lib/common.sh")"

echo "9. sql reruns a saved file, reads stdin, answers --help:"
printf -- '-- saved by the skill\n-- second comment\nDROP TABLE T;\n' > "$WORK/saved.sql"
has "--file is read and its comments dropped (the gate sees DROP)" "not a read statement" "$(bash "$CLI" sql --file "$WORK/saved.sql" 2>&1)"
has "stdin is read too" "not a read statement" "$(bash "$CLI" sql < "$WORK/saved.sql" 2>&1)"
has "a missing file is a clear rejection" "No such file" "$(bash "$CLI" sql --file "$WORK/nope.sql" 2>&1)"
check "--help renders the page, exit 0" "0" "$(bash "$CLI" sql --help >/dev/null 2>&1; echo $?)"
has "...and it is the sql page" "exakit sql" "$(bash "$CLI" sql --help 2>&1)"
check "an unknown option still exits 2" "2" "$(bash "$CLI" sql --bogus 'SELECT 1' >/dev/null 2>&1; echo $?)"

echo "10. a typo is a typo, not a write:"
_typo="$(bash "$CLI" sql 'SELCT 1' 2>&1)"
has "SELCT is reported as unrecognised" "is not an SQL statement this command recognises" "$_typo"
lacks "...and is not pointed at --write as a write" "not a read statement" "$_typo"
has "a real write is still a write" "not a read statement" "$(bash "$CLI" sql 'DROP TABLE T' 2>&1)"
check "both exit 2" "2 2" "$(bash "$CLI" sql 'SELCT 1' >/dev/null 2>&1; printf '%s ' $?; bash "$CLI" sql 'DROP TABLE T' >/dev/null 2>&1; echo $?)"

echo "11. --json on version and mcp-status, unknown options rejected:"
_v="$(bash "$CLI" version --json 2>/dev/null)"
check "version --json is one object with the contract keys" "yes" \
    "$(printf '%s' "$_v" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["installed"] is True; assert d["status"] in ("current","update_pending"); assert (d["remedy"] is None) == (d["status"] == "current"); print("yes")' 2>/dev/null || echo no)"
has "...with component rows" '"component": "exakit"' "$_v"
# EVERY row says whether it is optional. Without this an agent could not tell
# "you never installed this add-on" from "a piece of your kit is missing":
# both answer status "available"/"missing" with no other difference. Checked
# both ways round, so a builder that hardcodes true or false fails.
check "every component row says whether it is an add-on" "yes" \
    "$(printf '%s' "$_v" | python3 -c '
import json, sys
rows = json.load(sys.stdin)["components"]
assert rows, "no component rows"
assert all(isinstance(r.get("addon"), bool) for r in rows), "a row has no addon flag"
by = {r["component"]: r["addon"] for r in rows}
assert by.get("dash-server") is True, "dash-server is not marked an add-on"
assert by.get("exakit") is False, "exakit is marked an add-on"
print("yes")' 2>/dev/null || echo no)"
check "version --bogus exits 2" "2" "$(bash "$CLI" version --bogus >/dev/null 2>&1; echo $?)"
_ms="$(bash "$CLI" mcp-status --json 2>/dev/null)"
check "mcp-status --json is one object with a client list" "yes" \
    "$(printf '%s' "$_ms" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["installed"] is True and "status" in d and "remedy" in d and isinstance(d["details"]["clients"], list); print("yes")' 2>/dev/null || echo no)"
check "mcp-status --bogus exits 2" "2" "$(bash "$CLI" mcp-status --bogus >/dev/null 2>&1; echo $?)"
lacks "the client-name error no longer lists three of eight" "claude_desktop, cursor, codex, or all" "$(cat "$ROOT/setup/lib/common.sh")"

echo "12. a successful repair clears the failure note:"
has "cmd_mcp_doctor clears it" "exakit_clear_failure_note" "$(sed -n '/^cmd_mcp_doctor()/,/^}/p' "$CLI")"

# --- Round 2 (kit 0.2.3 audit) ---------------------------------------------

echo "R2-1. mcp-setup refuses options and arguments instead of ignoring them:"
check "mcp-setup --bogus exits 2" "2" "$(bash "$CLI" mcp-setup --bogus >/dev/null 2>&1; echo $?)"
has "...and names the EXAKIT_MCP_CLIENTS form" "EXAKIT_MCP_CLIENTS=" "$(bash "$CLI" mcp-setup --clients vscode_copilot 2>&1)"
check "a bare client name exits 2 too" "2" "$(bash "$CLI" mcp-setup vscode_copilot >/dev/null 2>&1; echo $?)"
lacks "nothing was set up on the way out" "MCP setup will edit" "$(bash "$CLI" mcp-setup --bogus 2>&1)"

echo "R2-2. status --json names a remedy for every install step that never finished:"
_sj="$(bash "$CLI" status --json 2>/dev/null)"
check "steps_missing lists the four unfinished steps" "exapump,mcp,pyexasol,exakit_helper" \
    "$(printf '%s' "$_sj" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["steps_missing"]))' 2>/dev/null)"
check "remedies.mcp is exakit mcp-setup" "exakit mcp-setup" "$(printf '%s' "$_sj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["remedies"]["mcp"])' 2>/dev/null)"
check "remedies.pyexasol is exakit update" "exakit update" "$(printf '%s' "$_sj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["remedies"]["pyexasol"])' 2>/dev/null)"
# This fixture's runtime does not EXIST (the container is absent), so the
# database remedy is the installer, not "exakit start" - which was the
# pre-runtime remedy bug this suite used to pin as correct. The property under
# test is unchanged: the database's remedy outranks the unfinished steps'.
# ...and per AGK-08 the remedy is the installer's RUNNABLE command, not prose.
check "the missing database still ranks first in the hoisted remedy" "runnable-install-command" "$(printf '%s' "$_sj" | python3 -c 'import json,sys
r = json.load(sys.stdin)["remedy"]
print("runnable-install-command" if r.startswith(("curl ", "irm ")) and "install" in r else r)' 2>/dev/null)"
_sj_full="$(python3 - "$EXAKIT_MANIFEST" "$CLI" <<'PY'
import json, os, subprocess, sys
manifest, cli = sys.argv[1:3]
doc = json.load(open(manifest))
saved = doc["steps_completed"]
doc["steps_completed"] = ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"]
json.dump(doc, open(manifest, "w"))
try:
    out = subprocess.run(["bash", cli, "status", "--json"], capture_output=True, text=True).stdout
finally:
    doc["steps_completed"] = saved
    json.dump(doc, open(manifest, "w"))
d = json.loads(out)
print("%s|%s" % (",".join(d["steps_missing"]), "mcp" in d["remedies"]))
PY
)"
check "with every step done, nothing is missing and no step remedy appears" "|False" "$_sj_full"

echo "R2-3. the remedy matcher reads the statement for TOP, and knows a TLS handshake failure:"
has "SELECT TOP n (engine: unexpected UNSIGNED_INTEGER_) gets the LIMIT remedy" "LIMIT" \
    "$(exakit_db_error_remedy 'Query execution failed: Protocol error: syntax error, unexpected UNSIGNED_INTEGER_, expecting UNION_' 'SELECT TOP 3 * FROM TPCH.NATION')"
check "a column called TOPIC is not TOP" "" "$(exakit_db_error_remedy 'syntax error, unexpected ;' 'SELECT TOPIC FROM T GROUP BY')"
check "a non-syntax error with TOP in the text stays quiet" "" "$(exakit_db_error_remedy 'some other failure' 'SELECT TOP 3 * FROM T')"
has "tls handshake eof points at exakit status" "exakit status" "$(exakit_db_error_remedy 'Error: Failed to connect to 127.0.0.1:8563: TLS error: tls handshake eof')"
lacks "...and is not mistaken for a stopped database" "stopped or unreachable" "$(exakit_db_error_remedy 'TLS error: tls handshake eof')"
has "cmd_sql hands the statement to the matcher" 'exakit_db_error_remedy "$_sql_out" "$_sql_text"' "$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"

echo "R2-4. a successful start retires only a runtime failure note:"
exakit_note_failure "Port 8563 is held by another process (pid 1, Python), not by Exasol, so the database cannot start. Stop that process, then: exakit start"
exakit_clear_runtime_failure_note
check "the port-conflict note is gone" "absent" "$([ -f "$EXAKIT_HOME/.last-failure" ] && echo present || echo absent)"
exakit_note_failure "the AI client configuration did not finish (see the log)"
exakit_clear_runtime_failure_note
check "an install-step note stays" "present" "$([ -f "$EXAKIT_HOME/.last-failure" ] && echo present || echo absent)"
exakit_clear_failure_note
has "cmd_start calls it once the database runs" "exakit_clear_runtime_failure_note" "$(sed -n '/^cmd_start()/,/^}/p' "$CLI")"

echo "R2-5. exakit sql --json is an option, and the gate still runs first:"
check "sql --json 'SELCT 1' exits 2 (typo gate before any connection)" "2" "$(bash "$CLI" sql --json 'SELCT 1' >/dev/null 2>&1; echo $?)"
has "the unknown-option message lists --json" "--json" "$(bash "$CLI" sql --bogus 'SELECT 1' 2>&1)"
has "the --json branch uses exapump's own json format" "-f json" "$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"
has "help names --json" "--json" "$(python3 -c 'import json; d=json.load(open("'"$ROOT"'/setup/help/exakit.json")); print([c for c in d["commands"] if c["command"]=="sql"][0]["options"])' 2>/dev/null)"

echo "R2-6. doctor names the client on every per-artifact finding, and the remedy names the command:"
check "no per-artifact finding is left without a client in scope" "0" "$(grep -c 'scope={"path": artifact.path}' "$ROOT/mcp/validator/service.py")"
check "no finding says the bare 'Run repair' any more" "0" "$(grep -c 'recommended_action="Run repair' "$ROOT/mcp/validator/service.py")"
has "the shared remedy names exakit mcp-doctor" "exakit mcp-doctor" "$(grep -A2 '^REPAIR_ACTION' "$ROOT/mcp/validator/service.py")"
has "discover-clients checks the file, not only the record" "_managed_entry_present" "$(cat "$ROOT/mcp/cli.py")"

echo "R2-7. the docs and skills carry the texts an agent actually sees:"
has "AGENTS.md: the TOP engine text" "UNSIGNED_INTEGER_" "$(cat "$ROOT/AGENTS.md")"
has "AGENTS.md: the masked MCP error" "A database error occurred" "$(cat "$ROOT/AGENTS.md")"
has "AGENTS.md: the TLS conflict text" "tls handshake" "$(cat "$ROOT/AGENTS.md")"
has "exasol-mcp skill: the masked MCP error" "A database error occurred" "$(cat "$ROOT/skills/exasol-mcp/SKILL.md")"
has "exasol-exapump skill: exakit sql --file" "exakit sql --file" "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"
has "exasol-exapump skill: discovery via SYS.EXA_ALL_TABLES" "SYS.EXA_ALL_TABLES" "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"
has "starter skill: discovery without MCP" "SYS.EXA_ALL_TABLES" "$(cat "$ROOT/skills/local-agent-ready-starter/SKILL.md")"
lacks "exasol-exapump skill no longer sends script files to exapump wholesale" "Drop to \`exapump\` for script files" "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"

# --- Round 3 (fresh 0.2.4 install audit) -----------------------------------

echo "R3-1. every command refuses an unknown option with exit 2, before doing anything:"
for _c in stop start info guide whats-new skills-install marketplace help catalog mcp-doctor mcp-remove update skills preflight; do
    check "exakit $_c --bogus exits 2" "2" "$(bash "$CLI" $_c --bogus >/dev/null 2>&1 </dev/null; echo $?)"
done
check "update with an unknown target exits 2" "2" "$(bash "$CLI" update nosuch-component >/dev/null 2>&1; echo $?)"
check "...and records no failure note" "absent" "$([ -f "$EXAKIT_HOME/.last-failure" ] && echo present || echo absent)"
has "help --bogus is a refusal, not a grep usage error" "Unknown option" "$(bash "$CLI" help --bogus 2>&1)"
check "info --json still answers" "yes" "$(bash "$CLI" info --json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin); print("yes")' 2>/dev/null || echo no)"

echo "R3-2. sql --json refusals are JSON on stdout:"
_rj="$(bash "$CLI" sql --json 'SELCT 1' 2>/dev/null)"
check "a typo is {ok:false, rejected:true}" "False True" "$(printf '%s' "$_rj" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["ok"], d["rejected"])' 2>/dev/null)"
check "...exit 2" "2" "$(bash "$CLI" sql --json 'SELCT 1' >/dev/null 2>&1; echo $?)"
check "two statements: JSON too" "False" "$(bash "$CLI" sql --json 'SELECT 1; SELECT 2' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)"
check "an unknown option with --json: JSON too" "False" "$(bash "$CLI" sql --json --bogus 'SELECT 1' 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])' 2>/dev/null)"
check "without --json the refusal is still the human line" "" "$(bash "$CLI" sql 'SELCT 1' 2>/dev/null)"

echo "R3-3. exakit mcp-remove exists and takes client names:"
check "no client named: exit 2" "2" "$(bash "$CLI" mcp-remove >/dev/null 2>&1; echo $?)"
check "'all' refused: exit 2" "2" "$(bash "$CLI" mcp-remove all >/dev/null 2>&1; echo $?)"
has "help documents it" '"command": "mcp-remove"' "$(cat "$ROOT/setup/help/exakit.json")"
has "the doctor remedy that names it is now true" "exakit mcp-remove" "$(cat "$ROOT/mcp/validator/service.py")"
has "AGENTS.md names it" "exakit mcp-remove" "$(cat "$ROOT/AGENTS.md")"

echo "R3-4. the not-found hint knows file-loaded columns keep their case:"
has "STARTER_KIT table: says to quote" 'must be quoted' "$(exakit_db_error_remedy 'Query execution failed: object VISITS not found [line 1, column 12]' 'SELECT SUM(VISITS) FROM STARTER_KIT.VISITS')"
lacks "a bundled TPCH table: no such line" 'must be quoted' "$(exakit_db_error_remedy 'object N_NAM not found' 'SELECT N_NAM FROM TPCH.NATION')"
has "the exapump skill says the same" 'keep the file' "$(cat "$ROOT/skills/exasol-exapump/SKILL.md")"

echo "R3-5. uninstall removes exactly the permission rules the kit added:"
mkdir -p "$HOME/.claude"
printf '%s\n' '{"permissions": {"allow": ["Bash(exakit status:*)", "Bash(git status:*)", "mcp__exasol"], "deny": ["Bash(exakit uninstall:*)", "Bash(rm -rf:*)"]}, "theme": "dark"}' > "$HOME/.claude/settings.json"
check "reports what it removed" "REMOVED 3" "$(exakit_remove_readonly_allowlist)"
check "the user's own rules and settings stay" "Bash(git status:*)|Bash(rm -rf:*)|dark" \
    "$(python3 -c 'import json; d=json.load(open("'"$HOME"'/.claude/settings.json")); print("|".join(d["permissions"]["allow"]+d["permissions"]["deny"]+[d["theme"]]))')"
check "a second run removes nothing" "REMOVED 0" "$(exakit_remove_readonly_allowlist)"
has "the uninstall step calls it" "exakit_remove_readonly_allowlist" "$(sed -n '/^_exakit_remove_installed_skills()/,/^}/p' "$ROOT/setup/lib/common.sh")"

echo "R3-6. doctor repairs a repairable WARNING, and blames one file once:"
_rr="$WORK/result.json"
printf '%s' '{"operation":"doctor","status":"success_with_warnings","findings":[{"code":"permission_drift","severity":"warning","scope":{"path":"/x","client":"codex"}}]}' > "$_rr"
check "a loosened mode is repairable" "yes" "$(_exakit_mcp_result_repairable "$_rr" && echo yes || echo no)"
printf '%s' '{"operation":"doctor","status":"success_with_warnings","findings":[{"code":"managed_client_missing","severity":"warning","scope":{"client":"cursor"}}]}' > "$_rr"
check "an absent client is not" "no" "$(_exakit_mcp_result_repairable "$_rr" && echo yes || echo no)"
has "cmd_mcp_doctor acts on the flag" "EXAKIT_MCP_LAST_REPAIRABLE" "$(sed -n '/^cmd_mcp_doctor()/,/^}/p' "$CLI")"
has "one finding per file in the validator" "seen_paths" "$(cat "$ROOT/mcp/validator/service.py")"
has "the hoisted remedy ranks the worst finding about a file first" "RANK = " "$(cat "$ROOT/setup/lib/common.sh")"

echo "R3-7. add-on endpoints go only to connected clients; configured means the exasol entry:"
has "repair scopes the add-on to connected clients" "_connected_clients(repository" "$(cat "$ROOT/mcp/cli.py")"
lacks "...and never to the whole supported list" "clients=clients or list(SETUP_CLIENT_IDS)" "$(cat "$ROOT/mcp/cli.py")"
has "discover counts the exasol entry only" '_record_entry_name(record) != "exasol"' "$(cat "$ROOT/mcp/cli.py")"

# --- Round 4 (main as of 2026-09-07) -----------------------------------------

echo "R4-1. sql --json carries the result through files, never argv:"
lacks "no argv hand-off of rows" 'run_python - "$_sql_rc" "$_sql_rows"' "$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"
has "rows come from a file" '_sql_rowsf' "$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"
has "a render failure is itself a JSON answer" 'could not render the result as JSON' "$(sed -n '/^cmd_sql()/,/^}/p' "$CLI")"

echo "R4-2. the install lock names its holder, not just a pid:"
_lk="$WORK/lock"; sleep 60 & _sp=$!
printf '%s\n%s\n' "$_sp" "$(exakit_process_start_time "$_sp")" > "$_lk"
check "a live holder with the recorded start time is alive" "yes" "$(exakit_lock_holder_alive "$_lk" && echo yes || echo no)"
printf '%s\n%s\n' "$_sp" "Thu Jan  1 00:00:00 1970" > "$_lk"
check "the same pid with another start time is NOT the holder" "no" "$(exakit_lock_holder_alive "$_lk" && echo yes || echo no)"
printf '%s\n' "$_sp" > "$_lk"
check "an old one-line lock still falls back to the pid check" "yes" "$(exakit_lock_holder_alive "$_lk" && echo yes || echo no)"
kill "$_sp" 2>/dev/null; wait "$_sp" 2>/dev/null
check "a dead pid is not the holder" "no" "$(exakit_lock_holder_alive "$_lk" && echo yes || echo no)"
has "acquire writes two lines" 'exakit_process_start_time "$$"' "$(sed -n '/^exakit_acquire_lock()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "status reads the lock through the same helper" 'exakit_lock_holder_alive "$EXAKIT_HOME/.install.lock"' "$(sed -n '/^cmd_status()/,/^}/p' "$CLI")"

echo "R4-3. a relocated EXAKIT_HOME answers as not installed, in JSON when asked:"
_nh="$(EXAKIT_HOME="$WORK/nowhere" bash "$CLI" status --json 2>/dev/null)"
check "JSON with installed=false and a remedy" "False|not installed|yes" \
    "$(printf '%s' "$_nh" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s|%s" % (d["installed"], d["status"], "yes" if d["remedy"] else "no"))' 2>/dev/null)"
check "...exit 4" "4" "$(EXAKIT_HOME="$WORK/nowhere" bash "$CLI" status --json >/dev/null 2>&1; echo $?)"
check "the prose form exits 4 too" "4" "$(EXAKIT_HOME="$WORK/nowhere" bash "$CLI" status >/dev/null 2>&1; echo $?)"

echo "R4-4. unsupported and one-column files are refused or flagged before the loader:"
has "the loader refuses unknown kinds before running" 'case "$_llf_kind" in' "$(cat "$ROOT/setup/lib/exapump.sh")"
has "...and a .txt/.tsv by name, with the rename that loads it" '_exakit_csv_extension_refused "$_path"' "$(cat "$ROOT/setup/lib/exapump.sh")"
has "...as bad input, not a failed step" "_llf_refuse \"Cannot load '" "$(cat "$ROOT/setup/lib/exapump.sh")"
has "a missing file without a TTY is bad input too" '_llf_refuse "File not found or empty' "$(cat "$ROOT/setup/lib/exapump.sh")"
has "the data-load menu turns the refusal into exit 2" '_local_status" -eq 3' "$(cat "$ROOT/setup/lib/exapump.sh")"
has "the installer does not book it as a failed step" 'The local file was refused' "$(cat "$ROOT/setup/lib/common.sh")"
# A ';' header used to be WARNED about; it is now read and passed on as
# exapump's own --delimiter, the file itself untouched.
has "a ';' header is passed on as exapump's own delimiter" '--delimiter "$_upl_delim"' "$(cat "$ROOT/setup/lib/exapump.sh")"
has "the PowerShell twin refuses the same files" 'llfKind -eq "unknown"' "$(cat "$ROOT/setup/lib/exapump.ps1")"

echo "R4-5. service logs are created owner-only before launchd opens them:"
has "the log is created 0600 before launchctl load" 'chmod 600 "$EXAKIT_LOG_DIR/autostart-$_ar_id.log"' "$(cat "$ROOT/setup/lib/common.sh")"

echo "R4-6. the installer records where the bootstrap time went:"
has "install.sh stamps its start" 'EXAKIT_INSTALL_T0="$(date +%s)"' "$(cat "$ROOT/install.sh")"
has "setup logs the elapsed bootstrap" 'after the installer began' "$(cat "$ROOT/setup/setup-macos.sh")"
has "...on the WSL path too" 'after the installer began' "$(cat "$ROOT/setup/setup-linux.sh")"

# --- Round 5 (agent-operability audit, round 2 of the 0.2.4 series) ---------
#
# THE FIXTURE THIS SUITE NEVER HAD. Every check above builds its manifest with
# `"runtime": {"type": "personal"}` already set, so the whole pre-runtime state
# - an installer that stopped before it deployed a database - was untested, and
# a fix that touched only the Windows prose could ship green while every other
# channel still sent an agent to `exakit start`, a command that in that state
# can only fail. This section owns that state.
PRE="$WORK/prerun"
mkdir -p "$PRE"
cat > "$PRE/manifest.json" <<'JSON'
{"manifest_version": 1, "kit_level": 2, "installed_at": "2026-09-07T10:00:00Z",
 "kit": {"version": "0.2.4", "source": "example/kit@main"},
 "install": {"current_step": "runtime"},
 "components": {}, "steps_completed": ["launcher"]}
JSON
# A DEAD installer: a lock naming a pid that is not running.
printf '%s\n' "999999" > "$PRE/.install.lock"
pre() { EXAKIT_HOME="$PRE" bash "$CLI" "$@"; }
pre_rc() { EXAKIT_HOME="$PRE" bash "$CLI" "$@" >/dev/null 2>&1; echo $?; }

echo "R5-1. with no runtime recorded, every channel names the installer, not exakit start:"
_pre_sj="$(pre status --json 2>/dev/null)"
check "status --json is one object" "yes" "$(printf '%s' "$_pre_sj" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
check "top-level status is a documented word, not 'unknown'" "no database" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])' 2>/dev/null)"
check "installed is true - the KIT is installed, the DATABASE is not" "True" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["installed"])' 2>/dev/null)"
check "a dead lock is not 'installing', and install_step survives it" "False|runtime" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s" % (d["installing"], d["install_step"]))' 2>/dev/null)"
check "remedies.install names the re-run (AGENTS.md promises exactly this)" "yes" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys; print("yes" if "install" in json.load(sys.stdin)["remedies"] else "no")' 2>/dev/null)"
check "the hoisted remedy is the installer, RUNNABLE, never exakit start" "runnable-install-command" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys
r = json.load(sys.stdin)["remedy"]
print("runnable-install-command" if r and r.startswith(("curl ", "irm ")) else r)' 2>/dev/null)"
check "remedies.database is the installer too, not exakit start" "yes" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys
d = json.load(sys.stdin)["remedies"]
print("yes" if d.get("database", "").startswith(("curl ", "irm ")) else d.get("database"))' 2>/dev/null)"
_pre_prose="$(pre status 2>&1)"
lacks "the human screen no longer prescribes exakit start" "Start it:" "$_pre_prose"
has "...it names the installer instead" "Deploy it:" "$_pre_prose"
has "...and says where the install stopped" "did not finish at step: runtime" "$_pre_prose"
has "the PowerShell twin answers 'not installed' for a runtime-less kit too" \
    'default { "not installed" }' "$(cat "$ROOT/setup/exakit.ps1")"
has "...and its screen names the installer for that state" 'Write-Host "Deploy it:' "$(cat "$ROOT/setup/exakit.ps1")"

echo "R5-2. every remedy is a runnable command; the prose lives in remedy_hints:"
check "no remedy in the pre-runtime state is an English sentence" "all-runnable" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys
d = json.load(sys.stdin)
bad = [k for k, v in d["remedies"].items() if not v.startswith(("exakit ", "curl ", "irm "))]
print("all-runnable" if not bad else "prose: %s" % ",".join(bad))' 2>/dev/null)"
check "the hints are there, keyed the same way" "yes" \
    "$(printf '%s' "$_pre_sj" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if set(d["remedy_hints"]) <= set(d["remedies"]) and d["remedy_hints"] else "no")' 2>/dev/null)"
_ps="$(cat "$ROOT/setup/exakit.ps1")"
has "the twin builds remedy_hints too" 'remedy_hints    = $remedyHints' "$_ps"
lacks "...and no longer puts the installing sentence inside remedy" \
    'remedy = "exakit status --json   (the installer is still running' "$_ps"
lacks "...nor the step prose inside remedy" \
    '"re-run the installer (it resumes at the unfinished step)"' "$_ps"
has "the twin's not-installed answer is a runnable command" 'remedy    = (Get-ExakitInstallCommand)' "$_ps"
has "AGENTS.md states the runnable-remedy contract" "is a command you can run verbatim, or " "$(cat "$ROOT/AGENTS.md")"

echo "R5-3. a failed QUERY is not a failed install step - it writes nothing:"
BARE="$WORK/bare-home"
_bare_out="$(EXAKIT_HOME="$BARE" bash "$CLI" sql --json 'SELECT 1' 2>/dev/null)"
_bare_rc="$(EXAKIT_HOME="$BARE" bash "$CLI" sql --json 'SELECT 1' >/dev/null 2>&1; echo $?)"
check "sql --json on a bare machine still answers JSON" "False" \
    "$(printf '%s' "$_bare_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["installed"])' 2>/dev/null)"
check "...with the documented not-installed code, not 1" "4" "$_bare_rc"
check "no .last-failure was written" "absent" "$([ -f "$BARE/.last-failure" ] && echo present || echo absent)"
check "no logs/ tree was created" "absent" "$([ -d "$BARE/logs" ] && echo present || echo absent)"
EXAKIT_HOME="$BARE" bash "$CLI" mcp-status --json >/dev/null 2>&1
check "mcp-status leaves the same machine untouched" "absent" \
    "$([ -f "$BARE/.last-failure" ] || [ -d "$BARE/logs" ] && echo present || echo absent)"
has "_require_install checks the manifest BEFORE it opens a log" \
    "NOTHING IS WRITTEN BEFORE THE MANIFEST CHECK" "$(cat "$CLI")"

echo "R5-4. a read-only state query installs nothing, and degrades honestly:"
has "exakit_ensure_uv refuses to bootstrap under a read-only query" \
    'if [ "${EXAKIT_READONLY_QUERY:-0}" = "1" ]; then' "$(sed -n '/^exakit_ensure_uv()/,/^}/p' "$ROOT/setup/lib/common.sh")"
has "manifest reads no longer go through the 3.11 gate" "run_python_any" \
    "$(sed -n '/^manifest_get()/,/^}/p' "$ROOT/setup/lib/common.sh")"
NOPY="$WORK/nopy"; NOPYBIN="$WORK/nopy-bin"
mkdir -p "$NOPY" "$NOPYBIN"
cp "$EXAKIT_MANIFEST" "$NOPY/manifest.json"
# STOCK MACOS, EXACTLY: no interpreter the kit will use and no uv anywhere, so
# the only way to answer is to download one - which is what a state query must
# never do. A stub PATH is what makes this a real test rather than a grep: with
# a uv on the machine's PATH the bootstrap short-circuits and proves nothing.
NOPYPATH="$WORK/nopy-path"; mkdir -p "$NOPYPATH"
for _bin in bash sh env sed awk grep cat tr cut sort head tail date mkdir rm chmod ls wc printf uname id dirname basename mktemp find stat; do
    _src="$(command -v "$_bin" 2>/dev/null || true)"
    [ -n "$_src" ] && ln -sf "$_src" "$NOPYPATH/$_bin"
done
# A curl that downloads nothing and leaves a fingerprint. The point of the
# assertion below is that this file is never created: a read-only state query
# must not so much as REACH for the network, let alone install 36 MB from it.
printf '#!/bin/sh\n: > "%s"\n' "$WORK/uv-download-attempted" > "$NOPYPATH/curl"
chmod +x "$NOPYPATH/curl"
_nopy="$(EXAKIT_HOME="$NOPY" EXAKIT_BIN_DIR="$NOPYBIN" EXAKIT_DISABLE_SYSTEM_PYTHON=1 \
    PATH="$NOPYPATH" bash "$CLI" status --json 2>/dev/null)"
check "no state query ever reached for the uv download" "absent" \
    "$([ -f "$WORK/uv-download-attempted" ] && echo present || echo absent)"
check "with no usable interpreter the answer is still one JSON object" "yes" \
    "$(printf '%s' "$_nopy" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
check "...carrying the three contract keys" "yes" \
    "$(printf '%s' "$_nopy" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if all(k in d for k in ("installed","status","remedy")) else "no")' 2>/dev/null)"
check "...and NOTHING was installed into the bin dir" "empty" \
    "$([ -z "$(ls -A "$NOPYBIN" 2>/dev/null)" ] && echo empty || echo "$(ls -A "$NOPYBIN")")"

echo "R5-5. the state queries agree on installed and on the exit code:"
_pre_doc="$(pre mcp-doctor --json 2>/dev/null)"
check "mcp-doctor --json agrees with status --json on installed" "True" \
    "$(printf '%s' "$_pre_doc" | python3 -c 'import json,sys; print(json.load(sys.stdin)["installed"])' 2>/dev/null)"
check "...and on the exit code" "3 3" "$(printf '%s %s' "$(pre_rc status --json)" "$(pre_rc mcp-doctor --json)")"
check "info --json agrees too" "True|no database" \
    "$(pre info --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%s|%s" % (d["installed"], d["status"]))' 2>/dev/null)"
check "plain info exits like info --json, not 0" "3 3" "$(printf '%s %s' "$(pre_rc info)" "$(pre_rc info --json)")"
check "plain info on a bare machine exits 4, not 1" "4" \
    "$(EXAKIT_HOME="$WORK/bare2" bash "$CLI" info >/dev/null 2>&1; echo $?)"
# THE EXIT-CODE ALLOW-LIST. AGENTS.md says "the code IS the answer", so a state
# query may only ever answer with a code the document defines.
_codes=""
for _q in status info version mcp-status mcp-doctor; do
    for _h in "$PRE" "$WORK/bare3" "$EXAKIT_HOME"; do
        _c="$(EXAKIT_HOME="$_h" bash "$CLI" $_q --json >/dev/null 2>&1 </dev/null; echo $?)"
        case "$_c" in 0|2|3|4) ;; *) _codes="${_codes:+$_codes }$_q@$(basename "$_h")=$_c" ;; esac
        _c="$(EXAKIT_HOME="$_h" bash "$CLI" $_q >/dev/null 2>&1 </dev/null; echo $?)"
        case "$_c" in 0|2|3|4) ;; *) _codes="${_codes:+$_codes }$_q@$(basename "$_h")=$_c" ;; esac
    done
done
check "every state query x state answers 0/2/3/4 and nothing else" "" "$_codes"

# EXAKIT_DB_PORT IS INPUT, so a bad one is exit 2 and not the container
# engine's own complaint six frames down. A leading zero is a separate case:
# bash reads 08563 as octal in an arithmetic test, so a range check alone
# errors on it instead of answering.
_ports=""
for _p in 85631 abc 08563 0 -1 "85 63"; do
    _c="$(EXAKIT_DB_PORT="$_p" EXAKIT_HOME="$WORK/bare3" bash "$CLI" --version >/dev/null 2>&1 </dev/null; echo $?)"
    [ "$_c" = "2" ] || _ports="${_ports:+$_ports }[$_p]=$_c"
done
check "a malformed EXAKIT_DB_PORT is refused as bad input (exit 2)" "" "$_ports"
# A valid port must change nothing: same code as the run that sets no port at
# all. Pinning a literal here would only pin whatever a bare home answers.
_c_set="$(EXAKIT_DB_PORT=8564 EXAKIT_HOME="$WORK/bare3" bash "$CLI" --version >/dev/null 2>&1 </dev/null; echo $?)"
_c_unset="$(EXAKIT_HOME="$WORK/bare3" bash "$CLI" --version >/dev/null 2>&1 </dev/null; echo $?)"
check "a valid EXAKIT_DB_PORT is not refused" "$_c_unset" "$_c_set"

# AUTOSTART IS A PROBE, NOT A RECORDED WISH.
#
# status --json and the status panel read the manifest's autostart.enabled -
# what the user last ASKED for - so a machine whose boot entry had since gone
# answered "autostart": true for a database nothing would restart. On the
# container path that is routine: recreating the container drops its restart
# policy, so a stop/start cycle turned autostart off while the manifest went on
# saying it was on. Found on a real Windows machine, where `exakit status`
# said true and `exakit autostart` said disabled at the same moment.
echo
echo "R6-1. autostart reports reality, not the recorded intent:"
_cs_body="$(sed -n '/^cmd_status()/,/^}/p' "$CLI")"
has "cmd_status probes the boot entries" "_exakit_autostart_registered" "$_cs_body"
lacks "...and no longer reads the manifest's wish" "manifest_get autostart.enabled" "$_cs_body"
_ps_status="$(awk '/^function Invoke-CmdStatus/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/exakit.ps1")"
has "the twin probes too" "Test-ExakitAutostartAll" "$_ps_status"
lacks "...and no longer reads the manifest there either" \
    'Get-ExakitManifestValue "autostart.enabled"' "$_ps_status"
has "the twin's probe requires EVERY service, like exakit autostart does" \
    "Test-ExakitAutostartRegistered -Id" "$(awk '/^function Test-ExakitAutostartAll/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/exakit.ps1")"

echo "R6-2. a multi-line failure keeps the line that names the cause:"
# The note file's line 1 is the reason and every reader takes it. Keeping line
# 1 of a Python traceback records "Traceback (most recent call last):" - which
# is what `exakit status --json` then reported as last_failure, permanently,
# for a crash whose cause was on line 4.
_rs_tb="$(exakit_reason_summary "Traceback (most recent call last):
  File \"<string>\", line 1, in <module>
ModuleNotFoundError: No module named 'exasol_json_tables'")"
has "a traceback yields its final line" "ModuleNotFoundError" "$_rs_tb"
lacks "...not its boilerplate header" "most recent call last" "$_rs_tb"
check "a one-line reason is unchanged" "the database refused the connection" \
    "$(exakit_reason_summary "the database refused the connection")"
check "the summary is always ONE line" "1" \
    "$(printf '%s\n' "$_rs_tb" | wc -l | tr -d ' ')"
# AND THE CALL SITES USE IT. Asserting the helper alone is a guard that cannot
# fail: reverting exakit_note_failure to write "$*" left the helper sitting
# there, correct and unreachable, and this section stayed green.
has "exakit_note_failure runs the reason through it" "exakit_reason_summary" \
    "$(sed -n '/^exakit_note_failure()/,/^}/p' "$ROOT/setup/lib/common.sh")"
lacks "...and no longer writes the raw text as line 1" \
    'printf '"'"'%s\\n%s\\n'"'"' "$*"' \
    "$(sed -n '/^exakit_note_failure()/,/^}/p' "$ROOT/setup/lib/common.sh")"
_ps_common="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "the PowerShell twin exists" "function Get-ExakitReasonSummary" "$_ps_common"
has "...and its soft-failure note runs the reason through it" \
    'Get-ExakitReasonSummary $note' "$_ps_common"
has "...and the log keeps every line, not just the first" \
    'foreach ($rline in @(("" + $reason) -split' "$_ps_common"

echo "R6-3. a leading-dash argument is answered, not swallowed:"
# The .cmd shim runs `powershell -File exakit.ps1 %*`, and that binder never
# lets a "-"-prefixed token fill a positional parameter: --version landed in
# $RestArgs, $Command kept its "help" default, and the CLI printed help and
# exited 0. A script asking a CLI its version got success and the wrong output.
_ps_cli="$(cat "$ROOT/setup/exakit.ps1")"
has "the twin promotes a leading --version" '"--version" { $Command = "version"' "$_ps_cli"
has "...and refuses an unknown one instead of printing help" \
    "Unknown option '\$leading'" "$_ps_cli"

echo "R5-6. a declined destructive repair is not a success:"
_rr="$(sed -n '/^cmd_repair_runtime()/,/^}/p' "$CLI")"
# The window from the confirmation to the end of the declined branch: the code
# it leaves with has to be 5, not the 0 a declined repair used to answer.
_rr_decline="$(printf '%s\n' "$_rr" | grep -A 30 'Delete everything in the database and rebuild it empty?')"
has "the declined path returns a distinct non-zero code" "return 5" "$_rr_decline"
lacks "...and no longer returns 0" "return 0" "$_rr_decline"
has "repair-runtime takes --json" '"Unknown option '"'"'$_rr_arg'"'"' for repair-runtime (supported: --yes, --json)."' "$_rr"
has "...and the declined answer is machine-readable" '"status": "declined"' "$_rr"
# Assigned first: a sed range with a `{` in it is brace-expanded by bash 3.2
# when it sits in argument position. See the note in tests/legacy-crossing.sh
# and the guard in tests/bash32-guard.sh. This one survives today only because
# its start address happens to carry no quotes; the next edit would not.
_cmd_repair_ps="$(sed -n '/^function Invoke-CmdRepairRuntime {/,/^}/p' "$ROOT/setup/exakit.ps1")"
has "the twin exits 5 too" "exit 5" "$_cmd_repair_ps"
has "...and answers --json" 'status = "declined"' "$_ps"
check "the help document names exit 5" "declined" \
    "$(python3 -c 'import json; d=json.load(open("'"$ROOT"'/setup/help/exakit.json")); print([c for c in d["commands"] if c["command"]=="repair-runtime"][0]["exit_codes"]["5"].split(" -")[0])')"
has "AGENTS.md documents exit 5" "exits \`5\` when the destructive confirmation was" "$(cat "$ROOT/AGENTS.md")"

echo "R5-7. a statement whose first line is an SQL comment is SQL, not an option:"
_cmt="$(bash "$CLI" sql --json '-- monthly revenue
DROP TABLE T' 2>/dev/null)"
check "the comment line is stripped and the GATE sees the statement" "not-an-option" \
    "$(printf '%s' "$_cmt" | python3 -c 'import json,sys
e = json.load(sys.stdin)["error"]
print("not-an-option" if "Unknown option" not in e else e)' 2>/dev/null)"
has "...and it is refused as a write, which is what it is" "not a read statement" "$_cmt"
check "a bare -- ends the options, so the statement after it is read" "not-an-option" \
    "$(bash "$CLI" sql --json -- 'DROP TABLE T' 2>/dev/null | python3 -c 'import json,sys
e = json.load(sys.stdin)["error"]
print("not-an-option" if "Unknown option" not in e else e)' 2>/dev/null)"
check "a REAL unknown option is still refused, exit 2" "2" "$(bash "$CLI" sql --nosuch 'SELECT 1' >/dev/null 2>&1; echo $?)"
has "...and the refusal now points at the comment case" "its first line is a '--' comment" \
    "$(bash "$CLI" sql --nosuch 'SELECT 1' 2>&1)"
has "the twin treats a leading comment as SQL" 'if ($a -like "-- *" -or $a -match' "$_ps"

echo "R5-8. every dispatched command is in a help document, hidden or not:"
_dispatch="$(sed -n '/^case "${1:-help}" in$/,/^esac$/p' "$CLI" | grep -o '^    [a-z0-9|-]*)' | tr -d ' )' | tr '|' '\n' | grep -v '^$' | grep -v '^-' | sort -u)"
_documented="$(python3 -c 'import json; d=json.load(open("'"$ROOT"'/setup/help/exakit.json")); print("\n".join(sorted(c["command"] for c in d["commands"])))')"
check "no dispatched command is missing from setup/help/exakit.json" "" \
    "$(comm -23 <(printf '%s\n' "$_dispatch") <(printf '%s\n' "$_documented") | grep -v '^\*$' | tr '\n' ' ' | sed 's/ $//')"
check "preflight has a page now" "yes" \
    "$(bash "$CLI" preflight --help >/dev/null 2>&1 && echo yes || echo no)"
has "...and it is on the help screen" "preflight" "$(bash "$CLI" help 2>&1)"
check "the kit2 commands are hidden, not absent" "True True" \
    "$(python3 -c 'import json; d=json.load(open("'"$ROOT"'/setup/help/exakit.json")); print(" ".join(str([c for c in d["commands"] if c["command"]==n][0].get("hidden")) for n in ("upgrade-kit2","rollback-kit2")))')"
# NOT ADVERTISED IS NOT THE SAME AS ABSENT. This used to assert that
# catalog --json did not contain the string at all, which is what the code did
# - and it contradicted AGENTS.md, which describes catalog --json as "every
# supported command (a handful of internal upgrade paths are marked hidden and
# are not for you to call)". Deleting them meant no row carried a hidden key,
# and three dispatchable commands were missing outright; skills-install among
# them, which `exakit skills --json` hands a machine as its own "next". An
# agent holding both documents had to conclude one of them was lying.
#
# So the intent is kept and the assertion moved to where it belongs: the
# SCREENS must not advertise these, and the machine surface must disclose them
# with the flag AGENTS.md says is there.
_ca_json="$(bash "$CLI" catalog --json 2>/dev/null)"
check "catalog --json discloses them, marked hidden" "True True" \
    "$(printf '%s' "$_ca_json" | python3 -c 'import json,sys
d = json.load(sys.stdin)
by = {r["invocation"]: r for r in d["commands"]}
print(" ".join(str(bool(by.get("exakit " + n, {}).get("hidden"))) for n in ("upgrade-kit2", "rollback-kit2")))' 2>/dev/null)"
lacks "...and the help overview does not advertise them" "upgrade-kit2" "$(bash "$CLI" help 2>/dev/null)"
lacks "...nor does --all"                               "upgrade-kit2" "$(bash "$CLI" help --all 2>/dev/null)"

echo "R5-9. AGENTS.md matches what the code actually does:"
_agents="$(cat "$ROOT/AGENTS.md")"
has "the contract block puts the CLI on PATH before it uses a bare exakit" \
    'export PATH="$HOME/.local/bin:$PATH"' "$_agents"
lacks "...and no longer polls by absolute path two lines above a bare call" \
    '~/.local/bin/exakit status --json' "$_agents"
has "the block backgrounds the install with nohup, as the Install section demands" \
    "nohup sh -c 'curl -fsSL" "$_agents"
has "refusals are documented on stderr, where reject() and die() write them" \
    "goes to **stderr**" "$_agents"
has "...with sql's stdout remedy kept as the exception" \
    '**`exakit sql` names its remedy first, on stdout**' "$_agents"
has "the one-shape claim is scoped to the state queries" \
    "The five state queries are" "$_agents"
has "...and says one shape covers exactly those" "one shape covers all of them" "$_agents"
has "...and the content commands' own shapes are named" \
    '`logs --json` is `{"count", "targets"}`' "$_agents"
has "the status vocabulary is written down" "\`no database\` (the kit is installed" "$_agents"
for _v in EXAKIT_NO_FANCY EXAKIT_HELP_PLAIN EXAKIT_CONFIRM_RUNTIME_REPAIR \
          EXAKIT_MCP_READONLY_SCHEMAS EXAKIT_ALLOW_UNVERIFIED_EXAPUMP \
          EXAKIT_ALLOW_UNVERIFIED_JSON_TABLES EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE; do
    has "AGENTS.md documents $_v" "$_v" "$_agents"
done
has "...and warns off the checksum bypass in an unattended run" \
    "Never set one in an unattended run" "$_agents"
lacks "the usage text no longer calls info --json the manifest verbatim" \
    "install record (manifest.json) verbatim" "$(cat "$CLI")"
lacks "...nor does the twin" "install record (manifest.json) verbatim" "$_ps"
lacks "...nor the help document" "verbatim" "$(cat "$ROOT/setup/help/exakit.json")"

echo "R5-10. the marketplace surfaces mirror across the twins:"
has "the twin's version --json uses the closed status vocabulary" \
    '$rowStatus = "available"; $rowRemedy = "exakit marketplace' "$_ps"
lacks "...and no longer puts a command in the status field" \
    'status          = $r.R' "$_ps"
has "the twin marks add-on rows too" 'addon           = ($addonIds -contains $r.C)' "$_ps"
has "...from the registry, not a hand-written set" 'Get-ExakitMarketplaceAddons | ForEach-Object { $_.Id }' "$_ps"
has "the twin's status --json carries the service urls" 'urls            = $serviceUrls' "$_ps"
has "...resolved through a registry hook, not a hardcoded id" 'function Get-ExakitServiceUrl' "$_ps"
has "dash-server registers its UrlFn" 'UrlFn       = "Get-DashServerUrl"' "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
has "...and defines it" "function Get-DashServerUrl" "$(cat "$ROOT/setup/lib/dash-server.ps1")"
has "the shell side still carries urls" '"urls": umap' "$(cat "$CLI")"
_dashskill="$(cat "$ROOT/skills/dash-server/SKILL.md")"
has "the dash-server skill points at the JSON that carries the URL" \
    'exakit status --json    # .urls["dash-server"]' "$_dashskill"
lacks "...and no longer at a command that does not print the port" \
    "exakit info        # dash-server's recorded port" "$_dashskill"

printf '\npassed: %d, failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
