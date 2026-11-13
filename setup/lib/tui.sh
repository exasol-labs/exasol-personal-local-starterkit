# shellcheck shell=bash
# tui.sh — exakit's terminal view: the whole kit on five tabs (Status, Marketplace, AI clients, External sources,
# Personas), a Textual app in setup/tui/exakit_tui. Twin: tui.ps1.
#
#   exakit                     in a terminal: the view (without one, or with EXAKIT_NO_TUI=1: the help, as before)
#   exakit tui [--tab T]       the view on a tab: status, marketplace, clients, sources, personas
#   exakit <persona-id>        the view on that persona's page (without a terminal: exakit persona show <id>)
#
# The view reads everything from the kit's own `exakit ... --json` answers and every button runs an `exakit` command,
# so it adds nothing the CLI does not do. It runs on the kit's own Textual - the version marketplace/defaults.env pins,
# through the kit's vetted uv (setup/tui/start.py), as the persona and marketplace questions do - so it shares their
# one pin and download cache and adds no environment of its own.

# exakit_tui_wanted — should a bare `exakit` open the view? Only for a person at a terminal: stdin and stdout are
# one, it is not CI, and EXAKIT_NO_TUI is not set (scripts, agents and the view's own commands get the help).
exakit_tui_wanted() {
    [ "${EXAKIT_NO_TUI:-0}" = 1 ] && return 1
    [ -n "${CI:-}" ] && return 1
    [ "${TERM:-dumb}" = dumb ] && return 1
    [ -t 0 ] && [ -t 1 ]
}

# cmd_tui [--tab T] [--persona ID] — open the view.
cmd_tui() {
    _ct_tab=status
    _ct_persona=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tab) [ $# -ge 2 ] || reject "--tab takes one of: status, marketplace, clients, sources, personas"; _ct_tab="$2"; shift 2 ;;
            --tab=*) _ct_tab="${1#--tab=}"; shift ;;
            --persona) [ $# -ge 2 ] || reject "--persona takes a persona id: exakit persona list"; _ct_persona="$2"; shift 2 ;;
            --persona=*) _ct_persona="${1#--persona=}"; shift ;;
            *) reject "Unknown option for tui: $1 (supported: --tab status|marketplace|clients|sources|personas, --persona ID)" ;;
        esac
    done
    case "$_ct_tab" in
        status|marketplace|clients|sources|personas) ;;
        *) reject "--tab takes one of: status, marketplace, clients, sources, personas (not '$_ct_tab')" ;;
    esac
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        reject "The terminal view needs a terminal. For scripts: exakit status --json, exakit marketplace --list --json, exakit persona show <id> --json"
    fi
    _ct_root="$(exakit_repo_root)"
    set -- "--cli=bash" "--cli=$_ct_root/setup/exakit" "--tab=$_ct_tab"
    [ -n "$_ct_persona" ] && set -- "$@" "--persona=$_ct_persona"
    run_python_any "$_ct_root/setup/tui/start.py" "$_ct_root" "$@"
    _ct_code=$?
    [ "$_ct_code" = 11 ] && echo "exakit: the terminal view could not start here. Every command works: exakit help" >&2
    return "$_ct_code"
}

# exakit_tui_persona <id> - `exakit data-scientist` at a terminal: the persona's page in the view (without one,
# setup/exakit prints the persona as `exakit persona show <id>` does instead). Twin of Invoke-ExakitTuiPersona.
exakit_tui_persona() {
    cmd_tui --tab personas --persona "$1"
}

# exakit_tui_is_persona <word> — is the word a persona id of this kit?
exakit_tui_is_persona() {
    case "${1:-}" in ""|-*) return 1 ;; esac
    command -v exakit_persona_ids >/dev/null 2>&1 || return 1
    exakit_persona_ids 2>/dev/null | grep -qx -- "$1"
}
