#!/usr/bin/env bash
# describe.sh — `exakit describe <table> [--sample N] [--id <slug>] [--json]
# [--write <path>]`: profile SCHEMA.TABLE and draft its descriptor (DS-5): a
# role per column with the evidence that chose it and, under missing, the
# roles no column fits, each with its reason. And the approve half:
#   exakit describe <id|draft.yaml> --approve [--role <role>=<COL>]... [--owner <who>] [--no-comments]
#   exakit describe <id> --show [--version n]  |  --versions  |  --comments
# approve validates the roles, computes the table digest, writes the next
# version into ~/.exasol-starter-kit/descriptors/<id>/ and writes the roles
# into the table's column comments (a view in STARTER_KIT for a virtual
# table); --show prints one version, --versions lists them, --comments writes
# the comments again. All take --json.
#
# THE PROFILING, THE SCORING AND THE APPROVING LIVE IN ONE PYTHON SERVICE,
# setup/lib/describe_service.py, which this file and its twin describe.ps1
# both run through the kit's notebook Python (pyexasol lives in that venv, so
# the add-on has to be there: exakit marketplace notebook), connected as the
# kit's admin user the way udf-devkit.sh runs udf_tool.py: the password is
# read from its file by the child and never reaches a command line. The shell
# keeps only the argument check and the refusals. Drafting runs SELECTs only;
# approving writes comments (and the view) and nothing else.
#
# Exit codes: 0 ok; 1 the add-on is not installed; 2 bad arguments or roles;
# 3 the table or the id is not there; 4 the database is not reachable; 5 a
# version conflict (the service's own codes pass through). Sourced after
# notebook.sh. Twin: describe.ps1.

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
# exakit describe <id|draft.yaml> --approve [--role r=COL]... [--owner x] [--no-comments] [--json]
# exakit describe <id> --show [--version n] | --versions | --comments [--json]
cmd_describe() {
    _cd_target=""; _cd_sample=""; _cd_id=""; _cd_json=""; _cd_write=""
    _cd_mode=""; _cd_owner=""; _cd_version=""; _cd_nocomments=""; _cd_roles=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) exakit_help_render command describe; return $? ;;
            --json|-j) _cd_json="--json"; EXAKIT_REFUSAL_JSON=1 ;;
            --approve|--show|--versions|--comments)
                [ -z "$_cd_mode" ] || [ "$_cd_mode" = "$1" ] || reject "$_cd_mode and $1 are two different things; give one of --approve, --show, --versions, --comments."
                _cd_mode="$1" ;;
            --no-comments) _cd_nocomments="--no-comments" ;;
            --sample|--id|--write|--owner|--version|--role)
                _cd_opt="$1"
                [ $# -ge 2 ] || reject "$_cd_opt needs a value: exakit describe ... $_cd_opt <value>"
                case "$2" in -*) reject "$_cd_opt needs a value: exakit describe ... $_cd_opt <value>" ;; esac
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
                    --owner)
                        [ -z "$_cd_owner" ] || reject "--owner was given twice."
                        _cd_owner="$2" ;;
                    --version)
                        [ -z "$_cd_version" ] || reject "--version was given twice."
                        case "$2" in ''|*[!0-9]*|0*) reject "--version takes a version number (a positive integer), not '$2'." ;; esac
                        _cd_version="$2" ;;
                    --role)
                        # role=COLUMN (text=A,B); the service checks the column against the table.
                        printf '%s' "$2" | grep -Eq '^(entity|category|date|label|text)=[A-Za-z][A-Za-z0-9_]*(,[A-Za-z][A-Za-z0-9_]*)*$' || \
                            reject "--role takes role=COLUMN with the role one of entity, category, date, label, text (text takes A,B,...), not '$2'."
                        _cd_roles+=("$2") ;;
                esac
                shift ;;
            -*) reject "Unknown option '$1' for describe (supported: --sample, --id, --json, --write, --approve, --role, --owner, --no-comments, --show, --version, --versions, --comments)." ;;
            *) [ -z "$_cd_target" ] || reject "Name one table or descriptor: exakit describe SCHEMA.TABLE | exakit describe <id> --approve|--show|--versions|--comments"
               _cd_target="$1" ;;
        esac
        shift
    done
    case "$_cd_mode" in
        "")
            [ -z "$_cd_owner$_cd_version$_cd_nocomments" ] && [ ${#_cd_roles[@]} -eq 0 ] || \
                reject "--role, --owner, --no-comments and --version go with --approve or --show: exakit describe <id> --approve [--role role=COLUMN]... [--owner who] [--no-comments]"
            [ -n "$_cd_target" ] || reject "Name the table: exakit describe SCHEMA.TABLE [--sample N] [--id slug] [--json] [--write <path>] (exakit describe --help)."
            # The table's shape, checked here so a stray word never reaches SQL: two
            # names joined by a dot, a part quoted when it is not a plain name.
            printf '%s' "$_cd_target" | grep -Eq '^("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)\.("([^"]|"")+"|[A-Za-z_][A-Za-z0-9_]*)$' || \
                reject "Name the table as SCHEMA.TABLE (quote a part that is not a plain name: \"my schema\".\"order data\"), not '$_cd_target'."
            set -- draft "$_cd_target" ${_cd_sample:+--sample "$_cd_sample"} ${_cd_id:+--id "$_cd_id"} ${_cd_json:+"$_cd_json"} ${_cd_write:+--write "$_cd_write"} ;;
        --approve)
            [ -z "$_cd_id$_cd_write$_cd_version" ] || reject "--id, --write and --version do not go with --approve (the id is the draft's; --show takes --version)."
            [ -n "$_cd_target" ] || reject "Name the draft to approve, a dataset id or a draft file: exakit describe <id|draft.yaml> --approve [--role role=COLUMN]... [--owner who] [--no-comments]"
            [ -f "$_cd_target" ] || printf '%s' "$_cd_target" | grep -Eq '^[a-z0-9]+([-_][a-z0-9]+)*$' || \
                reject "--approve takes a dataset id (lower-case letters and digits, joined by - or _) or a draft file that exists, not '$_cd_target'."
            set -- approve "$_cd_target" ${_cd_sample:+--sample "$_cd_sample"} ${_cd_owner:+--owner "$_cd_owner"} ${_cd_nocomments:+"$_cd_nocomments"} ${_cd_json:+"$_cd_json"}
            _cd_n=0
            while [ "$_cd_n" -lt ${#_cd_roles[@]} ]; do set -- "$@" --role "${_cd_roles[$_cd_n]}"; _cd_n=$((_cd_n + 1)); done ;;
        *)
            [ -z "$_cd_id$_cd_write$_cd_sample$_cd_owner$_cd_nocomments" ] && [ ${#_cd_roles[@]} -eq 0 ] || \
                reject "$_cd_mode takes a dataset id$( [ "$_cd_mode" = --show ] && printf ' and --version n' ) and --json, nothing else."
            [ "$_cd_mode" = --show ] || [ -z "$_cd_version" ] || reject "--version goes with --show: exakit describe <id> --show --version n"
            [ -n "$_cd_target" ] || reject "Name the dataset id: exakit describe <id> $_cd_mode [--json]"
            printf '%s' "$_cd_target" | grep -Eq '^[a-z0-9]+([-_][a-z0-9]+)*$' || \
                reject "$_cd_mode takes a dataset id (lower-case letters and digits, joined by - or _), not '$_cd_target'."
            set -- "${_cd_mode#--}" "$_cd_target" ${_cd_version:+--version "$_cd_version"} ${_cd_json:+"$_cd_json"} ;;
    esac
    describe_installed || die "The notebook add-on is not installed; its Python runs the profiler. Install it with: exakit marketplace notebook"
    describe_run "$@"
}
