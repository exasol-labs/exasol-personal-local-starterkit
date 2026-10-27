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
#     `exakit.nb` helpers (notebook/package; `exakit_nb` is the same module),
#     the `exasol-mlflow` client (packages/exasol-mlflow), ipykernel,
#     scikit-learn and the Langfuse, OpenAI and MLflow clients. PyPI versions
#     are immutable, so the version is the pin (as for dbt-exasol). The two
#     packages the kit carries are reinstalled from the kit copy on every
#     install and update, the pin unchanged or not, so the helpers always match
#     the notebooks beside them.
#   - The front ends the kit installs are pinned in versions.json too
#     (components.notebook.frontends.jupyterlab / .marimo), read here and by the
#     PowerShell twin alike; EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION and
#     EXAKIT_NOTEBOOK_MARIMO_VERSION outrank the pin, as EXAKIT_<ID>_VERSION
#     does for every component. Everything is ONE uv resolution: JupyterLab
#     comes through the connector's own `jupyter` extra (the pin holds its
#     version), Marimo as marimo==<pin>, so `exakit update notebook` moves a
#     front end the kit installed to a new pin with everything else.
#   - The connection lives in the connector's ENCRYPTED store. A Jupyter kernel
#     named "Exasol (Starter Kit)" finds it through two file paths in its spec
#     (the store, and the kit credential file holding its master password), so
#     no kernel spec, notebook or output ever holds a host, a user or a
#     password. The store is refreshed from the kit's record on every
#     `exakit notebook`.
#   - The notebook tools are the notebook row's three CHILD ROWS in the
#     marketplace's add-ons table, all three ticked, each saying before anything
#     installs what will become of it (notebook_table_children): JupyterLab (one
#     on PATH is used; with none, the kit's is installed because it was ticked -
#     the connector's jupyter extra, in the same resolution as the connector),
#     Marimo (installed into the kit's notebook environment) and Positron (the
#     user's own, only ever CONFIGURED: the notebooks folder names the kit's
#     Python as its interpreter; the kit never installs Positron). Each row then
#     shows how its tool settled. A run that draws no table asks one checklist
#     instead (notebook_questions), where a terminal is there to answer it.
#     EXAKIT_NOTEBOOK_FRONTENDS=jupyterlab,marimo,positron|none answers it for a
#     script; EXAKIT_NOTEBOOK_JUPYTER=skip / EXAKIT_NOTEBOOK_MARIMO=skip leave one
#     out. The answer is recorded (components.notebook.front_ends) and a
#     reinstall or an update keeps it instead of asking again. Untick one now,
#     add it later: exakit notebook setup | --marimo | --positron.
#   - On demand, never a boot service: `exakit notebook` starts JupyterLab in
#     the background on 127.0.0.1 with a token (kit credential, never printed)
#     and opens it logged in; `exakit notebook stop` stops it. That is why
#     this module defines no status/start/stop/autostart hooks: those would
#     fold it into `exakit start` and the boot entries. It does define
#     notebook_log_path, so `exakit logs notebook` (and notebook-marimo) shows
#     the servers' logs.
#   - `exakit notebook` is a LAUNCHER that checks before it opens anything
#     (_notebook_preflight): the notebook environment (missing or not
#     importing: repaired after a yes), the database (not running or the
#     connection lost: started after a yes, then the connection checked), the
#     connection store (one whose master password is gone is replaced by a new
#     one), the kernel and the notebooks folder (both put back). On a terminal,
#     plain `exakit notebook` then asks which tools to open, one multi-select
#     whose rows say each tool's state (notebook_open_menu); a JupyterLab or a
#     Marimo that was removed is reinstalled after a yes. Without a terminal it
#     never asks: it opens JupyterLab as it always did, and a problem it cannot
#     fix there is one line naming the command that does, and a non-zero exit.
#     A port another program holds is stepped over (up to
#     EXAKIT_NOTEBOOK_PORT_TRIES above it) unless --port named it.
#   - The login token never reaches a command line: the browser opens a short
#     HTML file (0600, in the notebook home, removed when the server stops)
#     that forwards to the logged-in address, as Jupyter itself does.
#   - A pid file is trusted only while its process is still the server the kit
#     started (its command line says so): a pid the system has since handed to
#     another program is a stale file, never something to stop.
#   - The Python steps (the store, the kernel, the connection check) are the
#     shared scripts in notebook/kit/, run with the venv's Python by this file
#     and its PowerShell twin alike.
#
#   - venv:      $EXAKIT_HOME/notebook-venv
#   - store:     $EXAKIT_HOME/notebook/connection.scs
#   - notebooks: $EXAKIT_HOME/notebooks/starter-kit-notebooks/<persona>/ and
#                .../marimo/<persona>/ (notebook/catalog.json; copied once, never
#                overwritten, one the user deleted not copied again; kept by an
#                uninstall, the full one too unless EXAKIT_UNINSTALL_NOTEBOOKS=remove)
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
# connection module imports (the jupyter extra joins them when the kit installs
# JupyterLab); the rest serve the kit's notebooks. Langfuse is pinned to SDK
# major 5 (trace() uses its API; Python >=3.11) and MLflow to 3.x (the client,
# mlflow-skinny; the server is the exasol-mlflow[server] extra).
EXAKIT_NOTEBOOK_EXTRAS="bucketfs,ibis,pyexasol,sqlalchemy"
EXAKIT_NOTEBOOK_PACKAGES="ipykernel>=6.29,<8 langfuse>=5,<6 openai>=1.40,<3 scikit-learn>=1.4,<2 mlflow-skinny>=3,<4 alembic>=1.13,<2 pyarrow>=14"
# The kit's own packages, by their distribution names (reinstalled every time).
EXAKIT_NOTEBOOK_OWN_PACKAGES="exakit-nb exasol-mlflow"
# The front ends' versions: the pins in versions.json, unless one of these asks
# for another (see notebook_frontend_pin).
EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION="${EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION:-}"
EXAKIT_NOTEBOOK_MARIMO_VERSION="${EXAKIT_NOTEBOOK_MARIMO_VERSION:-}"
EXAKIT_NOTEBOOK_KERNEL_NAME="exasol-starter-kit"
EXAKIT_NOTEBOOK_KERNEL_TITLE="Exasol (Starter Kit)"
EXAKIT_NOTEBOOK_INSTALL_GUIDE="https://jupyter.org/install"
# Kit credential names: the store's master password and JupyterLab's token.
EXAKIT_NOTEBOOK_MASTER_CRED="notebook_store_master_password"
EXAKIT_NOTEBOOK_TOKEN_CRED="notebook_jupyter_token"
EXAKIT_NOTEBOOK_MARIMO_CRED="notebook_marimo_token"
# Where Marimo, the second front end, serves (its version is the versions.json
# pin tools/notebooks.py converts the Marimo notebooks with). Positron is the
# user's own; this is where to get it.
EXAKIT_NOTEBOOK_MARIMO_PORT="${EXAKIT_MARIMO_PORT:-2718}"
EXAKIT_NOTEBOOK_POSITRON_DOWNLOAD="https://positron.posit.co/download.html"
# What a server's command line holds when it is the one the kit started (see
# _notebook_proc_ours), and how long a start may take, in seconds.
EXAKIT_NOTEBOOK_JUPYTER_MATCH="*jupyter*--ServerApp.ip=127.0.0.1*"
EXAKIT_NOTEBOOK_MARIMO_MATCH="*marimo_wrapper.py*"
EXAKIT_NOTEBOOK_START_TIMEOUT="${EXAKIT_NOTEBOOK_START_TIMEOUT:-60}"
# How many ports above the usual one a server may move to when another program
# holds it (never when --port named the port).
EXAKIT_NOTEBOOK_PORT_TRIES="${EXAKIT_NOTEBOOK_PORT_TRIES:-20}"

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

# _notebook_py <script> [args] — run one of notebook/kit/*.py with the venv's
# Python. The caller exports what the script reads.
_notebook_py() {
    _nbpy_script="$1"
    shift
    "$(notebook_venv_python)" "$(exakit_repo_root)/notebook/kit/$_nbpy_script" "$@"
}

# notebook_write_connection — the kit's current connection into the store;
# prints changed|same, or new when the store had to be started again: its
# master password credential is gone (without it the store is unreadable, so
# it is removed), or the store would not open (it is kept beside the new one as
# connection.scs.unreadable and put back if a fresh store fails too, so a
# failure that was never the store's loses nothing). The password is read by
# the script from its FILE.
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
    _nbw_store="$(notebook_store_file)"
    _nbw_new=""
    # Looked at BEFORE _notebook_secret, which would make a new master and leave
    # the old store unreadable under it.
    if [ -f "$_nbw_store" ] && [ ! -s "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED" ]; then
        rm -f "$_nbw_store"
        _nbw_new=1
    fi
    # Captured, not piped into tail: a pipeline's status is tail's, and a store
    # that could not be written has to fail here.
    if ! _nbw_out="$(_notebook_store_write)"; then
        [ -f "$_nbw_store" ] || return 1
        mv -f "$_nbw_store" "$_nbw_store.unreadable" || return 1
        if ! _nbw_out="$(_notebook_store_write)"; then
            mv -f "$_nbw_store.unreadable" "$_nbw_store"
            return 1
        fi
        _nbw_new=1
    fi
    if [ -n "$_nbw_new" ]; then printf 'new\n'; else printf '%s\n' "$_nbw_out" | tail -1; fi
}

# _notebook_store_write — write_store.py with the connection notebook_write_connection
# read (its _nbw_* variables); its output, and its status.
_notebook_store_write() {
    SCS_FILE="$_nbw_store" SCS_MASTER_PASSWORD="$(_notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED")" \
        EXAKIT_NB_HOST="$_nbw_host" EXAKIT_NB_PORT="$_nbw_port" EXAKIT_NB_USER="${_nbw_user:-sys}" \
        EXAKIT_NB_PWFILE="$_nbw_pw" _notebook_py write_store.py 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
}

# notebook_connected — the connector opens the database from the store.
notebook_connected() {
    SCS_FILE="$(notebook_store_file)" SCS_MASTER_PASSWORD="$(_notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED")" \
        _notebook_py check_connection.py >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
}

# _notebook_folders <command> [args] — notebook/kit/notebooks.py, which places
# the kit's notebooks and prepares the folder for Positron. Standard library
# only: the venv's Python runs it, and before the venv is there any Python 3.
# Its stderr goes to the log and, when it fails, to the screen as warnings too:
# it names what could not be done. ⇄ twin: Invoke-NotebookFolders.
_notebook_folders() {
    _nbf_err="$(mktemp "${TMPDIR:-/tmp}/exakit-notebooks.XXXXXX" 2>/dev/null)" || _nbf_err=""
    if [ -x "$(notebook_venv_python)" ]; then
        "$(notebook_venv_python)" "$(exakit_repo_root)/notebook/kit/notebooks.py" "$@" 2>"${_nbf_err:-/dev/null}"
    else
        run_python_any "$(exakit_repo_root)/notebook/kit/notebooks.py" "$@" 2>"${_nbf_err:-/dev/null}"
    fi
    _nbf_rc=$?
    if [ -n "$_nbf_err" ]; then
        [ -s "$_nbf_err" ] && cat "$_nbf_err" >>"${EXAKIT_LOG_FILE:-/dev/null}"
        if [ "$_nbf_rc" -ne 0 ]; then
            while IFS= read -r _nbf_line; do
                [ -n "$_nbf_line" ] && warn "$_nbf_line"
            done < "$_nbf_err"
        fi
        rm -f "$_nbf_err"
    fi
    return "$_nbf_rc"
}

# notebook_copy_notebooks [jupyter|marimo] — the kit's notebooks into their
# persona folders, as notebook/catalog.json says: starter-kit-notebooks/<persona>/
# (with a README naming the end-to-end path) or marimo/<persona>/. One already
# there is the user's and is never overwritten; one the kit copied before and
# the user deleted is not copied again (.kit-copied in the folder lists them).
# Prints persona/file per one added. Fails, after a warning naming each one,
# when some could not be copied; the others are copied all the same.
notebook_copy_notebooks() {
    mkdir -p "$EXAKIT_NOTEBOOK_DIR" || { warn "The notebooks folder $EXAKIT_NOTEBOOK_DIR could not be created"; return 1; }
    _notebook_folders copy "${1:-jupyter}" "$(exakit_repo_root)" "$EXAKIT_NOTEBOOK_DIR"
}

# _notebook_report_copied <folder shown> [jupyter|marimo] — copy, then say what
# came: one line for the new ones, one warning when some could not be copied.
_notebook_report_copied() {
    _nrc_added="$(notebook_copy_notebooks "${2:-jupyter}")"
    _nrc_rc=$?
    _nrc_added="$(printf '%s' "$_nrc_added" | tr '\n' ' ' | sed 's/ *$//')"
    [ -n "$_nrc_added" ] && ok "New notebooks in $1: $_nrc_added"
    [ "$_nrc_rc" -eq 0 ] || warn "Some of the kit's notebooks could not be copied into $1 (named above)."
    return 0
}

# notebook_register_kernel — the kernel any Jupyter front end on the machine
# offers. Its spec carries paths only.
notebook_register_kernel() {
    _notebook_secret "$EXAKIT_NOTEBOOK_MASTER_CRED" >/dev/null
    EXAKIT_KERNEL_NAME="$EXAKIT_NOTEBOOK_KERNEL_NAME" EXAKIT_KERNEL_TITLE="$EXAKIT_NOTEBOOK_KERNEL_TITLE" \
        EXAKIT_NB_STORE="$(notebook_store_file)" EXAKIT_NB_MASTER_FILE="$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED" \
        EXAKIT_NB_KIT="$(exakit_repo_root)" EXAKIT_NB_DATASETS="$(exakit_repo_root)/data/datasets" \
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
        notebook_install_jupyter && return 0
        warn "JupyterLab could not be installed (see the log)."
    fi
    info "No JupyterLab: get it at $EXAKIT_NOTEBOOK_INSTALL_GUIDE, then run: exakit notebook"
    info "The kernel '$EXAKIT_NOTEBOOK_KERNEL_TITLE' is registered: VS Code or any Jupyter front end can use it now."
    return 1
}

# notebook_install_jupyter — the kit's JupyterLab, at its pin, into the kit's
# notebook environment: the connector's jupyter extra, in the one resolution
# with everything else (so an update keeps it). Also how one that was removed
# comes back.
notebook_install_jupyter() {
    EXAKIT_ACTIVE_LABEL="Installing JupyterLab"
    NOTEBOOK_ADD_JUPYTERLAB=1
    notebook_sync_packages; _nij_rc=$?
    NOTEBOOK_ADD_JUPYTERLAB=0
    [ "$_nij_rc" -eq 0 ] && [ -x "$EXAKIT_NOTEBOOK_VENV/bin/jupyter-lab" ] || return 1
    manifest_set components.notebook.jupyter kit
    _notebook_front_end_add jupyterlab
    ok "JupyterLab $(notebook_frontend_pin jupyterlab 2>/dev/null) installed into the kit's notebook environment"
}

# _notebook_tool_recorded <jupyterlab|marimo> — the user chose this tool before
# (the recorded notebook tools, or the kit installed it), so finding none now
# means it was REMOVED, not that it was never wanted.
_notebook_tool_recorded() {
    case ",$(manifest_get components.notebook.front_ends 2>/dev/null || true)," in *",$1,"*) return 0 ;; esac
    case "$1" in
        jupyterlab) [ "$(manifest_get components.notebook.jupyter 2>/dev/null || true)" = kit ] ;;
        marimo) [ "$(manifest_get components.notebook.marimo 2>/dev/null || true)" = kit ] ;;
        *) return 1 ;;
    esac
}

# notebook_jupyter_ready <setup 0|1> — a JupyterLab to open the notebooks in,
# before `exakit notebook` starts one. One that is there: 0. None (the kit's
# was removed from its environment, the user's own is no longer on PATH, or
# there never was one): on a terminal, a yes reinstalls the kit's (the safe
# default is yes: the user asked to open it); EXAKIT_NOTEBOOK_JUPYTER=install|
# skip answers for a script; --setup without a terminal installs (it is the
# command the other paths name). Otherwise no question: one line naming
# `exakit notebook setup`, and 1. Returns 2 when the user said no.
notebook_jupyter_ready() {
    notebook_find_jupyter >/dev/null 2>&1 && return 0
    if _notebook_tool_recorded jupyterlab; then
        _njr_what="JupyterLab is missing (it was removed from this machine)"
        _njr_ask="Reinstall JupyterLab $(notebook_frontend_pin jupyterlab 2>/dev/null) into the kit's notebook environment?"
    else
        _njr_what="No JupyterLab was found"
        _njr_ask="Install JupyterLab $(notebook_frontend_pin jupyterlab 2>/dev/null) into the kit's notebook environment?"
    fi
    _njr_answer="$(printf '%s' "${EXAKIT_NOTEBOOK_JUPYTER:-}" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$_njr_answer" ]; then
        if _notebook_on_terminal; then
            info "$_njr_what"
            if confirm "$_njr_ask" y; then _njr_answer=install; else _njr_answer=skip; fi
        elif [ "${1:-0}" = 1 ]; then
            _njr_answer=install
        else
            warn "$_njr_what - there is nothing to open the notebooks in. Install it with: exakit notebook setup"
            return 1
        fi
    fi
    if [ "$_njr_answer" = install ]; then
        notebook_install_jupyter && return 0
        warn "JupyterLab could not be installed (see ${EXAKIT_LOG_FILE:-the log}) - retry with: exakit notebook setup"
        return 1
    fi
    info "JupyterLab was not installed. Add it any time with: exakit notebook setup"
    info "The kernel '$EXAKIT_NOTEBOOK_KERNEL_TITLE' is registered: VS Code or any Jupyter front end can use it now."
    return 2
}

# --- the notebook tools: the install's checklist, Marimo, Positron ------------

# _notebook_skipped <value> — EXAKIT_NOTEBOOK_JUPYTER/MARIMO say leave it out.
_notebook_skipped() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in skip|no|0|false|none) return 0 ;; *) return 1 ;; esac
}

# _notebook_front_ends_given <value> [source] — a list of notebook tools made
# canonical: jupyterlab (jupyter is the same), marimo, positron, or none; any
# case, separated by commas or any whitespace. An unknown name is warned about
# (naming <source>) and dropped. Prints nothing when no known name is left.
# ⇄ twin: ConvertTo-NotebookFrontEnds in notebook.ps1.
_notebook_front_ends_given() {
    _nfg_j=""; _nfg_m=""; _nfg_p=""; _nfg_none=""
    while IFS= read -r _nfg_tok; do
        case "$_nfg_tok" in
            '') ;;
            jupyterlab|jupyter) _nfg_j=1 ;;
            marimo) _nfg_m=1 ;;
            positron) _nfg_p=1 ;;
            none) _nfg_none=1 ;;
            *) warn "${2:-EXAKIT_NOTEBOOK_FRONTENDS}: '$_nfg_tok' is not a notebook tool (jupyterlab, marimo, positron or none) - ignored" ;;
        esac
    done <<EXAKIT_NFG_EOF
$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr ',;' '  ' | tr -s '[:space:]' '\n')
EXAKIT_NFG_EOF
    _nfg_out=""
    [ -n "$_nfg_j" ] && _nfg_out="jupyterlab"
    [ -n "$_nfg_m" ] && _nfg_out="${_nfg_out:+$_nfg_out,}marimo"
    [ -n "$_nfg_p" ] && _nfg_out="${_nfg_out:+$_nfg_out,}positron"
    [ -z "$_nfg_out" ] && [ -n "$_nfg_none" ] && _nfg_out="none"
    printf '%s' "$_nfg_out"
}

# _notebook_front_end_add <tool> — a tool added after the install (exakit
# notebook setup | --marimo | --positron) joins the recorded choice, so an
# update keeps it.
_notebook_front_end_add() {
    _nfa_now="$(manifest_get components.notebook.front_ends 2>/dev/null || true)"
    [ -n "$_nfa_now" ] || return 0
    [ "$_nfa_now" = "none" ] && _nfa_now=""
    manifest_set components.notebook.front_ends "$(_notebook_front_ends_given "$_nfa_now,$1" 2>/dev/null)"
}

# notebook_default_front_ends — the notebook tools WITHOUT asking; sets
# NOTEBOOK_FRONT_ENDS (jupyterlab,marimo,positron or none). EXAKIT_NOTEBOOK_FRONTENDS
# answers it; else a reinstall or an update keeps the recorded choice; else all
# three, less any EXAKIT_NOTEBOOK_JUPYTER or EXAKIT_NOTEBOOK_MARIMO=skip leaves
# out. Returns 0 when that is an ANSWER (the variable or the record), 1 when it
# is only where a question would start: the checklist below, and the ticks of
# the tools' rows in the add-ons table (notebook_table_children).
# ⇄ twin: Get-NotebookDefaultFrontEnds in notebook.ps1.
notebook_default_front_ends() {
    NOTEBOOK_FRONT_ENDS=""
    if [ -n "${EXAKIT_NOTEBOOK_FRONTENDS:-}" ]; then
        NOTEBOOK_FRONT_ENDS="$(_notebook_front_ends_given "$EXAKIT_NOTEBOOK_FRONTENDS")"
        [ -n "$NOTEBOOK_FRONT_ENDS" ] && return 0
        warn "EXAKIT_NOTEBOOK_FRONTENDS names no notebook tool, so it is not used"
    fi
    _ndf_recorded="$(manifest_get components.notebook.front_ends 2>/dev/null || true)"
    if [ -n "$_ndf_recorded" ]; then
        NOTEBOOK_FRONT_ENDS="$(_notebook_front_ends_given "$_ndf_recorded" "the recorded notebook tools" 2>/dev/null)"
        [ -n "$NOTEBOOK_FRONT_ENDS" ] && return 0
    fi
    _notebook_skipped "${EXAKIT_NOTEBOOK_JUPYTER:-}" || NOTEBOOK_FRONT_ENDS="jupyterlab"
    _notebook_skipped "${EXAKIT_NOTEBOOK_MARIMO:-}" || NOTEBOOK_FRONT_ENDS="${NOTEBOOK_FRONT_ENDS:+$NOTEBOOK_FRONT_ENDS,}marimo"
    NOTEBOOK_FRONT_ENDS="${NOTEBOOK_FRONT_ENDS:+$NOTEBOOK_FRONT_ENDS,}positron"
    return 1
}

# notebook_choose_front_ends — which notebook tools; sets NOTEBOOK_FRONT_ENDS
# (jupyterlab,marimo,positron or none). notebook_default_front_ends answers it
# when it can (the variable, or the recorded choice); else (the first install,
# with no table that already asked) one checklist starting from its ticks, and
# without a terminal the ticks stand.
notebook_choose_front_ends() {
    notebook_default_front_ends && return 0
    _ncf_defaults=""
    case ",$NOTEBOOK_FRONT_ENDS," in *,jupyterlab,*) _ncf_defaults="1" ;; esac
    case ",$NOTEBOOK_FRONT_ENDS," in *,marimo,*) _ncf_defaults="${_ncf_defaults:+$_ncf_defaults,}2" ;; esac
    _ncf_defaults="${_ncf_defaults:+$_ncf_defaults,}3"
    ui_checkbox_menu "Notebook tools - untick any you do not want" "$_ncf_defaults" \
        "JupyterLab - notebooks in the browser with the kit's kernel; yours is used if you have one" \
        "Marimo - reactive notebooks, installed into the kit's notebook environment" \
        "Positron - your Positron, pointed at the kit's Python; never installed by the kit"
    NOTEBOOK_FRONT_ENDS=""
    for _ncf_i in $(printf '%s' "${EXAKIT_CHECKBOX_SELECTION:-}" | tr ',' ' '); do
        case "$_ncf_i" in
            1) NOTEBOOK_FRONT_ENDS="${NOTEBOOK_FRONT_ENDS:+$NOTEBOOK_FRONT_ENDS,}jupyterlab" ;;
            2) NOTEBOOK_FRONT_ENDS="${NOTEBOOK_FRONT_ENDS:+$NOTEBOOK_FRONT_ENDS,}marimo" ;;
            3) NOTEBOOK_FRONT_ENDS="${NOTEBOOK_FRONT_ENDS:+$NOTEBOOK_FRONT_ENDS,}positron" ;;
        esac
    done
    [ -n "$NOTEBOOK_FRONT_ENDS" ] || NOTEBOOK_FRONT_ENDS="none"
}

# notebook_questions — the marketplace's QUESTIONS FIRST hook: the notebook
# tools are asked before the install table animates (a checklist asked under a
# live table is redrawn over), and the answer is exported so the install that
# follows takes it without asking again. Only reached on a run whose table did
# not carry the tools as rows (a scripted EXAKIT_MARKETPLACE_ADDONS): where it
# did, the rows were the question (notebook_table_children_picked).
notebook_questions() {
    notebook_choose_front_ends
    EXAKIT_NOTEBOOK_FRONTENDS="$NOTEBOOK_FRONT_ENDS"
    export EXAKIT_NOTEBOOK_FRONTENDS
}

# notebook_table_children — the notebook tools as CHILD ROWS of the notebook's
# row in the marketplace's add-ons table (the optional <id>_table_children
# hook), one "<key>|<label>|<version>|<description>|<tick>" line each. The
# description says, before anything installs, what will become of each tool
# - from the find helpers alone, no network - and the ticks are
# notebook_default_front_ends'. The version is the pin the kit installs at;
# Positron has none, the kit never installs it.
# ⇄ twin: Get-NotebookTableChildren in notebook.ps1.
notebook_table_children() {
    notebook_default_front_ends || true
    _ntc_fronts=",$NOTEBOOK_FRONT_ENDS,"
    case "$(notebook_find_jupyter 2>/dev/null || true)" in
        own\ *)
            _ntc_jpath="$(notebook_find_jupyter 2>/dev/null)"
            _ntc_jdesc="yours ($(ui_tilde "${_ntc_jpath#own }")) is used as it is" ;;
        kit\ *) _ntc_jdesc="already in the kit's notebook environment" ;;
        *) _ntc_jdesc="not on this machine: installed into the kit's notebook environment" ;;
    esac
    if notebook_marimo_installed; then
        _ntc_mdesc="already installed"
    else
        _ntc_mdesc="installed into the kit's notebook environment"
    fi
    if notebook_find_positron >/dev/null 2>&1; then
        _ntc_pdesc="yours: pointed at the kit's Python"
    else
        _ntc_pdesc="not on this machine: the notebooks folder is prepared for it (positron.posit.co)"
    fi
    _ntc_tick() { case "$_ntc_fronts" in *",$1,"*) printf 1 ;; *) printf 0 ;; esac; }
    # A "|" would end the field in the table's state file.
    printf 'jupyterlab|JupyterLab|%s|%s|%s\n' "$(notebook_frontend_pin jupyterlab 2>/dev/null)" \
        "$(printf '%s' "$_ntc_jdesc" | tr '|' '/')" "$(_ntc_tick jupyterlab)"
    printf 'marimo|Marimo|%s|%s|%s\n' "$(notebook_frontend_pin marimo 2>/dev/null)" \
        "$_ntc_mdesc" "$(_ntc_tick marimo)"
    printf 'positron|Positron||%s|%s\n' "$_ntc_pdesc" "$(_ntc_tick positron)"
}

# notebook_table_children_picked <keys-csv> — the ticked tool rows ARE the
# answer: exported as EXAKIT_NOTEBOOK_FRONTENDS ("none" when no tool row was
# ticked), so the install takes it without asking.
# ⇄ twin: Set-NotebookTableChildrenPicked in notebook.ps1.
notebook_table_children_picked() {
    EXAKIT_NOTEBOOK_FRONTENDS="$(_notebook_front_ends_given "${1:-}" 2>/dev/null)"
    [ -n "$EXAKIT_NOTEBOOK_FRONTENDS" ] || EXAKIT_NOTEBOOK_FRONTENDS="none"
    export EXAKIT_NOTEBOOK_FRONTENDS
}

# notebook_plan_front_ends — which front ends the install's one resolution
# brings (NOTEBOOK_ADD_JUPYTERLAB, NOTEBOOK_ADD_MARIMO = 1 or 0), from the
# ticked tools: JupyterLab when it is ticked and the user has none of their own
# (a JupyterLab on PATH is used instead), Marimo when it is ticked.
notebook_plan_front_ends() {
    NOTEBOOK_ADD_JUPYTERLAB=0
    NOTEBOOK_ADD_MARIMO=0
    case ",$NOTEBOOK_FRONT_ENDS," in
        *,jupyterlab,*)
            case "$(notebook_find_jupyter 2>/dev/null || true)" in own\ *) ;; *) NOTEBOOK_ADD_JUPYTERLAB=1 ;; esac ;;
    esac
    case ",$NOTEBOOK_FRONT_ENDS," in *,marimo,*) NOTEBOOK_ADD_MARIMO=1 ;; esac
}

# notebook_front_ends_setup — the install's notebook tools, one line each:
# JupyterLab (the user's, or the kit's because it was ticked; the kernel is
# registered either way), Marimo, and the user's Positron set to the kit's Python.
# The tools were chosen before the packages were installed (notebook_install),
# so what the kit installs came with them; this settles what is left.
#
# Under the marketplace's live add-ons table each tool also settles its own
# row there (exakit_addon_table_child): the lines below then go to the logfile,
# as every detail of an install narrated by the table does.
notebook_front_ends_setup() {
    [ -n "${NOTEBOOK_FRONT_ENDS:-}" ] || notebook_choose_front_ends
    case ",$NOTEBOOK_FRONT_ENDS," in
        *,jupyterlab,*)
            if _nfs_found="$(notebook_find_jupyter)"; then
                case "$_nfs_found" in
                    kit\ *) _nfs_whose="the kit's"; manifest_set components.notebook.jupyter kit
                           _nfs_row="installed$(_notebook_pin_suffix jupyterlab)" ;;
                    *) _nfs_whose="yours"; _nfs_row="yours, kernel added" ;;
                esac
                ok "JupyterLab ($_nfs_whose: ${_nfs_found#* }) with the kernel '$EXAKIT_NOTEBOOK_KERNEL_TITLE' - open it with: exakit notebook"
                exakit_addon_table_child jupyterlab done "$_nfs_row" || true
            elif EXAKIT_NOTEBOOK_JUPYTER=install notebook_offer_jupyter; then
                exakit_addon_table_child jupyterlab done "installed$(_notebook_pin_suffix jupyterlab)" || true
            else
                exakit_addon_table_child jupyterlab failed "not installed - see the log" || true
            fi ;;
        *) info "JupyterLab not set up; the kernel '$EXAKIT_NOTEBOOK_KERNEL_TITLE' is registered for any Jupyter - add it any time: exakit notebook setup"
           exakit_addon_table_child jupyterlab skipped "" || true ;;
    esac
    case ",$NOTEBOOK_FRONT_ENDS," in
        *,marimo,*)
            if notebook_marimo_installed; then
                notebook_copy_notebooks marimo >/dev/null || true
                manifest_set components.notebook.marimo kit
            fi
            if notebook_marimo_installed || notebook_install_marimo; then
                ok "Marimo with the notebooks in $EXAKIT_NOTEBOOK_DIR/marimo - start it with: exakit notebook marimo"
                exakit_addon_table_child marimo done "installed$(_notebook_pin_suffix marimo)" || true
            else
                warn "Marimo could not be installed (see the log) - retry with: exakit notebook marimo"
                exakit_addon_table_child marimo failed "not installed - see the log" || true
            fi ;;
        *) info "Marimo not installed - add it any time: exakit notebook marimo"
           exakit_addon_table_child marimo skipped "" || true ;;
    esac
    case ",$NOTEBOOK_FRONT_ENDS," in
        *,positron,*)
            notebook_positron_note
            case $? in
                0) exakit_addon_table_child positron done "configured" || true ;;
                2) exakit_addon_table_child positron skipped "not on this machine - folder ready" || true ;;
                *) exakit_addon_table_child positron failed "folder not prepared - see the log" || true ;;
            esac ;;
        *) info "Positron not set up - any time: exakit notebook positron"
           exakit_addon_table_child positron skipped "" || true ;;
    esac
    manifest_set components.notebook.front_ends "$NOTEBOOK_FRONT_ENDS"
}

# _notebook_pin_suffix <jupyterlab|marimo> — " <pin>" for a tool's table row,
# nothing when no version is pinned.
_notebook_pin_suffix() {
    _nps_v="$(notebook_frontend_pin "$1" 2>/dev/null)" || return 0
    printf ' %s' "$_nps_v"
}

notebook_marimo_command() {
    printf '%s\n' "$EXAKIT_NOTEBOOK_VENV/bin/marimo"
}

notebook_marimo_installed() {
    [ -x "$(notebook_marimo_command)" ]
}

# notebook_install_marimo — Marimo, at its pin, into the kit's notebook
# environment (the one resolution, so an update keeps it), then the kit's
# Marimo notebooks into marimo/<persona>/.
notebook_install_marimo() {
    EXAKIT_ACTIVE_LABEL="Installing Marimo"
    NOTEBOOK_ADD_MARIMO=1
    notebook_sync_packages; _nim_rc=$?
    NOTEBOOK_ADD_MARIMO=0
    [ "$_nim_rc" -eq 0 ] || return 1
    notebook_marimo_installed || return 1
    notebook_copy_notebooks marimo >/dev/null || true
    manifest_set components.notebook.marimo kit
    _notebook_front_end_add marimo
}

# --- the servers: pid files, starting, waiting, stopping, logging in --------------

# _notebook_proc_ours <pid> <pattern> — the process is alive AND its command line
# matches <pattern> (a glob), so it is still the server the kit started. A pid
# file outlives its process; the system hands the number to someone else, and
# that program must never be reported as ours, waited for, or stopped.
_notebook_proc_ours() {
    case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$1" 2>/dev/null || return 1
    _npo_cmd="$(ps -p "$1" -o command= 2>/dev/null || true)"
    # shellcheck disable=SC2254
    case "$_npo_cmd" in $2) return 0 ;; *) return 1 ;; esac
}

# _notebook_live_pid <pidfile> <pattern> — the pid in the file while it is still
# ours; otherwise the file is stale: removed, and nothing printed (return 1).
_notebook_live_pid() {
    _nlp_pid="$(cat "$1" 2>/dev/null || true)"
    if _notebook_proc_ours "$_nlp_pid" "$2"; then
        printf '%s\n' "$_nlp_pid"
        return 0
    fi
    rm -f "$1"
    return 1
}

# _notebook_wait_up <answers fn> <port> <pidfile> <pattern> <label> <log> — wait
# until the server answers. Gives up at once when its process is gone, and after
# EXAKIT_NOTEBOOK_START_TIMEOUT seconds of wall time (not attempts: a port that
# accepts but never answers makes each probe slow).
_notebook_wait_up() {
    EXAKIT_ACTIVE_LABEL="Starting $5"
    ui_spin_begin "Starting $5"
    _nwu_start="$(date +%s)"
    while :; do
        "$1" "$2" && { ui_spin_end; return 0; }
        if ! _notebook_live_pid "$3" "$4" >/dev/null; then
            ui_spin_end
            warn "$5 stopped while it was starting - see $6"
            return 1
        fi
        [ $(( $(date +%s) - _nwu_start )) -lt "$EXAKIT_NOTEBOOK_START_TIMEOUT" ] || break
        sleep 1
    done
    ui_spin_end
    warn "$5 did not answer within ${EXAKIT_NOTEBOOK_START_TIMEOUT}s - see $6"
    return 1
}

# _notebook_kill <pid> — TERM, a few seconds to shut down (JupyterLab stops its
# kernels, the Marimo wrapper stops Marimo), then KILL for it and its children.
_notebook_kill() {
    kill "$1" 2>/dev/null || return 0
    _nk_i=0
    while kill -0 "$1" 2>/dev/null && [ "$_nk_i" -lt 20 ]; do
        sleep 0.5; _nk_i=$((_nk_i + 1))
    done
    if kill -0 "$1" 2>/dev/null; then
        pkill -KILL -P "$1" 2>/dev/null || true
        kill -KILL "$1" 2>/dev/null || true
    fi
}

# _notebook_spawn <dir> <pidfile> <log> <command...> — the server in the
# background with NO inherited stdio (stdin from /dev/null, stdout and stderr to
# its log), so it never holds the caller's terminal or pipe open
# (`exakit notebook | cat` returns), and its own pid in the pid file: one plain
# background command, which nohup execs, not a subshell around it. The caller's
# environment (the Jupyter token) reaches the server; its command line does not
# carry it.
_notebook_spawn() {
    _nsw_dir="$1"; _nsw_pidfile="$2"; _nsw_log="$3"
    shift 3
    ( cd "$_nsw_dir" || exit 1
      nohup "$@" </dev/null >>"$_nsw_log" 2>&1 &
      echo $! > "$_nsw_pidfile" )
}

# _notebook_open_file <jupyter|marimo> — the HTML file that logs the browser in.
_notebook_open_file() { printf '%s\n' "$EXAKIT_NOTEBOOK_HOME/open-$1.html"; }

# _notebook_open_logged_in <jupyter|marimo> <url with token> — the browser opens a
# short HTML file that forwards to the address, as Jupyter does: a token on the
# opener's command line (open, xdg-open, wslview) is readable by every process
# on the machine. The file is 0600 in the notebook home and goes when the
# server stops. Nothing is printed; return 1 when no browser could be opened.
_notebook_open_logged_in() {
    case "$2" in *[\"\<\>]*) return 1 ;; esac
    _nol_file="$(_notebook_open_file "$1")"
    _nol_url="${2//&/&amp;}"
    mkdir -p "$EXAKIT_NOTEBOOK_HOME" || return 1
    rm -f "$_nol_file"
    ( umask 077
      printf '<!DOCTYPE html>\n<html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=%s">\n<title>Opening the notebooks</title></head>\n<body><p><a href="%s">Open the notebooks</a></p></body></html>\n' \
          "$_nol_url" "$_nol_url" > "$_nol_file" ) || return 1
    chmod 600 "$_nol_file" 2>/dev/null || true
    _notebook_open_browser "$_nol_file"
}

# _notebook_open_browser <file or url> — the default browser; never printed.
_notebook_open_browser() {
    if command -v open >/dev/null 2>&1 && [ "$(detect_os 2>/dev/null)" = "macos" ]; then
        open "$1" </dev/null >/dev/null 2>&1
    elif command -v wslview >/dev/null 2>&1; then
        wslview "$1" </dev/null >/dev/null 2>&1
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$1" </dev/null >/dev/null 2>&1
    else
        return 1
    fi
}

# --- Marimo on demand --------------------------------------------------------------

_notebook_marimo_pidfile() { printf '%s\n' "$EXAKIT_NOTEBOOK_HOME/marimo.pid"; }
_notebook_marimo_logfile() { printf '%s\n' "${EXAKIT_LOG_DIR:-$EXAKIT_HOME/logs}/notebook-marimo.log"; }

# _notebook_marimo_answers <port> — Marimo's health check answers on this port.
_notebook_marimo_answers() {
    case "$(curl -s --connect-timeout 1 -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/health" 2>/dev/null)" in
        [234][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# _notebook_marimo_port — where Marimo starts next: EXAKIT_MARIMO_PORT, else
# the recorded port, else the default.
_notebook_marimo_port() {
    _nmp_port="$(manifest_get components.notebook.marimo_port 2>/dev/null || true)"
    [ -n "${EXAKIT_MARIMO_PORT:-}" ] && _nmp_port="$EXAKIT_MARIMO_PORT"
    printf '%s\n' "${_nmp_port:-$EXAKIT_NOTEBOOK_MARIMO_PORT}"
}

# _notebook_marimo_running_port — where the Marimo the kit started serves: the
# port recorded when it started.
_notebook_marimo_running_port() {
    _nmr_port="$(manifest_get components.notebook.marimo_port 2>/dev/null || true)"
    printf '%s\n' "${_nmr_port:-$EXAKIT_NOTEBOOK_MARIMO_PORT}"
}

# notebook_marimo_state — running|starting|stopped|not installed, from the
# pidfile the kit wrote (its process still Marimo's wrapper) and the health
# check on the recorded port.
notebook_marimo_state() {
    notebook_marimo_installed || { printf 'not installed\n'; return 0; }
    if _notebook_live_pid "$(_notebook_marimo_pidfile)" "$EXAKIT_NOTEBOOK_MARIMO_MATCH" >/dev/null; then
        if _notebook_marimo_answers "$(_notebook_marimo_running_port)"; then printf 'running\n'; else printf 'starting\n'; fi
        return 0
    fi
    printf 'stopped\n'
}

# notebook_marimo_start <port> — Marimo in the background on 127.0.0.1 over the
# kit's Marimo notebooks. Its token is a kit credential marimo reads from the
# FILE, and the wrapper masks it in the log: never on a command line or in a log.
notebook_marimo_start() {
    _nmt_port="$1"
    if _notebook_marimo_answers "$_nmt_port"; then
        warn "Port $_nmt_port already answers for another program - pick another with: exakit notebook marimo --port <number>"
        return 1
    fi
    _notebook_secret "$EXAKIT_NOTEBOOK_MARIMO_CRED" >/dev/null
    _nmt_dir="$EXAKIT_NOTEBOOK_DIR/marimo"
    _nmt_token="$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MARIMO_CRED"
    mkdir -p "$_nmt_dir" "$EXAKIT_NOTEBOOK_HOME" "$(dirname "$(_notebook_marimo_logfile)")"
    _notebook_spawn "$_nmt_dir" "$(_notebook_marimo_pidfile)" "$(_notebook_marimo_logfile)" \
        "$(notebook_venv_python)" "$(exakit_repo_root)/notebook/kit/marimo_wrapper.py" "$_nmt_token" \
        "$(notebook_marimo_command)" edit "$_nmt_dir" --headless --host 127.0.0.1 --port "$_nmt_port" \
        --token-password-file "$_nmt_token" --skip-update-check
    manifest_set components.notebook.marimo_port "$_nmt_port"
    _notebook_wait_up _notebook_marimo_answers "$_nmt_port" "$(_notebook_marimo_pidfile)" \
        "$EXAKIT_NOTEBOOK_MARIMO_MATCH" Marimo "$(_notebook_marimo_logfile)"
}

# notebook_marimo_stop [quiet] — stop the Marimo the kit started; a stale pid
# file is only removed.
notebook_marimo_stop() {
    if _nmx_pid="$(_notebook_live_pid "$(_notebook_marimo_pidfile)" "$EXAKIT_NOTEBOOK_MARIMO_MATCH")"; then
        _notebook_kill "$_nmx_pid"
        ok "Marimo stopped (your notebooks are saved in their folder)"
    else
        [ "${1:-}" = quiet ] || info "Marimo is not running"
    fi
    rm -f "$(_notebook_marimo_pidfile)" "$(_notebook_open_file marimo)"
}

# --- Positron ------------------------------------------------------------------------

# notebook_find_positron — the command that opens Positron on a folder: its CLI
# on PATH, else the installed app; nothing (return 1) when it is not there.
notebook_find_positron() {
    command -v positron 2>/dev/null && return 0
    for _nfp_app in /Applications/Positron.app "$HOME/Applications/Positron.app" /usr/bin/positron /usr/share/positron/positron; do
        [ -e "$_nfp_app" ] && { printf '%s\n' "$_nfp_app"; return 0; }
    done
    return 1
}

# notebook_prepare_positron — the notebooks folder as a Positron workspace whose
# interpreter is the kit's notebook Python (.vscode/settings.json; its other
# settings kept). VS Code's JSON with comments is read; a file with comments is
# never rewritten (that would lose them), so it fails, the file left alone and
# the reason warned, unless it already names the kit's Python.
notebook_prepare_positron() {
    _notebook_folders positron "$EXAKIT_NOTEBOOK_DIR" "$(notebook_venv_python)" "$EXAKIT_NOTEBOOK_VENV" >/dev/null
}

# notebook_positron_note — configure the folder for Positron and say what came of
# it. Positron itself is never installed. Returns 0 when Positron is here and
# now opens the folder with the kit's Python, 2 when it is not on this machine
# (the folder is ready for it), 1 when the folder could not be prepared (the
# reason warned) - so the tool's row in the add-ons table can say which.
notebook_positron_note() {
    notebook_prepare_positron || return 1
    if _npn_found="$(notebook_find_positron)"; then
        ok "Positron ($_npn_found) opens the notebooks with the kit's Python: exakit notebook positron"
        return 0
    fi
    info "Positron is not on this machine, so there is nothing to configure in it - the notebooks folder is ready for it: $EXAKIT_NOTEBOOK_POSITRON_DOWNLOAD"
    return 2
}

# notebook_open_positron — Positron on the notebooks folder.
notebook_open_positron() {
    _nop_cmd="$(notebook_find_positron)" || return 1
    case "$_nop_cmd" in
        *.app) open -a "$_nop_cmd" "$EXAKIT_NOTEBOOK_DIR" </dev/null >/dev/null 2>&1 ;;
        *) ( nohup "$_nop_cmd" "$EXAKIT_NOTEBOOK_DIR" </dev/null >/dev/null 2>&1 & ) ;;
    esac
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

# notebook_frontend_pin <jupyterlab|marimo> — the version of a front end the kit
# installs: EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION / EXAKIT_NOTEBOOK_MARIMO_VERSION
# when set, else versions.json components.notebook.frontends.<name> - the
# advertised document, then the kit copy's own (an advertised document older
# than this kit copy has no such key). Nothing (return 1) when neither names a
# version in the safe charset: it goes on a uv command line.
# ⇄ twin: Get-NotebookFrontendPin in notebook.ps1.
notebook_frontend_pin() {
    case "$1" in
        jupyterlab) _nfp_v="${EXAKIT_NOTEBOOK_JUPYTERLAB_VERSION:-}" ;;
        marimo) _nfp_v="${EXAKIT_NOTEBOOK_MARIMO_VERSION:-}" ;;
        *) return 1 ;;
    esac
    [ -n "$_nfp_v" ] || _nfp_v="$(exakit_versions_value "components.notebook.frontends.$1" 2>/dev/null || true)"
    if [ -z "$_nfp_v" ]; then
        _nfp_doc="$(exakit_versions_baked_doc 2>/dev/null || true)"
        [ -n "$_nfp_doc" ] && _nfp_v="$(exakit_versions_value "components.notebook.frontends.$1" "$_nfp_doc" 2>/dev/null || true)"
    fi
    case "$_nfp_v" in ''|*[!A-Za-z0-9._+-]*) return 1 ;; esac
    printf '%s\n' "$_nfp_v"
}

# _notebook_frontends_installed — "<name>=<version>" for each front end the
# kit's venv holds (jupyterlab, marimo), one per line; nothing without a venv.
_notebook_frontends_installed() {
    [ -x "$(notebook_venv_python)" ] || return 0
    "$(notebook_venv_python)" -c 'import sys
from importlib.metadata import PackageNotFoundError, version
for name in sys.argv[1:]:
    try:
        print(name + "=" + version(name))
    except PackageNotFoundError:
        pass' jupyterlab marimo 2>/dev/null || true
}

# _notebook_specs — the connector with its extras, the companion packages, the
# front ends the kit installs (asked for now: NOTEBOOK_ADD_JUPYTERLAB /
# NOTEBOOK_ADD_MARIMO=1, or already in the venv) at their pins, and the two
# packages the kit carries, one per line (for one uv resolution). JupyterLab is
# the connector's jupyter extra, its version held by jupyterlab==<pin>. A front
# end with no pin: JupyterLab comes within the connector's own range, Marimo is
# left out, each with a warning.
_notebook_specs() {
    _nsp_extras="$EXAKIT_NOTEBOOK_EXTRAS"
    _nsp_lines=""
    if [ "${NOTEBOOK_ADD_JUPYTERLAB:-0}" = 1 ] || [ -x "$EXAKIT_NOTEBOOK_VENV/bin/jupyter-lab" ]; then
        _nsp_extras="$_nsp_extras,jupyter"
        if _nsp_pin="$(notebook_frontend_pin jupyterlab)"; then
            _nsp_lines="jupyterlab==$_nsp_pin"
        else
            warn "No JupyterLab version is pinned (versions.json components.notebook.frontends.jupyterlab) - the connector's range decides"
        fi
    fi
    if [ "${NOTEBOOK_ADD_MARIMO:-0}" = 1 ] || notebook_marimo_installed; then
        if _nsp_pin="$(notebook_frontend_pin marimo)"; then
            _nsp_lines="${_nsp_lines:+$_nsp_lines }marimo==$_nsp_pin"
        else
            warn "No Marimo version is pinned (versions.json components.notebook.frontends.marimo) - Marimo is left out"
        fi
    fi
    printf '%s[%s]==%s\n' "$EXAKIT_NOTEBOOK_PACKAGE" "$_nsp_extras" "${EXAKIT_NOTEBOOK_VERSION:-$(notebook_package_version 2>/dev/null)}"
    for _nbs_pkg in $EXAKIT_NOTEBOOK_PACKAGES $_nsp_lines; do printf '%s\n' "$_nbs_pkg"; done
    printf '%s\n' "$(exakit_repo_root)/notebook/package" "$(exakit_repo_root)/packages/exasol-mlflow"
}

# _notebook_report_frontends <before> — after a resolution: one line for each
# front end whose version moved (a new pin), compared with <before>
# (_notebook_frontends_installed's output from before it).
_notebook_report_frontends() {
    _notebook_frontends_installed | while IFS='=' read -r _nrf_name _nrf_now; do
        _nrf_was="$(printf '%s\n' "$1" | sed -n "s/^$_nrf_name=//p")"
        [ -n "$_nrf_was" ] && [ "$_nrf_was" != "$_nrf_now" ] && \
            ok "$_nrf_name $_nrf_was -> $_nrf_now (the version versions.json pins)"
    done
    return 0
}

# notebook_sync_packages — the whole set into the venv in one resolution, with
# the kit's own two packages REINSTALLED from this kit copy: their version
# numbers rarely move, so uv would otherwise keep the copy an older kit
# installed and a new notebook would run against old helpers. A front end the
# kit installed is in the set at its pin, so a pin that moved moves it too
# (said in one line). Cheap when nothing else changed. ⇄ twin: Sync-NotebookPackages.
notebook_sync_packages() {
    _nsy_uv="$(_notebook_uv)" || return 1
    # CPU-only PyTorch on Linux: the default wheel pulls gigabytes of CUDA.
    _nsy_torch=""
    [ "$(detect_os 2>/dev/null)" = "macos" ] || _nsy_torch="--torch-backend cpu"
    _nsy_reinstall=""
    for _nsy_pkg in $EXAKIT_NOTEBOOK_OWN_PACKAGES; do _nsy_reinstall="$_nsy_reinstall --reinstall-package $_nsy_pkg"; done
    _nsy_before="$(_notebook_frontends_installed)"
    # shellcheck disable=SC2046,SC2086
    run_logged "$_nsy_uv" pip install --python "$(notebook_venv_python)" $_nsy_torch $_nsy_reinstall $(_notebook_specs) || return 1
    _notebook_report_frontends "$_nsy_before"
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
    # The notebook tools first: the front ends the kit installs join the
    # connector's own resolution below.
    notebook_choose_front_ends
    notebook_plan_front_ends
    _nbi_current="$(notebook_package_version || true)"
    if [ -n "$_nbi_current" ] && [ "$_nbi_current" = "$EXAKIT_NOTEBOOK_VERSION" ] && \
       [ "${EXAKIT_FORCE_COMPONENT_INSTALL:-0}" != "1" ]; then
        ok "notebook $_nbi_current already installed: $EXAKIT_NOTEBOOK_VENV"
        EXAKIT_ACTIVE_LABEL="Refreshing the kit's notebook helpers"
        notebook_sync_packages || warn "The kit's notebook helpers could not be refreshed (see the log) - retry with: exakit update notebook"
    else
        EXAKIT_ACTIVE_LABEL="Installing the notebook connector $EXAKIT_NOTEBOOK_VERSION"
        info "Installing the notebook connector $EXAKIT_NOTEBOOK_VERSION (about 1 GB: it brings PyTorch for its transformer features)"
        if [ ! -x "$(notebook_venv_python)" ]; then
            # A venv whose Python is gone (its base interpreter removed, or the
            # folder half deleted) is made again from nothing: uv will not
            # create one over it. Only a folder that IS a venv, or is empty.
            if [ -d "$EXAKIT_NOTEBOOK_VENV" ] && { [ -f "$EXAKIT_NOTEBOOK_VENV/pyvenv.cfg" ] || \
                    [ -z "$(ls -A "$EXAKIT_NOTEBOOK_VENV" 2>/dev/null)" ]; }; then
                rm -rf "$EXAKIT_NOTEBOOK_VENV"
            fi
            if ! run_logged "$_nbi_uv" venv --python "$EXAKIT_MANAGED_PYTHON_VERSION" "$EXAKIT_NOTEBOOK_VENV"; then
                _notebook_not_installed "the virtual environment at $EXAKIT_NOTEBOOK_VENV could not be created (see log)"
                return 1
            fi
            push_rollback "rm -rf '$EXAKIT_NOTEBOOK_VENV'"
        fi
        if ! notebook_sync_packages; then
            _notebook_not_installed "installing ${EXAKIT_NOTEBOOK_PACKAGE}==${EXAKIT_NOTEBOOK_VERSION} and its companions failed (see log)"
            return 1
        fi
        if [ -z "$(notebook_package_version || true)" ]; then
            _notebook_not_installed "the venv cannot report a ${EXAKIT_NOTEBOOK_PACKAGE} version after the install (see log)"
            return 1
        fi
        ok "Notebook connector installed: $EXAKIT_NOTEBOOK_VENV"
    fi
    _notebook_report_copied "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks"
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
    manifest_set components.notebook.master_file "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED"
    manifest_set components.notebook.kernel "$EXAKIT_NOTEBOOK_KERNEL_NAME"
    notebook_front_ends_setup
    return 0
}

# notebook_validate — the packages import; with the database up, the connector
# connects from the store. Soft: records validated and returns 0.
notebook_validate() {
    [ -x "$(notebook_venv_python)" ] || return 0
    if ! "$(notebook_venv_python)" -c 'import exasol.nb_connector, exakit.nb, exakit_nb, exasol_mlflow, ipykernel' >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
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
        warn "The notebook connector could not connect - check with: exakit notebook check"
    fi
    return 0
}

notebook_update() {
    _nbu_available="$(exakit_component_available notebook 2>/dev/null || true)"
    [ -n "$_nbu_available" ] || die "Could not resolve the advertised notebook connector version."
    _nbu_current="$(notebook_installed_version 2>/dev/null || true)"
    if [ -n "$_nbu_current" ] && [ "$_nbu_current" = "$_nbu_available" ]; then
        # The connector pin stands still, but this kit copy may carry new
        # notebooks, new helpers or a new companion package: bring the venv in
        # line with it before the notebooks are copied.
        EXAKIT_NOTEBOOK_VERSION="$_nbu_current"
        EXAKIT_ACTIVE_LABEL="Refreshing the kit's notebook helpers"
        notebook_sync_packages || warn "The kit's notebook helpers could not be refreshed (see the log) - retry with: exakit update notebook"
        notebook_copy_notebooks >/dev/null || true
        notebook_marimo_installed && { notebook_copy_notebooks marimo >/dev/null || true; }
        manifest_set components.notebook.master_file "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED"
        notebook_register_kernel || true
        notebook_validate || true
        ok "notebook is already current ($_nbu_current); the kit's notebook helpers were refreshed"
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

# notebook_log_path — what `exakit logs` shows for this add-on, one log per
# line as "target|what|path": the JupyterLab and the Marimo server's.
notebook_log_path() {
    printf 'notebook|JupyterLab (exakit notebook)|%s\n' "$(_notebook_logfile)"
    printf 'notebook-marimo|Marimo (notebook marimo)|%s\n' "$(_notebook_marimo_logfile)"
}

# --- JupyterLab on demand --------------------------------------------------------

_notebook_pidfile() { printf '%s\n' "$EXAKIT_NOTEBOOK_HOME/jupyter.pid"; }
_notebook_logfile() { printf '%s\n' "${EXAKIT_LOG_DIR:-$EXAKIT_HOME/logs}/notebook.log"; }

# _notebook_api_answers <port> — JupyterLab's /api answers on this port.
_notebook_api_answers() {
    curl -fsS --connect-timeout 1 -m 2 "http://127.0.0.1:$1/api" 2>/dev/null | grep -q '"version"'
}

# _notebook_server_port — where the JupyterLab the kit started serves: the port
# recorded when it started.
_notebook_server_port() {
    _nsr_port="$(manifest_get components.notebook.port 2>/dev/null || true)"
    printf '%s\n' "${_nsr_port:-$EXAKIT_NOTEBOOK_PORT}"
}

# notebook_server_state — running|starting|stopped, from the pidfile the kit
# wrote (its process still the JupyterLab the kit started) and the API on the
# recorded port (a JupyterLab the kit did not start is never reported as ours).
notebook_server_state() {
    if _notebook_live_pid "$(_notebook_pidfile)" "$EXAKIT_NOTEBOOK_JUPYTER_MATCH" >/dev/null; then
        if _notebook_api_answers "$(_notebook_server_port)"; then printf 'running\n'; else printf 'starting\n'; fi
        return 0
    fi
    printf 'stopped\n'
}

# _notebook_jupyter_config — the kit's JupyterLab settings file, written fresh
# on every start, and its path: the file browser hides the Marimo copies (the
# marimo/ folder - they open in Marimo, `exakit notebook marimo`) beside
# Jupyter's own defaults (caches, checkpoints). Jupyter reads it through
# --config, so a JupyterLab of the user's own is never configured globally.
_notebook_jupyter_config() {
    _njc="$EXAKIT_NOTEBOOK_HOME/jupyter_server_config.json"
    printf '%s\n' '{"ContentsManager": {"hide_globs": ["__pycache__", "*.pyc", "*.pyo", ".DS_Store", "*~", ".ipynb_checkpoints", "marimo"]}}' > "$_njc" || return 1
    printf '%s\n' "$_njc"
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
    mkdir -p "$EXAKIT_NOTEBOOK_DIR" "$EXAKIT_NOTEBOOK_HOME" "$(dirname "$(_notebook_logfile)")"
    JUPYTER_TOKEN="$(_notebook_secret "$EXAKIT_NOTEBOOK_TOKEN_CRED")" \
        _notebook_spawn "$EXAKIT_NOTEBOOK_DIR" "$(_notebook_pidfile)" "$(_notebook_logfile)" \
        "$_nst_cmd" --no-browser --ServerApp.ip=127.0.0.1 "--ServerApp.port=$_nst_port" \
        --ServerApp.port_retries=0 "--ServerApp.root_dir=$EXAKIT_NOTEBOOK_DIR" \
        "--config=$(_notebook_jupyter_config)"
    manifest_set components.notebook.port "$_nst_port"
    _notebook_wait_up _notebook_api_answers "$_nst_port" "$(_notebook_pidfile)" \
        "$EXAKIT_NOTEBOOK_JUPYTER_MATCH" JupyterLab "$(_notebook_logfile)"
}

# notebook_server_stop [quiet] — stop the JupyterLab the kit started; a stale
# pid file is only removed.
notebook_server_stop() {
    if _nsp_pid="$(_notebook_live_pid "$(_notebook_pidfile)" "$EXAKIT_NOTEBOOK_JUPYTER_MATCH")"; then
        _notebook_kill "$_nsp_pid"
        ok "JupyterLab stopped"
    else
        [ "${1:-}" = quiet ] || info "JupyterLab is not running"
    fi
    rm -f "$(_notebook_pidfile)" "$(_notebook_open_file jupyter)"
}

# --- the launcher: what `exakit notebook` checks before it opens anything ----------

# _notebook_on_terminal — someone is there to answer: a terminal to read from
# (what confirm and the menus read) and one being written to (a menu drawn into
# a pipe is noise). Without one, nothing is asked. ⇄ twin: Test-NotebookOnTerminal.
_notebook_on_terminal() {
    [ -t 1 ] && [ -n "$(_exakit_prompt_tty)" ]
}

# notebook_env_state — ok, missing (the venv's Python is gone: the venv was
# deleted, or the interpreter it was made from) or broken (the connector or the
# kit's helpers do not import). ⇄ twin: Get-NotebookEnvState.
notebook_env_state() {
    [ -x "$(notebook_venv_python)" ] || { printf 'missing\n'; return 0; }
    if "$(notebook_venv_python)" -c 'import exasol.nb_connector, exakit.nb' >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        printf 'ok\n'
    else
        printf 'broken\n'
    fi
}

# notebook_repair_env — the notebook environment installed again, at the
# version the kit recorded, with the recorded notebook tools: the install
# itself, made to run the whole way (EXAKIT_FORCE_COMPONENT_INSTALL). In a
# subshell, so an install that dies leaves the launcher to say what to do. 0
# when the environment imports afterwards. ⇄ twin: Repair-NotebookEnv.
notebook_repair_env() {
    ( EXAKIT_NOTEBOOK_VERSION="$(manifest_get components.notebook.version 2>/dev/null || true)"
      EXAKIT_FORCE_COMPONENT_INSTALL=1
      export EXAKIT_NOTEBOOK_VERSION EXAKIT_FORCE_COMPONENT_INSTALL
      notebook_install ) || return 1
    [ "$(notebook_env_state)" = ok ]
}

# _notebook_start_database — the database started the way `exakit start
# database` starts it (_start_database in the exakit CLI: a stopped one is
# started, a missing deployment made), in a subshell so a start that dies
# leaves the launcher to say so; then asked again whether it answers SQL.
# ⇄ twin: Start-NotebookDatabase.
_notebook_start_database() {
    if command -v _start_database >/dev/null 2>&1; then
        ( exakit_init_logging >/dev/null 2>&1 || true; _start_database )
    else
        ( exakit_ensure_runtime_running deploy )
    fi
    command -v exakit_forget_db_reachable >/dev/null 2>&1 && exakit_forget_db_reachable
    exakit_db_reachable
}

# _notebook_port_in_use <port> — something already accepts connections on
# 127.0.0.1:<port> (curl's 7 is "could not connect": the port is free).
# ⇄ twin: Test-NotebookPortInUse.
_notebook_port_in_use() {
    curl -s -o /dev/null --connect-timeout 1 -m 2 "http://127.0.0.1:$1/" 2>/dev/null
    [ $? -ne 7 ]
}

# _notebook_pick_port <tool> <port> <given 0|1> <command> — the port a server
# the kit starts will serve on; sets NOTEBOOK_PICKED_PORT. A free one is used.
# One another program holds is refused when --port named it (the message names
# <command> --port); otherwise the next free one, at most
# EXAKIT_NOTEBOOK_PORT_TRIES above it, is used and said in one line (the start
# records it, so the next start begins there). The server the kit started is
# never what is in the way: a running one is reused before a port is picked.
# ⇄ twin: Select-NotebookPort.
_notebook_pick_port() {
    NOTEBOOK_PICKED_PORT="$2"
    _notebook_port_in_use "$2" || return 0
    if [ "$3" = 1 ]; then
        warn "Port $2 is in use by another program - pick another with: $4 --port <number>"
        return 1
    fi
    _npk_try=$(( $2 + 1 ))
    _npk_last=$(( $2 + EXAKIT_NOTEBOOK_PORT_TRIES ))
    while [ "$_npk_try" -le "$_npk_last" ] && [ "$_npk_try" -le 65535 ]; do
        if ! _notebook_port_in_use "$_npk_try"; then
            NOTEBOOK_PICKED_PORT="$_npk_try"
            info "Port $2 is in use by another program, so $1 uses port $_npk_try"
            return 0
        fi
        _npk_try=$((_npk_try + 1))
    done
    warn "Ports $2 to $_npk_last are all in use by other programs - pick a free one with: $4 --port <number>"
    return 1
}

# _notebook_preflight — what `exakit notebook` makes sure of before it opens
# anything, each problem said in one line and fixed or offered: the notebook
# environment (missing or not importing: repaired), the database (not running,
# or the connection lost: started, then the notebooks' own connection checked),
# the connection store (written again from the kit's record; one that cannot be
# read is replaced), the kernel (registered again, in case it was removed) and
# the notebooks folder (made again with the kit's notebooks when it was
# deleted). A fix that needs a yes is asked on a terminal, yes being the
# default (the user asked to open the notebooks); without a terminal nothing is
# asked and the command that fixes it is named. 1 when the notebooks could not
# work: nothing is opened then. ⇄ twin: Invoke-NotebookPreflight.
_notebook_preflight() {
    _npl_env="$(notebook_env_state)"
    if [ "$_npl_env" != ok ]; then
        if [ "$_npl_env" = missing ]; then
            _npl_what="The notebook environment is missing (its Python, $(notebook_venv_python), is gone)"
        else
            _npl_what="The notebook environment is broken (the notebook connector or the kit's helpers do not import)"
        fi
        if ! _notebook_on_terminal; then
            warn "$_npl_what - nothing was opened. Repair it with: exakit update notebook"
            return 1
        fi
        warn "$_npl_what"
        if ! confirm "Repair it now? The kit's notebook environment is installed again (about 1 GB)" y; then
            info "Nothing was opened. Repair it any time with: exakit update notebook"
            return 1
        fi
        if ! notebook_repair_env; then
            warn "The notebook environment could not be repaired (see ${EXAKIT_LOG_FILE:-the log}) - retry with: exakit update notebook"
            return 1
        fi
        ok "The notebook environment is repaired"
    fi
    _npl_started=0
    if ! exakit_db_reachable; then
        _notebook_on_terminal || die "The database is not running. Start it with: exakit start"
        warn "The database is not running, or the connection to it was lost"
        if ! confirm "Start the database now?" y; then
            info "Nothing was opened. Start it with: exakit start - then: exakit notebook"
            return 1
        fi
        if ! _notebook_start_database; then
            warn "The database still does not answer, so nothing was opened - see: exakit status   (and its log: exakit logs)"
            return 1
        fi
        _npl_started=1
    fi
    if _npl_conn="$(notebook_write_connection)"; then
        case "$_npl_conn" in
            changed) info "The database connection changed; the notebooks now use the new one" ;;
            new) info "The notebooks' connection store could not be read (its master password was gone, or the store was damaged), so a new one was written from the kit's connection" ;;
        esac
    else
        warn "The notebooks' connection could not be refreshed (see the log) - repair with: exakit update notebook"
    fi
    # Just started: the database answering SQL is not yet the notebooks
    # connecting through their own store, so that is proven before anything
    # opens (on a database that was already up, a launch stays quick).
    if [ "$_npl_started" = 1 ] && ! notebook_connected; then
        warn "The database is up, but the notebooks cannot connect to it, so nothing was opened - see: exakit status   (and its log: exakit logs)"
        return 1
    fi
    notebook_register_kernel || warn "The kernel could not be registered again (see the log)."
    if [ -d "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks" ]; then
        _notebook_report_copied "$EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks"
    elif notebook_copy_notebooks >/dev/null; then
        # The record of what the kit copied lives in the folder, so a folder
        # deleted whole gets every notebook back; one notebook deleted from a
        # folder that is still there stays deleted.
        info "The notebooks folder was gone, so it was made again with the kit's notebooks: $EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks"
    else
        warn "Some of the kit's notebooks could not be copied into $EXAKIT_NOTEBOOK_DIR/starter-kit-notebooks (named above)."
    fi
    return 0
}

# --- the launcher: which tools to open ---------------------------------------------

# notebook_jupyter_state — what the menu says of JupyterLab, decided before it
# asks: "running <port>" (the one the kit started, up or coming up), "kit
# <version>", "own <path>", "missing" (none, though the user chose it before:
# it was removed) or "none" (never set up). ⇄ twin: Get-NotebookJupyterState.
notebook_jupyter_state() {
    case "$(notebook_server_state)" in
        running|starting) printf 'running %s\n' "$(_notebook_server_port)"; return 0 ;;
    esac
    if _njs_found="$(notebook_find_jupyter 2>/dev/null)"; then
        case "$_njs_found" in
            kit\ *)
                _njs_v="$(_notebook_frontends_installed | sed -n 's/^jupyterlab=//p')"
                [ -n "$_njs_v" ] || _njs_v="$(notebook_frontend_pin jupyterlab 2>/dev/null)"
                printf 'kit %s\n' "$_njs_v" ;;
            *) printf 'own %s\n' "${_njs_found#own }" ;;
        esac
        return 0
    fi
    if _notebook_tool_recorded jupyterlab; then printf 'missing\n'; else printf 'none\n'; fi
}

# notebook_marimo_menu_state — the same for Marimo: "running <port>", ready,
# missing or none. ⇄ twin: Get-NotebookMarimoMenuState.
notebook_marimo_menu_state() {
    case "$(notebook_marimo_state)" in
        running|starting) printf 'running %s\n' "$(_notebook_marimo_running_port)" ;;
        stopped) printf 'ready\n' ;;
        *) if _notebook_tool_recorded marimo; then printf 'missing\n'; else printf 'none\n'; fi ;;
    esac
}

# notebook_menu_labels <jupyterlab state> <marimo state> <positron found 0|1> —
# the menu's three rows, one per line, each saying its tool's state. Positron
# not on this machine is a "!" row: shown, with where to get it, never picked.
# ⇄ twin: Get-NotebookMenuLabels.
notebook_menu_labels() {
    case "$1" in
        running\ *) printf 'JupyterLab - running at http://127.0.0.1:%s/lab\n' "${1#running }" ;;
        kit\ *) printf "JupyterLab - ready (the kit's %s)\n" "${1#kit }" ;;
        own\ *) printf 'JupyterLab - ready (yours: %s)\n' "$(ui_tilde "${1#own }")" ;;
        missing) printf "JupyterLab - missing - reinstall it into the kit's environment\n" ;;
        *) printf "JupyterLab - not installed - installs it into the kit's environment\n" ;;
    esac
    case "$2" in
        running\ *) printf 'Marimo - running at http://127.0.0.1:%s/\n' "${2#running }" ;;
        ready) printf 'Marimo - ready\n' ;;
        missing) printf "Marimo - missing - reinstall it into the kit's environment\n" ;;
        *) printf 'Marimo - not installed - installs it\n' ;;
    esac
    if [ "$3" = 1 ]; then
        printf 'Positron - found - opens on the notebooks folder\n'
    else
        printf '!Positron - not on this machine (get it at positron.posit.co)\n'
    fi
}

# notebook_menu_defaults <positron found 0|1> — the rows ticked at first, as a
# csv: the notebook tools the user chose (components.notebook.front_ends) that
# can open - JupyterLab and Marimo always can (one that is missing is installed
# again), Positron only when it is here - and JupyterLab when that leaves none.
# ⇄ twin: Get-NotebookMenuDefaults.
notebook_menu_defaults() {
    _nmd_rec=",$(manifest_get components.notebook.front_ends 2>/dev/null || true),"
    _nmd=""
    case "$_nmd_rec" in *,jupyterlab,*) _nmd="1" ;; esac
    case "$_nmd_rec" in *,marimo,*) _nmd="${_nmd:+$_nmd,}2" ;; esac
    if [ "$1" = 1 ]; then
        case "$_nmd_rec" in *,positron,*) _nmd="${_nmd:+$_nmd,}3" ;; esac
    fi
    printf '%s\n' "${_nmd:-1}"
}

# notebook_open_menu <browser 0|1> — plain `exakit notebook` on a terminal: one
# multi-select, "Open which notebook tools?", each row saying its tool's state,
# with Skip as the answer that opens nothing. Each tool picked is then opened
# in turn - JupyterLab and Marimo started in the background (or the running one
# reused) and opened logged in, Positron on the notebooks folder - one line each
# with its address, and then one line naming how to stop them. 1 when a tool
# picked could not be opened; the others are opened all the same.
# ⇄ twin: Invoke-NotebookOpenMenu.
notebook_open_menu() {
    _nom_p=0
    notebook_find_positron >/dev/null 2>&1 && _nom_p=1
    _nom_labels="$(notebook_menu_labels "$(notebook_jupyter_state)" "$(notebook_marimo_menu_state)" "$_nom_p")"
    _nom_l1="$(printf '%s\n' "$_nom_labels" | sed -n 1p)"
    _nom_l2="$(printf '%s\n' "$_nom_labels" | sed -n 2p)"
    _nom_l3="$(printf '%s\n' "$_nom_labels" | sed -n 3p)"
    EXAKIT_CHECKBOX_EXCLUSIVE=4
    ui_checkbox_menu "Open which notebook tools?" "$(notebook_menu_defaults "$_nom_p")" \
        "$_nom_l1" "$_nom_l2" "$_nom_l3" "Skip - open nothing"
    _nom_sel=",${EXAKIT_CHECKBOX_SELECTION:-},"
    case "$_nom_sel" in
        *,4,*|,,) info "Nothing opened. Open the notebook tools any time with: exakit notebook"; return 0 ;;
    esac
    _nom_rc=0; _nom_servers=""; _nom_positron=0
    _NOTEBOOK_MANY=1
    case "$_nom_sel" in
        *,1,*)
            notebook_jupyter_cmd 0 "$1" ""
            case $? in 0) _nom_servers="JupyterLab" ;; 2) ;; *) _nom_rc=1 ;; esac ;;
    esac
    case "$_nom_sel" in
        *,2,*)
            notebook_marimo_cmd 0 "$1" ""
            case $? in 0) _nom_servers="${_nom_servers:+$_nom_servers and }Marimo" ;; 2) ;; *) _nom_rc=1 ;; esac ;;
    esac
    case "$_nom_sel" in
        *,3,*) if notebook_positron_cmd; then _nom_positron=1; else _nom_rc=1; fi ;;
    esac
    _NOTEBOOK_MANY=0
    if [ -n "$_nom_servers" ]; then
        if [ "$_nom_positron" = 1 ]; then
            info "To stop $_nom_servers: exakit notebook stop   (Positron is yours to close)"
        else
            info "To stop $_nom_servers: exakit notebook stop"
        fi
    fi
    return "$_nom_rc"
}

# _notebook_running_line <tool> <address> <stop command> — the one line saying a
# server is up. Opened from the menu, the stop command is said once, after the
# last tool, instead.
_notebook_running_line() {
    if [ "${_NOTEBOOK_MANY:-0}" = 1 ]; then
        ok "$1 is running: $2"
    else
        ok "$1 is running: $2   (stop it with: $3)"
    fi
}

# notebook_cmd [jupyterlab|marimo|positron] [check] [setup] [stop] [--no-browser]
# [--port N] — the `exakit notebook` command (each word also as a --flag).
# Plain, on a terminal: the menu of notebook tools (notebook_open_menu); plain
# without one, with jupyterlab, or with --port (it is JupyterLab's port),
# JupyterLab; marimo Marimo, positron the user's Positron on the notebooks
# folder. Every form but stop first goes
# through _notebook_preflight. Exit 1 when what was asked could not be opened.
notebook_cmd() {
    _nbc_check=0; _nbc_setup=0; _nbc_stop=0; _nbc_browser=1; _nbc_port=""; _nbc_front=""
    while [ $# -gt 0 ]; do
        # The words are the command's own form (exakit notebook marimo); the
        # --flags are kept as aliases for scripts written against them.
        case "$1" in
            jupyterlab|marimo|positron|--marimo|--positron)
                [ -z "$_nbc_front" ] || [ "$_nbc_front" = "${1#--}" ] || die "Pick one of jupyterlab, marimo and positron"
                _nbc_front="${1#--}" ;;
            check|--check) _nbc_check=1 ;;
            setup|--setup) _nbc_setup=1 ;;
            stop|--stop) _nbc_stop=1 ;;
            --no-browser) _nbc_browser=0 ;;
            --port)
                shift
                case "${1:-}" in ''|*[!0-9]*) die "--port needs a number between 1024 and 65535" ;; esac
                [ "${#1}" -le 5 ] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] || die "--port needs a number between 1024 and 65535"
                _nbc_port="$1" ;;
            *) die "Unknown option for exakit notebook: $1 (see: exakit help notebook)" ;;
        esac
        shift
    done
    # The RECORD says whether the add-on is installed; a venv that is gone with
    # the record still there is a broken install, which the preflight repairs.
    [ -n "$(manifest_get components.notebook.version 2>/dev/null || true)" ] || \
        die "The notebook add-on is not installed. Install it with: exakit marketplace notebook"
    if [ "$_nbc_stop" = 1 ]; then
        case "$_nbc_front" in
            marimo) notebook_marimo_stop ;;
            positron) info "Positron is yours to close; the kit does not run it" ;;
            jupyterlab) notebook_server_stop ;;
            *) notebook_server_stop; notebook_marimo_stop quiet ;;
        esac
        return 0
    fi
    _notebook_preflight || return 1
    if [ "$_nbc_check" = 1 ]; then
        notebook_connected || die "The notebook connector could not connect to the database. Repair with: exakit update notebook"
        ok "Notebooks connect to the database"
        info "JupyterLab: $(notebook_server_state)   Marimo: $(notebook_marimo_state)   Notebooks: $EXAKIT_NOTEBOOK_DIR"
        return 0
    fi
    case "$_nbc_front" in
        marimo) notebook_marimo_cmd "$_nbc_setup" "$_nbc_browser" "$_nbc_port"; _nbc_rc=$? ;;
        positron) notebook_positron_cmd; _nbc_rc=$? ;;
        *)
            if [ -z "$_nbc_front" ] && [ "$_nbc_setup" = 0 ] && [ -z "$_nbc_port" ] && _notebook_on_terminal; then
                notebook_open_menu "$_nbc_browser"
                return $?
            fi
            notebook_jupyter_cmd "$_nbc_setup" "$_nbc_browser" "$_nbc_port"; _nbc_rc=$? ;;
    esac
    # 2: the user said no to installing the tool - an answer, not a failure.
    [ "$_nbc_rc" -eq 2 ] && return 0
    return "$_nbc_rc"
}

# notebook_jupyter_cmd <setup 0|1> <browser 0|1> [port] — JupyterLab: settled
# (notebook_jupyter_ready), then started in the background - on the port
# given, or the usual one, or the next free one when another program holds it
# - or the one the kit started reused, and opened logged in. 0 when it is
# open, 1 when it could not be, 2 when the user said no to installing it.
# ⇄ twin: Invoke-NotebookJupyterCmd.
notebook_jupyter_cmd() {
    notebook_jupyter_ready "$1"
    _njo_rc=$?
    [ "$_njo_rc" -eq 0 ] || return "$_njo_rc"
    if [ "$1" = 1 ]; then
        _notebook_front_end_add jupyterlab
        ok "Ready: $(notebook_find_jupyter | cut -d' ' -f2-) with the kernel '$EXAKIT_NOTEBOOK_KERNEL_TITLE'"
        return 0
    fi
    _njo_port="${3:-}"
    _njo_state="$(notebook_server_state)"
    if [ "$_njo_state" = "stopped" ]; then
        _njo_given=0
        [ -n "$_njo_port" ] && _njo_given=1
        _notebook_pick_port JupyterLab "${_njo_port:-$(_notebook_server_port)}" "$_njo_given" "exakit notebook" || return 1
        _njo_port="$NOTEBOOK_PICKED_PORT"
        notebook_server_start "$_njo_port" || return 1
    else
        # One the kit started is up, or coming up (a second `exakit notebook`
        # right after the first): use it, on the port it was started on, and
        # never start a second one over its pid file.
        _njo_running="$(_notebook_server_port)"
        if [ -n "$_njo_port" ] && [ "$_njo_port" != "$_njo_running" ]; then
            info "JupyterLab is already running on port $_njo_running, so --port $_njo_port is ignored (to move it: exakit notebook stop, then exakit notebook --port $_njo_port)"
        fi
        _njo_port="$_njo_running"
        if [ "$_njo_state" = "starting" ]; then
            _notebook_wait_up _notebook_api_answers "$_njo_port" "$(_notebook_pidfile)" \
                "$EXAKIT_NOTEBOOK_JUPYTER_MATCH" JupyterLab "$(_notebook_logfile)" || return 1
        fi
    fi
    _notebook_running_line JupyterLab "http://127.0.0.1:$_njo_port/lab" "exakit notebook stop"
    if [ "$2" = 1 ]; then
        _notebook_open_logged_in jupyter "http://127.0.0.1:$_njo_port/lab?token=$(_notebook_secret "$EXAKIT_NOTEBOOK_TOKEN_CRED")" || \
            info "Open http://127.0.0.1:$_njo_port/lab - the login token is in $EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_TOKEN_CRED"
    fi
    return 0
}

# notebook_marimo_cmd <setup 0|1> <browser 0|1> [port] — `exakit notebook
# --marimo`: Marimo installed (or, removed, installed again) when the user says
# yes - yes being the default, and the answer without a terminal
# (EXAKIT_NOTEBOOK_MARIMO=install|skip answers for a script) - then started
# and opened, logged in, on a free port as JupyterLab is. 0 when it is open, 1
# when it could not be, 2 when the user said no to installing it.
notebook_marimo_cmd() {
    if ! notebook_marimo_installed; then
        _nmc_answer="$(printf '%s' "${EXAKIT_NOTEBOOK_MARIMO:-}" | tr '[:upper:]' '[:lower:]')"
        if _notebook_tool_recorded marimo; then
            _nmc_ask="Marimo is missing (it was removed from the kit's notebook environment). Reinstall it?"
        else
            _nmc_ask="Marimo is not installed. Install it into the kit's notebook environment?"
        fi
        if [ -z "$_nmc_answer" ]; then
            if confirm "$_nmc_ask" y; then _nmc_answer=install; else _nmc_answer=skip; fi
        fi
        if [ "$_nmc_answer" != install ]; then
            info "Marimo was not installed. Add it any time with: exakit notebook marimo"
            return 2
        fi
        if ! notebook_install_marimo; then
            warn "Marimo could not be installed (see ${EXAKIT_LOG_FILE:-the log}) - retry with: exakit notebook marimo"
            return 1
        fi
        ok "Marimo installed into the kit's notebook environment"
    fi
    _notebook_report_copied "$EXAKIT_NOTEBOOK_DIR/marimo" marimo
    if [ "$1" = 1 ]; then
        ok "Ready: Marimo, with the kit's notebooks in $EXAKIT_NOTEBOOK_DIR/marimo"
        return 0
    fi
    _nmc_state="$(notebook_marimo_state)"
    if [ "$_nmc_state" = "stopped" ]; then
        _nmc_given=0
        [ -n "${3:-}" ] && _nmc_given=1
        _notebook_pick_port Marimo "${3:-$(_notebook_marimo_port)}" "$_nmc_given" "exakit notebook marimo" || return 1
        _nmc_port="$NOTEBOOK_PICKED_PORT"
        notebook_marimo_start "$_nmc_port" || return 1
    else
        # Up, or coming up (a second --marimo right after the first): wait for
        # that one rather than start another over its pid file.
        _nmc_port="$(_notebook_marimo_running_port)"
        if [ -n "${3:-}" ] && [ "$3" != "$_nmc_port" ]; then
            info "Marimo is already running on port $_nmc_port, so --port $3 is ignored (to move it: exakit notebook stop marimo, then exakit notebook marimo --port $3)"
        fi
        if [ "$_nmc_state" = "starting" ]; then
            _notebook_wait_up _notebook_marimo_answers "$_nmc_port" "$(_notebook_marimo_pidfile)" \
                "$EXAKIT_NOTEBOOK_MARIMO_MATCH" Marimo "$(_notebook_marimo_logfile)" || return 1
        fi
    fi
    _notebook_running_line Marimo "http://127.0.0.1:$_nmc_port/" "exakit notebook stop marimo"
    [ "${_NOTEBOOK_MANY:-0}" = 1 ] || info "Marimo notebooks connect with: import exakit.nb as nb; conn = nb.connect()"
    if [ "$2" = 1 ]; then
        _notebook_open_logged_in marimo "http://127.0.0.1:$_nmc_port/?access_token=$(_notebook_secret "$EXAKIT_NOTEBOOK_MARIMO_CRED")" || \
            info "Open http://127.0.0.1:$_nmc_port/ - the login token is in $EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MARIMO_CRED"
    fi
    return 0
}

# notebook_positron_cmd — `exakit notebook positron`: the notebooks folder
# set to the kit's Python (made again when it was deleted), then opened in the
# user's Positron. Never installs it. 1 when the folder could not be prepared.
notebook_positron_cmd() {
    if ! notebook_prepare_positron; then
        warn "The kit leaves $EXAKIT_NOTEBOOK_DIR/.vscode/settings.json alone (see above) - choose the interpreter $(notebook_venv_python) in Positron yourself"
        return 1
    fi
    _notebook_front_end_add positron
    if notebook_open_positron; then
        ok "Positron opened on $EXAKIT_NOTEBOOK_DIR with the kit's Python ($(notebook_venv_python))"
    else
        info "Positron is not on this machine. The folder is ready for it - get it at $EXAKIT_NOTEBOOK_POSITRON_DOWNLOAD, then run: exakit notebook positron"
    fi
    [ "${_NOTEBOOK_MANY:-0}" = 1 ] || info "In a notebook or script: import exakit.nb as nb; conn = nb.connect()"
    return 0
}

# _notebook_notebooks_go — does this uninstall delete the notebooks folder? Only
# a full kit uninstall (EXAKIT_UNINSTALL_FULL=1, set by exakit_uninstall_run)
# asked to with EXAKIT_UNINSTALL_NOTEBOOKS=remove, and only for a folder inside
# the kit home: that sweep keeps $EXAKIT_HOME/notebooks otherwise.
_notebook_notebooks_go() {
    [ "${EXAKIT_UNINSTALL_FULL:-0}" = "1" ] || return 1
    case "$(printf '%s' "${EXAKIT_UNINSTALL_NOTEBOOKS:-}" | tr '[:upper:]' '[:lower:]')" in remove) ;; *) return 1 ;; esac
    case "$EXAKIT_NOTEBOOK_DIR" in "$EXAKIT_HOME"/*) return 0 ;; *) return 1 ;; esac
}

# notebook_uninstall [1] — the kernel, the venv, the store and the servers go,
# and the kit's two settings come out of the notebooks folder's
# .vscode/settings.json (they would name a Python that no longer exists); the
# notebooks folder (with any MLflow store beside the notebooks) and the user's
# own JupyterLab stay. A full kit uninstall keeps the folder too, unless
# EXAKIT_UNINSTALL_NOTEBOOKS=remove; what is said is what happens.
notebook_uninstall() {
    _nbu_dry="${1:-0}"
    for _nbu_path in "$EXAKIT_NOTEBOOK_VENV" "$(notebook_store_file)"; do
        [ -e "$_nbu_path" ] || continue
        if [ "$_nbu_dry" = "1" ]; then info "  will remove: $_nbu_path"; fi
    done
    if [ "$_nbu_dry" = "1" ]; then
        [ -f "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json" ] && \
            info "  will remove: the kit's interpreter settings from $EXAKIT_NOTEBOOK_DIR/.vscode/settings.json"
        if _notebook_notebooks_go; then
            info "  will remove: your notebooks in $EXAKIT_NOTEBOOK_DIR (EXAKIT_UNINSTALL_NOTEBOOKS=remove)"
        elif [ -d "$EXAKIT_NOTEBOOK_DIR" ]; then
            info "  your notebooks stay in $EXAKIT_NOTEBOOK_DIR"
        fi
        return 0
    fi
    notebook_server_stop quiet >/dev/null 2>&1 || true
    notebook_marimo_stop quiet >/dev/null 2>&1 || true
    notebook_remove_kernel
    if [ -f "$EXAKIT_NOTEBOOK_DIR/.vscode/settings.json" ]; then
        _notebook_folders positron-remove "$EXAKIT_NOTEBOOK_DIR" "$(notebook_venv_python)" "$EXAKIT_NOTEBOOK_VENV" >/dev/null || true
    fi
    rm -rf "$EXAKIT_NOTEBOOK_VENV" "$(notebook_store_file)" "$(notebook_store_file).unreadable" \
        "$(_notebook_pidfile)" "$(_notebook_marimo_pidfile)" "$(_notebook_open_file jupyter)" "$(_notebook_open_file marimo)"
    rmdir "$EXAKIT_NOTEBOOK_HOME" 2>/dev/null || true
    rm -f "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MASTER_CRED" "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_TOKEN_CRED" \
        "$EXAKIT_CREDS_DIR/$EXAKIT_NOTEBOOK_MARIMO_CRED"
    manifest_del components.notebook
    manifest_del desired.notebook
    if _notebook_notebooks_go; then
        info "Your notebooks in $EXAKIT_NOTEBOOK_DIR go with the kit home (EXAKIT_UNINSTALL_NOTEBOOKS=remove)"
    elif [ -d "$EXAKIT_NOTEBOOK_DIR" ]; then
        info "Your notebooks stay in $EXAKIT_NOTEBOOK_DIR"
    fi
    ok_step "notebook removed — reinstall any time with: exakit marketplace notebook"
    return 0
}
