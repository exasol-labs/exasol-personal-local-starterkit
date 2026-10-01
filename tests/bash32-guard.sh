#!/usr/bin/env bash
# bash32-guard.sh — constructs that bash 3.2 mis-parses, banned at the source.
#
# The kit targets bash 3.2 because that is /bin/bash on macOS, and the macOS
# runner is the only place some of these show up. They are not style rules:
# each one silently produced a WRONG ANSWER rather than an error, which is what
# makes them worth a guard instead of a comment.
#
#   bash tests/bash32-guard.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. A sed RANGE whose addresses contain braces, used directly as an argument.
#
# In argument position bash 3.2 brace-expands the text of a command
# substitution, and `/start{/,/^end}$/p` reads as a brace list: the braces are
# eaten and ONE sed call becomes TWO, each of them invalid.
#
#     has "..." 'needle' "$(printf '%s\n' "$SRC" | sed -n '/a") -eq "T") {/,/^    }$/p')"
#     sed: 1: "/a") -eq "T") /$/p": invalid command code $
#     sed: 1: "/a") -eq "T") /^    $/p": invalid command code ^
#
# The substitution comes back empty, so the assertion reports MISSING about a
# line that is right there in the file - and bash 5 (every Linux runner) parses
# it correctly, so it fails on macOS alone. An ASSIGNMENT is not brace-expanded.
# Assign first, then pass the variable.
# ---------------------------------------------------------------------------
offenders=""
for f in "$ROOT"/tests/*.sh "$ROOT"/setup/*.sh "$ROOT"/setup/lib/*.sh "$ROOT"/setup/exakit; do
    [ -f "$f" ] || continue
    # This file quotes the construct in its own comments and fixtures.
    case "$f" in */bash32-guard.sh) continue ;; esac
    while IFS= read -r line; do
        _stripped="$(printf '%s' "$line" | sed 's/^[[:space:]]*//')"
        case "$_stripped" in \#*) continue ;; esac
        # Only lines that build a sed RANGE with a brace in an address.
        case "$_stripped" in *sed*"{/,"*) ;; *) continue ;; esac
        # An assignment is safe - it is not brace-expanded.
        case "$_stripped" in [A-Za-z_]*=\"\$\(*) continue ;; esac
        offenders="$offenders
  $(basename "$f"): $(printf '%s' "$_stripped" | cut -c1-72)"
    done < "$f"
done
if [ -z "$(printf '%s' "$offenders" | tr -d '[:space:]')" ]; then
    pass "no sed range with braces is passed straight as an argument"
else
    fail "a sed range with braces is passed straight as an argument (assign it first):$offenders"
fi

# The guard has to be able to SEE one, or it is guarding nothing. A fixture in
# the same shape as the bug, checked with the same test the loop above uses.
_probe='has "x" (printf %s "$S" | sed -n /a") -eq "T") {/,/^    }$/p)'
_seen=no
case "$_probe" in *sed*"{/,"*) _seen=yes ;; esac
if [ "$_seen" = yes ]; then pass "...and the check recognises the shape it bans"
else fail "the check no longer matches the construct it exists to ban"; fi

# ...and that the construct really is broken here, so the ban is not folklore.
# Two invocations of the same extraction: one as an argument, one assigned.
_fx="$(printf 'a") -eq "T") {\nmid\n    }\n')"
_as_arg() { printf '%s' "${#1}"; }
_arg_len="$(_as_arg "$(printf '%s\n' "$_fx" | sed -n '/a") -eq "T") {/,/^    }$/p' 2>/dev/null)")"
_assigned="$(printf '%s\n' "$_fx" | sed -n '/a") -eq "T") {/,/^    }$/p' 2>/dev/null)"
if [ "$_arg_len" -eq "${#_assigned}" ] 2>/dev/null; then
    pass "this bash parses both forms alike (bash ${BASH_VERSION%%(*}), so the ban costs nothing here)"
else
    pass "this bash mangles the argument form (bash ${BASH_VERSION%%(*}: $_arg_len vs ${#_assigned} chars) - the ban is load-bearing"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
