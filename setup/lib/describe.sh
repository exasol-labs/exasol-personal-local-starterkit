#!/usr/bin/env bash
# describe.sh — `exakit describe <table> [--sample N] [--id <slug>] [--json]
# [--write <path>]`: profile SCHEMA.TABLE and draft its descriptor (DS-5): a
# role per column with the evidence that chose it and, under missing, the
# roles no column fits, each with its reason. Approving a draft (--approve,
# --show, --versions) is the next step and is refused by name until it lands.
#
# THE PROFILING AND THE SCORING LIVE IN ONE PYTHON SERVICE,
# setup/lib/describe_service.py, which this file and its twin describe.ps1
# both run through the kit's notebook Python (pyexasol lives in that venv, so
# the add-on has to be there: exakit marketplace notebook), connected as the
# kit's admin user the way udf-devkit.sh runs udf_tool.py: the password is
# read from its file by the child and never reaches a command line. The shell
# keeps only the argument check and the refusals. Only SELECTs run.
#
# Exit codes: 0 ok; 1 the add-on is not installed; 2 bad arguments; 3 the
# table is not there; 4 the database is not reachable (the service's own codes
# pass through). Sourced after notebook.sh. Twin: describe.ps1.

# describe_installed — the notebook add-on's record is there (the profiler's
# Python lives in its venv). ⇄ twin: Test-DescribeInstalled.
describe_installed() {
    [ -n "$(manifest_get components.notebook.version 2>/dev/null || true)" ]
}

# describe_run <service args> — the service in the kit's notebook Python with
# the admin connection settings from the manifest (the password's FILE, never
# the password); its exit code is the command's. ⇄ twin:
# Invoke-DescribeService.
describe_run() {
    command -v notebook_venv_python >/dev/null 2>&1 || die "The notebook module is missing from this kit copy. Repair with: exakit update"
    _dr_python="$(notebook_venv_python)"
    [ -x "$_dr_python" ] || die "The notebook environment is missing ($_dr_python). Repair it with: exakit notebook setup"
    EXAKIT_PYX_DSN="$(manifest_get runtime.dsn 2>/dev/null || true)" \
    EXAKIT_PYX_USER="$(manifest_get runtime.user 2>/dev/null || echo sys)" \
    EXAKIT_PYX_PWFILE="$(manifest_get runtime.password_file 2>/dev/null || true)" \
        "$_dr_python" "$(exakit_repo_root)/setup/lib/describe_service.py" "$@"
}

# exakit describe <table> [--sample N] [--id <slug>] [--json] [--write <path>]
cmd_describe() {
    _cd_table=""; _cd_sample=""; _cd_id=""; _cd_json=""; _cd_write=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) exakit_help_render command describe; return $? ;;
            --json|-j) _cd_json="--json"; EXAKIT_REFUSAL_JSON=1 ;;
            --sample|--id|--write)
                _cd_opt="$1"
                [ $# -ge 2 ] || reject "$_cd_opt needs a value: exakit describe <table> $_cd_opt <value>"
                case "$2" in -*) reject "$_cd_opt needs a value: exakit describe <table> $_cd_opt <value>" ;; esac
                case "$_cd_opt" in
                    --sample)
                        [ -z "$_cd_sample" ] || reject "--sample was given twice."
                        case "$2" in ''|*[!0-9]*|0*) reject "--sample takes the number of rows to profile (a positive integer), not '$2'." ;; esac
                        _cd_sample="$2" ;;
                    --id)
                        [ -z "$_cd_id" ] || reject "--id was given twice."
                        printf '%s' "$2" | grep -Eq '^[a-z0-9]+([-_][a-z0-9]+)*$' || reject "--id takes a dataset id (lower-case letters and digits, joined by - or _), not '$2'."
                        _cd_id="$2" ;;
                    --write)
                        [ -z "$_cd_write" ] || reject "--write was given twice."
                        _cd_write="$2" ;;
                esac
                shift ;;
            --approve|--show|--versions) reject "$1 is not in this kit yet: exakit describe drafts; approving a draft comes with the next release. Draft with: exakit describe <table>" ;;
            -*) reject "Unknown option '$1' for describe (supported: --sample, --id, --json, --write)." ;;
            *) [ -z "$_cd_table" ] || reject "Name one table: exakit describe SCHEMA.TABLE [--sample N] [--id slug] [--json] [--write <path>]"
               _cd_table="$1" ;;
        esac
        shift
    done
    [ -n "$_cd_table" ] || reject "Name the table: exakit describe SCHEMA.TABLE [--sample N] [--id slug] [--json] [--write <path>] (exakit describe --help)."
    # The table's shape, checked here so a stray word never reaches SQL: two
    # names joined by a dot, a part quoted when it is not a plain name.
    printf '%s' "$_cd_table" | grep -Eq '^("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\.("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)$' || \
        reject "Name the table as SCHEMA.TABLE (quote a part that is not a plain name: \"my schema\".\"order data\"), not '$_cd_table'."
    describe_installed || die "The notebook add-on is not installed; its Python runs the profiler. Install it with: exakit marketplace notebook"
    describe_run draft "$_cd_table" ${_cd_sample:+--sample "$_cd_sample"} ${_cd_id:+--id "$_cd_id"} ${_cd_json:+"$_cd_json"} ${_cd_write:+--write "$_cd_write"}
}
