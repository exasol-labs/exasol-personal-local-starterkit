#!/usr/bin/env bash
# core-setup.sh — core setup tasks: work a kit release adds that only the
# installer can do.
#
# Sourced after common.sh (and exapump.sh, runtime-personal.sh, detect.sh) by
# the setup scripts and by exakit. ⇄ twin: core-setup.ps1.
#
# Three files hold the whole contract:
#   setup/core/tasks.json      the task names a kit release asks for
#   manifest.json              core_tasks.completed: names whose checks passed
#   setup/core/manage.py       compares the two, records completions
#
# The installer runs every task of a scope inside its own step, on every pass:
# the record skips nothing but the install, the check always runs. `exakit
# update` reruns the downloaded installer once when a task is pending, which is
# how a kit that is already installed picks up setup a later release added.

# exakit_core_rerun_active — true inside an installer that `exakit update`
# started to finish pending core tasks. The choices the first install asked
# about (sample data, AI clients, skills, marketplace) are not asked again.
exakit_core_rerun_active() {
    [ "${EXAKIT_CORE_RERUN:-0}" = "1" ]
}

# _exakit_core_manage <kit-root> <subcommand> [args...] — setup/core/manage.py.
_exakit_core_manage() {
    _ecm_root="$1"; shift
    _ecm_cmd="$1"; shift
    [ -f "$_ecm_root/setup/core/manage.py" ] || return 2
    case "$_ecm_cmd" in
        tasks) run_python "$_ecm_root/setup/core/manage.py" tasks --tasks "$_ecm_root/setup/core/tasks.json" "$@" ;;
        *)     run_python "$_ecm_root/setup/core/manage.py" "$_ecm_cmd" --tasks "$_ecm_root/setup/core/tasks.json" \
                   --manifest "$EXAKIT_MANIFEST" "$@" ;;
    esac
}

# exakit_core_tasks <kit-root> [scope] — every task name of a scope, in order.
exakit_core_tasks() {
    if [ -n "${2:-}" ]; then _exakit_core_manage "$1" tasks --scope "$2"; else _exakit_core_manage "$1" tasks; fi
}

# exakit_core_pending <kit-root> [scope] — task names not yet completed here.
exakit_core_pending() {
    if [ -n "${2:-}" ]; then _exakit_core_manage "$1" pending --scope "$2"; else _exakit_core_manage "$1" pending; fi
}

# exakit_core_complete <kit-root> <name> — record a task whose checks passed.
exakit_core_complete() {
    _ecc_err="$(_exakit_core_manage "$1" complete "$2" 2>&1 >/dev/null)"
    _ecc_rc=$?
    [ "$_ecc_rc" -eq 0 ] && return 0
    _exakit_log_file "WARN  could not record core task $2: $_ecc_err"
    warn "$(_exakit_manifest_write_error "$_ecc_rc" "the completed setup task $2")"
    return 1
}

# exakit_core_task_label <name> — what the reader is shown for a task.
exakit_core_task_label() {
    case "$1" in
        preprocessor) printf '%s\n' "the SQL preprocessor framework" ;;
        *)            printf '%s\n' "$1" ;;
    esac
}

# exakit_core_database_step <label> <kit-root> — the installer's "Configure
# database features" step: every database-scope task, installed when missing
# and verified when present. Never recorded in steps_completed, so it runs on
# every pass. A task that fails is booked in the closing summary with its
# retry command and the steps after it still run.
exakit_core_database_step() {
    _cds_label="$1"
    _cds_root="$2"
    begin_step db_features "$_cds_label" || return 0
    if ! _cds_tasks="$(exakit_core_tasks "$_cds_root" database 2>/dev/null)"; then
        exakit_record_soft_failure db_features "exakit update" \
            "the kit's task list (setup/core/tasks.json) could not be read" "database features"
        warn "The database feature list could not be read - carrying on so the rest of the install completes"
        return 0
    fi
    if [ -z "$_cds_tasks" ]; then
        ok_step "No database features to configure"
        return 0
    fi
    for _cds_task in $_cds_tasks; do
        if ! command -v "exakit_core_task_$_cds_task" >/dev/null 2>&1; then
            exakit_record_soft_failure "$_cds_task" "exakit update" \
                "this kit copy has no setup for it" "$(exakit_core_task_label "$_cds_task")"
            warn "$(exakit_core_task_label "$_cds_task") is not part of this kit copy - carrying on"
            continue
        fi
        if exakit_soft_step "$_cds_task" "exakit update" "$(exakit_core_task_label "$_cds_task")" \
                "exakit_core_task_$_cds_task" "$_cds_root"; then
            exakit_core_complete "$_cds_root" "$_cds_task" || true
        fi
    done
    return 0
}

# exakit_core_preprocessor_pin <kit-root> — "version|ref|asset|repo|sha256|core"
# for the framework package: the digest of the download, and of the core-only
# package the coordinator derives from it. The advertised manifest first, as for every
# component; the pin that shipped with this kit copy when the advertised one
# needs a newer kit or is not there at all.
exakit_core_preprocessor_pin() {
    _cpp_root="$1"
    for _cpp_doc in "" "$_cpp_root/versions.json"; do
        if [ -n "$_cpp_doc" ]; then
            [ -f "$_cpp_doc" ] || continue
        fi
        _cpp_v="$(exakit_versions_value components.preprocessor.version $_cpp_doc 2>/dev/null || true)"
        _cpp_ref="$(exakit_versions_value components.preprocessor.release $_cpp_doc 2>/dev/null || true)"
        _cpp_asset="$(exakit_versions_value components.preprocessor.asset $_cpp_doc 2>/dev/null || true)"
        _cpp_repo="$(exakit_versions_value components.preprocessor.repo $_cpp_doc 2>/dev/null || true)"
        _cpp_sha="$(exakit_versions_value components.preprocessor.sha256.release-sql $_cpp_doc 2>/dev/null || true)"
        _cpp_core="$(exakit_versions_value components.preprocessor.sha256.core-only $_cpp_doc 2>/dev/null || true)"
        _cpp_min="$(exakit_versions_value components.preprocessor.min_kit_version $_cpp_doc 2>/dev/null || true)"
        [ -n "$_cpp_v" ] && [ -n "$_cpp_ref" ] && [ -n "$_cpp_asset" ] && [ -n "$_cpp_repo" ] && [ -n "$_cpp_sha" ] && [ -n "$_cpp_core" ] || continue
        if [ -n "$_cpp_min" ] && ! exakit_min_kit_satisfied "$_cpp_min"; then
            _exakit_log_file "INFO  preprocessor $_cpp_v needs kit >= $_cpp_min; using the pin this kit copy shipped with"
            continue
        fi
        printf '%s|%s|%s|%s|%s|%s\n' "$_cpp_v" "$_cpp_ref" "$_cpp_asset" "$_cpp_repo" "$_cpp_sha" "$_cpp_core"
        return 0
    done
    return 1
}

# _exakit_core_preprocessor_render <output-file> — the coordinator's event
# lines, in the kit's own marks. A FAIL line becomes the failure note, which is
# the reason the closing summary prints.
_exakit_core_preprocessor_render() {
    while IFS= read -r _cpr_line || [ -n "$_cpr_line" ]; do
        case "$_cpr_line" in
            "OK "*)   ok_step "${_cpr_line#OK }" ;;
            "INFO "*) info "${_cpr_line#INFO }" ;;
            "WARN "*) warn "${_cpr_line#WARN }" ;;
            "FAIL "*)
                error "${_cpr_line#FAIL }"
                exakit_note_failure "${_cpr_line#FAIL }"
                ;;
            *) [ -n "$_cpr_line" ] && _exakit_log_file "PREPROC $_cpr_line" ;;
        esac
    done < "$1"
}

# exakit_core_task_preprocessor <kit-root> — install, activate and verify the
# SQL preprocessor framework. Runs inside exakit_soft_step's subshell.
exakit_core_task_preprocessor() {
    _ctp_root="$1"
    _ctp_py="$_ctp_root/setup/preprocessor/manage.py"
    [ -f "$_ctp_py" ] || { exakit_note_failure "setup/preprocessor/manage.py is missing from this kit copy"; return 1; }
    _ctp_pin="$(exakit_core_preprocessor_pin "$_ctp_root")" || {
        exakit_note_failure "no framework version is pinned in versions.json"
        return 1
    }
    IFS='|' read -r _ctp_ver _ctp_ref _ctp_asset _ctp_repo _ctp_sha _ctp_core <<CTP_PIN
$_ctp_pin
CTP_PIN
    _ctp_user="$(manifest_get runtime.user 2>/dev/null || true)"
    _ctp_package="$EXAKIT_HOME/cache/preprocessor/$_ctp_sha/$_ctp_asset"
    _ctp_out="$(mktemp "${TMPDIR:-/tmp}/exakit-preproc.XXXXXX")" || { exakit_note_failure "could not create a temporary file"; return 1; }
    _ctp_attempt=0
    while :; do
        _ctp_attempt=$((_ctp_attempt + 1))
        set -- ensure --exapump "$(exapump_cli)" --profile "$EXAKIT_EXAPUMP_PROFILE" \
            --manifest "$EXAKIT_MANIFEST" --admin-user "${_ctp_user:-sys}" \
            --pin-version "$_ctp_ver" --pin-ref "$_ctp_ref" --pin-sha256 "$_ctp_sha" \
            --pin-core-sha256 "$_ctp_core" \
            --log "${EXAKIT_LOG_FILE:-}"
        [ -f "$_ctp_package" ] && set -- "$@" --package "$_ctp_package"
        ui_spin_begin "Configuring the SQL preprocessor framework"
        run_python "$_ctp_py" "$@" > "$_ctp_out" 2>>"${EXAKIT_LOG_FILE:-/dev/null}"
        _ctp_rc=$?
        ui_spin_end
        _exakit_core_preprocessor_render "$_ctp_out"
        # 10: a fresh install needs the package, and only then is it fetched,
        # so a rerun over an installed framework never needs the network.
        [ "$_ctp_rc" -eq 10 ] && [ "$_ctp_attempt" -eq 1 ] || break
        # Downloaded under its own name in a staging folder: verify_sha256 names
        # the file it checked, and a temporary name there reads as a stray file.
        _ctp_dl="$(dirname "$_ctp_package")/.incoming/$_ctp_asset"
        mkdir -p "$(dirname "$_ctp_dl")" || { exakit_note_failure "could not create $(dirname "$_ctp_dl")"; break; }
        EXAKIT_ACTIVE_LABEL="Downloading the SQL preprocessor framework $_ctp_ver"
        fetch "https://github.com/$_ctp_repo/releases/download/$_ctp_ref/$_ctp_asset" "$_ctp_dl"
        verify_sha256 "$_ctp_dl" "$_ctp_sha"
        mv -f "$_ctp_dl" "$_ctp_package" || { exakit_note_failure "could not place the framework package in the cache"; break; }
        rmdir "$(dirname "$_ctp_dl")" 2>/dev/null || true
    done
    rm -f "$_ctp_out"
    case "$_ctp_rc" in
        0) return 0 ;;
        10) exakit_note_failure "the framework package was fetched but the install still could not find it" ;;
    esac
    return 1
}

# exakit_core_rerun_installer <kit-root> — run the downloaded installer once.
# Each component is pinned to the version installed now, so the rerun changes
# no component the update did not; the kit's source is passed through, so the
# record of where this kit came from survives. Exit code: the installer's.
exakit_core_rerun_installer() {
    _cri_root="$1"
    _cri_os="$(detect_os 2>/dev/null || true)"
    case "$_cri_os" in
        wsl) _cri_os=linux ;;
        macos|linux) ;;
        *) warn "The installer cannot be rerun on this platform ($_cri_os)."; return 7 ;;
    esac
    _cri_source="$(manifest_get kit.source 2>/dev/null || true)"
    _cri_fallback=""
    case "$_cri_source" in checkout:*) _cri_fallback="${_cri_source#checkout:}" ;; esac
    (
        [ -n "$_cri_source" ] && { EXAKIT_KIT_SOURCE="$_cri_source"; export EXAKIT_KIT_SOURCE; }
        for _cri_pair in personal:EXAKIT_PERSONAL_VERSION exapump:EXAKIT_EXAPUMP_VERSION \
                         mcp:EXAKIT_MCP_VERSION pyexasol:EXAKIT_PYEXASOL_VERSION; do
            _cri_comp="${_cri_pair%%:*}"
            _cri_var="${_cri_pair#*:}"
            eval "_cri_set=\${$_cri_var:-}"
            [ -z "$_cri_set" ] || continue
            _cri_have="$(exakit_component_current "$_cri_comp" 2>/dev/null || true)"
            case "$_cri_have" in
                ''|unknown|"not installed"|*[!A-Za-z0-9._+-]*) continue ;;
            esac
            eval "$_cri_var=\$_cri_have"
            export "$_cri_var"
        done
        if [ "${EXAKIT_UPDATE_JSON:-0}" = "1" ]; then
            run_python "$_cri_root/setup/core/rerun-installer.py" --platform "$_cri_os" \
                --kit-root "$_cri_root" --fallback-root "$_cri_fallback" --no-stdin
        else
            run_python "$_cri_root/setup/core/rerun-installer.py" --platform "$_cri_os" \
                --kit-root "$_cri_root" --fallback-root "$_cri_fallback"
        fi
    )
}

# exakit_core_update_check <target> — `exakit update`'s second check: does
# this kit ask for setup this machine has not completed? If so, rerun the
# downloaded installer once and confirm the tasks recorded themselves.
#
# Only for a whole-kit update (all, or the kit itself): `exakit update exapump`
# keeps its scope. Never inside an installer rerun. A database task with the
# database stopped is deferred with the command that finishes it, rather than
# starting the database behind the user's back.
exakit_core_update_check() {
    # Read by _exakit_update_run: set to 1 below once this check does work, so
    # a run that only finished new setup is not "already current".
    EXAKIT_CORE_UPDATE_ACTED=0
    case "${1:-all}" in all|exakit) ;; *) return 0 ;; esac
    exakit_core_rerun_active && return 0
    _cuc_root="$(exakit_repo_root 2>/dev/null)" || return 0
    [ -f "$_cuc_root/setup/core/tasks.json" ] || return 0
    if ! _cuc_pending="$(exakit_core_pending "$_cuc_root" 2>/dev/null)"; then
        warn "The kit's setup task list could not be compared with this machine - skipping that check. Details: exakit logs"
        return 0
    fi
    [ -n "$_cuc_pending" ] || return 0
    _cuc_list="$(printf '%s\n' "$_cuc_pending" | tr '\n' ' ' | sed 's/ *$//')"
    _cuc_db="$(exakit_core_pending "$_cuc_root" database 2>/dev/null || true)"
    EXAKIT_CORE_UPDATE_ACTED=1
    if [ -n "$_cuc_db" ] && ! personal_deployment_running >/dev/null 2>&1; then
        info "This kit has new setup to finish ($_cuc_list), and it needs the database running."
        info "Start the database, then update again: exakit start, then exakit update"
        _exakit_update_note core-setup deferred "" "$_cuc_list" "exakit start && exakit update"
        return 0
    fi
    info "This kit has new setup to finish ($_cuc_list) - running the installer once to complete it"
    exakit_core_rerun_installer "$_cuc_root"
    _cuc_rc=$?
    _cuc_left="$(exakit_core_pending "$_cuc_root" 2>/dev/null)" || _cuc_left="$_cuc_pending"
    _cuc_left="$(printf '%s\n' "$_cuc_left" | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$_cuc_rc" -eq 0 ] && [ -z "$_cuc_left" ]; then
        ok "New setup completed: $_cuc_list"
        _exakit_update_note core-setup updated "" "$_cuc_list"
        return 0
    fi
    warn "New setup did not complete: ${_cuc_left:-$_cuc_list}. Retry with: exakit update"
    _exakit_update_note core-setup failed "" "${_cuc_left:-$_cuc_list}" "exakit update"
    return 1
}

# exakit_update_handover <target> — `exakit update`'s first check. When this
# run just downloaded a newer kit, the rest of the run belongs to the NEW
# updater: it knows the new components, the new task list and the new
# installer, and this process is still running the old code. The new exakit
# is started once with the same target; --yes travels in
# EXAKIT_CONFIRM_RUNTIME_UPDATE, and under --json the results file and the
# no-prompt answer are already in the environment. EXAKIT_UPDATE_ROW_FIELDS=7
# tells the new run that this kit's reader takes the error and hint fields
# (see _exakit_update_note). Returns the new run's exit code. The caller
# checks exakit_update_handover_ready first: any code from here, 127
# included, is the new run's own.
exakit_update_handover() {
    _euh_bin="$EXAKIT_BIN_DIR/exakit"
    info "Continuing with the updated kit"
    EXAKIT_UPDATE_HANDOVER=1 EXAKIT_UPDATE_ROW_FIELDS=7 "$_euh_bin" update "${1:-all}"
}

# exakit_update_handover_ready — 0 when there is a new exakit to hand the run
# to. Asked before the handover, so "no handover" is never read off an exit
# code the new run could also return.
exakit_update_handover_ready() {
    [ -x "$EXAKIT_BIN_DIR/exakit" ]
}
