# line-coverage.sh — line coverage for one sourced shell module, on bash 3.2.
#
#   . "$ROOT/tests/lib/line-coverage.sh"
#   ... run the code under test with the statement coverage_prelude prints
#       first and `set -x` just before the module is sourced, then hand its
#       combined output and the raw file to coverage_collect ...
#   coverage_report "$ROOT/setup/lib/<module>.sh" "$TRACE" 85
#
# HOW IT WORKS. Bash's xtrace prints every simple command it runs, prefixed by
# PS4 - and PS4 is expanded, so a PS4 that names ${BASH_SOURCE} and ${LINENO}
# stamps each traced command with the file and line it came from. Collect
# those stamps, count the distinct lines of the module that appear, divide by
# the lines that COULD appear. No bashcov, no bash 4, nothing installed: the
# measurement runs on the same bash 3.2 the kit has to work on.
#
# TWO THINGS ABOUT BASH 3.2 SHAPE THIS FILE:
#   - PS4 is truncated at about a hundred characters after expansion, silently.
#     A full ${BASH_SOURCE} path from a temp directory is longer than that and
#     the LINENO after it simply vanished. The stamp carries the BASENAME only.
#   - the first character of PS4 is repeated once per level of nesting, so a
#     command inside $( ) arrives as ++@C@... - the parser strips any run of
#     leading pluses before it looks for the marker.
#
# WHAT COUNTS AS A LINE THAT COULD APPEAR. xtrace only prints simple commands,
# so a line is "executable" when it holds one. Excluded, because xtrace never
# prints them and counting them would understate coverage for no reason: blank
# lines and comment-only lines; structural keywords standing alone (`}`, `fi`,
# `done`, `esac`, `else`, `then`, `do`, `;;`); `done` with a redirection; a
# function header; a bare case label like `migrate|yes|1)`; a here-document
# body and its terminator; and the CONTINUATION lines of a command split with a
# trailing backslash - which are folded into the line the command starts on,
# so a hit on any line of the group counts for the group.
#
# This is an honest approximation, not an oracle: a branch whose only content
# is a structural line contributes nothing either way, and `a && b || c` on one
# line is one line however many of its arms ran. It is precise enough to say
# whether a suite has walked a module or merely looked at it.

COVERAGE_PS4='+@C@${BASH_SOURCE##*/}:${LINENO}@ '

# coverage_prelude <raw-file> — the statements that decide WHAT the trace is
# stamped with and WHERE it goes, to be run first inside the traced shell.
#
# PS4 IS SET HERE, NOT EXPORTED INTO THE SHELL. bash 3.2 takes PS4 from the
# environment; bash 4.4 and later deliberately do NOT - PS4 is expanded before
# each traced command, so inheriting it from the environment was a way to run
# code in someone else's shell, and the import was dropped. A suite that only
# exported it therefore measured every line on macOS and NOTHING on a modern
# Linux: the trace arrived with the default "+ " prefix, no stamp matched, and
# the report read "0 of 248 executable lines" - a coverage floor that could
# only ever fail, and said nothing about the module when it did. Turning tracing ON is the
# caller's `set -x`, placed right before the module under measurement is
# sourced: everything sourced before it (common.sh is ten thousand lines) is
# then neither traced nor counted, which is what makes fifty traced runs
# affordable.
#
# WHERE THE TRACE GOES DECIDES WHAT IS COUNTED. xtrace writes to stderr, and a
# module that redirects a helper's stderr away - `legacy_table_ddl ... 2>/dev/null`,
# `legacy_stop_container >/dev/null 2>&1` - throws away the trace of everything
# that helper ran: the whole DDL builder measured as never reached while its
# output sat in the index. bash 4.1 added BASH_XTRACEFD for exactly this, so
# on a bash that has it the trace goes to its own descriptor and no redirect in
# the module can touch it. On bash 3.2 it stays on stderr and the count is a
# floor on the truth, not the truth: code run under a stderr redirect is
# invisible. The report says which bash measured.
coverage_prelude() {
    # Single quotes around the value: PS4 must reach the shell UNEXPANDED, so
    # that $BASH_SOURCE and $LINENO name each traced command rather than this
    # line. COVERAGE_PS4 holds no single quote of its own, so there is nothing
    # to escape.
    printf "PS4='%s'\n" "$COVERAGE_PS4"
    printf 'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 1 ]; }; then exec 9>>"%s"; BASH_XTRACEFD=9; fi\n' "$1"
}

# coverage_collect <combined-output> <raw-file> <trace-file> — the stamps from
# both places a trace can land (stderr mixed into the output, or the raw file
# BASH_XTRACEFD wrote) go to the trace file; everything else in the output goes
# to stdout. Run the code with 2>&1 so a module's own stderr (warn, error)
# stays part of what the caller sees on "screen".
coverage_collect() {
    sed -n 's/^+*@C@\([^@]*\)@.*/\1/p' "$1" >> "$3"
    [ -f "$2" ] && sed -n 's/^+*@C@\([^@]*\)@.*/\1/p' "$2" >> "$3" && : > "$2"
    grep -v '^+*@C@' "$1" || true
}

# _coverage_classify <module> — one line per source line: "<n>\t<group>\t<exe>"
# where <group> is the first line of the command this line belongs to (itself,
# unless it continues a backslash-split command) and <exe> is 1 when the line
# can appear in an xtrace.
_coverage_classify() {
    awk '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        BEGIN { in_heredoc = 0; prev_continues = 0; group = 0 }
        {
            t = trim($0); exe = 1
            group = prev_continues ? group : NR
            if (in_heredoc) {
                exe = 0
                if (t == terminator) in_heredoc = 0
            } else if (t == "" || t ~ /^#/) {
                exe = 0
            } else if (prev_continues) {
                exe = 0
            } else if (t ~ /^(\}|\{|fi|done|esac|else|then|do|;;)$/) {
                exe = 0
            } else if (t ~ /^done[ \t]*<.*/) {
                exe = 0
            } else if (t ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{[ \t]*$/) {
                exe = 0
            } else if (t ~ /^[^ \t\[]+\)$/) {
                exe = 0
            }
            if (!in_heredoc && t ~ /<<-?\047?[A-Za-z_]+\047?[ \t]*$/) {
                terminator = t
                sub(/.*<<-?\047?/, "", terminator); sub(/\047?[ \t]*$/, "", terminator)
                in_heredoc = 1
            }
            prev_continues = (t ~ /\\$/ && !in_heredoc)
            printf "%d\t%d\t%d\n", NR, group, exe
        }' "$1"
}

# coverage_report <module> <trace-file> <floor-percent> — prints the coverage
# of <module> and every executable line the trace never reached, with its
# source. Returns 0 when coverage is at or above the floor.
coverage_report() {
    _cr_module="$1"; _cr_trace="$2"; _cr_floor="$3"
    _cr_base="${_cr_module##*/}"
    _cr_hits="$(mktemp "${TMPDIR:-/tmp}/exakit-cov-hits.XXXXXX")"
    _cr_lines="$(mktemp "${TMPDIR:-/tmp}/exakit-cov-lines.XXXXXX")"
    # Distinct line numbers of this module the trace stamped.
    sed -n "s/^${_cr_base}:\([0-9][0-9]*\)$/\1/p" "$_cr_trace" | sort -n -u > "$_cr_hits"
    _coverage_classify "$_cr_module" > "$_cr_lines"
    # A hit anywhere in a continuation group counts for the group's first line.
    _cr_hit_groups="$(awk -F'\t' 'NR==FNR { hit[$1] = 1; next } ($1 in hit) { print $2 }' "$_cr_hits" "$_cr_lines" | sort -n -u)"
    _cr_total="$(awk -F'\t' '$3 == 1' "$_cr_lines" | wc -l | tr -d ' ')"
    _cr_covered="$(printf '%s\n' "$_cr_hit_groups" | awk -F'\t' 'NR==FNR { g[$1] = 1; next } $3 == 1 && ($1 in g)' - "$_cr_lines" | wc -l | tr -d ' ')"
    _cr_pct=0
    [ "$_cr_total" -gt 0 ] && _cr_pct=$(( _cr_covered * 100 / _cr_total ))
    printf '\ncoverage of %s: %d of %d executable lines (%d%%), floor %d%% - measured by bash %s%s\n' \
        "$_cr_base" "$_cr_covered" "$_cr_total" "$_cr_pct" "$_cr_floor" "$BASH_VERSION" \
        "$([ "${BASH_VERSINFO[0]}" -ge 4 ] || printf ' (no BASH_XTRACEFD: code run under a stderr redirect is not counted)')"
    _cr_missed="$(printf '%s\n' "$_cr_hit_groups" | awk -F'\t' 'NR==FNR { g[$1] = 1; next } $3 == 1 && !($1 in g) { print $1 }' - "$_cr_lines")"
    if [ -n "$_cr_missed" ]; then
        printf 'never reached:\n'
        for _cr_n in $_cr_missed; do
            printf '  %4d  %s\n' "$_cr_n" "$(sed -n "${_cr_n}p" "$_cr_module" | sed 's/^[[:space:]]*//' | cut -c1-90)"
        done
    fi
    rm -f "$_cr_hits" "$_cr_lines"
    [ "$_cr_pct" -ge "$_cr_floor" ]
}
