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
#   exakit persona list|show <id>|apply <id> [--yes]
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

# exakit_persona_known <id>[,<id>] — every persona named exists.
exakit_persona_known() {
    [ -n "$1" ] && _exakit_persona_service check "$1" >/dev/null 2>&1
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
            EXAKIT_DATASETS|EXAKIT_LOAD_SAMPLE|EXAKIT_MCP_CLIENTS|EXAKIT_MARKETPLACE_ADDONS|EXAKIT_NOTEBOOK_FRONTENDS|EXAKIT_PERSONA)
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

# exakit_persona_apply_env — with EXAKIT_PERSONA set, export the personas'
# answers for every variable the user did not set. Dies on an unknown persona,
# before anything is installed. Records the persona in the manifest.
exakit_persona_apply_env() {
    [ -n "${EXAKIT_PERSONA:-}" ] || return 0
    if ! exakit_persona_known "$EXAKIT_PERSONA"; then
        die "Unknown persona '$EXAKIT_PERSONA' (available: $(exakit_persona_ids | tr '\n' ' ' | sed 's/ $//'))."
    fi
    _epa_answers="$(_exakit_persona_service answers "$EXAKIT_PERSONA")" || \
        die "The persona files could not be read - re-run the installer to repair the kit copy."
    _exakit_persona_export "$_epa_answers"
    info "Persona: $(_exakit_persona_service title "$EXAKIT_PERSONA") - datasets ${EXAKIT_DATASETS:-none}; AI clients ${EXAKIT_MCP_CLIENTS:-asked}; add-ons ${EXAKIT_MARKETPLACE_ADDONS:-none}"
    _exakit_log_file "INFO  persona $EXAKIT_PERSONA answered: $(printf '%s' "$_epa_answers" | tr '\n' ' ')"
    _exakit_persona_record
    export EXAKIT_PERSONA_ACTIVE=1
    return 0
}

# exakit_persona_question — "What will you use this machine for?": the personas
# the kit offers ("picker": true), the "default": true ones ticked to begin
# with, as many as wanted. Without a
# terminal nobody can be asked: General. The answer is EXAKIT_PERSONA.
exakit_persona_question() {
    _epq_rows="$(_exakit_persona_service picker 2>/dev/null)"
    if [ -z "$_epq_rows" ]; then
        _exakit_log_file "WARN  the persona service did not answer; no persona question"
        return 0
    fi
    _epq_ids=()
    _epq_labels=()
    _epq_default=""                  # the personas whose file says "default": true
    _epq_n=0
    while IFS='|' read -r _epq_id _epq_title _epq_summary _epq_ticked; do
        [ -n "$_epq_id" ] || continue
        _epq_n=$(( _epq_n + 1 ))
        _epq_ids+=("$_epq_id")
        _epq_labels+=("$_epq_title - $_epq_summary")
        [ "$_epq_ticked" = 1 ] && _epq_default="${_epq_default:+$_epq_default,}$_epq_n"
    done <<EXAKIT_EPQ_EOF
$_epq_rows
EXAKIT_EPQ_EOF
    ui_rule
    heading "What will you use this machine for?"
    _epq_default="${_epq_default:-1}"
    ui_checkbox_menu "Personas - tick one or more" "$_epq_default" "${_epq_labels[@]}"
    EXAKIT_PERSONA=""
    for _epq_i in $(printf '%s' "${EXAKIT_CHECKBOX_SELECTION:-}" | tr ',' ' '); do
        case "$_epq_i" in ''|*[!0-9]*) continue ;; esac
        [ "$_epq_i" -ge 1 ] && [ "$_epq_i" -le "$_epq_n" ] || continue
        EXAKIT_PERSONA="${EXAKIT_PERSONA:+$EXAKIT_PERSONA,}${_epq_ids[$(( _epq_i - 1 ))]}"
    done
    [ -n "$EXAKIT_PERSONA" ] || EXAKIT_PERSONA="${_epq_ids[$(( ${_epq_default%%,*} - 1 ))]}"
    export EXAKIT_PERSONA
}

# exakit_persona_flow <kit_root> — the install's persona section, after the
# parts everyone needs: the personas (asked here unless EXAKIT_PERSONA answered
# it already), then the data. Picked on screen, their datasets come TICKED in
# the data question and their add-ons ticked in the closing marketplace offer -
# nothing is installed or loaded unasked. Named in the environment, they answer
# as EXAKIT_DATASETS and EXAKIT_MARKETPLACE_ADDONS always did.
exakit_persona_flow() {
    _epf_root="$1"
    # No database: nothing here can run, and the install already said so.
    exakit_soft_failed runtime && return 0
    if [ -z "${EXAKIT_PERSONA:-}" ] && [ -n "$(_exakit_prompt_tty)" ] && [ "${UI_FANCY:-0}" = 1 ]; then
        exakit_persona_question
        if [ -n "${EXAKIT_PERSONA:-}" ] && exakit_persona_known "$EXAKIT_PERSONA"; then
            # Asked on screen: the answers become what the menus tick, not what
            # runs without them. EXAKIT_* the user set still win.
            _epf_answers="$(_exakit_persona_service answers "$EXAKIT_PERSONA" 2>/dev/null)"
            _epf_ds="$(printf '%s\n' "$_epf_answers" | sed -n 's/^EXAKIT_DATASETS=//p')"
            _epf_ad="$(printf '%s\n' "$_epf_answers" | sed -n 's/^EXAKIT_MARKETPLACE_ADDONS=//p')"
            [ "$_epf_ds" = all ] && _epf_ds="$(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
            [ -n "$_epf_ds" ] && { EXAKIT_DATASETS_PRESELECT="$_epf_ds"; export EXAKIT_DATASETS_PRESELECT; }
            [ -n "$_epf_ad" ] && [ "$_epf_ad" != none ] && { EXAKIT_MARKETPLACE_PRESELECT="$_epf_ad"; export EXAKIT_MARKETPLACE_PRESELECT; }
            ok "Persona: $(_exakit_persona_service title "$EXAKIT_PERSONA")"
            _exakit_log_file "INFO  persona $EXAKIT_PERSONA picked on screen: datasets ${_epf_ds:-none}; add-ons ${_epf_ad:-none}"
            _exakit_persona_record
            export EXAKIT_PERSONA_ACTIVE=1
        fi
    fi
    # The data, with the personas' datasets ticked (or loaded, when named in the
    # environment). See exakit_maybe_offer_data_load.
    exakit_persona_data "$_epf_root"
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

# exakit_persona_marketplace_note — after a persona install, the marketplace is
# named once: everything the personas did not bring is one command away.
exakit_persona_marketplace_note() {
    [ -n "${EXAKIT_PERSONA_ACTIVE:-}" ] || return 0
    info "More for any persona in the marketplace: exakit marketplace (dashboards, notebooks, dbt, the scheduler, Python UDFs, JSON tables)"
}
