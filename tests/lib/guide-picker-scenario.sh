#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty from tests/lakehouse-picker.sh:
# the connector guides inside exakit connect, shipping code throughout.
#   GUIDE_MODE=picker (default)  `exakit connect --help` at a terminal: the
#                                guide picker (exakit_vs_guide_picker);
#   GUIDE_MODE=menu              the connect menu (_exakit_vs_pick) with its
#                                catalog stubbed, where ? shows a row's guide;
#   GUIDE_MODE=exakit            setup/exakit connect --help itself.
# o opens the guide through a stand-in `open` / `xdg-open` first on PATH: it
# records the path it was given and opens nothing. The last lines are the
# answer:
#   OPEN <path>                  (one per o)
#   GUIDES RC=<rc> CONNECT=<id>  (picker)
#   PICKED=<ids> RC=<rc>         (menu)
set -u
ROOT="$1"
W="$(mktemp -d "${TMPDIR:-/tmp}/guide-picker.XXXXXX")"
export HOME="$W/home"; mkdir -p "$HOME"
EXAKIT_HOME="$W/kit"; EXAKIT_BIN_DIR="$W/bin"; mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
mkdir -p "$W/opener"
for _o in open xdg-open; do
    printf '#!/bin/sh\nprintf "OPEN %%s\\n" "$1" >> "%s"\n' "$W/opened" > "$W/opener/$_o"
    [ -n "${GUIDE_OPEN_FAILS:-}" ] && printf 'exit 1\n' >> "$W/opener/$_o"
    chmod +x "$W/opener/$_o"
done
PATH="$W/opener:$PATH"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"

case "${GUIDE_MODE:-picker}" in
    exakit)
        # The shipped command, as typed: `exakit connect --help`, nothing
        # installed. c runs `exakit connect <id>`, which says the kit is not
        # installed here - the same answer typing it gives.
        bash "$ROOT/setup/exakit" connect --help
        printf 'EXAKIT RC=%s\n' "$?" ;;
    picker)
        exakit_vs_guide_picker
        rc=$?
        [ -f "$W/opened" ] && cat "$W/opened"
        printf 'GUIDES RC=%s CONNECT=%s\n' "$rc" "${EXAKIT_VS_GUIDE_CONNECT:-}" ;;
    menu)
        _exakit_vs_catalog() {
            EXAKIT_VS_RESULT="$(cat "$ROOT/setup/virtual-schemas/catalog.json")"
        }
        _exakit_vs_clock_check() { :; }
        _exakit_vs_pick "$W"
        rc=$?
        [ -f "$W/opened" ] && cat "$W/opened"
        printf 'PICKED=%s RC=%s\n' "${EXAKIT_VS_PICKED:-}" "$rc" ;;
esac
rm -rf "$W"
