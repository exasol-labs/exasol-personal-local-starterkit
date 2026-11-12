#!/usr/bin/env bash
# describe.sh — `exakit describe <table> [--id <slug>] [--json] [--write <path>]`:
# describe SCHEMA.TABLE (DS-2, DS-5): its approved descriptor when the table
# still matches it, else a draft giving every column one of eight roles with
# the evidence that chose it, and the slots the notebooks use. The approve half:
#   exakit describe <id|SCHEMA.TABLE|draft.yaml> --approve [--role <slot>=<COL>]... [--owner <who>] [--no-comments]
#   exakit describe <id> --show [--version n]  |  --versions  |  --comments
# and the whole schema at once - its tables and the links between them:
#   exakit describe --schema <SCHEMA> [--approve [--link T.COL=T.KEY]... [--unlink T.COL]... [--owner <who>] [--no-comments]]
# and a semantic model over tables of any schemas (sample data, loaded files, external sources):
#   exakit describe --model <NAME> --table S.T... [--link S.T.COL=S.T.KEY]... [--ai] [--dry-run]  |  --refresh
#   exakit describe --models
# approve checks the roles and that the table has not changed, writes the next
# version into ~/.exasol-starter-kit/descriptors/<SCHEMA>.<TABLE>/ and
# rebuilds the schema's Exasol Semantic Views model with the roles (the
# user's own table is never commented); --show prints one version, --versions
# lists them, --comments publishes again. All take --json.
#
# THE PROFILING, THE DRAFTING AND THE APPROVING LIVE IN ONE PYTHON SERVICE,
# setup/lib/describe_service.py, which this file and its twin describe.ps1
# both run through the kit's notebook Python (pyexasol lives in that venv, so
# the add-on has to be there: exakit marketplace notebook), connected as the
# kit's admin user: the password is
# read from its file by the child and never reaches a command line. The shell
# keeps only the argument check and the refusals. Drafting runs SELECTs only;
# approving writes the semantic model (Semantic Views' catalog and SEM_<MODEL>) and nothing else.
#
# Exit codes: 0 ok; 1 the add-on is not installed; 2 bad arguments or roles;
# 3 the table or the id is not there; 4 the database is not reachable; 5 a
# version conflict (the service's own codes pass through). Twin: describe.ps1.

# describe_installed — the notebook add-on's record is there (the profiler's
# Python lives in its venv). ⇄ twin: Test-DescribeInstalled.
describe_installed() {
    [ -n "$(manifest_get components.notebook.version 2>/dev/null || true)" ]
}

# describe_run <service args> — the service in the kit's notebook Python with
# the admin connection settings from the manifest (the password's FILE, never
# the password; the DSN with the recorded TLS pin, SEC-14); its exit code is the
# command's. ⇄ twin:
# Invoke-DescribeService.
describe_run() {
    _dr_python="$(manifest_get components.notebook.python 2>/dev/null || true)"
    [ -n "$_dr_python" ] || _dr_python="${EXAKIT_NOTEBOOK_VENV:-$EXAKIT_HOME/notebook-venv}/bin/python"
    [ -x "$_dr_python" ] || die "The notebook environment is missing ($_dr_python). Repair it with: exakit notebook setup"
    EXAKIT_PYX_DSN="$(exakit_tls_pinned_dsn)" \
    EXAKIT_PYX_USER="$(manifest_get runtime.user 2>/dev/null || echo sys)" \
    EXAKIT_PYX_PWFILE="$(manifest_get runtime.password_file 2>/dev/null || true)" \
    EXAKIT_MCP_READER="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)" \
        "$_dr_python" "$(exakit_repo_root)/setup/lib/describe_service.py" "$@"
}

# exakit describe <table> [--sample N] [--id <slug>] [--json] [--write <path>]
# exakit describe <id|draft.yaml> --approve [--role r=COL]... [--owner x] [--no-comments] [--json]
# exakit describe <id> --show [--version n] | --versions | --comments [--json]
# exakit describe --schema <SCHEMA> [--approve [--link T.COL=T.KEY]... [--unlink T.COL]... [--owner x] [--no-comments]] [--json]
# exakit describe --model <NAME> --table S.T... [--link S.T.COL=S.T.KEY]... [--ai] [--description text] [--dry-run] [--json]
# exakit describe --model <NAME> --refresh [--json] | exakit describe --models [--json]
cmd_describe() {
    _cd_target=""; _cd_sample=""; _cd_id=""; _cd_json=""; _cd_write=""
    _cd_mode=""; _cd_owner=""; _cd_version=""; _cd_nocomments=""; _cd_roles=()
    _cd_schema=""; _cd_links=(); _cd_unlinks=()
    _cd_model=""; _cd_tables=(); _cd_ai=""; _cd_dry=""; _cd_desc=""; _cd_refresh=""; _cd_models=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h) exakit_help_render command describe; return $? ;;
            --json|-j) _cd_json="--json"; EXAKIT_REFUSAL_JSON=1 ;;
            --approve|--show|--versions|--comments)
                [ -z "$_cd_mode" ] || [ "$_cd_mode" = "$1" ] || reject "$_cd_mode and $1 are two different things; give one of --approve, --show, --versions, --comments."
                _cd_mode="$1" ;;
            --no-comments) _cd_nocomments="--no-comments" ;;
            --ai) _cd_ai="--ai" ;;
            --dry-run) _cd_dry="--dry-run" ;;
            --refresh) _cd_refresh=1 ;;
            --models) _cd_models=1 ;;
            --sample|--id|--write|--owner|--version|--role|--schema|--link|--unlink|--model|--table|--description)
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
                        # slot=COLUMN (or slot=- to leave it empty); the service checks the column against the table.
                        printf '%s' "$2" | grep -Eq '^(key|time|text|target|category|entity|date|label)=([A-Za-z][A-Za-z0-9_]*(,[A-Za-z][A-Za-z0-9_]*)*|-)$' || \
                            reject "--role takes slot=COLUMN with the slot one of key, time, text, target, category, entity (date and label name time and target; slot=- leaves it empty), not '$2'."
                        _cd_roles+=("$2") ;;
                    --schema)
                        [ -z "$_cd_schema" ] || reject "--schema was given twice."
                        printf '%s' "$2" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || reject "--schema takes a schema name (letters, digits and _), not '$2'."
                        _cd_schema="$2" ;;
                    --link)
                        # TABLE.COLUMN=TABLE.KEY with --schema; SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY with --model.
                        printf '%s' "$2" | grep -Eq '^([A-Za-z_][A-Za-z0-9_]*\.){1,2}[A-Za-z_][A-Za-z0-9_]*=([A-Za-z_][A-Za-z0-9_]*\.){1,2}[A-Za-z_][A-Za-z0-9_]*$' || \
                            reject "--link takes TABLE.COLUMN=TABLE.KEY (the column, then the key it points at; with --model SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY), not '$2'."
                        _cd_links+=("$2") ;;
                    --model)
                        [ -z "$_cd_model" ] || reject "--model was given twice."
                        printf '%s' "$2" | grep -Eq '^[A-Za-z][A-Za-z0-9_]*$' || reject "--model takes a model name (a letter, then letters, digits and _), not '$2'."
                        _cd_model="$2" ;;
                    --table)
                        printf '%s' "$2" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$' || \
                            reject "--table takes SCHEMA.TABLE, not '$2'."
                        _cd_tables+=("$2") ;;
                    --description)
                        [ -z "$_cd_desc" ] || reject "--description was given twice."
                        _cd_desc="$2" ;;
                    --unlink)
                        printf '%s' "$2" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$' || \
                            reject "--unlink takes the TABLE.COLUMN a link starts from, not '$2'."
                        _cd_unlinks+=("$2") ;;
                esac
                shift ;;
            -*) reject "Unknown option '$1' for describe (supported: --sample, --id, --json, --write, --approve, --role, --owner, --no-comments, --show, --version, --versions, --comments, --schema, --link, --unlink, --model, --table, --ai, --description, --dry-run, --refresh, --models)." ;;
            *) [ -z "$_cd_target" ] || reject "Name one table or descriptor: exakit describe SCHEMA.TABLE | exakit describe <id> --approve|--show|--versions|--comments"
               _cd_target="$1" ;;
        esac
        shift
    done
    if [ -n "$_cd_models$_cd_model" ]; then
        # Semantic models (Exasol Semantic Views): every model, one built over tables of any schemas, or a refresh.
        [ -z "$_cd_target$_cd_sample$_cd_id$_cd_write$_cd_version$_cd_mode$_cd_schema$_cd_owner$_cd_nocomments" ] && [ ${#_cd_roles[@]} -eq 0 ] && [ ${#_cd_unlinks[@]} -eq 0 ] || \
            reject "--model and --models take only --table, --link, --ai, --description, --dry-run, --refresh and --json: exakit describe --model NAME --table SCHEMA.TABLE... [--link S.T.COL=S.T.KEY]..."
        if [ -n "$_cd_models" ]; then
            [ -z "$_cd_model$_cd_ai$_cd_dry$_cd_desc$_cd_refresh" ] && [ ${#_cd_tables[@]} -eq 0 ] && [ ${#_cd_links[@]} -eq 0 ] || \
                reject "--models lists the models and takes only --json: exakit describe --models [--json]"
            set -- models ${_cd_json:+"$_cd_json"}
        elif [ -n "$_cd_refresh" ]; then
            [ -z "$_cd_ai$_cd_dry$_cd_desc" ] && [ ${#_cd_tables[@]} -eq 0 ] && [ ${#_cd_links[@]} -eq 0 ] || \
                reject "--refresh rebuilds a model from what it was built on and takes only --json: exakit describe --model NAME --refresh"
            set -- refresh "$_cd_model" ${_cd_json:+"$_cd_json"}
        else
            [ ${#_cd_tables[@]} -gt 0 ] || reject "Name the tables of the model: exakit describe --model $_cd_model --table SCHEMA.TABLE [--table SCHEMA.TABLE]..."
            set -- model "$_cd_model" ${_cd_ai:+"$_cd_ai"} ${_cd_dry:+"$_cd_dry"} ${_cd_json:+"$_cd_json"} ${_cd_desc:+--description "$_cd_desc"}
            _cd_n=0
            while [ "$_cd_n" -lt ${#_cd_tables[@]} ]; do set -- "$@" --table "${_cd_tables[$_cd_n]}"; _cd_n=$((_cd_n + 1)); done
            _cd_n=0
            while [ "$_cd_n" -lt ${#_cd_links[@]} ]; do
                printf '%s' "${_cd_links[$_cd_n]}" | grep -Eq '^[^.=]+\.[^.=]+\.[^.=]+=[^.=]+\.[^.=]+\.[^.=]+$' || \
                    reject "--link with --model takes SCHEMA.TABLE.COLUMN=SCHEMA.TABLE.KEY, not '${_cd_links[$_cd_n]}'."
                set -- "$@" --link "${_cd_links[$_cd_n]}"; _cd_n=$((_cd_n + 1))
            done
        fi
        describe_installed || die "The notebook add-on is not installed; its Python runs the describe service. Install it with: exakit marketplace notebook"
        describe_run "$@"
        return $?
    fi
    [ -z "$_cd_ai$_cd_dry$_cd_desc$_cd_refresh" ] && [ ${#_cd_tables[@]} -eq 0 ] || \
        reject "--table, --ai, --description, --dry-run and --refresh go with --model: exakit describe --model NAME --table SCHEMA.TABLE..."
    if [ -n "$_cd_schema" ]; then
        _cd_n=0
        while [ "$_cd_n" -lt ${#_cd_links[@]} ]; do
            printf '%s' "${_cd_links[$_cd_n]}" | grep -Eq '^[^.=]+\.[^.=]+=[^.=]+\.[^.=]+$' || \
                reject "--link with --schema takes TABLE.COLUMN=TABLE.KEY, not '${_cd_links[$_cd_n]}'."
            _cd_n=$((_cd_n + 1))
        done
        # The whole schema: its tables and the links between them, drafted or approved.
        [ -z "$_cd_target$_cd_sample$_cd_id$_cd_write$_cd_version" ] && [ ${#_cd_roles[@]} -eq 0 ] || \
            reject "--schema describes a whole schema and takes no table, --sample, --id, --write, --version or --role: exakit describe --schema SCHEMA [--approve [--link T.COL=T.KEY]... [--unlink T.COL]... [--owner who] [--no-comments]] [--json]"
        if [ "$_cd_mode" = --approve ]; then
            set -- schema-approve "$_cd_schema" ${_cd_owner:+--owner "$_cd_owner"} ${_cd_nocomments:+"$_cd_nocomments"} ${_cd_json:+"$_cd_json"}
            _cd_n=0
            while [ "$_cd_n" -lt ${#_cd_links[@]} ]; do set -- "$@" --link "${_cd_links[$_cd_n]}"; _cd_n=$((_cd_n + 1)); done
            _cd_n=0
            while [ "$_cd_n" -lt ${#_cd_unlinks[@]} ]; do set -- "$@" --unlink "${_cd_unlinks[$_cd_n]}"; _cd_n=$((_cd_n + 1)); done
        elif [ -z "$_cd_mode" ]; then
            [ -z "$_cd_owner$_cd_nocomments" ] && [ ${#_cd_links[@]} -eq 0 ] && [ ${#_cd_unlinks[@]} -eq 0 ] || \
                reject "--link, --unlink, --owner and --no-comments go with --approve: exakit describe --schema SCHEMA --approve [--link T.COL=T.KEY]..."
            set -- schema "$_cd_schema" ${_cd_json:+"$_cd_json"}
        else
            reject "$_cd_mode does not go with --schema: exakit describe --schema SCHEMA [--approve] [--json]"
        fi
        describe_installed || die "The notebook add-on is not installed; its Python runs the profiler. Install it with: exakit marketplace notebook"
        describe_run "$@"
        return $?
    fi
    [ ${#_cd_links[@]} -eq 0 ] && [ ${#_cd_unlinks[@]} -eq 0 ] || \
        reject "--link and --unlink go with --schema: exakit describe --schema SCHEMA --approve [--link T.COL=T.KEY]... [--unlink T.COL]..."
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
