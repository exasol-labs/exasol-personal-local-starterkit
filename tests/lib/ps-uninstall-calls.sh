#!/usr/bin/env bash
# Every helper the uninstall path calls must resolve when
# tests/uninstall-ps.ps1 runs it in isolation -- either because the test
# extracts the CLI's own functions, or because the test stubs it.
#
# This exists because that suite had NO caller anywhere and, on its first ever
# execution, died on a helper it did not stub -- with three more queued behind
# it, each costing a full CI round to discover. pwsh is not on the machine this
# kit is developed on, so without a check like this the only way to find the
# next one is to push and wait.
#
# IT USED TO READ ONE FUNCTION BODY. Invoke-ExakitUninstallRun's own text was
# scanned and nothing else, so a helper that the CLI defines -- which the
# harness therefore loads and really executes -- could call anything it liked
# and the guard stayed green. The suite would still die in CI on that helper's
# first unstubbed call, which is precisely the round-trip this file exists to
# avoid. The walk is now transitive: it follows every call that lands in a
# function exakit.ps1 defines and the test does NOT stub, because a stub is
# defined after the extraction and wins, so a stubbed name is a leaf.
#
#   bash tests/lib/ps-uninstall-calls.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/setup/exakit.ps1"
TEST="$ROOT/tests/uninstall-ps.ps1"
fails=0

# PowerShell built-ins the test does not have to supply.
BUILTINS=" Get-Command Get-ChildItem Get-Content Remove-Item Test-Path Join-Path New-Item Set-Variable Write-Host Out-Null Where-Object ForEach-Object Select-Object Start-Process Split-Path Move-Item Get-Date "

VERBS='(Get|Set|New|Remove|Invoke|Test|Write|Unregister|Register|Stop|Start|Confirm|Show|Read)-[A-Za-z]+'

# The body of one top-level function, by name.
_fn_body() {
    awk -v n="$1" '
        !f && $0 ~ ("^function " n "([ ({]|$)") { f = 1 }
        f { print }
        f && /^}[[:space:]]*$/ { exit }
    ' "$CLI"
}

_defined_in_cli() { grep -qE "^function $1([ ({]|$)" "$CLI"; }
_stubbed_in_test() { grep -qE "function $1([ ({]|$)" "$TEST"; }

ALL="${TMPDIR:-/tmp}/ps-uninst-all.$$"
: > "$ALL"

queue="Invoke-ExakitUninstallRun"
seen=""
while [ -n "$queue" ]; do
    fn="${queue%% *}"
    if [ "$queue" = "$fn" ]; then queue=""; else queue="${queue#* }"; fi
    case " $seen " in *" $fn "*) continue ;; esac
    seen="$seen $fn"

    body="$(_fn_body "$fn")"
    [ -n "$body" ] || continue
    printf '%s\n' "$body" >> "$ALL"

    for call in $(printf '%s\n' "$body" | grep -oE "\\b$VERBS" | sort -u); do
        case "$BUILTINS" in *" $call "*) continue ;; esac
        # A stub wins over the extracted definition, so a stubbed name is a
        # leaf: following it would police code the suite never runs.
        _stubbed_in_test "$call" && continue
        _defined_in_cli "$call" && queue="$queue $call"
    done
done

while read -r call; do
    case "$BUILTINS" in *" $call "*) continue ;; esac
    case " $seen " in *" $call "*) continue ;; esac
    if _defined_in_cli "$call"; then continue; fi        # extracted
    if _stubbed_in_test "$call"; then continue; fi       # stubbed
    printf 'FAIL %s is neither defined in exakit.ps1 nor stubbed in uninstall-ps.ps1\n' "$call"
    fails=$((fails + 1))
done < <(grep -oE "\\b$VERBS" "$ALL" | sort -u)

# The kit's bare output helpers (OkStep, Warn2, ...) carry no Verb-Noun hyphen,
# so the pattern above never saw them -- and the first time the pwsh suite ran
# in CI it died on exactly one of those: `OkStep` had no stub. They live in
# exakit-common.ps1, which the test does not load, so each one the uninstall
# path calls has to be stubbed in the test.
while read -r call; do
    if grep -q "function $call\b" "$TEST"; then continue; fi
    printf 'FAIL %s (bare output helper) is not stubbed in uninstall-ps.ps1\n' "$call"
    fails=$((fails + 1))
done < <(grep -oE '(^|[{;(]|\|) *(Info|InfoStep|Ok|OkStep|Warn2|Fail|Heading)\b' "$ALL" | grep -oE '[A-Za-z0-9]+$' | sort -u)

_walked="$(printf '%s' "$seen" | wc -w | tr -d ' ')"
rm -f "$ALL"

if [ "$fails" -eq 0 ]; then
    echo "ok   every helper the uninstall path calls resolves in the test ($_walked function(s) walked)"
    exit 0
fi
printf '\n%d unresolved call(s) -- uninstall-ps.ps1 would die on the first one\n' "$fails"
exit 1
