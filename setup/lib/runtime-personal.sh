#!/usr/bin/env bash
# runtime-personal.sh — Exasol Personal local runtime module (macOS).
#
# Sourced by setup scripts after common.sh and detect.sh. Installs the Exasol
# launcher from the resolved GitHub release (checksum-verified) and deploys a
# local database with `exasol install local`.
#
# Launcher facts:
#   - release assets: exasol-personal_macOS_{arm64,x86_64}.tar.gz + checksums
#   - local deployment needs macOS with at least 8 GB RAM
#   - deployment state: ~/.exasol/personal/deployments/default
#   - `exasol info` prints connection details for the current deployment
#   - rerunning `exasol install local` with the same preset is safe

EXAKIT_PERSONAL_PORT=8563
EXAKIT_PERSONAL_MIN_RAM_GB="${EXAKIT_PERSONAL_MIN_RAM_GB:-8}"
EXAKIT_PERSONAL_MIN_DISK_GB="${EXAKIT_PERSONAL_MIN_DISK_GB:-20}"
EXAKIT_PERSONAL_BIN="$EXAKIT_BIN_DIR/exasol"
EXAKIT_PERSONAL_DEPLOY_DIR="${EXAKIT_PERSONAL_DEPLOY_DIR:-$HOME/.exasol/personal/deployments/default}"

# personal_check_requirements — the compatibility gate. Incompatible machines
# get a clear explanation and a graceful exit; machines at the bare minimum
# proceed with an explicit warning; comfortable machines get one quiet OK line.
# (Replaces the old "Detected environment" panel: users don't act on a table of
# facts — they act on "this will/won't work and why".)
EXAKIT_PERSONAL_COMFORT_RAM_GB="${EXAKIT_PERSONAL_COMFORT_RAM_GB:-12}"
EXAKIT_PERSONAL_COMFORT_DISK_GB="${EXAKIT_PERSONAL_COMFORT_DISK_GB:-40}"
personal_check_requirements() {
    if [ "$(detect_os)" != "macos" ]; then
        error "This machine is not compatible: the Exasol Personal local deployment is macOS-only in this kit."
        info "On Linux/WSL use the Linux installer (Exasol Nano via Docker/Podman); on Windows use install.ps1."
        die "Incompatible platform: $(detect_os)."
    fi

    _arch="$(detect_arch)"
    if [ "$_arch" = "unsupported" ]; then
        error "This machine is not compatible: no Exasol Personal build exists for the '$(uname -m)' CPU architecture."
        info "Supported architectures: Apple Silicon (arm64) and Intel (x86_64)."
        die "Incompatible CPU architecture: $(uname -m)."
    fi

    _ram="$(detect_ram_gb)"
    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        if [ "$_ram" -eq 0 ]; then
            die "Could not determine this machine's memory. Fix the environment or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_ram" -lt "$EXAKIT_PERSONAL_MIN_RAM_GB" ]; then
            error "This machine is not compatible: Exasol Personal needs at least ${EXAKIT_PERSONAL_MIN_RAM_GB} GB RAM and this machine has ${_ram} GB."
            info "Nothing was installed. Re-run on a machine with ${EXAKIT_PERSONAL_MIN_RAM_GB}+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient memory: ${_ram} GB."
        fi
        if [ "$_disk" -eq 0 ]; then
            die "Could not determine free disk space at $HOME. Free up space or set EXAKIT_FORCE=1 to install anyway."
        fi
        if [ "$_disk" -lt "$EXAKIT_PERSONAL_MIN_DISK_GB" ]; then
            error "This machine is not compatible right now: the deployment needs at least ${EXAKIT_PERSONAL_MIN_DISK_GB} GB free disk and $HOME has ${_disk} GB."
            info "Nothing was installed. Free up disk space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient free disk space: ${_disk} GB."
        fi
    fi

    # Bare minimum: run, but say what to expect.
    if [ "$_ram" -lt "$EXAKIT_PERSONAL_COMFORT_RAM_GB" ]; then
        warn "Memory is at the bare minimum (${_ram} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_RAM_GB}+ GB) — the database will run, but expect slower queries and keep other heavy apps closed."
    fi
    if [ "$_disk" -lt "$EXAKIT_PERSONAL_COMFORT_DISK_GB" ]; then
        warn "Free disk is tight (${_disk} GB; comfortable: ${EXAKIT_PERSONAL_COMFORT_DISK_GB}+ GB) — fine for the bundled datasets, but watch space before loading large files."
    fi
    ok "Compatibility check passed (macOS $_arch, ${_ram} GB RAM, ${_disk} GB free)"
}

personal_asset_name() {
    case "$(detect_arch)" in
        arm64)  echo "exasol-personal_macOS_arm64.tar.gz" ;;
        x86_64) echo "exasol-personal_macOS_x86_64.tar.gz" ;;
    esac
}

personal_release_url() {
    echo "https://github.com/${EXAKIT_PERSONAL_REPO}/releases/download/v${EXAKIT_PERSONAL_VERSION}"
}

# personal_install_launcher — download, verify, and install the `exasol` CLI.
# An already-installed launcher is only accepted if it supports the 'local'
# preset (older releases do not); otherwise the resolved version is installed
# alongside it and preferred.
personal_install_launcher() {
    if [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ] && command -v exasol >/dev/null 2>&1; then
        _existing="$(command -v exasol)"
        if "$_existing" install --help 2>/dev/null | grep -w "local" >/dev/null; then
            ok "Exasol launcher already installed: $_existing"
            return 0
        fi
        warn "The installed Exasol launcher ($_existing) does not support the 'local' preset (too old)."
        info "Installing launcher v${EXAKIT_PERSONAL_VERSION} to $EXAKIT_PERSONAL_BIN — your existing launcher is left untouched"
    fi

    _asset="$(personal_asset_name)"
    _base="$(personal_release_url)"
    _tmp="$(mktemp -d "${TMPDIR:-/tmp}/exakit-personal.XXXXXX")"

    info "Downloading Exasol launcher v${EXAKIT_PERSONAL_VERSION} ($_asset)"
    fetch "$_base/$_asset" "$_tmp/$_asset"
    fetch "$_base/exasol-personal_${EXAKIT_PERSONAL_VERSION}_checksums.txt" "$_tmp/checksums.txt"
    verify_sha256_from_file "$_tmp/$_asset" "$_tmp/checksums.txt"

    info "Installing launcher to $EXAKIT_PERSONAL_BIN"
    mkdir -p "$EXAKIT_BIN_DIR"
    run_logged tar -xzf "$_tmp/$_asset" -C "$_tmp" || die "Could not extract $_asset"
    _binary="$(find "$_tmp" -name exasol -type f | head -1)"
    [ -n "$_binary" ] || die "The release archive did not contain an 'exasol' binary"
    install -m 755 "$_binary" "$EXAKIT_PERSONAL_BIN" \
        || die "Could not install the Exasol launcher to $EXAKIT_PERSONAL_BIN (is it writable? is the disk full?)."
    push_rollback "rm -f \"$EXAKIT_PERSONAL_BIN\""
    rm -rf "$_tmp"

    ensure_path_hint "$EXAKIT_BIN_DIR"
    ok "Launcher installed: $EXAKIT_PERSONAL_BIN"
}

personal_cli() {
    # Prefer the kit-installed managed launcher; fall back to one on PATH.
    if [ -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "$EXAKIT_PERSONAL_BIN"
    elif command -v exasol >/dev/null 2>&1; then
        command -v exasol
    else
        echo "$EXAKIT_PERSONAL_BIN"
    fi
}

personal_deployment_exists() {
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] && "$(personal_cli)" info >/dev/null 2>&1
}

# personal_deployment_running — is a local Exasol deployment actually up and
# reachable right now? Some launcher versions can answer `exasol info` even
# before the SQL listener exists, so require both signals before reusing an
# existing database.
personal_deployment_running() {
    port_in_use "$EXAKIT_PERSONAL_PORT" && "$(personal_cli)" info >/dev/null 2>&1
}

# personal_db_port_pids — PIDs currently LISTENing on the deployment port.
personal_db_port_pids() {
    command -v lsof >/dev/null 2>&1 || return 0
    lsof -nP -iTCP:"$EXAKIT_PERSONAL_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u
}

# personal_is_orphan_daemon PID — true only if PID is an Exasol Personal runner
# daemon (the "mac-runner ... __daemon__" forwarder). Scopes cleanup so we never
# kill an unrelated application that happens to hold the port.
personal_is_orphan_daemon() {
    case "$(ps -p "$1" -o command= 2>/dev/null || true)" in
        *mac-runner*__daemon__*) return 0 ;;
        *) return 1 ;;
    esac
}

# personal_reap_orphan_daemon — the Exasol Personal launcher can leave an
# orphaned "mac-runner ... __daemon__" process bound to the database port after
# a failed deploy, or after a destroy that could not find its PID file (it logs
# "VM is not running (no PID file found)"). The orphan then makes the next
# deploy fail with "bind: operation not permitted" on vm.sock and makes MCP
# clients see "Connection reset by peer". Reap only that specific daemon; a
# genuinely foreign process on the port is reported and left untouched.
# Returns 0 if the port ends up free (or was never held), 1 otherwise.
personal_reap_orphan_daemon() {
    # Judge the port by whether a process is actually LISTENing on it, not by a
    # bare TCP connect: after a teardown, client sockets linger in
    # CLOSE_WAIT/TIME_WAIT and would make a connect test wrongly report "in use".
    if ! command -v lsof >/dev/null 2>&1; then
        if port_in_use "$EXAKIT_PERSONAL_PORT"; then
            warn "Port $EXAKIT_PERSONAL_PORT is in use but 'lsof' is unavailable to identify the process; cannot auto-clean a leftover Exasol daemon."
            return 1
        fi
        return 0
    fi

    _listeners="$(personal_db_port_pids)"
    [ -n "$_listeners" ] || return 0   # nothing listening → port is free

    _reaped=""
    for _pid in $_listeners; do
        if personal_is_orphan_daemon "$_pid"; then
            info "Reaping orphaned Exasol runner daemon (pid $_pid) still holding port $EXAKIT_PERSONAL_PORT"
            pkill -P "$_pid" 2>/dev/null || true
            kill "$_pid" 2>/dev/null || true
            _reaped="$_reaped $_pid"
        else
            warn "Port $EXAKIT_PERSONAL_PORT is held by a non-Exasol process (pid $_pid: $(ps -p "$_pid" -o command= 2>/dev/null | cut -c1-80)); leaving it untouched."
        fi
    done

    # Only a foreign listener remains (nothing of ours to reap) → not our port.
    [ -n "$_reaped" ] || return 1

    # Wait for the listener to release the port (SIGTERM path, up to ~5s), then
    # force-kill any survivor and its children and give it a moment to settle.
    _waited=0
    while [ "$_waited" -lt 5 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done
    for _pid in $_reaped; do
        if kill -0 "$_pid" 2>/dev/null; then
            pkill -9 -P "$_pid" 2>/dev/null || true
            kill -9 "$_pid" 2>/dev/null || true
        fi
    done
    _waited=0
    while [ "$_waited" -lt 3 ] && [ -n "$(personal_db_port_pids)" ]; do
        sleep 1
        _waited=$((_waited + 1))
    done

    if [ -n "$(personal_db_port_pids)" ]; then
        warn "Port $EXAKIT_PERSONAL_PORT still has a listening process after reaping the Exasol daemon."
        return 1
    fi
    ok "Freed port $EXAKIT_PERSONAL_PORT (removed a leftover Exasol runner daemon)"
    return 0
}

# personal_deploy_local — run the local deployment. This is the long step
# (usually under 2 minutes); output stays visible and is logged.
personal_deploy_local() {
    # A reachable Exasol is already up (this run, a previous run, or the user
    # started it by hand). `exasol info` is the launcher's own health signal.
    # Checked BEFORE the port test below so a healthy database that legitimately
    # owns port 8563 is offered for reuse rather than reported as a conflict.
    # Ask before adopting it — a piped/non-interactive install defaults to yes
    # (reuse), which is the safe, idempotent choice for automation. Set
    # EXAKIT_REUSE_DB=0 to force a fresh deployment, =1 to reuse without asking.
    if personal_deployment_running; then
        info "An Exasol database is already running and reachable on port $EXAKIT_PERSONAL_PORT."
        if confirm_env EXAKIT_REUSE_DB "Use the running database instead of deploying a new one?" y; then
            ok "Reusing the existing Exasol deployment"
            personal_record_manifest
            return 0
        fi
        die "Declined to reuse the running database. Stop it first ('exakit stop', or 'exasol stop'), then re-run to deploy a fresh one — port $EXAKIT_PERSONAL_PORT stays in use while it is running."
    fi

    # A deployment exists but is not running — cleanly stopped, or a crashed
    # VM. The launcher refuses `install local` over a stopped deployment
    # ("run `start` to restart or `destroy` to delete resources"), so
    # deploying here would dead-end. Adopt it the way a running one is
    # adopted: start it and reuse. A piped/non-interactive install defaults
    # to yes (reuse); EXAKIT_REUSE_DB=0 rebuilds fresh instead, destroying
    # the old deployment's data. A deployment that will not start (a crashed
    # VM) is replaced — announced, never silently.
    if personal_deployment_exists; then
        info "An existing Exasol deployment was found (not running)."
        if confirm_env EXAKIT_REUSE_DB "Start and reuse the existing database instead of deploying a new one?" y; then
            if personal_launcher_supports start && run_logged "$(personal_cli)" start; then
                ok "Reusing the existing Exasol deployment (started)"
                personal_wait_ready
                personal_record_manifest
                return 0
            fi
            warn "The existing deployment could not be started."
        fi
        info "Replacing the existing deployment — its previous data is not recoverable."
        # --auto-approve: destroy has its own [y/N] prompt, which a piped or
        # scripted install cannot answer; the consent came from the reuse
        # question (or EXAKIT_REUSE_DB=0) just above.
        run_logged "$(personal_cli)" destroy --remove --auto-approve || \
            warn "Could not fully remove the old deployment; the launcher will deploy over it."
    fi

    # Port busy but the launcher sees no reachable deployment on it. This is
    # usually our own orphaned runner daemon from a failed deploy or destroy —
    # reap it and continue. Only a genuinely foreign process (another database,
    # a stale container), which the reaper leaves untouched, is a hard stop.
    # EXAKIT_DB_PORT does not apply to the macOS path, so name the real port.
    if port_in_use "$EXAKIT_PERSONAL_PORT"; then
        personal_reap_orphan_daemon || \
            die "Port $EXAKIT_PERSONAL_PORT is in use by a process that is not a reachable Exasol Personal deployment. Stop that application and re-run (EXAKIT_DB_PORT does not apply to the macOS deployment)."
    fi

    info "Deploying Exasol Personal locally — super quick !"
    push_rollback "$(personal_cli) destroy --remove --auto-approve || true"
    # The launcher prints its own (verbose) output; contain it in a dim gutter so
    # it reads as "not ours", while the full text still lands in the log.
    foreign_note "exasol launcher output"
    "$(personal_cli)" install local 2>&1 | exakit_stream_foreign
    _deploy_rc=${PIPESTATUS[0]}
    foreign_note "launcher finished"
    [ "$_deploy_rc" -eq 0 ] || die "Local deployment failed. Re-running the installer retries it safely."

    personal_wait_ready
    personal_record_manifest
}

personal_wait_ready() {
    info "Checking deployment health"
    _tries=0
    while [ "$_tries" -lt 30 ]; do
        if port_in_use "$EXAKIT_PERSONAL_PORT" && "$(personal_cli)" info >/dev/null 2>&1; then
            ok "Deployment is reachable"
            return 0
        fi
        sleep 5
        _tries=$((_tries + 1))
    done
    die "Deployment does not respond to 'exasol info'. Check: $(personal_cli) info"
}

personal_record_manifest() {
    manifest_set runtime.type "personal"
    manifest_set runtime.version "$EXAKIT_PERSONAL_VERSION"
    manifest_set runtime.launcher "$(personal_cli)"
    manifest_set runtime.deployment_dir "$EXAKIT_PERSONAL_DEPLOY_DIR"

    # The deployment directory has everything a client needs:
    #   deployment.json -> host, dbPort, username, cert-validation flag
    #   secrets.json    -> dbPassword
    _dep="$EXAKIT_PERSONAL_DEPLOY_DIR/deployment.json"
    _sec="$EXAKIT_PERSONAL_DEPLOY_DIR/secrets.json"
    if [ -f "$_dep" ]; then
        require_python3
        _conn="$(run_python -c '
import json, sys
doc = json.load(open(sys.argv[1]))
c = doc.get("connection", {})
print("%s:%s\t%s" % (c.get("host", "127.0.0.1"), c.get("dbPort", 8563), c.get("username", "sys")))
' "$_dep" 2>/dev/null)"
        _dsn="$(printf '%s' "$_conn" | cut -f1)"
        _user="$(printf '%s' "$_conn" | cut -f2)"
        # A corrupt/unreadable deployment.json must not record an empty DSN.
        manifest_set runtime.dsn "${_dsn:-127.0.0.1:${EXAKIT_PERSONAL_PORT}}"
        manifest_set runtime.user "${_user:-sys}"
    else
        manifest_set runtime.dsn "127.0.0.1:${EXAKIT_PERSONAL_PORT}"
        manifest_set runtime.user "sys"
    fi
    _password=""
    if [ -f "$_sec" ]; then
        _password="$(run_python -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dbPassword",""))' "$_sec" 2>/dev/null)"
    fi
    if [ -n "$_password" ]; then
        store_credential personal_sys_password "$_password"
        manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/personal_sys_password"
    else
        warn "Could not read the database password from the deployment secrets — the exapump profile and MCP configs will ask for it or need manual completion."
    fi
    manifest_set runtime.tls "self-signed"
    manifest_set runtime.status "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
personal_launcher_supports() {
    # No `grep -q` here: it exits at the first match and closes the pipe, the
    # launcher takes a SIGPIPE (141) writing the rest of its help, and the
    # dispatcher's `set -o pipefail` then fails the whole pipeline — making a
    # supported command look unsupported. Plain grep reads the full help.
    "$(personal_cli)" --help 2>&1 | grep -w "$1" >/dev/null
}

personal_status() {
    if ! command -v exasol >/dev/null 2>&1 && [ ! -x "$EXAKIT_PERSONAL_BIN" ]; then
        echo "not installed"
    elif personal_deployment_exists; then
        # `exasol info` answers even when the cluster is stopped — the SQL
        # port tells the truth about whether the database is actually up.
        if port_in_use "$EXAKIT_PERSONAL_PORT"; then
            echo "running"
        else
            echo "stopped"
        fi
    else
        echo "not deployed"
    fi
}

personal_start() {
    if personal_launcher_supports start; then
        run_logged "$(personal_cli)" start || die "Failed to start the deployment"
        ok "Deployment started"
    else
        info "This launcher version has no explicit start command."
        info "Check the deployment with: $(personal_cli) info"
    fi
}

personal_stop() {
    if personal_launcher_supports stop; then
        run_logged "$(personal_cli)" stop || die "Failed to stop the deployment"
        manifest_set runtime.status "stopped"
        ok "Deployment stopped"
    else
        info "This launcher version has no explicit stop command."
        info "To remove the deployment entirely use: exakit uninstall"
    fi
}

# personal_teardown [--data] — destroy the local deployment. An Exasol
# Personal deployment keeps runtime and data together, so removing it always
# deletes the database content; without --data we refuse instead of silently
# destroying data the documented contract says would be kept.
personal_teardown() {
    if [ "${1:-}" != "--data" ]; then
        warn "Exasol Personal keeps the runtime and the database content in one deployment — removing it deletes all data."
        info "Use 'exakit stop' to stop it without deleting, or 'exakit uninstall' to remove everything."
        return 1
    fi
    if personal_deployment_exists; then
        info "Destroying the local Exasol Personal deployment"
        # --auto-approve: the launcher's 'destroy' prompts for confirmation by
        # default. run_logged sends its output to the log, so that prompt is
        # invisible and the install just hangs forever waiting for input. The
        # user has already confirmed at the exakit uninstall level.
        run_logged "$(personal_cli)" destroy --remove --auto-approve || warn "Destroy reported errors (see log)"
    else
        info "No active deployment found"
    fi
    # The launcher's destroy can leave an orphaned runner daemon bound to the
    # port when it cannot locate the daemon PID. Reap it unconditionally (even
    # when no deployment was found above, the orphan can outlive the deployment
    # dir) so a future deploy and MCP clients get a clean port.
    personal_reap_orphan_daemon || \
        warn "Could not fully free port $EXAKIT_PERSONAL_PORT; if a later deploy fails to bind it, stop the leftover process holding that port and retry."
    manifest_set runtime.status "removed"
}

personal_upgrade_plan() {
    _current="$1"
    _latest="$2"
    warn "Exasol Personal major upgrade detected: ${_current:-unknown} -> $_latest."
    warn "Personal keeps runtime and database content together in the local deployment."
    info "No destructive action was taken."
    info "Deployment: $EXAKIT_PERSONAL_DEPLOY_DIR"
    info "Step 1: exakit update personal --backup"
    info "Step 2: follow the Exasol Personal $_latest migration/redeployment guidance for your data."
    info "Step 3: exakit update personal --apply"
}

personal_upgrade_backup() {
    _current="$1"
    _latest="$2"
    require_cmd tar "tar"
    [ -d "$EXAKIT_PERSONAL_DEPLOY_DIR" ] || \
        die "No Exasol Personal deployment directory found at $EXAKIT_PERSONAL_DEPLOY_DIR; nothing was backed up."
    if [ "$(personal_status 2>/dev/null || true)" = "running" ] && [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        die "Stop Exasol Personal before backing up for a major upgrade: exakit stop"
    fi

    _backup_dir="$EXAKIT_HOME/backups"
    mkdir -p "$_backup_dir"
    chmod 700 "$_backup_dir" 2>/dev/null || true
    _stamp="$(date +%Y%m%d-%H%M%S)"
    _safe_current="$(printf '%s' "${_current:-unknown}" | tr '/ :' '---')"
    _safe_latest="$(printf '%s' "${_latest:-unknown}" | tr '/ :' '---')"
    _backup="$_backup_dir/personal-upgrade-${_safe_current}-to-${_safe_latest}-${_stamp}.tar.gz"
    _parent="$(dirname "$EXAKIT_PERSONAL_DEPLOY_DIR")"
    _base="$(basename "$EXAKIT_PERSONAL_DEPLOY_DIR")"

    info "Creating Exasol Personal deployment backup"
    if ! tar -czf "$_backup" -C "$_parent" "$_base" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        rm -f "$_backup"
        die "Could not create the Personal backup; no update was applied."
    fi
    chmod 600 "$_backup" 2>/dev/null || true
    if exakit_can_run_python; then
        manifest_set backups.personal_upgrade.latest "$_backup"
        manifest_set backups.personal_upgrade.created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        manifest_set backups.personal_upgrade.from "${_current:-unknown}"
        manifest_set backups.personal_upgrade.to "$_latest"
    else
        warn "Backup was created, but the manifest could not be updated because no Python runtime is available."
    fi
    ok "Personal deployment backup created: $_backup"
}

personal_update() {
    _mode="default"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --plan) _mode="plan" ;;
            --backup) _mode="backup" ;;
            --apply) _mode="apply" ;;
            *) die "Unknown option '$1' for 'exakit update personal'." ;;
        esac
        shift
    done

    _latest="$(exakit_component_latest personal)"
    [ -n "$_latest" ] || die "Could not resolve the latest Exasol Personal release."
    _current="$(manifest_get runtime.version 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "Exasol Personal launcher is already current ($_current)"
        return 0
    fi

    _current_major="$(exakit_major_version "$_current")"
    _latest_major="$(exakit_major_version "$_latest")"
    if [ -n "$_current_major" ] && [ -n "$_latest_major" ] && [ "$_current_major" != "$_latest_major" ]; then
        case "$_mode" in
            plan|default)
                personal_upgrade_plan "$_current" "$_latest"
                [ "$_mode" = "plan" ] && return 0
                return 1
                ;;
            backup)
                personal_upgrade_plan "$_current" "$_latest"
                personal_upgrade_backup "$_current" "$_latest"
                return 0
                ;;
            apply)
                _last_backup="$(manifest_get backups.personal_upgrade.latest 2>/dev/null || true)"
                _backup_from="$(manifest_get backups.personal_upgrade.from 2>/dev/null || true)"
                _backup_to="$(manifest_get backups.personal_upgrade.to 2>/dev/null || true)"
                if [ -z "$_last_backup" ] || [ ! -f "$_last_backup" ]; then
                    die "Create a backup first: exakit update personal --backup"
                fi
                if [ "$_backup_from" != "${_current:-unknown}" ] || [ "$_backup_to" != "$_latest" ]; then
                    die "The latest recorded Personal backup does not match this upgrade (${_current:-unknown} -> $_latest). Run: exakit update personal --backup"
                fi
                info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
                EXAKIT_PERSONAL_VERSION="$_latest"
                EXAKIT_FORCE_COMPONENT_INSTALL=1
                export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
                rm -f "$EXAKIT_PERSONAL_BIN"
                personal_install_launcher
                manifest_set runtime.launcher "$(personal_cli)"
                manifest_set runtime.launcher_version "$EXAKIT_PERSONAL_VERSION"
                manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
                warn "Launcher updated. Existing database content was not deleted or migrated."
                info "Complete the Exasol Personal $_latest data migration before recording runtime.version as $_latest."
                ok "Exasol Personal launcher update applied with backup available at $_last_backup"
                return 0
                ;;
        esac
    fi

    info "Updating Exasol Personal launcher ${_current:-unknown} -> $_latest"
    EXAKIT_PERSONAL_VERSION="$_latest"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_PERSONAL_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    rm -f "$EXAKIT_PERSONAL_BIN"
    personal_install_launcher
    personal_record_manifest
    manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
    ok "Exasol Personal launcher updated; deployment data was not changed"
}
