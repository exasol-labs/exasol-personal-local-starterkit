#!/usr/bin/env bash
# exasol-scheduler.sh — Exasol Scheduler (table-driven SQL jobs): managed
# install + service lifecycle.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. The user picks it
# from `exakit marketplace`; once installed it joins `exakit update` and the
# service set (`exakit start/stop/status/autostart/logs`) like dash-server.
# Sourced by the exakit CLI after common.sh.
#
# exasol-scheduler facts (github.com/exasol-labs/exasol-scheduler):
#   - A single stateless Rust binary that polls a SCHED.SCHED_TASKS table and
#     runs each due row's SQL_TEXT verbatim against Exasol. Jobs are defined,
#     paused and audited with plain SQL; history lands in SCHED_HISTORY.
#   - Upstream publishes prebuilt binaries for every platform the kit runs on;
#     the pkg workflow verifies them against upstream's own per-asset .sha256
#     files and republishes them as bare binaries on ONE IMMUTABLE RELEASE per
#     build (exasol-scheduler-<version>), the same posture as json-tables.
#   - SCHED_TASKS is a CODE-EXECUTION SURFACE: whoever can write that table
#     runs arbitrary SQL as the scheduler's database user. So the kit NEVER
#     runs it as the admin user — install creates a dedicated SCHEDULER_SVC
#     user, grants it the bootstrap privileges upstream documents
#     (CREATE SCHEMA, CREATE TABLE), and validate REVOKES them again the
#     moment the schema exists, exactly as upstream's security guide says.
#   - The process EXITS on a fatal root error and after losing the database,
#     and upstream's own systemd example runs it Restart=on-failure. The kit's
#     macOS boot entry is RunAtLoad with no KeepAlive, so supervision lives in
#     the LAUNCHER: it waits for the database, restarts the engine with
#     backoff, and gives up loudly on a crash loop instead of spinning.
#   - Upstream requires a SINGLETON per task table — two pollers run every job
#     twice. The launcher takes a pidfile guard, as upstream's operations
#     guide recommends for manual supervision.
#   - Missed occurrences are NEVER replayed: on restart the next run is
#     computed from the current clock. On a laptop that sleeps, that is a
#     documented property, not a bug — the help page says so.
#
#   - engine:   $EXAKIT_HOME/exasol-scheduler/libexec/exasol_scheduler
#   - launcher: $EXAKIT_BIN_DIR/exasol-scheduler (supervises the engine)
#   - pidfile:  $EXAKIT_HOME/exasol-scheduler/exasol-scheduler.pid
#   - log:      $EXAKIT_LOG_DIR/exasol-scheduler.log
#   - DB user:  SCHEDULER_SVC (password under $EXAKIT_CREDS_DIR, mode 600)
#
# Safe to re-run: an existing engine at the desired version is kept.

# The add-on's version constants live here, next to the code that uses them —
# the generic registry arms in common.sh find them by the derived name
# convention (EXAKIT_<ID>_VERSION[_FALLBACK]), and the versions-bump workflow
# keeps the fallback in lockstep with versions.json (COUPLED table).
EXAKIT_EXASOL_SCHEDULER_VERSION="${EXAKIT_EXASOL_SCHEDULER_VERSION:-}"
EXAKIT_EXASOL_SCHEDULER_VERSION_FALLBACK="${EXAKIT_EXASOL_SCHEDULER_VERSION_FALLBACK:-v0.3.1}"
EXAKIT_EXASOL_SCHEDULER_REPO="${EXAKIT_EXASOL_SCHEDULER_REPO:-exasol-labs/exasol-scheduler}"
EXAKIT_EXASOL_SCHEDULER_HOME="${EXAKIT_EXASOL_SCHEDULER_HOME:-$EXAKIT_HOME/exasol-scheduler}"
EXAKIT_EXASOL_SCHEDULER_BIN="${EXAKIT_EXASOL_SCHEDULER_BIN:-$EXAKIT_BIN_DIR/exasol-scheduler}"
EXAKIT_EXASOL_SCHEDULER_LOG="${EXAKIT_EXASOL_SCHEDULER_LOG:-$EXAKIT_LOG_DIR/exasol-scheduler.log}"
EXAKIT_EXASOL_SCHEDULER_PIDFILE="${EXAKIT_EXASOL_SCHEDULER_PIDFILE:-$EXAKIT_EXASOL_SCHEDULER_HOME/exasol-scheduler.pid}"
EXAKIT_EXASOL_SCHEDULER_USER="${EXAKIT_EXASOL_SCHEDULER_USER:-scheduler_svc}"
EXAKIT_EXASOL_SCHEDULER_SCHEMA="${EXAKIT_EXASOL_SCHEDULER_SCHEMA:-SCHED}"
# Names a release tag by hand (tests, or pointing an install at one specific
# build); empty means "the release versions.json pins".
EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG="${EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG:-}"

exasol_scheduler_engine_path() {
    printf '%s\n' "$EXAKIT_EXASOL_SCHEDULER_HOME/libexec/exasol_scheduler"
}

exasol_scheduler_log_path() {
    printf '%s\n' "$EXAKIT_EXASOL_SCHEDULER_LOG"
}

# --- version + release resolution --------------------------------------------

# exasol_scheduler_latest — the generic <id>_latest hook. Deliberately the
# version versions.json ADVERTISES, not upstream's newest: only a build the
# pkg workflow has already published and pinned is installable, so nothing is
# ever offered before its artifacts and digests exist. Same posture as
# json-tables. ⇄ twin: Get-ExasolSchedulerLatest.
exasol_scheduler_latest() {
    _esl="$(exakit_versions_value components.exasol-scheduler.version 2>/dev/null || true)"
    [ -n "$_esl" ] || _esl="$EXAKIT_EXASOL_SCHEDULER_VERSION_FALLBACK"
    printf '%s\n' "$_esl"
}

_exasol_scheduler_target_version() {
    if [ -n "${EXAKIT_EXASOL_SCHEDULER_VERSION:-}" ]; then
        printf '%s\n' "$EXAKIT_EXASOL_SCHEDULER_VERSION"
        return 0
    fi
    exasol_scheduler_latest
}

# The digest pins describe the ADVERTISED build only; a build chosen by hand
# reads its own release's published digests instead.
_exasol_scheduler_pin_applies() {
    [ -n "${EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG:-}" ] && return 1
    [ -z "${EXAKIT_EXASOL_SCHEDULER_VERSION:-}" ] && return 0
    _esp_adv="$(exakit_versions_value components.exasol-scheduler.version 2>/dev/null || true)"
    [ -n "$_esp_adv" ] && [ "$_esp_adv" = "$EXAKIT_EXASOL_SCHEDULER_VERSION" ]
}

# Where the prebuilt artifacts live: the repository this kit copy came from,
# so a fork install downloads from the fork. Same resolution as
# json_tables_mirror_repo.
exasol_scheduler_mirror_repo() {
    if [ -n "${EXAKIT_EXASOL_SCHEDULER_MIRROR_REPO:-}" ]; then
        printf '%s\n' "$EXAKIT_EXASOL_SCHEDULER_MIRROR_REPO"
        return 0
    fi
    _esm_src="$(manifest_get kit.source 2>/dev/null || true)"
    case "$_esm_src" in
        */*@*) printf '%s\n' "${_esm_src%@*}"; return 0 ;;
    esac
    printf '%s\n' "$EXAKIT_KIT_REPO"
}

exasol_scheduler_release_tag() {
    if [ -n "${EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG:-}" ]; then
        printf '%s\n' "$EXAKIT_EXASOL_SCHEDULER_RELEASE_TAG"
        return 0
    fi
    if _exasol_scheduler_pin_applies; then
        _esr_pin="$(exakit_versions_value components.exasol-scheduler.release 2>/dev/null || true)"
        if [ -n "$_esr_pin" ]; then
            printf '%s\n' "$_esr_pin"
            return 0
        fi
    fi
    printf 'exasol-scheduler-%s\n' "$(_exasol_scheduler_target_version)"
}

# --- platform ----------------------------------------------------------------

# exasol_scheduler_asset — the engine built for THIS machine, by the kit
# release's own naming (bare binaries, repackaged by the pkg workflow from
# upstream's archives). Upstream ships every platform the kit runs on —
# including Intel macOS, which most add-ons lack — so "not applicable" is only
# ever an exotic architecture. ⇄ twin: Get-ExasolSchedulerAsset.
exasol_scheduler_asset() {
    if command -v detect_os >/dev/null 2>&1; then
        _esa_raw_os="$(detect_os 2>/dev/null || true)"
        _esa_raw_arch="$(detect_arch 2>/dev/null || true)"
    else
        _esa_raw_os="$(uname -s 2>/dev/null || true)"
        _esa_raw_arch="$(uname -m 2>/dev/null || true)"
    fi
    case "$_esa_raw_os" in
        macos|Darwin|darwin) _esa_os="macos" ;;
        # WSL runs the linux binary; detect_os keeps them apart for the
        # installer's sake, an artifact lookup folds them back together.
        linux|Linux|wsl)     _esa_os="linux" ;;
        *)                   return 1 ;;
    esac
    case "$_esa_raw_arch" in
        arm64|aarch64)  _esa_arch="arm64" ;;
        x86_64|amd64)   _esa_arch="x86_64" ;;
        *)              return 1 ;;
    esac
    printf 'exasol-scheduler-%s-%s\n' "$_esa_os" "$_esa_arch"
}

exasol_scheduler_applicable() {
    exasol_scheduler_asset >/dev/null 2>&1
}

exasol_scheduler_applicable_reason() {
    if command -v detect_os >/dev/null 2>&1; then
        _esr_where="$(detect_os 2>/dev/null || true)/$(detect_arch 2>/dev/null || true)"
    else
        _esr_where="$(uname -s 2>/dev/null || true)/$(uname -m 2>/dev/null || true)"
    fi
    printf '%s\n' "no prebuilt scheduler binary is published for this platform ($_esr_where)"
}

# A copy the user installed themselves (cargo install, a package manager, a
# hand-built binary on PATH) is respected, never managed. The kit's own
# launcher answers to this name too, so the kit path is excluded.
exasol_scheduler_system_present() {
    _ess_path="$(command -v exasol_scheduler 2>/dev/null || true)"
    [ -n "$_ess_path" ] && [ "$_ess_path" != "$(exasol_scheduler_engine_path)" ] && return 0
    return 1
}

exasol_scheduler_installed_version() {
    [ -x "$(exasol_scheduler_engine_path)" ] || return 1
    _esv="$(manifest_get components.exasol_scheduler.version 2>/dev/null || true)"
    [ -n "$_esv" ] || return 1
    printf '%s\n' "$_esv"
}

# --- verified download --------------------------------------------------------

_exasol_scheduler_asset_url() {
    printf 'https://github.com/%s/releases/download/%s/%s\n' \
        "$(exasol_scheduler_mirror_repo)" "$(exasol_scheduler_release_tag)" "$1"
}

# _exasol_scheduler_digest <asset> — the sha256 to verify against: the pin in
# versions.json for the advertised build (no network, cannot be rate limited),
# else the digest GitHub publishes for the asset on the release being
# installed. An unverifiable download is refused either way.
_exasol_scheduler_digest() {
    _esd_key="${1#exasol-scheduler-}"
    _esd_key="$(printf '%s' "$_esd_key" | sed 's/\.exe$//')"
    if _exasol_scheduler_pin_applies; then
        _esd_pin="$(exakit_versions_value "components.exasol-scheduler.sha256.$_esd_key" 2>/dev/null || true)"
        if [ -n "$_esd_pin" ]; then
            printf '%s\n' "$_esd_pin"
            return 0
        fi
    fi
    exakit_can_run_python || return 1
    # --proto/--proto-redir, and here it matters most: this call attaches
    # GITHUB_TOKEN as a bearer header and -L follows redirects, so without the
    # guard a redirect to http:// would put the token on the wire in clear -
    # and the response it fetches decides which digest is checked.
    _esd_json="$(curl -sSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
        "https://api.github.com/repos/$(exasol_scheduler_mirror_repo)/releases/tags/$(exasol_scheduler_release_tag)" \
        2>/dev/null || true)"
    [ -n "$_esd_json" ] || return 1
    printf '%s' "$_esd_json" | run_python -c '
import json, sys
name = sys.argv[1]
doc = json.load(sys.stdin)
for asset in doc.get("assets", []):
    if asset["name"] == name and asset.get("digest", "").startswith("sha256:"):
        print(asset["digest"].split(":", 1)[1])
        break
' "$1"
}

_exasol_scheduler_fetch_verified() {
    _esf_asset="$1"
    _esf_dest="$2"
    fetch_quiet "$(_exasol_scheduler_asset_url "$_esf_asset")" "$_esf_dest" || return 1
    _esf_expected="$(_exasol_scheduler_digest "$_esf_asset" 2>/dev/null || true)"
    if [ -z "$_esf_expected" ]; then
        # The escape hatch the other components already carry, named in the
        # refusal rather than left as folklore: a refusal that offers only a
        # retry is a dead end on an offline machine or a fork whose packaging
        # workflow has not run. ⇄ twin: Get-ExasolSchedulerVerifiedAsset.
        if [ "${EXAKIT_ALLOW_UNVERIFIED_EXASOL_SCHEDULER:-0}" = "1" ]; then
            warn "No digest available for $_esf_asset — proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXASOL_SCHEDULER=1)."
            return 0
        fi
        rm -f "$_esf_dest"
        warn "No checksum is available for $_esf_asset; refusing an unverified artifact. Usually the release is still publishing or the GitHub API was unreachable - retry with: exakit update exasol-scheduler. Add its digest to versions.json (components.exasol-scheduler.sha256.<platform>) or, at your own risk, override with EXAKIT_ALLOW_UNVERIFIED_EXASOL_SCHEDULER=1."
        return 1
    fi
    _esf_actual="$(sha256_of "$_esf_dest")"
    if [ "$_esf_actual" != "$_esf_expected" ]; then
        rm -f "$_esf_dest"
        warn "Checksum mismatch for $_esf_asset (expected $_esf_expected, got $_esf_actual)"
        return 1
    fi
    ok "Checksum verified: $_esf_asset"
}

# --- the dedicated database user ----------------------------------------------
#
# SCHED_TASKS is a code-execution surface (any writer runs arbitrary SQL as
# this user), so the scheduler NEVER runs as the admin. The bootstrap grants
# upstream documents — CREATE SCHEMA and CREATE TABLE, needed only for the
# very first startup — are granted here and revoked by validate once the
# schema exists. Idempotent: an existing user has its password rotated to the
# stored credential, exactly the mcp_readonly posture.
_exasol_scheduler_sql() {
    printf '%s\n' "$1" | "$(exakit_exapump_bin)" sql -p "$EXAKIT_EXAPUMP_PROFILE" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
}

_exasol_scheduler_sql_has_token() {
    printf '%s\n' "$1" | "$(exakit_exapump_bin)" sql -p "$EXAKIT_EXAPUMP_PROFILE" 2>/dev/null \
        | grep -Fq "$2"
}

_exasol_scheduler_identifier_user() {
    printf '%s' "$EXAKIT_EXASOL_SCHEDULER_USER" | tr '[:lower:]' '[:upper:]'
}

_exasol_scheduler_ensure_db_user() {
    command -v exakit_exapump_bin >/dev/null 2>&1 || {
        warn "exapump is required to create the scheduler's database user."
        return 1
    }
    _esu_pw="$(read_credential exasol_scheduler_password)"
    if ! _exakit_validate_sql_password_token "$_esu_pw"; then
        _esu_pw="$(_exakit_generate_sql_password_token)"
        store_credential exasol_scheduler_password "$_esu_pw"
    fi
    _esu_user="$(_exasol_scheduler_identifier_user)"
    if _exasol_scheduler_sql_has_token \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '$_esu_user') THEN 'EXAKIT_SCHED_USER_PRESENT' ELSE 'EXAKIT_SCHED_USER_MISSING' END AS STATUS" \
        "EXAKIT_SCHED_USER_PRESENT"; then
        _exasol_scheduler_sql "ALTER USER ${_esu_user} IDENTIFIED BY ${_esu_pw}" || {
            warn "Could not rotate the scheduler database user's password."
            return 1
        }
    else
        info "Creating the dedicated scheduler database user ($EXAKIT_EXASOL_SCHEDULER_USER)"
        _exasol_scheduler_sql "CREATE USER ${_esu_user} IDENTIFIED BY ${_esu_pw}" || {
            warn "Could not create the scheduler database user."
            return 1
        }
    fi
    _exasol_scheduler_sql "GRANT CREATE SESSION TO ${_esu_user}" || return 1
    # Bootstrap only — validate revokes both once the schema exists.
    _exasol_scheduler_sql "GRANT CREATE SCHEMA TO ${_esu_user}" || return 1
    _exasol_scheduler_sql "GRANT CREATE TABLE TO ${_esu_user}" || return 1
    return 0
}

_exasol_scheduler_schema_exists() {
    _ese_schema="$(printf '%s' "$EXAKIT_EXASOL_SCHEDULER_SCHEMA" | tr '[:lower:]' '[:upper:]')"
    _exasol_scheduler_sql_has_token \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_SCHEMAS WHERE SCHEMA_NAME = '$_ese_schema') THEN 'EXAKIT_SCHED_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHED_SCHEMA_MISSING' END AS STATUS" \
        "EXAKIT_SCHED_SCHEMA_PRESENT"
}

# The bootstrap-then-revoke step upstream's security guide prescribes. Runs
# from validate once the schema exists; a no-op after the first success (the
# manifest remembers). REVOKE of a privilege the user no longer holds errors,
# so failures here are logged, never fatal.
_exasol_scheduler_revoke_bootstrap() {
    [ "$(manifest_get components.exasol_scheduler.bootstrap_revoked 2>/dev/null || true)" = "true" ] && return 0
    _esu_user="$(_exasol_scheduler_identifier_user)"
    _exasol_scheduler_sql "REVOKE CREATE SCHEMA FROM ${_esu_user}" || true
    _exasol_scheduler_sql "REVOKE CREATE TABLE FROM ${_esu_user}" || true
    manifest_set components.exasol_scheduler.bootstrap_revoked true
    ok "Bootstrap privileges revoked from $EXAKIT_EXASOL_SCHEDULER_USER (schema exists; upstream's least-privilege posture)"
}

# --- launcher -----------------------------------------------------------------
#
# The launcher IS the supervisor. Three properties upstream documents force
# its shape:
#   1. SINGLETON: two pollers on one table run every job twice, so a pidfile
#      guard refuses a second copy — the guard upstream's own operations
#      guide prescribes for manual supervision.
#   2. The engine EXITS on fatal errors and upstream runs it
#      Restart=on-failure; the kit's macOS boot entry is RunAtLoad with no
#      KeepAlive, so the launcher restarts the engine itself, with backoff,
#      and gives up loudly on a crash loop instead of spinning forever.
#   3. At login the database may not be up yet, so the launcher waits for the
#      port before the first start — bounded, so a machine whose database was
#      deliberately stopped does not hold a zombie supervisor.
# Credentials: only the PATH of the password file is baked in (mode 600); the
# password is read at RUN time into the environment, never onto an argv, where
# `ps` would show it to every local user.
exasol_scheduler_write_launcher() {
    mkdir -p "$EXAKIT_BIN_DIR" "$EXAKIT_EXASOL_SCHEDULER_HOME" 2>/dev/null || {
        warn "Could not create the scheduler's directories."
        return 1
    }
    _esw_dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    _esw_host="${_esw_dsn%%:*}"; _esw_port="${_esw_dsn##*:}"
    [ -n "$_esw_host" ] || _esw_host="127.0.0.1"
    case "$_esw_port" in ''|*[!0-9]*) _esw_port=8563 ;; esac
    _esw_pwfile="$EXAKIT_CREDS_DIR/exasol_scheduler_password"

    cat > "$EXAKIT_EXASOL_SCHEDULER_BIN" <<'EXAKIT_ES_EOF'
#!/bin/sh
# exasol-scheduler launcher — generated by the Exasol Personal Local Starter
# Kit; regenerated by `exakit update exasol-scheduler`. Supervises the
# scheduler engine: waits for the database, restarts the engine on failure
# (it exits on fatal errors by design), refuses a second copy (two pollers on
# one task table run every job twice), and stops on a crash loop.
PIDFILE="@PIDFILE@"
ENGINE="@ENGINE@"
LOG="@LOG@"

# Singleton guard: a live supervisor already owns the task table.
if [ -f "$PIDFILE" ]; then
    _pid="$(cat "$PIDFILE" 2>/dev/null)"
    case "$_pid" in
        ''|*[!0-9]*) ;;
        *) if kill -0 "$_pid" 2>/dev/null; then
               printf 'exasol-scheduler is already running (pid %s).\n' "$_pid"
               printf 'One instance per task table: a second poller would run every job twice.\n'
               printf 'State: exakit status   Logs: exakit logs exasol-scheduler -f   Stop: exakit stop\n'
               exit 0
           fi ;;
    esac
fi
printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null || true
trap 'rm -f "$PIDFILE"' EXIT
# A fresh start is a fresh chance: the give-up marker below only ever
# describes the CURRENT stretch of supervision.
rm -f "@GIVEUP@" 2>/dev/null || true

# The scheduler talks to the kit's local database over TLS with the
# deployment's self-signed certificate. Everything is a setdefault: anything
# the user exports themselves wins.
[ -n "${EXA_HOST:-}" ]                 || { EXA_HOST="@HOST@"; export EXA_HOST; }
[ -n "${EXA_PORT:-}" ]                 || { EXA_PORT="@PORT@"; export EXA_PORT; }
[ -n "${EXA_USER:-}" ]                 || { EXA_USER="@DBUSER@"; export EXA_USER; }
[ -n "${EXA_TLS:-}" ]                  || { EXA_TLS="true"; export EXA_TLS; }
[ -n "${EXA_VALIDATE_SERVER_CERT:-}" ] || { EXA_VALIDATE_SERVER_CERT="false"; export EXA_VALIDATE_SERVER_CERT; }
[ -n "${EXA_SCHEMA:-}" ]               || { EXA_SCHEMA="@SCHEMA@"; export EXA_SCHEMA; }
if [ -z "${EXA_PASSWORD:-}" ]; then
    if [ ! -r "@PWFILE@" ]; then
        printf 'exasol-scheduler: credential file missing or unreadable: @PWFILE@\n' >&2
        printf 'Repair with: exakit update exasol-scheduler\n' >&2
        exit 1
    fi
    EXA_PASSWORD="$(cat "@PWFILE@")"
    export EXA_PASSWORD
fi

# Wait for the database, bounded: at login the boot entries race, and the
# engine exits when the port is closed. curl exit 7 is "connection refused" -
# still booting; any other answer means something is listening.
_waited=0
while [ "$_waited" -lt 120 ]; do
    curl -sk --max-time 2 "https://$EXA_HOST:$EXA_PORT/" >/dev/null 2>&1
    [ $? -ne 7 ] && break
    sleep 3
    _waited=$((_waited + 3))
done

# Supervise: restart on failure with backoff, stop on a crash loop. Five
# failures inside a minute each means configuration, not weather - looping
# further would only fill the log.
_fails=0
while :; do
    _t0=$(date +%s 2>/dev/null || echo 0)
    "$ENGINE" "$@"
    _rc=$?
    [ "$_rc" -eq 0 ] && exit 0
    _t1=$(date +%s 2>/dev/null || echo 0)
    if [ $((_t1 - _t0)) -lt 60 ]; then
        _fails=$((_fails + 1))
    else
        _fails=1
    fi
    if [ "$_fails" -ge 5 ]; then
        printf 'exasol-scheduler: engine failed %s times in quick succession (last exit %s) - giving up.\n' "$_fails" "$_rc" >&2
        printf 'Diagnose with: exakit logs exasol-scheduler   then restart with: exakit start\n' >&2
        # The log line above is read by nobody whose jobs just stopped. The
        # marker is what makes `exakit status` say WHY the service is down
        # instead of a bare "stopped" that reads like a choice someone made.
        printf 'gave up after %s rapid failures (last exit %s) at %s\n' \
            "$_fails" "$_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" > "@GIVEUP@" 2>/dev/null || true
        exit "$_rc"
    fi
    printf 'exasol-scheduler: engine exited (%s) - restarting in 5s (attempt %s/5)\n' "$_rc" "$_fails" >&2
    sleep 5
done
EXAKIT_ES_EOF

    # The connection facts are baked in with a safe substitution; the heredoc
    # above is quoted so the credential read expands at RUN time.
    _esw_tmp="$EXAKIT_EXASOL_SCHEDULER_BIN.tmp.$$"
    sed -e "s|@PIDFILE@|$EXAKIT_EXASOL_SCHEDULER_PIDFILE|g" \
        -e "s|@GIVEUP@|$EXAKIT_EXASOL_SCHEDULER_HOME/gave-up|g" \
        -e "s|@ENGINE@|$(exasol_scheduler_engine_path)|g" \
        -e "s|@LOG@|$EXAKIT_EXASOL_SCHEDULER_LOG|g" \
        -e "s|@HOST@|$_esw_host|g" \
        -e "s|@PORT@|$_esw_port|g" \
        -e "s|@DBUSER@|$EXAKIT_EXASOL_SCHEDULER_USER|g" \
        -e "s|@SCHEMA@|$EXAKIT_EXASOL_SCHEDULER_SCHEMA|g" \
        -e "s|@PWFILE@|$_esw_pwfile|g" \
        "$EXAKIT_EXASOL_SCHEDULER_BIN" > "$_esw_tmp" && \
        mv "$_esw_tmp" "$EXAKIT_EXASOL_SCHEDULER_BIN"
    chmod 755 "$EXAKIT_EXASOL_SCHEDULER_BIN"
}

# --- install / validate / lifecycle -------------------------------------------

_exasol_scheduler_not_installed() {
    warn "exasol-scheduler was not installed: $1"
    warn "Everything else in the kit is unaffected. Retry with: exakit update exasol-scheduler"
    command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "exasol-scheduler: $1"
    manifest_set components.exasol_scheduler.validated false 2>/dev/null || true
    return 1
}

exasol_scheduler_install() {
    if ! exasol_scheduler_applicable; then
        _exasol_scheduler_not_installed "$(exasol_scheduler_applicable_reason)"
        return 1
    fi
    _esi_version="$(_exasol_scheduler_target_version)"
    _esi_current="$(exasol_scheduler_installed_version 2>/dev/null || true)"
    if [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && \
       [ -n "$_esi_current" ] && [ "$_esi_current" = "$_esi_version" ]; then
        ok "exasol-scheduler $_esi_current is already installed"
        return 0
    fi
    info "Installing exasol-scheduler $_esi_version (prebuilt — table-driven SQL job scheduling)"
    _esi_asset="$(exasol_scheduler_asset)"
    _esi_tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-scheduler.XXXXXX")" || {
        _exasol_scheduler_not_installed "could not create a temporary download directory"
        return 1
    }
    if ! _exasol_scheduler_fetch_verified "$_esi_asset" "$_esi_tmp/engine"; then
        rm -rf "$_esi_tmp"
        _exasol_scheduler_not_installed "the prebuilt scheduler binary ($_esi_asset) could not be downloaded or verified (see log). The release: $(exasol_scheduler_release_tag) in $(exasol_scheduler_mirror_repo)"
        return 1
    fi
    mkdir -p "$EXAKIT_EXASOL_SCHEDULER_HOME/libexec" 2>/dev/null || {
        rm -rf "$_esi_tmp"
        _exasol_scheduler_not_installed "could not create $EXAKIT_EXASOL_SCHEDULER_HOME"
        return 1
    }
    install -m 755 "$_esi_tmp/engine" "$(exasol_scheduler_engine_path)" || {
        rm -rf "$_esi_tmp"
        _exasol_scheduler_not_installed "could not install the engine to $(exasol_scheduler_engine_path)"
        return 1
    }
    rm -rf "$_esi_tmp"
    # The engine must at least run on this machine before a database user is
    # created for it.
    if ! "$(exasol_scheduler_engine_path)" --help >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        _exasol_scheduler_not_installed "the prebuilt engine does not run on this machine (see log)"
        return 1
    fi
    if ! _exasol_scheduler_ensure_db_user; then
        _exasol_scheduler_not_installed "the dedicated database user could not be created — is the database running? (exakit start)"
        return 1
    fi
    exasol_scheduler_write_launcher || {
        _exasol_scheduler_not_installed "the launcher could not be written"
        return 1
    }
    manifest_set components.exasol_scheduler.version "$_esi_version"
    manifest_set components.exasol_scheduler.engine "$(exasol_scheduler_engine_path)"
    manifest_set components.exasol_scheduler.db_user "$EXAKIT_EXASOL_SCHEDULER_USER"
    manifest_set components.exasol_scheduler.schema "$EXAKIT_EXASOL_SCHEDULER_SCHEMA"
    manifest_set components.exasol_scheduler.bootstrap_revoked false
    ok "exasol-scheduler $_esi_version installed"
    return 0
}

# exasol_scheduler_validate — prove the pieces work TOGETHER: start the
# service, wait for the schema the engine bootstraps on first startup, then
# revoke the bootstrap privileges upstream says to revoke. A validate that
# only checked files would happily bless a scheduler that cannot reach its
# own database.
exasol_scheduler_validate() {
    [ -x "$(exasol_scheduler_engine_path)" ] || {
        warn "exasol-scheduler is not installed."
        return 1
    }
    exasol_scheduler_start || return 1
    _esv_waited=0
    info "Waiting for the scheduler to bootstrap its schema ($EXAKIT_EXASOL_SCHEDULER_SCHEMA)"
    while [ "$_esv_waited" -lt 60 ]; do
        if _exasol_scheduler_schema_exists; then
            _exasol_scheduler_revoke_bootstrap
            manifest_set components.exasol_scheduler.validated true
            ok "exasol-scheduler is running and its schema exists — define jobs in ${EXAKIT_EXASOL_SCHEDULER_SCHEMA}.SCHED_TASKS"
            return 0
        fi
        sleep 3
        _esv_waited=$((_esv_waited + 3))
    done
    warn "The scheduler is running but its schema has not appeared yet — check: exakit logs exasol-scheduler"
    return 1
}

exasol_scheduler_status() {
    if [ ! -x "$EXAKIT_EXASOL_SCHEDULER_BIN" ]; then
        printf '%s\n' "not installed"
        return 0
    fi
    if [ -n "$(_exasol_scheduler_pids)" ]; then
        printf '%s\n' "running"
        return 0
    fi
    # "stopped" reads like a choice someone made; a supervisor that gave up is
    # a different state and the row must say so, with the diagnosis one paste
    # away. Same posture as dash-server's "port held by another process" row.
    if [ -f "$EXAKIT_EXASOL_SCHEDULER_HOME/gave-up" ]; then
        printf 'stopped (%s — diagnose: exakit logs exasol-scheduler, restart: exakit start)\n' \
            "$(head -1 "$EXAKIT_EXASOL_SCHEDULER_HOME/gave-up" 2>/dev/null | cut -d' ' -f1-6)"
        return 0
    fi
    printf '%s\n' "stopped"
}

# The supervising launcher (whose pid the pidfile holds) plus any engine it
# started. The engine path is unique to this install, so pgrep never matches
# an unrelated process — the same posture as _dash_server_pids.
_exasol_scheduler_pids() {
    _esp_out=""
    if [ -f "$EXAKIT_EXASOL_SCHEDULER_PIDFILE" ]; then
        _esp_pid="$(cat "$EXAKIT_EXASOL_SCHEDULER_PIDFILE" 2>/dev/null)"
        case "$_esp_pid" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$_esp_pid" 2>/dev/null && _esp_out="$_esp_pid" ;;
        esac
    fi
    if command -v pgrep >/dev/null 2>&1; then
        for _esp_extra in $(pgrep -f "$(exasol_scheduler_engine_path)" 2>/dev/null); do
            case " $_esp_out " in
                *" $_esp_extra "*) ;;
                *) _esp_out="${_esp_out:+$_esp_out }$_esp_extra" ;;
            esac
        done
    fi
    printf '%s' "$_esp_out"
}

exasol_scheduler_start() {
    [ -x "$EXAKIT_EXASOL_SCHEDULER_BIN" ] || {
        warn "exasol-scheduler is not installed — add it with: exakit marketplace"
        return 1
    }
    if [ -n "$(_exasol_scheduler_pids)" ]; then
        ok "exasol-scheduler is already running"
        return 0
    fi
    mkdir -p "$EXAKIT_EXASOL_SCHEDULER_HOME" "$EXAKIT_LOG_DIR" 2>/dev/null || true
    rm -f "$EXAKIT_EXASOL_SCHEDULER_HOME/gave-up" 2>/dev/null || true
    info "Starting exasol-scheduler"
    nohup "$EXAKIT_EXASOL_SCHEDULER_BIN" >> "$EXAKIT_EXASOL_SCHEDULER_LOG" 2>&1 &
    disown 2>/dev/null || true
    sleep 2
    if [ -n "$(_exasol_scheduler_pids)" ]; then
        ok "exasol-scheduler is running (jobs live in ${EXAKIT_EXASOL_SCHEDULER_SCHEMA}.SCHED_TASKS)"
        return 0
    fi
    warn "exasol-scheduler did not stay up — see $(ui_tilde "$EXAKIT_EXASOL_SCHEDULER_LOG")"
    return 1
}

exasol_scheduler_stop() {
    _est_pids="$(_exasol_scheduler_pids)"
    if [ -z "$_est_pids" ]; then
        ok "exasol-scheduler is already stopped"
        rm -f "$EXAKIT_EXASOL_SCHEDULER_PIDFILE" 2>/dev/null || true
        return 0
    fi
    info "Stopping exasol-scheduler"
    for _est_pid in $_est_pids; do
        pkill -P "$_est_pid" 2>/dev/null
        kill "$_est_pid" 2>/dev/null
    done
    sleep 1
    for _est_pid in $(_exasol_scheduler_pids); do
        pkill -9 -P "$_est_pid" 2>/dev/null
        kill -9 "$_est_pid" 2>/dev/null
    done
    rm -f "$EXAKIT_EXASOL_SCHEDULER_PIDFILE" 2>/dev/null || true
    ok "exasol-scheduler stopped (missed occurrences are not replayed on restart — upstream computes the next run from the current clock)"
}

exasol_scheduler_autostart_command() {
    printf '%s\n' "$EXAKIT_EXASOL_SCHEDULER_BIN"
}

exasol_scheduler_summary() {
    printf 'SQL jobs in %s.SCHED_TASKS\n' "$EXAKIT_EXASOL_SCHEDULER_SCHEMA"
}

# exasol_scheduler_uninstall [dry] — remove what the INSTALL put on this
# machine: the engine, the launcher, the pidfile, the credential, the
# database user, the manifest record. The SCHED schema — task definitions and
# execution history — is the USER'S data and is deliberately left, and the
# farewell says so rather than leaving them to wonder.
exasol_scheduler_uninstall() {
    _esu_dry="${1:-0}"
    if [ "$_esu_dry" != "1" ]; then
        exasol_scheduler_stop >/dev/null 2>&1 || true
    fi
    for _esu_path in "$EXAKIT_EXASOL_SCHEDULER_HOME" "$EXAKIT_EXASOL_SCHEDULER_BIN" \
                     "$EXAKIT_CREDS_DIR/exasol_scheduler_password"; do
        [ -e "$_esu_path" ] || continue
        if [ "$_esu_dry" = "1" ]; then
            info "  will remove: $_esu_path"
        else
            info "Removing $_esu_path"
            rm -rf "$_esu_path"
        fi
    done
    if [ "$_esu_dry" = "1" ]; then
        info "  will drop:   database user $EXAKIT_EXASOL_SCHEDULER_USER (the ${EXAKIT_EXASOL_SCHEDULER_SCHEMA} schema and its history stay — they are your data)"
        return 0
    fi
    # The user is kit-created and its credential is being deleted; leaving it
    # would strand an account nobody can log into. The schema it bootstrapped
    # holds the user's job definitions and audit history, so that stays.
    _exasol_scheduler_sql "DROP USER $(_exasol_scheduler_identifier_user)" 2>/dev/null || true
    manifest_del components.exasol_scheduler
    manifest_del desired.exasol_scheduler
    ok_step "exasol-scheduler removed — the ${EXAKIT_EXASOL_SCHEDULER_SCHEMA} schema (your job definitions and history) was left in the database. Reinstall any time with: exakit marketplace"
    return 0
}

exasol_scheduler_update() {
    _esu_available="$(exakit_component_available exasol-scheduler 2>/dev/null || true)"
    [ -n "$_esu_available" ] || die "Could not resolve the advertised exasol-scheduler version."
    _esu_current="$(exasol_scheduler_installed_version 2>/dev/null || true)"
    if [ -n "$_esu_current" ] && [ "$_esu_current" = "$_esu_available" ]; then
        # Same version can still need repair: regenerate the launcher so a
        # DSN or credential change since the install is picked up.
        exasol_scheduler_write_launcher >/dev/null 2>&1 || true
        ok "exasol-scheduler is already current ($_esu_current)"
        return 0
    fi
    info "Updating exasol-scheduler ${_esu_current:-not installed} -> $_esu_available"
    _esu_was_running=0
    [ -n "$(_exasol_scheduler_pids)" ] && _esu_was_running=1
    # A running engine would keep executing with the old binary; the pidfile
    # guard would also refuse validate's restart.
    [ "$_esu_was_running" = "1" ] && exasol_scheduler_stop >/dev/null 2>&1
    EXAKIT_EXASOL_SCHEDULER_VERSION="$_esu_available"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_EXASOL_SCHEDULER_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    if ! exasol_scheduler_install; then
        die "exasol-scheduler could not be installed — see the warning above and ${EXAKIT_LOG_FILE:-the log}."
    fi
    # Validate after a FRESH install too, not only when the service was
    # running before: validate is what starts the service, waits for the
    # schema bootstrap, and revokes the bootstrap privileges - `exakit update
    # exasol-scheduler` is the documented repair path after a failed
    # marketplace install, and a repair that leaves CREATE SCHEMA granted
    # forever repaired nothing. Only a same-version refresh skips it.
    if [ "$_esu_was_running" = "1" ] || [ -z "$_esu_current" ]; then
        exasol_scheduler_validate || true
    fi
    manifest_set desired.exasol_scheduler "$EXAKIT_EXASOL_SCHEDULER_VERSION"
    ok "exasol-scheduler updated; your job definitions and history were not changed"
}
