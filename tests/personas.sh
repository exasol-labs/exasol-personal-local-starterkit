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
#     the two personas of the TDD/BRD: Data Scientist (data-scientist: Pharma and
#     Banking, Notebook, JSON Tables and Dash Server) and ML Engineer
#     (Pharma and Banking, Notebook, JSON Tables and udf-devkit)
#   - the persona service (setup/lib/persona_service.py) combines several, and
#     the data question (one "Data to load" table) ticks their datasets and
#     names who each is for
#   - an explicit answer wins, per variable; an unknown persona stops the run
#     before anything is installed; the persona is recorded in the manifest
#   - exakit persona add (apply its alias) asks nothing: the personas named join
#     the recorded ones (their union is recorded, source add), what is in
#     already is one line, each part runs on its own and a failed one exits 1
#     with its retry; on a pty it draws the installer's three tables, headed
#     Step 1/3..3/3, each taken with its defaults and filled in, one at a time
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
check "the question offers Data Scientist, then ML Engineer" "data-scientist,ml-engineer" \
    "$(_exakit_persona_service picker | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
check "no persona: the kit's own samples (default=yes)" "tpch,energy,weather" "$(_exakit_persona_service default-datasets)"
check "data-scientist: Pharma and Banking" "pharma_trials,banking_complaints" "$(exakit_persona_value data-scientist datasets)"
check "data-scientist: notebook, JSON loading and Share" "notebook,json-tables,dash-server" "$(exakit_persona_value data-scientist addons)"
check "ml-engineer: Pharma and Banking" "pharma_trials,banking_complaints" "$(exakit_persona_value ml-engineer datasets)"
check "ml-engineer: notebook, JSON loading and UDFs" "notebook,json-tables,udf-devkit" "$(exakit_persona_value ml-engineer addons)"

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
check "the title names each" "Data Scientist + ML Engineer" "$(_exakit_persona_service title ml-engineer,data-scientist)"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=data-scientist,ml-engineer; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "their datasets and add-ons together, each once" "pharma_trials,banking_complaints|all|notebook,json-tables,dash-server,udf-devkit" "$out"
check "each dataset is named with the personas it is for" "pharma_trials|both personas" \
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
    "3~4~Sample datasets;TPC-H retail benchmark;Pharma clinical trials;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - coming soon;Skip;~;;both personas;;;;" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\npharma_trials|Pharma clinical trials (ClinicalTrials.gov, ~5k)\n'; }
        EXAKIT_PERSONA_ACTIVE=1 EXAKIT_DATASETS_PRESELECT=pharma_trials; exakit_data_table_build "$WORK/table"
        printf '%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')") )"
check "a persona picked: only its datasets under Sample datasets, then upload, external and Skip" \
    "1,2~Sample datasets;Pharma clinical trials;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - coming soon;Skip;" "$out"
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
check "the persona answers everything left open" "pharma_trials,banking_complaints|all|notebook,json-tables,udf-devkit" "$out"
out="$( (unset EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_DATASETS=pharma_trials EXAKIT_PERSONA=ml-engineer; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "EXAKIT_DATASETS wins, the rest stays the persona's" "pharma_trials|all|notebook,json-tables,udf-devkit" "$out"
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
out="$( (exakit_pending_datasets() { printf 'banking_complaints|Banking\n'; }; exakit_marketplace_installed_addons() { printf 'notebook\njson-tables\ndash-server\n'; }
        exakit_persona_plan ml-engineer 0 2>&1) )"
contains "what is loaded and what is pending" "loaded: pharma_trials   pending: banking_complaints" "$out"
contains "...add-ons the same way" "installed: notebook json-tables   pending: udf-devkit" "$out"
contains "...and how to finish" "exakit persona add ml-engineer" "$out"
out="$( (exakit_pending_datasets() { :; }; exakit_marketplace_installed_addons() { printf 'notebook\njson-tables\ndash-server\nudf-devkit\n'; }
        exakit_persona_plan ml-engineer 1 2>/dev/null) )"
check "--json after a complete install: nothing pending" "true" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d["nothing_pending"]).lower() if not d["datasets"]["pending"] and not d["addons"]["pending"] else "pending")' 2>/dev/null)"

echo "exakit persona add (apply is its alias): nothing asked, the personas join:"
_cp_range='/^cmd_persona() {/,/^}/p'      # assigned first: bash 3.2 brace-expands it as an argument
sed -n "$_cp_range" "$ROOT/setup/exakit" > "$WORK/cmd_persona.sh"
. "$WORK/cmd_persona.sh"
# Each step says what it was handed, and whether anything in it could ask.
cmd_data_load() { echo "STEP data-load datasets=${EXAKIT_DATASETS:-} tty=$(_exakit_prompt_tty)"; }
cmd_mcp_setup() { echo "STEP mcp-setup clients=${EXAKIT_MCP_CLIENTS:-} tty=$(_exakit_prompt_tty)"; }
cmd_marketplace() { echo "STEP marketplace addons=${EXAKIT_MARKETPLACE_ADDONS:-} tty=$(_exakit_prompt_tty)"; }
cmd_mlflow() { echo "STEP mlflow action=${1:-} tty=$(_exakit_prompt_tty)"; }
# Pharma is in already and the notebook installed: neither is redone.
exakit_pending_datasets() { printf 'banking_complaints|Banking complaints (CFPB, ~7k complaints)\n'; }
exakit_marketplace_installed_addons() { printf 'notebook\njson-tables\ndash-server\n'; }
add() { ( _exakit_prompt_tty() { echo /dev/tty; }; confirm() { echo ASKED; return 1; }; cmd_persona "$@" 2>&1 ); echo "rc=$?"; }
manifest_set persona.id data-scientist
out="$(add add ml-engineer </dev/null)"
contains "no --yes and no terminal: it runs" "rc=0" "$out"
check "...and asks nothing" "" "$(printf '%s\n' "$out" | grep -E 'ASKED|\[Y/n\]|tty=/dev/tty')"
check "the personas recorded are the union, in the kit's order" "data-scientist,ml-engineer|add" \
    "$(manifest_get persona.id)|$(manifest_get persona.source)"
contains "the title line names the persona added and the set it makes" \
    "Adding persona: ML Engineer (now Data Scientist + ML Engineer)" "$out"
check "three steps headed like the installer's" "Step 1/3  Sample data|Step 2/3  AI clients|Step 3/3  Add-ons" \
    "$(printf '%s\n' "$out" | grep -o 'Step [0-9]/3  [A-Za-z -]*' | sed 's/ *$//' | tr '\n' '|' | sed 's/|$//')"
contains "a dataset already loaded is said, not redone" "Already loaded: Pharma clinical trials" "$out"
contains "...the data step loads only the rest" "STEP data-load datasets=banking_complaints tty=" "$out"
contains "the AI clients are the personas' (every one detected)" "STEP mcp-setup clients=all tty=" "$out"
contains "an add-on already installed is said, not redone" "Already installed: notebook" "$out"
contains "...the add-ons step installs only the rest" "STEP marketplace addons=udf-devkit tty=" "$out"
check "the steps run in order" "data-load mcp-setup marketplace" \
    "$(printf '%s\n' "$out" | sed -n 's/^STEP \([a-z-]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//' | sed 's/ mlflow$//')"
contains "the ML Engineer starts its MLflow service" "STEP mlflow action=start tty=" "$out"
contains "one closing line names the whole set" "Persona added: Data Scientist + ML Engineer" "$out"
out="$( (cmd_persona list 2>&1) )"
contains "list says what this kit was set up as, by title" "This kit was set up as: Data Scientist + ML Engineer" "$out"
contains "...and how to add one" "exakit persona add <id>" "$out"
out="$( (exakit_pending_datasets() { :; }; exakit_marketplace_installed_addons() { printf 'notebook\njson-tables\ndash-server\nudf-devkit\n'; }
        cmd_persona plan --json 2>/dev/null) )"
check "plan with no id reports the combined set, nothing pending after the add" "data-scientist,ml-engineer|true" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["persona"] + "|" + str(d["nothing_pending"]).lower())' 2>/dev/null)"
out="$( (exakit_pending_datasets() { :; }; exakit_marketplace_installed_addons() { printf 'notebook\njson-tables\ndash-server\nudf-devkit\n'; }
        cmd_persona add ml-engineer 2>&1); echo "rc=$?")"
contains "added again with everything in: each part says so" "Already loaded: Pharma clinical trials, Banking complaints" "$out"
check "...nothing is loaded or installed (the AI client step says for itself what is connected)" "STEP mcp-setup" \
    "$(printf '%s\n' "$out" | sed -n 's/^\(STEP [a-z-]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//' | sed 's/ STEP mlflow$//')"
contains "...rc 0" "rc=0" "$out"
manifest_set persona.id "general,data-scientist"
out="$(add apply ml-engineer --yes)"
contains "apply is the same command, and --yes is accepted" "rc=0" "$out"
check "...a recorded persona this kit no longer ships is left out" "data-scientist,ml-engineer" "$(manifest_get persona.id)"
manifest_set persona.id ""
out="$(add add data-scientist)"
contains "nothing recorded before: the title line names just the one" "Adding persona: Data Scientist" "$out"
check "...recorded on its own" "data-scientist" "$(manifest_get persona.id)"
manifest_set persona.id data-scientist
out="$( (cmd_data_load() { echo "STEP data-load"; exit 1; }; cmd_persona add ml-engineer 2>&1); echo "rc=$?")"
contains "a step that dies: the command exits 1" "rc=1" "$out"
contains "...the others still run" "STEP marketplace" "$out"
contains "...the closing line says not everything finished" "Persona added: Data Scientist + ML Engineer - not everything finished" "$out"
contains "...and the one command that retries the part" "Sample data did not finish - retry with: EXAKIT_DATASETS=banking_complaints exakit data-load" "$out"
check "...only that part" "" "$(printf '%s\n' "$out" | grep -E '(AI clients|Add-ons) did not finish')"
out="$( (cmd_marketplace() { return 1; }; cmd_persona add ml-engineer 2>&1); echo "rc=$?")"
contains "a failed add-on install names its retry" "Add-ons did not finish - retry with: exakit marketplace udf-devkit" "$out"
manifest_set persona.id ""
out="$( (cmd_persona add data-scientist ml-engineer 2>&1); echo "rc=$?")"
contains "two ids as two words: refused, joined with a comma instead" "exakit persona add data-scientist,ml-engineer" "$out"
check "...and nothing is recorded" "" "$(manifest_get persona.id 2>/dev/null)"
out="$( (cmd_persona add nope 2>&1); echo "rc=$?")"
contains "an unknown persona: refused, naming the ones there are" "available: data-scientist ml-engineer" "$out"
contains "...exit 1" "rc=1" "$out"
out="$( (cmd_persona add ml-engineer --force 2>&1); echo "rc=$?")"
contains "an unknown option: refused" "Unknown option for persona add: --force" "$out"
check "...and nothing is recorded" "" "$(manifest_get persona.id 2>/dev/null)"
out="$( (exakit_repo_root() { printf '%s\n' "$WORK/kit3"; }; cmd_persona add bare 2>&1) )"
contains "a persona without datasets loads none" "No sample data for these personas" "$out"
contains "...nor add-ons" "No add-ons for these personas" "$out"
contains "...nor AI clients" "No AI clients for these personas" "$out"
manifest_set persona.id ""

echo "exakit persona add on a terminal: the installer's tables, with no key pressed:"
# A real pty (tests/lib/tty-replay.py) and no keystroke at all: every table is
# drawn with its defaults and filled in - one of each on screen, at every
# instant (tests/lib/persona-add-scenario.sh).
_pa_loc="$( . "$ROOT/tests/lib/utf8-locale.sh"; printf '%s' "$EXAKIT_TEST_UTF8_LOCALE")"
if ! command -v python3 >/dev/null 2>&1 || [ -z "$_pa_loc" ]; then
    check "python3 and a UTF-8 locale for the pty replay" "skipped" "skipped"
else
    for _pa_title in "Data to load" "AI clients to connect" "Marketplace add-ons"; do
        OUT="$(env LANG="$_pa_loc" LC_ALL="$_pa_loc" python3 "$ROOT/tests/lib/tty-replay.py" \
            "$ROOT/tests/lib/persona-add-scenario.sh" "$ROOT" "$_pa_title" "" 3 2>&1)"
        check "one '$_pa_title' table on screen at every instant, three boxes in all" "0" "$?"
    done
    SCREEN="$(printf '%s\n' "$OUT" | sed -n '/=== FINAL SCREEN ===/,/=== tables on screen/p')"
    contains "the title line"                          "Adding persona: ML Engineer (now Data Scientist + ML Engineer)" "$SCREEN"
    check "the step headings, in order" "Step 1/3  Sample data|Step 2/3  AI clients|Step 3/3  Add-ons" \
        "$(printf '%s\n' "$SCREEN" | grep -o 'Step [0-9]/3  [A-Za-z -]*' | sed 's/ *$//' | tr '\n' '|' | sed 's/|$//')"
    check "each step's table under its own heading" "Step 1/3|Data to load|Step 2/3|AI clients to connect|Step 3/3|Marketplace add-ons" \
        "$(printf '%s\n' "$SCREEN" | grep -o 'Step [0-9]/3\|╭─ [A-Za-z -]*[a-z]' | sed 's/^╭─ //' | tr '\n' '|' | sed 's/|$//')"
    contains "the dataset already in is one line"      "Already loaded: Pharma clinical trials" "$SCREEN"
    contains "the one still to load fills its row"     "└─ Banking complaints   ✓ completed" "$SCREEN"
    contains "Claude, waiting, is configured"          "[✓] ├─ Claude          ✓ configured" "$SCREEN"
    contains "Codex, already connected, says so"       "├─ Codex           already connected" "$SCREEN"
    contains "the add-on already installed is one line" "Already installed: notebook" "$SCREEN"
    contains "the one still missing fills its row"     "└─ udf-devkit  ✓ installed" "$SCREEN"
    contains "one closing line"                        "✓ Persona added: Data Scientist + ML Engineer" "$SCREEN"
    check "no menu hint and no question: nothing waited for a key" "" \
        "$(printf '%s\n' "$OUT" | grep -E 'Space to toggle|\[Y/n\]|\[y/N\]')"
    contains "the exit code"                           "RC=0" "$OUT"
    contains "the personas recorded: both"             "RECORDED=data-scientist,ml-engineer|add" "$OUT"
    contains "only the pending dataset was loaded"     "LOADED=banking_complaints" "$OUT"
    contains "only the waiting client was configured"  "CLIENTS=claude_desktop,claude_code" "$OUT"
    contains "only the missing add-on was installed"   "INSTALLED=udf-devkit" "$OUT"
fi

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
