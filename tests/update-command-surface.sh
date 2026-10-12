#!/usr/bin/env bash
# Guard: nothing a user can read names a component after `exakit update`.
#
# The per-component form still WORKS -- `exakit_update_targets` accepts it and
# `exakit update all` iterates it -- but it is deliberately not advertised: the
# everyday command is `exakit update`, and a reader who never learns the
# component form never has to choose between two ways of doing one thing.
#
# This is the opposite of the uninstall case, where the advertised form was
# rejected by the parser. Here the capability is real and stays; only its
# documentation goes. So the guard cannot simply run the command and check for
# an error -- it has to read the surfaces a user reads.
#
#   bash tests/update-command-surface.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

# Every component that is a valid update target, plus the add-on-author template
# used in MARKETPLACE.md. Kept as a list rather than a wildcard so a NEW
# component has to be added here consciously.
COMPONENTS='dash-server runtime pyexasol exakit json-tables exapump personal exasol-vscode exasol-scheduler mcp skills kit2 my-tool'

# WHERE the rule applies: the surfaces a reader goes through to LEARN the kit.
# There the everyday command is bare `exakit update`, and a reader who never
# meets the component form never has to choose between two ways of doing one
# thing.
#
# It does NOT apply to a repair remedy or to an add-on's own page, and that is
# not a loophole -- it is the difference between guidance and diagnosis. Bare
# `exakit update` skips a component whose version is already current, so a
# message about a component that is installed-but-broken ("the engine is
# missing, repair with: ...") CANNOT use the bare form: it would print a
# command that does nothing. The kit's own contract says a remedy is a command
# you can run, so those messages name the component on purpose.
GUIDANCE_FILES="README.md QUICKSTART.md AGENTS.md setup/help/exakit.json skills/local-agent-ready-starter/SKILL.md"
GUIDANCE_GLOBS="quickstarts"

printf '\n== no learn-the-kit surface names a component after "exakit update" ==\n'

# The ONE exception, and it is the staged Personal major upgrade. Its three
# steps are a data migration gated on a backup, and the flags that express them
# are parsed inside the Personal updater -- `exakit update --plan` is rejected
# by the option parser, so the component form is the only way to write it down.
# Hiding a working, backup-gated migration route is worse than naming a
# component once, with its flag on the same line to say why.
scan() { # scan <component>
    _sc_files=""
    for _sc_f in $GUIDANCE_FILES; do
        [ -f "$ROOT/$_sc_f" ] && _sc_files="$_sc_files $ROOT/$_sc_f"
    done
    for _sc_g in $GUIDANCE_GLOBS; do
        [ -d "$ROOT/$_sc_g" ] && _sc_files="$_sc_files $(find "$ROOT/$_sc_g" -type f -name '*.md' | tr '\n' ' ')"
    done
    # shellcheck disable=SC2086 -- the list is built from known paths
    grep -n "exakit update $1" $_sc_files 2>/dev/null \
        | grep -vE -- '--plan|--backup|--apply' \
        | grep -vE ':[0-9]+: *#'
}

_offenders=0
for _c in $COMPONENTS; do
    _hits="$(scan "$_c" || true)"
    if [ -n "$_hits" ]; then
        _offenders=$((_offenders + 1))
        fail "\"exakit update $_c\" is still advertised where a reader learns the kit"
        printf '%s\n' "$_hits" | sed "s|$ROOT/||" | sed 's/^/         /' | head -4
    fi
done
[ "$_offenders" -eq 0 ] && pass "no component name follows \"exakit update\" on a learn-the-kit surface"

printf '\n== a repair remedy names the component it repairs ==\n'
# The other half of the same rule. A message that tells the reader to repair one
# component must name it, because the bare form would skip it. If someone
# "simplifies" these to `exakit update` the remedy silently stops working, and
# the guard above would happily pass.
_repair_ok=0
_repair_missing=""
for _rc in json-tables exasol-scheduler; do
    if grep -rq "exakit update $_rc" "$ROOT/setup/lib/$_rc.sh" 2>/dev/null; then
        _repair_ok=$((_repair_ok + 1))
    else
        _repair_missing="$_repair_missing $_rc"
    fi
done
if [ -z "$_repair_missing" ]; then
    pass "each add-on's repair remedy still names its own component ($_repair_ok checked)"
else
    fail "a repair remedy no longer names its component:$_repair_missing"
fi

printf '\n== the flags that only exist on the component form are not advertised ==\n'
# --plan / --backup / --apply are parsed inside the Personal upgrade path, which
# is reached through `exakit update personal`. Written against bare
# `exakit update` they would be rejected, so documenting them there is worse
# than not documenting them at all.
_flaghits="$(grep -rn 'exakit update --\(plan\|backup\|apply\)' \
    --include="*.sh" --include="*.ps1" --include="*.json" --include="*.md" --include="exakit" \
    "$ROOT" 2>/dev/null | grep -v '/CHANGELOG.md:' | grep -v "/tests/update-command-surface.sh:" \
    | grep -v '/.claude/' || true)"
if [ -z "$_flaghits" ]; then
    pass "no staged-upgrade flag is written against bare \"exakit update\""
else
    fail "a flag that needs the component form is advertised on bare \"exakit update\""
    printf '%s\n' "$_flaghits" | sed "s|$ROOT/||" | sed 's/^/         /' | head -4
fi

printf '\n== the capability itself is untouched ==\n'
# The point is to stop ADVERTISING the form, not to remove it. If someone
# "fixed" this by deleting the targets, every check above would still pass while
# `exakit update` quietly stopped being able to update anything.
# Each component resolved ON ITS OWN, not via `all`. They are different arms:
# `all` prints the whole set from one branch, while `exakit update exapump` goes
# through the per-component branch -- which is the arm being hidden and so the
# only arm worth guarding. Asserting `all` here passed happily with the
# per-component arm deleted, which is the exact failure this section exists to
# catch.
for _want in exakit runtime exapump mcp pyexasol skills; do
    _got="$(bash -c ". '$ROOT/setup/lib/common.sh' 2>/dev/null; exakit_update_targets $_want 2>/dev/null" | tr '\n' ' ' || true)"
    case " $_got " in
        *" $_want "*) pass "\"$_want\" still resolves as an update target" ;;
        *)            fail "\"$_want\" no longer resolves - the capability was removed, not just hidden" ;;
    esac
done

printf '\n== the command advertises one option list, and it is the true one ==\n'
# `exakit update --json` used to answer "supported: --yes -y --plan --backup
# --apply", and `exakit update --plan` then answered "supported: --yes". Both
# were true in their own position (the staged flags only work behind the
# Personal target) and read as a contradiction from outside, so an agent that
# retried with an option the tool had just advertised was refused twice.
# Driven through the real CLI on an EMPTY home: the option gate runs before
# the install check, so bad input is exit 2 there, while an accepted shape
# falls through to the install check's exit 4. That difference is the whole
# assertion - 2 means the parser refused it, 4 means it let it through.
_UCS_HOME="$(mktemp -d "${TMPDIR:-/tmp}/exakit-ucs.XXXXXX")"
_ucs_run() { # _ucs_run <args...> -> stderr+stdout; sets _ucs_rc
    EXAKIT_HOME="$_UCS_HOME/none" bash "$ROOT/setup/exakit" update "$@" 2>&1
}
_ucs_hint="$(bash -c ". '$ROOT/setup/lib/common.sh' 2>/dev/null; exakit_update_options_hint 2>/dev/null" || true)"
if [ -n "$_ucs_hint" ]; then
    pass "exakit_update_options_hint prints the shared sentence"
else
    fail "exakit_update_options_hint is missing or prints nothing"
fi
# Both parsers go through it, or the two lists drift apart again by omission:
# the dispatcher calls it, and common.sh holds the definition plus its own
# calls (the outer gate, the wrong-target refusal), so at least two more.
if grep -q '$(exakit_update_options_hint)' "$ROOT/setup/exakit" && \
   [ "$(grep -c '$(exakit_update_options_hint)' "$ROOT/setup/lib/common.sh")" -ge 2 ]; then
    pass "the dispatcher and exakit_update both print the shared hint"
else
    fail "a refusal no longer uses exakit_update_options_hint (lists can drift)"
fi

_ucs_out="$(_ucs_run --json)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 2 ] && pass "update --json is refused with exit 2" || fail "update --json exited $_ucs_rc, expected 2"
case "$_ucs_out" in
    *"supported: --yes -y --plan"*) fail "update --json still advertises the flat list with --plan in it" ;;
    *)                              pass "update --json no longer advertises --plan as a bare option" ;;
esac
case "$_ucs_out" in
    *"$_ucs_hint"*) pass "...and carries the shared hint" ;;
    *)              fail "...but the shared hint is not in the refusal" ;;
esac
case "$_ucs_out" in
    *'"rejected": true'*) pass "...as JSON, because --json was asked for" ;;
    *)                    fail "...but a --json refusal was not JSON" ;;
esac

_ucs_out="$(_ucs_run --plan)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 2 ] && pass "a staged flag with no target is refused with exit 2" || fail "update with a leading staged flag exited $_ucs_rc, expected 2"
case "$_ucs_out" in
    *"exakit update personal --plan"*) pass "...and is told where the flag goes" ;;
    *)                                 fail "...but the refusal does not name 'exakit update personal --plan'" ;;
esac
case "$_ucs_out" in
    *"supported: --yes;"*|*"supported: --yes -y"*) fail "...and still answers with one of the two old lists" ;;
    *) pass "...without either of the two old lists" ;;
esac

_ucs_out="$(_ucs_run exapump --plan)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 2 ] && pass "a staged flag behind the wrong target is refused with exit 2" || fail "update exapump with a staged flag exited $_ucs_rc, expected 2"
case "$_ucs_out" in
    *"exakit update personal --plan"*) pass "...and names the target it belongs to" ;;
    *)                                 fail "...but does not name the Personal form" ;;
esac

_ucs_out="$(_ucs_run --bogus)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 2 ] && pass "an unknown option is still refused with exit 2" || fail "update --bogus exited $_ucs_rc, expected 2"
case "$_ucs_out" in
    *"$_ucs_hint"*) pass "...with the same shared hint" ;;
    *)              fail "...but with a different option list" ;;
esac

# The accepted shapes reach the install check (exit 4 on an empty home), which
# proves the gate let them through rather than refusing them as bad input.
for _ucs_shape in "personal --plan" "runtime --backup" "--yes" "personal --plan --yes" "--yes personal --apply"; do
    # shellcheck disable=SC2086 -- the shape is a word list by construction
    _ucs_out="$(_ucs_run $_ucs_shape)"; _ucs_rc=$?
    if [ "$_ucs_rc" -eq 4 ]; then
        pass "\"exakit update $_ucs_shape\" passes the option gate (exit 4: no install, not 2)"
    else
        fail "\"exakit update $_ucs_shape\" exited $_ucs_rc - the gate refused a valid shape"
    fi
done
rm -rf "$_UCS_HOME"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
