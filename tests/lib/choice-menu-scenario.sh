#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty from tests/virtual-schemas.sh:
# _exakit_vs_tui_radio, the arrow-key question a connect choice is asked with
# (the catalog login here), shipping code, the keys from the replay. A line
# before it stays; the question and its rows are erased once answered. The last
# line is the answer: ANS=<value> RC=<code>.
set +u
ROOT="$1"
W="$(mktemp -d "${TMPDIR:-/tmp}/choice-menu.XXXXXX")"
export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"
printf 'BEFORE THE QUESTION\n'
_exakit_vs_tui_radio "How should Exasol login to the catalog?" token "token oauth" \
    "Token|OAuth client" "one access token from the catalog|client ID + secret" 1
_rc=$?
printf 'ANS=%s RC=%s\n' "$_EVT_ANSWER" "$_rc"
rm -rf "$W"
