#!/usr/bin/env bash
# ps-python-pick-guard.sh - a PowerShell suite never picks the Microsoft Store
# alias as its Python. On a normal Windows box `python3` is the WindowsApps
# stub: it prints "Python was not found; run without arguments to install from
# the Microsoft Store" and exits 9009, so tests/data-question-ps.ps1, which
# preferred it, failed with "tests/release_kit.py made no kit copy".
#
# Every python3 lookup in a suite must either skip a path under \WindowsApps\
# (as mcp-sidecar-ps.ps1 does) or come right after a `python` lookup, as the
# fallback when there is none, and a suite never calls `& python3` bare. The
# second half checks the guard itself.
#
#   bash tests/ps-python-pick-guard.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# store_prone <dir> - every python3 lookup or call that can take the Store
# alias, one "<file>:<line>" per line. EACH one is checked on its own (review
# 0.3.1, item 4: only the first lookup was, and the word WindowsApps anywhere
# exempted the whole file): a `Get-Command python3` needs a \WindowsApps\
# filter on its own pipeline (that line or the three after it, where a loop
# skips the path), or a `python` lookup in the five lines before it (the
# python3 one is then only the fallback). A bare `& python3` or `python3.exe`
# call cannot be filtered and is always named. Comment lines do not count.
store_prone() {
    for _f in "$1"/*.ps1 "$1"/lib/*.ps1; do
        [ -f "$_f" ] || continue
        awk -v f="$_f" '
            { line[NR] = $0 }
            END {
                for (n = 1; n <= NR; n++) {
                    l = line[n]
                    if (l ~ /^[ \t]*#/) continue
                    if (l ~ /&[ \t]*["'\'']?python3([ \t"'\'']|$)/ || l ~ /python3\.exe/) { print f ":" n; continue }
                    if (l !~ /Get-Command[ \t]+python3/) continue
                    ok = 0
                    pre = l; sub(/Get-Command[ \t]+python3.*/, "", pre)
                    if (pre ~ /Get-Command[ \t]+python([^0-9A-Za-z]|$)/) ok = 1
                    for (k = n; k <= n + 3 && k <= NR; k++) if (line[k] ~ /WindowsApps/) ok = 1
                    for (k = n - 5; k < n; k++) if (k >= 1 && line[k] ~ /Get-Command[ \t]+python([^0-9A-Za-z]|$)/) ok = 1
                    if (!ok) print f ":" n
                }
            }' "$_f"
    done
}

printf '== no suite takes the Store alias for Python ==\n'
_bad="$(store_prone "$ROOT/tests")"
if [ -z "$_bad" ]; then
    pass "every python3 lookup skips \\WindowsApps\\ or comes after python"
else
    for _b in $_bad; do fail "${_b#"$ROOT"/} asks for python3 first and does not skip the \\WindowsApps\\ alias"; done
fi

printf '\n== the guard catches a suite that does ==\n'
_t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
mkdir -p "$_t/lib"
printf '$py = Get-Command python3 -ErrorAction SilentlyContinue\n' > "$_t/bad.ps1"
printf 'if (-not (Get-Command python -ErrorAction SilentlyContinue)) { $py3 = Get-Command python3 }\n' > "$_t/after.ps1"
printf '$py = @(Get-Command python3 | Where-Object { $_.Source -notlike "*\\WindowsApps\\*" })\n' > "$_t/filtered.ps1"
printf '$py = @(Get-Command python3 | Where-Object { $_.Source -notlike "*\\WindowsApps\\*" })\n\n\n\n\n\n$late = Get-Command python3\n' > "$_t/late.ps1"
printf '$ok = Get-Command python\n& python3 -c "print(1)"\n' > "$_t/call.ps1"
printf '# Get-Command python3 in a comment\n' > "$_t/comment.ps1"
_got="$(store_prone "$_t" | sed "s#^$_t/##" | sort | tr '\n' ' ')"
_want="bad.ps1:1 call.ps1:2 late.ps1:7 "
[ "$_got" = "$_want" ] && pass "each unfiltered python3 lookup and every bare python3 call is named, the safe forms are not" \
    || fail "the guard named: '$_got' (want: '$_want')"

printf '\nps-python-pick-guard.sh: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
