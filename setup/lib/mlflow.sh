#!/usr/bin/env bash
# MLflow server and spool commands; the lifecycle itself is shared with PowerShell in mlflow_service.py.

_mlflow_service() {
    if [ -x "$(notebook_venv_python)" ]; then
        EXAKIT_HOME="$EXAKIT_HOME" "$(notebook_venv_python)" "$(exakit_repo_root)/setup/lib/mlflow_service.py" "$@"
    elif _exakit_python3_present; then
        EXAKIT_HOME="$EXAKIT_HOME" python3 "$(exakit_repo_root)/setup/lib/mlflow_service.py" "$@"
    else
        return 1
    fi
}

# mlflow_enabled — the user or a persona asked for the server: `exakit mlflow
# start` records it, `exakit mlflow disable` (or `stop --disable`) clears it.
# `exakit start` brings MLflow back only then, so a udf-devkit user who never
# asked for it never gets a server; a plain `stop` is for the session and keeps it.
mlflow_enabled() {
    [ "$(manifest_get components.udf_devkit.mlflow.enabled 2>/dev/null || true)" = true ]
}

mlflow_executable() { printf '%s\n' "${EXAKIT_NOTEBOOK_VENV:-$EXAKIT_HOME/notebook-venv}/bin/mlflow"; }

mlflow_require_server() {
    [ -n "$(manifest_get components.udf_devkit.version 2>/dev/null || true)" ] || \
        die "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit"
    [ -x "$(notebook_venv_python)" ] || die "The notebook add-on is needed for MLflow. Install it with: exakit marketplace notebook"
    if ! "$(notebook_venv_python)" -c 'import mlflow.server' >/dev/null 2>&1; then
        _mrs_uv="$(_notebook_uv)" || die "The notebook package installer is missing. Repair with: exakit update notebook"
        exakit_init_logging
        _mrs_previous_label="${EXAKIT_ACTIVE_LABEL:-}"
        EXAKIT_ACTIVE_LABEL="Installing the local MLflow server"
        run_logged "$_mrs_uv" pip install --python "$(notebook_venv_python)" 'mlflow>=3,<4' || \
            die "MLflow server could not be installed. Read: exakit logs setup"
        EXAKIT_ACTIVE_LABEL="$_mrs_previous_label"
    fi
}

cmd_mlflow() {
    _cm_action="${1:-}"; [ $# -eq 0 ] || shift
    case "$_cm_action" in
        --help|-h) exakit_help_render command mlflow; return $? ;;
        start|stop|status|url|replay|disable) ;;
        '') reject 'Name an MLflow action: start, stop, status, url, replay or disable.' ;;
        *) reject "Unknown MLflow action '$_cm_action' (start, stop, status, url, replay, disable)." ;;
    esac
    case "$_cm_action" in
        start)
            _cm_port=""; _cm_json=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --port) [ $# -ge 2 ] || reject 'Name a port after --port'; _cm_port="$2"; shift 2 ;;
                    --json) _cm_json=--json; shift ;;
                    *) reject "Unknown option '$1' for exakit mlflow start" ;;
                esac
            done
            mlflow_require_server
            if [ -n "$_cm_port" ]; then
                _mlflow_service start --executable "$(mlflow_executable)" --port "$_cm_port" ${_cm_json:+"$_cm_json"}
            else
                _mlflow_service start --executable "$(mlflow_executable)" ${_cm_json:+"$_cm_json"}
            fi
            _cm_rc=$?
            [ "$_cm_rc" -eq 0 ] && manifest_set components.udf_devkit.mlflow.enabled true
            return "$_cm_rc" ;;
        stop|disable)
            _cm_json=""; _cm_disable=0
            [ "$_cm_action" = disable ] && _cm_disable=1
            for _cm_arg in "$@"; do
                case "$_cm_arg" in
                    --json) _cm_json=--json ;;
                    --disable) _cm_disable=1 ;;
                    *) reject "Unknown option '$_cm_arg' for exakit mlflow $_cm_action (--json$( [ "$_cm_action" = stop ] && printf ', --disable'))." ;;
                esac
            done
            _mlflow_service stop ${_cm_json:+"$_cm_json"}
            _cm_rc=$?
            if [ "$_cm_rc" -eq 0 ] && [ "$_cm_disable" = 1 ]; then
                manifest_set components.udf_devkit.mlflow.enabled false
                [ -n "$_cm_json" ] || info "MLflow will not start with exakit start until: exakit mlflow start"
            fi
            return "$_cm_rc" ;;
        replay)
            [ -x "$(notebook_venv_python)" ] || die 'The notebook add-on is needed for replay: exakit marketplace notebook'
            EXAKIT_HOME="$EXAKIT_HOME" "$(notebook_venv_python)" -m exasol_mlflow replay "$@" ;;
        *)
            [ $# -eq 0 ] || [ "$*" = --json ] || reject "Unknown option for exakit mlflow $_cm_action (only --json is accepted)."
            _mlflow_service "$_cm_action" "$@" ;;
    esac
}

# The generic service registry sees udf-devkit as the MLflow service.
udf_devkit_status() {
    _uds="$(_mlflow_service status --json 2>/dev/null || true)"
    case "$_uds" in
        *'"status": "running"'*) printf 'running\n' ;;
        *'"status": "stopped"'*) if mlflow_enabled; then printf 'stopped\n'; else printf 'stopped (not enabled: exakit mlflow start)\n'; fi ;;
        *) printf 'unknown\n' ;;
    esac
}
udf_devkit_start() { mlflow_enabled || return 0; [ -x "$(notebook_venv_python)" ] || return 0; cmd_mlflow start; }
udf_devkit_stop() { _mlflow_service stop >/dev/null; }
udf_devkit_url() { _mlflow_service url; }
udf_devkit_log_path() { printf 'udf-devkit-mlflow|MLflow server|%s\n' "$EXAKIT_HOME/mlflow/server.log"; }
