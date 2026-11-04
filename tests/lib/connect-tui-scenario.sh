#!/usr/bin/env bash
# Driven by tests/lib/tty-replay.py under a real pty from tests/virtual-schemas.sh:
# `exakit connect` with no arguments, the whole terminal flow - the connector
# menu, one source's panel (a refused answer included), the review and the live
# table - so the replay can assert what a terminal is left holding.
#
# Everything is shipping code except the engine's database: exakit_vs_engine is
# pointed at tests/lib/fake-exasol-vs.py through the suite's own deployment
# folder and kit home (TUI_* from the caller), and the kit-install checks are
# stubbed. The keystrokes come from the replay.
set -u
ROOT="$1"; shift
export HOME="${TUI_HOME_DIR:-$HOME}"
EXAKIT_HOME="$TUI_KIT"; EXAKIT_BIN_DIR="$TUI_KIT/bin"
. "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/virtual-schemas.sh"

_require_install() { :; }
exakit_init_logging() { EXAKIT_LOG_FILE="$TUI_LOG"; }
personal_slc_dns_repair() { return 0; }
command -v reject >/dev/null 2>&1 || reject() { printf '%s\n' "$*" >&2; exit 2; }
exakit_vs_engine() {
    EXAKIT_VS_FAKE_DB="$ROOT/tests/lib/fake-exasol-vs.py" FAKE_VS_STATE="$TUI_STATE" FAKE_VS_EXA="$TUI_EXA" \
        EXAKIT_VS_SETTLE_SECONDS=0 EXAKIT_VS_VISIBLE_TIMEOUT=5 \
        python3 "$ROOT/setup/virtual-schemas/engine/cli.py" --defs "$TUI_DEFS" --kit-home "$TUI_KIT" \
        --deployment-dir "$TUI_DEPLOY" --dsn 127.0.0.1:8563 --user sys --password-file /nonexistent "$@"
}

# The Java language container's install is a download and a restart; here it is
# the fake database learning that Java is there, after the same question.
if [ -n "${TUI_FAKE_JAVA_INSTALL:-}" ]; then
    _exakit_vs_install_java() {
        info "Virtual schemas run Java inside the database, and its Java language container is not installed."
        _exakit_vs_confirm "Install the Java language container now?" || return 1
        python3 - "$TUI_STATE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["java"] = True; json.dump(d, open(sys.argv[1], "w"))
PY
        ok "Java language container installed"
    }
fi

# TUI_ARGS: what the command line said (a connector, --name, --set ...), word split.
# shellcheck disable=SC2086
cmd_connect ${TUI_ARGS:-}
