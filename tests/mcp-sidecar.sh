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
check "...one recreate (disable, then start again)" 1 "$(grep -c '^sidecar disable mcp$' "$STUB_CALLS")"
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
out="$(STUB_HELP='install start stop' mcp_sidecar_apply 2>&1)"; rc=$?
check "an older launcher: an error, nothing else to fall back to" 1 "$rc"
has "...naming the fix" "Fix: exakit update personal" "$out"
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

echo ""
echo "mcp-sidecar.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
