#!/usr/bin/env bash
# Guard the group-parent checkbox: a parent row must never claim more than is
# selected.
#
# The checkbox widget's group parent has two modes (see the spec comment on
# _ui_checkbox_apply_group in common.sh): "any" leaves the parent checked while
# ANY child is checked, "all" checks it only while EVERY child is. Every menu
# whose parent row IS the select-all ("Select All", above the add-ons or the
# bundled datasets) must use "all". Under "any" a menu with one of three children
# ticked renders
#
#     [x] Select All
#     [ ] |- dash-server ...
#     [ ] |- exasol-vscode ...
#     [x] `- json-tables ...
#
# and the summary row says "everything" on the exact line a user reads to
# confirm what is about to be installed or loaded.
#
# The spec is a bare string built at the call site, so a refactor can drop the
# 4th field and silently fall back to "any" with nothing failing. This checks
# the behaviour, not just the strings. Run:
#
#   bash tests/checkbox-group.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

# The three pure helpers, lifted out of common.sh so this stays hermetic.
eval "$(sed -n '/^_ui_checkbox_toggle()/,/^}/p;/^_ui_checkbox_group_children()/,/^}/p;/^_ui_checkbox_apply_group()/,/^}/p;/^_ui_checkbox_apply_one_group()/,/^}/p' "$ROOT/setup/lib/common.sh")"

# Rows: 1 = parent, 2..4 = three children, all selectable.
_UI_CHECKBOX_SELECTABLE="2 3 4"

# One keypress: toggle the row, then re-derive the parent. Same order as the
# real loop in ui_checkbox_menu.
press() { _p_s="$(_ui_checkbox_toggle "$1" 4 "$2")"; _ui_checkbox_apply_group "$_p_s" "$2" "$3"; }
parent_on() { case ",$1," in *",1,"*) printf 'checked' ;; *) printf 'unchecked' ;; esac; }

# The mode is taken from a SHIPPED call site, not hardcoded here, so these
# behavioural checks fail when a call site loses its 4th field. A guard that
# asserts a literal ":all" only proves the widget can do it, never that the kit
# asks for it.
#
# Specifically an ":all" spec, not merely the first one. The kit now ships two
# modes -- the add-on group is "all", and EVERYTHING above it is "master", which
# is "all" downward only -- and a plain `head -1` picked up whichever came
# first. When that turned out to be the "master" spec, the case below matched
# neither arm, fell back to "any", and every all-mode assertion here started
# testing the wrong mode: still red, but for the wrong reason.
# Matched anywhere in the assignment rather than anchored at its end: a spec
# may now be one of SEVERAL in the string ("2:3:5:all 6:2:5:master"), so the
# one asking for :all is not necessarily the last thing before the quote.
_live="$(grep -o 'EXAKIT_CHECKBOX_GROUP="[^"]*"' "$ROOT/setup/lib/common.sh" | grep -v '=""' | grep ':all' | head -1)"
case "$_live" in
    *':all'*) _mode="all" ;;
    *)        _mode="" ;;   # no 4th field: the widget falls back to "any"
esac
SPEC="1:2:4${_mode:+:$_mode}"

# 1. A partially selected group must NOT show a checked parent. This is the
#    regression: under "any" both of these report "checked".
_two="$(press "1,2,3,4" 3 "$SPEC")"
if [ "$(parent_on "$_two")" = "unchecked" ]; then
    pass "2 of 3 children ticked leaves the parent unchecked"
else
    fail "2 of 3 children ticked still shows a CHECKED parent - the group spec lost its :all mode, so the summary row overstates the selection"
fi

_one="$(press "$_two" 4 "$SPEC")"
if [ "$(parent_on "$_one")" = "unchecked" ]; then
    pass "1 of 3 children ticked leaves the parent unchecked"
else
    fail "1 of 3 children ticked still shows a CHECKED parent - the group spec lost its :all mode"
fi

# 2. Every child ticked must show a checked parent (the mode must not be so
#    strict that the parent never lights up).
_all_back="$(press "$(press "$_one" 3 "$SPEC")" 4 "$SPEC")"
if [ "$(parent_on "$_all_back")" = "checked" ]; then
    pass "3 of 3 children ticked shows a checked parent"
else
    fail "3 of 3 children ticked does NOT show a checked parent"
fi

# 3. The parent itself stays an all-or-none master toggle.
_cleared="$(press "1,2,3,4" 1 "$SPEC")"
if [ -z "$_cleared" ]; then
    pass "pressing a checked parent clears every child"
else
    fail "pressing a checked parent left rows selected: $_cleared"
fi
_filled="$(press "" 1 "$SPEC")"
if [ "$_filled" = "1,2,3,4" ]; then
    pass "pressing an unchecked parent selects every child"
else
    fail "pressing an unchecked parent did not select all: $_filled"
fi

# 4. Every menu whose parent is a select-all summary must ask for "all". A new
#    grouped menu that forgets the 4th field reintroduces the bug, so the call
#    sites are checked by name rather than only the behaviour above.
while IFS='|' read -r _f _what; do
    [ -n "$_f" ] || continue
    # Two spellings, one invariant: the marketplace still drives ui_checkbox_menu,
    # while the data-load screen drives the live TABLE — whose group spec has the
    # same four fields under the name EXAKIT_TABLE_GROUP.
    _spec="$(grep -oE 'EXAKIT_(CHECKBOX|TABLE)_GROUP="[^"]*"' "$ROOT/$_f" | grep -v '=""' | head -1)"
    case "$_spec" in
        *':all"') pass "$_what uses the all-or-none parent" ;;
        '')       fail "$_what no longer sets a group spec at all - check $_f" ;;
        *)        fail "$_what parent is not all-or-none ($_spec) - append :all, or the summary row overstates the selection" ;;
    esac
done <<EOF
setup/lib/common.sh|the marketplace menu
setup/lib/exapump.sh|the data-load menu
EOF

# 5. PowerShell twins must ask for the same mode (no ASCII/glyph concerns here,
#    purely that the parameter is passed).
for _ps in setup/lib/exakit-common.ps1 setup/lib/exapump.ps1 setup/lib/mcp.ps1; do
    if grep -q 'GroupLast[^)]*)* *-GroupMode "all"' "$ROOT/$_ps"; then
        pass "$_ps passes -GroupMode all"
    else
        fail "$_ps does not pass -GroupMode all - the Windows menu keeps the overstating parent"
    fi
done

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
