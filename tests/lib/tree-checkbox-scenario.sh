#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty from tests/lakehouse-picker.sh:
# ui_checkbox_menu with the tree group modes (collapse, one, first), shipping
# code, the keys from the replay. The last line is the answer: SEL=<csv>.
#
# Rows: 1 Alpha, 2 Lake (collapse+one over 3..9), 3 Cat A (collapse+one+first
# over 4..6: 4 a1, 5 a2, 6 a3 disabled), 7 Cat B (collapse over 8: 8 a note,
# disabled), 9 Cat C, 10 Skip (exclusive).
set -u
ROOT="$1"
W="$(mktemp -d "${TMPDIR:-/tmp}/tree-checkbox.XXXXXX")"
export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"
EXAKIT_CHECKBOX_GROUP="3:4:6:collapse+one+first 7:8:8:collapse 2:3:9:collapse+one"
# TREE_NOGROUP=1: the same rows with no group at all - a menu as every other
# kit menu is, for what ←/→ and the hint do there.
[ "${TREE_NOGROUP:-}" = 1 ] && EXAKIT_CHECKBOX_GROUP=""
EXAKIT_CHECKBOX_EXCLUSIVE=10
ui_checkbox_menu "Pick" "" "Alpha" "Lake" "Cat A" "a1" "a2" "!a3 - not yet" "Cat B" "!note: automatic" "Cat C" "Skip"
printf 'SEL=%s\n' "$EXAKIT_CHECKBOX_SELECTION"
rm -rf "$W"
