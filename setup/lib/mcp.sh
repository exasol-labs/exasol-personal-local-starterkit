#!/usr/bin/env bash
# mcp.sh — Exasol MCP server module (the AI agent bridge).
#
# Sourced by setup scripts after common.sh, detect.sh, a runtime module, and
# exapump.sh. The MCP server is the one the Exasol Personal launcher runs beside
# the database (a sidecar, 2.4.0+): this module writes its definition, heals it
# when it does not serve, and keeps the AI client entries pointed at it. There
# is no second server: the kit's own `uvx exasol-mcp-server` fallback is gone,
# and every case that used to fall back to it is healed here or reported with
# the command that fixes it.
#
# Guardrail layering:
#   1. server is read-only by design (the definition turns the write tools off)
#   2. dedicated read-only database user, provisioned and posture-checked by
#      exakit_configure_mcp_readonly_access in common.sh
#   3. permanent client setup (handled by the Python mcp package) points at
#      the server's loopback URL, never at the admin user

# Legacy fallback used only when older manifest state does not yet contain the
# validated connection block. Keep it aligned with the provisioned read-only
# database user name.
EXAKIT_MCP_USER="${EXAKIT_MCP_USER:-mcp_readonly}"

# mcp_command_path — the uvx the AI clients are told to launch.
#
# The uv the kit vetted comes FIRST, ahead of the manifest record: the record
# is whatever a previous run wrote, and after a uv below the floor was shadowed
# by the kit's own copy, a record that still names the old uvx would put the
# refused binary straight back into every client config. The record and the
# PATH lookups remain as fallbacks for a kit copy that cannot resolve uv at
# all (a read-only query on a machine with none).
mcp_command_path() {
    if command -v exakit_uv_uvx >/dev/null 2>&1; then
        _vetted_uvx="$(exakit_uv_uvx 2>/dev/null || true)"
        if [ -n "$_vetted_uvx" ]; then
            printf '%s\n' "$_vetted_uvx"
            return 0
        fi
    fi
    _manifest_command="$(manifest_get components.mcp_server.command 2>/dev/null || true)"
    if [ -n "$_manifest_command" ]; then
        printf '%s\n' "$_manifest_command"
        return 0
    fi
    if command -v uvx >/dev/null 2>&1; then
        command -v uvx
        return 0
    fi
    if [ -x "$HOME/.local/bin/uvx" ]; then
        printf '%s\n' "$HOME/.local/bin/uvx"
        return 0
    fi
    printf '%s\n' "uvx"
}

# mcp_uv_install — the MCP step's uv. One resolver for the whole kit
# (exakit_ensure_uv in common.sh): a uv already on the machine is used only at
# or above components.uv.min_version; otherwise the pinned release archive is
# downloaded, verified against its digest in versions.json and unpacked - no
# installer script is executed, from astral or anyone else. Homebrew is no
# longer asked: it was preferred only to stay off the pipe-to-shell path, and
# that path no longer exists.
mcp_uv_install() {
    if exakit_ensure_uv; then
        # A dependency that was already there is not an outcome of this step,
        # and its path is not something to act on. Logged, not printed.
        _exakit_log_file "OK    uv $(exakit_uv_version_of "$EXAKIT_UV_BIN" 2>/dev/null || printf '?') ready: $EXAKIT_UV_BIN"
        exakit_uv_record_manifest
        push_rollback "\"$EXAKIT_UV_BIN\" cache clean >/dev/null 2>&1 || true"
        return 0
    fi
    die "uv could not be installed, and the MCP server's definition and the Claude Desktop bridge run through uv. What happened: exakit logs setup. Then re-run the installer, or: exakit update uv"
}

# mcp_point_clients_at_kit_uv — after uv moved (exakit update uv), make the AI
# clients that go through the bridge (Claude Desktop's mcp-proxy) launch the
# uvx the kit vetted. The record is rewritten first because the config renderer
# reads it; then every already-connected client is refreshed. Clients the user
# never connected are left alone, as always.
mcp_point_clients_at_kit_uv() {
    _pck_uvx="$(exakit_uv_uvx 2>/dev/null || true)"
    [ -n "$_pck_uvx" ] || return 1
    [ -f "${EXAKIT_MANIFEST:-}" ] || return 0
    [ "$(manifest_get components.mcp_server.backend 2>/dev/null || true)" = sidecar ] || return 0
    manifest_set components.mcp_server.command "$_pck_uvx"
    manifest_set components.mcp_server.uv_path "$EXAKIT_UV_BIN"
    mcp_refresh_clients
}

# mcp_update — put the MCP server image this kit copy pins beside the database.
# The image is the version (exakit_component_available offers its tag), so an
# update is: write the definition with the new image and let `exasol start`
# recreate that one container. A kit from before the sidecar left its clients on
# the stdio server; they are moved to the URL here, once.
mcp_update() {
    _latest="$(exakit_component_available mcp)"
    [ -n "$_latest" ] || die "Could not resolve the MCP server version this kit pins."
    _mcp_recorded="$(manifest_get components.mcp_server.version 2>/dev/null || true)"
    _mu_backend="$(manifest_get components.mcp_server.backend 2>/dev/null || true)"
    if [ "$_latest" = "$_mcp_recorded" ] && [ "$_mu_backend" = sidecar ]; then
        ok "MCP server is already current ($_mcp_recorded)"
        return 0
    fi
    # The image is the version: writing the one this kit copy pins and calling
    # that "$_latest" was an update that never happened, offered again on the
    # next run. Only an explicit EXAKIT_MCP_VERSION can ask for a version with
    # no pinned image (what is offered is the image's own).
    _mu_image_version="$(mcp_sidecar_image_version)"
    if [ "$_mu_image_version" != "$_latest" ]; then
        warn "This kit pins no launcher image of MCP server $_latest (it pins $_mu_image_version), so the MCP server beside your database stays at ${_mcp_recorded:-$_mu_image_version}. A kit update brings newer images: exakit update"
        return 1
    fi
    info "Updating MCP server ${_mcp_recorded:-unknown} -> $_latest"
    mcp_sidecar_apply || return 1
    manifest_set desired.mcp "$_latest"
    if [ "$_mu_backend" != sidecar ]; then
        # Clients written by a kit from before still launch the stdio server.
        mcp_refresh_clients || true
    fi
    ok "MCP server updated; database data was not changed"
}

# mcp_managed_clients — the client ids that already carry a managed MCP entry, as
# a comma-separated list. Empty when nothing is connected, the module is missing,
# or Python is unavailable; callers treat that as "nothing to refresh".
mcp_managed_clients() {
    command -v exakit_run_mcp_operation_cli >/dev/null 2>&1 || return 0
    exakit_can_run_python || return 0
    _mmc_result="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-managed.XXXXXX")"
    if ! exakit_run_mcp_operation_cli status \
            "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" \
            "$_mmc_result" >/dev/null 2>&1; then
        rm -f "$_mmc_result"
        return 0
    fi
    _mmc_clients="$(run_python - "$_mmc_result" 2>/dev/null <<'PY'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
seen = []
for artifact in doc.get("artifacts", []) or []:
    client = artifact.get("client")
    if client and client not in seen:
        seen.append(client)
print(",".join(seen))
PY
    )"
    rm -f "$_mmc_result"
    printf '%s\n' "$_mmc_clients"
}

# mcp_refresh_clients — re-render the managed entry in the clients that are
# already connected, so they say what the record now says (the server's URL, the
# bridge's uvx). This is the configure operation (what `exakit mcp-setup` runs):
# configure re-renders unconditionally, and mid-update the guarantee wanted is
# "the entry now says what we just recorded", not the outcome of a comparison.
#
# Scoped to already-managed clients on purpose: configure would happily create a
# config for a client the user never chose to connect.
mcp_refresh_clients() {
    if ! command -v exakit_run_mcp_setup_cli >/dev/null 2>&1; then
        warn "Run exakit mcp-setup to refresh the AI client configs."
        return 1
    fi
    _refresh_clients="$(mcp_managed_clients)"
    if [ -z "$_refresh_clients" ]; then
        info "No AI client is connected yet — connect one any time with: exakit mcp-setup"
        return 0
    fi
    _refresh_result="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-refresh.XXXXXX")"
    if ! exakit_run_mcp_setup_cli "$_refresh_clients" "$_refresh_result"; then
        rm -f "$_refresh_result"
        warn "Could not refresh the AI client configs — run exakit mcp-setup to finish."
        return 1
    fi
    if [ -s "$_refresh_result" ]; then
        exakit_print_mcp_setup_summary "$_refresh_result"
    fi
    rm -f "$_refresh_result"
    ok "AI client configs point at the MCP server beside your database"
}

# The fallback keeps this module usable on its own: the exakit CLI sources
# common.sh, a bare `. mcp.sh` does not, and there is no table in that case
# anyway.
_exakit_mcp_addon_say() {
    if command -v _exakit_addon_note >/dev/null 2>&1; then
        _exakit_addon_note "$1" "$2"
        return 0
    fi
    case "$1" in
        warn) warn "$2" ;;
        *)    info "$2" ;;
    esac
}

# mcp_register_addon_servers <label> - put an installed add-on's MCP endpoint
# into the clients that are already connected.
#
# Scoped to already-managed clients for the same reason mcp_refresh_clients
# is: configure would happily create a config for a client the user never chose
# to connect. Nothing here is fatal - an add-on that installed correctly is
# installed, whether or not an AI client is wired to it yet, and the endpoint is
# one `exakit mcp-setup` away in any case.
mcp_register_addon_servers() {
    _mras_label="${1:-the add-on}"
    command -v exakit_run_mcp_addon_cli >/dev/null 2>&1 || return 0
    exakit_can_run_python || return 0
    _mras_clients="$(mcp_managed_clients)"
    if [ -z "$_mras_clients" ]; then
        info "No AI client is connected yet - connect one any time with: exakit mcp-setup"
        return 0
    fi
    _mras_result="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-addon.XXXXXX")"
    if ! exakit_run_mcp_addon_cli "$_mras_clients" "$_mras_result"; then
        rm -f "$_mras_result"
        _exakit_mcp_addon_say warn "Could not register the $_mras_label MCP endpoint with your AI clients - run: exakit mcp-setup"
        return 1
    fi
    _mras_configured="$(run_python - "$_mras_result" 2>/dev/null <<'PY'
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(0)
dash = doc.get("dash_server") or {}
print(",".join(dash.get("configured_clients") or []))
PY
    )"
    rm -f "$_mras_result"
    if [ -n "$_mras_configured" ]; then
        # Nothing on screen. Registering the endpoint is part of installing the
        # add-on, not a step of its own, and the row in the marketplace table
        # already says the add-on installed. A separate line for a sub-step of a
        # row that has just reported success is one fact twice -- and it was
        # arriving under a live table, where any line at all strands the frame.
        # The logfile keeps the record, which is where the account of what an
        # install touched belongs.
        _exakit_log_file "OK    $_mras_label MCP endpoint registered with: $_mras_configured"
        return 0
    fi
    # Every connected client was skipped: a client that cannot express a
    # remote MCP server (Claude Desktop; Codex gained HTTP support in
    # mcp/adapters/codex.py) is the usual reason, and that is a fact about
    # the client, not a failure of this install.
    _exakit_mcp_addon_say info "No connected AI client can take a remote MCP endpoint - drive $_mras_label with: exakit help dash-server"
    return 0
}

# mcp_unregister_server_entry <server> <label> - the mirror image, for an add-on
# being removed: drop just that one entry, so the exasol server (and any other
# add-on) stays where it is.
mcp_unregister_server_entry() {
    _muse_server="$1"
    _muse_label="${2:-$1}"
    command -v exakit_run_mcp_server_removal_cli >/dev/null 2>&1 || return 0
    exakit_can_run_python || return 0
    _muse_clients="$(mcp_managed_clients)"
    [ -n "$_muse_clients" ] || return 0
    _muse_result="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-unregister.XXXXXX")"
    if ! exakit_run_mcp_server_removal_cli "$_muse_server" "$_muse_clients" "$_muse_result"; then
        rm -f "$_muse_result"
        warn "The $_muse_label MCP entry may still be in your AI client configs - check with: exakit mcp-status"
        return 1
    fi
    rm -f "$_muse_result"
    return 0
}

# mcp_credentials — prints "user<TAB>password_file" for the client configs.
# Prefers the validated dedicated read-only user; falls back to the legacy
# MCP default or, as a last resort, the runtime admin user.
# A THIRD FIELD: which credential this is. The fallback below hands back the
# ADMIN account, and it used to do so indistinguishably from the read-only one
# - so every caller took it at face value and the status line went on printing
# "(read-only)" about a full-privilege session. That inverts the kit's central
# safety claim ("writes are rejected by the database itself") in the one
# direction that matters: it degrades OPEN, and the single line a user would
# check to catch it reassured them instead.
#
# Reaching it needs a manifest that lost those keys - a partially restored kit
# home, a hand edit, a crossing from an older layout - not a clean install. So
# the fallback stays (it is what lets a half-provisioned kit still be
# repaired); what changes is that it can no longer pass itself off as the
# read-only user. Consumers read fields 1 and 2 with `cut`, so appending a
# third is compatible with every existing caller.
mcp_credentials() {
    _connection_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _connection_pwfile="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    if [ -n "$_connection_user" ] && [ -n "$_connection_pwfile" ]; then
        printf '%s\t%s\t%s\n' "$_connection_user" "$_connection_pwfile" "readonly"
        return 0
    fi
    if [ -n "$(manifest_get components.mcp_server.user 2>/dev/null || true)" ]; then
        printf '%s\t%s\t%s\n' "$EXAKIT_MCP_USER" "$EXAKIT_CREDS_DIR/mcp_readonly_password" "readonly"
        return 0
    fi
    _exakit_log_file "WARN  No read-only MCP credential is recorded; falling back to the ADMIN account. Repair with: exakit mcp-setup"
    printf '%s\t%s\t%s\n' "$(manifest_get runtime.user 2>/dev/null)" \
        "$(manifest_get runtime.password_file 2>/dev/null)" "admin-fallback"
}

# --- the launcher's MCP server (Exasol Personal 2.4.0+) ---------------------
# From 2.4.0 the launcher runs the official Exasol MCP server as a sidecar next
# to the database, on 127.0.0.1:4896 over Streamable HTTP. It is the server
# behind every `exasol` client entry, with one change the launcher leaves to its
# user: the launcher connects it as SYS ("these controls limit the exposed MCP
# tools; they do not change the database privileges of the saved user"), the
# kit connects it as its read-only MCP user. It is the only MCP server: when it
# does not serve, mcp_sidecar_apply heals what it can (the read-only user, a
# port another program took, the one restart an older deployment needs, a
# container that did not start) and names the fix for the rest.
#
# The definition is the kit's, written whole BEFORE anything starts it: the
# launcher's `exasol sidecar enable mcp` starts its catalog template at once on
# a running deployment, which would serve the database as SYS, without auth,
# until an edit landed. Written instead into <deployment>/sidecars.yaml (0600,
# the launcher's file; the password is read from the kit's credential file by
# the editor, never put on a command line) and applied by `exasol start`, which
# reconciles a running deployment without restarting the database.

EXAKIT_MCP_SIDECAR="${EXAKIT_MCP_SIDECAR:-mcp}"
EXAKIT_MCP_SIDECAR_PORT="${EXAKIT_MCP_SIDECAR_PORT:-4896}"
EXAKIT_SIDECAR_PYYAML="${EXAKIT_SIDECAR_PYYAML:-PyYAML==6.0.3}"
EXAKIT_MCP_SIDECAR_IMAGE_FALLBACK="docker.io/exasol/mcp-server:2.4.0@sha256:ae13d5430dff463aa0817f5a188211820fb8c2565e95e477d5ca71b04bb50b68"
EXAKIT_MCP_BRIDGE_FALLBACK="mcp-proxy@0.13.0"

# mcp_sidecar_image — the launcher's MCP server image, by digest, from THIS KIT
# COPY's versions.json (SEC-13): a digest read from the fetched main branch
# would be the mutable branch vouching for itself, so a newer image arrives with
# the kit update that reviewed it. mcp_sidecar_image_version is its tag, the
# version that image IS - what an update of a sidecar install can offer and
# record. Twins: Get-McpSidecarImage / Get-McpSidecarImageVersion.
mcp_sidecar_image() {
    _msi_image="$(exakit_versions_pin components.mcp.sidecar_image 2>/dev/null || true)"
    case "$_msi_image" in *@sha256:*) : ;; *) _msi_image="$EXAKIT_MCP_SIDECAR_IMAGE_FALLBACK" ;; esac
    printf '%s\n' "$_msi_image"
}
mcp_sidecar_image_version() {
    _msiv="$(mcp_sidecar_image)"
    _msiv="${_msiv%%@*}"
    printf '%s\n' "${_msiv##*:}"
}

# mcp_sidecar_supported — the launcher can run the kit's MCP server here: the
# kit's Exasol Personal deployment, and a launcher that has both `sidecar` and
# `mcp` (2.4.0+).
mcp_sidecar_supported() {
    [ "$(manifest_get runtime.type 2>/dev/null || true)" = personal ] || return 1
    command -v personal_cli >/dev/null 2>&1 || return 1
    [ -d "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || return 1
    _mss_help="$(exakit_run_bounded "${EXAKIT_PERSONAL_PROBE_TIMEOUT:-20}" "$(personal_cli)" --help 2>&1)" || return 1
    printf '%s\n' "$_mss_help" | personal_help_names_token sidecar || return 1
    printf '%s\n' "$_mss_help" | personal_help_names_token mcp
}

# mcp_sidecar_remove — switch the kit's MCP sidecar off and drop its record: for
# uninstalling the MCP component, never as a way out of a failure.
mcp_sidecar_remove() {
    if [ "$(manifest_get components.mcp_server.backend 2>/dev/null || true)" = sidecar ] && \
       command -v personal_cli >/dev/null 2>&1; then
        run_logged "$(personal_cli)" sidecar disable "$EXAKIT_MCP_SIDECAR" >/dev/null 2>&1 || true
    fi
    manifest_del components.mcp_server.backend 2>/dev/null || true
    manifest_del components.mcp_server.url 2>/dev/null || true
    manifest_del components.mcp_server.bridge 2>/dev/null || true
    manifest_del components.mcp_server.port 2>/dev/null || true
    return 0
}

# _mcp_sidecar_field <json> <health|restartRequired|url|detail> — one answer out
# of `exasol mcp status --json` (an object, or a one-item array). `detail` is
# the launcher's own words for a sidecar that does not serve (its message,
# error or reason), cut to 200 characters, for the error line.
_mcp_sidecar_field() {
    printf '%s' "$1" | run_python_any -c 'import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if isinstance(doc, list):
    doc = doc[0] if doc else {}
if sys.argv[1] == "detail":
    for key in ("message", "error", "reason", "lastError", "status"):
        value = doc.get(key)
        if isinstance(value, str) and value.strip():
            print(" ".join(value.split())[:200])
            break
elif sys.argv[1] == "url":
    for endpoint in doc.get("endpoints") or []:
        if isinstance(endpoint, dict) and endpoint.get("url"):
            print(endpoint["url"])
            break
else:
    value = doc.get(sys.argv[1])
    print(("true" if value else "false") if isinstance(value, bool) else (value or ""))' "$2" 2>/dev/null
}

# _mcp_sidecar_definition <user> <password file> [port] — the mcp sidecar as JSON on
# stdout: the launcher's own catalog entry (image pinned in versions.json,
# --no-auth on loopback, origin protection, the read-oriented tool set) with
# the kit's read-only user in place of the deployment's SYS. The password is a
# file reference the editor resolves; it is never in this text.
_mcp_sidecar_definition() {
    _msd_image="$(mcp_sidecar_image)"
    run_python_any - "$_msd_image" "${3:-$EXAKIT_MCP_SIDECAR_PORT}" "$1" "$2" <<'PY'
import json, sys
image, port, user, password_file = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
def ref(key):
    return {"secretKeyRef": {"name": "exasol-database", "key": key}}
settings = {"default_row_limit": 1000, "enable_read_query": True, "enable_summarize_table": True,
            "enable_query_profiling": True, "enable_preprocessor_tools": False, "enable_write_query": False,
            "enable_read_bucketfs": False, "enable_write_bucketfs": False, "views": {"enable": True}}
print(json.dumps({
    "enabled": True,
    "container": {
        "image": image,
        "imagePullPolicy": "IfNotPresent",
        "restartPolicy": "Always",
        "args": ["--host", "0.0.0.0", "--port", "4896", "--no-auth"],
        "env": [
            {"name": "EXASOL_DB_HOST", "valueFrom": ref("host")},
            {"name": "EXASOL_DB_PORT", "valueFrom": ref("port")},
            {"name": "EXA_DSN", "value": "$(EXASOL_DB_HOST):$(EXASOL_DB_PORT)"},
            {"name": "EXA_USER", "value": user},
            {"name": "EXA_PASSWORD", "valueFile": password_file},
            {"name": "EXA_SSL_CERT_VALIDATION", "value": "false"},
            {"name": "FASTMCP_HTTP_HOST_ORIGIN_PROTECTION", "value": "true"},
            {"name": "EXA_MCP_SETTINGS", "value": json.dumps(settings)},
            {"name": "EXASOL_TELEMETRY_DISABLE", "value": "1"},
        ],
        "ports": [{"name": "mcp", "containerPort": 4896, "hostPort": port, "hostIP": "127.0.0.1"}],
        "readinessProbe": {"httpGet": {"path": "/health", "port": "mcp"}, "periodSeconds": 10, "failureThreshold": 6},
    },
    "endpoints": [{"port": "mcp", "scheme": "http", "path": "/mcp"}],
}))
PY
}

# _mcp_sidecar_put <user> <password file> <port> — write the definition into
# the deployment's sidecars.yaml; prints "changed" or "unchanged".
_mcp_sidecar_put() {
    _msp_root="$(exakit_repo_root)" || return 1
    _msp_def="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-sidecar.XXXXXX")" || return 1
    exakit_track_tmp "$_msp_def"
    if ! _mcp_sidecar_definition "$1" "$2" "$3" > "$_msp_def"; then
        rm -f "$_msp_def"
        return 1
    fi
    "$EXAKIT_UV_BIN" run --no-project --quiet --with "$EXAKIT_SIDECAR_PYYAML" python \
        "$_msp_root/setup/lib/sidecar_definition.py" put \
        "$EXAKIT_PERSONAL_DEPLOY_DIR/sidecars.yaml" "$EXAKIT_MCP_SIDECAR" "$_msp_def" \
        2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    _msp_rc=$?
    rm -f "$_msp_def"
    return $_msp_rc
}

# _mcp_sidecar_wait <cli> — poll `exasol mcp status` until the sidecar serves.
# Sets _msw_state (serving | restart | timeout) and _msw_status (the last
# status JSON) - variables, not output, so the caller keeps both. The budget is EXAKIT_MCP_SIDECAR_WAIT (the probe's own startup
# window is a minute; twice that before calling it stuck).
_mcp_sidecar_wait() {
    _msw_budget="${EXAKIT_MCP_SIDECAR_WAIT:-120}"
    _msw_waited=0
    while :; do
        _msw_status="$(exakit_run_bounded 60 "$1" mcp status --json 2>/dev/null || true)"
        if [ "$(_mcp_sidecar_field "$_msw_status" restartRequired)" = true ]; then
            _msw_state=restart; return 0
        fi
        if [ "$(_mcp_sidecar_field "$_msw_status" health)" = serving ]; then
            _msw_state=serving; return 0
        fi
        [ "$_msw_waited" -lt "$_msw_budget" ] || break
        sleep 3
        _msw_waited=$((_msw_waited + 3))
    done
    _msw_state=timeout
}

# _mcp_sidecar_unhealed <port> — what a failure leaves: the server's address
# (so the clients are pointed at it, and work the moment it serves) and
# validated=false (so the ready panel and the doctor say it does not yet).
_mcp_sidecar_unhealed() {
    manifest_set components.mcp_server.backend sidecar
    manifest_set components.mcp_server.port "$1"
    manifest_set components.mcp_server.url "http://127.0.0.1:$1/mcp"
    manifest_set components.mcp_server.validated false
}

# _mcp_sidecar_free_port <port> — the first port from <port>+1 to <port>+20
# nothing listens on; nothing printed when all of them are taken.
_mcp_sidecar_free_port() {
    _msfp="$1"
    _msfp_last=$(( $1 + 20 ))
    while [ "$_msfp" -lt "$_msfp_last" ]; do
        _msfp=$(( _msfp + 1 ))
        port_in_use "$_msfp" || { printf '%s\n' "$_msfp"; return 0; }
    done
    return 1
}

# mcp_sidecar_apply — make the launcher's MCP server the one behind every
# client entry, connected as the kit's read-only user: write its definition,
# reconcile, wait until it serves, and record it (components.mcp_server
# backend=sidecar, url, port, version, bridge) for the client configs.
#
# It HEALS what it can, each said in one info line: a read-only user that is not
# ready is set up again; a port another program took moves the server to the
# next free one; a deployment from an older launcher that serves sidecars only
# after one restart is restarted (the data stays); a container that did not
# start is recreated once. What it cannot heal - a launcher without sidecars,
# no free port, a server that still does not start - is an error naming the
# fix. A failure records the server's address with validated=false (the clients
# are pointed at it, and the next `exakit mcp-doctor` tries again). 0 when it
# serves.
# ⇄ twin: Set-McpSidecar in mcp.ps1.
mcp_sidecar_apply() {
    if ! mcp_sidecar_supported; then
        error "The Exasol Personal launcher here has no MCP sidecar (it predates 2.4.0)."
        info "Fix: exakit update personal"
        return 1
    fi
    _msa_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _msa_pw="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    if [ -z "$_msa_user" ] || [ ! -f "$_msa_pw" ]; then
        info "Self-heal: the read-only MCP user is not ready - setting it up again"
        ( exakit_configure_mcp_readonly_access ) >/dev/null 2>&1 || true
        _msa_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
        _msa_pw="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
        if [ -z "$_msa_user" ] || [ ! -f "$_msa_pw" ]; then
            error "The read-only MCP user could not be set up."
            info "Fix: exakit mcp-setup (exakit logs setup says what failed)"
            return 1
        fi
    fi
    if ! exakit_ensure_uv; then
        error "uv is not available, and the MCP server's definition is written with it."
        info "Fix: exakit update uv"
        return 1
    fi
    _msa_cli="$(personal_cli)"
    _msa_port="$(manifest_get components.mcp_server.port 2>/dev/null || true)"
    case "$_msa_port" in ''|*[!0-9]*) _msa_port="$EXAKIT_MCP_SIDECAR_PORT" ;; esac
    _msa_status="$(exakit_run_bounded 60 "$_msa_cli" mcp status --json 2>/dev/null || true)"
    # A port that answers while our server does not serve is someone else's.
    if [ "$(_mcp_sidecar_field "$_msa_status" health)" != serving ] && port_in_use "$_msa_port"; then
        _msa_free="$(_mcp_sidecar_free_port "$_msa_port" || true)"
        if [ -z "$_msa_free" ]; then
            error "Port $_msa_port and the 20 after it are in use, so the MCP server has nowhere to listen."
            info "Fix: free port $_msa_port, or set EXAKIT_MCP_SIDECAR_PORT to a free port and run: exakit mcp-setup"
            manifest_set components.mcp_server.validated false
            return 1
        fi
        info "Self-heal: port $_msa_port is in use by another program - the MCP server moves to $_msa_free"
        _msa_port="$_msa_free"
    fi
    _msa_changed="$(_mcp_sidecar_put "$_msa_user" "$_msa_pw" "$_msa_port")" || {
        error "The MCP server's definition could not be written into $EXAKIT_PERSONAL_DEPLOY_DIR/sidecars.yaml."
        info "Fix: exakit mcp-doctor (exakit logs setup says what failed)"
        _mcp_sidecar_unhealed "$_msa_port"
        return 1
    }
    if [ "$_msa_changed" = changed ] || [ "$(_mcp_sidecar_field "$_msa_status" health)" != serving ]; then
        # `exasol start` reconciles saved definitions even when the database is
        # already running: it recreates only what changed, the database stays up.
        run_logged "$_msa_cli" start || _exakit_log_file "WARN  MCP: exasol start reported a failure; waiting for the sidecar anyway"
    fi
    _msa_restarted=0
    _msa_recreated=0
    while :; do
        _mcp_sidecar_wait "$_msa_cli"
        _msa_status="$_msw_status"
        case "$_msw_state" in
            serving) break ;;
            restart)
                if [ "$_msa_restarted" = 1 ]; then
                    error "The deployment still asks for a restart before it serves the MCP server."
                    info "Fix: exakit stop && exakit start"
                    _mcp_sidecar_unhealed "$_msa_port"
                    return 1
                fi
                _msa_restarted=1
                # A deployment created by an older launcher serves sidecars only
                # after its next stop and start. The data is on disk; only the
                # running database goes down for the moment it takes.
                info "Self-heal: this deployment serves the MCP server only after one restart - restarting the database (your data is kept)"
                ( personal_stop ) >/dev/null 2>&1 || true
                ( personal_start ) >/dev/null 2>&1 || true
                ;;
            *)
                if [ "$_msa_recreated" = 1 ]; then
                    _msa_detail="$(_mcp_sidecar_field "$_msa_status" detail)"
                    error "The MCP server beside your database did not start (status: $(_mcp_sidecar_field "$_msa_status" health | sed 's/^$/unknown/'))${_msa_detail:+: $_msa_detail}."
                    info "Fix: exakit mcp-doctor - details: $_msa_cli mcp status"
                    _mcp_sidecar_unhealed "$_msa_port"
                    return 1
                fi
                _msa_recreated=1
                info "Self-heal: the MCP server did not start - recreating it"
                run_logged "$_msa_cli" sidecar disable "$EXAKIT_MCP_SIDECAR" >/dev/null 2>&1 || true
                _mcp_sidecar_put "$_msa_user" "$_msa_pw" "$_msa_port" >/dev/null || true
                run_logged "$_msa_cli" start >/dev/null 2>&1 || true
                ;;
        esac
    done
    _msa_url="$(_mcp_sidecar_field "$_msa_status" url)"
    case "$_msa_url" in http://127.0.0.1:*) : ;; *) _msa_url="http://127.0.0.1:$_msa_port/mcp" ;; esac
    _msa_bridge="$(exakit_versions_value components.mcp.bridge 2>/dev/null || true)"
    manifest_set components.mcp_server.backend sidecar
    manifest_set components.mcp_server.url "$_msa_url"
    manifest_set components.mcp_server.port "$_msa_port"
    # The server version is the image's tag (pinned with versions.json's
    # components.mcp.version): what `exakit version` reads.
    _msa_tag="$(mcp_sidecar_image_version)"
    case "$_msa_tag" in [0-9]*) manifest_set components.mcp_server.version "$_msa_tag" ;; esac
    manifest_set components.mcp_server.bridge "${_msa_bridge:-$EXAKIT_MCP_BRIDGE_FALLBACK}"
    # The same absolute uv/uvx for the bridge: Claude Desktop runs it, and a GUI
    # app has no ~/.local/bin on its PATH. Fetched now, so its first start is not
    # a download.
    [ -n "${EXAKIT_UV_BIN:-}" ] && manifest_set components.mcp_server.uv_path "$EXAKIT_UV_BIN"
    manifest_set components.mcp_server.command "$(mcp_command_path)"
    manifest_set components.mcp_server.validated true
    if [ "${EXAKIT_MCP_BRIDGE_PREFETCH:-1}" = 1 ]; then
        "$(mcp_command_path)" "${_msa_bridge:-$EXAKIT_MCP_BRIDGE_FALLBACK}" --help >/dev/null 2>&1 || \
            _exakit_log_file "INFO  MCP: the Claude Desktop bridge was not fetched ahead (it downloads on its first start)"
    fi
    _exakit_log_file "OK    MCP: the launcher's MCP server answers at $_msa_url as $_msa_user"
    return 0
}
