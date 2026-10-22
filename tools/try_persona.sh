#!/usr/bin/env bash
# try_persona.sh — try a persona file before adding it to the kit, in a sandbox:
# a copy of this kit with the file dropped into its personas/, a throwaway kit
# home, nothing installed, this checkout and your installed kit left untouched.
#
#   bash tools/try_persona.sh personas/examples/analyst.json          # the checks
#   bash tools/try_persona.sh personas/examples/analyst.json --ask    # ...then the install question, live
#
# It shows what the installer will do with the file: the checks tests/personas.sh
# runs on every persona (valid id, known datasets and add-ons, no secrets), where
# the install question lists it, what `exakit persona show` prints, the answers it
# fills in alone and with General, how the sample-data table names and ticks its
# datasets, and the installer's dry run with EXAKIT_PERSONA=<id>. With --ask it
# then draws "What will you use this machine for?" in this terminal (arrows,
# Space, Enter) and prints what was picked.
#
# Happy with it? Copy the file to personas/<id>.json; personas/README.md has the
# rest (the docs row, the two test lines that list the personas).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="${1:-}"
ASK=0
[ "${2:-}" = "--ask" ] && ASK=1
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    printf 'usage: bash tools/try_persona.sh <persona.json> [--ask]\n' >&2
    exit 2
fi
FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

PASS=0; FAIL=0
# Not ok/bad: common.sh, sourced below, has an ok of its own.
t_ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
t_bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
step() { printf '\n== %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KIT="$WORK/kit-copy"

step "the file"
ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$FILE" 2>/dev/null)"
if [ -z "$ID" ]; then
    t_bad "not valid JSON, or no \"id\" - nothing else can be checked"
    exit 1
fi
# The id names the file the sandbox writes: anything but a plain id stops here,
# before a path like ../setup/help/exakit could reach a real file.
if printf '%s' "$ID" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
    t_ok "valid JSON, id '$ID'"
else
    t_bad "the id '$ID' must be lowercase letters, digits, - and _ (starting with a letter or digit)"
    exit 1
fi
if [ -f "$ROOT/personas/$ID.json" ] && ! cmp -s "$FILE" "$ROOT/personas/$ID.json"; then
    printf '  note  personas/%s.json already exists: the sandbox uses your file in its place\n' "$ID"
fi

# The sandbox: this kit through symlinks (nothing copied), with a personas/
# folder of its own - the kit's personas plus the file as personas/<id>.json.
mkdir -p "$KIT/personas"
for _entry in "$ROOT"/* "$ROOT"/.[!.]*; do
    case "$(basename "$_entry")" in personas|.git|'.[!.]*') continue ;; esac
    ln -s "$_entry" "$KIT/$(basename "$_entry")"
done
for _p in "$ROOT"/personas/*; do ln -s "$_p" "$KIT/personas/$(basename "$_p")"; done
rm -f "$KIT/personas/$ID.json"
cp "$FILE" "$KIT/personas/$ID.json"
export HOME="$WORK/home" EXAKIT_HOME="$WORK/kithome" EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$HOME" "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
# shellcheck disable=SC1091
. "$KIT/setup/lib/ui.sh"; . "$KIT/setup/lib/common.sh"; . "$KIT/setup/lib/exapump.sh"; . "$KIT/setup/lib/persona.sh"
EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
manifest_init >/dev/null 2>&1
SERVICE() { python3 "$KIT/setup/lib/persona_service.py" "$KIT" "$@"; }
# The persona service runs on any Python 3.9+: no need for the kit's managed
# Python, which an empty sandbox home would download first.
run_python_any() { python3 "$@"; }

step "what tests/personas.sh will check"
_problem="$(SERVICE problems 2>/dev/null | sed -n "s/^$ID\.json|//p")"
if [ -n "$_problem" ]; then
    t_bad "the persona service refuses it: $_problem"
    printf '\n%d ok, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
if out="$(SERVICE check "$ID" 2>&1)"; then t_ok "the persona service reads it"; else t_bad "the persona service refuses it: $out"; fi
for key in title summary; do
    [ -n "$(SERVICE value "$ID" "$key" 2>/dev/null)" ] && t_ok "has a $key" || t_bad "no \"$key\""
done
DATASETS=" $(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ' ') "
ADDONS=" $(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ') "
ds="$(SERVICE value "$ID" datasets 2>/dev/null)"
case "$ds" in
    all|none|"") t_ok "datasets: ${ds:-none}" ;;
    *) for d in $(printf '%s' "$ds" | tr ',' ' '); do
           case "$DATASETS" in *" $d "*) t_ok "dataset '$d' is bundled" ;; *) t_bad "dataset '$d' is not in data/datasets/ (there are:$DATASETS)" ;; esac
       done ;;
esac
ad="$(SERVICE value "$ID" addons 2>/dev/null)"
case "$ad" in
    all|none|"") t_ok "add-ons: ${ad:-none}" ;;
    *) for a in $(printf '%s' "$ad" | tr ',' ' '); do
           case "$ADDONS" in *" $a "*) t_ok "add-on '$a' is in the marketplace" ;; *) t_bad "add-on '$a' is not a marketplace id (there are:$ADDONS)" ;; esac
       done ;;
esac
if grep -qiE 'password|secret|token|/Users/|/home/|C:\\\\|EXAKIT_HOME' "$FILE"; then
    t_bad "it holds a secret or a machine path - a persona names things, it never holds them"
else
    t_ok "no secret and no machine path"
fi

step "the install question lists it (\"What will you use this machine for?\")"
if [ "$(SERVICE value "$ID" picker 2>/dev/null)" != "True" ]; then
    printf '  note  "picker" is not true: the question does not offer it; EXAKIT_PERSONA=%s still works\n' "$ID"
fi
SERVICE picker 2>/dev/null | while IFS='|' read -r pid ptitle _ pdefault; do
    mark="[ ]"; [ "$pdefault" = 1 ] && mark="[x]"
    new=""; [ "$pid" = "$ID" ] && new="   <- your persona"
    printf '        %s %s%s\n' "$mark" "$ptitle" "$new"
done

step "exakit persona show $ID"
SERVICE show "$ID" 2>/dev/null | sed 's/^/        /'

step "what it answers (EXAKIT_PERSONA=$ID)"
env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE -u EXAKIT_MCP_CLIENTS -u EXAKIT_MARKETPLACE_ADDONS -u EXAKIT_NOTEBOOK_FRONTENDS \
    python3 "$KIT/setup/lib/persona_service.py" "$KIT" answers "$ID" 2>/dev/null | sed 's/^/        /'
printf '   ...with General too (EXAKIT_PERSONA=general,%s):\n' "$ID"
env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE -u EXAKIT_MCP_CLIENTS -u EXAKIT_MARKETPLACE_ADDONS -u EXAKIT_NOTEBOOK_FRONTENDS \
    python3 "$KIT/setup/lib/persona_service.py" "$KIT" answers "general,$ID" 2>/dev/null | sed 's/^/        /'

step "the sample-data table, picked on screen"
title="$(SERVICE title "$ID" 2>/dev/null)"
(
    exakit_pending_datasets() { exakit_bundled_datasets | cut -d'|' -f1,2; }   # a new machine: nothing loaded yet
    _ans="$(env -u EXAKIT_DATASETS -u EXAKIT_LOAD_SAMPLE python3 "$KIT/setup/lib/persona_service.py" "$KIT" answers "$ID" 2>/dev/null)"
    EXAKIT_DATASETS_PRESELECT="$(printf '%s\n' "$_ans" | sed -n 's/^EXAKIT_DATASETS=//p')"
    [ "$EXAKIT_DATASETS_PRESELECT" = all ] && EXAKIT_DATASETS_PRESELECT="$(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ',' | sed 's/,$//')"
    EXAKIT_DATA_TABLE_NO_LOCAL=1 exakit_data_table_build "$WORK/table" >/dev/null 2>&1
    n=0
    while IFS='|' read -r _ label _; do
        n=$((n + 1))
        case ",$EXAKIT_TABLE_DEFAULTS," in *",$n,"*) mark="[x]" ;; *) mark="[ ]" ;; esac
        printf '        %s %s\n' "$mark" "$label"
    done < "$WORK/table"
)
[ -n "$title" ] && printf '        (rows naming "%s" are the ones it is for)\n' "$title"

step "the installer's dry run (EXAKIT_PERSONA=$ID, nothing installed)"
out="$(HOME="$WORK/dryhome" EXAKIT_HOME="$WORK/dryhome/kit" EXAKIT_BIN_DIR="$WORK/dryhome/bin" \
    EXAKIT_LOCAL_KIT="$KIT" EXAKIT_DRY_RUN=1 EXAKIT_PERSONA="$ID" sh "$KIT/install.sh" 2>&1)"
case "$out" in
    *"Persona: $ID"*) t_ok "install.sh accepts it: Persona: $ID" ;;
    *) t_bad "install.sh did not take it:"; printf '%s\n' "$out" | tail -5 | sed 's/^/        /' ;;
esac

printf '\n%d ok, %d failed\n' "$PASS" "$FAIL"

if [ "$ASK" = 1 ]; then
    if [ -z "$(_exakit_prompt_tty)" ]; then
        printf '\n--ask needs a terminal: run it in Terminal or iTerm.\n'
    else
        step "the install question, live (arrows to move, Space to tick, Enter to confirm)"
        UI_FANCY=1
        unset EXAKIT_PERSONA
        exakit_persona_question
        printf '\n  You picked: EXAKIT_PERSONA=%s\n' "${EXAKIT_PERSONA:-}"
    fi
fi

if [ "$FAIL" -eq 0 ]; then
    printf '\nTo add it to the kit: cp %s personas/%s.json  (then personas/README.md, "Adding a persona")\n' "$1" "$ID"
fi
[ "$FAIL" -eq 0 ]
