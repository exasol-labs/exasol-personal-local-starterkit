#!/usr/bin/env bash
# runtime-nano.sh — Exasol Nano container runtime module (Linux, WSL, Windows).
#
# Sourced by setup scripts after common.sh and detect.sh. Runs the resolved
# exasol/nano image tag under Docker (preferred) or Podman (fallback), with:
#   - a persistent named volume for /exa (database state survives restarts)
#   - the SQL port bound to localhost only
#   - a generated SYS password injected on first deployment via secret mount
#
# Container contract (from the image documentation):
#   - readiness: logs print "Database is now up and running!"
#   - connection: 127.0.0.1:8563, user sys, TLS (self-signed certificate)
#   - recommended limits: --shm-size=512mb --pids-limit=-1

EXAKIT_NANO_CONTAINER="${EXAKIT_NANO_CONTAINER:-exasol-nano}"
EXAKIT_NANO_VOLUME="${EXAKIT_NANO_VOLUME:-exasol-nano-data}"
EXAKIT_NANO_MIN_RAM_GB="${EXAKIT_NANO_MIN_RAM_GB:-4}"
EXAKIT_NANO_READY_TIMEOUT="${EXAKIT_NANO_READY_TIMEOUT:-600}"
# Minimal image used only for the self-repair of root-owned state leftovers
# (see nano_repair_creds); pulled on demand, never on the happy path.
EXAKIT_NANO_REPAIR_IMAGE="${EXAKIT_NANO_REPAIR_IMAGE:-docker.io/library/busybox:stable}"

# nano_engine — the usable container engine, cached after first call.
nano_engine() {
    if [ -z "${EXAKIT_NANO_ENGINE:-}" ]; then
        EXAKIT_NANO_ENGINE="$(detect_container_runtime)"
    fi
    echo "$EXAKIT_NANO_ENGINE"
}

# nano_resolve_names — lifecycle commands must act on the names the install
# actually used (recorded in the manifest), not on this shell's defaults.
# An explicit environment override still wins.
nano_resolve_names() {
    if [ "$EXAKIT_NANO_CONTAINER" = "exasol-nano" ]; then
        _mc="$(manifest_get runtime.container 2>/dev/null)"
        [ -n "$_mc" ] && EXAKIT_NANO_CONTAINER="$_mc"
    fi
    if [ "$EXAKIT_NANO_VOLUME" = "exasol-nano-data" ]; then
        _mv="$(manifest_get runtime.volume 2>/dev/null)"
        [ -n "$_mv" ] && EXAKIT_NANO_VOLUME="$_mv"
    fi
}

nano_check_requirements() {
    [ "$(detect_arch)" != "unsupported" ] || \
        die "Unsupported CPU architecture: $(uname -m). Exasol Nano images exist for x86_64 and arm64 only."

    _engine="$(detect_container_runtime_detail)"
    case "$_engine" in
        docker|podman)
            ok "Container runtime: $_engine"
            ;;
        docker-permission)
            # The daemon is up — the USER cannot reach the socket (classic
            # fresh-Linux state: not in the docker group). Say exactly that;
            # "unreachable, start Docker" would send them in circles, and
            # sudo'ing the installer is not the fix (it must run as the user).
            error "Docker is running, but this user is not allowed to use it (permission denied on the Docker socket)."
            printf '    Your user is not in the docker group. Fix it and re-run this installer:\n' >&2
            printf '      1. sudo usermod -aG docker $USER\n' >&2
            printf '      2. log out and back in (or run: newgrp docker)\n' >&2
            printf '      3. confirm it works without sudo: docker ps\n' >&2
            printf '    Do not run this installer with sudo — it must run as your normal user.\n' >&2
            die "No usable container runtime — fix the Docker socket permission, then re-run."
            ;;
        docker-stopped)
            # Docker's CLI is present but its daemon did not respond. Podman was
            # already tried as the fallback (detect_container_runtime checks it
            # second), so tell the user the whole picture: what failed, what was
            # tried, and how to fix either one.
            if command -v podman >/dev/null 2>&1; then
                _podman_hint="Podman was tried as a fallback, but its machine/service is not running either."
                _podman_fix="start it: podman machine start (or: sudo systemctl start podman)"
            else
                _podman_hint="Podman was tried as a fallback, but it is not installed."
                _podman_fix="install it (https://podman.io/docs/installation), then re-run"
            fi
            if wsl_docker_desktop_on_windows; then
                error "Docker is installed but unreachable: Docker Desktop is running on Windows, but it is not connected to this WSL distro."
                printf '    %s\n' "$_podman_hint" >&2
                printf '    Fix either runtime and re-run this installer:\n' >&2
                printf '      Docker:  Docker Desktop > Settings > Resources > WSL integration >\n' >&2
                printf '               turn on this distro, then click Apply & restart\n' >&2
                printf '      Podman:  %s\n' "$_podman_fix" >&2
                die "No usable container runtime — connect Docker Desktop to this distro or provide Podman, then re-run."
            fi
            error "Docker is installed but unreachable (its daemon did not respond)."
            printf '    %s\n' "$_podman_hint" >&2
            printf '    Fix either runtime and re-run this installer:\n' >&2
            printf '      Docker:  start it (e.g. open Docker Desktop, or: sudo systemctl start docker)\n' >&2
            printf '      Podman:  %s\n' "$_podman_fix" >&2
            die "No usable container runtime — start Docker or provide Podman, then re-run."
            ;;
        podman-stopped)
            error "Podman is installed but its machine/service is not running (Docker was not found)."
            printf '    Fix either runtime and re-run this installer:\n' >&2
            printf '      Podman:  podman machine start (or: sudo systemctl start podman)\n' >&2
            printf '      Docker:  install it (https://docs.docker.com/get-docker/)\n' >&2
            die "No usable container runtime — start Podman or install Docker, then re-run."
            ;;
        none)
            error "No container runtime found. Exasol Nano needs Docker or Podman."
            printf '    Install one of:\n' >&2
            printf '      Docker:  https://docs.docker.com/get-docker/\n' >&2
            printf '      Podman:  https://podman.io/docs/installation\n' >&2
            die "Install a container runtime and re-run this script."
            ;;
    esac

    _ram="$(detect_ram_gb)"
    if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        if [ "$_ram" -eq 0 ]; then
            die "Could not determine this machine's memory. Fix the environment or set EXAKIT_FORCE=1 to install anyway."
        elif [ "$_ram" -lt "$EXAKIT_NANO_MIN_RAM_GB" ]; then
            error "This machine is not compatible: Exasol Nano needs at least ${EXAKIT_NANO_MIN_RAM_GB} GB RAM and this machine has ${_ram} GB."
            info "Nothing was installed. Re-run on a machine with ${EXAKIT_NANO_MIN_RAM_GB}+ GB RAM (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient memory: ${_ram} GB."
        fi
    fi

    _disk="$(detect_free_disk_gb "$HOME")"
    if [ "${EXAKIT_FORCE:-0}" != "1" ]; then
        if [ "$_disk" -eq 0 ]; then
            die "Could not determine free disk space at $HOME. Free up space or set EXAKIT_FORCE=1 to install anyway."
        elif [ "$_disk" -lt 10 ]; then
            error "This machine is not compatible right now: the database image and data need at least 10 GB free disk and $HOME has ${_disk} GB."
            info "Nothing was installed. Free up disk space and re-run (or force at your own risk with EXAKIT_FORCE=1)."
            die "Insufficient free disk space: ${_disk} GB."
        fi
    fi

    # Bare minimum: run, but say what to expect.
    if [ "$_ram" -lt $((EXAKIT_NANO_MIN_RAM_GB + 2)) ]; then
        warn "Memory is at the bare minimum (${_ram} GB) — the database will run, but expect slower queries and keep other heavy apps closed."
    fi
    if [ "$_disk" -lt 20 ]; then
        warn "Free disk is tight (${_disk} GB) — fine for the bundled datasets, but watch space before loading large files."
    fi
    ok "Compatibility check passed (${_ram} GB RAM, ${_disk} GB free)"
}

nano_image_ref() {
    echo "docker.io/${EXAKIT_NANO_IMAGE}:${EXAKIT_NANO_TAG}"
}

nano_container_exists() {
    "$(nano_engine)" container inspect "$EXAKIT_NANO_CONTAINER" >/dev/null 2>&1
}

nano_container_running() {
    [ "$("$(nano_engine)" container inspect -f '{{.State.Running}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null)" = "true" ]
}

# nano_ready_in_logs — ready marker from the CURRENT boot only. Container
# logs survive stop/start, so scanning the full history would match a stale
# line from a previous boot; scoping to StartedAt also keeps each poll cheap.
nano_ready_in_logs() {
    _engine="$(nano_engine)"
    _started="$("$_engine" container inspect -f '{{.State.StartedAt}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null)"
    # Normalize StartedAt to an epoch that `logs --since` accepts on both
    # engines. docker emits RFC3339 ("2026-07-06T05:46:47.33Z"); podman emits
    # Go's default String() form ("2026-07-06 05:46:47.33 +0000 UTC"), which
    # podman's own --since cannot parse — left as-is it silently returns no
    # logs, the marker never matches, and readiness polling loops until timeout.
    _since=""
    if [ -n "$_started" ]; then
        _norm="$(printf '%s' "$_started" | sed -E 's/\.[0-9]+//; s/ UTC$//; s/T/ /')"
        _since="$(date -d "$_norm" +%s 2>/dev/null || true)"
    fi
    # Capture then match, rather than `logs | grep -q`. Under `set -o pipefail`
    # (which exakit and the setup scripts enable), `grep -q` closing the pipe on
    # first match makes `logs` exit with SIGPIPE, and pipefail reports the whole
    # pipeline as failed — so a genuinely-ready DB is misread as "starting".
    if [ -n "$_since" ]; then
        _out="$("$_engine" logs --since "$_since" "$EXAKIT_NANO_CONTAINER" 2>&1)"
    else
        # Fallback: if the timestamp could not be parsed, scan full history
        # rather than loop forever. Risks matching a stale marker from a prior
        # boot, but a false-ready beats a guaranteed timeout.
        _out="$("$_engine" logs "$EXAKIT_NANO_CONTAINER" 2>&1)"
    fi
    case "$_out" in
        *"Database is now up and running!"*) return 0 ;;
        *) return 1 ;;
    esac
}

# nano_has_first_deploy_args — the container was created with the
# first-deploy-only 'init sys_password_file=...' arguments. Nano refuses to
# boot with them once /exa is initialized, so such a container cannot simply
# be restarted — it must be recreated without them (the data volume carries
# the database and its password forward).
nano_has_first_deploy_args() {
    "$(nano_engine)" container inspect -f '{{join .Config.Cmd " "}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null | \
        grep -q "sys_password_file"
}

# nano_start_existing — bring a stopped container back up, recreating it
# first when it still carries the single-use first-deploy arguments.
nano_start_existing() {
    _engine="$(nano_engine)"
    if nano_has_first_deploy_args; then
        _image="$("$_engine" container inspect -f '{{.Config.Image}}' "$EXAKIT_NANO_CONTAINER" 2>/dev/null)"
        [ -n "$_image" ] || _image="$(nano_image_ref)"
        info "Recreating the Nano container (first-deploy options are single-use; the data volume is kept)"
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || die "Could not replace the old container (see log)"
        run_logged "$_engine" run -d \
            --name "$EXAKIT_NANO_CONTAINER" \
            --shm-size=512mb \
            --pids-limit=-1 \
            -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
            -v "${EXAKIT_NANO_VOLUME}:/exa" \
            "$_image" || die "Container failed to start (see log)"
    else
        run_logged "$_engine" start "$EXAKIT_NANO_CONTAINER" || \
            die "Could not start existing container $EXAKIT_NANO_CONTAINER (see log)"
    fi
    nano_wait_ready
}

# nano_creds_poisoned — detect the debris a root Docker daemon leaves behind
# when a container was ever started while the secret file was missing: Docker
# creates the whole missing mount path as root-owned DIRECTORIES on the host.
# The result is a credentials dir this user cannot write into and a
# nano_sys_password that is a directory — every later install then dies with
# a bare "Permission denied" (seen in the wild on WSL).
nano_creds_poisoned() {
    [ -d "${EXAKIT_CREDS_DIR}/nano_sys_password" ] && return 0
    [ -d "$EXAKIT_CREDS_DIR" ] && [ ! -w "$EXAKIT_CREDS_DIR" ] && return 0
    return 1
}

# nano_repair_creds — fix that state WITHOUT sudo: the user cannot delete
# root-owned files, but the container engine's daemon (already a hard
# requirement, already verified usable) runs as root — so let it remove the
# bogus mount-path directory and hand the credentials dir back to this user.
# Falls back to a precise manual remedy if the engine repair does not stick.
nano_repair_creds() {
    nano_creds_poisoned || return 0
    _engine="$(nano_engine)"
    warn "Found root-owned leftovers from an interrupted install in $(ui_tilde "$EXAKIT_CREDS_DIR")"
    info "Repairing them via $_engine (no sudo needed)"
    run_logged "$_engine" run --rm \
        -v "${EXAKIT_CREDS_DIR}:/repair" \
        "$EXAKIT_NANO_REPAIR_IMAGE" \
        sh -c "[ -d /repair/nano_sys_password ] && rm -rf /repair/nano_sys_password; chown -R $(id -u):$(id -g) /repair" || true
    if nano_creds_poisoned; then
        error "Could not repair the credentials directory automatically."
        printf '    An earlier interrupted install left root-owned files in it, and this\n' >&2
        printf '    user (%s) cannot remove them. Remove them once, then re-run:\n' "$(id -un)" >&2
        printf '      sudo rm -rf %s\n' "$EXAKIT_CREDS_DIR" >&2
        die "Credentials directory $EXAKIT_CREDS_DIR is not writable."
    fi
    ok "Credentials directory repaired"
}

# nano_install — pull the resolved image and start the container (first run
# deploys the database with a generated SYS password). Idempotent.
nano_install() {
    _engine="$(nano_engine)"
    _image="$(nano_image_ref)"

    if nano_container_running && nano_ready_in_logs; then
        ok "Nano container already running and healthy"
        nano_record_manifest
        return 0
    fi

    if nano_container_exists && ! nano_container_running; then
        info "Found existing Nano container — starting it"
        nano_start_existing
        nano_record_manifest
        return 0
    fi

    if ! nano_container_exists; then
        if port_in_use "$EXAKIT_DB_PORT"; then
            die "Port $EXAKIT_DB_PORT is already in use by another application. Stop it or set EXAKIT_DB_PORT, then re-run."
        fi
        info "Pulling image $_image"
        _pulled=0
        for _attempt in 1 2 3; do
            if run_logged "$_engine" pull "$_image"; then
                _pulled=1
                break
            fi
            [ "$_attempt" -lt 3 ] && { warn "Pull attempt $_attempt failed — retrying in $((_attempt * 10))s"; sleep $((_attempt * 10)); }
        done
        [ "$_pulled" -eq 1 ] || die "Image pull failed after 3 attempts: $_image (network/Docker Hub issue — see log)"
        ok "Image pulled"

        # First deployment: generate the SYS password up front and hand it to
        # the container as a read-only secret file. It is only applied when
        # /exa is empty; on an existing volume the previous password stays.
        nano_repair_creds
        _password="$(read_credential nano_sys_password)"
        if [ -z "$_password" ]; then
            _password="$(generate_password)"
            store_credential nano_sys_password "$_password"
        fi

        # SELinux systems (Fedora, RHEL) need the :z label on bind mounts;
        # harmless elsewhere, so apply it for podman across the board.
        _secret_mount="${EXAKIT_CREDS_DIR}/nano_sys_password:/run/secrets/sys_password:ro"
        [ "$_engine" = "podman" ] && _secret_mount="${_secret_mount},z"

        # The secret must exist as a regular FILE before the engine sees the
        # bind mount: if the path were missing, a root Docker daemon would
        # create it as a root-owned directory on the host — the exact debris
        # nano_repair_creds exists to clean up. Never hand it that chance.
        [ -f "${EXAKIT_CREDS_DIR}/nano_sys_password" ] || \
            die "Credential file ${EXAKIT_CREDS_DIR}/nano_sys_password is missing or not a regular file — re-run the installer."

        info "Starting Nano container ($EXAKIT_NANO_CONTAINER)"
        run_logged "$_engine" run -d \
            --name "$EXAKIT_NANO_CONTAINER" \
            --shm-size=512mb \
            --pids-limit=-1 \
            -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
            -v "${EXAKIT_NANO_VOLUME}:/exa" \
            -v "$_secret_mount" \
            "$_image" init sys_password_file=/run/secrets/sys_password || \
            die "Container failed to start (see log)"
        # run_rollback executes in reverse order: the container must be
        # removed BEFORE its volume, or the engine refuses ("volume in use")
        # and a half-initialized volume is orphaned for the next install.
        push_rollback "$_engine volume rm $EXAKIT_NANO_VOLUME"
        push_rollback "$_engine rm -f $EXAKIT_NANO_CONTAINER"
    fi

    nano_wait_ready
    nano_record_manifest
}

# nano_wait_ready — poll container logs until the database reports ready.
nano_wait_ready() {
    nano_wait_ready_soft || die "Nano startup timed out"
}

nano_wait_ready_soft() {
    info "Waiting for the database to come up (timeout: ${EXAKIT_NANO_READY_TIMEOUT}s)"
    _waited=0
    while [ "$_waited" -lt "$EXAKIT_NANO_READY_TIMEOUT" ]; do
        if ! nano_container_running; then
            "$(nano_engine)" logs --tail 30 "$EXAKIT_NANO_CONTAINER" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
            warn "Nano container stopped unexpectedly (see log)"
            return 1
        fi
        if nano_ready_in_logs; then
            ok "Database is up (took ~${_waited}s)"
            return 0
        fi
        sleep 5
        _waited=$((_waited + 5))
        if [ $((_waited % 30)) -eq 0 ]; then
            info "Still starting... (${_waited}s)"
        fi
    done
    error "Database did not become ready within ${EXAKIT_NANO_READY_TIMEOUT}s."
    printf '    Inspect the logs:   %s logs %s\n' "$(nano_engine)" "$EXAKIT_NANO_CONTAINER" >&2
    printf '    If a first install was interrupted, the data volume may be half-initialized.\n' >&2
    printf '    Reset and retry:    %s rm -f %s && %s volume rm %s\n' \
        "$(nano_engine)" "$EXAKIT_NANO_CONTAINER" "$(nano_engine)" "$EXAKIT_NANO_VOLUME" >&2
    return 1
}

nano_record_manifest() {
    manifest_set runtime.type "nano"
    manifest_set runtime.engine "$(nano_engine)"
    manifest_set runtime.image "$(nano_image_ref)"
    manifest_set runtime.container "$EXAKIT_NANO_CONTAINER"
    manifest_set runtime.volume "$EXAKIT_NANO_VOLUME"
    manifest_set runtime.dsn "127.0.0.1:${EXAKIT_DB_PORT}"
    manifest_set runtime.user "sys"
    manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/nano_sys_password"
    manifest_set runtime.tls "self-signed"
    manifest_set runtime.status "healthy"
}

# --- lifecycle (used by exakit) ---------------------------------------------
nano_status() {
    nano_resolve_names
    if ! nano_container_exists; then
        echo "not installed"
    elif ! nano_container_running; then
        echo "stopped"
    elif nano_ready_in_logs; then
        echo "running"
    else
        echo "starting"
    fi
}

nano_start() {
    nano_resolve_names
    nano_container_exists || die "No Nano container found. Run the installer first."
    if nano_container_running; then
        ok "Nano container is already running"
        return 0
    fi
    nano_start_existing
    ok "Nano started"
}

nano_stop() {
    nano_resolve_names
    nano_container_running || { ok "Nano container is not running"; return 0; }
    info "Stopping Nano container (waiting up to 60s for a clean shutdown)"
    run_logged "$(nano_engine)" stop -t 60 "$EXAKIT_NANO_CONTAINER" || die "Failed to stop container"
    manifest_set runtime.status "stopped"
    ok "Nano stopped"
}

# nano_teardown [--data] — remove the container; --data also removes the
# persistent volume (all database content).
nano_teardown() {
    nano_resolve_names
    _engine="$(nano_engine)"
    if nano_container_exists; then
        info "Removing Nano container"
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || warn "Container removal failed"
    else
        warn "No container named '$EXAKIT_NANO_CONTAINER' found — nothing to remove (was it created under a different name?)"
    fi
    if [ "${1:-}" = "--data" ]; then
        if "$_engine" volume inspect "$EXAKIT_NANO_VOLUME" >/dev/null 2>&1; then
            info "Removing data volume $EXAKIT_NANO_VOLUME"
            run_logged "$_engine" volume rm "$EXAKIT_NANO_VOLUME" || warn "Volume removal failed"
        fi
    else
        info "Data volume $EXAKIT_NANO_VOLUME kept (pass --data to remove it)"
    fi
    manifest_set runtime.status "removed"
}

nano_update() {
    nano_resolve_names
    _latest="$(exakit_component_latest nano)"
    [ -n "$_latest" ] || die "Could not resolve the latest Exasol Nano image tag."
    _current="$(exakit_component_current nano 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "Exasol Nano is already current ($_current)"
        return 0
    fi

    _engine="$(nano_engine)"
    _image="docker.io/${EXAKIT_NANO_IMAGE}:${_latest}"
    _old_image="docker.io/${EXAKIT_NANO_IMAGE}:${_current}"
    _snapshot="$(nano_update_snapshot "$_current" "$_latest")"
    info "Updating Exasol Nano ${_current:-unknown} -> $_latest"
    info "The container will be recreated; the data volume '$EXAKIT_NANO_VOLUME' is kept."
    info "Pre-update runtime snapshot: $_snapshot"
    run_logged "$_engine" pull "$_image" || die "Could not pull $_image"

    if nano_container_exists; then
        if nano_container_running; then
            info "Stopping Nano before recreating the container"
            run_logged "$_engine" stop -t 60 "$EXAKIT_NANO_CONTAINER" || die "Could not stop $EXAKIT_NANO_CONTAINER"
        fi
        run_logged "$_engine" rm -f "$EXAKIT_NANO_CONTAINER" || die "Could not remove old Nano container"
    fi

    info "Starting Nano with the existing data volume"
    run_logged "$_engine" run -d \
        --name "$EXAKIT_NANO_CONTAINER" \
        --shm-size=512mb \
        --pids-limit=-1 \
        -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
        -v "${EXAKIT_NANO_VOLUME}:/exa" \
        "$_image" || {
            nano_restore_previous_container "$_old_image"
            die "Could not start updated Nano container; attempted to restore the previous image."
        }
    EXAKIT_NANO_TAG="$_latest"
    export EXAKIT_NANO_TAG
    if ! nano_wait_ready_soft; then
        nano_restore_previous_container "$_old_image"
        die "Updated Nano container did not become ready; attempted to restore the previous image."
    fi
    nano_record_manifest
    manifest_set desired.runtime.nano "$EXAKIT_NANO_TAG"
    manifest_set backups.nano_update.latest "$_snapshot"
    ok "Nano updated; data volume kept: $EXAKIT_NANO_VOLUME"
}

nano_update_snapshot() {
    _current="$1"
    _latest="$2"
    _backup_dir="$EXAKIT_HOME/backups/nano-update"
    _stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    _snapshot="$_backup_dir/${_stamp}-${_current:-unknown}-to-${_latest}.json"
    mkdir -p "$_backup_dir"
    chmod 700 "$EXAKIT_HOME/backups" "$_backup_dir" 2>/dev/null || true
    {
        printf '{\n'
        printf '  "created_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '  "operation": "nano_update",\n'
        printf '  "from": "%s",\n' "${_current:-unknown}"
        printf '  "to": "%s",\n' "$_latest"
        printf '  "container": "%s",\n' "$EXAKIT_NANO_CONTAINER"
        printf '  "volume": "%s",\n' "$EXAKIT_NANO_VOLUME"
        printf '  "image": "%s"\n' "$(manifest_get runtime.image 2>/dev/null || true)"
        printf '}\n'
    } > "$_snapshot"
    chmod 600 "$_snapshot" 2>/dev/null || true
    printf '%s\n' "$_snapshot"
}

nano_restore_previous_container() {
    _old_image="$1"
    [ -n "$_old_image" ] && [ "$_old_image" != "docker.io/${EXAKIT_NANO_IMAGE}:" ] || return 0
    warn "Restoring the previous Nano container image ($_old_image)"
    run_logged "$(nano_engine)" rm -f "$EXAKIT_NANO_CONTAINER" || true
    run_logged "$(nano_engine)" run -d \
        --name "$EXAKIT_NANO_CONTAINER" \
        --shm-size=512mb \
        --pids-limit=-1 \
        -p "127.0.0.1:${EXAKIT_DB_PORT}:8563" \
        -v "${EXAKIT_NANO_VOLUME}:/exa" \
        "$_old_image" || warn "Could not restore the previous Nano container automatically."
}
