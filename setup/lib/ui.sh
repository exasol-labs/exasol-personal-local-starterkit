# ui.sh — shared visual layer for the installer (bash side).
#
# This is the single source of truth for how the installer LOOKS: colors,
# glyphs, the spinner, the progress bar, the boxed plan, and the boxed
# success panel. setup/lib/ui.ps1 is its function-for-function PowerShell
# twin — every glyph, colour, and animation here has a documented mirror
# there so the install flow looks identical on macOS, Linux/WSL, and Windows.
#
# Design rules:
#   * Fancy output (colour + Unicode + animation) is used ONLY on an
#     interactive UTF-8 terminal. Piped / redirected / CI / non-UTF-8
#     output falls back to plain ASCII, one line per event — safe for logs.
#   * No sub-second timers, no bash-4-only features: this must run on the
#     stock macOS bash 3.2.
#
# Nothing here writes to the log file; callers still use info/ok/warn for
# that. This layer is purely presentation.

# --- capability detection ---------------------------------------------------
# UI_FANCY=1 only when stdout is an interactive UTF-8 terminal that wants
# colour. Everything downstream keys off this one flag.
UI_FANCY=0
ui_detect() {
    UI_FANCY=0
    [ -t 1 ] || return 0                      # not a terminal (piped/CI/log)
    [ -z "${NO_COLOR:-}" ] || return 0        # user opted out of colour
    [ "${TERM:-}" != "dumb" ] || return 0     # dumb terminal
    [ "${EXAKIT_NO_FANCY:-0}" != "1" ] || return 0   # explicit override
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]*) UI_FANCY=1 ;;         # UTF-8 locale → glyphs render
    esac
    return 0
}
ui_detect

# --- palette & glyphs -------------------------------------------------------
if [ "$UI_FANCY" = 1 ]; then
    UI_RESET=$'\033[0m';  UI_BOLD=$'\033[1m';  UI_DIM=$'\033[2m'
    UI_ACCENT=$'\033[38;5;35m'                 # Exasol green accent
    UI_GREEN=$'\033[38;5;77m'                  # brand green for the wordmark X
    UI_FG=$'\033[39m'                          # default fg (adapts to light/dark)
    UI_OK=$'\033[1;32m';  UI_WARN=$'\033[1;33m';  UI_ERR=$'\033[1;31m'
    UI_INFO=$'\033[1;34m';  UI_ASK=$'\033[1;36m'
    UI_TICK='✓';  UI_CROSS='✗';  UI_BULLET='•';  UI_ARROW='▸'
    UI_HR='─';  UI_TL='╭';  UI_TR='╮';  UI_BL='╰';  UI_BR='╯';  UI_VB='│'
    UI_TEE='├─';  UI_CORNER='└─'
    UI_BAR_FULL='█';  UI_BAR_EMPTY='░'
else
    UI_RESET='';  UI_BOLD='';  UI_DIM='';  UI_ACCENT=''
    UI_GREEN='';  UI_FG=''
    UI_OK='';  UI_WARN='';  UI_ERR='';  UI_INFO='';  UI_ASK=''
    UI_TICK='[ok]';  UI_CROSS='[x]';  UI_BULLET='-';  UI_ARROW='>'
    UI_HR='-';  UI_TL='+';  UI_TR='+';  UI_BL='+';  UI_BR='+';  UI_VB='|'
    UI_TEE='|-';  UI_CORNER='`-'
    UI_BAR_FULL='#';  UI_BAR_EMPTY='.'
fi

# Spinner frames (braille). Indexed array works on bash 3.2.
UI_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# EXASOL wordmark (ANSI Shadow style). Shown only in fancy mode; the plain
# fallback prints a plain-text title instead. Split into segments so the "X"
# carries the logo's two-tone look: the left strokes and the crossing peak are
# Exasol green (UI_GREEN); the rest of the wordmark and the X's right strokes
# stay the terminal's default colour (UI_FG) so it reads on light or dark.
# The segments are mirrored byte-for-byte in setup/lib/ui.ps1.
UI_WM_E=('███████╗' '██╔════╝' '█████╗  ' '██╔══╝  ' '███████╗' '╚══════╝')
UI_WM_XL=('██╗ ' '╚██╗' ' ╚███' ' ██╔' '██╔╝' '╚═╝ ')
UI_WM_XR=(' ██╗' '██╔╝' '╔╝ ' '██╗ ' ' ██╗' ' ╚═╝')
UI_WM_R=(
' █████╗ ███████╗ ██████╗ ██╗'
'██╔══██╗██╔════╝██╔═══██╗██║'
'███████║███████╗██║   ██║██║'
'██╔══██║╚════██║██║   ██║██║'
'██║  ██║███████║╚██████╔╝███████╗'
'╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝'
)

# Inner width of boxes (plan / panel), in visible columns.
UI_BOX_W="${UI_BOX_W:-58}"

# --- primitive helpers ------------------------------------------------------

# ui_tilde <path> — shorten $HOME to ~ so panels don't balloon to the full
# home path width. Leaves non-home paths untouched.
ui_tilde() {
    case "$1" in
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        "$HOME")   printf '~' ;;
        *)         printf '%s' "$1" ;;
    esac
}

# ui_repeat <char> <count> — echo <char> <count> times (no trailing newline).
ui_repeat() {
    _uir_out=''
    _uir_i=0
    while [ "$_uir_i" -lt "$2" ]; do _uir_out="$_uir_out$1"; _uir_i=$((_uir_i + 1)); done
    printf '%s' "$_uir_out"
}

# ui_link <url> [text] — a terminal hyperlink (OSC 8): clickable text that
# opens <url>. Falls back to plain text (or the URL) when stdout is not an
# interactive terminal (piped, CI, logs), so nothing leaks escape codes into
# a captured value. Most modern terminals (iTerm2, the macOS Terminal on
# recent macOS, GNOME Terminal, Windows Terminal, VS Code) render it; older
# ones that don't simply show the visible text.
ui_link() {
    _ul_url="$1"
    _ul_text="${2:-$1}"
    # Gate on UI_FANCY only, not a fresh `-t 1`: ui_link is meant to be called
    # inside $(...) when building panel lines, where its own stdout is a pipe.
    # UI_FANCY was set at load time from the real terminal, so it is the right
    # signal for "this session renders rich output".
    if [ "${UI_FANCY:-0}" = 1 ]; then
        printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$_ul_url" "$_ul_text"
    else
        printf '%s' "$_ul_text"
    fi
}

# _ui_visible_len <string> — character length ignoring escape sequences, so a
# line carrying colour (CSI) or hyperlink (OSC 8) codes still lines up inside a
# panel box. Strips CSI `ESC [ … m` and OSC 8 `ESC ] 8 ; ; … (BEL|ESC\)`.
_ui_visible_len() {
    _uvl_clean="$(printf '%s' "$1" | LC_ALL=C sed \
        -e 's/'"$(printf '\033')"'\[[0-9;]*m//g' \
        -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*\('"$(printf '\007')"'\|'"$(printf '\033')"'\\\)//g')"
    printf '%s' "${#_uvl_clean}"
}

# ui_banner <title> <subtitle> — the top-of-install wordmark block.
# Fancy mode draws the EXASOL block-letter wordmark above the title; the
# plain fallback prints the title as text (block glyphs can't render there).
ui_banner() {
    printf '\n'
    if [ "$UI_FANCY" = 1 ]; then
        _uib_i=0
        while [ "$_uib_i" -lt 6 ]; do
            printf '  %s%s%s%s%s%s%s\n' \
                "$UI_BOLD$UI_FG" "${UI_WM_E[$_uib_i]}" \
                "$UI_GREEN" "${UI_WM_XL[$_uib_i]}" \
                "$UI_FG" "${UI_WM_XR[$_uib_i]}${UI_WM_R[$_uib_i]}" \
                "$UI_RESET"
            _uib_i=$((_uib_i + 1))
        done
        printf '\n'
    fi
    printf '  %s%s%s\n' "$UI_BOLD" "${1:-Exasol Personal Local Starter Kit}" "$UI_RESET"
    [ -n "${2:-}" ] && printf '  %s%s%s\n' "$UI_DIM" "$2" "$UI_RESET"
    printf '\n'
}

# ui_rule — a full-width accent divider (box inner width).
ui_rule() {
    printf '  %s%s%s\n' "$UI_DIM" "$(ui_repeat "$UI_HR" "$UI_BOX_W")" "$UI_RESET"
}

# ui_box_top <title> / ui_box_line <text> / ui_box_bottom — a titled frame.
ui_box_top() {
    _uibt_title=" $1 "
    _uibt_fill=$((UI_BOX_W - ${#_uibt_title} - 1))
    [ "$_uibt_fill" -lt 0 ] && _uibt_fill=0
    printf '  %s%s%s%s%s%s%s\n' \
        "$UI_ACCENT" "$UI_TL$UI_HR" "$UI_RESET$UI_BOLD$_uibt_title$UI_RESET" \
        "$UI_ACCENT" "$(ui_repeat "$UI_HR" "$_uibt_fill")" "$UI_TR" "$UI_RESET"
}
ui_box_line() {
    # Inner width (between the verticals) is exactly UI_BOX_W: one leading
    # space, the text, right-padding, one trailing space. Note ${#text}
    # counts bytes, so keep box content ASCII (labels/paths) to stay aligned.
    _uibl_text="$1"
    _uibl_pad=$((UI_BOX_W - ${#_uibl_text} - 2))
    [ "$_uibl_pad" -lt 0 ] && _uibl_pad=0
    printf '  %s %s%s %s\n' \
        "$UI_ACCENT$UI_VB$UI_RESET" "$_uibl_text" \
        "$(ui_repeat ' ' "$_uibl_pad")" "$UI_ACCENT$UI_VB$UI_RESET"
}
ui_box_bottom() {
    printf '  %s%s%s%s\n' \
        "$UI_ACCENT" "$UI_BL" "$(ui_repeat "$UI_HR" "$UI_BOX_W")" "$UI_BR$UI_RESET"
}

# --- auto-width panel -------------------------------------------------------
# Like the box above, but sizes itself to the longest buffered line — use it
# for content with long values (paths, DSNs) that a fixed width would break.
#   ui_panel_begin "Title"; ui_panel_line "a"; ui_panel_line "b"; ui_panel_end
_UI_PANEL_TITLE=''
_UI_PANEL_BUF=''
ui_panel_begin() { _UI_PANEL_TITLE="${1:-}"; _UI_PANEL_BUF=''; }
ui_panel_line() {
    if [ -z "$_UI_PANEL_BUF" ]; then _UI_PANEL_BUF="$1"
    else _UI_PANEL_BUF="$_UI_PANEL_BUF
$1"; fi
}
ui_panel_end() {
    _uipe_w=$(( ${#_UI_PANEL_TITLE} + 1 ))
    _uipe_oifs=$IFS; IFS='
'
    for _uipe_l in $_UI_PANEL_BUF; do
        _uipe_ll=$(_ui_visible_len "$_uipe_l")
        [ "$_uipe_ll" -gt "$_uipe_w" ] && _uipe_w=$_uipe_ll
    done
    IFS=$_uipe_oifs
    _uipe_w=$(( _uipe_w + 2 ))                  # breathing room on the right
    # top border with inset title
    _uipe_title=" $_UI_PANEL_TITLE "
    _uipe_fill=$(( _uipe_w - ${#_uipe_title} - 1 ))
    [ "$_uipe_fill" -lt 0 ] && _uipe_fill=0
    printf '  %s%s%s%s%s%s%s\n' \
        "$UI_ACCENT" "$UI_TL$UI_HR" "$UI_RESET$UI_BOLD$_uipe_title$UI_RESET" \
        "$UI_ACCENT" "$(ui_repeat "$UI_HR" "$_uipe_fill")" "$UI_TR" "$UI_RESET"
    # content lines, each padded to the inner width
    _uipe_oifs=$IFS; IFS='
'
    for _uipe_l in $_UI_PANEL_BUF; do
        _uipe_pad=$(( _uipe_w - $(_ui_visible_len "$_uipe_l") - 2 ))
        [ "$_uipe_pad" -lt 0 ] && _uipe_pad=0
        printf '  %s %s%s %s\n' \
            "$UI_ACCENT$UI_VB$UI_RESET" "$_uipe_l" \
            "$(ui_repeat ' ' "$_uipe_pad")" "$UI_ACCENT$UI_VB$UI_RESET"
    done
    IFS=$_uipe_oifs
    printf '  %s%s%s%s\n' \
        "$UI_ACCENT" "$UI_BL" "$(ui_repeat "$UI_HR" "$_uipe_w")" "$UI_BR$UI_RESET"
}

# --- spinner / step animation ----------------------------------------------
# Model: ui_step_start prints (or animates) a "working" line; the step body
# runs with its chatter sent to the log; ui_step_ok / ui_step_fail replaces
# the line with a final status + elapsed time.

_UI_SPIN_PID=''
_UI_STEP_T0=''
_UI_STEP_LABEL=''

# ui_spin_begin <label> — start ONLY the animated spinner (prints no line of
# its own). No-op unless we are on an interactive fancy terminal *right now*:
# it re-checks `-t 1` at call time so a spinner can never leak into a
# $(command substitution) capture, even when UI_FANCY was 1 at load time.
ui_spin_begin() {
    [ "$UI_FANCY" = 1 ] || return 0
    [ -t 1 ] || return 0
    _UI_STEP_LABEL="$1"
    _UI_STEP_T0="$(date +%s 2>/dev/null || echo 0)"
    printf '\033[?25l'                          # hide cursor
    (
        _i=0
        while :; do
            _f="${UI_SPIN_FRAMES[$_i]}"
            _now="$(date +%s 2>/dev/null || echo 0)"
            _el=$((_now - _UI_STEP_T0))
            printf '\r  %s%s%s %s %s(%ss)%s\033[K' \
                "$UI_ACCENT" "$_f" "$UI_RESET" "$_UI_STEP_LABEL" \
                "$UI_DIM" "$_el" "$UI_RESET"
            _i=$(((_i + 1) % 10))
            sleep 0.08
        done
    ) &
    _UI_SPIN_PID=$!
}

# ui_spin_end — stop the spinner and clear its line, printing no status line
# (the caller's own info/ok lines carry the message).
ui_spin_end() { _ui_step_stop_spinner; }

# ui_step_start <label> — begin a visible step: an animated spinner in fancy
# mode, or a plain "> label…" line otherwise. Pair with ui_step_ok/_fail.
ui_step_start() {
    if [ "$UI_FANCY" = 1 ] && [ -t 1 ]; then
        ui_spin_begin "$1"
    else
        _UI_STEP_LABEL="$1"
        _UI_STEP_T0="$(date +%s 2>/dev/null || echo 0)"
        printf '  %s %s…\n' "$UI_ARROW" "$1"
    fi
}

_ui_step_stop_spinner() {
    [ -n "$_UI_SPIN_PID" ] || return 0
    kill "$_UI_SPIN_PID" 2>/dev/null
    wait "$_UI_SPIN_PID" 2>/dev/null
    _UI_SPIN_PID=''
    printf '\r\033[K\033[?25h'                   # clear spinner line, restore cursor
}

_ui_step_elapsed() {
    _now="$(date +%s 2>/dev/null || echo 0)"
    _el=$((_now - _UI_STEP_T0))
    [ "$_el" -lt 1 ] && { printf '<1s'; return; }
    printf '%ss' "$_el"
}

# ui_step_ok <label> [detail]
ui_step_ok() {
    _ui_step_stop_spinner
    _uiso_detail=''
    [ -n "${2:-}" ] && _uiso_detail=" ${UI_DIM}${2}${UI_RESET}"
    if [ "$UI_FANCY" = 1 ]; then
        printf '  %s%s%s %s%s %s(%s)%s\n' \
            "$UI_OK" "$UI_TICK" "$UI_RESET" "$1" "$_uiso_detail" \
            "$UI_DIM" "$(_ui_step_elapsed)" "$UI_RESET"
    else
        printf '  %s %s%s\n' "$UI_TICK" "$1" "${2:+ ($2)}"
    fi
}

# ui_step_fail <label> [detail]
ui_step_fail() {
    _ui_step_stop_spinner
    if [ "$UI_FANCY" = 1 ]; then
        printf '  %s%s%s %s%s\n' \
            "$UI_ERR" "$UI_CROSS" "$UI_RESET" "$1" "${2:+ ${UI_DIM}$2${UI_RESET}}"
    else
        printf '  %s %s%s\n' "$UI_CROSS" "$1" "${2:+ ($2)}"
    fi
}

# Restore the cursor if we died mid-spin. NOT wired to a trap here on
# purpose: the installer owns `trap ... EXIT` (exakit_on_failure), which
# calls this itself, so a trap here would clobber the installer's cleanup.
ui_restore_cursor() { [ "$UI_FANCY" = 1 ] && printf '\033[?25h'; return 0; }

# --- progress bar (determinate) --------------------------------------------
# ui_progress <current> <total> <label> — redraws in place; caller prints a
# newline (or calls ui_step_ok) when done.
ui_progress() {
    _uip_cur="$1"; _uip_tot="$2"; _uip_label="${3:-}"
    [ "$_uip_tot" -gt 0 ] 2>/dev/null || _uip_tot=1
    _uip_w=20
    _uip_filled=$(( _uip_cur * _uip_w / _uip_tot ))
    [ "$_uip_filled" -gt "$_uip_w" ] && _uip_filled="$_uip_w"
    _uip_pct=$(( _uip_cur * 100 / _uip_tot ))
    if [ "$UI_FANCY" = 1 ]; then
        printf '\r  %s%s%s%s %s%3s%%%s %s\033[K' \
            "$UI_ACCENT" "$(ui_repeat "$UI_BAR_FULL" "$_uip_filled")" \
            "$UI_DIM" "$(ui_repeat "$UI_BAR_EMPTY" $((_uip_w - _uip_filled)))$UI_RESET" \
            "$UI_BOLD" "$_uip_pct" "$UI_RESET" "$_uip_label"
    else
        printf '  [%s%s] %s%%  %s\n' \
            "$(ui_repeat "$UI_BAR_FULL" "$_uip_filled")" \
            "$(ui_repeat "$UI_BAR_EMPTY" $((_uip_w - _uip_filled)))" \
            "$_uip_pct" "$_uip_label"
    fi
}

# --- direct-invocation render entry points ----------------------------------
# When this file is EXECUTED (not sourced), it exposes render helpers so a
# POSIX-sh caller (install.sh, which can't source a bash lib) can reuse this
# exact banner + palette. The guard means sourcing never triggers this.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        __render_install_plan)
            # Banner only: the old "Installation plan" panel repeated internals
            # (kit copy path, component list) users don't act on. Whether this
            # machine can run the kit is answered by the compatibility checks
            # that follow, which fail or warn explicitly.
            ui_banner "Personal Local Starter Kit"
            printf '\n'
            ;;
    esac
fi
