#!/usr/bin/env bash
# mcp.sh — Exasol MCP server module (the AI agent bridge).
#
# Sourced by setup scripts after common.sh, detect.sh, a runtime module, and
# exapump.sh. Installs uv if needed, prepares MCP client configurations, and
# validates that the server starts and answers over stdio.
#
# Server facts:
#   - PyPI package exasol-mcp-server; run: uvx exasol-mcp-server@<version>
#   - config env: EXA_DSN, EXA_USER, EXA_PASSWORD, EXA_SSL_CERT_VALIDATION
#   - HTTP mode: exasol-mcp-server-http --host <h> --port <p>
#   - the server's tools are read-only (metadata + data reading queries);
#     a least-privilege database user adds defense in depth
#
# Guardrail layering:
#   1. server is read-only by design
#   2. dedicated read-only database user, provisioned and posture-checked by
#      exakit_configure_mcp_readonly_access in common.sh
#   3. permanent client setup (handled by the Python mcp package) points at
#      that user, never the admin user

# Legacy fallback used only when older manifest state does not yet contain the
# validated connection block. Keep it aligned with the provisioned read-only
# database user name.
EXAKIT_MCP_USER="${EXAKIT_MCP_USER:-mcp_readonly}"
EXAKIT_MCP_HTTP_PORT="${EXAKIT_MCP_HTTP_PORT:-8123}"

mcp_command_path() {
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

mcp_ssl_cert_validation() {
    # Disable certificate validation ONLY for a loopback DSN (the kit's local
    # self-signed runtime). The decision is keyed on the ACTUAL address, not on
    # the runtime.tls label: every local runtime hardcodes tls="self-signed", so
    # keying on the label would blanket-disable validation even if the DSN were
    # ever pointed at a non-loopback host — letting credentials cross an
    # unauthenticated TLS channel. For any non-loopback DSN, keep validation on.
    _dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    case "$_dsn" in
        127.0.0.1:*|localhost:*|\[::1\]:*)
            printf '%s\n' "no"
            ;;
        *)
            printf '%s\n' "yes"
            ;;
    esac
}

mcp_uv_install() {
    if command -v uv >/dev/null 2>&1; then
        ok "uv already installed: $(command -v uv)"
        return 0
    fi
    info "Installing uv (Python tool runner used by the MCP server)"
    if command -v brew >/dev/null 2>&1; then
        run_logged brew install uv || die "brew install uv failed (see log)"
    else
        # TODO(security): this pipes a remote installer straight into a shell,
        # unlike the kit's own artifacts which are SHA256-verified. It can't be
        # checksum-pinned without breakage (astral's install.sh content changes
        # over time) — a real fix means vendoring a pinned installer or shipping
        # uv via a verified release asset. Brew is preferred above precisely to
        # avoid this path on the common macOS case. Fetched over TLS from the
        # official host as a documented, accepted risk until then.
        curl -LsSf --retry 3 https://astral.sh/uv/install.sh | run_logged sh || \
            die "uv installation failed (see log)"
        # The uv installer defaults to ~/.local/bin
        case ":$PATH:" in
            *":$HOME/.local/bin:"*) ;;
            *) PATH="$HOME/.local/bin:$PATH" ;;
        esac
    fi
    command -v uv >/dev/null 2>&1 || \
        die "uv installed but is not on PATH. Add ~/.local/bin to your PATH (or restart your shell), then re-run."
    push_rollback "uv cache clean >/dev/null 2>&1 || true"
    ok "uv installed"
}

mcp_install() {
    mcp_uv_install
    info "Priming ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION} (downloads on first use)"
    # `--help` exits non-zero on server versions that demand connection env
    # before printing usage — so the exit code can't distinguish "download
    # failed" from "downloaded fine, refused to run without a database".
    # Any output from the package itself proves the prime worked; warn only
    # when the run never reached the package (uvx resolution/network failure).
    _exakit_log_file "CMD   uvx ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION} --help"
    ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-working}"
    _prime_out="$(uvx "${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}" --help 2>&1)"
    _prime_rc=$?
    ui_spin_end
    [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_prime_out" >> "$EXAKIT_LOG_FILE"
    if [ "$_prime_rc" -eq 0 ] || printf '%s' "$_prime_out" | grep -qiE 'usage:|insufficient database connection|exasol[./]ai[./]mcp|site-packages/exasol'; then
        ok "MCP server package cached"
    else
        warn "Could not prime the MCP server package (it will download on first client start)"
    fi
    _uv_bin="$(command -v uv 2>/dev/null || true)"
    [ -n "$_uv_bin" ] && manifest_set components.mcp_server.uv_path "$_uv_bin"
    manifest_set components.mcp_server.command "$(mcp_command_path)"
    manifest_set components.mcp_server.package "$EXAKIT_MCP_PACKAGE"
    manifest_set components.mcp_server.version "$EXAKIT_MCP_VERSION"
    ok "MCP server ready to run via uvx"
}

mcp_update() {
    _latest="$(exakit_component_latest mcp)"
    [ -n "$_latest" ] || die "Could not resolve the latest ${EXAKIT_MCP_PACKAGE} version."
    _current="$(manifest_get components.mcp_server.version 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "MCP server is already current ($_current)"
        return 0
    fi
    info "Updating MCP server ${_current:-unknown} -> $_latest"
    mcp_update_snapshot || warn "MCP pre-update snapshot was not created; generated configs will still be refreshed."
    EXAKIT_MCP_VERSION="$_latest"
    export EXAKIT_MCP_VERSION
    mcp_install
    warn "Run exakit mcp-setup to refresh AI client configs with the new MCP version."
    mcp_validate || true
    manifest_set desired.mcp "$EXAKIT_MCP_VERSION"
    ok "MCP server updated; database data was not changed"
}

mcp_update_snapshot() {
    command -v exakit_run_mcp_operation_cli >/dev/null 2>&1 || return 1
    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-update-backup.XXXXXX")"
    if ! exakit_run_mcp_operation_cli "backup" "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" "$_result_file"; then
        rm -f "$_result_file"
        return 1
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_operation_summary "$_result_file"
        _snapshot_id="$(run_python - "$_result_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("backup_reference", ""))
PY
)"
        [ -n "$_snapshot_id" ] && manifest_set backups.mcp_update.latest "$_snapshot_id"
    fi
    rm -f "$_result_file"
}

# mcp_credentials — prints "user<TAB>password_file" for the client configs.
# Prefers the validated dedicated read-only user; falls back to the legacy
# MCP default or, as a last resort, the runtime admin user.
mcp_credentials() {
    _connection_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _connection_pwfile="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    if [ -n "$_connection_user" ] && [ -n "$_connection_pwfile" ]; then
        printf '%s\t%s\n' "$_connection_user" "$_connection_pwfile"
        return 0
    fi
    if [ -n "$(manifest_get components.mcp_server.user 2>/dev/null || true)" ]; then
        printf '%s\t%s\n' "$EXAKIT_MCP_USER" "$EXAKIT_CREDS_DIR/mcp_readonly_password"
        return 0
    fi
    printf '%s\t%s\n' "$(manifest_get runtime.user 2>/dev/null)" \
        "$(manifest_get runtime.password_file 2>/dev/null)"
}

# mcp_resolve_creds — sets _mcp_user and _mcp_password for the caller.
# Single place that turns the credential reference into a usable secret.
mcp_resolve_creds() {
    _creds="$(mcp_credentials)"
    _mcp_user="$(printf '%s' "$_creds" | cut -f1)"
    _pwfile="$(printf '%s' "$_creds" | cut -f2)"
    _mcp_password=""
    [ -n "$_pwfile" ] && [ -f "$_pwfile" ] && _mcp_password="$(cat "$_pwfile")"
}

# mcp_stdio_handshake_once — one stdio initialize round against the server.
# Expects _dsn/_user/_password/_mcp_command/_ssl_cert_validation to be set by
# mcp_validate. Extra env (e.g. the faked-SVE OPENSSL_armcap workaround) is
# inherited from the caller's environment and reaches the uvx-spawned server.
mcp_stdio_handshake_once() {
    EXA_DSN="$_dsn" EXA_USER="$_user" EXA_PASSWORD="$_password" \
        EXA_SSL_CERT_VALIDATION="$_ssl_cert_validation" \
        run_python - "$_mcp_command" "$EXAKIT_MCP_PACKAGE" "$EXAKIT_MCP_VERSION" <<'PY' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
import json, subprocess, sys

command, pkg, ver = sys.argv[1], sys.argv[2], sys.argv[3]
proc = subprocess.Popen(
    [command, f"{pkg}@{ver}"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True,
)
request = json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {
        "protocolVersion": "2024-11-05",
        "capabilities": {},
        "clientInfo": {"name": "starter-kit-validator", "version": "1.0"},
    },
}) + "\n"
try:
    out, err = proc.communicate(request, timeout=120)
except subprocess.TimeoutExpired:
    proc.kill()
    print("handshake timed out")
    sys.exit(1)
print(err)
for line in out.splitlines():
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    if msg.get("id") == 1 and "result" in msg:
        info = msg["result"].get("serverInfo", {})
        print(f"handshake ok: {info.get('name')} {info.get('version')}")
        sys.exit(0)
print("no initialize result in server output")
sys.exit(1)
PY
}

# mcp_validate — start the server over stdio and check it answers an MCP
# initialize handshake. Uses the same env the client configs use.
mcp_validate() {
    info "Validating the MCP server (stdio handshake)"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    mcp_resolve_creds
    _user="$_mcp_user"
    _password="$_mcp_password"
    _mcp_command="$(mcp_command_path)"
    _ssl_cert_validation="$(mcp_ssl_cert_validation)"

    require_python3
    _handshake_ok=0
    for _attempt in 1 2; do
        if mcp_stdio_handshake_once; then
            _handshake_ok=1
            break
        fi
        [ "$_attempt" -lt 2 ] && { warn "Handshake attempt $_attempt failed — retrying"; sleep 5; }
    done
    # Faked-SVE self-repair: on aarch64 guests whose hypervisor advertises
    # SVE the host CPU cannot execute (seen: VirtualBox on Apple Silicon),
    # the server's cryptography stack dies with SIGILL inside OpenSSL's CPU
    # detection before it can answer. Retry once with OPENSSL_armcap=0; when
    # that is what fixes it, persist the flag so the generated client configs
    # launch the server with the same override.
    if [ "$_handshake_ok" -eq 0 ] && detect_cpu_advertises_sve; then
        warn "Handshake failed on a guest that advertises SVE its host CPU may not execute — retrying with OPENSSL_armcap=0"
        if ( export OPENSSL_armcap=0; mcp_stdio_handshake_once ); then
            _handshake_ok=1
            manifest_set components.mcp_server.openssl_armcap_workaround true
            detect_sve_remedy_hint
            info "Client configs generated by mcp-setup will launch the MCP server with OPENSSL_armcap=0."
        fi
    fi
    if [ "$_handshake_ok" -eq 1 ]; then
        ok "MCP server answers over stdio"
        manifest_set components.mcp_server.mode "stdio"
        manifest_set components.mcp_server.validated true
    else
        warn "MCP stdio validation failed (see log). The configs are still in place; clients may show more detail."
        manifest_set components.mcp_server.validated false
    fi

    if [ "${EXAKIT_MCP_HTTP_TEST:-0}" = "1" ]; then
        mcp_validate_http
    fi
}

# mcp_validate_http — optional: start the HTTP variant briefly and probe it.
mcp_validate_http() {
    info "Validating the MCP server (HTTP mode on port $EXAKIT_MCP_HTTP_PORT)"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    mcp_resolve_creds
    _user="$_mcp_user"
    _password="$_mcp_password"
    _ssl_cert_validation="$(mcp_ssl_cert_validation)"

    # The HTTP server refuses to start without authentication unless
    # --no-auth is passed. For this brief localhost-only validation that is
    # acceptable; a real remote deployment must configure proper auth.
    EXA_DSN="$_dsn" EXA_USER="$_user" EXA_PASSWORD="$_password" \
        EXA_SSL_CERT_VALIDATION="$_ssl_cert_validation" \
        uvx --from "${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}" \
        exasol-mcp-server-http --host 127.0.0.1 --port "$EXAKIT_MCP_HTTP_PORT" --no-auth \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 &
    _http_pid=$!
    # Poll instead of a fixed sleep: first uvx run may need to download.
    _http_ok=0
    _waited=0
    while [ "$_waited" -lt 60 ]; do
        if curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                "http://127.0.0.1:$EXAKIT_MCP_HTTP_PORT/mcp" 2>/dev/null | grep -qE '^(200|3..|4..)'; then
            _http_ok=1
            break
        fi
        kill -0 "$_http_pid" 2>/dev/null || break
        sleep 2
        _waited=$((_waited + 2))
    done
    if [ "$_http_ok" -eq 1 ]; then
        ok "HTTP mode answers on port $EXAKIT_MCP_HTTP_PORT"
        manifest_set components.mcp_server.http_validated true
    else
        warn "HTTP mode did not answer on port $EXAKIT_MCP_HTTP_PORT (see log)"
        manifest_set components.mcp_server.http_validated false
    fi
    # uvx spawns the actual server as a child process — kill both, bounded.
    pkill -P "$_http_pid" 2>/dev/null
    kill "$_http_pid" 2>/dev/null
    sleep 1
    pkill -9 -P "$_http_pid" 2>/dev/null
    kill -9 "$_http_pid" 2>/dev/null
    wait "$_http_pid" 2>/dev/null || true
}
