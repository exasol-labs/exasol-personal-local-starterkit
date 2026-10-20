#!/usr/bin/env bash
# notebook.sh — notebook (Jupyter notebooks connected to the local database):
# managed install + validation + the `exakit notebook` command.
#
# A MARKETPLACE ADD-ON: never installed by the setup scripts. The user picks it
# from `exakit marketplace`; once installed it joins `exakit update` like every
# other component. Sourced by the exakit CLI after common.sh.
#
# notebook facts:
#   - Exasol's notebook connector (PyPI `exasol-notebook-connector`, the
#     package AI Lab is built on) in a venv of its own, with the kit's
#     `exakit_nb` helpers (notebook/package), the `exasol-mlflow` client
#     (packages/exasol-mlflow), ipykernel, scikit-learn and the Langfuse,
#     OpenAI and MLflow clients. PyPI versions are immutable, so the version is
#     the pin (as for dbt-exasol).
#   - The connection lives in the connector's ENCRYPTED store. A Jupyter kernel
#     named "Exasol (Starter Kit)" finds it through two file paths in its spec
#     (the store, and the kit credential file holding its master password), so
#     no kernel spec, notebook or output ever holds a host, a user or a
#     password. The store is refreshed from the kit's record on every
#     `exakit notebook`.
#   - JupyterLab is NOT installed behind the user's back: one on PATH is used;
#     with none the user is asked (EXAKIT_NOTEBOOK_JUPYTER=install|skip answers
#     for a script), and a skip prints where to get it.
#   - On demand, never a boot service: `exakit notebook` starts JupyterLab in
#     the background on 127.0.0.1 with a token (kit credential, never printed)
#     and opens it logged in; `exakit notebook --stop` stops it. That is why
#     this module defines no status/start/stop/autostart hooks: those would
#     fold it into `exakit start` and the boot entries.
#   - The Python steps (the store, the kernel, the connection check) are the
#     shared scripts in notebook/kit/, run with the venv's Python by this file
#     and its PowerShell twin alike.
#
#   - venv:      $EXAKIT_HOME/notebook-venv
#   - store:     $EXAKIT_HOME/notebook/connection.scs
#   - notebooks: $EXAKIT_HOME/notebooks  (copied once, never overwritten; kept
#                by an uninstall)
#
# Safe to re-run: an existing venv with the desired version installed is kept.

EXAKIT_NOTEBOOK_VERSION="${EXAKIT_NOTEBOOK_VERSION:-}"
EXAKIT_NOTEBOOK_VERSION_FALLBACK="${EXAKIT_NOTEBOOK_VERSION_FALLBACK:-3.1.0}"
EXAKIT_NOTEBOOK_PACKAGE="${EXAKIT_NOTEBOOK_PACKAGE:-exasol-notebook-connector}"
EXAKIT_NOTEBOOK_VENV="${EXAKIT_NOTEBOOK_VENV:-$EXAKIT_HOME/notebook-venv}"
EXAKIT_NOTEBOOK_HOME="${EXAKIT_NOTEBOOK_HOME:-$EXAKIT_HOME/notebook}"
EXAKIT_NOTEBOOK_DIR="${EXAKIT_NOTEBOOK_DIR:-$EXAKIT_HOME/notebooks}"
EXAKIT_NOTEBOOK_PORT="${EXAKIT_NOTEBOOK_PORT:-8888}"
# What the venv holds besides the connector. Its extras are the ones its
# connection module imports; the rest serve the kit's notebooks.
EXAKIT_NOTEBOOK_EXTRAS="bucketfs,ibis,pyexasol,sqlalchemy"
EXAKIT_NOTEBOOK_PACKAGES="ipykernel>=6.29,<8 langfuse>=3,<4 openai>=1.40,<3 scikit-learn>=1.4,<2 mlflow-skinny>=2.14,<4 alembic>=1.13,<2"
EXAKIT_NOTEBOOK_JUPYTERLAB="jupyterlab>=4.2,<5"
EXAKIT_NOTEBOOK_KERNEL_NAME="exasol-starter-kit"
EXAKIT_NOTEBOOK_KERNEL_TITLE="Exasol (Starter Kit)"
EXAKIT_NOTEBOOK_INSTALL_GUIDE="https://jupyter.org/install"
# Kit credential names: the store's master password and JupyterLab's token.
EXAKIT_NOTEBOOK_MASTER_CRED="notebook_store_master_password"
EXAKIT_NOTEBOOK_TOKEN_CRED="notebook_jupyter_token"

notebook_venv_python() {
    printf '%s\n' "$EXAKIT_NOTEBOOK_VENV/bin/python"
}

notebook_store_file() {
    printf '%s\n' "$EXAKIT_NOTEBOOK_HOME/connection.scs"
}

# notebook_package_version — what the venv says about the connector.
# ⇄ twin: Get-NotebookPackageVersion in notebook.ps1.
notebook_package_version() {
    _nbp_python="$(notebook_venv_python)"
    [ -x "$_nbp_python" ] || return 1
    ( "$_nbp_python" -c 'from importlib.metadata import version; print(version("exasol-notebook-connector"))' && : ) 2>/dev/null
}

# notebook_installed_version — the record AND the venv (see
# dash_server_installed_version for why both).
notebook_installed_version() {
    _nbi_recorded="$(manifest_get components.notebook.version 2>/dev/null || true)"
    [ -n "$_nbi_recorded" ] || return 1
    notebook_package_version
}

_notebook_not_installed() {
    warn "The notebook add-on was not installed: $1"
    command -v exakit_explain_last_log_error >/dev/null 2>&1 && exakit_explain_last_log_error
    warn "Everything else in the kit is unaffected. Retry with: exakit update notebook"
    command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "$1"
    manifest_set components.notebook.validated false
    return 1
}

# _notebook_secret <credential name> — the kit credential, generated on first
# use. Its value goes to a child's environment, never to a command line or a log.
_notebook_secret() {
    _nbs_value="$(read_credential "$1")"
    if [ -z "$_nbs_value" ]; then
        _nbs_value="$(generate_password)"
        store_credential "$1" "$_nbs_value"
    fi
    printf '%s' "$_nbs_value"
}

# _notebook_py <script> — run one of notebook/kit/*.py with the venv's Python.
# The caller exports what the script reads.
_notebook_py() {
    "$(notebook_venv_python)" "$(exakit_repo_root)/notebook/kit/$1"
}

# notebook_write_connection — the kit's current connection into the store;
# prints changed|same. The password is read by the script from its FILE.
notebook_write_connection() {
    _nbw_dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    _nbw_user="$(manifest_get runtime.user 2>/dev/null || true)"
    _nbw_pw="$(manifest_get runtime.password_file 2>/dev/null || true)"
    _nbw_host="${_nbw_dsn%:*}"
    _nbw_port="${_nbw_dsn##*:}"
    if [ -z "$_nbw_dsn" ] || [ "$_nbw_host" = "$_nbw_dsn" ] || [ -z "$_nbw_pw" ]; then
        warn "The kit has no complete database connection recorded yet - install the kit first."
        return 1
    fi
    mkdir -p "$EXAKIT_NOTEBOOK_HOME" || return 1
    SCS_FILE="$(notebook_store_file)" SCS_MASTER_PASSWORD="$(_notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED")" \
        EXAKIT_NB_HOST="$_nbw_host" EXAKIT_NB_PORT="$_nbw_port" EXAKIT_NB_USER="${_nbw_user:-sys}" \
        EXAKIT_NB_PWFILE="$_nbw_pw" _notebook_py write_store.py 2>>"${EXAKIT_LOG_FILE:-/dev/null}" | tail -1
}

# notebook_connected — the connector opens the database from the store.
notebook_connected() {
    SCS_FILE="$(notebook_store_file)" SCS_MASTER_PASSWORD="$(_notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED")" \
        _notebook_py check_connection.py >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
}

# notebook_copy_notebooks — the kit's notebooks into the user's folder; one
# already there is the user's and is never overwritten. Prints what it added.
notebook_copy_notebooks() {
    mkdir -p "$EXAKIT_NOTEBOOK_DIR" || return 1
    for _nbc_src in "$(exakit_repo_root)"/notebook/notebooks/*.ipynb; do
        [ -f "$_nbc_src" ] || continue
        _nbc_name="$(basename "$_nbc_src")"
        [ -e "$EXAKIT_NOTEBOOK_DIR/$_nbc_name" ] && continue
        cp "$_nbc_src" "$EXAKIT_NOTEBOOK_DIR/$_nbc_name" && printf '%s\n' "$_nbc_name"
    done
}

# notebook_register_kernel — the kernel any Jupyter front end on the machine
# offers. Its spec carries paths only.
notebook_register_kernel() {
    _notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED" >/dev/null
    EXAKIT_KERNEL_NAME="$EXAKIT_NOTEBOOK_KERNEL_NAME" EXAKIT_KERNEL_TITLE="$EXAKIT_NOTEBOOK_KERNEL_TITLE" \
        EXAKIT_NB_STORE="$(notebook_store_file)" EXAKIT_NB_MASTER_FILE="$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED" \
        EXAKIT_NB_DATASETS="$(exakit_repo_root)/data/datasets" \
        _notebook_py register_kernel.py >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
}

notebook_remove_kernel() {
    [ -x "$(notebook_venv_python)" ] || return 0
    EXAKIT_KERNEL_NAME="$EXAKIT_NOTEBOOK_KERNEL_NAME" _notebook_py remove_kernel.py >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || true
}

# notebook_find_jupyter — "kit <path>" for one the user let the kit install,
# "own <path>" for one on PATH; nothing (return 1) when there is none.
notebook_find_jupyter() {
    for _nbf_cmd in jupyter-lab jupyter-notebook; do
        if [ -x "$EXAKIT_NOTEBOOK_VENV/bin/$_nbf_cmd" ]; then
            printf 'kit %s\n' "$EXAKIT_NOTEBOOK_VENV/bin/$_nbf_cmd"; return 0
        fi
    done
    for _nbf_cmd in jupyter-lab jupyter-notebook; do
        _nbf_path="$(command -v "$_nbf_cmd" 2>/dev/null || true)"
        [ -n "$_nbf_path" ] && { printf 'own %s\n' "$_nbf_path"; return 0; }
    done
    return 1
}

# notebook_offer_jupyter — settle JupyterLab: the user's own, or the kit's
# after a yes (EXAKIT_NOTEBOOK_JUPYTER=install|skip answers for a script; a run
# with no terminal skips). Returns 1 when there is none afterwards.
notebook_offer_jupyter() {
    notebook_find_jupyter >/dev/null && return 0
    _nbo_answer="$(printf '%s' "${EXAKIT_NOTEBOOK_JUPYTER:-}" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$_nbo_answer" ]; then
        if confirm "No JupyterLab was found. Install JupyterLab into the kit's notebook environment?" n; then
            _nbo_answer=install
        else
            _nbo_answer=skip
        fi
    fi
    if [ "$_nbo_answer" = "install" ]; then
        _nbo_uv="$(_notebook_uv)" || return 1
        EXAKIT_ACTIVE_LABEL="Installing JupyterLab"
        if run_logged "$_nbo_uv" pip install --python "$(notebook_venv_python)" "$EXAKIT_NOTEBOOK_JUPYTERLAB"; then
            manifest_set components.notebook.jupyter kit
            ok "JupyterLab installed into the kit's notebook environment"
            return 0
        fi
        warn "JupyterLab could not be installed (see the log)."
    fi
    info "No JupyterLab: get it at $EXAKIT_NOTEBOOK_INSTALL_GUIDE, then run: exakit notebook"
    info "The kernel '$EXAKIT_NOTEBOOK_KERNEL_TITLE' is registered: VS Code or any Jupyter front end can use it now."
    return 1
}

_notebook_uv() {
    if command -v uv >/dev/null 2>&1; then
        printf 'uv\n'
    elif exakit_ensure_uv && [ -x "${EXAKIT_UV_BIN:-}" ]; then
        printf '%s\n' "$EXAKIT_UV_BIN"
    else
        return 1
    fi
}

# _notebook_specs — the connector with its extras, the companion packages and
# the two packages the kit carries, one per line (for one uv resolution).
_notebook_specs() {
    printf '%s[%s]==%s\n' "$EXAKIT_NOTEBOOK_PACKAGE" "$EXAKIT_NOTEBOOK_EXTRAS" "$EXAKIT_NOTEBOOK_VERSION"
    for _nbs_pkg in $EXAKIT_NOTEBOOK_PACKAGES; do printf '%s\n' "$_nbs_pkg"; done
    printf '%s\n' "$(exakit_repo_root)/notebook/package" "$(exakit_repo_root)/packages/exasol-mlflow"
}

notebook_install() {
    if [ -z "${EXAKIT_NOTEBOOK_VERSION:-}" ]; then
        EXAKIT_NOTEBOOK_VERSION="$(exakit_component_available notebook 2>/dev/null || true)"
        [ -n "$EXAKIT_NOTEBOOK_VERSION" ] || EXAKIT_NOTEBOOK_VERSION="$EXAKIT_NOTEBOOK_VERSION_FALLBACK"
        export EXAKIT_NOTEBOOK_VERSION
    fi
    _nbi_uv="$(_notebook_uv)" || {
        _notebook_not_installed "uv (the Python tool runner) is not available — install it from https://docs.astral.sh/uv/ and re-run"
        return 1
    }
    _nbi_current="$(notebook_package_version || true)"
    if [ -n "$_nbi_current" ] && [ "$_nbi_current" = "$EXAKIT_NOTEBOOK_VERSION" ] && \
       [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ]; then
        ok "notebook $_nbi_current already installed: $EXAKIT_NOTEBOOK_VENV"
    else
        EXAKIT_ACTIVE_LABEL="Installing the notebook connector $EXAKIT_NOTEBOOK_VERSION"
        info "Installing the notebook connector $EXAKIT_NOTEBOOK_VERSION (about 1 GB: it brings PyTorch for its transformer features)"
        if [ ! -x "$(notebook_venv_python)" ]; then
            if ! run_logged "$_nbi_uv" venv --python "$EXAKIT_MANAGED_PYTHON_VERSION" "$EXAKIT_NOTEBOOK_VENV"; then
                _notebook_not_installed "the virtual environment at $EXAKIT_NOTEBOOK_VENV could not be created (see log)"
                return 1
            fi
            push_rollback "rm -rf '$EXAKIT_NOTEBOOK_VENV'"
        fi
        # CPU-only PyTorch on Linux: the default wheel pulls gigabytes of CUDA.
        _nbi_torch=""
        [ "$(detect_os 2>/dev/null)" = "macos" ] || _nbi_torch="--torch-backend cpu"
        # shellcheck disable=SC2046,SC2086
        if ! run_logged "$_nbi_uv" pip install --python "$(notebook_venv_python)" $_nbi_torch $(_notebook_specs); then
            _notebook_not_installed "installing ${EXAKIT_NOTEBOOK_PACKAGE}==${EXAKIT_NOTEBOOK_VERSION} and its companions failed (see log)"
            return 1
        fi
        if [ -z "$(notebook_package_version || true)" ]; then
            _notebook_not_installed "the venv cannot report a ${EXAKIT_NOTEBOOK_PACKAGE} version after the install (see log)"
            return 1
        fi
        ok "Notebook connector installed: $EXAKIT_NOTEBOOK_VENV"
    fi
    _nbi_added="$(notebook_copy_notebooks | tr '\n' ' ')"
    [ -n "$_nbi_added" ] && ok "Notebooks in $EXAKIT_NOTEBOOK_DIR: $_nbi_added"
    if ! notebook_register_kernel; then
        _notebook_not_installed "the Jupyter kernel could not be registered (see log)"
        return 1
    fi
    ok "Kernel registered: $EXAKIT_NOTEBOOK_KERNEL_TITLE"
    manifest_set components.notebook.version "$EXAKIT_NOTEBOOK_VERSION"
    manifest_set components.notebook.venv "$EXAKIT_NOTEBOOK_VENV"
    manifest_set components.notebook.python "$(notebook_venv_python)"
    manifest_set components.notebook.notebooks_dir "$EXAKIT_NOTEBOOK_DIR"
    manifest_set components.notebook.store_file "$(notebook_store_file)"
    manifest_set components.notebook.kernel "$EXAKIT_NOTEBOOK_KERNEL_NAME"
    notebook_offer_jupyter || true
    return 0
}

# notebook_validate — the packages import; with the database up, the connector
# connects from the store. Soft: records validated and returns 0.
notebook_validate() {
    [ -x "$(notebook_venv_python)" ] || return 0
    if ! "$(notebook_venv_python)" -c 'import exasol.nb_connector, exakit_nb, exasol_mlflow, ipykernel' >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        warn "The notebook environment does not import - repair with: exakit update notebook"
        manifest_set components.notebook.validated false
        return 0
    fi
    if ! { command -v exakit_db_reachable >/dev/null 2>&1 && exakit_db_reachable; }; then
        manifest_set components.notebook.validated true
        manifest_set components.notebook.validated_by import
        return 0
    fi
    notebook_write_connection >/dev/null || true
    if notebook_connected; then
        manifest_set components.notebook.validated true
        manifest_set components.notebook.validated_by connection
        ok "Notebooks connect to the database - open them with: exakit notebook"
    else
        manifest_set components.notebook.validated false
        warn "The notebook connector could not connect - check with: exakit notebook --check"
    fi
    return 0
}

notebook_update() {
    _nbu_available="$(exakit_component_available notebook 2>/dev/null || true)"
    [ -n "$_nbu_available" ] || die "Could not resolve the advertised notebook connector version."
    _nbu_current="$(notebook_installed_version 2>/dev/null || true)"
    if [ -n "$_nbu_current" ] && [ "$_nbu_current" = "$_nbu_available" ]; then
        notebook_copy_notebooks >/dev/null || true
        notebook_register_kernel || true
        notebook_validate || true
        ok "notebook is already current ($_nbu_current)"
        return 0
    fi
    info "Updating notebook ${_nbu_current:-not installed} -> $_nbu_available"
    EXAKIT_NOTEBOOK_VERSION="$_nbu_available"
    EXAKIT_FORCE_COMPONENT_INSTALL=1
    export EXAKIT_NOTEBOOK_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
    notebook_install || die "The notebook add-on could not be updated — see the warning above and ${EXAKIT_LOG_FILE:-the log}."
    notebook_validate || true
    manifest_set desired.notebook "$EXAKIT_NOTEBOOK_VERSION"
    ok "notebook updated; database data was not changed"
}

notebook_summary() {
    printf 'notebooks: exakit notebook\n'
}

# --- JupyterLab on demand --------------------------------------------------------

_notebook_pidfile() { printf '%s\n' "$EXAKIT_NOTEBOOK_HOME/jupyter.pid"; }
_notebook_logfile() { printf '%s\n' "${EXAKIT_LOG_DIR:-$EXAKIT_HOME/logs}/notebook.log"; }

# _notebook_api_answers <port> — JupyterLab's /api answers on this port.
_notebook_api_answers() {
    curl -fsS -m 3 "http://127.0.0.1:$1/api" 2>/dev/null | grep -q '"version"'
}

# notebook_server_state — running|starting|stopped, from the pidfile the kit
# wrote and the API on the recorded port (a JupyterLab the kit did not start is
# never reported as ours).
notebook_server_state() {
    _nss_pid="$(cat "$(_notebook_pidfile)" 2>/dev/null || true)"
    _nss_port="$(manifest_get components.notebook.port 2>/dev/null || true)"
    if [ -n "$_nss_pid" ] && kill -0 "$_nss_pid" 2>/dev/null; then
        if _notebook_api_answers "${_nss_port:-$EXAKIT_NOTEBOOK_PORT}"; then printf 'running\n'; else printf 'starting\n'; fi
        return 0
    fi
    printf 'stopped\n'
}

# notebook_server_start <port> — JupyterLab in the background on 127.0.0.1,
# rooted at the notebooks folder, with the token in its environment only.
notebook_server_start() {
    _nst_port="$1"
    _nst_found="$(notebook_find_jupyter)" || return 1
    _nst_cmd="${_nst_found#* }"
    if _notebook_api_answers "$_nst_port"; then
        warn "Port $_nst_port already answers for another Jupyter - pick another with: exakit notebook --port <number>"
        return 1
    fi
    mkdir -p "$EXAKIT_NOTEBOOK_HOME" "$(dirname "$(_notebook_logfile)")"
    ( cd "$EXAKIT_NOTEBOOK_DIR" && JUPYTER_TOKEN="$(_notebook_secret "$EXAKIT_NOTEBOOK_TOKEN_CRED")" \
        nohup "$_nst_cmd" --no-browser --ServerApp.ip=127.0.0.1 "--ServerApp.port=$_nst_port" \
        --ServerApp.port_retries=0 "--ServerApp.root_dir=$EXAKIT_NOTEBOOK_DIR" >>"$(_notebook_logfile)" 2>&1 &
      echo $! > "$(_notebook_pidfile)" )
    manifest_set components.notebook.port "$_nst_port"
    EXAKIT_ACTIVE_LABEL="Starting JupyterLab"
    ui_spin_begin "Starting JupyterLab"
    _nst_i=0
    while [ "$_nst_i" -lt 60 ]; do
        _notebook_api_answers "$_nst_port" && { ui_spin_end; return 0; }
        sleep 1; _nst_i=$((_nst_i + 1))
    done
    ui_spin_end
    warn "JupyterLab did not answer within 60s - see $(_notebook_logfile)"
    return 1
}

notebook_server_stop() {
    _nsp_pid="$(cat "$(_notebook_pidfile)" 2>/dev/null || true)"
    if [ -n "$_nsp_pid" ] && kill -0 "$_nsp_pid" 2>/dev/null; then
        pkill -P "$_nsp_pid" 2>/dev/null || true
        kill "$_nsp_pid" 2>/dev/null || true
        ok "JupyterLab stopped"
    else
        info "JupyterLab is not running"
    fi
    rm -f "$(_notebook_pidfile)"
}

# _notebook_open_browser <url> — the logged-in address goes to the browser
# only; it is never printed.
_notebook_open_browser() {
    if command -v open >/dev/null 2>&1 && [ "$(detect_os 2>/dev/null)" = "macos" ]; then
        open "$1" >/dev/null 2>&1
    elif command -v wslview >/dev/null 2>&1; then
        wslview "$1" >/dev/null 2>&1
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$1" >/dev/null 2>&1
    else
        return 1
    fi
}

# notebook_cmd [--check] [--setup] [--stop] [--no-browser] [--port N] — the
# `exakit notebook` command.
notebook_cmd() {
    _nbc_check=0; _nbc_setup=0; _nbc_stop=0; _nbc_browser=1; _nbc_port=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --check) _nbc_check=1 ;;
            --setup) _nbc_setup=1 ;;
            --stop) _nbc_stop=1 ;;
            --no-browser) _nbc_browser=0 ;;
            --port)
                shift
                case "${1:-}" in ''|*[!0-9]*) die "--port needs a number between 1024 and 65535" ;; esac
                [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] || die "--port needs a number between 1024 and 65535"
                _nbc_port="$1" ;;
            *) die "Unknown option for exakit notebook: $1 (see: exakit help notebook)" ;;
        esac
        shift
    done
    notebook_installed_version >/dev/null || die "The notebook add-on is not installed. Install it with: exakit marketplace notebook"
    if [ "$_nbc_stop" = 1 ]; then notebook_server_stop; return 0; fi
    exakit_db_reachable || die "The database is not running. Start it with: exakit start"
    [ "$(notebook_write_connection)" = "changed" ] && info "The database connection changed; the notebooks now use the new one"
    notebook_register_kernel || warn "The kernel could not be registered again (see the log)."
    _nbc_added="$(notebook_copy_notebooks | tr '\n' ' ')"
    [ -n "$_nbc_added" ] && ok "New notebooks in $EXAKIT_NOTEBOOK_DIR: $_nbc_added"
    if [ "$_nbc_check" = 1 ]; then
        notebook_connected || die "The notebook connector could not connect to the database. Repair with: exakit update notebook"
        ok "Notebooks connect to the database"
        info "JupyterLab: $(notebook_server_state)   Notebooks: $EXAKIT_NOTEBOOK_DIR"
        return 0
    fi
    notebook_offer_jupyter || return 0
    if [ "$_nbc_setup" = 1 ]; then
        ok "Ready: $(notebook_find_jupyter | cut -d' ' -f2-) with the kernel '$EXAKIT_NOTEBOOK_KERNEL_TITLE'"
        return 0
    fi
    _nbc_port="${_nbc_port:-$(manifest_get components.notebook.port 2>/dev/null || true)}"
    _nbc_port="${_nbc_port:-$EXAKIT_NOTEBOOK_PORT}"
    if [ "$(notebook_server_state)" != "running" ]; then
        notebook_server_start "$_nbc_port" || return 1
    fi
    ok "JupyterLab is running: http://127.0.0.1:$_nbc_port/lab   (stop it with: exakit notebook --stop)"
    if [ "$_nbc_browser" = 1 ]; then
        _notebook_open_browser "http://127.0.0.1:$_nbc_port/lab?token=$(_notebook_secret "$EXAKIT_NOTEBOOK_TOKEN_CRED")" || \
            info "Open http://127.0.0.1:$_nbc_port/lab - the login token is in $EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_TOKEN_CRED"
    fi
    return 0
}

# notebook_uninstall [1] — the kernel, the venv, the store and the server go;
# the notebooks folder and the user's own JupyterLab stay.
notebook_uninstall() {
    _nbu_dry="${1:-0}"
    for _nbu_path in "$EXAKIT_NOTEBOOK_VENV" "$(notebook_store_file)"; do
        [ -e "$_nbu_path" ] || continue
        if [ "$_nbu_dry" = "1" ]; then info "  will remove: $_nbu_path"; fi
    done
    if [ "$_nbu_dry" = "1" ]; then
        info "  your notebooks stay in $EXAKIT_NOTEBOOK_DIR"
        return 0
    fi
    notebook_server_stop >/dev/null 2>&1 || true
    notebook_remove_kernel
    rm -rf "$EXAKIT_NOTEBOOK_VENV" "$(notebook_store_file)" "$(_notebook_pidfile)"
    rmdir "$EXAKIT_NOTEBOOK_HOME" 2>/dev/null || true
    rm -f "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED" "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_TOKEN_CRED"
    manifest_del components.notebook
    manifest_del desired.notebook
    info "Your notebooks stay in $EXAKIT_NOTEBOOK_DIR"
    ok_step "notebook removed — reinstall any time with: exakit marketplace notebook"
    return 0
}
