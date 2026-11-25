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
# The one rule of exakit_personal_db_state (common.sh). A caller that loaded
# this file without common.sh (a test of one function) gets a guard that lets
# everything through, as before the rule; common.sh, sourced first or later,
# defines the real one.
command -v exakit_kit_database_guard >/dev/null 2>&1 || exakit_kit_database_guard() { return 0; }
command -v exakit_personal_db_state >/dev/null 2>&1 || exakit_personal_db_state() { return 0; }

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
    # Clients a kit from before left on the stdio server are moved once the
    # server serves. The move is recorded as pending BEFORE the apply: a failed
    # apply still records backend=sidecar (the clients' address), and without
    # the mark the next update read "current" and the clients stayed on the
    # old server, with its password in their configs, for good (audit UGR-02).
    _mu_move="$(manifest_get components.mcp_server.clients_move 2>/dev/null || true)"
    if [ "$_latest" = "$_mcp_recorded" ] && [ "$_mu_backend" = sidecar ] && [ "$_mu_move" != pending ]; then
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
    if [ "$_mu_backend" != sidecar ]; then
        manifest_set components.mcp_server.clients_move pending
        _mu_move=pending
    fi
    mcp_sidecar_apply || return 1
    manifest_set desired.mcp "$_latest"
    if [ "$_mu_move" = pending ]; then
        # Clients written by a kit from before still launch the stdio server.
        # The mark goes only once they say the URL; until then the next
        # update offers the move again.
        if mcp_refresh_clients; then
            manifest_del components.mcp_server.clients_move
        fi
    fi
    # The receipt the move from 0.2.3's own server never wrote (audit LCY-04):
    # without it every later MCP update read "not the kit's" and was skipped.
    exakit_record_ownership mcp kit >/dev/null 2>&1 || true
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
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    [ -d "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ] || return 1
    _mss_help="$(exakit_run_bounded "${EXAKIT_PERSONAL_PROBE_TIMEOUT:-20}" "$(personal_cli)" --help 2>&1)" || return 1
    printf '%s\n' "$_mss_help" | personal_help_names_token sidecar || return 1
    printf '%s\n' "$_mss_help" | personal_help_names_token mcp
}

# mcp_sidecar_is_kits — 0 when the `mcp` sidecar of the deployment in use is
# the kit's to write and remove (OWN-04): the deployment is the kit's own, or
# the kit wrote the sidecar in this very folder (components.mcp_server.
# sidecar_dir, recorded by _mcp_sidecar_put, followed where the launcher moved
# it), or a kit from before that record set it up (backend "sidecar") on a
# database not known to be the user's. A deployment the kit adopted can carry
# the launcher's own MCP server, set up by its user: never replaced, never
# removed. Twin of Test-McpSidecarIsKits.
mcp_sidecar_is_kits() {
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    _msik_owner=unknown
    command -v exakit_component_ownership >/dev/null 2>&1 && _msik_owner="$(exakit_component_ownership database)"
    [ "$_msik_owner" = kit ] && return 0
    _msik="$(manifest_get components.mcp_server.sidecar_dir 2>/dev/null || true)"
    if [ -n "$_msik" ]; then
        command -v exakit_personal_deploy_dir_now >/dev/null 2>&1 && _msik="$(exakit_personal_deploy_dir_now "$_msik")"
        [ "$_msik" = "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ]
        return
    fi
    # A kit from before that record set one up as backend "sidecar": its own,
    # unless the database is known to be the user's.
    [ "$(manifest_get components.mcp_server.backend 2>/dev/null || true)" = sidecar ] && [ "$_msik_owner" != user ]
}

# mcp_sidecar_claim — the record a kit before 0.3.1 never wrote
# (components.mcp_server.sidecar_dir), written by the update once the
# database is followed by its id, when the `mcp` sidecar of the deployment in
# use is provably the kit's: the kit's MCP server is recorded (backend
# "sidecar", its read-only login and its port), AND the sidecar saved in the
# deployment's sidecars.yaml signs in with that login and publishes that
# port (sidecar_definition.py is-kits). Without it, a database the user let
# the 0.3.0 kit use (runtime.ownership user) kept the kit's MCP server
# running after `exakit uninstall`, since mcp_sidecar_is_kits could not tell
# it was the kit's. A sidecar the user set up (the launcher's own signs in
# with the deployment's user) is never claimed, and nothing is claimed when
# the proof cannot be read: no sidecars.yaml, no usable uv, a record already
# there, or a database that is not the kit's to act on. Always 0. Twin of
# the PowerShell side's claim (mcp.ps1).
# mcp_sidecar_claim offline — the same, NEVER DOWNLOADING: the uv the kit
# has and PyYAML from its cache, or nothing claimed. For a caller whose
# database is stopped (the one question's rename, before the deploy step
# starts it), so a slow or blocked network never keeps it down longer. The
# update claims after its one start instead.
mcp_sidecar_claim() {
    [ "$(manifest_get components.mcp_server.backend 2>/dev/null || true)" = sidecar ] || return 0
    [ -z "$(manifest_get components.mcp_server.sidecar_dir 2>/dev/null || true)" ] || return 0
    # The kit's own database: its sidecar is the kit's without a record.
    [ "$(exakit_component_ownership database 2>/dev/null || true)" != kit ] || return 0
    _mscl_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _mscl_port="$(manifest_get components.mcp_server.port 2>/dev/null || true)"
    [ -n "$_mscl_user" ] && [ -n "$_mscl_port" ] || return 0
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    [ -f "${EXAKIT_PERSONAL_DEPLOY_DIR:-}/sidecars.yaml" ] || return 0
    [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] || return 0
    _mscl_root="$(exakit_repo_root 2>/dev/null)" || return 0
    command -v exakit_ensure_uv >/dev/null 2>&1 || return 0
    _mscl_offline=""
    if [ "${1:-}" = offline ]; then
        # exakit_ensure_uv installs nothing for a read-only query.
        _mscl_ro_set="${EXAKIT_READONLY_QUERY+set}"; _mscl_ro="${EXAKIT_READONLY_QUERY-}"
        EXAKIT_READONLY_QUERY=1
        _mscl_uv=0
        exakit_ensure_uv >/dev/null 2>&1 || _mscl_uv=1
        if [ -n "$_mscl_ro_set" ]; then EXAKIT_READONLY_QUERY="$_mscl_ro"; else unset EXAKIT_READONLY_QUERY; fi
        [ "$_mscl_uv" = 0 ] || return 0
        _mscl_offline=--offline
    else
        exakit_ensure_uv >/dev/null 2>&1 || return 0
    fi
    "$EXAKIT_UV_BIN" run ${_mscl_offline:+"$_mscl_offline"} --no-project --quiet --with "$EXAKIT_SIDECAR_PYYAML" python \
        "$_mscl_root/setup/lib/sidecar_definition.py" is-kits \
        "$EXAKIT_PERSONAL_DEPLOY_DIR/sidecars.yaml" "$EXAKIT_MCP_SIDECAR" "$_mscl_user" "$_mscl_port" \
        >/dev/null 2>>"${EXAKIT_LOG_FILE:-/dev/null}" || return 0
    manifest_set components.mcp_server.sidecar_dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1 || true
    return 0
}

# mcp_sidecar_remove — switch the kit's MCP sidecar off and drop its record: for
# uninstalling the MCP component, never as a way out of a failure.
mcp_sidecar_remove() {
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    # Never a sidecar of a deployment that is not the kit's (exakit_personal_db_state).
    if [ "$(manifest_get components.mcp_server.backend 2>/dev/null || true)" = sidecar ] && \
       command -v personal_cli >/dev/null 2>&1 && \
       [ -z "$(exakit_personal_db_state 2>/dev/null || true)" ] && mcp_sidecar_is_kits; then
        run_logged "$(personal_cli)" sidecar disable "$EXAKIT_MCP_SIDECAR" --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1 || true
    fi
    manifest_del components.mcp_server.sidecar_dir 2>/dev/null || true
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
#
# The SQL-preprocessor tools are OFF. Semantic SQL needs no session setup: the
# SQL preprocessor framework holds the database's slot and Semantic Views is
# one of its modules for every user, so a semantic query through MCP is an
# ordinary SELECT. A tool that repoints the session's preprocessor would take
# the framework, and every add-on's module, out of the server's session.
# ⇄ twin: Get-McpSidecarDefinitionJson in mcp.ps1.
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
# the deployment's sidecars.yaml; prints "changed" or "unchanged". A sidecar
# of that name the kit did not write (mcp_sidecar_is_kits) is kept: it prints
# "foreign" and returns 3. The folder written is recorded as the kit's.
_mcp_sidecar_put() {
    _msp_root="$(exakit_repo_root)" || return 1
    _msp_def="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-sidecar.XXXXXX")" || return 1
    exakit_track_tmp "$_msp_def"
    if ! _mcp_sidecar_definition "$1" "$2" "$3" > "$_msp_def"; then
        rm -f "$_msp_def"
        return 1
    fi
    # The folder the deployment is in now: launcher 2.5.0 moves it.
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    # Only into the kit's own deployment (exakit_personal_db_state).
    exakit_kit_database_guard || { rm -f "$_msp_def"; return 1; }
    _msp_keep=""
    mcp_sidecar_is_kits || _msp_keep="--keep-foreign"
    "$EXAKIT_UV_BIN" run --no-project --quiet --with "$EXAKIT_SIDECAR_PYYAML" python \
        "$_msp_root/setup/lib/sidecar_definition.py" put \
        "$EXAKIT_PERSONAL_DEPLOY_DIR/sidecars.yaml" "$EXAKIT_MCP_SIDECAR" "$_msp_def" $_msp_keep \
        2>>"${EXAKIT_LOG_FILE:-/dev/null}"
    _msp_rc=$?
    rm -f "$_msp_def"
    [ "$_msp_rc" = 0 ] && manifest_set components.mcp_server.sidecar_dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1
    return $_msp_rc
}

# mcp_sidecar_refresh — the MCP server's definition as THIS kit copy writes
# it, for a kit that already runs the launcher's sidecar. `exakit update` runs
# it once the kit is current: a release that changes the definition (its tool
# settings, say) reaches a server set up by an earlier kit, which `exakit
# update mcp` would skip as "already current". The definition is rewritten;
# only when that changed anything, and the database is up, `exasol start`
# reconciles the sidecar (the database stays up, the URL stays). A stopped
# database takes it at its next start. Nothing for any other backend.
# ⇄ twin: Update-McpSidecarDefinition in mcp.ps1.
mcp_sidecar_refresh() {
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    [ "$(manifest_get components.mcp_server.backend 2>/dev/null || true)" = sidecar ] || return 0
    # A server the kit did not write is not the kit's to refresh (OWN-04).
    mcp_sidecar_is_kits || return 0
    _msr_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _msr_pw="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    [ -n "$_msr_user" ] && [ -f "$_msr_pw" ] || return 0
    exakit_ensure_uv || return 1
    _msr_port="$(manifest_get components.mcp_server.port 2>/dev/null || true)"
    case "$_msr_port" in ''|*[!0-9]*) _msr_port="$EXAKIT_MCP_SIDECAR_PORT" ;; esac
    _msr_changed="$(_mcp_sidecar_put "$_msr_user" "$_msr_pw" "$_msr_port")" || return 1
    [ "$_msr_changed" = changed ] || return 0
    if personal_deployment_running >/dev/null 2>&1; then
        _msr_cli="$(personal_cli)"
        run_logged "$_msr_cli" start --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || return 1
        _mcp_sidecar_wait "$_msr_cli"
        [ "$_msw_state" = serving ] || return 1
    fi
    info "The MCP server beside your database now runs with this kit's settings"
    return 0
}

# mcp_sidecar_restart — restart the kit's MCP server beside the database once,
# when it is running, so it signs in again. Its pooled database session keeps
# the SQL preprocessor slot it logged in with: ALTER SYSTEM reaches only
# sessions opened after it, so a server started before the framework took the
# slot (an `exakit update` from 0.2.x sets the server up first) answers Semantic
# SQL and JSON paths without the framework until it reconnects. The restart is
# the recreate mcp_sidecar_apply heals with - switched off, the definition
# written again, `exasol start` reconciles; the database stays up. Nothing to do
# when the launcher's sidecar is not the backend or is not running. 0 when it
# serves again (or there was nothing to restart).
# ⇄ twin: Restart-McpSidecar in mcp.ps1.
mcp_sidecar_restart() {
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    [ "$(manifest_get components.mcp_server.backend 2>/dev/null || true)" = sidecar ] || return 0
    exakit_kit_database_guard || return 1
    mcp_sidecar_is_kits || return 0
    command -v personal_cli >/dev/null 2>&1 || return 0
    _msx_cli="$(personal_cli)"
    _msx_status="$(exakit_run_bounded 60 "$_msx_cli" mcp status --json --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)"
    [ "$(_mcp_sidecar_field "$_msx_status" running)" = true ] || \
        [ "$(_mcp_sidecar_field "$_msx_status" health)" = serving ] || return 0
    _msx_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _msx_pw="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    [ -n "$_msx_user" ] && [ -f "$_msx_pw" ] || return 0
    _msx_port="$(manifest_get components.mcp_server.port 2>/dev/null || true)"
    case "$_msx_port" in ''|*[!0-9]*) _msx_port="$EXAKIT_MCP_SIDECAR_PORT" ;; esac
    if ! exakit_ensure_uv; then
        warn "The MCP server beside your database could not be restarted (uv is not available). Fix: exakit mcp-doctor"
        return 1
    fi
    run_logged "$_msx_cli" sidecar disable "$EXAKIT_MCP_SIDECAR" --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1 || true
    if ! _mcp_sidecar_put "$_msx_user" "$_msx_pw" "$_msx_port" >/dev/null; then
        warn "The MCP server beside your database could not be restarted (its definition was not written). Fix: exakit mcp-doctor"
        manifest_set components.mcp_server.validated false
        return 1
    fi
    run_logged "$_msx_cli" start --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1 || true
    _mcp_sidecar_wait "$_msx_cli"
    if [ "$_msw_state" != serving ]; then
        warn "The MCP server beside your database did not come back after its restart. Fix: exakit mcp-doctor"
        manifest_set components.mcp_server.validated false
        return 1
    fi
    info "The MCP server was restarted to pick up the SQL Preprocessor. If an AI chat is open, reconnect it"
    return 0
}

# _mcp_sidecar_wait <cli> — poll `exasol mcp status` until the sidecar serves.
# Sets _msw_state (serving | restart | timeout) and _msw_status (the last
# status JSON) - variables, not output, so the caller keeps both. The budget is EXAKIT_MCP_SIDECAR_WAIT (the probe's own startup
# window is a minute; twice that before calling it stuck).
_mcp_sidecar_wait() {
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    _msw_budget="${EXAKIT_MCP_SIDECAR_WAIT:-120}"
    _msw_waited=0
    while :; do
        _msw_status="$(exakit_run_bounded 60 "$1" mcp status --json --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)"
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

# _mcp_sidecar_saved_ports — the host ports the MCP servers of the user's
# other deployments have saved (their sidecars.yaml), " 4896 4897 " form. A
# stopped deployment binds its port when it starts, so a saved port is taken
# even when nothing listens on it now (Q5, as the database port, D3). Read as
# text: no Python.
_mcp_sidecar_saved_ports() {
    _mssp=" "
    command -v personal_saved_port_deployments >/dev/null 2>&1 || { printf '%s' "$_mssp"; return 0; }
    while IFS= read -r _mssp_dep; do
        [ -n "$_mssp_dep" ] && [ -f "$_mssp_dep/sidecars.yaml" ] || continue
        for _mssp_p in $(sed -n 's/.*"\{0,1\}hostPort"\{0,1\}[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$_mssp_dep/sidecars.yaml" 2>/dev/null); do
            _mssp="$_mssp$_mssp_p "
        done
    done <<EXAKIT_MSSP_DEPS
$(personal_saved_port_deployments)
EXAKIT_MSSP_DEPS
    printf '%s' "$_mssp"
}

# _mcp_sidecar_port_taken <port> [<saved ports>] — 0 when something listens
# on <port> now, or another deployment's MCP server has it saved.
_mcp_sidecar_port_taken() {
    case "${2:-$(_mcp_sidecar_saved_ports)}" in *" $1 "*) return 0 ;; esac
    port_in_use "$1"
}

# _mcp_sidecar_free_port <port> — the first port from <port>+1 to <port>+20
# that is neither in use nor saved by another deployment's MCP server; nothing
# printed when all of them are taken.
_mcp_sidecar_free_port() {
    _msfp="$1"
    _msfp_last=$(( $1 + 20 ))
    _msfp_saved="$(_mcp_sidecar_saved_ports)"
    while [ "$_msfp" -lt "$_msfp_last" ]; do
        _msfp=$(( _msfp + 1 ))
        _mcp_sidecar_port_taken "$_msfp" "$_msfp_saved" || { printf '%s\n' "$_msfp"; return 0; }
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
    command -v personal_deploy_dir_refresh >/dev/null 2>&1 && personal_deploy_dir_refresh
    # Beside the kit's own database only (exakit_personal_db_state).
    exakit_kit_database_guard || return 1
    if ! mcp_sidecar_supported; then
        # The true reason, of the three mcp_sidecar_supported can fail on: no
        # deployment of the kit's own, a launcher the user installed, or the
        # kit's own launcher from before 2.4.0.
        if [ ! -d "${EXAKIT_PERSONAL_DEPLOY_DIR:-}" ]; then
            error "This kit has no database deployment yet, so the MCP server has nothing to run beside."
            info "Fix: once the database is installed, run exakit mcp-setup"
        elif ! exakit_component_is_managed personal; then
            error "Your own Exasol launcher has no MCP sidecar, so the MCP server cannot run beside the database."
            info "Fix: update your launcher to Exasol Personal 2.4.0 or later, then run exakit mcp-setup"
        else
            error "The Exasol Personal launcher here has no MCP sidecar (it predates 2.4.0)."
            info "Fix: exakit update personal"
        fi
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
            if ! exakit_exapump_bin >/dev/null 2>&1; then
                error "MCP initialisation failed: the read-only database user your AI clients sign in with could not be created, because exapump is not installed (the kit creates that user with it)."
                info "Fix: exakit update exapump, then: exakit mcp-setup"
                return 1
            fi
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
    _msa_status="$(exakit_run_bounded 60 "$_msa_cli" mcp status --json --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" 2>/dev/null || true)"
    # A port that answers while our server does not serve is someone else's.
    # So is a port another deployment's MCP server has saved (Q5): it binds
    # it when that deployment starts.
    if [ "$(_mcp_sidecar_field "$_msa_status" health)" != serving ] && _mcp_sidecar_port_taken "$_msa_port"; then
        _msa_free="$(_mcp_sidecar_free_port "$_msa_port" || true)"
        if [ -z "$_msa_free" ]; then
            error "Port $_msa_port and the 20 after it are in use, so the MCP server has nowhere to listen."
            info "Fix: free port $_msa_port, or set EXAKIT_MCP_SIDECAR_PORT to a free port and run: exakit mcp-setup"
            manifest_set components.mcp_server.validated false
            return 1
        fi
        if port_in_use "$_msa_port"; then
            info "Self-heal: port $_msa_port is in use by another program - the MCP server moves to $_msa_free"
        else
            info "Self-heal: port $_msa_port is saved by another Exasol Personal deployment - the MCP server moves to $_msa_free"
        fi
        _msa_port="$_msa_free"
    fi
    _msa_changed="$(_mcp_sidecar_put "$_msa_user" "$_msa_pw" "$_msa_port")" || {
        if [ "$_msa_changed" = foreign ]; then
            # The user's own MCP server (OWN-04): kept, and nothing recorded as the kit's.
            error "This deployment already has an MCP server of its own (sidecar '$EXAKIT_MCP_SIDECAR'). The kit leaves it as it is and sets up no server beside it."
            return 1
        fi
        error "The MCP server's definition could not be written into $EXAKIT_PERSONAL_DEPLOY_DIR/sidecars.yaml."
        info "Fix: exakit mcp-doctor (exakit logs setup says what failed)"
        _mcp_sidecar_unhealed "$_msa_port"
        return 1
    }
    if [ "$_msa_changed" = changed ] || [ "$(_mcp_sidecar_field "$_msa_status" health)" != serving ]; then
        # `exasol start` reconciles saved definitions even when the database is
        # already running: it recreates only what changed, the database stays up.
        run_logged "$_msa_cli" start --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" || _exakit_log_file "WARN  MCP: exasol start reported a failure; waiting for the sidecar anyway"
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
                run_logged "$_msa_cli" sidecar disable "$EXAKIT_MCP_SIDECAR" --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1 || true
                _mcp_sidecar_put "$_msa_user" "$_msa_pw" "$_msa_port" >/dev/null || true
                run_logged "$_msa_cli" start --deployment-dir "$EXAKIT_PERSONAL_DEPLOY_DIR" >/dev/null 2>&1 || true
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
    # Serving now: the install step's "the MCP server did not finish" record
    # (and its failure note) is history, whichever command healed it.
    # ⇄ twin: the same clear in Set-McpSidecar.
    command -v exakit_clear_soft_failure >/dev/null 2>&1 && exakit_clear_soft_failure mcp
    return 0
}
