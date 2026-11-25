#!/usr/bin/env bash
# mcp-sidecar.sh — the kit's MCP server as the launcher's sidecar (Exasol
# Personal 2.4.0+), against a stub launcher.
#
#   bash tests/mcp-sidecar.sh
#
# What it pins:
#   - mcp_sidecar_supported needs the kit's Personal deployment and a launcher
#     with both `sidecar` and `mcp`;
#   - the definition written is the kit's (pinned image, --no-auth on loopback)
#     connected as the read-only user, never the deployment's SYS, and the JSON
#     handed to the editor holds a file reference, not the password;
#   - a serving sidecar is recorded (backend, url, bridge, version from the
#     image tag), `exasol start` reconciles only when something changed;
#   - it is the only MCP server, so what does not serve is HEALED: a port another
#     program took moves the server, a deployment that needs one restart gets
#     it, a container that did not start is recreated once, a read-only user
#     that is missing is set up again; what cannot be healed (an older
#     launcher, a server that still does not start) is an error with its fix,
#     and the record stays (validated=false) for the doctor to try again.
# The YAML editor is replaced by a recorder: tests/test_sidecar_definition.py
# covers the editor itself. No network, no real launcher, no real deployment.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s = %s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kh"; mkdir -p "$EXAKIT_HOME/credentials"
export EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/deployment"; mkdir -p "$EXAKIT_PERSONAL_DEPLOY_DIR"
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"

. "$ROOT/setup/lib/common.sh" 2>/dev/null || { echo "FAIL could not source common.sh"; exit 1; }
. "$ROOT/setup/lib/detect.sh"
. "$ROOT/setup/lib/runtime-personal.sh"
. "$ROOT/setup/lib/mcp.sh"

printf 'readonly-secret\n' > "$EXAKIT_HOME/credentials/mcp_readonly_password"
_fresh_manifest() {
    cat > "$EXAKIT_HOME/manifest.json" <<JSON
{"manifest_version": 1, "runtime": {"type": "${1:-personal}", "dsn": "127.0.0.1:8563", "user": "sys"},
 "components": {"mcp_server": {"connection": {"user": "mcp_readonly",
   "password_file": "$EXAKIT_HOME/credentials/mcp_readonly_password", "validated": true}}}}
JSON
}

# The stub launcher: its --help names the subcommands STUB_HELP lists, `mcp
# status --json` answers STUB_STATUS, and every call is recorded.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/exasol" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_CALLS"
case "$1 ${2:-}" in
    "--help ") for c in $STUB_HELP; do printf '  %s   the %s command\n' "$c" "$c"; done ;;
    "mcp status") if [ -f "$STUB_STATUS_FILE" ]; then cat "$STUB_STATUS_FILE"; else printf '%s\n' "$STUB_STATUS"; fi ;;
    # A start (or a stop and start) can change what the status says next.
    "start "*) [ -f "$STUB_STATUS_FILE.after-start" ] && mv "$STUB_STATUS_FILE.after-start" "$STUB_STATUS_FILE"; exit 0 ;;
    "sidecar disable") exit 0 ;;
    # Only a stop (the restart) changes it for a deployment that needs one.
    "stop ") [ -f "$STUB_STATUS_FILE.after-restart" ] && mv "$STUB_STATUS_FILE.after-restart" "$STUB_STATUS_FILE"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/exasol"
personal_cli() { printf '%s\n' "$WORK/bin/exasol"; }
personal_stop() { "$WORK/bin/exasol" stop; }
personal_start() { "$WORK/bin/exasol" start; }
export STUB_CALLS="$WORK/calls" STUB_STATUS_FILE="$WORK/status"
# The ports taken on this "machine" - never the real one, where a kit's own
# sidecar may well be listening on 4896.
STUB_PORTS_TAKEN=""
port_in_use() { case " $STUB_PORTS_TAKEN " in *" $1 "*) return 0 ;; esac; return 1; }
# The editor, recorded: what it was handed, and "changed" the first time.
cat > "$WORK/bin/uv" <<'UV'
#!/bin/sh
# uv run --no-project --quiet --with PyYAML==x python <editor> put <file> <name> <json>
while [ "$1" != "python" ]; do shift; done; shift
printf '%s\n' "$*" >> "$STUB_CALLS"
[ "$2" = put ] && cp "$5" "$STUB_DEF"
if [ -f "$STUB_DEF.seen" ]; then echo unchanged; else : > "$STUB_DEF.seen"; echo changed; fi
UV
chmod +x "$WORK/bin/uv"
# The uvx beside the kit's uv, as a real install has it: the bridge's absolute command comes from there, never from
# whatever uvx this machine happens to have on PATH (a CI runner has none).
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/uvx"; chmod +x "$WORK/bin/uvx"
exakit_ensure_uv() { EXAKIT_UV_BIN="$WORK/bin/uv"; }
export STUB_DEF="$WORK/definition.json"
export EXAKIT_MCP_SIDECAR_WAIT=0       # one look at the status, no waiting
export EXAKIT_MCP_BRIDGE_PREFETCH=0    # never run a real uvx here

SERVING='{"name": "mcp", "enabled": true, "running": true, "health": "serving", "restartRequired": false,
  "endpoints": [{"ip": "127.0.0.1", "port": 4896, "url": "http://127.0.0.1:4896/mcp"}]}'

echo "mcp_sidecar_supported:"
_fresh_manifest
export STUB_HELP="install start stop sidecar mcp" STUB_STATUS="$SERVING"
check "a 2.4.0 launcher and the kit's deployment" 0 "$(mcp_sidecar_supported; echo $?)"
STUB_HELP="install start stop" check "a launcher without sidecars (before 2.4.0)" 1 "$(STUB_HELP='install start stop' mcp_sidecar_supported; echo $?)"
_fresh_manifest docker
check "a database the launcher does not run" 1 "$(mcp_sidecar_supported; echo $?)"

echo "mcp_sidecar_apply, the launcher's server serving:"
_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF" "$STUB_DEF.seen"
check "applies" 0 "$(mcp_sidecar_apply; echo $?)"
check "backend recorded" "sidecar" "$(manifest_get components.mcp_server.backend)"
check "url recorded" "http://127.0.0.1:4896/mcp" "$(manifest_get components.mcp_server.url)"
check "bridge recorded from versions.json" "$(exakit_versions_value components.mcp.bridge)" "$(manifest_get components.mcp_server.bridge)"
check "version from the image tag" "$(exakit_versions_value components.mcp.version)" "$(manifest_get components.mcp_server.version)"
check "the uv the bridge runs through is recorded" "$WORK/bin/uv" "$(manifest_get components.mcp_server.uv_path)"
has "...and an absolute uvx for Claude Desktop" "/" "$(manifest_get components.mcp_server.command)"
def="$(cat "$STUB_DEF")"
has "the read-only user, not SYS" '{"name": "EXA_USER", "value": "mcp_readonly"}' "$def"
lacks "...never the deployment's saved username" '"key": "username"' "$def"
has "the password is a file reference" "\"valueFile\": \"$EXAKIT_HOME/credentials/mcp_readonly_password\"" "$def"
lacks "...and never the password itself" "readonly-secret" "$def"
has "the image is pinned by digest" "$(exakit_versions_value components.mcp.sidecar_image)" "$def"
has "loopback only" '"hostIP": "127.0.0.1"' "$def"
has "write tools off" '\"enable_write_query\": false' "$def"
# RPM-01: the SQL-preprocessor tools are off. Semantic SQL is a module of the
# framework in every session, so nothing needs to repoint the server's
# session preprocessor, and nothing may. The Windows twin says the same.
has "the SQL-preprocessor tools are off" '\"enable_preprocessor_tools\": false' "$def"
lacks "...never on" '\"enable_preprocessor_tools\": true' "$def"
has "...and so in the Windows definition" 'enable_preprocessor_tools = $false' \
    "$(awk '/^function Get-McpSidecarDefinitionJson/,/^}/' "$ROOT/setup/lib/mcp.ps1")"
lacks "the definition handed to the editor is gone" "exakit-mcp-sidecar" "$(ls "$TMPDIR")"
calls="$(cat "$STUB_CALLS")"
has "written into the deployment's sidecars.yaml" "put $EXAKIT_PERSONAL_DEPLOY_DIR/sidecars.yaml mcp" "$calls"
check "a changed definition is reconciled by exasol start" 1 "$(grep -c '^start' "$STUB_CALLS")"
lacks "the catalog template is never enabled (it would run as SYS)" "sidecar enable" "$calls"
lacks "no password on any command line" "readonly-secret" "$calls"
: > "$STUB_CALLS"
mcp_sidecar_apply >/dev/null 2>&1
check "unchanged and serving: no restart of anything" 0 "$(grep -c '^start' "$STUB_CALLS")"

echo "mcp_sidecar_apply heals what does not serve:"
_status() { printf '{"name": "mcp", "health": "%s", "restartRequired": %s, "endpoints": [%s]%s}\n' "$1" "$2" "$3" "${4:-}"; }
SERVING_AT() { _status serving false "{\"ip\": \"127.0.0.1\", \"port\": $1, \"url\": \"http://127.0.0.1:$1/mcp\"}"; }
_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF.seen" "$STUB_STATUS_FILE"*
_status starting false "" > "$STUB_STATUS_FILE"; SERVING_AT 4897 > "$STUB_STATUS_FILE.after-start"
STUB_PORTS_TAKEN="4896"
out="$(mcp_sidecar_apply 2>&1)"; rc=$?
check "port 4896 taken by another program: still served" 0 "$rc"
has "...said as a self-heal" "Self-heal: port 4896 is in use by another program - the MCP server moves to 4897" "$out"
has "...the definition listens on the new port" '"hostPort": 4897' "$(cat "$STUB_DEF")"
check "...recorded" "4897|http://127.0.0.1:4897/mcp" "$(manifest_get components.mcp_server.port)|$(manifest_get components.mcp_server.url)"
STUB_PORTS_TAKEN=""
: > "$STUB_CALLS"
mcp_sidecar_apply >/dev/null 2>&1
check "...and the recorded port is kept on the next run" '"hostPort": 4897' "$(grep -o '"hostPort": [0-9]*' "$STUB_DEF")"

# Q5: another deployment of the user's has 4896 SAVED for its MCP server. It
# is stopped (nothing listens), but it binds 4896 when it starts.
_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF.seen" "$STUB_STATUS_FILE"*
mkdir -p "$WORK/their-dev"
printf 'mcp:\n  container:\n    ports:\n    - containerPort: 4896\n      hostPort: 4896\n      name: mcp\n' > "$WORK/their-dev/sidecars.yaml"
_status starting false "" > "$STUB_STATUS_FILE"; SERVING_AT 4897 > "$STUB_STATUS_FILE.after-start"
out="$(mcp_sidecar_apply 2>&1)"; rc=$?
check "Q5: 4896 saved by another deployment, nothing listening: still served" 0 "$rc"
has "...said as a self-heal" "Self-heal: port 4896 is saved by another Exasol Personal deployment - the MCP server moves to 4897" "$out"
check "...on 4897, recorded for the clients" "4897|http://127.0.0.1:4897/mcp" "$(manifest_get components.mcp_server.port)|$(manifest_get components.mcp_server.url)"
STUB_PORTS_TAKEN="4897"
check "Q5: the next free port skips one in use too" "4898" "$(_mcp_sidecar_free_port 4896)"
STUB_PORTS_TAKEN=""
printf 'mcp:\n  container:\n    ports:\n    - hostPort: 4897\n' > "$WORK/their-dev/sidecars.yaml"
check "Q5: a saved 4897 is skipped" "4898" "$(_mcp_sidecar_free_port 4896)"
rm -rf "$WORK/their-dev"

_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF.seen" "$STUB_STATUS_FILE"*
_status starting true "" > "$STUB_STATUS_FILE"; SERVING_AT 4896 > "$STUB_STATUS_FILE.after-restart"
out="$(mcp_sidecar_apply 2>&1)"; rc=$?
check "a deployment that needs one restart: restarted, then served" 0 "$rc"
has "...said as a self-heal, the data kept" "Self-heal: this deployment serves the MCP server only after one restart - restarting the database (your data is kept)" "$out"
check "...one stop" 1 "$(grep -c '^stop' "$STUB_CALLS")"
check "...recorded and validated" "sidecar|true" "$(manifest_get components.mcp_server.backend)|$(manifest_get components.mcp_server.validated)"
_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF.seen" "$STUB_STATUS_FILE"*
_status starting true "" > "$STUB_STATUS_FILE"
out="$(mcp_sidecar_apply 2>&1)"; rc=$?
check "...a deployment that still asks after the restart: an error" 1 "$rc"
has "...with its fix" "Fix: exakit stop && exakit start" "$out"
check "...restarted once only" 1 "$(grep -c '^stop' "$STUB_CALLS")"

_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF.seen" "$STUB_STATUS_FILE"*
_status failing false "" > "$STUB_STATUS_FILE"
out="$(mcp_sidecar_apply 2>&1)"; rc=$?
check "a container that never serves: an error after one recreate" 1 "$rc"
has "...said as a self-heal first" "Self-heal: the MCP server did not start - recreating it" "$out"
check "...one recreate (disable, then start again)" 1 "$(grep -c "^sidecar disable mcp --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR\$" "$STUB_CALLS")"
has "...the error names the status" "did not start (status: failing)" "$out"
has "...and the fix" "Fix: exakit mcp-doctor" "$out"
check "...the record stays for the doctor, not validated" "sidecar|false" \
    "$(manifest_get components.mcp_server.backend 2>/dev/null)|$(manifest_get components.mcp_server.validated)"
_fresh_manifest; manifest_set components.mcp_server.backend sidecar; : > "$STUB_CALLS"; rm -f "$STUB_STATUS_FILE"*
_status failing false "" ', "message": "image pull failed: no network"' > "$STUB_STATUS_FILE"
check "...the launcher's own words are quoted" "image pull failed: no network" \
    "$(mcp_sidecar_apply 2>&1 | grep -o 'image pull failed: no network' | head -1)"
_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_STATUS_FILE"*
_status failing false "" > "$STUB_STATUS_FILE"; SERVING_AT 4896 > "$STUB_STATUS_FILE.after-start"
check "a container the recreate brings up: served" 0 "$(mcp_sidecar_apply >/dev/null 2>&1; echo $?)"

rm -f "$STUB_STATUS_FILE"*; STUB_STATUS="$SERVING"
_fresh_manifest; manifest_set components.mcp_server.backend sidecar
# The kit's own launcher: its update is the fix. A launcher the user installed
# is not the kit's to update, and the fix says so.
out="$(exakit_component_is_managed(){ return 0; }; STUB_HELP='install start stop' mcp_sidecar_apply 2>&1)"; rc=$?
check "an older launcher: an error, nothing else to fall back to" 1 "$rc"
has "...naming the fix" "Fix: exakit update personal" "$out"
out="$(exakit_component_is_managed(){ return 1; }; STUB_HELP='install start stop' mcp_sidecar_apply 2>&1)"
has "...a launcher the user installed: the user updates it" "Fix: update your launcher to Exasol Personal 2.4.0 or later, then run exakit mcp-setup" "$out"
check "...the record stays" "sidecar" "$(manifest_get components.mcp_server.backend 2>/dev/null)"
_fresh_manifest; manifest_set components.mcp_server.connection.password_file "$WORK/gone"
exakit_configure_mcp_readonly_access() { manifest_set components.mcp_server.connection.password_file "$EXAKIT_HOME/credentials/mcp_readonly_password"; }
out="$(mcp_sidecar_apply 2>&1)"; rc=$?
check "a read-only user that is not ready: set up again, then served" 0 "$rc"
has "...said as a self-heal" "Self-heal: the read-only MCP user is not ready" "$out"

echo "updating the launcher's MCP server: the image is the version:"
IMAGE_VERSION="$(exakit_versions_pin components.mcp.sidecar_image | sed 's/@.*//; s/.*://')"
check "the image comes from this kit copy" "$(exakit_versions_pin components.mcp.sidecar_image)" "$(mcp_sidecar_image)"
check "...and its version is the image tag" "$IMAGE_VERSION" "$(mcp_sidecar_image_version)"
# A fetched document naming another image changes nothing: a digest read from
# the mutable main branch would be that branch vouching for itself (SEC-13).
sed 's#mcp-server:[0-9][^@"]*@sha256:[0-9a-f]*#mcp-server:9.9.9@sha256:'"$(printf 'f%.0s' $(seq 64))"'#' \
    "$ROOT/versions.json" > "$WORK/fetched.json"
check "a fetched versions.json cannot swap the image" "$IMAGE_VERSION" "$(_EXAKIT_VERSIONS_DOC="$WORK/fetched.json" mcp_sidecar_image_version)"
_fresh_manifest; manifest_set components.mcp_server.backend sidecar
exakit_component_latest() { printf '9.9.9\n'; }
check "offered on a sidecar: the image's version, not PyPI's newest" "$IMAGE_VERSION" \
    "$(EXAKIT_VERSION_POLICY=latest exakit_component_available mcp)"
_fresh_manifest
check "...also before the server first served (it is the only one)" "$IMAGE_VERSION" \
    "$(EXAKIT_VERSION_POLICY=latest exakit_component_available mcp)"
echo "a 0.2.5 move whose sidecar does not start: the next update finishes it (UGR-02):"
# 0.2.5's record: the image's version (2.4.0 then, the same number) and no
# backend, the clients on its stdio server. The failure records backend=sidecar
# (the clients' address); read as current from then on, mcp_update never moved
# the clients. Twin of the same block in tests/mcp-sidecar-ps.ps1.
eval "_ugr_orig_$(declare -f mcp_refresh_clients)"
mcp_refresh_clients() { printf 'clients-refreshed\n' >> "$STUB_CALLS"; return "${STUB_REFRESH_RC:-0}"; }
_fresh_manifest; manifest_set components.mcp_server.version "$IMAGE_VERSION"
: > "$STUB_CALLS"; rm -f "$STUB_DEF.seen" "$STUB_STATUS_FILE"*; _status failing false "" > "$STUB_STATUS_FILE"
check "the move's sidecar does not start: the update fails" 1 "$(mcp_update >/dev/null 2>&1; echo $?)"
check "...the sidecar address is recorded" "sidecar" "$(manifest_get components.mcp_server.backend)"
check "...no client touched" 0 "$(grep -c '^clients-refreshed$' "$STUB_CALLS")"
check "...and the MCP server does not read as current" "" "$(exakit_component_current mcp 2>/dev/null)"
rm -f "$STUB_STATUS_FILE"*; STUB_STATUS="$SERVING"; : > "$STUB_CALLS"
check "the next update moves them" 0 "$(mcp_update >/dev/null 2>&1; echo $?)"
check "...the clients are moved, once" 1 "$(grep -c '^clients-refreshed$' "$STUB_CALLS")"
check "...now current" "$IMAGE_VERSION" "$(exakit_component_current mcp 2>/dev/null)"
check "...the pending move is cleared" "" "$(manifest_get components.mcp_server.clients_move 2>/dev/null)"
_fresh_manifest; manifest_set components.mcp_server.version "$IMAGE_VERSION"; : > "$STUB_CALLS"
STUB_REFRESH_RC=1 mcp_update >/dev/null 2>&1
check "a client refresh that fails: the move stays pending" "pending" "$(manifest_get components.mcp_server.clients_move 2>/dev/null)"
check "...and the MCP server does not read as current" "" "$(exakit_component_current mcp 2>/dev/null)"
eval "$(declare -f _ugr_orig_mcp_refresh_clients | sed '1s/^_ugr_orig_//')"

exakit_component_current() { manifest_get components.mcp_server.version 2>/dev/null; }
_fresh_manifest; manifest_set components.mcp_server.backend sidecar; manifest_set components.mcp_server.version 2.3.0
: > "$STUB_CALLS"; rm -f "$STUB_DEF.seen"; STUB_STATUS="$SERVING"
check "a version with no pinned image is refused" 1 "$(EXAKIT_MCP_VERSION=9.9.9 mcp_update >/dev/null 2>&1; echo $?)"
check "...nothing reconciled" 0 "$(grep -c '^start' "$STUB_CALLS")"
check "...and nothing recorded as updated" "" "$(manifest_get desired.mcp 2>/dev/null)"
check "...the record keeps what runs" "2.3.0" "$(manifest_get components.mcp_server.version)"
check "the pinned image's version updates" 0 "$(mcp_update >/dev/null 2>&1; echo $?)"
check "...reconciled by exasol start" 1 "$(grep -c '^start' "$STUB_CALLS")"
check "...recorded as the image's version" "$IMAGE_VERSION" "$(manifest_get components.mcp_server.version)"
check "...and as the desired one" "$IMAGE_VERSION" "$(manifest_get desired.mcp)"
check "run again: already current, nothing offered" 0 "$(mcp_update >/dev/null 2>&1; echo $?)"
check "...and nothing reconciled again" 1 "$(grep -c '^start' "$STUB_CALLS")"

echo "a serving sidecar retires the install's MCP record:"
# The install step failed and booked "the MCP server did not finish"; a later
# `exakit mcp-setup` got the server serving, and `exakit status` still showed
# the step as unfinished and its note as the last failure. Twin of the same
# block in tests/mcp-sidecar-ps.ps1.
_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF.seen" "$STUB_STATUS_FILE"*
STUB_PORTS_TAKEN=""; STUB_STATUS="$SERVING"
NOTE="$(exakit_failure_note_file)"
( exakit_record_soft_failure mcp "exakit update" "the server did not start" "the MCP server" )
printf 'the MCP server did not finish - the server did not start\n2026-11-13 14:34:12\n' > "$NOTE"
check "...booked" "the server did not start" "$(manifest_get install.soft_failures.mcp.reason)"
check "the sidecar applies" 0 "$(mcp_sidecar_apply >/dev/null 2>&1; echo $?)"
check "...the record is gone" "" "$(manifest_get install.soft_failures.mcp 2>/dev/null)"
check "...and so is its failure note" absent "$([ -f "$NOTE" ] && echo present || echo absent)"
( exakit_record_soft_failure skills "exakit skills-install" "no network" "AI skills" )
( exakit_record_soft_failure mcp "exakit update" "the server did not start" "the MCP server" )
printf 'AI skills did not finish - no network\n2026-11-13 14:34:12\n' > "$NOTE"
check "a note about another step" 0 "$(mcp_sidecar_apply >/dev/null 2>&1; echo $?)"
check "...stays" present "$([ -f "$NOTE" ] && echo present || echo absent)"
check "...and so does that step's record" "no network" "$(manifest_get install.soft_failures.skills.reason)"
rm -f "$NOTE"
has "exakit mcp-setup retires the client step's record when it finishes" "exakit_clear_soft_failure mcp_clients" \
    "$(awk '/^exakit_mcp_setup\(\)/,/^}/' "$ROOT/setup/lib/common.sh")"
has "...and so does its Windows twin" 'Clear-ExakitSoftFailure -Component "mcp_clients"' \
    "$(awk '/^function Invoke-McpSetup \{/,/^}/' "$ROOT/setup/lib/mcp.ps1")"

echo "mcp_sidecar_refresh: a kit update gives a running server this kit's definition:"
# PRE-01. `exakit update mcp` skips a current image, so a definition change in
# a kit release (the preprocessor tools switched on) never reached a sidecar an
# earlier kit had written. The whole-kit update now rewrites it, and
# reconciles the sidecar only when it changed.
_fresh_manifest; manifest_set components.mcp_server.backend sidecar; manifest_set components.mcp_server.port 4896
: > "$STUB_CALLS"; rm -f "$STUB_DEF" "$STUB_DEF.seen" "$STUB_STATUS_FILE"*
export STUB_STATUS="$SERVING"
personal_deployment_running() { return 0; }
out="$(mcp_sidecar_refresh 2>&1)"; rc=$?
check "a changed definition: refreshed" 0 "$rc"
has "...written into sidecars.yaml" "put $EXAKIT_PERSONAL_DEPLOY_DIR/sidecars.yaml mcp" "$(cat "$STUB_CALLS")"
has "...with the preprocessor tools off" '\"enable_preprocessor_tools\": false' "$(cat "$STUB_DEF")"
check "...and exasol start reconciles the sidecar, once" 1 "$(grep -c '^start' "$STUB_CALLS")"
has "...said once" "now runs with this kit's settings" "$out"
: > "$STUB_CALLS"
out="$(mcp_sidecar_refresh 2>&1)"; rc=$?
check "an unchanged definition: nothing to do" "0 0" "$rc $(grep -c '^start' "$STUB_CALLS")"
lacks "...and nothing said" "now runs with" "$out"
rm -f "$STUB_DEF.seen"; : > "$STUB_CALLS"
personal_deployment_running() { return 1; }
check "a stopped database: the definition is written, nothing started" "0 0" \
    "$(mcp_sidecar_refresh >/dev/null 2>&1; echo "$? $(grep -c '^start' "$STUB_CALLS")")"
: > "$STUB_CALLS"; rm -f "$STUB_DEF.seen"
manifest_set components.mcp_server.backend stdio
check "a kit whose MCP server is not the sidecar: untouched" "0 0" \
    "$(mcp_sidecar_refresh >/dev/null 2>&1; echo "$? $(wc -l < "$STUB_CALLS" | tr -d ' ')")"
has "exakit update runs it for a whole-kit update" "mcp_sidecar_refresh ||" \
    "$(awk '/^_exakit_update_run\(\)/,/^}/' "$ROOT/setup/lib/common.sh")"
has "...and so does the Windows update" "Update-McpSidecarDefinition" \
    "$(awk '/^function Invoke-ExakitUpdateRun/,/^}/' "$ROOT/setup/exakit.ps1")"

echo "mcp_sidecar_restart: a running server signs in again (U5):"
# Its pooled session keeps the SQL preprocessor slot it logged in with, so the
# kit restarts it once after the framework takes the slot. The restart is the
# recreate the apply heals with: switched off, written again, reconciled.
_fresh_manifest; manifest_set components.mcp_server.backend sidecar
printf '%s\n' "$SERVING" > "$STUB_STATUS_FILE"; : > "$STUB_CALLS"; rm -f "$STUB_DEF" "$STUB_DEF.seen"
out="$(mcp_sidecar_restart 2>&1)"; rc=$?
check "a running server is restarted" 0 "$rc"
check "...switched off, written again, then reconciled - in that order" "mcp status --json --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR|sidecar disable mcp --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR|put|start --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR|mcp status --json --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR" \
    "$(sed 's/^.*sidecar_definition.py put.*/put/' "$STUB_CALLS" | tr '\n' '|' | sed 's/|$//')"
has "...said in one line" "The MCP server was restarted to pick up the SQL Preprocessor. If an AI chat is open, reconnect it" "$out"
check "...as the read-only user still" '{"name": "EXA_USER", "value": "mcp_readonly"}' \
    "$(grep -o '{"name": "EXA_USER", "value": "[^"]*"}' "$STUB_DEF")"
lacks "...and the database is not restarted" "stop" "$(cat "$STUB_CALLS")"
printf '%s\n' '{"name": "mcp", "enabled": true, "running": false, "health": "stopped"}' > "$STUB_STATUS_FILE"; : > "$STUB_CALLS"
out="$(mcp_sidecar_restart 2>&1)"; rc=$?
check "a server that is not running: nothing restarted" "0 mcp status --json --deployment-dir $EXAKIT_PERSONAL_DEPLOY_DIR" "$rc $(tr '\n' ' ' < "$STUB_CALLS" | sed 's/ $//')"
lacks "...and nothing said" "restarted" "$out"
manifest_set components.mcp_server.backend stdio; printf '%s\n' "$SERVING" > "$STUB_STATUS_FILE"; : > "$STUB_CALLS"
check "a kit whose MCP server is not the sidecar: untouched" "0 0" \
    "$(mcp_sidecar_restart >/dev/null 2>&1; echo "$? $(wc -l < "$STUB_CALLS" | tr -d ' ')")"
manifest_set components.mcp_server.backend sidecar; : > "$STUB_CALLS"
printf '%s\n' '{"name": "mcp", "running": false, "health": "starting"}' > "$STUB_STATUS_FILE.after-start"
printf '%s\n' "$SERVING" > "$STUB_STATUS_FILE"
out="$(mcp_sidecar_restart 2>&1)"; rc=$?
check "a server that does not come back: failure" 1 "$rc"
has "...with the fix" "did not come back after its restart. Fix: exakit mcp-doctor" "$out"
check "...and the record says it is not validated" false "$(manifest_get components.mcp_server.validated)"
rm -f "$STUB_STATUS_FILE.after-start"

echo "mcp-doctor --json over a 0.2.5 record: a real answer, and nothing written:"
# The record 0.2.5 wrote (clients on the kit's own stdio uvx server, no
# backend). The real runtime answers it with nothing on stdout and the reason on
# stderr, so --json printed "produced no result" with remedy "exakit logs
# setup" - and set the read-only user up again first (ALTER USER, the GRANTs)
# although --json only reports. Twin of the same block in
# tests/mcp-sidecar-ps.ps1.
printf 'admin-secret\n' > "$EXAKIT_HOME/credentials/runtime_sys_password"
cat > "$EXAKIT_HOME/manifest.json" <<JSON
{"manifest_version": 1, "runtime": {"type": "personal", "dsn": "127.0.0.1:8563", "user": "sys",
   "password_file": "$EXAKIT_HOME/credentials/runtime_sys_password", "tls": "self-signed"},
 "components": {"mcp_server": {"package": "exasol-mcp-server", "version": "2.4.0", "mode": "stdio",
   "command": "$HOME/.local/bin/uvx", "validated": true, "connection": {"user": "mcp_readonly",
   "password_file": "$EXAKIT_HOME/credentials/mcp_readonly_password", "validated": true}}}}
JSON
exakit_configure_mcp_readonly_access() { printf 'readonly-setup\n' >> "$STUB_CALLS"; return 0; }
eval "$(declare -f _exakit_reassert_mcp_readonly_posture | sed '1s/^_exakit_reassert_mcp_readonly_posture/_real_reassert_posture/')"
_exakit_reassert_mcp_readonly_posture() { return 0; }
_doctor_json_field() { run_python -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1]))' "$1"; }
: > "$STUB_CALLS"
doc="$(EXAKIT_MCP_RESULT_JSON=1 exakit_mcp_operation doctor claude_code 2>/dev/null)"; rc=$?
check "a pre-sidecar record: blocked" blocked "$(printf '%s' "$doc" | _doctor_json_field status)"
check "...the remedy moves the clients" "exakit update" "$(printf '%s' "$doc" | _doctor_json_field remedy)"
check "...installed, as every state answer says" True "$(printf '%s' "$doc" | _doctor_json_field installed)"
check "...and the doctor fails" 1 "$rc"
lacks "--json did not set the read-only user up again" "readonly-setup" "$(cat "$STUB_CALLS")"
manifest_set components.mcp_server.backend sidecar; : > "$STUB_CALLS"
doc="$(EXAKIT_MCP_RESULT_JSON=1 exakit_mcp_operation doctor claude_code 2>/dev/null)"
check "a sidecar that produced no result keeps the generic answer" "exakit logs setup" "$(printf '%s' "$doc" | _doctor_json_field remedy)"
: > "$STUB_CALLS"
( exakit_run_mcp_operation_cli doctor claude_code "$WORK/doctor-out" ) >/dev/null 2>&1
has "a plain doctor (it repairs) still sets the read-only user up" "readonly-setup" "$(cat "$STUB_CALLS")"

echo "mcp-doctor --json carries mcp_privileges, the read-only user's own list:"
# AGENTS.md promises it on every platform; only the PowerShell twin emitted it.
# The list is read as the MCP user from SYS.EXA_USER_SYS_PRIVS (CSV, as
# exapump prints by default). Twin of the same block in tests/mcp-sidecar-ps.ps1.
_exakit_reassert_mcp_readonly_posture() { _real_reassert_posture "$@"; }
_exakit_assert_mcp_readonly_posture() { [ "${STUB_POSTURE_OK:-1}" = 1 ]; }
cat > "$WORK/bin/exapump" <<'EXAPUMP'
#!/bin/sh
sql="$(cat)"
case "$sql" in
    *EXA_USER_SYS_PRIVS*) printf 'PRIVILEGE\r\nCREATE SESSION\r\nSELECT ANY TABLE\r\nUSE ANY SCHEMA\r\n' ;;
    *) printf 'STATUS\nOK\n' ;;
esac
EXAPUMP
chmod +x "$WORK/bin/exapump"
cat > "$EXAKIT_HOME/manifest.json" <<JSON
{"manifest_version": 1, "runtime": {"type": "personal", "dsn": "127.0.0.1:8563", "user": "sys",
   "password_file": "$EXAKIT_HOME/credentials/runtime_sys_password", "tls": "self-signed"},
 "components": {"exapump": {"path": "$WORK/bin/exapump"},
   "mcp_server": {"backend": "sidecar", "connection": {"user": "mcp_readonly",
   "password_file": "$EXAKIT_HOME/credentials/mcp_readonly_password", "schemas": ["STARTER_KIT"], "validated": true}}}}
JSON
exakit_run_mcp_operation_cli() { printf '%s\n' '{"operation": "doctor", "status": "success", "findings": []}' > "$3"; }
_doctor_json_list() { run_python -c 'import json,sys; print(",".join(json.loads(sys.stdin.read()).get(sys.argv[1]) or []))' "$1"; }
doc="$(EXAKIT_MCP_RESULT_JSON=1 exakit_mcp_operation doctor claude_code 2>/dev/null)"; rc=$?
check "doctor --json: mcp_privileges" "CREATE SESSION,SELECT ANY TABLE,USE ANY SCHEMA" "$(printf '%s' "$doc" | _doctor_json_list mcp_privileges)"
check "...the doctor's own fields untouched" success "$(printf '%s' "$doc" | _doctor_json_field status)"
check "...and it passes" 0 "$rc"
doc="$(EXAKIT_MCP_RESULT_JSON=1 exakit_mcp_operation status claude_code 2>/dev/null)"
check "status --json does not re-check, so carries no list" None "$(printf '%s' "$doc" | _doctor_json_field mcp_privileges)"
STUB_POSTURE_OK=0
doc="$(EXAKIT_MCP_RESULT_JSON=1 exakit_mcp_operation doctor claude_code 2>/dev/null)"; rc=$?
check "a drifted posture: no list claimed" None "$(printf '%s' "$doc" | _doctor_json_field mcp_privileges)"
check "...and the doctor fails" 1 "$rc"
STUB_POSTURE_OK=1
out="$(_exakit_reassert_mcp_readonly_posture 2>&1)"
has "plain doctor names the list" "mcp_readonly holds exactly: CREATE SESSION, SELECT ANY TABLE, USE ANY SCHEMA" "$out"

echo "the Windows definition writer (setup/lib/mcp.ps1), read as text:"
# Windows PowerShell 5.1's `Set-Content -Encoding UTF8` writes a BOM that the
# editor's json.loads refused; pwsh 7 does not, so only a 5.1 run shows it. The
# writer must use a BOM-less encoder, and the editor's stderr must be captured
# rather than left to 5.1's 'Stop' (which threw away all but its first line).
_PS_WRITER="$(awk '/^function Write-McpSidecarDefinition/,/^}/' "$ROOT/setup/lib/mcp.ps1" | grep -v '^[[:space:]]*#')"
lacks "no Set-Content for the definition" "Set-Content" "$_PS_WRITER"
has "...a BOM-less UTF-8 encoder" 'UTF8Encoding($false)' "$_PS_WRITER"
lacks "...and the editor's stderr is not discarded" '2>$null' "$_PS_WRITER"

echo "the user's own MCP sidecar on a deployment the kit adopted (OWN-04):"
# The editor as it answers a sidecar of that name it was told to keep.
cat > "$WORK/bin/uv-foreign" <<'UV'
#!/bin/sh
while [ "$1" != "python" ]; do shift; done; shift
printf '%s\n' "$*" >> "$STUB_CALLS"
case " $* " in *" --keep-foreign "*) echo foreign; exit 3 ;; esac
echo changed
UV
chmod +x "$WORK/bin/uv-foreign"
_fresh_manifest
manifest_set runtime.deployment_dir "$EXAKIT_PERSONAL_DEPLOY_DIR"
manifest_set runtime.ownership user
manifest_set runtime.ownership_path "$EXAKIT_PERSONAL_DEPLOY_DIR"
: > "$STUB_CALLS"
out="$( exakit_ensure_uv() { EXAKIT_UV_BIN="$WORK/bin/uv-foreign"; }; mcp_sidecar_apply 2>&1; echo "RC $?")"
has "the kit asks the editor to keep a sidecar of that name" "--keep-foreign" "$(grep ' put ' "$STUB_CALLS")"
has "...which is the user's: the kit says so" "already has an MCP server of its own" "$out"
has "...and sets up nothing" "RC 1" "$out"
lacks "...no start reconciles it" "start --deployment-dir" "$(cat "$STUB_CALLS")"
check "...nothing recorded as the kit's sidecar" "|" "$(manifest_get components.mcp_server.backend)|$(manifest_get components.mcp_server.sidecar_dir)"
# On the kit's own deployment the definition is the kit's to write.
: > "$STUB_CALLS"
( exakit_component_ownership() { printf kit; }; exakit_ensure_uv() { EXAKIT_UV_BIN="$WORK/bin/uv-foreign"; }
  _mcp_sidecar_put mcp_readonly "$EXAKIT_HOME/credentials/mcp_readonly_password" 4896 >/dev/null 2>&1 )
lacks "the kit's own deployment: written without --keep-foreign" "--keep-foreign" "$(grep ' put ' "$STUB_CALLS")"
# The uninstall removes only the sidecar the kit wrote.
manifest_del components.mcp_server.sidecar_dir
manifest_set components.mcp_server.backend sidecar
: > "$STUB_CALLS"
mcp_sidecar_remove
lacks "uninstall: the user's own MCP sidecar stays" "sidecar disable" "$(cat "$STUB_CALLS")"
manifest_set components.mcp_server.backend sidecar
manifest_set components.mcp_server.sidecar_dir "$EXAKIT_PERSONAL_DEPLOY_DIR"
: > "$STUB_CALLS"
mcp_sidecar_remove
has "uninstall: one the kit wrote in that folder goes" "sidecar disable mcp" "$(cat "$STUB_CALLS")"
check "...and its record with it" "" "$(manifest_get components.mcp_server.sidecar_dir)"

echo ""
echo "mcp-sidecar.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
