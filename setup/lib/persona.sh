#!/usr/bin/env bash
# persona.sh — personas: a named set of the answers the installer already
# takes from the environment (EXAKIT_DATASETS, EXAKIT_MCP_CLIENTS,
# EXAKIT_MARKETPLACE_ADDONS). Files: personas/<id>.json (personas/README.md).
#
#   EXAKIT_PERSONA=<id> at install time  -> exakit_persona_apply_env fills in
#                                           every answer the user did not give
#   exakit persona list|show <id>|apply <id> [--yes]
#
# An explicit answer always wins, per variable: EXAKIT_PERSONA=data-scientist
# EXAKIT_DATASETS=pharma_trials loads only that dataset and keeps the persona's
# clients and add-ons. Sourced after common.sh. Twin: persona.ps1.
#
# The files are read without Python (the installer reads them before any
# Python exists): each key's value is a "string" or a ["list"], and the reader
# below takes exactly that. tests/personas.sh holds every shipped file to it.

# exakit_persona_dir — where the persona files live in this kit copy.
exakit_persona_dir() {
    printf '%s/personas\n' "$(exakit_repo_root)"
}

# exakit_persona_ids — every persona this kit ships, one per line.
exakit_persona_ids() {
    for _epi_f in "$(exakit_persona_dir)"/*.json; do
        [ -f "$_epi_f" ] && basename "$_epi_f" .json
    done
}

# exakit_persona_value <id> <key> — the key's value: a string as it is, a list
# as a comma-separated line. Empty when the key is absent.
exakit_persona_value() {
    tr -d '\n\r\t' < "$(exakit_persona_dir)/$1.json" 2>/dev/null | \
        sed -nE "s/.*\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|\[[^]]*\]).*/\1/p" | \
        sed -e 's/^\[//' -e 's/\]$//' -e 's/"//g' -e 's/[[:space:]]*,[[:space:]]*/,/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# exakit_persona_known <id> — the persona exists.
exakit_persona_known() {
    [ -n "$1" ] && [ -f "$(exakit_persona_dir)/$1.json" ]
}

# exakit_persona_apply_env — with EXAKIT_PERSONA set, export the persona's
# answers for every variable the user did not set. Dies on an unknown persona,
# before anything is installed. Records the persona in the manifest.
exakit_persona_apply_env() {
    [ -n "${EXAKIT_PERSONA:-}" ] || return 0
    if ! exakit_persona_known "$EXAKIT_PERSONA"; then
        die "Unknown persona '$EXAKIT_PERSONA' (available: $(exakit_persona_ids | tr '\n' ' ' | sed 's/ $//'))."
    fi
    _epa_from=""
    if [ -z "${EXAKIT_DATASETS:-}" ] && [ -z "${EXAKIT_LOAD_SAMPLE:-}" ]; then
        _epa_ds="$(exakit_persona_value "$EXAKIT_PERSONA" datasets)"
        case "$_epa_ds" in
            none) EXAKIT_LOAD_SAMPLE=0; export EXAKIT_LOAD_SAMPLE ;;
            all)  EXAKIT_DATASETS="$(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"; export EXAKIT_DATASETS ;;
            ?*)   EXAKIT_DATASETS="$_epa_ds"; export EXAKIT_DATASETS ;;
        esac
        _epa_from="$_epa_from datasets"
    fi
    if [ -z "${EXAKIT_MCP_CLIENTS:-}" ] && [ "${EXAKIT_SKIP_MCP:-0}" != 1 ]; then
        _epa_cl="$(exakit_persona_value "$EXAKIT_PERSONA" mcp_clients)"
        [ -n "$_epa_cl" ] && { EXAKIT_MCP_CLIENTS="$_epa_cl"; export EXAKIT_MCP_CLIENTS; _epa_from="$_epa_from clients"; }
    fi
    if [ -z "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then
        _epa_ad="$(exakit_persona_value "$EXAKIT_PERSONA" addons)"
        [ -n "$_epa_ad" ] && { EXAKIT_MARKETPLACE_ADDONS="$_epa_ad"; export EXAKIT_MARKETPLACE_ADDONS; _epa_from="$_epa_from add-ons"; }
    fi
    info "Persona: $(exakit_persona_value "$EXAKIT_PERSONA" title) - datasets ${EXAKIT_DATASETS:-none}; AI clients ${EXAKIT_MCP_CLIENTS:-asked}; add-ons ${EXAKIT_MARKETPLACE_ADDONS:-none}"
    _exakit_log_file "INFO  persona $EXAKIT_PERSONA answered:${_epa_from:- nothing (every answer was given explicitly)}"
    manifest_set persona.id "$EXAKIT_PERSONA"
    manifest_set persona.source "${EXAKIT_PERSONA_SOURCE:-install}"
    manifest_set persona.requested_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export EXAKIT_PERSONA_ACTIVE=1
    return 0
}
