#!/usr/bin/env bash
# mcp-sidecar.sh — the kit's MCP server as the launcher's sidecar (Exasol
# Personal 2.4.0+), against a stub launcher.
#
#   bash tests/mcp-sidecar.sh
#
# What it pins:
#   - mcp_sidecar_supported needs the kit's Personal deployment and a launcher
#     with both `sidecar` and `mcp`; EXAKIT_MCP_BACKEND=uvx turns it off;
#   - the definition written is the kit's (pinned image, --no-auth on loopback)
#     connected as the read-only user, never the deployment's SYS, and the JSON
#     handed to the editor holds a file reference, not the password;
#   - a serving sidecar is recorded (backend, url, bridge, version from the
#     image tag), `exasol start` reconciles only when something changed;
#   - a deployment that needs a restart first, an older launcher, or a sidecar
#     that never serves leaves no record, so the clients keep the stdio server.
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
    "mcp status") printf '%s\n' "$STUB_STATUS" ;;
    "start "*|"sidecar disable") exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/exasol"
personal_cli() { printf '%s\n' "$WORK/bin/exasol"; }
export STUB_CALLS="$WORK/calls"
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
exakit_ensure_uv() { EXAKIT_UV_BIN="$WORK/bin/uv"; }
export STUB_DEF="$WORK/definition.json"
export EXAKIT_MCP_SIDECAR_WAIT=0       # one look at the status, no waiting

SERVING='{"name": "mcp", "enabled": true, "running": true, "health": "serving", "restartRequired": false,
  "endpoints": [{"ip": "127.0.0.1", "port": 4896, "url": "http://127.0.0.1:4896/mcp"}]}'

echo "mcp_sidecar_supported:"
_fresh_manifest
export STUB_HELP="install start stop sidecar mcp" STUB_STATUS="$SERVING"
check "a 2.4.0 launcher and the kit's deployment" 0 "$(mcp_sidecar_supported; echo $?)"
STUB_HELP="install start stop" check "a launcher without sidecars (before 2.4.0)" 1 "$(STUB_HELP='install start stop' mcp_sidecar_supported; echo $?)"
check "EXAKIT_MCP_BACKEND=uvx keeps the kit's own server" 1 "$(EXAKIT_MCP_BACKEND=uvx mcp_sidecar_supported; echo $?)"
_fresh_manifest docker
check "a database the launcher does not run" 1 "$(mcp_sidecar_supported; echo $?)"

echo "mcp_sidecar_apply, the launcher's server serving:"
_fresh_manifest; : > "$STUB_CALLS"; rm -f "$STUB_DEF" "$STUB_DEF.seen"
check "applies" 0 "$(mcp_sidecar_apply; echo $?)"
check "backend recorded" "sidecar" "$(manifest_get components.mcp_server.backend)"
check "url recorded" "http://127.0.0.1:4896/mcp" "$(manifest_get components.mcp_server.url)"
check "bridge recorded from versions.json" "$(exakit_versions_value components.mcp.bridge)" "$(manifest_get components.mcp_server.bridge)"
check "version from the image tag" "$(exakit_versions_value components.mcp.version)" "$(manifest_get components.mcp_server.version)"
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

echo "mcp_sidecar_apply, falling back to the kit's stdio server:"
_fresh_manifest; rm -f "$STUB_DEF.seen"
STUB_STATUS='{"name": "mcp", "health": "starting", "restartRequired": true, "endpoints": []}'
check "a deployment that needs a restart first: not applied" 1 "$(mcp_sidecar_apply; echo $?)"
check "...nothing recorded, clients keep stdio" "" "$(manifest_get components.mcp_server.backend 2>/dev/null)"
_fresh_manifest; manifest_set components.mcp_server.backend sidecar; : > "$STUB_CALLS"
STUB_STATUS='{"name": "mcp", "health": "failing", "restartRequired": false, "endpoints": []}'
check "a sidecar that never serves: not applied" 1 "$(mcp_sidecar_apply; echo $?)"
check "...the old record is cleared" "" "$(manifest_get components.mcp_server.backend 2>/dev/null)"
has "...and the sidecar it set up is switched off" "sidecar disable mcp" "$(cat "$STUB_CALLS")"
STUB_STATUS="$SERVING"
_fresh_manifest; manifest_set components.mcp_server.backend sidecar
check "an older launcher after an earlier sidecar run: not applied" 1 "$(STUB_HELP='install start stop' mcp_sidecar_apply; echo $?)"
check "...and the record goes" "" "$(manifest_get components.mcp_server.backend 2>/dev/null)"

echo ""
echo "mcp-sidecar.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
