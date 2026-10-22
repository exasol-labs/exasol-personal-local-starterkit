#!/usr/bin/env bash
# personas.sh — the persona files and setup/lib/persona.sh (PRD P-1).
#
#   bash tests/personas.sh
#
# What it pins:
#   - every personas/<id>.json is valid: its id is its file name; its datasets
#     are bundled datasets (or all/none), its add-ons registered add-ons (or
#     all/none), its AI clients all/skip or known ids; it holds no secret and no
#     machine path; and the Python-free shell reader reads it the way a JSON
#     parser does
#   - the three personas the install question offers, each with its own data:
#     the two personas of the TDD/BRD: AI Scientist (data-scientist: Pharma and
#     Banking, the notebook add-on) and ML Engineer (the same plus udf-devkit)
#   - the persona service (setup/lib/persona_service.py) combines several, and
#     the data question (one "Data to load" table) ticks their datasets and
#     names who each is for
#   - an explicit answer wins, per variable; an unknown persona stops the run
#     before anything is installed; the persona is recorded in the manifest
#
# A sandboxed kit home; nothing is installed.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# shellcheck disable=SC1091
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"; . "$ROOT/setup/lib/persona.sh"
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
manifest_init >/dev/null 2>&1

DATASETS=" $(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ' ') "
ADDONS=" $(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ') "

echo "every persona file is valid:"
ids="$(exakit_persona_ids)"
check "personas exist" "yes" "$([ -n "$ids" ] && echo yes || echo no)"
for id in $ids; do
    f="$ROOT/personas/$id.json"
    check "$id: the id is the file name" "$id" "$(exakit_persona_value "$id" id)"
    check "$id: schema 1" "1" "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['schema_version'])" "$f")"
    for key in title summary; do
        check "$id: has a $key" "yes" "$([ -n "$(exakit_persona_value "$id" $key)" ] && echo yes || echo no)"
    done
    bad=""
    ds="$(exakit_persona_value "$id" datasets)"
    case "$ds" in all|none) ;; *) for d in $(printf '%s' "$ds" | tr ',' ' '); do case "$DATASETS" in *" $d "*) ;; *) bad="$bad dataset:$d" ;; esac; done ;; esac
    ad="$(exakit_persona_value "$id" addons)"
    case "$ad" in all|none) ;; *) for a in $(printf '%s' "$ad" | tr ',' ' '); do case "$ADDONS" in *" $a "*) ;; *) bad="$bad addon:$a" ;; esac; done ;; esac
    check "$id: names only datasets and add-ons this kit ships" "" "$bad"
    check "$id: holds no secret and no machine path" "" \
        "$(grep -i -E 'password|secret|token|/Users/|/home/|C:\\\\|EXAKIT_HOME' "$f" || true)"
    # The persona service reads every key the way a JSON parser does.
    for key in datasets mcp_clients addons title; do
        py="$(python3 -c "import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(','.join(v) if isinstance(v, list) else v)" "$f" "$key")"
        check "$id: the service agrees on $key" "$py" "$(exakit_persona_value "$id" "$key")"
    done
done

echo "the three personas the install question offers, each with its own data:"
check "the question offers AI Scientist, then ML Engineer" "data-scientist,ml-engineer" \
    "$(_exakit_persona_service picker | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
check "no persona: the kit's own samples (default=yes)" "tpch,energy,weather" "$(_exakit_persona_service default-datasets)"
check "data-scientist: Pharma and Banking" "pharma_trials,banking_complaints" "$(exakit_persona_value data-scientist datasets)"
check "data-scientist: the notebook add-on" "notebook" "$(exakit_persona_value data-scientist addons)"
check "ml-engineer: Pharma and Banking" "pharma_trials,banking_complaints" "$(exakit_persona_value ml-engineer datasets)"
check "ml-engineer: notebook and udf-devkit" "notebook,udf-devkit" "$(exakit_persona_value ml-engineer addons)"

echo "a new persona is one file and no code:"
mkdir -p "$WORK/kit2/personas"
cp "$ROOT"/personas/*.json "$WORK/kit2/personas/"
printf '{"schema_version": 1, "id": "analyst", "title": "Analyst", "summary": "SQL on the samples.", "picker": true, "order": 15, "datasets": ["tpch"], "mcp_clients": "all", "addons": ["dash-server"]}\n' \
    > "$WORK/kit2/personas/analyst.json"
check "the question offers it where its order says, unticked" "data-scientist|0 analyst|0 ml-engineer|0" \
    "$(python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit2" picker | awk -F'|' '{printf "%s%s|%s", (NR>1?" ":""), $1, $4}')"
check "it answers like any other" "EXAKIT_DATASETS=tpch EXAKIT_MARKETPLACE_ADDONS=dash-server" \
    "$(env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE -u EXAKIT_MARKETPLACE_ADDONS python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit2" answers analyst | grep -E '^EXAKIT_(DATASETS|MARKETPLACE_ADDONS)=' | tr '\n' ' ' | sed 's/ $//')"
check "the notebook catalog names only personas the kit ships" "" \
    "$(python3 "$ROOT/notebook/kit/notebooks.py" list "$ROOT" | cut -d'|' -f2 | sort -u | while read -r p; do [ -f "$ROOT/personas/$p.json" ] || printf ' %s' "$p"; done)"

echo "several personas ticked together are combined by the service:"
check "the title names each" "AI Scientist + ML Engineer" "$(_exakit_persona_service title ml-engineer,data-scientist)"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=data-scientist,ml-engineer; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "their datasets and add-ons together, each once" "pharma_trials,banking_complaints|all|notebook,udf-devkit" "$out"
check "each dataset is named with the personas it is for" "pharma_trials|AI Scientist, ML Engineer" \
    "$(exakit_persona_dataset_hints | grep '^pharma_trials|')"

echo "the data question: one table, the personas' datasets ticked:"
# The ids as _exakit_data_table_preselect sees them: the parent and the
# datasets (the table builder asks before the file, external and Skip rows).
EXAKIT_TABLE_IDS="
tpch
energy
pharma_trials
banking_complaints
"
check "a persona's datasets are the rows ticked" "4,5" "$(_exakit_data_table_preselect pharma_trials,banking_complaints)"
check "datasets covering every dataset row tick the Sample datasets parent too" "1,2,3,4,5" "$(_exakit_data_table_preselect tpch,energy,pharma_trials,banking_complaints)"
check "a persona that wants none ticks nothing (the table then ticks Skip)" "" "$(_exakit_data_table_preselect none)"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\npharma_trials|Pharma clinical trials (ClinicalTrials.gov, ~5k)\n'; }
        EXAKIT_DATASETS_PRESELECT=pharma_trials; exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_ROW_LOCAL" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')" \
            "$(cut -d'|' -f11 "$WORK/table" | tr '\n' ';')") )"
check "the persona's row ticked, the file and external rows after the datasets, each named for its persona in the For column" \
    "3~4~Sample datasets;TPC-H retail benchmark;Pharma clinical trials;Your file or folder: CSV, Parquet, JSON;Connect an external source - coming soon;Skip;~;;AI Scientist, ML Engineer;;;;" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; _exakit_prompt_tty() { :; }
        exakit_data_load_select Skip >/dev/null 2>&1; printf '%s' "$EXAKIT_DATA_LOAD_SELECTION") )"
check "without a terminal the pending samples are the answer" "tpch" "$out"
out="$( (exakit_pending_datasets() { :; }; _exakit_prompt_tty() { :; }
        exakit_data_load_select Skip >/dev/null 2>&1; printf '%s' "$EXAKIT_DATA_LOAD_SELECTION") )"
check "with every sample loaded, your own file is the default" "local" "$out"

echo "an explicit answer wins, per variable:"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=ml-engineer; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "the persona answers everything left open" "pharma_trials,banking_complaints|all|notebook,udf-devkit" "$out"
out="$( (unset EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_DATASETS=pharma_trials EXAKIT_PERSONA=ml-engineer; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "EXAKIT_DATASETS wins, the rest stays the persona's" "pharma_trials|all|notebook,udf-devkit" "$out"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS
        export EXAKIT_LOAD_SAMPLE=0 EXAKIT_MARKETPLACE_ADDONS=none EXAKIT_PERSONA=data-scientist; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "${EXAKIT_DATASETS:-unset}" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "EXAKIT_LOAD_SAMPLE=0 and add-ons none win" "unset|all|none" "$out"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_SKIP_MCP=1 EXAKIT_PERSONA=data-scientist; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s' "${EXAKIT_MCP_CLIENTS:-unset}") )"
check "EXAKIT_SKIP_MCP=1 wins over the persona's clients" "unset" "$out"

echo "an unknown persona stops the run; a known one is recorded:"
out="$( (EXAKIT_PERSONA=nope exakit_persona_apply_env) 2>&1)"; rc=$?
check "unknown: refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
contains "unknown: names the ones there are" "data-scientist" "$out"
out="$( (EXAKIT_PERSONA=data-scientist,nope exakit_persona_apply_env) 2>&1)"; rc=$?
check "one unknown among several: refused" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
( unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
  EXAKIT_PERSONA=data-scientist exakit_persona_apply_env >/dev/null 2>&1 )
check "the manifest records the persona" "data-scientist|install" "$(manifest_get persona.id)|$(manifest_get persona.source)"
check "no persona, no change" "" "$( (unset EXAKIT_PERSONA; exakit_persona_apply_env 2>&1) )"

echo "a broken persona file is named and the others keep working:"
mkdir -p "$WORK/kit3/personas"
cp "$ROOT"/personas/*.json "$WORK/kit3/personas/"
ln -s "$ROOT/data" "$WORK/kit3/data"; ln -s "$ROOT/setup" "$WORK/kit3/setup"
printf '{' > "$WORK/kit3/personas/broken.json"
printf '{"id":"pipe","title":"SQL | BI","summary":"x","picker":true}' > "$WORK/kit3/personas/pipe.json"
printf '{"id":"inj","title":"Inj","summary":"x","datasets":["tpch\\nEXAKIT_MCP_CLIENTS=claude"]}' > "$WORK/kit3/personas/inj.json"
printf '\xef\xbb\xbf{"id":"everything","title":"Everything","summary":"All of it.","datasets":"all","addons":"all"}' > "$WORK/kit3/personas/everything.json"
printf '{"id":"bare","title":"Bare","summary":"Nothing.","datasets":[],"addons":[],"mcp_clients":[]}' > "$WORK/kit3/personas/bare.json"
printf 'junk' > "$WORK/kit3/personas/._data-scientist.json"
SVC3() { env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE -u EXAKIT_MARKETPLACE_ADDONS -u EXAKIT_MCP_CLIENTS -u EXAKIT_NOTEBOOK_FRONTENDS \
    python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit3" "$@"; }
check "the valid ones still answer (a BOM is fine, dotfiles are skipped)" "data-scientist ml-engineer bare everything" \
    "$(SVC3 ids 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "each broken file is named with what is wrong" "broken.json inj.json pipe.json" \
    "$(SVC3 problems | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
contains "a title with | is refused" "'title' must be one line without '|'" "$(SVC3 problems)"
contains "a list item that is not an id is refused" "which is not an id" "$(SVC3 problems)"
contains "naming a broken persona says what is wrong with its file" "personas/pipe.json is invalid" "$(SVC3 check pipe 2>&1)"
check "datasets \"all\" become the kit's dataset ids (EXAKIT_DATASETS takes ids)" \
    "EXAKIT_DATASETS=$(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')" "$(SVC3 answers everything 2>/dev/null | grep '^EXAKIT_DATASETS=')"
check "[] answers the nothing-word for each key" "EXAKIT_LOAD_SAMPLE=0 EXAKIT_MCP_CLIENTS=skip EXAKIT_MARKETPLACE_ADDONS=none" \
    "$(SVC3 answers bare 2>/dev/null | grep -v '^EXAKIT_PERSONA=' | tr '\n' ' ' | sed 's/ $//')"
check "an empty add-on list answers none" "EXAKIT_MARKETPLACE_ADDONS=none" "$(SVC3 answers bare 2>/dev/null | grep '^EXAKIT_MARKETPLACE_ADDONS=')"
check "an EXAKIT_LOAD_SAMPLE the installer does not read is not an answer" "EXAKIT_DATASETS=pharma_trials,banking_complaints" \
    "$(EXAKIT_LOAD_SAMPLE=yes python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" answers data-scientist 2>/dev/null | grep '^EXAKIT_DATASETS=')"
check "one persona where one is meant" "2" "$(python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" value data-scientist,ml-engineer title >/dev/null 2>&1; echo $?)"
out="$( (EXAKIT_PERSONA=nope; exakit_persona_known nope; printf '%s' "$EXAKIT_PERSONA_PROBLEM") )"
contains "an unknown persona is named with the ones there are" "Unknown persona 'nope' (available: data-scientist ml-engineer)" "$out"
out="$( (run_python_any() { return 127; }; exakit_persona_known data-scientist; printf '%s' "$EXAKIT_PERSONA_PROBLEM") )"
contains "no Python: says so, not 'unknown persona'" "needs Python 3" "$out"

echo "the install's persona section:"
out="$( (manifest_set persona.id ""
        ui_checkbox_menu() { shift; printf '%s|%s|%s' "$1" "${EXAKIT_CHECKBOX_EXCLUSIVE:-}" "$(eval echo \"\${$#}\")" > "$WORK/q"; EXAKIT_CHECKBOX_SELECTION="3"; }
        exakit_persona_question >/dev/null 2>&1; printf '%s~%s' "$(cat "$WORK/q")" "${EXAKIT_PERSONA:-}") )"
check "the question ends with None, exclusive and ticked to begin with; picking it is no persona" \
    "3|3|None - just the kit, with the TPC-H, energy and weather samples~" "$out"
out="$( (unset EXAKIT_PERSONA EXAKIT_DATASETS EXAKIT_LOAD_SAMPLE EXAKIT_DATASETS_PRESELECT EXAKIT_MARKETPLACE_PRESELECT
        exakit_persona_data() { :; }; exakit_persona_flow "$ROOT" </dev/null >/dev/null 2>&1
        printf '%s|%s|%s' "${EXAKIT_DATASETS_PRESELECT:-}" "${EXAKIT_MARKETPLACE_PRESELECT:-}" "${EXAKIT_PERSONA:-}") )"
check "no terminal, no persona: the default personas' datasets, nothing recorded" "tpch,energy,weather||" "$out"
out="$( (unset EXAKIT_DATASETS_PRESELECT EXAKIT_MARKETPLACE_PRESELECT; exakit_repo_root() { printf '%s\n' "$WORK/kit3"; }
        _exakit_persona_preselect bare; printf '%s|%s' "${EXAKIT_DATASETS_PRESELECT:-}" "${EXAKIT_MARKETPLACE_PRESELECT:-}") )"
check "a persona with no datasets ticks none (and offers no add-ons)" "none|" "$out"
out="$( (unset EXAKIT_DATASETS_PRESELECT EXAKIT_MARKETPLACE_PRESELECT; exakit_repo_root() { printf '%s\n' "$WORK/kit3"; }
        _exakit_persona_preselect everything; printf '%s' "${EXAKIT_MARKETPLACE_PRESELECT:-}") )"
check "a persona with every add-on offers all" "all" "$out"
out="$( (exakit_soft_failed() { [ "$1" = exapump ]; }; exakit_persona_question() { echo ASKED; }
        exakit_persona_data() { echo DATA; }; _exakit_prompt_tty() { echo /dev/tty; }; UI_FANCY=1; unset EXAKIT_PERSONA
        exakit_persona_flow "$ROOT" 2>&1) )"
check "exapump missing: nobody is asked, the data step says why" "DATA" "$out"
out="$( (_exakit_prompt_tty() { echo /dev/tty; }; UI_FANCY=1; unset EXAKIT_PERSONA; exakit_persona_question() { echo ASKED; }
        exakit_persona_data() { :; }; EXAKIT_DATASETS=tpch EXAKIT_MARKETPLACE_ADDONS=none exakit_persona_flow "$ROOT" 2>&1) )"
check "everything already answered in the environment: not asked" "" "$out"
out="$( (manifest_set persona.id ml-engineer
        ui_checkbox_menu() { shift; printf '%s' "$1" > "$WORK/defaults"; EXAKIT_CHECKBOX_SELECTION=""; }
        exakit_persona_question >/dev/null 2>&1; cat "$WORK/defaults") )"
check "a re-run ticks the persona this kit was set up as" "2" "$out"
out="$( (EXAKIT_PERSONA_ACTIVE=1; unset EXAKIT_MARKETPLACE_PRESELECT; exakit_persona_marketplace_note 2>&1) )"
check "no persona offer, no second marketplace pointer" "" "$out"
contains "...after a persona offer, one pointer" "exakit marketplace" \
    "$( (EXAKIT_PERSONA_ACTIVE=1 EXAKIT_MARKETPLACE_PRESELECT=notebook exakit_persona_marketplace_note 2>&1) )"

echo "exakit persona plan (AC-P1.1: nothing pending after a persona install):"
out="$( (exakit_pending_datasets() { printf 'banking_complaints|Banking\n'; }; exakit_marketplace_installed_addons() { echo notebook; }
        exakit_persona_plan ml-engineer 0 2>&1) )"
contains "what is loaded and what is pending" "loaded: pharma_trials   pending: banking_complaints" "$out"
contains "...add-ons the same way" "installed: notebook   pending: udf-devkit" "$out"
contains "...and how to finish" "exakit persona apply ml-engineer" "$out"
out="$( (exakit_pending_datasets() { :; }; exakit_marketplace_installed_addons() { printf 'notebook\nudf-devkit\n'; }
        exakit_persona_plan ml-engineer 1 2>/dev/null) )"
check "--json after a complete install: nothing pending" "true" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d["nothing_pending"]).lower() if not d["datasets"]["pending"] and not d["addons"]["pending"] else "pending")' 2>/dev/null)"

echo "exakit persona apply:"
_cp_range='/^cmd_persona() {/,/^}/p'      # assigned first: bash 3.2 brace-expands it as an argument
sed -n "$_cp_range" "$ROOT/setup/exakit" > "$WORK/cmd_persona.sh"
. "$WORK/cmd_persona.sh"
cmd_data_load() { echo "STEP data-load"; }; cmd_mcp_setup() { echo "STEP mcp-setup"; }; cmd_marketplace() { echo "STEP marketplace"; }
manifest_set persona.id ""
out="$( (_exakit_prompt_tty() { :; }; cmd_persona apply ml-engineer 2>&1); echo "rc=$?")"
contains "no terminal and no --yes: nothing changes" "rc=5" "$out"
check "...and nothing is recorded" "" "$(manifest_get persona.id 2>/dev/null)"
out="$( (_exakit_prompt_tty() { echo /dev/tty; }; confirm() { return 1; }; cmd_persona apply ml-engineer 2>&1); echo "rc=$?")"
contains "declined: exit 5" "rc=5" "$out"
check "...and nothing is recorded" "" "$(manifest_get persona.id 2>/dev/null)"
out="$( (cmd_persona apply ml-engineer --yes 2>&1); echo "rc=$?")"
contains "with --yes every step runs" "STEP data-load" "$out"
contains "...and the persona is recorded" "rc=0" "$out"
check "...as apply" "ml-engineer|apply" "$(manifest_get persona.id)|$(manifest_get persona.source)"
out="$( (cmd_persona apply data-scientist ml-engineer --yes 2>&1); echo "rc=$?")"
contains "two ids as two words: refused, joined with a comma instead" "exakit persona apply data-scientist,ml-engineer" "$out"
out="$( (exakit_repo_root() { printf '%s\n' "$WORK/kit3"; }; cmd_persona apply bare --yes 2>&1) )"
contains "a persona without datasets loads none" "No sample data for this persona" "$out"
manifest_set persona.id ""

echo "the installer refuses an unknown persona before anything is installed:"
# install.sh's dry run stops before the setup scripts, so it checks the persona
# itself; install.ps1 carries the same check (Windows only - pinned statically).
dry() { HOME="$WORK/dryhome" EXAKIT_HOME="$WORK/dryhome/kit" EXAKIT_BIN_DIR="$WORK/dryhome/bin" \
        EXAKIT_LOCAL_KIT="$ROOT" EXAKIT_DRY_RUN=1 EXAKIT_PERSONA="$1" sh "$ROOT/install.sh" 2>&1; }
out="$(dry nope)"; rc=$?
check "install.sh: an unknown persona fails" "1" "$rc"
contains "install.sh: and says which exist" "available: data-scientist ml-engineer" "$out"
out="$(dry data-scientist,ml-engineer)"
contains "install.sh: several personas joined by commas" "Persona: data-scientist,ml-engineer" "$out"
out="$(dry data-scientist,nope)"
contains "install.sh: one unknown among several is named" "Unknown persona 'nope'" "$out"
for bad in ML-ENGINEER ../versions examples/analyst '*' 'ml-engineer ml-engineer' general; do
    out="$(dry "$bad")"; rc=$?
    check "install.sh: '$bad' is not a persona id" "1" "$rc"
done
out="$(dry ' data-scientist , ml-engineer ')"
contains "install.sh: spaces around the ids are fine" "Persona: data-scientist,ml-engineer" "$out"
out="$(dry ml-engineer)"
contains "install.sh: a known persona is named in the plan" "Persona: ml-engineer" "$out"
check "install.ps1: the same refusal" "yes" \
    "$(grep -q "throw \"Unknown persona '\$personaId'" "$ROOT/install.ps1" && grep -q '"personas"' "$ROOT/install.ps1" && echo yes || echo no)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
