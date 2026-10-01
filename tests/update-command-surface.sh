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

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
