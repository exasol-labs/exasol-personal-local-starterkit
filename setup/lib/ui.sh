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
    # One -e per terminator, never a BRE alternation. `\|` is a GNU sed
    # extension: BSD sed (macOS, the platform this kit targets first) does not
    # support it, so the OSC 8 branch silently matched nothing there and this
    # returned the RAW byte length. A two-link line measured 124 instead of 37,
    # which made it the widest line in ui_panel_end's first pass -- drawing the
    # box to 124 columns -- and left its own padding at ~0 in the second, so its
    # right border closed early. Every hyperlinked panel line was affected.
    _uvl_clean="$(printf '%s' "$1" | LC_ALL=C sed \
        -e 's/'"$(printf '\033')"'\[[0-9;]*m//g' \
        -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\007')"'//g' \
        -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\033')"'\\//g')"
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
    # CAPPED TO THE TERMINAL. A panel takes the width of its widest line, and
    # the uninstall consent panel measured 116 columns — so the one box that
    # must be read whole wrapped mid-border and broke apart on every default
    # terminal. Lines longer than the cap are WRAPPED into the panel (indented
    # continuations), not truncated: this panel names what is about to be
    # deleted, and a consent screen that hides its own consequences is worse
    # than an ugly one. Only where a terminal is actually rendering — captured
    # and piped output has no columns to break, and wrapping there would split
    # long paths across lines under every grep that reads them.
    if [ -t 1 ]; then
        _uipe_cols="$(_ui_term_cols 2>/dev/null || echo 80)"
        case "$_uipe_cols" in ''|*[!0-9]*) _uipe_cols=80 ;; esac
        _uipe_max=$(( _uipe_cols - 4 ))         # two-space indent + borders
        [ "$_uipe_max" -lt 24 ] && _uipe_max=24
    else
        _uipe_max=$_uipe_w
    fi
    if [ "$_uipe_w" -gt "$_uipe_max" ]; then
        _uipe_w=$_uipe_max
        _uipe_inner=$(( _uipe_w - 2 ))
        _uipe_new=""
        _uipe_oifs=$IFS; IFS='
'
        for _uipe_l in $_UI_PANEL_BUF; do
            if [ "$(_ui_visible_len "$_uipe_l")" -le "$_uipe_inner" ]; then
                _uipe_new="${_uipe_new}${_uipe_l}
"
                continue
            fi
            IFS=$_uipe_oifs
            _ui_wrap "$_uipe_l" "$(( _uipe_inner - 2 ))"
            _uipe_i=0
            while [ "$_uipe_i" -lt "${_UI_WRAP_N:-0}" ]; do
                if [ "$_uipe_i" -eq 0 ]; then
                    _uipe_new="${_uipe_new}${_UI_WRAP[$_uipe_i]}
"
                else
                    _uipe_new="${_uipe_new}  ${_UI_WRAP[$_uipe_i]}
"
                fi
                _uipe_i=$(( _uipe_i + 1 ))
            done
            IFS='
'
        done
        IFS=$_uipe_oifs
        _UI_PANEL_BUF="${_uipe_new%
}"
    fi
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

# ui_rule — a dim full-width divider, with a blank line either side.
#
# For the seam between two parts of a run: the install is finished and something
# else is being asked. Sized to the terminal so it reads as a break rather than
# as content. ⇄ twin: Write-ExakitRule in ui.ps1.
ui_rule() {
    _uir_w="$(_ui_term_cols 2>/dev/null || echo 80)"
    _uir_w=$(( _uir_w - 4 ))
    [ "$_uir_w" -gt 76 ] && _uir_w=76
    [ "$_uir_w" -ge 8 ] || _uir_w=8
    printf '\n  %s%s%s\n\n' "${UI_DIM:-}" "$(ui_repeat "${UI_HR:--}" "$_uir_w")" "${UI_RESET:-}"
}

# --- spinner / step animation ----------------------------------------------
# Model: ui_step_start prints (or animates) a "working" line; the step body
# runs with its chatter sent to the log; ui_step_ok / ui_step_fail replaces
# the line with a final status + elapsed time.

_UI_SPIN_PID=''
_UI_STEP_T0=''
_UI_STEP_LABEL=''
# ONE animation at a time. There is a single line being redrawn, so a second
# request to animate is a no-op rather than a second painter: two loops writing
# \r to the same row produce a flicker, and the first one's pid is lost the
# moment the second overwrites _UI_SPIN_PID.
#
# This is what lets a progress line survive the work underneath it. A dataset
# load paints its own bar and then calls exapump through run_logged, which asks
# for a spinner of its own; without the counter, run_logged's ui_spin_end would
# kill the bar after the first file. Counted rather than flagged, because the
# nesting can be more than one deep.
_UI_SPIN_NESTED=0
# WHICH SHELL started the animation. A subshell inherits _UI_SPIN_PID but not
# the right to end it: the installer runs each dataset load inside ( ), that
# subshell called ui_progress_end for a bar it had never started, and the kill
# landed on the PARENT's table animator -- mid-frame, leaving a half-drawn table
# on screen with the finished one printed under it. A subshell's nesting counter
# starts at zero, so counting alone cannot tell the two apart; ownership can.
_UI_SPIN_OWNER=''

# ui_spin_begin <label> — start ONLY the animated spinner (prints no line of
# its own). No-op unless we are on an interactive fancy terminal *right now*:
# it re-checks `-t 1` at call time so a spinner can never leak into a
# $(command substitution) capture, even when UI_FANCY was 1 at load time.
ui_spin_begin() {
    # Something is already animating this line: take a reference, draw nothing.
    # _UI_LINE_BUSY is checked as well as the pid because the loads run in
    # subshells that had to drop the pid, and run_logged starts one of these for
    # every silent stretch of every dataset load -- a second animator writing its
    # own line, with no newline, into the row the table owns.
    if [ -n "${_UI_SPIN_PID:-}" ] || [ -n "${_UI_LINE_BUSY:-}" ]; then
        _UI_SPIN_NESTED=$(( _UI_SPIN_NESTED + 1 ))
        return 0
    fi
    [ "$UI_FANCY" = 1 ] || return 0
    [ -t 1 ] || return 0
    _UI_SPIN_OWNER="$$"
    _UI_STEP_LABEL="$1"
    # $2 is an ORIGINAL start time, passed only by ui_spin_resume: a spinner that
    # was paused so a line could be printed under it has to carry on counting
    # from where it was, not restart at (0s) every time something prints.
    _UI_STEP_T0="${2:-$(date +%s 2>/dev/null || echo 0)}"
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
    # Disowned for the same reason as the two animators below: a component that
    # runs in a subshell inherits this pid, and the kill that ends the spinner is
    # then announced by the shell over whatever is on screen.
    disown 2>/dev/null || true
}

# ui_spin_end — stop the spinner and clear its line, printing no status line
# (the caller's own info/ok lines carry the message).
ui_spin_end() {
    # Give back a reference taken while something else owned the line; only the
    # call that actually started the animation stops it.
    if [ "${_UI_SPIN_NESTED:-0}" -gt 0 ]; then
        _UI_SPIN_NESTED=$(( _UI_SPIN_NESTED - 1 ))
        return 0
    fi
    _ui_step_stop_spinner
}

# ui_spin_pause / ui_spin_resume — print a line without losing the spinner.
#
# A spinner OWNS its line and rewrites it every 80ms, so anything printed while
# it runs lands in the middle of that line rather than on a row of its own. The
# uninstall showed it plainly: three add-on outcomes appended themselves to
# "Removing the kit (4s)" instead of standing under it.
#
# Pausing stops the animation and clears the line; resuming restarts it with the
# same label AND the same start time, so the elapsed counter carries on. Only
# the shell that owns the animation may pause it, and only when nothing else
# holds a reference -- a nested caller is not this one's to stop.
_UI_SPIN_PAUSED=0
ui_spin_pause() {
    _UI_SPIN_PAUSED=0
    [ -n "${_UI_SPIN_PID:-}" ] || return 0
    [ "${_UI_SPIN_OWNER:-}" = "$$" ] || return 0
    [ "${_UI_SPIN_NESTED:-0}" -eq 0 ] || return 0
    _UI_SPIN_PAUSED=1
    _UI_SPIN_PAUSE_LABEL="$_UI_STEP_LABEL"
    _UI_SPIN_PAUSE_T0="$_UI_STEP_T0"
    _ui_step_stop_spinner
}
ui_spin_resume() {
    [ "${_UI_SPIN_PAUSED:-0}" = 1 ] || return 0
    _UI_SPIN_PAUSED=0
    ui_spin_begin "$_UI_SPIN_PAUSE_LABEL" "$_UI_SPIN_PAUSE_T0"
}

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
    # Started by another shell: this one is a subshell that inherited the pid,
    # and ending someone else's animation is never what it meant to do.
    if [ -n "${_UI_SPIN_OWNER:-}" ] && [ "$_UI_SPIN_OWNER" != "$$" ]; then
        return 0
    fi
    kill "$_UI_SPIN_PID" 2>/dev/null
    wait "$_UI_SPIN_PID" 2>/dev/null
    _UI_SPIN_PID=''
    _UI_SPIN_OWNER=''
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

# --- the progress line -----------------------------------------------------
# ui_progress_creep <pct> <ceiling> <seconds> <elapsed-in-segment> — where
# the bar should sit RIGHT NOW, between the stage the job last reported and
# the one it will report next.
#
# A milestone-only bar stands still for as long as the job is quiet, and every
# job the kit runs is quiet for its longest stretch. So the milestones stay
# the truth -- the bar never claims a stage that has not been reached -- and the
# time between them is filled in at the pace that stage usually takes. The creep is
# capped one point BELOW the next milestone, so arriving at it is still something
# you see happen, and a stage that runs long simply waits there instead of
# walking into the next one's territory.
ui_progress_creep() {
    _upc_span=$(( $2 - $1 ))
    if [ "$_upc_span" -le 0 ] || [ "$3" -le 0 ]; then
        printf '%s\n' "$1"
        return 0
    fi
    _upc_step=$(( _upc_span * $4 / $3 ))
    [ "$_upc_step" -gt $(( _upc_span - 1 )) ] && _upc_step=$(( _upc_span - 1 ))
    [ "$_upc_step" -lt 0 ] && _upc_step=0
    printf '%s\n' "$(( $1 + _upc_step ))"
}

UI_PROGRESS_EIGHTHS=' ▏▎▍▌▋▊▉'

# ui_progress_line <pct> <phase> <elapsed-seconds> <frame> <columns> — the
# progress line.
#
# Laid out in four cells across the terminal's own width, so the bar starts at
# the same column whatever the phase is called and nothing shuffles sideways as
# the text changes underneath it:
#
#   45% phase text · 40% bar · 7% percentage · 8% elapsed
#
# The phase leads because it is the part a reader is actually reading; the
# numbers trail because they are the part they glance at. A braille head sits in
# front of the whole thing: the bar can legitimately sit still (a slow step holds its
# position on purpose), and the head is
# what says the run is alive while it does.
#
# One bar for every long job the kit runs: the local deployment, a bundled
# dataset, a folder of files, an add-on install. Twin: Write-ExakitProgressLine.
ui_progress_line() {
    _upl_pct="$1"; _upl_phase="$2"; _upl_el="$3"; _upl_frame="${4:-0}"; _upl_cols="${5:-80}"

    # The gutter the rest of the step's lines use, plus the head and its space,
    # and ONE COLUMN LEFT UNWRITTEN. A line that fills the last cell sets the
    # terminal's pending-wrap flag, and the next \r lands a row lower — which on
    # a wide terminal showed up as a clipped "(19s" with its bracket eaten.
    _upl_avail=$(( _upl_cols - 6 - 2 - 1 ))
    # Capped, because the cells are proportions and a very wide terminal turns
    # the 45% text cell into sixty columns of nothing between the phase and the
    # bar. Past this width the line stays put and the screen gets wider around
    # it, which is what a reader wants from a line they are watching.
    [ "$_upl_avail" -le 112 ] || _upl_avail=112
    [ "$_upl_avail" -ge 24 ] || _upl_avail=24
    #   30% phase · 40% bar · 10% percentage · 10% elapsed
    # The remaining tenth is the gap between the phase and the bar. Spending it
    # there rather than widening a cell is what stops a long phase from butting
    # against the bar while a short one leaves the two looking unrelated.
    _upl_tw=$(( _upl_avail * 30 / 100 ))
    _upl_bw=$(( _upl_avail * 40 / 100 ))
    _upl_nw=$(( _upl_avail * 10 / 100 ))
    _upl_ew=$(( _upl_avail * 10 / 100 ))
    _upl_gap=$(( _upl_avail - _upl_tw - _upl_bw - _upl_nw - _upl_ew ))
    [ "$_upl_gap" -ge 1 ] || _upl_gap=1
    # Floors, because a cell that cannot hold its content is worse than a
    # narrower neighbour: "100%" needs four columns and "(120s)" needs six. The
    # text cell pays for them, since it is the only one that can be shortened
    # without losing information the others carry exactly.
    [ "$_upl_nw" -ge 5 ] || { _upl_tw=$(( _upl_tw - (5 - _upl_nw) )); _upl_nw=5; }
    [ "$_upl_ew" -ge 7 ] || { _upl_tw=$(( _upl_tw - (7 - _upl_ew) )); _upl_ew=7; }
    [ "$_upl_bw" -ge 8 ] || _upl_bw=8
    [ "$_upl_tw" -ge 8 ] || _upl_tw=8

    # The phase, truncated to its cell MINUS ONE: a phase long enough to fill
    # the cell would otherwise run straight into the bar with no gap between
    # them, which is what a narrow terminal does to every long phase there is.
    # _ui_fit_row measures what the reader SEES, so a phase carrying an escape
    # sequence is not cut by byte count.
    _upl_text="$(_ui_fit_row "$_upl_phase" 0 $(( _upl_tw - 1 )))"
    _upl_pad=$(( _upl_tw - $(_ui_visible_len "$_upl_text") ))
    [ "$_upl_pad" -ge 0 ] || _upl_pad=0

    # Eighths across the whole bar, from integer percent: at forty cells one
    # percent is three eighths, so every step of the creep moves something.
    if [ "${UI_FANCY:-0}" = 1 ]; then
        _upl_units=$(( _upl_pct * _upl_bw * 8 / 100 ))
        _upl_full=$(( _upl_units / 8 ))
        _upl_rem=$(( _upl_units % 8 ))
        [ "$_upl_full" -gt "$_upl_bw" ] && { _upl_full="$_upl_bw"; _upl_rem=0; }
        _upl_head=""
        if [ "$_upl_full" -lt "$_upl_bw" ] && [ "$_upl_rem" -gt 0 ]; then
            _upl_head="$(printf '%s' "$UI_PROGRESS_EIGHTHS" | cut -c $((_upl_rem + 1)))"
        fi
        _upl_empty=$(( _upl_bw - _upl_full ))
        [ -n "$_upl_head" ] && _upl_empty=$(( _upl_empty - 1 ))
        [ "$_upl_empty" -ge 0 ] || _upl_empty=0
        _upl_bar="${UI_ACCENT:-}$(ui_repeat "${UI_BAR_FULL:-#}" "$_upl_full")${UI_DIM:-}${_upl_head}$(ui_repeat "${UI_BAR_EMPTY:-.}" "$_upl_empty")${UI_RESET:-}"
        _upl_spin="${UI_SPIN_FRAMES[$(( _upl_frame % 10 ))]}"
    else
        _upl_full=$(( _upl_pct * _upl_bw / 100 ))
        [ "$_upl_full" -gt "$_upl_bw" ] && _upl_full="$_upl_bw"
        _upl_bar="$(ui_repeat "${UI_BAR_FULL:-#}" "$_upl_full")$(ui_repeat "${UI_BAR_EMPTY:-.}" $(( _upl_bw - _upl_full )))"
        _upl_spin='>'
    fi

    printf '\r      %s%s%s %s%s%s%s%s%*s%%%s%s%*s%s\033[K' \
        "${UI_ACCENT:-}" "$_upl_spin" "${UI_RESET:-}" \
        "$_upl_text" "$(ui_repeat ' ' $(( _upl_pad + _upl_gap )))" \
        "$_upl_bar" \
        "${UI_BOLD:-}" "" $(( _upl_nw - 1 )) "$_upl_pct" "${UI_RESET:-}" \
        "${UI_DIM:-}" "$_upl_ew" "($_upl_el""s)" "${UI_RESET:-}"
}

# ui_progress_animate <state-file> <t0> — redraw the progress line five
# times a second from whatever the collector last wrote, so the elapsed counter
# keeps moving through the launcher's long silences (13s between messages on a
# warm cache, minutes on a cold one).
#
# It runs in the UI layer's single spinner slot (_UI_SPIN_PID), so the
# installer's existing EXIT trap -- which calls ui_spin_end and
# ui_restore_cursor -- stops it and gives the cursor back if the run is
# interrupted or dies mid-deploy. Only one animation is ever on screen, so the
# slot is free while this runs.
ui_progress_animate() {
    _upa_shown=0
    _upa_frame=0
    # Measured ONCE. _ui_term_cols forks stty or tput, and this loop runs five
    # times a second for as long as the deploy takes; a terminal resized mid
    # deploy keeps the width it started with, which is a fair trade for not
    # forking a process per frame.
    _upa_cols="$(_ui_term_cols 2>/dev/null || echo 80)"
    while :; do
        _upa_state=""
        read -r _upa_state < "$1" 2>/dev/null || true
        # A read that caught the file mid-write has no phase yet: skip the frame
        # rather than paint a half-written one.
        case "$_upa_state" in
            *"|"*"|"*"|"*"|"*)
                _upa_now="$(date +%s 2>/dev/null || echo 0)"
                # pct|ceiling|seconds|segment-start|label
                _upa_rest="${_upa_state#*|}"
                _upa_pct="${_upa_state%%|*}"
                _upa_ceil="${_upa_rest%%|*}"; _upa_rest="${_upa_rest#*|}"
                _upa_secs="${_upa_rest%%|*}"; _upa_rest="${_upa_rest#*|}"
                _upa_t0="${_upa_rest%%|*}"
                _upa_label="${_upa_rest#*|}"
                _upa_at="$(ui_progress_creep "$_upa_pct" "$_upa_ceil" \
                    "$_upa_secs" "$(( _upa_now - _upa_t0 ))")"
                # The bar never walks backwards. A milestone can arrive BELOW
                # where the creep has already reached (the launcher emits
                # "starting deployment" twenty seconds into a segment whose
                # ceiling is higher); the new segment is adopted, the position is
                # not given up.
                [ "$_upa_at" -lt "$_upa_shown" ] && _upa_at="$_upa_shown"
                _upa_shown="$_upa_at"
                ui_progress_line "$_upa_at" "$_upa_label" \
                    "$(( _upa_now - $2 ))" "$_upa_frame" "$_upa_cols"
                _upa_frame=$(( _upa_frame + 1 ))
                ;;
        esac
        sleep 0.2
    done
}

# --- driving the bar --------------------------------------------------------
# The animator reads its position from a FILE, because the thing doing the work
# usually cannot reach the animator's variables: a pipeline's right-hand side, a
# subshell, a loop whose output is captured. One short line, rewritten whenever
# the job reaches a new stage:
#
#   pct|ceiling|seconds|segment-start|phase
#
# pct is where the job actually is, ceiling is where the NEXT stage sits, and
# seconds is how long this stage usually takes -- which is what lets the bar
# keep moving between the two without ever claiming the next stage. See
# ui_progress_creep.

# ui_progress_state <file> <pct> <ceiling> <seconds> <phase> — the job has
# reached a new stage. The segment's own clock starts now.
ui_progress_state() {
    printf '%s|%s|%s|%s|%s\n' "$2" "$3" "$4" \
        "$(date +%s 2>/dev/null || echo 0)" "$5" > "$1"
}

# ui_progress_begin <file> <t0> — start painting, in the UI layer's single
# animation slot (_UI_SPIN_PID), so the installer's existing EXIT trap stops it
# and gives the cursor back if the run is interrupted or dies mid-job.
#
# Live only on an interactive fancy terminal, checked HERE rather than at load
# time so a redrawing line can never leak into a capture or a log. Returns 1 when
# it did not start, which is the caller's cue to narrate in plain lines instead.
ui_progress_begin() {
    [ "${UI_FANCY:-0}" = 1 ] || return 1
    [ -t 1 ] || return 1
    # A table owns the line: this bar would be a SECOND animator painting up to
    # 121 columns over the table's own rows. Refuse, and let the caller narrate
    # through its table row (or in plain lines) instead. Checked before the pid,
    # because a detached subshell has no pid to look at.
    [ -n "${_UI_LINE_BUSY:-}" ] && return 1
    # Same single-animation rule as ui_table_begin: whatever is animating now is
    # about to have its pid overwritten, and would print over this bar forever.
    if [ -n "${_UI_SPIN_PID:-}" ]; then
        _UI_SPIN_NESTED=0
        _ui_step_stop_spinner
    fi
    printf '\033[?25l'
    ui_progress_animate "$1" "$2" &
    _UI_SPIN_PID=$!
    _UI_SPIN_OWNER="$$"
    # Out of the job table right away, or bash ANNOUNCES the kill: killing a
    # tracked background job prints "line N: 12345 Terminated: 15 ( ... )" —
    # several lines of the loop's own source — straight into the middle of the
    # frame it was drawing. Every redraw here was already correct; that message
    # was the thing wrecking the screen, and it comes from the shell, not from
    # anything this file printed. dash_server_validate disowns its probe server
    # for exactly the same reason.
    disown 2>/dev/null || true
    return 0
}

# ui_progress_phase <file> <phase> — change the words without touching the
# position or restarting the segment's clock. For a stage that reports what it
# has finished while the bar keeps creeping on its own (concurrent uploads
# landing one by one). ⇄ twin: Set-ExakitProgressPhase in ui.ps1.
ui_progress_phase() {
    _upp_state=""
    read -r _upp_state < "$1" 2>/dev/null || return 0
    case "$_upp_state" in
        *"|"*"|"*"|"*"|"*)
            printf '%s|%s\n' "$(printf '%s' "$_upp_state" | cut -d'|' -f1-4)" "$2" > "$1"
            ;;
    esac
}

# ui_progress_end — stop it and clear the line. Same call as ui_spin_end; named
# for symmetry so a caller never has to know which of the two it started.
ui_progress_end() { ui_spin_end; }

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

# ui_bar <pct> [width] — the bar on its own, as a STRING.
#
# ui_progress above owns a whole line and redraws it. This one owns nothing: it
# is for embedding a bar inside a label somebody else paints — the dataset load
# hands it to run_logged's spinner, so the animation, the bar, the percentage
# and the current file are one line instead of four competing for it.
# ⇄ twin: Get-ExakitBar in ui.ps1.
ui_bar() {
    _uib_w="${2:-20}"
    _uib_filled=$(( $1 * _uib_w / 100 ))
    [ "$_uib_filled" -gt "$_uib_w" ] && _uib_filled="$_uib_w"
    [ "$_uib_filled" -lt 0 ] && _uib_filled=0
    printf '%s%s%s%s%s' \
        "${UI_ACCENT:-}" "$(ui_repeat "${UI_BAR_FULL:-#}" "$_uib_filled")" \
        "${UI_DIM:-}" "$(ui_repeat "${UI_BAR_EMPTY:-.}" $((_uib_w - _uib_filled)))" \
        "${UI_RESET:-}"
}

# --- the live table ----------------------------------------------------------
# One table that is both the menu and the progress display: you tick rows in it,
# it fills its Status column in place as the work runs, and what is left on
# screen at the end is the record of what happened. Nothing scrolls past.
#
# Every row's state lives in ONE FILE, one line per row, because the thing doing
# the work usually cannot reach the drawing code's variables — a pipeline's
# right-hand side, a subshell, a background animator. The line is:
#
#   <kind>|<label>|<tick>|<state>|<pct>|<ceiling>|<secs>|<segment-start>|<phase>|<final>|<col2>|<col3>
#
#   kind    group | tee | corner | plain   — the tree connector to draw
#   tick    1 while the row is selected
#   state   idle | waiting | running | done | failed | disabled
#   final   what the Status column says once the row is finished
#   col2    the second column's cell, drawn only when UI_TABLE_COL2 names one
#   col3    the third column's cell, drawn only when UI_TABLE_COL3 names one
#
# col2/col3 are OPTIONAL and were added after the fact, which is why they are
# last: `read` with IFS='|' fills missing trailing fields with the empty string,
# so every row written in the old ten-field shape still parses, and a table that
# names no extra headings draws exactly what it drew before. The rewriters below
# read all twelve for the same reason -- reading ten would fold "final|col2|col3"
# into the final cell, because the last variable takes the whole remainder.
#
# A "disabled" row is one the reader can look at but never pick — an AI client
# that is not installed on this machine. It is drawn by ui_table_frame itself
# (dim, no checkbox, its note reading on from the label) and never reaches
# _ui_table_cell, because it has no Status of its own to report. See
# ui_table_disable.
#
# The redraw is the same one ui_checkbox_menu has always used: count the lines
# the last frame REALLY occupied (a wrapped row is two), go up by that many, and
# clear from there. Anything else stacks stale rows with every keypress.

UI_TABLE_LINES=0
UI_TABLE_INNER=0
_UI_TABLE_PREV_INNER=''
UI_TABLE_NAME_W=0
UI_TABLE_STAT_W=0
UI_TABLE_COL2_W=0
UI_TABLE_COL3_W=0

# UI_TABLE_COL3_FIXED — the Description column's width, FIXED rather than
# measured. Measured, it would size to the longest About and change the table's
# width whenever a fetch landed a longer one; fixed, the same description reads
# the same here as it does in `exakit help`, which wraps to the same 44.
UI_TABLE_COL3_FIXED="${UI_TABLE_COL3_FIXED:-44}"

# UI_TABLE_COL3_MAX — how wide the Description may GROW into slack the terminal
# has going spare. The Status column reserves a 44-column floor for statuses
# that only arrive once rows finish, so on a wide terminal the selection screen
# showed a 44-wide description wrapped to five lines next to an empty 44-wide
# column: a wall of text beside a void. Growing the description into the slack
# spends that width on the only cell that has anything to say yet.
#
# Capped rather than uncapped: past about 90 columns a line of prose stops being
# easy to track back to the next one, and the box would grow to whatever width
# the terminal happens to be. Still FIXED for the life of the menu -- it is
# derived from the terminal width, which is measured once -- so a row's height
# cannot change under the animator.
UI_TABLE_COL3_MAX="${UI_TABLE_COL3_MAX:-90}"

# _UI_TABLE_SEP / _UI_TABLE_SEP_W — the rule drawn between columns, and how wide
# it reads. Only a table with extra columns gets them: the dataset and AI-client
# menus are a name and a status, where a rule between two columns is furniture
# around nothing. Set per frame by ui_table_frame.
_UI_TABLE_SEP=""
_UI_TABLE_SEP_W=2

# _ui_wrap <text> <width> — greedy word wrap into the _UI_WRAP array, with the
# count in _UI_WRAP_N. Pure parameter expansion: this runs for every wrapping
# cell of every frame, five frames a second, and a fork in here is the 223 ms
# that made the screen sit blank (see the note above _ui_table_cell).
#
# A word longer than the cell is BROKEN, not allowed to overhang. That is the
# one place this differs from exakit_about_wrap, which prints into open space
# where an overhang costs nothing; here it would print straight through the
# table's right border.
_ui_wrap() {
    _UI_WRAP=(); _UI_WRAP_N=0
    _uw_w="$2"
    [ "$_uw_w" -gt 0 ] || return 0
    [ -n "$1" ] || return 0
    # Globbing off while the text is split on whitespace: an About containing a
    # bare * would otherwise expand to the contents of the working directory.
    set -f
    # shellcheck disable=SC2086 — deliberate word splitting, that is the split.
    set -- $1
    _uw_line=""
    for _uw_word do
        # Longer than the whole cell: emit it in cell-wide pieces.
        while [ "${#_uw_word}" -gt "$_uw_w" ]; do
            [ -n "$_uw_line" ] && {
                _UI_WRAP[$_UI_WRAP_N]="$_uw_line"; _UI_WRAP_N=$(( _UI_WRAP_N + 1 )); _uw_line=""
            }
            _UI_WRAP[$_UI_WRAP_N]="${_uw_word:0:$_uw_w}"; _UI_WRAP_N=$(( _UI_WRAP_N + 1 ))
            _uw_word="${_uw_word:$_uw_w}"
        done
        if [ -z "$_uw_line" ]; then
            _uw_line="$_uw_word"
        elif [ $(( ${#_uw_line} + 1 + ${#_uw_word} )) -le "$_uw_w" ]; then
            _uw_line="$_uw_line $_uw_word"
        else
            _UI_WRAP[$_UI_WRAP_N]="$_uw_line"; _UI_WRAP_N=$(( _UI_WRAP_N + 1 ))
            _uw_line="$_uw_word"
        fi
    done
    [ -n "$_uw_line" ] && { _UI_WRAP[$_UI_WRAP_N]="$_uw_line"; _UI_WRAP_N=$(( _UI_WRAP_N + 1 )); }
    set +f
    return 0
}

# ui_table_widths <state-file> — how wide the two columns want to be, capped to
# what the terminal has. The name column is the widest label, the status column
# is the widest finished status, and neither is allowed to push the table past
# the screen: the name gives way first, because a truncated label is still
# recognisable while a truncated row count is a lie.
ui_table_widths() {
    # Measured once per frame, not per row: _ui_term_cols forks stty or tput.
    _utw_cols="${_UI_TABLE_COLS:-}"
    if [ -z "$_utw_cols" ]; then
        _utw_cols="$(_ui_term_cols 2>/dev/null || echo 80)"
        _UI_TABLE_COLS="$_utw_cols"
    fi
    UI_TABLE_NAME_W=10
    # A FLOOR, not a starting guess. The status column is measured from the
    # finished statuses, and while the work is still running there are none — so
    # a column sized to what it holds today would be twenty wide during the load
    # and forty when it finished, and the whole table would change width as the
    # last row completed. Wide enough for a bar worth looking at, and for
    # "completed · 8 tables, 173,745 rows (23s)".
    # The FLOOR is only reserved once the table has something to report. While
    # every row is still idle -- the selection screen, before a single install
    # has started -- there is no status to hold room for, and holding it anyway
    # put a 44-column void beside a description squeezed to fit around it.
    #
    # It is still a floor and not a measurement for the whole of the run that
    # follows: the moment the first row leaves idle the column appears at its
    # full width and stays there, so it does not grow from twenty to forty as
    # the last row finishes. The one width change is at the selection/progress
    # boundary, which ui_table_redraw already handles by clearing first -- and
    # where the table SHOULD look different, because it is doing a different job.
    # Only a table with OTHER columns may drop it. A name-and-status menu has
    # nothing else to carry the width: withhold Status there and the box shrinks
    # to barely wider than the longest name, then doubles the moment the first
    # row starts. The marketplace table has a description holding the width
    # either way, so the column can come and go without the box lurching.
    UI_TABLE_STAT_W="${UI_TABLE_STAT_MIN:-44}"
    if [ -n "${UI_TABLE_COL2:-}" ] || [ -n "${UI_TABLE_COL3:-}" ]; then
        UI_TABLE_STAT_W=0
        while IFS='|' read -r _utw_k _utw_l _utw_t _utw_st _utw_rest2; do
            case "$_utw_st" in
                ''|idle|disabled) ;;
                *) UI_TABLE_STAT_W="${UI_TABLE_STAT_MIN:-44}"; break ;;
            esac
        done < "$1"
    fi
    # Zero unless a heading names the column, so a table that asks for neither
    # is measured, and drawn, exactly as it was before they existed.
    UI_TABLE_COL2_W=0; UI_TABLE_COL3_W=0
    [ -n "${UI_TABLE_COL2:-}" ] && UI_TABLE_COL2_W="${#UI_TABLE_COL2}"
    # FIXED, never measured: the Description column wraps to fill it rather than
    # growing to fit the longest About.
    [ -n "${UI_TABLE_COL3:-}" ] && UI_TABLE_COL3_W="${UI_TABLE_COL3_FIXED:-44}"
    while IFS='|' read -r _utw_kind _utw_label _utw_tick _utw_state _utw_pct \
                          _utw_ceil _utw_secs _utw_t0 _utw_phase _utw_final \
                          _utw_c2 _utw_c3; do
        [ -n "$_utw_kind" ] || continue
        case "$_utw_kind" in tee|corner) _utw_len=$(( ${#_utw_label} + 3 )) ;; *) _utw_len="${#_utw_label}" ;; esac
        [ "$_utw_len" -gt "$UI_TABLE_NAME_W" ] && UI_TABLE_NAME_W="$_utw_len"
        if [ "$UI_TABLE_COL2_W" -gt 0 ] && [ "${#_utw_c2}" -gt "$UI_TABLE_COL2_W" ]; then
            UI_TABLE_COL2_W="${#_utw_c2}"
        fi
        # Measured the way _ui_table_cell RENDERS it, not as stored: a finished
        # cell is "<tick> <final>", so a column sized to the bare string is short
        # by the glyph and its space -- and the plain palette's tick is "[ok]",
        # four columns, not one. Short here means a row wider than the box, which
        # wraps, which makes the frame one line taller than the cursor
        # arithmetic believes.
        # Only for a row that HAS a status; an idle row's final is empty and
        # measuring it would reintroduce the column the check above just
        # withheld.
        case "$_utw_state" in
            ''|idle|disabled) ;;
            *)
                _utw_flen=$(( ${#_utw_final} + ${#UI_TICK} + 1 ))
                [ "$_utw_flen" -gt "$UI_TABLE_STAT_W" ] && UI_TABLE_STAT_W="$_utw_flen"
                ;;
        esac
    done < "$1"
    # 2 border + 1 space + 4 checkbox + name + 2 gap + status + 1 space + 1 border
    # = 11, PLUS the two-column left margin ui_table_frame prints every row with
    # and one column left unwritten at the right. The margin was missing here,
    # so a table sized to fit "exactly" printed two columns wider than the
    # terminal: the last column got written, which sets the pending-wrap flag,
    # and the next newline landed a row lower. The frame was then one line taller
    # than the height the animator moves the cursor up by, which strands the
    # previous frame's top border on screen until a later frame re-syncs -- a
    # table that flickers into two and heals itself a second later. The one-line
    # progress bar reserves its last column for the same reason.
    # Columns are separated by a plain two-space gap, whatever they hold. A
    # drawn rule between them was tried here and taken out: alignment already
    # tells the eye where a column starts, and the ONE vertical the table needs
    # is the tree spine in the name column, which is a different line entirely.
    _utw_sepw=2
    # ONE decomposition, and the same one ui_table_frame uses: the fixed chrome,
    # the name, then every column that follows preceded by its gap. Written as
    # "11 + name + status" with the gap folded into the 11, an extra column had
    # to add its gap AND unpick that fold -- which is how the no-extras table
    # came out two columns wider than it had been.
    #
    # 9 is the chrome without that fold: 2 border + 1 space + 4 checkbox + 1
    # space + 1 border. 3 is the two-column left margin every row is drawn with
    # plus the one column left unwritten at the right.
    _utw_statsep=0
    [ "$UI_TABLE_STAT_W" -gt 0 ] && _utw_statsep="$_utw_sepw"
    _utw_total=$(( 9 + UI_TABLE_NAME_W + 3 ))
    [ "$UI_TABLE_COL2_W" -gt 0 ] && _utw_total=$(( _utw_total + _utw_sepw + UI_TABLE_COL2_W ))
    [ "$UI_TABLE_COL3_W" -gt 0 ] && _utw_total=$(( _utw_total + _utw_sepw + UI_TABLE_COL3_W ))
    _utw_total=$(( _utw_total + _utw_statsep + UI_TABLE_STAT_W ))
    _utw_over=$(( _utw_total - _utw_cols ))
    # Slack, not overflow: spend it on the Description rather than leave it as a
    # gap beside an empty Status column. Bounded by UI_TABLE_COL3_MAX, and
    # derived from a terminal width measured once per frame set, so the wrap it
    # produces is the same on every redraw.
    if [ "$_utw_over" -lt 0 ] && [ "$UI_TABLE_COL3_W" -gt 0 ]; then
        _utw_slack=$(( -_utw_over ))
        _utw_grow=$(( UI_TABLE_COL3_MAX - UI_TABLE_COL3_W ))
        [ "$_utw_grow" -lt 0 ] && _utw_grow=0
        [ "$_utw_slack" -lt "$_utw_grow" ] && _utw_grow="$_utw_slack"
        UI_TABLE_COL3_W=$(( UI_TABLE_COL3_W + _utw_grow ))
        _utw_over=$(( _utw_over + _utw_grow ))
    fi
    # The description gives way FIRST, and can give way entirely. It is the one
    # cell whose absence costs nothing that is not recoverable -- `exakit help
    # <add-on>` is one command away -- while a truncated add-on id is a name the
    # reader cannot match to anything and a squeezed bar stops reading as
    # progress. On an 80-column terminal this column is the first thing to go,
    # which is the intended outcome, not a failure of the layout.
    if [ "$_utw_over" -gt 0 ] && [ "$UI_TABLE_COL3_W" -gt 0 ]; then
        if [ "$_utw_over" -ge "$(( UI_TABLE_COL3_W + 2 ))" ]; then
            _utw_over=$(( _utw_over - UI_TABLE_COL3_W - 2 ))
            UI_TABLE_COL3_W=0
        else
            UI_TABLE_COL3_W=$(( UI_TABLE_COL3_W - _utw_over ))
            _utw_over=0
            [ "$UI_TABLE_COL3_W" -ge 8 ] || { _utw_over=$(( 8 - UI_TABLE_COL3_W )); UI_TABLE_COL3_W=8; }
        fi
    fi
    if [ "$_utw_over" -gt 0 ]; then
        UI_TABLE_NAME_W=$(( UI_TABLE_NAME_W - _utw_over ))
        if [ "$UI_TABLE_NAME_W" -lt 12 ]; then
            # The name column has given all it can. Take the rest off the status
            # column rather than overflow: a narrow bar still reads, a wrapped
            # row does not.
            _utw_over=$(( 12 - UI_TABLE_NAME_W ))
            UI_TABLE_NAME_W=12
            UI_TABLE_STAT_W=$(( UI_TABLE_STAT_W - _utw_over ))
            [ "$UI_TABLE_STAT_W" -ge 12 ] || UI_TABLE_STAT_W=12
        fi
    fi
    return 0
}

# --- building a frame without forking ----------------------------------------
# Every string here is one the table itself assembled, so its width is KNOWN and
# never has to be measured. That matters more than it sounds: _ui_visible_len
# runs a sed, and measuring three cells a row cost 223 ms a frame — the screen
# was cleared and then sat blank for a quarter of a second before anything
# appeared, which is exactly what flickering is. Assembled arithmetically it is
# a couple of milliseconds, and the whole frame goes out in one write.
#
# bash counts CHARACTERS in ${#s} under a UTF-8 locale, not bytes ("├─ x" is 4,
# not 8), so plain text can be measured with the shell alone. Colour is the only
# thing ${#} would get wrong, and the table is the one adding it.
_UI_TABLE_SP=""
_ui_table_prep() {
    [ -n "$_UI_TABLE_SP" ] && return 0
    _utp_i=0
    while [ "$_utp_i" -lt 240 ]; do
        _UI_TABLE_SP="$_UI_TABLE_SP "
        _UI_TABLE_FULL="${_UI_TABLE_FULL:-}${UI_BAR_FULL:-#}"
        _UI_TABLE_EMPTY="${_UI_TABLE_EMPTY:-}${UI_BAR_EMPTY:-.}"
        _UI_TABLE_HR="${_UI_TABLE_HR:-}${UI_HR:--}"
        _utp_i=$(( _utp_i + 1 ))
    done
    return 0
}

# _ui_table_cell <state> <pct> <ceiling> <secs> <segt0> <phase> <final> <now>
# Sets UI_TABLE_CELL / _LEN — the text and how wide it reads, because only the
# builder can tell them apart once colour is in.
#
# ONE line per row. A running row used to get a second line underneath carrying
# the phase on the left and an elapsed "(Ns)" on the right; it is gone, and with
# it the reserved blank line that kept the frame a constant height while no row
# was running. The bar still creeps with the clock (see ui_progress_creep), so
# the row goes on saying "alive" without a counter to read it off.
_ui_table_cell() {
    _utc_num=7
    _utc_barw=$(( UI_TABLE_STAT_W - _utc_num ))
    [ "$_utc_barw" -ge 8 ] || _utc_barw=8
    UI_TABLE_CELL=""; UI_TABLE_CELL_LEN=0
    case "$1" in
        running)
            # The creep, inline: where the bar sits between the stage the job
            # last reported and the one it will report next.
            _utc_at="$2"
            _utc_span=$(( $3 - $2 ))
            if [ "$_utc_span" -gt 0 ] && [ "$4" -gt 0 ]; then
                _utc_step=$(( _utc_span * ($8 - $5) / $4 ))
                [ "$_utc_step" -gt $(( _utc_span - 1 )) ] && _utc_step=$(( _utc_span - 1 ))
                [ "$_utc_step" -lt 0 ] && _utc_step=0
                _utc_at=$(( $2 + _utc_step ))
            fi
            [ "$_utc_at" -gt 100 ] && _utc_at=100
            _utc_units=$(( _utc_at * _utc_barw * 8 / 100 ))
            _utc_full=$(( _utc_units / 8 ))
            _utc_rem=$(( _utc_units % 8 ))
            [ "$_utc_full" -gt "$_utc_barw" ] && { _utc_full="$_utc_barw"; _utc_rem=0; }
            _utc_head=""
            if [ "${UI_FANCY:-0}" = 1 ] && [ "$_utc_full" -lt "$_utc_barw" ] && [ "$_utc_rem" -gt 0 ]; then
                _utc_head="${UI_PROGRESS_EIGHTHS:$_utc_rem:1}"
                _utc_empty=$(( _utc_barw - _utc_full - 1 ))
            else
                _utc_empty=$(( _utc_barw - _utc_full ))
            fi
            [ "$_utc_empty" -ge 0 ] || _utc_empty=0
            _utc_pct="${_utc_at}%"
            _utc_npad=$(( _utc_num - ${#_utc_pct} )); [ "$_utc_npad" -ge 0 ] || _utc_npad=0
            UI_TABLE_CELL="${UI_ACCENT:-}${_UI_TABLE_FULL:0:$_utc_full}${UI_DIM:-}${_utc_head}${_UI_TABLE_EMPTY:0:$_utc_empty}${UI_RESET:-}${_UI_TABLE_SP:0:$_utc_npad}${_utc_pct}"
            UI_TABLE_CELL_LEN=$(( _utc_barw + _utc_num ))
            ;;
        waiting)
            UI_TABLE_CELL="${UI_DIM:-}waiting${UI_RESET:-}"; UI_TABLE_CELL_LEN=7 ;;
        done)
            UI_TABLE_CELL="${UI_OK:-}${UI_TICK:-[ok]}${UI_RESET:-} $7"
            UI_TABLE_CELL_LEN=$(( ${#UI_TICK} + 1 + ${#7} )) ;;
        failed)
            UI_TABLE_CELL="${UI_ERR:-}${UI_CROSS:-[x]}${UI_RESET:-} $7"
            UI_TABLE_CELL_LEN=$(( ${#UI_CROSS} + 1 + ${#7} )) ;;
        disabled)
            # No glyph: this is not an outcome of anything that ran, it is a
            # standing fact about the row. Dim, like the name beside it.
            #
            # ONLY when a Status column exists. A disabled row does not count as
            # a status for width purposes -- that is what lets the selection
            # screen drop the column entirely -- so filling the cell anyway drew
            # text into a column of width zero and pushed the row past its own
            # border. On that screen the same word is in the Description column.
            if [ "${UI_TABLE_STAT_W:-0}" -gt 0 ]; then
                UI_TABLE_CELL="${UI_DIM:-}$7${UI_RESET:-}"
                UI_TABLE_CELL_LEN=${#7}
            fi ;;
    esac
    return 0
}

# ui_table_frame <state-file> <cursor> — the whole table, as a STRING in
# UI_TABLE_FRAME, with its height in UI_TABLE_LINES. One write is what keeps a
# redraw from flickering, and a string is what lets the caller do the clear and
# the draw in that one write.
ui_table_frame() {
    _ui_table_prep
    ui_table_widths "$1"
    # A plain gap between columns. Rules were drawn here once and removed: they
    # boxed every wrapped description into a cage, and they competed with the
    # one line that carries meaning -- the tree spine down the name column.
    _UI_TABLE_SEP="  "
    _UI_TABLE_SEP_W=2

    # No Status column at all while nothing has a status: no heading, no rule,
    # no reserved width. _utr_statsep is the rule before it, which goes with it.
    _utr_statsep=""
    _utr_statsep_w=0
    if [ "$UI_TABLE_STAT_W" -gt 0 ]; then
        _utr_statsep="$_UI_TABLE_SEP"
        _utr_statsep_w="$_UI_TABLE_SEP_W"
    fi
    # The same decomposition ui_table_widths uses: 5 of chrome, the name, then
    # every column that follows preceded by its rule, and one trailing column.
    _utr_inner=$(( 5 + UI_TABLE_NAME_W + 1 ))
    [ "$UI_TABLE_COL2_W" -gt 0 ] && _utr_inner=$(( _utr_inner + _UI_TABLE_SEP_W + UI_TABLE_COL2_W ))
    [ "$UI_TABLE_COL3_W" -gt 0 ] && _utr_inner=$(( _utr_inner + _UI_TABLE_SEP_W + UI_TABLE_COL3_W ))
    _utr_inner=$(( _utr_inner + _utr_statsep_w + UI_TABLE_STAT_W ))
    _utr_title=" ${UI_TABLE_TITLE:-Progress} "
    _utr_fill=$(( _utr_inner - ${#_utr_title} - 1 ))
    [ "$_utr_fill" -ge 0 ] || _utr_fill=0
    _utr_f="  ${UI_ACCENT:-}${UI_TL:-+}${UI_HR:--}${UI_RESET:-}${UI_BOLD:-}${_utr_title}${UI_RESET:-}${UI_ACCENT:-}${_UI_TABLE_HR:0:$_utr_fill}${UI_TR:-+}${UI_RESET:-}
"
    # The first column is named by its caller: the dataset load fills it with
    # datasets, the MCP step with AI clients. Its width is UI_TABLE_NAME_W,
    # whose floor is 10, so any short heading pads without going negative.
    _utr_col1="${UI_TABLE_COL1:-Dataset}"
    _utr_head="     ${_utr_col1}${_UI_TABLE_SP:0:$(( UI_TABLE_NAME_W - ${#_utr_col1} ))}"
    # Headings are clamped the same way their cells are, so a column squeezed by
    # a narrow terminal never prints a heading wider than the column under it.
    _utr_headlen=$(( 5 + UI_TABLE_NAME_W ))
    if [ "$UI_TABLE_COL2_W" -gt 0 ]; then
        _utr_h2="${UI_TABLE_COL2:0:$UI_TABLE_COL2_W}"
        _utr_head="$_utr_head${_UI_TABLE_SEP}${_utr_h2}${_UI_TABLE_SP:0:$(( UI_TABLE_COL2_W - ${#_utr_h2} ))}"
        _utr_headlen=$(( _utr_headlen + _UI_TABLE_SEP_W + UI_TABLE_COL2_W ))
    fi
    if [ "$UI_TABLE_COL3_W" -gt 0 ]; then
        _utr_h3="${UI_TABLE_COL3:0:$UI_TABLE_COL3_W}"
        _utr_head="$_utr_head${_UI_TABLE_SEP}${_utr_h3}${_UI_TABLE_SP:0:$(( UI_TABLE_COL3_W - ${#_utr_h3} ))}"
        _utr_headlen=$(( _utr_headlen + _UI_TABLE_SEP_W + UI_TABLE_COL3_W ))
    fi
    if [ "$UI_TABLE_STAT_W" -gt 0 ]; then
        _utr_head="$_utr_head${_utr_statsep}Status"
        _utr_headlen=$(( _utr_headlen + _utr_statsep_w + 6 ))
    fi
    # Padded from the LENGTH COUNTED ABOVE, never from ${#_utr_head}: the rules
    # carry colour escapes, so the string is bytes longer than it reads.
    _utr_f="$_utr_f  ${UI_ACCENT:-}${UI_VB:-|}${UI_RESET:-}${_utr_head}${_UI_TABLE_SP:0:$(( _utr_inner - _utr_headlen ))}${UI_ACCENT:-}${UI_VB:-|}${UI_RESET:-}
"
    _utr_lines=2
    _utr_now="$(date +%s 2>/dev/null || echo 0)"
    _utr_i=0
    while IFS='|' read -r _utr_kind _utr_label _utr_tick _utr_state _utr_pct \
                          _utr_ceil _utr_secs _utr_t0 _utr_phase _utr_final \
                          _utr_c2 _utr_c3; do
        [ -n "$_utr_kind" ] || continue
        _utr_i=$(( _utr_i + 1 ))
        case "$_utr_kind" in
            tee)    _utr_conn="${UI_TEE:-|-} "; _utr_spine=1 ;;
            corner) _utr_conn="${UI_CORNER:-\`-} "; _utr_spine=0 ;;
            *)      _utr_conn=""; _utr_spine=0 ;;
        esac
        # A row nobody can pick: no checkbox at all, because an empty one
        # invites the reader to try. It keeps its COLUMNS though. It used to
        # merge into one sentence -- "json-tables · Installed (0.2)" -- which
        # put a version in the middle of a name while the Version column beside
        # it sat empty, and left the Status column with nothing to say about the
        # one row whose status was already known. The 5-space indent is the
        # width of the pointer and checkbox it replaces, so the tree connectors
        # still line up.
        if [ "$_utr_state" = "disabled" ]; then
            # Three spaces, the width of "[ ]": with two the tree connector
            # sat a column left of every pickable row above it.
            _utr_ptr=" "; _utr_box="   "; _utr_boxlen=3
        elif [ "$_utr_tick" = "1" ]; then
            # A plain "x", not the palette tick, when there is no colour: the
            # plain-palette UI_TICK is the multi-character "[ok]", and a checkbox
            # is already brackets — together they read "[[ok]]".
            # ui_checkbox_menu makes the same substitution for the same reason.
            if [ "${UI_FANCY:-0}" = 1 ]; then _utr_mark="${UI_TICK:-x}"; else _utr_mark="x"; fi
            _utr_box="${UI_OK:-}[${_utr_mark}]${UI_RESET:-}"
            _utr_boxlen=$(( 2 + ${#_utr_mark} ))
        else
            _utr_box="[ ]"; _utr_boxlen=3
        fi
        if [ "$_utr_i" = "$2" ]; then
            if [ "${UI_FANCY:-0}" = 1 ]; then _utr_ptr="${UI_ACCENT:-}❯${UI_RESET:-}"; else _utr_ptr=">"; fi
        else
            _utr_ptr=" "
        fi
        # MEASURED plain, PRINTED possibly dim: a disabled row's name carries
        # colour escapes, and ${#...} would count those bytes as width and pad
        # the row short by exactly the length of the escape sequence.
        _utr_plain="$_utr_conn$_utr_label"
        [ "${#_utr_plain}" -le "$UI_TABLE_NAME_W" ] || \
            _utr_plain="${_utr_plain:0:$(( UI_TABLE_NAME_W - 1 ))}…"
        _utr_namelen=${#_utr_plain}
        if [ "$_utr_state" = "disabled" ]; then
            _utr_name="${UI_DIM:-}${_utr_plain}${UI_RESET:-}"
        else
            _utr_name="$_utr_plain"
        fi
        _ui_table_cell "$_utr_state" "${_utr_pct:-0}" "${_utr_ceil:-0}" \
            "${_utr_secs:-0}" "${_utr_t0:-0}" "$_utr_phase" "$_utr_final" "$_utr_now"
        _utr_used=$(( 1 + _utr_boxlen + 1 + UI_TABLE_NAME_W + _utr_statsep_w + UI_TABLE_CELL_LEN ))
        # Clamped, never trusted. A negative length is a bash ERROR ("substring
        # expression < 0") printed straight into the frame, and the row then goes
        # out unpadded -- so a width miscalculation would show up as garbage on
        # screen instead of a border a column out of line.
        _utr_npad=$(( UI_TABLE_NAME_W - _utr_namelen )); [ "$_utr_npad" -ge 0 ] || _utr_npad=0
        # The optional cells, dim so the eye still lands on the name and the
        # status. Truncated to their own column, never measured with
        # _ui_visible_len: every string here is one this file assembled, so its
        # width is arithmetic rather than a sed per cell per frame.
        _utr_mid=""
        if [ "$UI_TABLE_COL2_W" -gt 0 ]; then
            _utr_v2="$_utr_c2"
            [ "${#_utr_v2}" -le "$UI_TABLE_COL2_W" ] || \
                _utr_v2="${_utr_v2:0:$(( UI_TABLE_COL2_W - 1 ))}…"
            _utr_mid="$_utr_mid${_UI_TABLE_SEP}${UI_DIM:-}${_utr_v2}${UI_RESET:-}${_UI_TABLE_SP:0:$(( UI_TABLE_COL2_W - ${#_utr_v2} ))}"
            _utr_used=$(( _utr_used + UI_TABLE_COL2_W + _UI_TABLE_SEP_W ))
        fi
        # The Description is never truncated. It wraps to as many lines as it
        # needs; the first sits on the row, the rest follow underneath with
        # every other cell blank, so the column stays a column. An About is
        # written for a repository page, and an ellipsis throws away the half
        # that says what the tool is for.
        _utr_wrapn=0
        if [ "$UI_TABLE_COL3_W" -gt 0 ]; then
            _ui_wrap "$_utr_c3" "$UI_TABLE_COL3_W"
            _utr_wrapn="$_UI_WRAP_N"
            _utr_v3=""
            [ "$_utr_wrapn" -gt 0 ] && _utr_v3="${_UI_WRAP[0]}"
            _utr_mid="$_utr_mid${_UI_TABLE_SEP}${UI_DIM:-}${_utr_v3}${UI_RESET:-}${_UI_TABLE_SP:0:$(( UI_TABLE_COL3_W - ${#_utr_v3} ))}"
            _utr_used=$(( _utr_used + UI_TABLE_COL3_W + _UI_TABLE_SEP_W ))
        fi
        _utr_rpad=$(( _utr_inner - _utr_used )); [ "$_utr_rpad" -ge 0 ] || _utr_rpad=0
        _utr_f="$_utr_f  ${UI_ACCENT:-}${UI_VB:-|}${UI_RESET:-}${_utr_ptr}${_utr_box} ${_utr_name}${_UI_TABLE_SP:0:$_utr_npad}${_utr_mid}${_utr_statsep}${UI_TABLE_CELL}${_UI_TABLE_SP:0:$_utr_rpad}${UI_ACCENT:-}${UI_VB:-|}${UI_RESET:-}
"
        _utr_lines=$(( _utr_lines + 1 ))
        # The rest of a wrapped description. Only the Description cell carries
        # anything: the checkbox, the name and the version belong to the row
        # above, and repeating them would read as more rows than there are.
        #
        # These lines make the frame taller than one line per row, which the
        # redraw can afford because the height is still the SAME on every
        # redraw: an About and the column it wraps to are both fixed for the
        # life of the menu, so a row's height cannot change under it. That is
        # exactly what the phase sub-line could not promise -- it appeared and
        # vanished as a row started and stopped running, which is why it needed
        # a reserved blank line and why it is gone.
        _utr_wi=1
        while [ "$_utr_wi" -lt "$_utr_wrapn" ]; do
            _utr_wl="${_UI_WRAP[$_utr_wi]}"
            # The TREE SPINE carries down the continuation lines. Without it the
            # connector column goes blank for as long as a description wraps, and
            # the line joining the add-ons snaps in half -- the same menu draws
            # an unbroken spine while it installs, where every row is one line,
            # so a description must not be what breaks it. Only a tee continues:
            # after the corner the tree has ended and a spine below it would
            # point at nothing. Built cell by cell and MEASURED as it goes, so
            # the width is arithmetic rather than a count of escape bytes.
            if [ "${_utr_spine:-0}" = 1 ]; then
                _utr_wleft="     ${UI_VB:-|}${_UI_TABLE_SP:0:$(( UI_TABLE_NAME_W - 1 ))}"
            else
                _utr_wleft="${_UI_TABLE_SP:0:$(( 5 + UI_TABLE_NAME_W ))}"
            fi
            _utr_wlen=$(( 5 + UI_TABLE_NAME_W ))
            if [ "$UI_TABLE_COL2_W" -gt 0 ]; then
                _utr_wleft="${_utr_wleft}${_UI_TABLE_SEP}${_UI_TABLE_SP:0:$UI_TABLE_COL2_W}"
                _utr_wlen=$(( _utr_wlen + _UI_TABLE_SEP_W + UI_TABLE_COL2_W ))
            fi
            _utr_wlen=$(( _utr_wlen + _UI_TABLE_SEP_W + UI_TABLE_COL3_W + _utr_statsep_w ))
            _utr_wpad=$(( _utr_inner - _utr_wlen ))
            [ "$_utr_wpad" -ge 0 ] || _utr_wpad=0
            _utr_f="$_utr_f  ${UI_ACCENT:-}${UI_VB:-|}${UI_RESET:-}${_utr_wleft}${_UI_TABLE_SEP}${UI_DIM:-}${_utr_wl}${UI_RESET:-}${_UI_TABLE_SP:0:$(( UI_TABLE_COL3_W - ${#_utr_wl} ))}${_utr_statsep}${_UI_TABLE_SP:0:$_utr_wpad}${UI_ACCENT:-}${UI_VB:-|}${UI_RESET:-}
"
            _utr_lines=$(( _utr_lines + 1 ))
            _utr_wi=$(( _utr_wi + 1 ))
        done
    done < "$1"
    # The frame is still ONE height in every state, and now structurally so
    # rather than by arrangement: every row is exactly one line whatever it is
    # doing, so there is nothing left to reserve. That property is what the
    # redraw depends on -- a frame that grows by a line pushes the terminal to
    # scroll, and once the screen has scrolled a cursor-up by the frame height
    # no longer lands at the frame's top. Every redraw after that is off by one
    # and the error accumulates, which is what left four lines of an old frame
    # stranded above the new one near the bottom of a screen.
    _utr_f="$_utr_f  ${UI_ACCENT:-}${UI_BL:-+}${_UI_TABLE_HR:0:$_utr_inner}${UI_BR:-+}${UI_RESET:-}"
    UI_TABLE_FRAME="$_utr_f"
    UI_TABLE_LINES=$(( _utr_lines + 1 ))
    # Reported so a redraw can tell whether the geometry moved. Same height and
    # same width means the frame can be overwritten in place; anything else has
    # old content to erase first.
    UI_TABLE_INNER="$_utr_inner"
    return 0
}

# ui_table_render <state-file> <cursor> — the frame, printed.
ui_table_render() {
    ui_table_frame "$1" "$2"
    printf '%s\n' "$UI_TABLE_FRAME"
    return 0
}

# ui_table_redraw <state-file> <cursor> — replace the frame already on screen
# with a new one, in ONE write. Clearing first and drawing after is what a
# reader sees as a flicker.
ui_table_redraw() {
    _utd_prev="${UI_TABLE_LINES:-0}"
    case "$_utd_prev" in ''|*[!0-9]*) _utd_prev=0 ;; esac
    ui_table_frame "$1" "$2"
    # The \r is not decoration. Cursor-up PRESERVES the column, so a cursor left
    # mid-row by anything that printed without a newline -- a spinner frame, a
    # progress line -- makes the whole frame draw from that column, and \033[0J
    # clears only from there rightwards. What is left on screen is the first N
    # columns of the old frame with a new one starting inside it: several top
    # borders side by side on one line, at different widths.
    if [ "$_utd_prev" -gt 0 ]; then
        # Overwritten in place, NOT cleared and redrawn. \033[0J erases from the
        # cursor to the end of the screen, and it lands before the new frame
        # does -- so there is a real instant with nothing there, which is the
        # flicker a reader sees as "something, empty, something". Every line is
        # already padded to the full box width, so when the geometry has not
        # moved an overwrite cannot leave anything stale behind. Redrawing FASTER
        # would only show that gap more often; not clearing removes it.
        if [ "$_utd_prev" = "$UI_TABLE_LINES" ] && \
           [ "${_UI_TABLE_PREV_INNER:-}" = "$UI_TABLE_INNER" ]; then
            printf '\r\033[%dA%s\n' "$_utd_prev" "$UI_TABLE_FRAME"
        else
            # The geometry moved -- a resize, or the first frame after the
            # selection menu. Now there IS old content to erase.
            printf '\r\033[%dA\033[0J%s\n' "$_utd_prev" "$UI_TABLE_FRAME"
        fi
    else
        printf '\r%s\n' "$UI_TABLE_FRAME"
    fi
    _UI_TABLE_PREV_INNER="$UI_TABLE_INNER"
    return 0
}


# ui_table_set <state-file> <row> <state> [pct] [ceiling] [secs] [phase] [final]
# — one row has changed. Rewrites the whole file because a row is a line and
# there is no seeking in a text file; it is six lines, once per stage.
ui_table_set() {
    _uts_f="$1"; _uts_row="$2"; _uts_state="$3"
    _uts_pct="${4:-}"; _uts_ceil="${5:-}"; _uts_secs="${6:-}"
    _uts_phase="${7:-}"; _uts_final="${8:-}"
    _uts_t0=""
    [ "$_uts_state" = "running" ] && _uts_t0="$(date +%s 2>/dev/null || echo 0)"
    _uts_tmp="$_uts_f.new"
    _uts_i=0
    while IFS='|' read -r _u1 _u2 _u3 _u4 _u5 _u6 _u7 _u8 _u9 _u10 _u11 _u12; do
        [ -n "$_u1" ] || continue
        _uts_i=$(( _uts_i + 1 ))
        if [ "$_uts_i" = "$_uts_row" ]; then
            # A row that was already running keeps its clock: a new PHASE inside
            # the same job must not restart the elapsed count the reader is
            # watching. Only entering "running" starts one.
            [ "$_u4" = "running" ] && [ "$_uts_state" = "running" ] && _uts_t0="$_u8"
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_u1" "$_u2" "$_u3" \
                "$_uts_state" "$_uts_pct" "$_uts_ceil" "$_uts_secs" "$_uts_t0" \
                "$_uts_phase" "$_uts_final" "$_u11" "$_u12"
        else
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_u1" "$_u2" "$_u3" "$_u4" \
                "$_u5" "$_u6" "$_u7" "$_u8" "$_u9" "$_u10" "$_u11" "$_u12"
        fi
    done < "$_uts_f" > "$_uts_tmp"
    mv -f "$_uts_tmp" "$_uts_f"
}

# ui_table_tick <state-file> <csv-of-selected-rows> — mark which rows are ticked.
ui_table_tick() {
    _utt_tmp="$1.new"
    _utt_i=0
    while IFS='|' read -r _u1 _u2 _u3 _u4 _u5 _u6 _u7 _u8 _u9 _u10 _u11 _u12; do
        [ -n "$_u1" ] || continue
        _utt_i=$(( _utt_i + 1 ))
        case ",$2," in *",$_utt_i,"*) _u3=1 ;; *) _u3=0 ;; esac
        # A disabled row can never carry a tick, whoever asked. Select All spans
        # a range that may contain one, and the defaults are built by the caller
        # — this is the one place both of those pass through.
        [ "$_u4" = "disabled" ] && _u3=0
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_u1" "$_u2" "$_u3" "$_u4" \
            "$_u5" "$_u6" "$_u7" "$_u8" "$_u9" "$_u10" "$_u11" "$_u12"
    done < "$1" > "$_utt_tmp"
    mv -f "$_utt_tmp" "$1"
}

# ui_table_disable <state-file> <row> <note> — that row can be read but never
# picked: drawn dim with no checkbox and the note reading on from the label
# ("Cursor · not installed"), skipped by the cursor, by Space and by Select All.
#
# It exists so a menu can show the WHOLE set of options and say why the ones it
# cannot offer are missing. The MCP client list is the case: a list that quietly
# omitted the clients this machine does not have would read as "the kit supports
# four clients", and the reader has no way to tell a short list from a filtered
# one. The note is the answer to the question the row raises.
ui_table_disable() {
    _utx_f="$1"; _utx_row="$2"; _utx_note="$3"
    _utx_tmp="$_utx_f.new"
    _utx_i=0
    while IFS='|' read -r _u1 _u2 _u3 _u4 _u5 _u6 _u7 _u8 _u9 _u10 _u11 _u12; do
        [ -n "$_u1" ] || continue
        _utx_i=$(( _utx_i + 1 ))
        if [ "$_utx_i" = "$_utx_row" ]; then
            # The note goes in the FINAL field: it is what this row has to say
            # for itself, which is exactly what that field is for.
            printf '%s|%s|0|disabled|%s|%s|%s|%s|%s|%s\n' "$_u1" "$_u2" \
                "$_u5" "$_u6" "$_u7" "$_u8" "$_u9" "$_utx_note"
        else
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$_u1" "$_u2" "$_u3" "$_u4" \
                "$_u5" "$_u6" "$_u7" "$_u8" "$_u9" "$_u10" "$_u11" "$_u12"
        fi
    done < "$_utx_f" > "$_utx_tmp"
    mv -f "$_utx_tmp" "$_utx_f"
}

# ui_table_begin <state-file> — animate the table in place. Returns 1 when it
# did not start (no terminal, no colour), which is the caller's cue to narrate
# in plain lines instead. Runs in the UI layer's single animation slot, so the
# installer's EXIT trap stops it and restores the cursor.
ui_table_begin() {
    [ "${UI_FANCY:-0}" = 1 ] || return 1
    [ -t 1 ] || return 1
    # ONE animation at a time. ui_spin_begin takes a nesting reference when
    # something is already animating; this did not, so a step spinner that was
    # still running had its pid overwritten here and became an orphan -- and an
    # orphaned spinner keeps printing "\r  <glyph> <label> (Ns)\033[K" forever,
    # leaving the cursor mid-row for the frame that follows. The table REPLACES
    # the step's narration, so the spinner is stopped rather than refused.
    # Set-ExakitTable's twin has always guarded this.
    if [ -n "${_UI_SPIN_PID:-}" ]; then
        _UI_SPIN_NESTED=0
        _ui_step_stop_spinner
    fi
    printf '\033[?25l'
    # How many lines are ALREADY on screen. The selection phase leaves its table
    # drawn, and the first frame has to overwrite it rather than print a second
    # one underneath.
    _utb_prev="${UI_TABLE_LINES:-0}"
    case "$_utb_prev" in ''|*[!0-9]*) _utb_prev=0 ;; esac
    rm -f "$1.stop"
    (
        UI_TABLE_LINES="$_utb_prev"
        while :; do
            # ONE frame, ONE write. Rendering straight to the terminal meant a
            # kill could land between two of a frame's rows: the cursor was then
            # part-way through a table nobody had finished, and the next thing to
            # move the cursor up by a frame height landed INSIDE the frame before
            # it and cleared from there — which left the top of a table stranded
            # on screen with the final one printed under it. Built as a string
            # first, the cursor is only ever at a frame boundary.
            ui_table_redraw "$1" 0
            # The parent cannot see a variable set in here, and it needs the
            # height to redraw the finished table over this one.
            printf '%s\n' "$UI_TABLE_LINES" > "$1.lines"
            # Asked to stop: finish the frame that is on screen and go, so the
            # parent inherits a cursor sitting at a frame boundary.
            [ -f "$1.stop" ] && exit 0
            sleep 0.2
        done
    ) &
    _UI_SPIN_PID=$!
    _UI_SPIN_OWNER="$$"
    # Who to stop if this shell goes down without calling ui_table_end. The CLI
    # sets no EXIT trap and die() exits where it stands, so without this the
    # animator outlives the command: an orphan whose next frame moves the cursor
    # up and clears, which ERASES the message that was just printed and repaints
    # the half-finished table over it. That is what "data-load has issues, with
    # no error shown" looks like from the outside.
    _UI_TABLE_ACTIVE="$1"
    _UI_LINE_BUSY=1
    trap 'ui_table_abort; exit 130' INT TERM
    [ -n "$(trap -p EXIT)" ] || trap 'ui_table_abort' EXIT
    # Out of the job table right away, or bash ANNOUNCES the kill: killing a
    # tracked background job prints "line N: 12345 Terminated: 15 ( ... )" —
    # several lines of the loop's own source — straight into the middle of the
    # frame it was drawing. Every redraw here was already correct; that message
    # was the thing wrecking the screen, and it comes from the shell, not from
    # anything this file printed. dash_server_validate disowns its probe server
    # for exactly the same reason.
    disown 2>/dev/null || true
    return 0
}

# ui_table_end <state-file> — stop animating and leave the FINAL table on
# screen. The animator can be killed part-way through a frame, so the last thing
# drawn is redrawn deliberately rather than trusted.
ui_table_end() {
    _UI_TABLE_ACTIVE=''
    _UI_LINE_BUSY=''
# Set while a table owns the terminal, and DELIBERATELY survives ui_table_detach:
# it is the one signal a subshell can still read to know it must not start an
# animation of its own. _UI_SPIN_PID cannot serve that purpose, because detach
# has to clear it (see ui_table_detach).
_UI_LINE_BUSY=''
    [ -n "${_UI_SPIN_PID:-}" ] || return 0
    # ASKED to stop, not shot. The animator finishes the frame it is drawing and
    # exits, which is the only way the cursor is guaranteed to be at a frame
    # boundary when this function starts counting lines. A kill is still the
    # backstop for an animator that has somehow wedged.
    : > "$1.stop"
    _ute_wait=0
    while [ "$_ute_wait" -lt 15 ] && kill -0 "$_UI_SPIN_PID" 2>/dev/null; do
        sleep 0.1
        _ute_wait=$(( _ute_wait + 1 ))
    done
    kill "$_UI_SPIN_PID" 2>/dev/null
    wait "$_UI_SPIN_PID" 2>/dev/null
    _UI_SPIN_PID=''
    _UI_SPIN_OWNER=''
    _UI_SPIN_NESTED=0
    printf '\033[?25h'
    _ute_lines="$(cat "$1.lines" 2>/dev/null || echo '')"
    case "$_ute_lines" in ''|*[!0-9]*) _ute_lines="${UI_TABLE_LINES:-0}" ;; esac
    case "$_ute_lines" in ''|*[!0-9]*) _ute_lines=0 ;; esac
    UI_TABLE_LINES="$_ute_lines"
    ui_table_redraw "$1" 0
    rm -f "$1.lines" "$1.stop"
    return 0
}

# ui_table_abort — stop a live table from anywhere that is not ui_table_end: a
# die(), a trap, a Ctrl-C. Leaves the FINAL frame on screen, so whatever is said
# next is said below a table instead of on top of one, and gives the cursor back.
# Safe to call when nothing is animating.
ui_table_abort() {
    [ -n "${_UI_TABLE_ACTIVE:-}" ] || return 0
    _uta_state="$_UI_TABLE_ACTIVE"
    _UI_TABLE_ACTIVE=''
    ui_table_end "$_uta_state"
    ui_restore_cursor
    return 0
}

# ui_table_detach — call this FIRST inside a subshell that does work while a
# table is animating. A subshell inherits both the animator's pid and the
# active-table handle, and bash never changes $$ in a subshell, so no guard can
# tell parent from child by pid. Without this, a die() inside the subshell would
# stop the PARENT's animation on its way out and every remaining row would load
# with a frozen table. Dropping the handles makes ui_animation_stop and
# ui_spin_end no-ops in here; row updates are unaffected because they travel
# through the state FILE, which is shared on purpose.
ui_table_detach() {
    _UI_TABLE_ACTIVE=''
    _UI_SPIN_PID=''
    _UI_SPIN_NESTED=0
    _UI_SPIN_OWNER=''
    # _UI_LINE_BUSY is NOT cleared. Dropping the pid is what stops this subshell
    # from ending the parent's animation -- but the pid is also the only thing
    # ui_spin_begin and ui_progress_begin looked at, so clearing it used to let
    # this subshell START one instead. The table is still on screen and still
    # being repainted by the parent; this flag is what says so.
    return 0
}

# ui_animation_stop — stop whatever this shell is animating, table or spinner,
# before printing something the reader must not lose. die() calls this first for
# exactly that reason.
ui_animation_stop() {
    if [ -n "${_UI_TABLE_ACTIVE:-}" ]; then
        ui_table_abort
    else
        ui_spin_end 2>/dev/null || true
    fi
    ui_restore_cursor
    return 0
}

# ui_table_menu <state-file> — the SELECTION phase of the same table: ticks are
# toggled in the rows the progress will later fill in, so the reader never has
# to map one screen onto another. Sets EXAKIT_TABLE_SELECTION to a csv of row
# numbers, or "none".
#
# The key handling is ui_checkbox_menu's, deliberately: same keys, same hint,
# same group and exclusive semantics, so there is one thing to learn.
#
# UI_TABLE_MENU_ONSCREEN (optional, cleared on use): how many lines of this
# table — frame plus anything printed under it — are ALREADY on screen, so a
# re-ask overwrites them instead of drawing a second table below them. The MCP
# step sets it when an unconfirmed "Skip" sends the reader back to the menu.
ui_table_menu() {
    _utm_f="$1"
    _utm_n=0
    # Which rows can be ticked at all. A disabled row is drawn but never
    # selectable: the cursor steps over it, Space ignores it, and Select All
    # leaves it alone — that last one through _UI_CHECKBOX_SELECTABLE, which the
    # group helpers already consult, so there is no second rule to keep in step.
    _utm_dis=""
    _UI_CHECKBOX_SELECTABLE=""
    while IFS='|' read -r _u1 _u2 _u3 _u4 _urest; do
        [ -n "$_u1" ] || continue
        _utm_n=$(( _utm_n + 1 ))
        if [ "$_u4" = "disabled" ]; then
            _utm_dis="$_utm_dis $_utm_n"
        else
            _UI_CHECKBOX_SELECTABLE="${_UI_CHECKBOX_SELECTABLE:+$_UI_CHECKBOX_SELECTABLE }$_utm_n"
        fi
    done < "$_utm_f"
    _utm_pickable() { # _utm_pickable <row>
        case " $_utm_dis " in *" $1 "*) return 1 ;; esac
        return 0
    }
    _utm_move() { # _utm_move <dir:+1|-1> — move the cursor, stepping over disabled rows
        _utm_tries=0
        while [ "$_utm_tries" -lt "$_utm_n" ]; do
            _utm_cur=$(( _utm_cur + $1 ))
            [ "$_utm_cur" -lt 1 ] && _utm_cur="$_utm_n"
            [ "$_utm_cur" -gt "$_utm_n" ] && _utm_cur=1
            _utm_pickable "$_utm_cur" && return 0
            _utm_tries=$(( _utm_tries + 1 ))
        done
        return 0
    }
    # Row 2 as before — past the group row — but never a row that cannot be
    # picked, or the first Space would land on one.
    _utm_cur=1
    [ "$_utm_n" -ge 2 ] && _utm_move 1
    _utm_pickable "$_utm_cur" || _utm_move 1
    _utm_sel="$EXAKIT_TABLE_DEFAULTS"
    # CONFIRMED means a human pressed Enter on this table - nothing else. The
    # defaults standing on a machine with no usable terminal is the right
    # answer for the data-load and MCP-client menus, whose callers documented
    # exactly that; a caller about to INSTALL things must be able to tell the
    # two apart, because "Enter alone installs what is on offer" is only a safe
    # posture while there is an Enter. See exakit_marketplace_menu.
    EXAKIT_TABLE_CONFIRMED=0
    _utm_tty="$(_exakit_prompt_tty)"
    if [ -z "$_utm_tty" ] || [ "${UI_FANCY:-0}" != 1 ]; then
        # No terminal: the defaults stand, and the table is printed once so a
        # log still shows what was chosen.
        ui_table_tick "$_utm_f" "$_utm_sel"
        ui_table_render "$_utm_f" 0
        EXAKIT_TABLE_SELECTION="${_utm_sel:-none}"
        _UI_CHECKBOX_SELECTABLE=""
        return 0
    fi
    _utm_first=1
    # Normally nothing of this table is on screen yet; a re-ask says otherwise.
    _utm_drawn="${UI_TABLE_MENU_ONSCREEN:-0}"
    case "$_utm_drawn" in ''|*[!0-9]*) _utm_drawn=0 ;; esac
    UI_TABLE_MENU_ONSCREEN=""
    while :; do
        ui_table_tick "$_utm_f" "$_utm_sel"
        # Built first, then clear and draw in ONE write. The old order — clear,
        # then spend a fifth of a second assembling — is what flickered: the
        # region was genuinely empty for that whole time.
        ui_table_frame "$_utm_f" "$_utm_cur"
        _utm_hint="      ${UI_DIM:-}↑/↓ to move · Space to toggle · Enter to confirm${UI_RESET:-}"
        if [ "$_utm_drawn" -gt 0 ]; then
            printf '\033[%dA\033[0J%s\n%s\n' "$_utm_drawn" "$UI_TABLE_FRAME" "$_utm_hint"
        else
            printf '%s\n%s\n' "$UI_TABLE_FRAME" "$_utm_hint"
        fi
        _utm_drawn=$(( UI_TABLE_LINES + 1 ))
        _utm_first=0
        if [ "$_utm_tty" = "/dev/tty" ]; then
            IFS= read -rsn1 _utm_key < /dev/tty || break
        else
            IFS= read -rsn1 _utm_key || break
        fi
        case "$_utm_key" in
            "") [ -n "$_utm_sel" ] && { EXAKIT_TABLE_CONFIRMED=1; break; } ;;
            " ")
                # A row that cannot be picked cannot be toggled either. The
                # cursor never rests on one, so this catches only the keypress
                # that arrives before the cursor has moved at all.
                _utm_pickable "$_utm_cur" || continue
                _utm_sel="$(_ui_checkbox_toggle "$_utm_sel" "$_utm_n" "$_utm_cur")"
                _utm_sel="$(_ui_checkbox_apply_group "$_utm_sel" "$_utm_cur" "$EXAKIT_TABLE_GROUP")"
                _utm_sel="$(_ui_checkbox_apply_exclusive "$_utm_sel" "$_utm_cur" "$EXAKIT_TABLE_EXCLUSIVE")"
                ;;
            "$(printf '\033')")
                if [ "$_utm_tty" = "/dev/tty" ]; then
                    IFS= read -rsn2 -t 1 _utm_seq < /dev/tty || _utm_seq=""
                else
                    IFS= read -rsn2 -t 1 _utm_seq || _utm_seq=""
                fi
                case "$_utm_seq" in
                    '[A') _utm_move -1 ;;
                    '[B') _utm_move 1 ;;
                esac
                ;;
            k|K) _utm_move -1 ;;
            j|J) _utm_move 1 ;;
        esac
    done
    # Redraw once without the pointer or the hint: the selection is made, and
    # the same table is about to become the progress display.
    ui_table_tick "$_utm_f" "$_utm_sel"
    UI_TABLE_LINES="$_utm_drawn"
    ui_table_redraw "$_utm_f" 0
    EXAKIT_TABLE_SELECTION="${_utm_sel:-none}"
    _UI_CHECKBOX_SELECTABLE=""
    return 0
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
