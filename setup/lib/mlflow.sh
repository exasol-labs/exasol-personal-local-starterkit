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

mlflow_executable() { printf '%s\n' "${EXAKIT_NOTEBOOK_VENV:-$EXAKIT_HOME/notebook-venv}/bin/mlflow"; }

mlflow_require_server() {
    [ -n "$(manifest_get components.udf_devkit.version 2>/dev/null || true)" ] || \
        die "The UDF dev kit is not installed. Install it with: exakit marketplace udf-devkit"
    [ -x "$(notebook_venv_python)" ] || die "The notebook add-on is needed for MLflow. Install it with: exakit marketplace notebook"
    if ! "$(notebook_venv_python)" -c 'import mlflow.server' >/dev/null 2>&1; then
        _mrs_uv="$(_notebook_uv)" || die "The notebook package installer is missing. Repair with: exakit update notebook"
        run_logged "$_mrs_uv" pip install --python "$(notebook_venv_python)" 'mlflow>=3,<4' || \
            die "MLflow server could not be installed. Read: exakit logs setup"
    fi
}

cmd_mlflow() {
    _cm_action="${1:-}"; [ $# -eq 0 ] || shift
    case "$_cm_action" in
        --help|-h) exakit_help_render command mlflow; return $? ;;
        start|stop|status|url|replay) ;;
        '') reject 'Name an MLflow action: start, stop, status, url or replay.' ;;
        *) reject "Unknown MLflow action '$_cm_action' (start, stop, status, url, replay)." ;;
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
            fi ;;
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
        *'"status": "stopped"'*) printf 'stopped\n' ;;
        *) printf 'unknown\n' ;;
    esac
}
udf_devkit_start() { [ -x "$(notebook_venv_python)" ] || return 0; cmd_mlflow start; }
udf_devkit_stop() { _mlflow_service stop >/dev/null; }
udf_devkit_url() { _mlflow_service url; }
udf_devkit_log_path() { printf 'udf-devkit-mlflow|MLflow server|%s\n' "$EXAKIT_HOME/mlflow/server.log"; }
