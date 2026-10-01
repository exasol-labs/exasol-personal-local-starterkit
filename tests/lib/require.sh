# require.sh — a skip that CI can turn into a failure.
#
# THE PROBLEM THIS EXISTS FOR: every suite with a prerequisite handled a
# missing one by printing "skipped" and exiting 0. On a runner without that
# prerequisite the suite therefore reported SUCCESS having asserted nothing,
# and the matrix stayed green. Two live examples from the audit:
#
#   - macos-latest has no pwsh, so on that leg the PowerShell AST sweep - the
#     guard credited with catching a shipped-broken exasol-scheduler install -
#     read nothing and passed. ubuntu-latest was the only thing running it, on
#     the implicit property that the hosted image happens to ship pwsh. If that
#     image ever drops it, five suites go quiet and nobody gets a red build.
#
#   - mcp-readonly-sql-matrix.sh is the ONLY suite that empirically proves the
#     MCP user can read and cannot write. It needs a live database, no CI job
#     starts one, and wiring it in as-is would print SKIP and pass - so the
#     kit's central security claim has 40 assertions behind it and zero that
#     can fire automatically.
#
# A developer running the suites on a laptop still wants the skip; what was
# missing is a way for the ONE environment that is supposed to have the
# prerequisite to insist on it. Hence an opt-in: the caller declares what it
# requires, and only then does a missing prerequisite fail.
#
#   EXAKIT_REQUIRE_PS=1   pwsh must exist        (set on the CI leg that has it)
#   EXAKIT_REQUIRE_DB=1   a live kit+database must exist (a maintainer's
#                         post-install verification, never a dry runner)
#   EXAKIT_REQUIRE_ALL=1  both of the above
#
# Usage:  exakit_require_skip PS "pwsh is not installed - the AST guard needs it"

exakit_require_skip() { # exakit_require_skip <PS|DB> <reason>
    _ers_kind="$1"
    _ers_why="$2"
    eval "_ers_want=\"\${EXAKIT_REQUIRE_${_ers_kind}:-0}\""
    if [ "$_ers_want" = "1" ] || [ "${EXAKIT_REQUIRE_ALL:-0}" = "1" ]; then
        printf 'FAIL %s\n' "$_ers_why" >&2
        printf 'This environment declared EXAKIT_REQUIRE_%s=1, so a missing prerequisite is a failure, not a skip.\n' \
            "$_ers_kind" >&2
        exit 1
    fi
    printf 'skipped: %s\n' "$_ers_why"
    printf '  (set EXAKIT_REQUIRE_%s=1 to make this a failure instead)\n' "$_ers_kind"
    exit 0
}
