#!/usr/bin/env bash
# workflow.sh — `exakit workflow list|show <id> [--json]`: the workflow logs the
# notebook helpers write (X-1). A notebook starts a workflow with
# nb.workflow("name"); from then on every statement, trace, MLflow run, draft,
# approval, handoff, dashboard revision and model put appends one JSON line to
# $EXAKIT_HOME/workflows/<id>.jsonl, all carrying the id. This command only
# reads those files.
#
# THE READING LIVES IN THE HELPERS' OWN MODULE,
# notebook/package/exakit_nb/workflow.py (`python -m exakit_nb.workflow`),
# which this file and its twin workflow.ps1 both run through the kit's
# notebook Python - the module is installed in that venv, so the add-on has to
# be there (exakit marketplace notebook). The shell keeps only the argument
# check and the two refusals.
#
# Exit codes: 0 ok; 1 the add-on is not installed or no such workflow; 2 bad
# arguments. Sourced after notebook.sh. Twin: workflow.ps1.

# workflow_installed — the notebook add-on's record is there (the helpers and
# their Python live in its venv). ⇄ twin: Test-WorkflowInstalled.
workflow_installed() {
    [ -n "$(manifest_get components.notebook.version 2>/dev/null || true)" ]
}

# workflow_run <module args> — the module in the kit's notebook Python, with
# the kit home the CLI resolved; its exit code is the command's. ⇄ twin:
# Invoke-WorkflowModule.
workflow_run() {
    command -v notebook_venv_python >/dev/null 2>&1 || die "The notebook module is missing from this kit copy. Repair with: exakit update"
    _wfr_python="$(notebook_venv_python)"
    [ -x "$_wfr_python" ] || die "The notebook environment is missing ($_wfr_python). Repair it with: exakit notebook setup"
    EXAKIT_HOME="$EXAKIT_HOME" "$_wfr_python" -m exakit_nb.workflow "$@"
}

# exakit workflow list [--json] | show <id> [--json]
cmd_workflow() {
    _cw_sub="${1:-}"
    [ $# -gt 0 ] && shift
    _cw_json=""; _cw_id=""
    case "$_cw_sub" in --help|-h) exakit_help_render command workflow; return $? ;; esac
    for _cw_arg in "$@"; do
        case "$_cw_arg" in
            --json|-j) _cw_json="--json" ;;
            --help|-h) exakit_help_render command workflow; return $? ;;
            -*) reject "Unknown option '$_cw_arg' for workflow (supported: --json)." ;;
            *) [ -z "$_cw_id" ] || reject "Name one workflow: exakit workflow show <id> [--json]"
               _cw_id="$_cw_arg" ;;
        esac
    done
    case "$_cw_sub" in
        list) [ -z "$_cw_id" ] || reject "list takes no argument: exakit workflow list [--json]" ;;
        show)
            [ -n "$_cw_id" ] || reject "Name the workflow: exakit workflow show <id> [--json] (exakit workflow list)"
            # The id's shape, checked here so a stray word never reaches the
            # file system as a name: wf-YYYYMMDD-<6 lowercase hex>.
            case "$_cw_id" in
                wf-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
                *) reject "Not a workflow id: '$_cw_id' (expected wf-YYYYMMDD-xxxxxx; exakit workflow list)" ;;
            esac ;;
        "") reject "Name what to do: exakit workflow list | exakit workflow show <id> (exakit workflow --help)." ;;
        *) reject "Unknown workflow command '$_cw_sub' (supported: list, show)." ;;
    esac
    workflow_installed || die "The notebook add-on is not installed; its helpers write the workflow log. Install it with: exakit marketplace notebook"
    if [ "$_cw_sub" = show ]; then
        workflow_run show "$_cw_id" ${_cw_json:+"$_cw_json"}
    else
        workflow_run list ${_cw_json:+"$_cw_json"}
    fi
}
