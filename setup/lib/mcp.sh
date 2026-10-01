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
        # A dependency that was already there is not an outcome of this step,
        # and its path is not something to act on. Logged, not printed.
        _exakit_log_file "OK    uv already installed: $(command -v uv)"
        return 0
    fi
    info "Installing uv (Python tool runner used by the MCP server)"
    if command -v brew >/dev/null 2>&1; then
        run_logged brew install uv ||
            die "Homebrew could not install uv, which the MCP server runs through. What brew said: exakit logs setup. Then install it yourself and re-run:  brew install uv"
    else
        # TODO(security): this pipes a remote installer straight into a shell,
        # unlike the kit's own artifacts which are SHA256-verified. It can't be
        # checksum-pinned without breakage (astral's install.sh content changes
        # over time) — a real fix means vendoring a pinned installer or shipping
        # uv via a verified release asset. Brew is preferred above precisely to
        # avoid this path on the common macOS case. Fetched over TLS from the
        # official host as a documented, accepted risk until then.
        # --proto/--proto-redir: this is the one artifact the kit installs
        # WITHOUT a digest, and it is also the longest-lived one - uvx is the
        # process the AI client launches to run the MCP server, and it is
        # handed EXA_PASSWORD on every start. -L follows redirects, so without
        # --proto-redir a 302 to http:// is fetched in the clear and piped
        # straight into sh. Every binary download in this kit already carries
        # --proto '=https'; the script that is executed carried neither.
        curl -LsSf --proto '=https' --proto-redir '=https' --retry 3 \
            https://astral.sh/uv/install.sh | run_logged sh || \
            die "The uv installer did not finish, and the MCP server runs through uv. What it printed: exakit logs setup. Then install it yourself and re-run:  curl -LsSf https://astral.sh/uv/install.sh | sh"
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

# Six lines became one. uv's path, the priming bullet, "package cached",
# "ready to run via uvx", the handshake bullet and its tick were one fact:
# the server is cached and answers. mcp_validate prints the merged line; the
# phases live on the spinner instead. ⇄ twin: Install-Mcp in mcp.ps1.
# mcp_prefetch_begin — start the MCP package download NOW, in the background,
# so it overlaps the data load instead of queueing behind it.
#
# THE TWO STEPS NEED NOTHING FROM EACH OTHER. Priming the package is a download
# and an unpack; the data load is a local database talking to local files.
# Run one after the other they cost the sum of their times, and on Windows that
# sum was ~5 minutes of a fresh install (131s loading, 166s on the bridge).
# The prime is the bigger half and almost all of it is uv materialising the
# server's environment — 12,099 files and 207MB, measured — which is exactly
# the work a machine can do while its database is busy elsewhere.
#
# Best-effort by construction: no uv, no network, or a kit where the MCP step
# never runs, and this returns having done nothing. mcp_install then primes
# inline exactly as it always did, so the only thing that can be lost is the
# saving.
mcp_prefetch_begin() {
    [ "${EXAKIT_MCP_PREFETCH:-1}" = "1" ] || return 0
    [ -n "${EXAKIT_MCP_PREFETCH_PID:-}" ] && return 0
    mcp_uv_install >/dev/null 2>&1 || return 0
    command -v uvx >/dev/null 2>&1 || return 0
    EXAKIT_MCP_PREFETCH_LOG="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-prefetch.XXXXXX" 2>/dev/null)" || return 0
    # Its own file, not the install log: this writes while the data load is
    # writing too, and two appenders interleave into nonsense. It is folded
    # into the install log when mcp_install collects it.
    # The exit code goes to a file beside the log, because the collector cannot
    # read it any other way - see the note on waiting in mcp_install.
    ( uvx "${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}" --help >"$EXAKIT_MCP_PREFETCH_LOG" 2>&1
      printf '%s' "$?" > "$EXAKIT_MCP_PREFETCH_LOG.rc" ) &
    EXAKIT_MCP_PREFETCH_PID=$!
    _exakit_log_file "INFO  MCP package prefetch started in the background (pid $EXAKIT_MCP_PREFETCH_PID)"
    return 0
}

# mcp_prefetch_stop — leave no orphan behind when the install dies early.
mcp_prefetch_stop() {
    [ -n "${EXAKIT_MCP_PREFETCH_PID:-}" ] || return 0
    kill "$EXAKIT_MCP_PREFETCH_PID" 2>/dev/null
    wait "$EXAKIT_MCP_PREFETCH_PID" 2>/dev/null
    rm -f "${EXAKIT_MCP_PREFETCH_LOG:-}" "${EXAKIT_MCP_PREFETCH_LOG:-}.rc" 2>/dev/null
    EXAKIT_MCP_PREFETCH_PID=""
    EXAKIT_MCP_PREFETCH_LOG=""
    return 0
}

mcp_install() {
    EXAKIT_MCP_STEP_T0="$(date +%s 2>/dev/null || echo 0)"
    mcp_uv_install
    EXAKIT_ACTIVE_LABEL="Downloading ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION} — first run only"
    info "Priming ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION} (downloads on first use)"
    # `--help` exits non-zero on server versions that demand connection env
    # before printing usage — so the exit code can't distinguish "download
    # failed" from "downloaded fine, refused to run without a database".
    # Any output from the package itself proves the prime worked; warn only
    # when the run never reached the package (uvx resolution/network failure).
    _exakit_log_file "CMD   uvx ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION} --help"
    ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-working}"
    if [ -n "${EXAKIT_MCP_PREFETCH_PID:-}" ]; then
        # Started before the data load (mcp_prefetch_begin). On a machine that
        # took longer to load than to download, this has already finished and
        # the poll below returns at once - which is the whole point.
        #
        # NOT `wait`, AND THAT IS NOT A STYLE CHOICE. mcp_install runs inside
        # the soft-step SUBSHELL (`if ( "$@" )` in exakit_soft_step), and a
        # shell can only wait on its OWN children. `wait` on a sibling pid
        # returns non-zero IMMEDIATELY without waiting for anything - so the
        # log was read while it was still being written, yielding uv's first
        # progress line and none of the package output the verdict is graded
        # on, and then deleted out from under a process that was still running.
        # Observed on a real install: "Installed 87 packages in 429ms", six
        # seconds after the prefetch started, graded "Could not prime".
        # kill -0 asks the same question about any process, child or not.
        while kill -0 "$EXAKIT_MCP_PREFETCH_PID" 2>/dev/null; do
            sleep 1
        done
        _prime_out="$(cat "$EXAKIT_MCP_PREFETCH_LOG" 2>/dev/null)"
        _prime_rc="$(cat "$EXAKIT_MCP_PREFETCH_LOG.rc" 2>/dev/null)"
        case "$_prime_rc" in ''|*[!0-9]*) _prime_rc=1 ;; esac
        rm -f "$EXAKIT_MCP_PREFETCH_LOG" "$EXAKIT_MCP_PREFETCH_LOG.rc" 2>/dev/null
        EXAKIT_MCP_PREFETCH_PID=""
        EXAKIT_MCP_PREFETCH_LOG=""
    else
        _prime_out="$(uvx "${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}" --help 2>&1)"
        _prime_rc=$?
    fi
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
    # Not announced: "cached" above and "answers over stdio" below are the two
    # facts, and this said neither of them again.
    _exakit_log_file "OK    MCP server ready to run via uvx"
}

mcp_update() {
    _latest="$(exakit_component_available mcp)"
    [ -n "$_latest" ] || die "Could not resolve the advertised ${EXAKIT_MCP_PACKAGE} version."
    # The already-current guard reads the same thing `exakit version` prints in
    # its Installed column: the pin in the AI client configs, which is the spec uvx
    # will materialise the next time a client starts. The manifest record is only
    # what a previous run WROTE DOWN, and mcp_install writes it before the client
    # configs are refreshed (it has to — the config renderer reads the record to
    # build the pin). Comparing against the record therefore let a half-finished
    # update look complete: the dispatcher announced "mcp 1.10.1 -> 2.0.0" from the
    # live pin, and this function answered "already current (2.0.0)" from the record
    # while every client was still launching 1.10.1.
    _mcp_recorded="$(manifest_get components.mcp_server.version 2>/dev/null || true)"
    if command -v exakit_component_current >/dev/null 2>&1; then
        _current="$(exakit_component_current mcp 2>/dev/null || true)"
    else
        _current=""
    fi
    [ -n "$_current" ] || _current="$_mcp_recorded"
    if [ "$_latest" = "$_current" ]; then
        # Genuinely already current, so this stays a clean skip — but a record that
        # disagrees with the configs is still reconciled, because that record is what
        # the renderer would write into the next client the user connects.
        if [ "$_mcp_recorded" != "$_current" ]; then
            info "Reconciling the recorded MCP version (${_mcp_recorded:-unrecorded}) with the pin in the AI client configs"
            manifest_set components.mcp_server.version "$_current"
        fi
        ok "MCP server is already current ($_current)"
        return 0
    fi
    info "Updating MCP server ${_current:-unknown} -> $_latest"
    mcp_update_snapshot || warn "MCP pre-update snapshot was not created; generated configs will still be refreshed."
    EXAKIT_MCP_VERSION="$_latest"
    export EXAKIT_MCP_VERSION
    mcp_install
    mcp_refresh_client_pins || true
    mcp_validate || true
    manifest_set desired.mcp "$EXAKIT_MCP_VERSION"
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

# mcp_refresh_client_pins — re-render the managed entry in the clients that are
# already connected, so the version they launch is the one this update installed.
# Without this the update moved nothing a client can see: only the manifest record
# changed, and the next `exakit update` used to trust that record and skip.
#
# This is the configure operation (what `exakit mcp-setup` runs), and it stays
# configure because configure re-renders unconditionally: mid-update the guarantee
# wanted is "the entry now says what we just installed", not the outcome of a
# comparison. `repair` can also move an intact-but-outdated pin now — it compares
# the live entry against the definition the kit would write, not only against the
# hash recorded at the last write (mcp/validator/service.py) — so it is the right
# command for a user fixing a client after the fact, not the one for this step.
#
# Scoped to already-managed clients on purpose: configure would happily create a
# config for a client the user never chose to connect.
mcp_refresh_client_pins() {
    if ! command -v exakit_run_mcp_setup_cli >/dev/null 2>&1; then
        warn "Run exakit mcp-setup to refresh AI client configs with the new MCP version."
        return 1
    fi
    _refresh_clients="$(mcp_managed_clients)"
    if [ -z "$_refresh_clients" ]; then
        info "No AI client is connected yet — connect one any time with: exakit mcp-setup"
        return 0
    fi
    info "Refreshing AI client configs to ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}"
    _refresh_result="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-refresh.XXXXXX")"
    if ! exakit_run_mcp_setup_cli "$_refresh_clients" "$_refresh_result"; then
        rm -f "$_refresh_result"
        warn "Could not refresh the AI client configs — run exakit mcp-setup to finish the update."
        return 1
    fi
    if [ -s "$_refresh_result" ]; then
        exakit_print_mcp_setup_summary "$_refresh_result"
    fi
    rm -f "$_refresh_result"
    # Confirm from the configs, not from the record: mcp_install already wrote the
    # record, so only the live pin can say whether the clients actually moved.
    _refresh_pin="$(exakit_installed_mcp_version 2>/dev/null || true)"
    if [ -n "$_refresh_pin" ] && [ "$_refresh_pin" != "$EXAKIT_MCP_VERSION" ]; then
        warn "An AI client is still pinned to ${EXAKIT_MCP_PACKAGE}@${_refresh_pin} — see exakit mcp-doctor."
        return 1
    fi
    ok "AI client configs now launch ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION}"
}

# _exakit_mcp_addon_say <info|warn> <text> - say something that may be
# happening UNDER A LIVE TABLE.
#
# The marketplace paints its add-ons as an animated table: it redraws the frame
# in place by moving the cursor up by the frame height. A line printed straight
# to the terminal in the middle of that lands inside the box and throws the
# cursor arithmetic off, so the frame is stranded exactly where it was -- which
# is what the registration line did on a real install: dash-server frozen at
# 14%, the two rows below it never drawn, and the message sitting under a table
# that had stopped moving.
#
# _exakit_addon_note is the mechanism that already exists for this: it holds a
# line back while the table is live and the apply loop drains it the moment the
# table stops. ok_step was the wrong tool -- it exists to survive the QUIETING a
# one-line step turns on, which is a different problem, and surviving the
# quieting is precisely how it punched through the protection.
#
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
# Scoped to already-managed clients for the same reason mcp_refresh_client_pins
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

# mcp_resolve_creds — sets _mcp_user and _mcp_password for the caller.
# Single place that turns the credential reference into a usable secret.
mcp_resolve_creds() {
    _creds="$(mcp_credentials)"
    _mcp_user="$(printf '%s' "$_creds" | cut -f1)"
    _pwfile="$(printf '%s' "$_creds" | cut -f2)"
    # "readonly" or "admin-fallback" - see mcp_credentials. Callers that tell
    # the user what the AI client connects as must not describe the second as
    # the first.
    _mcp_user_kind="$(printf '%s' "$_creds" | cut -f3)"
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

# mcp_print_handshake_detail — show what the failed handshake actually said.
#
# mcp_stdio_handshake_once deliberately captures the server's stderr and prints
# it, and the whole call is redirected into the log file — so the process was
# already holding the reason (an authentication failure, a bad DSN, a missing
# package) when the old wording said "see log" and sent the reader into a
# different program to look for it. On this step above all — the one a user
# reaches BECAUSE their assistant cannot see the database — the cause belongs on
# screen.
#
# Only this validation's own slice of the log is read, from the mark taken
# before the first attempt, so noise from an earlier step can never be presented
# as this failure's cause. Only the tail of that slice is shown: uvx narrates
# its own environment build first and the reason is always last.
#
# The text is redacted before printing. It comes from a process that was handed
# the database password in its environment, and a driver traceback can echo its
# connection arguments back out.
mcp_print_handshake_detail() {
    [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -f "$EXAKIT_LOG_FILE" ] || return 1
    _mphd_text="$(tail -n "+$(( ${_mcp_handshake_log_mark:-0} + 1 ))" "$EXAKIT_LOG_FILE" 2>/dev/null \
        | grep -av '^[[:space:]]*$' | tail -8)"
    [ -n "$_mphd_text" ] || return 1
    _mphd_text="$(_exakit_redact_mcp_secret_output "$_mphd_text" "${_password:-}")"
    # Same dim-gutter containment every other piece of foreign output gets, in
    # the error colour because that is what this is.
    printf '%s\n' "$_mphd_text" | while IFS= read -r _mphd_line; do
        printf '      %s%s %s%s\n' "${UI_ERR:-}" "${UI_VB:-|}" "$_mphd_line" "${UI_RESET:-}" >&2
    done
    return 0
}

# mcp_validate — start the server over stdio and check it answers an MCP
# initialize handshake. Uses the same env the client configs use.
mcp_validate() {
    info "Validating the MCP server (stdio handshake)"
    EXAKIT_ACTIVE_LABEL="Starting the MCP server and checking it answers"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    mcp_resolve_creds
    _user="$_mcp_user"
    _password="$_mcp_password"
    _mcp_command="$(mcp_command_path)"
    _ssl_cert_validation="$(mcp_ssl_cert_validation)"

    require_python3
    # Where this validation's output starts in the log, so a failure can quote
    # its own handshake and nothing else.
    _mcp_handshake_log_mark=0
    [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -f "$EXAKIT_LOG_FILE" ] && \
        _mcp_handshake_log_mark="$(wc -l < "$EXAKIT_LOG_FILE" 2>/dev/null | tr -d ' ')"
    case "$_mcp_handshake_log_mark" in ''|*[!0-9]*) _mcp_handshake_log_mark=0 ;; esac
    _handshake_ok=0
    for _attempt in 1 2; do
        # The handshake starts the server, and starting it can mean uvx
        # materialising an environment first. Under the step's one-line quieting
        # the info above went to the log, so without a spinner this phase is a
        # blank screen for as long as that takes.
        ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-working}"
        if mcp_stdio_handshake_once; then
            ui_spin_end
            _handshake_ok=1
            break
        fi
        ui_spin_end
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
        # The step's one line: what is cached, and that it answers. The elapsed
        # spans the prime and the handshake, which is the whole of this step's
        # work. Through ok_step so it survives the caller's one-line quieting.
        ok_step "MCP server ${EXAKIT_MCP_PACKAGE}@${EXAKIT_MCP_VERSION} cached and answering over stdio ($(( $(date +%s 2>/dev/null || echo 0) - ${EXAKIT_MCP_STEP_T0:-0} ))s)"
        manifest_set components.mcp_server.mode "stdio"
        manifest_set components.mcp_server.validated true
    else
        error "The MCP server did not answer the stdio handshake. What it said:"
        mcp_print_handshake_detail || \
            printf '      %s%s (the handshake produced no output)%s\n' \
                "${UI_ERR:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        warn "Your database and the client configs are unchanged — clients will still start the server. For a deeper check, run: exakit mcp-doctor"
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
        warn "The HTTP MCP server did not answer on port $EXAKIT_MCP_HTTP_PORT. What it printed: exakit logs setup. Check nothing else holds that port, then retry with: exakit mcp-setup"
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
