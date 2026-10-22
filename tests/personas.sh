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
#     General (tpch, energy, weather), AI / Data Scientist (fda_recalls,
#     banking_complaints), ML Engineer (bank_marketing, pharma_trials)
#   - the persona service (setup/lib/persona_service.py) combines several, and
#     the data question ticks their datasets and names who each is for
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
check "the question offers General, AI / Data Scientist, ML Engineer, in that order" "general,data-scientist,ml-engineer" \
    "$(_exakit_persona_service picker | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
check "general: tpch, energy, weather" "tpch,energy,weather" "$(exakit_persona_value general datasets)"
check "data-scientist: the FDA recalls and the banking complaints" "fda_recalls,banking_complaints" "$(exakit_persona_value data-scientist datasets)"
check "data-scientist: notebooks, dashboards, JSON tables" "notebook,dash-server,json-tables" "$(exakit_persona_value data-scientist addons)"
check "ml-engineer: bank marketing and pharma trials" "bank_marketing,pharma_trials" "$(exakit_persona_value ml-engineer datasets)"
check "ml-engineer: notebook and udf-devkit" "notebook,udf-devkit" "$(exakit_persona_value ml-engineer addons)"

echo "a new persona is one file and no code:"
mkdir -p "$WORK/kit2/personas"
cp "$ROOT"/personas/*.json "$WORK/kit2/personas/"
printf '{"schema_version": 1, "id": "analyst", "title": "Analyst", "summary": "SQL on the samples.", "picker": true, "order": 15, "datasets": ["tpch"], "mcp_clients": "all", "addons": ["dash-server"]}\n' \
    > "$WORK/kit2/personas/analyst.json"
check "the question offers it where its order says, unticked" "general|1 analyst|0 data-scientist|0 ml-engineer|0" \
    "$(python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit2" picker | awk -F'|' '{printf "%s%s|%s", (NR>1?" ":""), $1, $4}')"
check "it answers like any other" "EXAKIT_DATASETS=tpch EXAKIT_MARKETPLACE_ADDONS=dash-server" \
    "$(env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE -u EXAKIT_MARKETPLACE_ADDONS python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit2" answers analyst | grep -E '^EXAKIT_(DATASETS|MARKETPLACE_ADDONS)=' | tr '\n' ' ' | sed 's/ $//')"
check "the notebook catalog names only personas the kit ships" "" \
    "$(python3 "$ROOT/notebook/kit/notebooks.py" list "$ROOT" | cut -d'|' -f2 | sort -u | while read -r p; do [ -f "$ROOT/personas/$p.json" ] || printf ' %s' "$p"; done)"

echo "several personas ticked together are combined by the service:"
check "the title names each" "General + ML Engineer" "$(_exakit_persona_service title ml-engineer,general)"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=general,ml-engineer; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "their datasets and add-ons together, each once" "tpch,energy,weather,bank_marketing,pharma_trials|all|notebook,udf-devkit" "$out"
check "each dataset is named with the personas it is for" "fda_recalls|AI / Data Scientist" \
    "$(exakit_persona_dataset_hints | grep '^fda_recalls|')"

echo "the data question: the source first, then the samples with the personas' ticked:"
EXAKIT_TABLE_IDS="
tpch
energy
fda_recalls
banking_complaints
"
check "a persona's datasets are the rows ticked" "4,5" "$(_exakit_data_table_preselect fda_recalls,banking_complaints)"
check "datasets covering every row tick Select All too" "1,2,3,4,5" "$(_exakit_data_table_preselect tpch,energy,fda_recalls,banking_complaints)"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H retail benchmark (~175k rows)\nfda_recalls|FDA recalls (openFDA, ~5k)\n'; }
        EXAKIT_DATASETS_PRESELECT=fda_recalls; EXAKIT_DATA_TABLE_NO_LOCAL=1 exakit_data_table_build "$WORK/table"
        printf '%s~%s~%s' "$EXAKIT_TABLE_DEFAULTS" "$EXAKIT_TABLE_ROW_LOCAL" "$(cut -d'|' -f2 "$WORK/table" | tr '\n' ';')") )"
check "the samples table: the persona's row ticked, no file row, each named for its persona" \
    "3~0~Select All;TPC-H retail benchmark - for General;FDA recalls - for AI / Data Scientist;Skip;" "$out"
out="$( (exakit_pending_datasets() { printf 'tpch|TPC-H\n'; }
        exakit_data_source_select >/dev/null 2>&1; printf '%s' "$EXAKIT_DATA_SOURCE") )"
check "without a terminal the samples are the answer" "sample" "$out"
out="$( (exakit_pending_datasets() { :; }
        exakit_data_source_select >/dev/null 2>&1; printf '%s' "$EXAKIT_DATA_SOURCE") )"
check "with every sample loaded, your own file is the default" "local" "$out"

echo "an explicit answer wins, per variable:"
out="$( (unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
        export EXAKIT_PERSONA=ml-engineer; exakit_persona_apply_env >/dev/null 2>&1
        printf '%s|%s|%s' "$EXAKIT_DATASETS" "$EXAKIT_MCP_CLIENTS" "$EXAKIT_MARKETPLACE_ADDONS") )"
check "the persona answers everything left open" "bank_marketing,pharma_trials|all|notebook,udf-devkit" "$out"
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
out="$( (EXAKIT_PERSONA=general,nope exakit_persona_apply_env) 2>&1)"; rc=$?
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
printf 'junk' > "$WORK/kit3/personas/._general.json"
SVC3() { env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE -u EXAKIT_MARKETPLACE_ADDONS -u EXAKIT_MCP_CLIENTS -u EXAKIT_NOTEBOOK_FRONTENDS \
    python3 "$ROOT/setup/lib/persona_service.py" "$WORK/kit3" "$@"; }
check "the valid ones still answer (a BOM is fine, dotfiles are skipped)" "general data-scientist ml-engineer bare everything" \
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
check "General's empty add-on list answers none" "EXAKIT_MARKETPLACE_ADDONS=none" "$(SVC3 answers general 2>/dev/null | grep '^EXAKIT_MARKETPLACE_ADDONS=')"
check "an EXAKIT_LOAD_SAMPLE the installer does not read is not an answer" "EXAKIT_DATASETS=fda_recalls,banking_complaints" \
    "$(EXAKIT_LOAD_SAMPLE=yes python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" answers data-scientist 2>/dev/null | grep '^EXAKIT_DATASETS=')"
check "one persona where one is meant" "2" "$(python3 "$ROOT/setup/lib/persona_service.py" "$ROOT" value general,ml-engineer title >/dev/null 2>&1; echo $?)"
out="$( (EXAKIT_PERSONA=nope; exakit_persona_known nope; printf '%s' "$EXAKIT_PERSONA_PROBLEM") )"
contains "an unknown persona is named with the ones there are" "Unknown persona 'nope' (available: general data-scientist ml-engineer)" "$out"
out="$( (run_python_any() { return 127; }; exakit_persona_known general; printf '%s' "$EXAKIT_PERSONA_PROBLEM") )"
contains "no Python: says so, not 'unknown persona'" "needs Python 3" "$out"

echo "the install's persona section:"
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
check "a re-run ticks the persona this kit was set up as" "3" "$out"
out="$( (EXAKIT_PERSONA_ACTIVE=1; unset EXAKIT_MARKETPLACE_PRESELECT; exakit_persona_marketplace_note 2>&1) )"
check "no persona offer, no second marketplace pointer" "" "$out"
contains "...after a persona offer, one pointer" "exakit marketplace" \
    "$( (EXAKIT_PERSONA_ACTIVE=1 EXAKIT_MARKETPLACE_PRESELECT=notebook exakit_persona_marketplace_note 2>&1) )"

echo "exakit persona apply:"
sed -n '/^cmd_persona() {/,/^}/p' "$ROOT/setup/exakit" > "$WORK/cmd_persona.sh"
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
out="$( (cmd_persona apply general ml-engineer --yes 2>&1); echo "rc=$?")"
contains "two ids as two words: refused, joined with a comma instead" "exakit persona apply general,ml-engineer" "$out"
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
contains "install.sh: and says which exist" "available: data-scientist general ml-engineer" "$out"
out="$(dry general,ml-engineer)"
contains "install.sh: several personas joined by commas" "Persona: general,ml-engineer" "$out"
out="$(dry general,nope)"
contains "install.sh: one unknown among several is named" "Unknown persona 'nope'" "$out"
for bad in GENERAL ../versions examples/analyst '*' 'general general'; do
    out="$(dry "$bad")"; rc=$?
    check "install.sh: '$bad' is not a persona id" "1" "$rc"
done
out="$(dry ' general , ml-engineer ')"
contains "install.sh: spaces around the ids are fine" "Persona: general,ml-engineer" "$out"
out="$(dry ml-engineer)"
contains "install.sh: a known persona is named in the plan" "Persona: ml-engineer" "$out"
check "install.ps1: the same refusal" "yes" \
    "$(grep -q "throw \"Unknown persona '\$personaId'" "$ROOT/install.ps1" && grep -q '"personas"' "$ROOT/install.ps1" && echo yes || echo no)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
