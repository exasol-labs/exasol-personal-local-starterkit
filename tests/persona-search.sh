#!/usr/bin/env bash
# persona-search.sh - the persona question's search line in the shell menu (the one the
# installer falls back to when the Textual picker cannot start): _ui_fuzzy_score scores every
# case in tests/fuzzy-search-cases.json exactly as fuzzy_score (marketplace/ui.py) and
# Get-ExakitFuzzyScore do, and ui_checkbox_menu with EXAKIT_CHECKBOX_SEARCH=1 types letters into
# the search, points at the closest row, and keeps Space and Enter. bash 3.2 compatible.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0
pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected <$2>, got <$3>"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kit-home"; mkdir -p "$EXAKIT_HOME"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh" 2>/dev/null
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"

echo "the same score as the Python and PowerShell twins:"
python3 - "$ROOT/tests/fuzzy-search-cases.json" > "$WORK/cases" <<'PY'
import json, sys
for case in json.load(open(sys.argv[1], encoding="utf-8"))["cases"]:
    score = "none" if case["score"] is None else str(case["score"])
    print("\x1f".join([case["query"], case["text"], score]))
PY
while IFS="$(printf '\037')" read -r _q _t _want; do
    _have="$(_ui_fuzzy_score "$_q" "$_t")"
    check "'$_q' in '$(printf '%s' "$_t" | cut -c1-14)...'" "$_want" "${_have:-none}"
done < "$WORK/cases"

echo
echo "the menu: letters search, the pointer follows:"
PTY_KIND="none"
if command -v script >/dev/null 2>&1; then
    if script -q /dev/null /bin/echo probe </dev/null >/dev/null 2>&1; then
        PTY_KIND="bsd"
    elif script -q -c "/bin/echo probe" /dev/null </dev/null >/dev/null 2>&1; then
        PTY_KIND="util-linux"
    fi
fi
menu() { # menu <keys command> <search:1|""> <defaults> -> the drawn frames, then "SELECTION=<csv>"
    cat > "$WORK/case.sh" <<EOF
. '$ROOT/setup/lib/ui.sh' 2>/dev/null; ui_detect 2>/dev/null
. '$ROOT/setup/lib/common.sh'
EXAKIT_CHECKBOX_SEARCH='$2' ui_checkbox_menu 'Personas - tick one or more' '$3' \
    'Data Scientist - Explore data' 'ML Engineer - Train models' "General - The kit's own samples"
echo "SELECTION=\$EXAKIT_CHECKBOX_SELECTION"
EOF
    case "$PTY_KIND" in
        bsd)        sh -c "$1; sleep 1" | script -q /dev/null /bin/bash "$WORK/case.sh" 2>&1 ;;
        util-linux) sh -c "$1; sleep 1" | script -q -c "/bin/bash $WORK/case.sh" /dev/null 2>&1 ;;
    esac | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'
}
if [ "$PTY_KIND" = "none" ]; then
    echo "SKIP: no usable script(1); the menu is only drawn on a terminal"
else
    out="$(menu "printf 'ml \\n'" 1 3)"
    case "$out" in *"Search:"*"type to find a persona"*) pass "the first line under the title is the search" ;;
        *) fail "no search line was drawn" ;; esac
    case "$out" in *"Type to search"*) pass "the hint says letters search" ;; *) fail "the hint does not mention the search" ;; esac
    check "typing 'ml' points at ML Engineer, Space ticks it" "SELECTION=2,3" "$(printf '%s\n' "$out" | grep '^SELECTION=' | tail -1)"
    out="$(menu "printf 'qajk\\033'; sleep 2; printf '\\n'" 1 3)"
    check "q, a, j and k are typed, not tick-all or moves; a lone Esc clears" "SELECTION=3" \
        "$(printf '%s\n' "$out" | grep '^SELECTION=' | tail -1)"
    out="$(menu "printf 'gex\\177 \\n'" 1 1)"
    check "Backspace takes the last letter back ('ge' is General)" "SELECTION=1,3" \
        "$(printf '%s\n' "$out" | grep '^SELECTION=' | tail -1)"
    out="$(menu "printf 'a\\n'" '' 3)"
    check "without the search, 'a' still ticks every row" "SELECTION=1,2,3" \
        "$(printf '%s\n' "$out" | grep '^SELECTION=' | tail -1)"
    case "$out" in *"Search:"*) fail "a menu without the search drew a search line" ;; *) pass "only the asked-for menu has a search line" ;; esac
fi

echo
echo "the persona question asks for it on both sides:"
check "persona.sh opens its menu with the search" "1" \
    "$(grep -c 'EXAKIT_CHECKBOX_SEARCH=1' "$ROOT/setup/lib/persona.sh")"
check "persona.ps1 opens its menu with -Search" "1" \
    "$(grep -c 'Read-ExakitCheckboxMenu .*-Search' "$ROOT/setup/lib/persona.ps1")"

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
