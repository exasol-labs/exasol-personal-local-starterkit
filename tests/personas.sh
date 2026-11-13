#!/usr/bin/env bash
# Persona definitions, environment precedence, and installer data selection.
# Public add/apply/remove coverage lives in test_marketplace_persona_apply.py.

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

echo "the personas the install question offers (the ML Engineer is disabled on this branch, not removed):"
check "the question offers the Data Scientist and General" "data-scientist,general" \
    "$(_exakit_persona_service picker | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
check "ml-engineer: kept, hidden (visible: false)" "False" \
    "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('visible', True))" "$ROOT/personas/ml-engineer.json")"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=ml-engineer; exakit_persona_apply_env 2>&1; printf '|%s' "${EXAKIT_DATASETS:-unset}") )"
contains "ml-engineer: asking for it by name is refused, nothing answered" "Persona 'ml-engineer' is disabled" "$out"
check "no persona: the kit's own samples (default=yes)" "tpch,energy,weather" "$(_exakit_persona_service default-datasets)"
check "data-scientist: the Amazon and fraud datasets" "amazon_sales,fraud_transactions" "$(exakit_persona_value data-scientist datasets)"
check "data-scientist: Dash Server, the notebook, JSON Tables, Semantic Views" "dash-server,notebook,json-tables,semantic-views" "$(exakit_persona_value data-scientist addons)"
check "ml-engineer: the Amazon sales and fraud datasets" "amazon_sales,fraud_transactions" "$(exakit_persona_value ml-engineer datasets)"
check "ml-engineer: BRD notebook and UDF baseline" "notebook,udf-devkit" "$(exakit_persona_value ml-engineer addons)"

echo "a new persona is one file and no code:"
mkdir -p "$WORK/kit2/personas"
cp "$ROOT"/personas/*.json "$WORK/kit2/personas/"
printf '{"schema_version": 1, "id": "analyst", "title": "Analyst", "summary": "SQL on the samples.", "picker": true, "order": 15, "datasets": ["tpch"], "mcp_clients": "all", "addons": ["dash-server"]}\n' \
    > "$WORK/kit2/personas/analyst.json"
check "the question offers it where its order says, unticked" "data-scientist|0 analyst|0 general|1" \
    "$(python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit2" picker | awk -F'|' '{printf "%s%s|%s", (NR>1?" ":""), $1, $4}')"
check "it answers like any other" "EXAKIT_DATASETS=tpch EXAKIT_MARKETPLACE_ADDONS=dash-server" \
    "$(env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE -u EXAKIT_MARKETPLACE_ADDONS python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit2" answers analyst | grep -E '^EXAKIT_(DATASETS|MARKETPLACE_ADDONS)=' | tr '\n' ' ' | sed 's/ $//')"
check "the notebook catalog names only personas the kit ships" "" \
    "$(python3 "$ROOT/notebook/kit/notebooks.py" list "$ROOT" | cut -d'|' -f2 | sort -u | while read -r p; do [ -f "$ROOT/personas/$p.json" ] || printf ' %s' "$p"; done)"

echo "several personas ticked together are combined by the service:"
check "the title names each" "Data Scientist + General" "$(_exakit_persona_service title general,data-scientist)"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=data-scientist,general; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "their datasets and add-ons together, each once" "amazon_sales,fraud_transactions,tpch,energy,weather|all|dash-server,notebook,json-tables,semantic-views" "$out"
check "each dataset is named with the personas it is for (a hidden one is not named)" "amazon_sales|Data Scientist" \
    "$(exakit_persona_dataset_hints | grep '^amazon_sales|')"

echo "the data question: one table, the personas' datasets ticked:"
# The ids as _exakit_data_table_preselect sees them: the parent and the
# datasets (the table builder asks before the file, external and Skip rows).
EXAKIT_TABLE_IDS="
tpch
energy
amazon_sales
fraud_transactions
"
check "a persona's datasets are the rows ticked" "4,5" "$(_exakit_data_table_preselect amazon_sales,fraud_transactions)"
check "datasets covering every dataset row tick the Sample datasets parent too" "1,2,3,4,5" "$(_exakit_data_table_preselect tpch,energy,amazon_sales,fraud_transactions)"
check "a persona that wants none ticks nothing (the table then ticks Skip)" "" "$(_exakit_data_table_preselect none)"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\namazon_sales|Amazon sales (Amazon.in fashion orders, Apr-Jun 2022, ~129k lines)\n'; }
        EXAKIT_DATASETS_PRESELECT=amazon_sales; exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_ROW_LOCAL" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')" \
            "$(cut -d'|' -f11 "$WORK/table" | tr '\n' ';')") )"
check "the persona's row ticked, the file and external rows after the datasets, each described in the Description column" \
    "3~4~Sample datasets;TPC-H retail benchmark;Amazon sales;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - unavailable;Skip;~;Orders, customers, parts;Online orders;;;;" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\namazon_sales|Amazon sales (Amazon.in fashion orders, Apr-Jun 2022, ~129k lines)\n'; }
        EXAKIT_PERSONA_ACTIVE=1 EXAKIT_DATASETS_PRESELECT=amazon_sales; exakit_data_table_build "$WORK/table"
        printf '%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')") )"
check "a persona picked: every sample listed, only its own ticked, then upload, external and Skip" \
    "3~Sample datasets;TPC-H retail benchmark;Amazon sales;Upload a file or folder: CSV/Parquet/JSON;Connect an external source - unavailable;Skip;" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }; _exakit_prompt_tty() { :; }
        exakit_data_load_select Skip >/dev/null 2>&1; printf '%s' "$EXAKIT_DATA_LOAD_SELECTION") )"
check "without a terminal the pending samples are the answer" "tpch" "$out"
out="$( (exakit_pending_datasets() { :; }; _exakit_prompt_tty() { :; }
        exakit_data_load_select Skip >/dev/null 2>&1; printf '%s' "$EXAKIT_DATA_LOAD_SELECTION") )"
# The file row is the default, but its path question needs a person: without a
# terminal the answer is none (and the EXAKIT_DATA_FILE hint), Enter gives local.
check "with every sample loaded and nobody at the table, the answer is none" "none" "$out"
out="$( (exakit_pending_datasets() { :; }
        ui_table_menu() { EXAKIT_TABLE_SELECTION="$EXAKIT_TABLE_DEFAULTS"; EXAKIT_TABLE_CONFIRMED=1; }
        exakit_data_load_select Skip >/dev/null 2>&1; printf '%s' "$EXAKIT_DATA_LOAD_SELECTION") )"
check "with every sample loaded, your own file is the default Enter takes" "local" "$out"

echo "an explicit answer wins, per variable:"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=data-scientist; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "the persona answers everything left open" "amazon_sales,fraud_transactions|all|dash-server,notebook,json-tables,semantic-views" "$out"
out="$( (unset EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_DATASETS=amazon_sales EXAKIT_PERSONA=data-scientist; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "EXAKIT_DATASETS wins, the rest stays the persona's" "amazon_sales|all|dash-server,notebook,json-tables,semantic-views" "$out"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS
        export EXAKIT_LOAD_SAMPLE=0 EXAKIT_MARKETPLACE_ADDONS=none EXAKIT_PERSONA=data-scientist; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "${EXAKIT_DATASETS:-unset}" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "EXAKIT_LOAD_SAMPLE=0 and add-ons none win" "unset|all|none" "$out"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_SKIP_MCP=1 EXAKIT_PERSONA=data-scientist; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s' "${EXAKIT_MCP_CLIENTS:-unset}") )"
check "EXAKIT_SKIP_MCP=1 wins over the persona's clients" "unset" "$out"

echo "a persona and a file of your own: both load, the file after the datasets:"
# EXAKIT_PERSONA answers through EXAKIT_DATASETS, and that answer used to
# return before EXAKIT_DATA_FILE was looked at: the file was dropped without a
# word. The real persona answers and the real installer step; the loaders are
# stubs that say what they were asked to load.
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=data-scientist EXAKIT_DATA_FILE="$WORK/mine.csv"
        exakit_persona_apply_env >/dev/null 2>&1
        exakit_load_dataset() { printf 'LOAD %s\n' "$2"; }
        exakit_load_local_file() { printf 'FILE %s\n' "$EXAKIT_DATA_FILE"; }
        exakit_maybe_offer_data_load "$ROOT" </dev/null 2>&1 | grep -E '^(LOAD|FILE) ' | tr '\n' ';') )"
check "EXAKIT_PERSONA plus EXAKIT_DATA_FILE: the persona's datasets, then the file" \
    "LOAD amazon_sales;LOAD fraud_transactions;FILE $WORK/mine.csv;" "$out"
# The persona picked at the install's question (EXAKIT_PERSONA_ACTIVE, its
# datasets in EXAKIT_DATASETS_PRESELECT): a file named in the environment skips
# the table, and the persona's datasets still to load are loaded before it.
sel() { # sel — the data question's answer with a file named, no terminal
    (
        exakit_pending_datasets() { printf 'tpch|TPC-H\namazon_sales|Amazon sales\nfraud_transactions|Fraud\n'; }
        EXAKIT_DATA_FILE="$WORK/mine.csv" exakit_data_load_select Skip </dev/null >/dev/null 2>&1
        printf '%s' "$EXAKIT_DATA_LOAD_SELECTION"
    )
}
check "a persona picked at the question, and a file: its datasets, then the file" "amazon_sales,fraud_transactions,local" \
    "$(EXAKIT_PERSONA_ACTIVE=1 EXAKIT_DATASETS_PRESELECT=amazon_sales,fraud_transactions sel)"
check "...only the ones still to load" "amazon_sales,local" \
    "$(EXAKIT_PERSONA_ACTIVE=1 EXAKIT_DATASETS_PRESELECT=amazon_sales,weather sel)"
check "a persona that wants no samples, and a file: the file" "local" "$(EXAKIT_PERSONA_ACTIVE=1 EXAKIT_DATASETS_PRESELECT=none sel)"
check "no persona, and a file: the file, as always" "local" "$(EXAKIT_DATASETS_PRESELECT=tpch sel)"

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
check "the valid ones still answer (a BOM is fine, dotfiles are skipped)" "data-scientist general bare everything" \
    "$(SVC3 ids 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
check "each broken file is named with what is wrong" "broken.json inj.json pipe.json" \
    "$(SVC3 problems | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
contains "a title with | is refused" "'title' must be one line without '|'" "$(SVC3 problems)"
contains "a list item that is not an id is refused" "which is not an id" "$(SVC3 problems)"
contains "naming a broken persona says what is wrong with its file" "personas/pipe.json is invalid" "$(SVC3 check pipe 2>&1)"

echo "a persona says what each of its add-ons does for it (NEW-10):"
check "the personas' own lines, first persona first" \
    "dash-server|Share what you find as a live dashboard others open in a browser;notebook|The Data Scientist notebooks, already connected to your data;json-tables|Load JSON files and folders as tables, nested data included;semantic-views|The semantic layer your column maps publish to, queried by notebooks and AI clients;udf-devkit|Train and score models inside the database, runs kept in MLflow" \
    "$(python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" addon-reasons data-scientist,ml-engineer | tr '\n' ';' | sed 's/;$//')"
check "a persona without them gives none" "" "$(python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" addon-reasons general)"
mkdir -p "$WORK/kit4/personas"; ln -s "$ROOT/data" "$WORK/kit4/data"; ln -s "$ROOT/setup" "$WORK/kit4/setup"
printf '{"id":"why","title":"Why","summary":"x","addons":["notebook"],"addon_reasons":{"dash-server":"not listed","notebook":"a | b"}}' > "$WORK/kit4/personas/why.json"
_why="$(python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit4" problems)"
contains "a reason for an add-on the persona does not list is refused" "names 'dash-server', which is not in its 'addons'" "$_why"
contains "a reason with | is refused" "for 'notebook' must be one line" "$_why"
check "offered for a persona, a row shows the persona's line" "Train and score models" \
    "$(EXAKIT_MARKETPLACE_REASONS="$(printf 'notebook|N\nudf-devkit|Train and score models')" exakit_marketplace_addon_description udf-devkit)"
_outside="$(unset EXAKIT_MARKETPLACE_REASONS; exakit_marketplace_addon_description udf-devkit)"
_shows=no
case "$_outside" in *"Train and score models"*) _shows=yes ;; esac
check "...and outside one, never" "no" "$_shows"
check "datasets \"all\" become the kit's dataset ids (EXAKIT_DATASETS takes ids)" \
    "EXAKIT_DATASETS=$(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')" "$(SVC3 answers everything 2>/dev/null | grep '^EXAKIT_DATASETS=')"
check "[] answers the nothing-word for each key" "EXAKIT_LOAD_SAMPLE=0 EXAKIT_MCP_CLIENTS=skip EXAKIT_MARKETPLACE_ADDONS=none" \
    "$(SVC3 answers bare 2>/dev/null | grep -v '^EXAKIT_PERSONA=' | tr '\n' ' ' | sed 's/ $//')"
check "an empty add-on list answers none" "EXAKIT_MARKETPLACE_ADDONS=none" "$(SVC3 answers bare 2>/dev/null | grep '^EXAKIT_MARKETPLACE_ADDONS=')"
check "an EXAKIT_LOAD_SAMPLE the installer does not read is not an answer" "EXAKIT_DATASETS=amazon_sales,fraud_transactions" \
    "$(EXAKIT_LOAD_SAMPLE=yes python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" answers data-scientist 2>/dev/null | grep '^EXAKIT_DATASETS=')"
check "one persona where one is meant" "2" "$(python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" value data-scientist,ml-engineer title >/dev/null 2>&1; echo $?)"
out="$( (EXAKIT_PERSONA=nope; exakit_persona_known nope; printf '%s' "$EXAKIT_PERSONA_PROBLEM") )"
contains "an unknown persona is named with the ones there are" "Unknown persona 'nope' (available: data-scientist general)" "$out"
out="$( (run_python_any() { return 127; }; exakit_persona_known data-scientist; printf '%s' "$EXAKIT_PERSONA_PROBLEM") )"
contains "no Python: says so, not 'unknown persona'" "needs Python 3" "$out"

echo "the install's persona section:"
out="$( (manifest_set persona.id ""
        ui_checkbox_menu() { shift; printf '%s|%s|%s' "$1" "${EXAKIT_CHECKBOX_EXCLUSIVE:-}" "$(eval echo \"\${$#}\")" > "$WORK/q"; EXAKIT_CHECKBOX_SELECTION="2"; }
        exakit_persona_question >/dev/null 2>&1; printf '%s~%s' "$(cat "$WORK/q")" "${EXAKIT_PERSONA:-}") )"
check "the question ends with General, ticked to begin with, combinable (no exclusive row)" \
    "2||General - Sample data (retail, energy, weather) and your AI clients.~general" "$out"
out="$( (unset EXAKIT_PERSONA EXAKIT_DATASETS EXAKIT_LOAD_SAMPLE EXAKIT_DATASETS_PRESELECT EXAKIT_MARKETPLACE_PRESELECT
        exakit_persona_data() { :; }; exakit_persona_flow "$ROOT" </dev/null >/dev/null 2>&1
        printf '%s|%s|%s' "${EXAKIT_DATASETS_PRESELECT:-}" "${EXAKIT_MARKETPLACE_PRESELECT:-}" "${EXAKIT_PERSONA:-}") )"
check "no terminal, no persona: the default personas' datasets, nothing recorded" "tpch,energy,weather||" "$out"
out="$( (unset EXAKIT_DATASETS_PRESELECT EXAKIT_MARKETPLACE_PRESELECT; exakit_persona_data() { :; }
        export EXAKIT_PERSONA=bare; exakit_persona_flow "$WORK/kit3" selected >/dev/null 2>&1; printf '%s|%s' "${EXAKIT_DATASETS_PRESELECT:-}" "${EXAKIT_MARKETPLACE_PRESELECT:-}") )"
check "a persona with no datasets ticks none (and offers no add-ons)" "none|" "$out"
out="$( (unset EXAKIT_DATASETS_PRESELECT EXAKIT_MARKETPLACE_PRESELECT; exakit_persona_data() { :; }
        export EXAKIT_PERSONA=everything; exakit_persona_flow "$WORK/kit3" selected >/dev/null 2>&1; printf '%s' "${EXAKIT_MARKETPLACE_PRESELECT:-}") )"
check "a persona with every add-on offers all" "all" "$out"
out="$( (exakit_soft_failed() { [ "$1" = exapump ]; }; exakit_persona_question() { echo ASKED; }
        exakit_persona_data() { echo DATA; }; _exakit_prompt_tty() { echo /dev/tty; }; UI_FANCY=1; unset EXAKIT_PERSONA
        exakit_persona_flow "$ROOT" 2>"$WORK/flow.stderr") )"
check "exapump missing: nobody is asked, the data step says why" "DATA" "$out"
out="$( (_exakit_prompt_tty() { echo /dev/tty; }; UI_FANCY=1; unset EXAKIT_PERSONA; exakit_persona_question() { echo ASKED; }
        exakit_persona_data() { :; }; EXAKIT_DATASETS=tpch EXAKIT_MARKETPLACE_ADDONS=none exakit_persona_flow "$ROOT" 2>"$WORK/flow.stderr") )"
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
out="$( (exakit_pending_datasets() { printf 'fraud_transactions|Fraud transactions\n'; }; exakit_marketplace_installed_addons() { printf 'notebook\njson-tables\ndash-server\n'; }
        exakit_persona_plan ml-engineer 0 2>&1) )"
contains "what is loaded and what is pending" "loaded: amazon_sales   pending: fraud_transactions" "$out"
contains "...add-ons the same way" "installed: notebook   pending: udf-devkit" "$out"
contains "...and, for a persona not offered, that it cannot be added (audit AGX-03)" "is not offered in this release, so it cannot be added" "$out"
lacks "...never naming the refused command" "exakit persona add ml-engineer" "$out"
out="$( (exakit_pending_datasets() { :; }; exakit_marketplace_installed_addons() { printf 'notebook\njson-tables\ndash-server\nudf-devkit\n'; }
        exakit_persona_plan ml-engineer 1 2>/dev/null) )"
check "--json after a complete install: nothing pending" "true" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d["nothing_pending"]).lower() if not d["datasets"]["pending"] and not d["addons"]["pending"] else "pending")' 2>/dev/null)"

echo "the installer refuses an unknown persona before anything is installed:"
# install.sh's dry run stops before the setup scripts, so it checks the persona
# itself; install.ps1 carries the same check (Windows only - pinned statically).
dry() { HOME="$WORK/dryhome" EXAKIT_HOME="$WORK/dryhome/kit" EXAKIT_BIN_DIR="$WORK/dryhome/bin" \
        EXAKIT_LOCAL_KIT="$ROOT" EXAKIT_DRY_RUN=1 EXAKIT_PERSONA="$1" sh "$ROOT/install.sh" 2>&1; }
out="$(dry nope)"; rc=$?
check "install.sh: an unknown persona fails" "1" "$rc"
contains "install.sh: and says which exist" "available: data-scientist general ml-engineer" "$out"
out="$(dry data-scientist,ml-engineer)"
contains "install.sh: several personas joined by commas" "Persona: data-scientist,ml-engineer" "$out"
out="$(dry data-scientist,nope)"
contains "install.sh: one unknown among several is named" "Unknown persona 'nope'" "$out"
for bad in ML-ENGINEER ../versions examples/analyst '*' 'ml-engineer ml-engineer' analyst; do
    out="$(dry "$bad")"; rc=$?
    check "install.sh: '$bad' is not a persona id" "1" "$rc"
done
out="$(dry ' data-scientist , ml-engineer ')"
contains "install.sh: spaces around the ids are fine" "Persona: data-scientist,ml-engineer" "$out"
echo "the dry run shows the plan, not only the banner (audit MAC-07):"
out="$(dry ml-engineer)"
contains "install.sh: the steps" "1 Exasol launcher, 2 the local database" "$out"
contains "install.sh: seven steps, the database features fourth" "3 exapump, 4 database features," "$out"
contains "...and the exakit command last, after the persona's data" "6 pyexasol, then your persona's data, 7 the exakit command" "$out"
contains "install.sh: the persona's add-ons" "notebook,udf-devkit (the persona's)" "$out"
out="$(EXAKIT_DATASETS=tpch dry ml-engineer)"
contains "install.sh: an answer you set is yours, and wins" "tpch (yours)" "$out"
out="$(dry '')"
contains "install.sh: no persona, no answers: what happens to the choices" "asked on a terminal" "$out"
out="$(dry ml-engineer)"
contains "install.sh: a known persona is named in the plan" "Persona: ml-engineer" "$out"
check "install.ps1: the same refusal" "yes" \
    "$(grep -q "throw \"Unknown persona '\$personaId'" "$ROOT/install.ps1" && grep -q '"personas"' "$ROOT/install.ps1" && echo yes || echo no)"

echo "the personas' add-ons install under the install lock (no second setup run beside them):"
for _os in macos linux; do
    check "setup-$_os.sh takes the lock again before the add-on offer and releases it after" "acquire offer release" \
        "$(awk '/^if \[ -n "\$\{EXAKIT_PERSONA_ACTIVE:-\}" \]/{p=1} p&&/exakit_acquire_lock/{printf "acquire "} p&&/exakit_marketplace_offer \)/{printf "offer "} p&&/exakit_release_lock/{printf "release"; exit}' "$ROOT/setup/setup-$_os.sh")"
done

echo "exakit persona add with no id: the persona question, then the newly ticked:"
check "only the ones the kit was not set up as are added" "ml-engineer,general" \
    "$(_exakit_persona_newly_ticked "data-scientist" "data-scientist,ml-engineer,general")"
check "nothing new ticked adds nothing" "" "$(_exakit_persona_newly_ticked "data-scientist,general" "general")"
out="$(exakit_persona_add_menu </dev/null 2>&1)"; rc=$?
named=no; case "$out" in *"exakit persona add <id>"*) named=yes ;; esac
check "without a terminal it names the command and exits 2" "2|yes" "$rc|$named"
check "the dispatcher sends a bare add to the menu" "1" \
    "$(grep -c 'if \[ "\$1" = add \] && \[ \$# -eq 1 \]; then exakit_persona_add_menu' "$ROOT/setup/exakit")"

echo "the persona command's answers for scripts (audit AGT-05/06/07/09/12):"
_bare="$WORK/bare"; mkdir -p "$_bare/home"
_cli() { HOME="$_bare/home" EXAKIT_HOME="$_bare/home/.exasol-starter-kit" EXAKIT_BIN_DIR="$_bare/bin" \
    EXAKIT_NO_UPDATE_NOTICE=1 bash "$ROOT/setup/exakit" "$@" 2>/dev/null; printf '|rc=%s' "$?"; }
_json() { python3 -c 'import json,sys; d=json.loads(sys.stdin.read().rsplit("|rc=",1)[0]); print(eval(sys.argv[1]))' "$1"; }
out="$(_cli persona list --json)"
contains "persona list --json exits 0" "|rc=0" "$out"
check "...and lists every persona it offers" "data-scientist,general" "$(printf '%s' "$out" | _json '",".join(p["id"] for p in d["personas"])')"
out="$(_cli persona show ml-engineer --json)"
check "persona show --json names the notebooks it brings, in order" \
    "ml-engineer/00_quickstart.ipynb,ml-engineer/01_train.ipynb,ml-engineer/02_rust_score.ipynb,ml-engineer/03_score_external_model.ipynb" \
    "$(printf '%s' "$out" | _json '",".join(n["jupyter"] for n in d["notebooks"])')"
out="$(_cli persona show nope --json)"
contains "an unknown persona is bad input: exit 2" "|rc=2" "$out"
check "...one refusal object on stdout" "True" "$(printf '%s' "$out" | _json 'd["rejected"]')"
out="$(_cli persona plan --json)"
contains "plan with no persona recorded is bad input: exit 2" "|rc=2" "$out"
check "...and records no failure" "no" "$([ -e "$_bare/home/.exasol-starter-kit/.last-failure" ] && echo yes || echo no)"
out="$(_cli marketplace --list --json)"
contains "marketplace with no kit exits 4, as every state query does" "|rc=4" "$out"
check "...with the installer's command" "False" "$(printf '%s' "$out" | _json 'd["installed"]')"
out="$(_cli persona add data-scientist --json)"
contains "persona add with no kit exits 4" "|rc=4" "$out"
check "...having downloaded nothing and edited no shell profile" "0" "$(find "$_bare/home" -type f | wc -l | tr -d ' ')"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
