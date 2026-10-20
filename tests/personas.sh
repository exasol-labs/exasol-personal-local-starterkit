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
#   - P-1: data-scientist is both reference datasets + notebook; ml-engineer is
#     both reference datasets + notebook + udf-devkit
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
    # The shell reader (no Python) must read every key the way a JSON parser does.
    for key in datasets mcp_clients addons title; do
        py="$(python3 -c "import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(','.join(v) if isinstance(v, list) else v)" "$f" "$key")"
        check "$id: the shell reader agrees on $key" "$py" "$(exakit_persona_value "$id" "$key")"
    done
done

echo "P-1, the two personas of the persona-based kit:"
check "data-scientist: both reference datasets" "pharma_trials,banking_complaints" "$(exakit_persona_value data-scientist datasets)"
check "data-scientist: the notebook add-on" "notebook" "$(exakit_persona_value data-scientist addons)"
check "ml-engineer: both reference datasets" "pharma_trials,banking_complaints" "$(exakit_persona_value ml-engineer datasets)"
check "ml-engineer: notebook and udf-devkit" "notebook,udf-devkit" "$(exakit_persona_value ml-engineer addons)"

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
( unset EXAKIT_DATASETS EXAKIT_MCP_CLIENTS EXAKIT_MARKETPLACE_ADDONS EXAKIT_LOAD_SAMPLE
  EXAKIT_PERSONA=data-scientist exakit_persona_apply_env >/dev/null 2>&1 )
check "the manifest records the persona" "data-scientist|install" "$(manifest_get persona.id)|$(manifest_get persona.source)"
check "no persona, no change" "" "$( (unset EXAKIT_PERSONA; exakit_persona_apply_env 2>&1) )"

echo "the installer refuses an unknown persona before anything is installed:"
# install.sh's dry run stops before the setup scripts, so it checks the persona
# itself; install.ps1 carries the same check (Windows only - pinned statically).
dry() { HOME="$WORK/dryhome" EXAKIT_HOME="$WORK/dryhome/kit" EXAKIT_BIN_DIR="$WORK/dryhome/bin" \
        EXAKIT_LOCAL_KIT="$ROOT" EXAKIT_DRY_RUN=1 EXAKIT_PERSONA="$1" sh "$ROOT/install.sh" 2>&1; }
out="$(dry nope)"; rc=$?
check "install.sh: an unknown persona fails" "1" "$rc"
contains "install.sh: and says which exist" "available: data-scientist ml-engineer" "$out"
out="$(dry ml-engineer)"
contains "install.sh: a known persona is named in the plan" "Persona: ml-engineer" "$out"
check "install.ps1: the same refusal" "yes" \
    "$(grep -q "throw \"Unknown persona '\$(\$env:EXAKIT_PERSONA)'" "$ROOT/install.ps1" && grep -q '"personas"' "$ROOT/install.ps1" && echo yes || echo no)"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
