#!/usr/bin/env bash
# persona.sh — personas: a named set of the answers the installer already takes
# from the environment (EXAKIT_DATASETS, EXAKIT_MCP_CLIENTS,
# EXAKIT_MARKETPLACE_ADDONS). Files: personas/<id>.json (personas/README.md).
#
# THE RULES LIVE IN ONE PYTHON SERVICE, setup/lib/persona_service.py, which this
# file and its twin persona.ps1 both call: which personas the question offers,
# what several ticked together add up to, which answers they fill in, and which
# personas each dataset is for. The shell keeps only the asking and the UI.
#
#   EXAKIT_PERSONA=<id>[,<id>] at install  -> exakit_persona_apply_env fills in
#                                             every answer the user did not give
#   no EXAKIT_PERSONA, a terminal           -> exakit_persona_flow asks, after the
#                                             parts everyone needs: the personas,
#                                             then the data; their add-ons are
#                                             ticked in the closing marketplace offer
#   exakit persona list|show <id>|plan [<id>]|add <id>  (apply: the same)
#
# An explicit answer always wins, per variable: EXAKIT_PERSONA=data-scientist
# EXAKIT_DATASETS=pharma_trials loads only that dataset and keeps the persona's
# clients and add-ons. Sourced after common.sh. Twin: persona.ps1.

# _exakit_persona_service <command> [args] — ask the persona service.
_exakit_persona_service() {
    _eps_root="$(exakit_repo_root)"
    run_python_any "$_eps_root/setup/lib/persona_service.py" "$_eps_root" "$@"
}

# exakit_persona_dir — where the persona files live in this kit copy.
exakit_persona_dir() {
    printf '%s/personas\n' "$(exakit_repo_root)"
}

# exakit_persona_ids — every persona this kit ships, one per line.
exakit_persona_ids() {
    _exakit_persona_service ids 2>/dev/null
}

# exakit_persona_value <id> <key> — the key's value: a string as it is, a list
# as a comma-separated line. Empty when the key is absent.
exakit_persona_value() {
    _exakit_persona_service value "$1" "$2" 2>/dev/null
}

# exakit_persona_known <id>[,<id>] — every persona named exists and its file
# is valid. When not, EXAKIT_PERSONA_PROBLEM says why, in the service's words:
# the persona is unknown (naming the ones there are), its file is invalid, or
# the service could not run at all (no Python 3).
exakit_persona_known() {
    EXAKIT_PERSONA_PROBLEM=""
    if [ -z "${1:-}" ]; then
        EXAKIT_PERSONA_PROBLEM="Name a persona: $(exakit_persona_ids | tr '\n' ' ' | sed 's/ $//')"
        return 1
    fi
    _epk_err="$(_exakit_persona_service check "$1" 2>&1 >/dev/null)" && return 0
    EXAKIT_PERSONA_PROBLEM="$(printf '%s\n' "$_epk_err" | grep -v '^Ignored persona file' | tail -n 1)"
    [ -n "$EXAKIT_PERSONA_PROBLEM" ] || \
        EXAKIT_PERSONA_PROBLEM="The persona files could not be read - the kit needs Python 3 for them (see ${EXAKIT_LOG_FILE:-the log})"
    _exakit_log_file "WARN  persona check '$1': $(printf '%s' "$_epk_err" | tr '\n' ' ')"
    return 1
}

exakit_persona_selectable() {
    _eps_recorded="$(manifest_get persona.id 2>/dev/null || true)"
    _eps_error="$(_exakit_persona_service select "$1" "$_eps_recorded" 2>&1 >/dev/null)" && return 0
    EXAKIT_PERSONA_PROBLEM="$(printf '%s\n' "$_eps_error" | tail -n 1)"
    return 1
}

# exakit_persona_dataset_hints — dataset|persona titles, for the data menu.
exakit_persona_dataset_hints() {
    _exakit_persona_service dataset-hints 2>/dev/null
}

# _exakit_persona_export <KEY=value lines> — export the service's answers. Only
# the installer's own variables are taken; anything else is ignored.
_exakit_persona_export() {
    while IFS='=' read -r _epe_key _epe_value; do
        case "$_epe_key" in
            EXAKIT_DATASETS|EXAKIT_LOAD_SAMPLE|EXAKIT_MCP_CLIENTS|EXAKIT_MARKETPLACE_ADDONS|EXAKIT_NOTEBOOK_FRONTENDS|EXAKIT_UDF_LANGUAGE|EXAKIT_PERSONA)
                eval "$_epe_key=\"\$_epe_value\""
                export "${_epe_key?}"
                ;;
        esac
    done <<EXAKIT_EPE_EOF
$1
EXAKIT_EPE_EOF
}

# _exakit_persona_record — the persona in the install record.
_exakit_persona_record() {
    manifest_set persona.id "$EXAKIT_PERSONA"
    manifest_set persona.source "${EXAKIT_PERSONA_SOURCE:-install}"
    manifest_set persona.requested_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# exakit_persona_apply_env [norecord] — with EXAKIT_PERSONA set, export the
# personas' answers for every variable the user did not set. Dies on an unknown
# or invalid persona, before anything is installed. Records the persona in the
# manifest unless told not to.
exakit_persona_apply_env() {
    [ -n "${EXAKIT_PERSONA:-}" ] || return 0
    exakit_persona_selectable "$EXAKIT_PERSONA" || die "$EXAKIT_PERSONA_PROBLEM"
    _epa_answers="$(_exakit_persona_service answers "$EXAKIT_PERSONA")" || \
        die "The persona files could not be read - re-run the installer to repair the kit copy."
    _exakit_persona_export "$_epa_answers"
    info "Persona: $(_exakit_persona_service title "$EXAKIT_PERSONA") - datasets ${EXAKIT_DATASETS:-none}; AI clients ${EXAKIT_MCP_CLIENTS:-asked}; add-ons ${EXAKIT_MARKETPLACE_ADDONS:-none}"
    _exakit_log_file "INFO  persona $EXAKIT_PERSONA answered: $(printf '%s' "$_epa_answers" | tr '\n' ' ')"
    [ "${1:-}" = norecord ] || _exakit_persona_record
    export EXAKIT_PERSONA_ACTIVE=1
    return 0
}

# exakit_persona_question — "What will you use this machine for?": the personas
# the kit offers ("picker": true), as many as wanted, or None. Ticked to begin
# with: the personas this kit was set up as (a re-run), else the "default": true
# ones, else None. The answer is EXAKIT_PERSONA (empty for None).
exakit_persona_question() {
    # After the common install steps, uv is present for the MCP runtime. The
    # Textual picker owns this screen; the old checkbox remains a recovery path
    # if a package mirror is offline or the terminal cannot run Textual.
    if [ -t 0 ] && [ -t 1 ] && [ "${EXAKIT_NO_FANCY:-0}" != 1 ]; then
        _epq_root="$(exakit_repo_root)"
        _epq_result="$(mktemp "${TMPDIR:-/tmp}/exakit-persona-ui.XXXXXX")" || _epq_result=""
        if [ -n "$_epq_result" ]; then
            rm -f "$_epq_result"
            if run_python_any "$_epq_root/marketplace/launch.py" "$_epq_root" persona \
                --out "$_epq_result" --recorded "$(manifest_get persona.id 2>/dev/null || true)"; then
                EXAKIT_PERSONA="$(run_python_any - "$_epq_result" <<'PY'
import json, sys
print(','.join(json.load(open(sys.argv[1], encoding='utf-8'))['selected']))
PY
)"
                export EXAKIT_PERSONA
                rm -f "$_epq_result"
                return 0
            else
                _epq_ui_rc=$?
                rm -f "$_epq_result"
                [ "$_epq_ui_rc" -eq 10 ] && { EXAKIT_PERSONA=""; export EXAKIT_PERSONA; return 0; }
                warn "The Textual persona picker did not start; using the kit's checkbox menu."
            fi
        fi
    fi
    _epq_rows="$(_exakit_persona_service picker 2>/dev/null)"
    if [ -z "$_epq_rows" ]; then
        _exakit_log_file "WARN  the persona service did not answer; no persona question"
        return 0
    fi
    _epq_ids=()
    _epq_labels=()
    _epq_default=""                  # the personas whose file says "default": true
    _epq_recorded=""                 # ...or the ones a previous run recorded
    _epq_was=",$(manifest_get persona.id 2>/dev/null || true),"
    _epq_n=0
    while IFS='|' read -r _epq_id _epq_title _epq_summary _epq_ticked; do
        [ -n "$_epq_id" ] || continue
        _epq_n=$(( _epq_n + 1 ))
        _epq_ids+=("$_epq_id")
        _epq_labels+=("$_epq_title - $_epq_summary")
        [ "$_epq_ticked" = 1 ] && _epq_default="${_epq_default:+$_epq_default,}$_epq_n"
        case "$_epq_was" in *",$_epq_id,"*) _epq_recorded="${_epq_recorded:+$_epq_recorded,}$_epq_n" ;; esac
    done <<EXAKIT_EPQ_EOF
$_epq_rows
EXAKIT_EPQ_EOF
    # The last row is the kit on its own, no persona - exclusive, and ticked to
    # begin with unless a persona file says "default": true or a previous run
    # recorded one.
    _epq_none=$(( _epq_n + 1 ))
    _epq_labels+=("None - just the kit, with the TPC-H, energy and weather samples")
    ui_rule
    heading "What will you use this machine for?"
    _epq_default="${_epq_recorded:-${_epq_default:-$_epq_none}}"
    EXAKIT_CHECKBOX_EXCLUSIVE="$_epq_none"
    ui_checkbox_menu "Personas - tick one or more, or None" "$_epq_default" "${_epq_labels[@]}"
    EXAKIT_PERSONA=""
    for _epq_i in $(printf '%s' "${EXAKIT_CHECKBOX_SELECTION:-}" | tr ',' ' '); do
        case "$_epq_i" in ''|*[!0-9]*) continue ;; esac
        [ "$_epq_i" -ge 1 ] && [ "$_epq_i" -le "$_epq_n" ] || continue
        EXAKIT_PERSONA="${EXAKIT_PERSONA:+$EXAKIT_PERSONA,}${_epq_ids[$(( _epq_i - 1 ))]}"
    done
    export EXAKIT_PERSONA
}

# The install asks for a persona after the common steps, then offers its data.
# Add-ons are offered at the end; no persona keeps the kit's sample defaults.
exakit_persona_flow() {
    _epf_root="$1"
    # No database or no exapump: nothing here can run (the data needs both, and
    # the closing offer is not made after a soft failure), so nobody is asked.
    # The database skip was said with the other database steps; the exapump one
    # is said by exakit_persona_data.
    exakit_soft_failed runtime && return 0
    if exakit_soft_failed exapump; then
        exakit_persona_data "$_epf_root"
        return 0
    fi
    if [ -z "${EXAKIT_PERSONA:-}" ]; then
        if [ -n "$(_exakit_prompt_tty)" ] && [ "${UI_FANCY:-0}" = 1 ] && ! _exakit_persona_all_answered; then
            exakit_persona_question
            if [ -n "${EXAKIT_PERSONA:-}" ] && exakit_persona_known "$EXAKIT_PERSONA"; then
                _exakit_persona_preselect "$EXAKIT_PERSONA"
                ok "Persona: $(_exakit_persona_service title "$EXAKIT_PERSONA" 2>/dev/null)"
                _exakit_log_file "INFO  persona $EXAKIT_PERSONA picked on screen: datasets ${EXAKIT_DATASETS_PRESELECT:-as asked}; add-ons ${EXAKIT_MARKETPLACE_PRESELECT:-as asked}"
                _exakit_persona_record
                export EXAKIT_PERSONA_ACTIVE=1
            elif [ -n "${EXAKIT_PERSONA:-}" ]; then
                warn "$EXAKIT_PERSONA_PROBLEM - carrying on without a persona"
                EXAKIT_PERSONA=""
            fi
        else
            _exakit_persona_kit_defaults
        fi
    fi
    # Asked, and the answer was None: the kit's own default datasets.
    [ -n "${EXAKIT_PERSONA:-}" ] || [ -n "${EXAKIT_DATASETS_PRESELECT:-}" ] || _exakit_persona_kit_defaults
    # The data, with the personas' datasets ticked (or loaded, when named in the
    # environment). See exakit_maybe_offer_data_load.
    exakit_persona_data "$_epf_root"
}

# _exakit_persona_kit_defaults — no persona: the data question ticks the
# datasets the kit loads on its own (default=yes in their dataset.conf: TPC-H,
# energy, weather). Nothing is recorded - no persona was chosen.
_exakit_persona_kit_defaults() {
    _epkd="$(_exakit_persona_service default-datasets 2>/dev/null)"
    [ -n "$_epkd" ] && { EXAKIT_DATASETS_PRESELECT="$_epkd"; export EXAKIT_DATASETS_PRESELECT; }
    return 0
}

# _exakit_persona_all_answered — everything the persona question would answer
# was answered in the environment already, so asking would change nothing.
_exakit_persona_all_answered() {
    { [ -n "${EXAKIT_DATASETS:-}" ] || [ "${EXAKIT_LOAD_SAMPLE:-}" = 0 ] || [ "${EXAKIT_LOAD_SAMPLE:-}" = 1 ]; } && \
        [ -n "${EXAKIT_MARKETPLACE_ADDONS:-}" ]
}

# _exakit_persona_preselect <ids> [datasets] — what the menus tick for these
# personas: EXAKIT_DATASETS_PRESELECT (dataset ids, or "none") and, unless told
# datasets only, EXAKIT_MARKETPLACE_PRESELECT (add-on ids, or "all"). Answers
# the user set in the environment still win: they are not overwritten.
_exakit_persona_preselect() {
    _epp_answers="$(_exakit_persona_service answers "$1" 2>/dev/null)"
    _epp_ds="$(printf '%s\n' "$_epp_answers" | sed -n 's/^EXAKIT_DATASETS=//p')"
    printf '%s\n' "$_epp_answers" | grep -qx 'EXAKIT_LOAD_SAMPLE=0' && _epp_ds=none
    _epp_ad="$(printf '%s\n' "$_epp_answers" | sed -n 's/^EXAKIT_MARKETPLACE_ADDONS=//p')"
    [ -n "$_epp_ds" ] && { EXAKIT_DATASETS_PRESELECT="$_epp_ds"; export EXAKIT_DATASETS_PRESELECT; }
    [ "${2:-}" = datasets ] && return 0
    [ -n "$_epp_ad" ] && [ "$_epp_ad" != none ] && { EXAKIT_MARKETPLACE_PRESELECT="$_epp_ad"; export EXAKIT_MARKETPLACE_PRESELECT; }
    return 0
}

# exakit_persona_data <kit_root> — the sample-data section, booked as a soft
# step: a failed load is repaired with one command, never a reason to stop.
exakit_persona_data() {
    if exakit_soft_failed runtime; then
        info "Skipping the sample data - it needs the database, which is not installed"
        return 0
    fi
    if exakit_soft_failed exapump; then
        info "Skipping the sample data - it is loaded with exapump, which is not installed"
        return 0
    fi
    exakit_clear_failure_note
    if ! exakit_maybe_offer_data_load "$1"; then
        exakit_record_soft_failure sample_data "exakit data-load" "$(exakit_take_failure_note)" "sample data"
        warn "Sample data did not finish loading - carrying on so the rest of the install completes"
    fi
    exakit_clear_failure_note
    return 0
}

# exakit_persona_marketplace_note — after the closing offer showed only the
# personas' add-ons, the rest of the marketplace is named once. (Without that
# offer the closing lines already name the marketplace: no second pointer.)
exakit_persona_marketplace_note() {
    [ -n "${EXAKIT_PERSONA_ACTIVE:-}" ] && [ -n "${EXAKIT_MARKETPLACE_PRESELECT:-}" ] || return 0
    info "More for any persona in the marketplace: exakit marketplace (dashboards, notebooks, dbt, the scheduler, Python UDFs, JSON tables)"
}

# exakit_persona_plan <ids> <json 0|1> — what these personas bring and what of
# it is still pending on this machine: their datasets (loaded or not) and their
# add-ons (installed or not). After `EXAKIT_PERSONA=<id>` installs, nothing is
# pending. Read-only; exit 0 either way.
exakit_persona_plan() {
    # The personas' own answers, not this shell's: what they bring, whatever was set.
    _epl_answers="$( (unset EXAKIT_DATASETS EXAKIT_LOAD_SAMPLE EXAKIT_MARKETPLACE_ADDONS EXAKIT_MCP_CLIENTS \
        EXAKIT_NOTEBOOK_FRONTENDS EXAKIT_SKIP_MCP; _exakit_persona_service answers "$1" 2>/dev/null) )"
    _epl_ds="$(printf '%s\n' "$_epl_answers" | sed -n 's/^EXAKIT_DATASETS=//p' | tr ',' ' ')"
    _epl_ad="$(printf '%s\n' "$_epl_answers" | sed -n 's/^EXAKIT_MARKETPLACE_ADDONS=//p')"
    case "$_epl_ad" in
        none|"") _epl_ad="" ;;
        all) _epl_ad="$(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ')" ;;
        *) _epl_ad="$(printf '%s' "$_epl_ad" | tr ',' ' ')" ;;
    esac
    _epl_pending_ids=" $(exakit_pending_datasets 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ') "
    _epl_installed=" $(exakit_marketplace_installed_addons 2>/dev/null | tr '\n' ' ') "
    _epl_dl=""; _epl_dp=""; _epl_ai=""; _epl_ap=""
    for _epl_x in $_epl_ds; do
        case "$_epl_pending_ids" in *" $_epl_x "*) _epl_dp="$_epl_dp $_epl_x" ;; *) _epl_dl="$_epl_dl $_epl_x" ;; esac
    done
    for _epl_x in $_epl_ad; do
        case "$_epl_installed" in *" $_epl_x "*) _epl_ai="$_epl_ai $_epl_x" ;; *) _epl_ap="$_epl_ap $_epl_x" ;; esac
    done
    if [ "$2" = 1 ]; then
        _epl_arr() { printf '%s' "$1" | awk '{for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? ", " : ""), $i}'; }
        exakit_json_out '{"persona": "%s", "datasets": {"loaded": [%s], "pending": [%s]}, "addons": {"installed": [%s], "pending": [%s]}, "nothing_pending": %s}\n' \
            "$(_exakit_json_string "$1")" "$(_epl_arr "$_epl_dl")" "$(_epl_arr "$_epl_dp")" "$(_epl_arr "$_epl_ai")" "$(_epl_arr "$_epl_ap")" \
            "$([ -z "$_epl_dp$_epl_ap" ] && echo true || echo false)"
        return 0
    fi
    printf '%s\n' "$(_exakit_persona_service title "$1" 2>/dev/null) ($1)"
    printf '  %-12s %s\n' "Datasets" "loaded:${_epl_dl:- none}   pending:${_epl_dp:- none}"
    printf '  %-12s %s\n' "Add-ons" "installed:${_epl_ai:- none}   pending:${_epl_ap:- none}"
    if [ -z "$_epl_dp$_epl_ap" ]; then
        ok "Nothing pending for $1"
    else
        info "Pending - bring it in with: exakit persona add $1"
    fi
    return 0
}

# exakit_persona_recorded — the personas this kit was set up as (persona.id),
# in the kit's order; one this kit copy no longer ships is left out. Empty when
# none is recorded.
exakit_persona_recorded() {
    _epr_out=""
    for _epr_id in $(manifest_get persona.id 2>/dev/null | tr ',' ' '); do
        _exakit_persona_service check "$_epr_id" >/dev/null 2>&1 || continue
        _epr_out="${_epr_out:+$_epr_out,}$_epr_id"
    done
    [ -n "$_epr_out" ] || return 0
    _exakit_persona_service check "$_epr_out" 2>/dev/null
}

# _exakit_persona_label <dataset-id> — the dataset's name as a line says it:
# its label without the "(~5k rows)" estimate or the download size.
_exakit_persona_label() {
    exakit_bundled_datasets 2>/dev/null | awk -F'|' -v id="$1" '$1 == id { print $2; exit }' | \
        sed 's/ - [0-9.]* MB download$//; s/ *([^()]*)$//'
}

# Legacy apply path for direct callers. The public CLI uses
# marketplace/persona_apply.py on both platforms.
exakit_persona_add() {
    _epd_was="$(exakit_persona_recorded)"
    _epd_new="$(_exakit_persona_service select "$1" "$_epd_was" 2>/dev/null)" || \
        die "$(_exakit_persona_service select "$1" "$_epd_was" 2>&1 | tail -n 1)"
    _epd_ids="$_epd_new"
    [ -n "$_epd_was" ] && _epd_ids="$(_exakit_persona_service check "$_epd_was,$_epd_new" 2>/dev/null || printf '%s' "$_epd_new")"
    _epd_title="$(_exakit_persona_service title "$_epd_new" 2>/dev/null || printf '%s' "$_epd_new")"
    _epd_all="$(_exakit_persona_service title "$_epd_ids" 2>/dev/null || printf '%s' "$_epd_ids")"
    _epd_answers="$(_exakit_persona_service answers "$_epd_ids")" || \
        die "The persona files could not be read - repair the kit copy with: exakit update"
    _exakit_persona_export "$_epd_answers"
    EXAKIT_PERSONA_SOURCE=add
    export EXAKIT_PERSONA_SOURCE
    _exakit_persona_record
    _exakit_log_file "INFO  persona add $_epd_new -> $EXAKIT_PERSONA: $(printf '%s' "$_epd_answers" | tr '\n' ' ')"
    printf '\n'
    if [ "$_epd_ids" = "$_epd_new" ]; then
        heading "Adding persona: $_epd_title"
    else
        heading "Adding persona: $_epd_title (now $_epd_all)"
    fi
    # The installer's tables where there is a screen to animate them on.
    _epd_live=0
    [ "${UI_FANCY:-0}" = 1 ] && [ -t 1 ] && _epd_live=1
    _epd_failed=""                   # "<part>|<the command that retries it>" lines

    exakit_step_heading "Step 1/3  Sample data"
    _epd_load=""; _epd_have=""
    if [ "${EXAKIT_LOAD_SAMPLE:-}" != 0 ] && [ -n "${EXAKIT_DATASETS:-}" ]; then
        _epd_known=" $(exakit_bundled_datasets 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ') "
        _epd_pending=" $(exakit_pending_datasets 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ') "
        for _epd_d in $(printf '%s' "$EXAKIT_DATASETS" | tr ',' ' '); do
            case "$_epd_known" in
                *" $_epd_d "*) ;;
                *) warn "Unknown dataset id '$_epd_d' in EXAKIT_DATASETS - left out"; continue ;;
            esac
            case "$_epd_pending" in
                *" $_epd_d "*) _epd_load="${_epd_load:+$_epd_load,}$_epd_d" ;;
                *) _epd_have="${_epd_have:+$_epd_have, }$(_exakit_persona_label "$_epd_d")" ;;
            esac
        done
    fi
    [ -n "$_epd_have" ] && ok "Already loaded: $_epd_have"
    if [ -n "$_epd_load" ]; then
        if ( _exakit_prompt_tty() { :; }
             unset EXAKIT_DATA_FILE EXAKIT_LOAD_SAMPLE
             if [ "$_epd_live" = 1 ]; then
                 # The data question's table, with only these datasets under
                 # Sample datasets (a persona lists its own), ticked.
                 unset EXAKIT_DATASETS
                 EXAKIT_PERSONA_ACTIVE=1 EXAKIT_DATASETS_PRESELECT="$_epd_load" UI_TABLE_AUTO=1
                 export EXAKIT_PERSONA_ACTIVE EXAKIT_DATASETS_PRESELECT UI_TABLE_AUTO
             else
                 EXAKIT_DATASETS="$_epd_load"
                 export EXAKIT_DATASETS
             fi
             cmd_data_load ); then
            :
        else
            _epd_failed="${_epd_failed}Sample data|EXAKIT_DATASETS=$_epd_load exakit data-load
"
        fi
    elif [ -z "$_epd_have" ]; then
        info "No sample data for these personas"
    fi

    exakit_step_heading "Step 2/3  AI clients"
    if [ "${EXAKIT_SKIP_MCP:-}" = 1 ]; then
        info "Skipping the AI clients (EXAKIT_SKIP_MCP=1) - connect them any time with: exakit mcp-setup"
    else
        case "${EXAKIT_MCP_CLIENTS:-}" in
            ""|skip|SKIP|Skip|none|NONE|None) info "No AI clients for these personas" ;;
            *)
                if ( _exakit_prompt_tty() { :; }
                     if [ "$_epd_live" = 1 ]; then
                         # The installer's client table: the clients already
                         # connected are on it, saying so; the personas' pending
                         # ones are ticked ("all": every one on this machine).
                         EXAKIT_MCP_PRESELECT="$EXAKIT_MCP_CLIENTS" UI_TABLE_AUTO=1
                         export EXAKIT_MCP_PRESELECT UI_TABLE_AUTO
                         unset EXAKIT_MCP_CLIENTS
                     fi
                     cmd_mcp_setup ); then
                    :
                else
                    _epd_failed="${_epd_failed}AI clients|exakit mcp-setup
"
                fi
                ;;
        esac
    fi

    exakit_step_heading "Step 3/3  Add-ons"
    _epd_ad="${EXAKIT_MARKETPLACE_ADDONS:-}"
    case "$_epd_ad" in
        none) _epd_ad="" ;;
        all) _epd_ad="$(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')" ;;
    esac
    _epd_installed=" $(exakit_marketplace_installed_addons 2>/dev/null | tr '\n' ' ') "
    _epd_get=""; _epd_got=""
    for _epd_a in $(printf '%s' "$_epd_ad" | tr ',' ' '); do
        case "$_epd_installed" in
            *" $_epd_a "*) _epd_got="${_epd_got:+$_epd_got, }$_epd_a" ;;
            *) _epd_get="${_epd_get:+$_epd_get,}$_epd_a" ;;
        esac
    done
    [ -n "$_epd_got" ] && ok "Already installed: $_epd_got"
    if [ -n "$_epd_get" ]; then
        if ( _exakit_prompt_tty() { :; }
             if [ "$_epd_live" = 1 ]; then
                 # The marketplace's table, narrowed to these add-ons, all ticked
                 # (the notebook's tools as its child rows, their own defaults).
                 EXAKIT_MARKETPLACE_ONLY="$_epd_get" UI_TABLE_AUTO=1
                 export EXAKIT_MARKETPLACE_ONLY UI_TABLE_AUTO
                 unset EXAKIT_MARKETPLACE_ADDONS
             else
                 EXAKIT_MARKETPLACE_ADDONS="$_epd_get"
                 export EXAKIT_MARKETPLACE_ADDONS
             fi
             cmd_marketplace ); then
            :
        else
            _epd_failed="${_epd_failed}Add-ons|exakit marketplace $(printf '%s' "$_epd_get" | tr ',' ' ')
"
        fi
    elif [ -z "$_epd_got" ]; then
        info "No add-ons for these personas"
    fi

    # Services are declared by the persona, and start only after its add-ons
    # have been installed. Reapplying a persona is safe: start is idempotent.
    for _epd_service in $(_exakit_persona_service services "$_epd_new" 2>/dev/null); do
        case "$_epd_service" in
            mlflow)
                if ( _exakit_prompt_tty() { :; }; cmd_mlflow start ); then :
                else _epd_failed="${_epd_failed}MLflow service|exakit mlflow start
"; fi ;;
        esac
    done

    printf '\n'
    if [ -z "$_epd_failed" ]; then
        printf '  %s%s%s %sPersona added: %s%s\n' "${UI_OK:-}" "${UI_TICK:-[ok]}" "${UI_RESET:-}" \
            "${UI_BOLD:-}" "$_epd_all" "${UI_RESET:-}"
        _exakit_log_file "OK    persona added: $EXAKIT_PERSONA"
        return 0
    fi
    printf '  %s%s%s %sPersona added: %s%s - not everything finished\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_RESET:-}" \
        "${UI_BOLD:-}" "$_epd_all" "${UI_RESET:-}"
    while IFS='|' read -r _epd_part _epd_retry; do
        [ -n "$_epd_part" ] || continue
        warn "$_epd_part did not finish - retry with: $_epd_retry"
    done <<EXAKIT_EPD_EOF
$_epd_failed
EXAKIT_EPD_EOF
    return 1
}
