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
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1 = $3"; else fail "$1: expected $2, got $3"; fi
}

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
# "After the target" read as if other components took the staged flags
# too. The sentence names personal alone, even though its aliases work.
case "$_ucs_hint" in
    *"only with personal"*) pass "...and says the staged flags work only with personal" ;;
    *) fail "...but does not say the staged flags work only with personal" ;;
esac
case "$_ucs_hint" in
    *"target"*) fail "...and must not speak of 'the target', which reads as any component" ;;
    *) pass "...without speaking of 'the target'" ;;
esac
# Both parsers go through it, or the two lists drift apart again by omission:
# the dispatcher calls it, and common.sh holds the definition plus its own
# calls (the outer gate, the wrong-target refusal), so at least two more.
if grep -q '$(exakit_update_options_hint)' "$ROOT/setup/exakit" && \
   [ "$(grep -c '$(exakit_update_options_hint)' "$ROOT/setup/lib/common.sh")" -ge 2 ]; then
    pass "the dispatcher and exakit_update both print the shared hint"
else
    fail "a refusal no longer uses exakit_update_options_hint (lists can drift)"
fi

# --json is an ANSWER now, not a refusal: on an empty home it is the same
# not-installed object every state query gives (exit 4), and a staged flag
# under --json is refused as JSON (exit 2). The old flat list must not come
# back in either.
_ucs_out="$(_ucs_run --json)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 4 ] && pass "update --json on an empty home answers the not-installed object (exit 4)" || fail "update --json exited $_ucs_rc, expected 4"
case "$_ucs_out" in
    *'"installed": false'*) pass "...as JSON" ;;
    *)                      fail "...but not as JSON" ;;
esac
_ucs_out="$(_ucs_run --json --plan)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 2 ] && pass "a staged flag under --json is refused with exit 2" || fail "update --json --plan exited $_ucs_rc, expected 2"
case "$_ucs_out" in
    *'"rejected": true'*) pass "...as JSON, because --json was asked for" ;;
    *)                    fail "...but a --json refusal was not JSON" ;;
esac
case "$_ucs_out" in
    *"supported: --yes -y --plan"*) fail "...and still advertises the flat list with --plan in it" ;;
    *)                              pass "...without the old flat list" ;;
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
for _ucs_shape in "personal --plan" "runtime --backup" "--yes" "personal --plan --yes" "--yes personal --apply" "--json" "exapump --json"; do
    # shellcheck disable=SC2086 -- the shape is a word list by construction
    _ucs_out="$(_ucs_run $_ucs_shape)"; _ucs_rc=$?
    if [ "$_ucs_rc" -eq 4 ]; then
        pass "\"exakit update $_ucs_shape\" passes the option gate (exit 4: no install, not 2)"
    else
        fail "\"exakit update $_ucs_shape\" exited $_ucs_rc - the gate refused a valid shape"
    fi
done

printf '\n== update --json reports what happened, one object, nothing else ==\n'
# The run is stubbed at the updaters: exapump updates, mcp dies, the runtime
# is deferred (no --yes under --json means no prompt and no stop), exakit and
# pyexasol are current. The object has to say all of that, and the exit code
# has to be 1 because one updater failed.
mkdir -p "$_UCS_HOME/kit" && printf '{"runtime":{"type":"personal"},"kit":{"version":"0.2.0"}}\n' > "$_UCS_HOME/kit/manifest.json"
_ucs_json="$(HOME="$_UCS_HOME" EXAKIT_HOME="$_UCS_HOME/kit" EXAKIT_BIN_DIR="$_UCS_HOME/bin" bash -c '
. "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
exakit_print_versions_source_line() { info "versions: stubbed"; }
exakit_update_targets() { printf "%s\n" exakit runtime exapump mcp pyexasol; }
exakit_component_supported() { return 0; }
exakit_component_is_ahead() { return 1; }
exakit_component_min_kit() { return 1; }
exakit_component_current()   { case "$1" in exakit) echo 0.2.0;; personal) echo 2.2.0;; exapump) echo 0.12.0;; mcp) echo 2.1.0;; pyexasol) echo 2.4.1;; esac; }
exakit_component_available() { case "$1" in exakit) echo 0.2.0;; personal) echo 2.3.0;; exapump) echo 0.13.0;; mcp) echo 2.2.0;; pyexasol) echo 2.4.1;; esac; }
exakit_update_component() { echo "updater for $1"; case "$1" in mcp) die "stub: mcp failed";; esac; return 0; }
exakit_update --json; echo "rc=$?" >&2' 2>"$_UCS_HOME/stderr")"
_ucs_json_rc="$(sed -n 's/^rc=//p' "$_UCS_HOME/stderr" | tail -1)"
_ucs_verdict="$(printf '%s' "$_ucs_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["ok"], d["status"],
      [e["component"] for e in d["updated"]],
      [(e["component"], e["remedy"]) for e in d["deferred"]],
      d["current"],
      [(e["component"], e["remedy"]) for e in d["failed"]],
      d["remedy"])' 2>/dev/null)"
check "the object names what happened" \
    "False failed ['exapump'] [('personal', 'exakit update --yes')] ['exakit', 'pyexasol'] [('mcp', 'exakit update mcp')] exakit update mcp" \
    "$_ucs_verdict"
check "...and the exit code says one updater failed" "1" "$_ucs_json_rc"
case "$_ucs_json" in
    "{"*"}") pass "stdout is the object and nothing else" ;;
    *)       fail "stdout carries more than the object" ;;
esac

printf '\n== update --json keeps the answer the caller gave ==\n'
# The runbook names EXAKIT_CONFIRM_RUNTIME_UPDATE=1 as the unattended way to
# allow the database change, and the deferred object's remedy_hint repeats it.
# The --json arm used to force the variable to 0 whenever --yes was absent, so
# that one documented form deferred on every run and then recommended the very
# variable it had just overridden. Same stub as above, three answers: the
# caller's 1 applies the runtime change, the caller's 0 still defers it, and
# an unreadable value defaults to "no" because nothing may prompt under --json.
_ucs_answer_run() { # _ucs_answer_run <value> -> "<status> <updated> <deferred>"
    HOME="$_UCS_HOME" EXAKIT_HOME="$_UCS_HOME/kit" EXAKIT_BIN_DIR="$_UCS_HOME/bin" EXAKIT_CONFIRM_RUNTIME_UPDATE="$1" bash -c '
. "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
exakit_print_versions_source_line() { info "versions: stubbed"; }
exakit_update_targets() { printf "%s\n" exakit runtime exapump mcp pyexasol; }
exakit_component_supported() { return 0; }
exakit_component_is_ahead() { return 1; }
exakit_component_min_kit() { return 1; }
exakit_component_current()   { case "$1" in exakit) echo 0.2.0;; personal) echo 2.2.0;; exapump) echo 0.12.0;; mcp) echo 2.1.0;; pyexasol) echo 2.4.1;; esac; }
exakit_component_available() { case "$1" in exakit) echo 0.2.0;; personal) echo 2.3.0;; exapump) echo 0.13.0;; mcp) echo 2.2.0;; pyexasol) echo 2.4.1;; esac; }
exakit_update_component() { echo "updater for $1"; case "$1" in mcp) die "stub: mcp failed";; esac; return 0; }
exakit_update --json' 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["status"], [e["component"] for e in d["updated"]], [e["component"] for e in d["deferred"]])' 2>/dev/null
}
check "EXAKIT_CONFIRM_RUNTIME_UPDATE=1 applies the runtime change under --json" \
    "failed ['personal', 'exapump'] []" "$(_ucs_answer_run 1)"
check "...=0 still defers it" \
    "failed ['exapump'] ['personal']" "$(_ucs_answer_run 0)"
check "...and an unreadable answer defaults to no, never to a prompt" \
    "failed ['exapump'] ['personal']" "$(_ucs_answer_run maybe)"
check "the PowerShell twin keeps the caller's answer the same way" "1" \
    "$(grep -c 'confirmAnswer -cnotmatch' "$ROOT/setup/exakit.ps1")"
rm -rf "$_UCS_HOME"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
