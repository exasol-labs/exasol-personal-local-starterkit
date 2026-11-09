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
# The kit's pyexasol, which the credential reader runs on: here, python3.
pyexasol_venv_python() { command -v python3; }
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

# TUI_SLOW_CONNECT=<seconds>: each connect takes at least that long, so a key
# typed while the live table runs is typed while it runs, however fast the
# simulated database answers.
if [ -n "${TUI_SLOW_CONNECT:-}" ]; then
    eval "_tui_fast_engine() $(declare -f exakit_vs_engine | sed 1d)"
    exakit_vs_engine() {
        case " $* " in *" connect "*) sleep "$TUI_SLOW_CONNECT" ;; esac
        _tui_fast_engine "$@"
    }
fi

# TUI_PLAN_FAIL: the form's first plan is refused with this reason - what the
# engine says of an input the form's own checks let through - and every later
# plan is the engine's own. One shell: the form runs the plan in this process.
if [ -n "${TUI_PLAN_FAIL:-}" ]; then
    eval "_tui_engine() $(declare -f exakit_vs_engine | sed 1d)"
    exakit_vs_engine() {
        if [ "$1" = plan ] && [ -z "${_TUI_PLAN_REFUSED:-}" ]; then
            _TUI_PLAN_REFUSED=1
            printf 'FAIL %s\n' "$TUI_PLAN_FAIL"
            return 2
        fi
        _tui_engine "$@"
    }
fi

# TUI_PLAIN=1: a terminal without the drawn form (a dumb TERM, NO_COLOR), so
# cmd_connect takes its line-by-line questions. Run with TTY_REPLAY_CTTY=1:
# those prompts and the hidden one read /dev/tty.
[ -n "${TUI_PLAIN:-}" ] && UI_FANCY=0

# TUI_SAY_EXIT=1: the exit status is the last line written ("EXIT <n>"), for a
# refusal the replay could otherwise only see the words of.
[ -n "${TUI_SAY_EXIT:-}" ] && trap 'printf "EXIT %s\n" "$?"' EXIT

# TUI_STDIN: stdin is a pipe carrying this text, the terminal still behind
# /dev/tty (run with TTY_REPLAY_CTTY=1) - `printf pw | exakit connect ...`.
if [ -n "${TUI_STDIN:-}" ]; then
    # shellcheck disable=SC2086
    printf '%s' "$TUI_STDIN" | cmd_connect ${TUI_ARGS:-}
    exit $?
fi

# TUI_ARGS: what the command line said (a connector, --name, --set ...), word split.
# shellcheck disable=SC2086
cmd_connect ${TUI_ARGS:-}
