#!/usr/bin/env bash
# Guard: the learn-the-kit surfaces teach bare `exakit update`, and the
# command reference documents the component form once.
#
# The component form is supported and documented (#47): `exakit update <id>
# [<id>...]` updates only those, each once and in any order. Where a reader
# LEARNS the kit (README, quickstarts, AGENTS.md, the starter skill) the
# everyday command stays bare `exakit update`, and no concrete component name
# follows it: a reader who never meets the component form there never has to
# choose between two ways of doing one thing. The command reference
# (setup/help/exakit.json, what `exakit help update` and `exakit catalog
# --json` print) is where the form is documented: it says `[<component>...]`,
# its first example stays bare, and its one component example names several
# ids, never one.
#
# This is the opposite of the uninstall case, where the advertised form was
# rejected by the parser. Here the capability is real and stays, so the guard
# cannot simply run the command and check for an error -- it has to read the
# surfaces a user reads.
#
#   bash tests/update-command-surface.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Offline, for every child below. exakit_update asks upstream for versions.json
# before it applies anything (_exakit_update_run, force), so each stubbed
# `exakit_update --json` run fetched it from raw.githubusercontent.com. A
# non-https URL is refused without a request, as in tests/versions-manifest.sh.
EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
export EXAKIT_VERSIONS_URL
# The add-ons' GitHub About look-up an update warms (_exakit_marketplace_warm_about)
# asked api.github.com once per add-on from every fixture that reached it.
EXAKIT_ABOUT_OFFLINE=1
export EXAKIT_ABOUT_OFFLINE
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
GUIDANCE_FILES="README.md QUICKSTART.md AGENTS.md skills/local-agent-ready-starter/SKILL.md"
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

printf '\n== the command reference documents several ids, once ==\n'
# setup/help/exakit.json is what `exakit help update` (both shells) and
# `exakit catalog --json` print. It used to say `[<component>]`, one optional
# id, so the #47 fix could not be found where a reader or an agent looks.
_ucs_ref="$(python3 - "$ROOT/setup/help/exakit.json" <<'UCS_REF'
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
entry = next(c for c in doc["commands"] if c["command"] == "update")
examples = entry.get("examples") or []
named = [e for e in examples if e.startswith("exakit update ") and not e.split()[2].startswith("-")]
print("|".join([entry["options"], examples[0] if examples else "",
                ",".join(str(len(e.split()) - 2) for e in named),
                entry["parameters"][0]["name"]]))
UCS_REF
)"
check "exakit help update: several ids, a bare first example, one example naming two ids" \
    "[<component>...] [--yes] [--json]|exakit update|2|<component>..." "$_ucs_ref"

printf '\n== a repair remedy names the component it repairs ==\n'
# The other half of the same rule. A message that tells the reader to repair one
# component must name it, because the bare form would skip it. If someone
# "simplifies" these to `exakit update` the remedy silently stops working, and
# the guard above would happily pass.
_repair_ok=0
_repair_missing=""
# The add-ons are Python now (marketplace/addons/, and the Scheduler's launcher
# beside them); the remedy is wherever the add-on's code lives.
for _rc in json-tables exasol-scheduler; do
    if grep -rq "exakit update $_rc" "$ROOT/marketplace" "$ROOT/setup/lib/$_rc.sh" 2>/dev/null; then
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
# Several ids through the REAL CLI (#47): the dispatcher's own option gate runs
# before exakit_update, so a second id it refused there - with the old "Update
# options" message - never reached the parser the checks below exercise. On the
# empty home an accepted shape falls through to the install check's exit 4.
for _ucs_shape in "exapump dbt-exasol" "runtime dash-server" "personal exapump --yes" "dash-server exapump --json"; do
    # shellcheck disable=SC2086 -- the shape is words on purpose
    _ucs_out="$(_ucs_run $_ucs_shape)"; _ucs_rc=$?
    check "the real CLI lets 'exakit update $_ucs_shape' through its option gate (exit 4, no option refusal)" \
        "4|0" "$_ucs_rc|$(printf '%s\n' "$_ucs_out" | grep -c 'Update options\|Unknown option')"
done

# Several component ids (#47): `exakit update exapump dbt-exasol` updates both,
# as `exakit marketplace` installs several; a second id is never read as an
# option. Only the run is stubbed: the parsing is the real exakit_update.
# Its own kit home, no update lock and no About look-up: the fixture once left
# a lock and a failure note in the real ~/.exasol-starter-kit and asked GitHub.
_ucs_multi() { # _ucs_multi <args...> -> the targets the run was handed, or the refusal; sets _ucs_rc
    EXAKIT_HOME="$_UCS_HOME/multi" bash -c '. "$1/setup/lib/common.sh" >/dev/null 2>&1
        exakit_init_logging() { :; }
        exakit_update_lock_acquire() { :; }
        _exakit_marketplace_warm_about() { :; }
        exakit_marketplace_installed_addons() { :; }
        _exakit_addon_registered() { [ "$1" = dbt-exasol ] || [ "$1" = dash-server ]; }
        _exakit_update_run() { printf "target=%s|targets=%s|rest=%s\n" "$1" "$(printf "%s" "$2" | tr "\n" " ")" "$*"; }
        shift; exakit_update "$@"' _ "$ROOT" "$@" 2>&1
}
_ucs_out="$(_ucs_multi exapump dbt-exasol)"; _ucs_rc=$?
case "$_ucs_out" in
    *"targets=exapump dbt-exasol|"*) pass "update with two ids updates both" ;;
    *) fail "update exapump dbt-exasol did not hand both to the run: $_ucs_out" ;;
esac
case "$_ucs_out" in
    *"Update options"*) fail "...and still blames options" ;;
    *) pass "...and no longer blames options" ;;
esac
_ucs_out="$(_ucs_multi exapump dbt-exasol exapump --yes)"; _ucs_rc=$?
case "$_ucs_out" in
    *"targets=exapump dbt-exasol|"*) pass "...each once, with --yes anywhere" ;;
    *) fail "a repeated id or --yes changed the targets: $_ucs_out" ;;
esac
_ucs_out="$(_ucs_multi exapump nonsense)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 2 ] && pass "an unknown second id is refused with exit 2" || fail "an unknown second id exited $_ucs_rc, expected 2"
case "$_ucs_out" in
    *"Unknown update target 'nonsense'"*) pass "...naming the id" ;;
    *) fail "...but does not name it: $_ucs_out" ;;
esac
_ucs_out="$(_ucs_multi exapump dbt-exasol --plan)"; _ucs_rc=$?
[ "$_ucs_rc" -eq 2 ] && pass "an option behind several ids is still refused with exit 2" || fail "ids plus --plan exited $_ucs_rc"
# In any order (#47, the other way round): personal/runtime/database/db first
# kept every later word as a Personal option, so `exakit update runtime
# dash-server` said "Everything is already current." with dash-server never
# looked at, or died "Unknown option 'dash-server'".
_ucs_out="$(_ucs_multi runtime dash-server)"; _ucs_rc=$?
case "$_ucs_rc|$_ucs_out" in
    "0|target=runtime dash-server|targets=runtime dash-server|"*) pass "runtime first, then an add-on: both are updated" ;;
    *) fail "update runtime dash-server: $_ucs_rc|$_ucs_out" ;;
esac
_ucs_out="$(_ucs_multi personal exapump)"; _ucs_rc=$?
case "$_ucs_rc|$_ucs_out" in
    "0|"*"targets=personal exapump|rest="*) pass "personal first, then an id: both are updated, nothing is read as an option" ;;
    *) fail "update personal exapump: $_ucs_rc|$_ucs_out" ;;
esac
_ucs_out="$(_ucs_multi database exapump db)"; _ucs_rc=$?
case "$_ucs_rc|$_ucs_out" in
    "0|"*"targets=runtime exapump|"*) pass "database first: the runtime and exapump, the runtime once" ;;
    *) fail "update database exapump db: $_ucs_rc|$_ucs_out" ;;
esac
_ucs_out="$(_ucs_multi personal --plan)"; _ucs_rc=$?
case "$_ucs_rc|$_ucs_out" in
    "0|target=personal|targets=personal|rest="*"--plan") pass "personal --plan still hands the option to the Personal updater" ;;
    *) fail "update personal --plan: $_ucs_rc|$_ucs_out" ;;
esac
_ucs_out="$(_ucs_multi personal exapump --plan)"; _ucs_rc=$?
case "$_ucs_rc|$_ucs_out" in
    "2|"*"Update options are only supported for Personal runtime updates"*) pass "an option beside personal and another id is refused with exit 2" ;;
    *) fail "update personal exapump --plan: $_ucs_rc|$_ucs_out" ;;
esac
# An empty id is bad input, never "everything" (an unset variable in a cron
# line once updated the whole kit, runtime included).
_ucs_out="$(_ucs_multi dash-server "")"; _ucs_rc=$?
check "an empty second id is refused with exit 2, naming it" \
    "2|1|0" "$_ucs_rc|$(printf '%s\n' "$_ucs_out" | grep -c "Component id 2 of 'exakit update' is empty. Name each component to update, or run 'exakit update' alone to update everything.")|$(printf '%s\n' "$_ucs_out" | grep -c 'targets=')"
_ucs_out="$(_ucs_multi "" dash-server)"; _ucs_rc=$?
check "an empty first id is refused with exit 2, naming it" \
    "2|1" "$_ucs_rc|$(printf '%s\n' "$_ucs_out" | grep -c "Component id 1 of 'exakit update' is empty")"
_ucs_out="$(_ucs_multi --yes "")"; _ucs_rc=$?
check "an empty id alone is refused, not read as everything" \
    "2|1" "$_ucs_rc|$(printf '%s\n' "$_ucs_out" | grep -c "Component id 1 of 'exakit update' is empty")"
_ucs_out="$(_ucs_multi uv)"; _ucs_rc=$?
case "$_ucs_rc|$_ucs_out" in
    "0|target=uv|targets=uv|"*) pass "uv is an update target (the status remedy for uv)" ;;
    *) fail "update uv: $_ucs_rc|$_ucs_out" ;;
esac

# A named add-on that was never installed: its module refused with "not
# kit-owned; its owner manages updates" and the failed row's remedy was the
# same command, so an agent obeying remedy looped. The run is the real
# _exakit_update_run; the module never runs, and the remedy is the install.
_ucs_missing() { # _ucs_missing <json 0|1> -> the screen, the module calls, the report
    _ucs_mtmp="$(mktemp -d)"
    EXAKIT_HOME="$_ucs_mtmp/kit" EXAKIT_UPDATE_JSON="$1" EXAKIT_UPDATE_RESULTS="$_ucs_mtmp/results" bash -c '
        . "$1/setup/lib/common.sh" >/dev/null 2>&1
        EXAKIT_VERSION_POLICY=pinned
        exakit_print_versions_source_line() { :; }
        exakit_component_min_kit() { :; }
        exakit_core_update_check() { :; }
        exakit_core_preprocessor_verify() { :; }
        exakit_component_supported() { return 0; }
        exakit_component_is_ahead() { return 1; }
        exakit_update_actual_target() { printf "%s\n" "$1"; }
        _exakit_addon_registered() { [ "$1" = dbt-exasol ]; }
        _exakit_addon_system_present() { return 1; }
        manifest_get() { return 1; }
        exakit_component_is_managed() { return 0; }
        exakit_component_current() { case "$1" in exapump) echo 1.0 ;; *) return 1 ;; esac; }
        exakit_component_available() { echo 2.0; }
        exakit_update_component() { printf "MODULE:%s\n" "$1"; return 0; }
        _exakit_update_run "exapump dbt-exasol" "exapump
dbt-exasol"; _rc=$?
        printf "RC=%s\n" "$_rc"
        if [ "$2" = 1 ]; then _exakit_update_json_report "$EXAKIT_UPDATE_RESULTS" "$_rc"; fi' _ "$ROOT" "$1" 2>&1
    rm -rf "$_ucs_mtmp"
}
_ucs_out="$(_ucs_missing 0)"
check "a named add-on that is not installed: its module never runs, the others do" "1|0" \
    "$(printf '%s\n' "$_ucs_out" | grep -c 'MODULE:exapump')|$(printf '%s\n' "$_ucs_out" | grep -c 'MODULE:dbt-exasol')"
check "...the screen says it is not installed and names the install" "1|1|1" \
    "$(printf '%s\n' "$_ucs_out" | grep -c 'dbt-exasol is not installed, so there is nothing to update. Install it with: exakit marketplace dbt-exasol')|$(printf '%s\n' "$_ucs_out" | grep -c 'Update finished with problems (updated: exapump). Install what is missing with: exakit marketplace dbt-exasol')|$(printf '%s\n' "$_ucs_out" | grep -c 'RC=1')"
check "...and never says it is not kit-owned or to retry the update" "0" \
    "$(printf '%s\n' "$_ucs_out" | grep -cE 'not kit-owned|Retry with: exakit update')"
_ucs_out="$(_ucs_missing 1)"
_ucs_json="$(printf '%s\n' "$_ucs_out" | sed -n '/^{/,/^}/p')"
check "--json: the failed row and the top-level remedy are the install" \
    "False|failed|exakit marketplace dbt-exasol|dbt-exasol|exakit marketplace dbt-exasol|dbt-exasol is not installed, so there is nothing to update.|exapump" \
    "$(printf '%s' "$_ucs_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); f=d["failed"][0]; print("|".join(str(x) for x in [d["ok"], d["status"], d["remedy"], f["component"], f["remedy"], f["error"], ",".join(u["component"] for u in d["updated"])]))' 2>&1)"

# The kit moves first, then the NEW kit finishes the run (#45): the same shell
# kept the old code and manifest and built a download URL the new release does
# not have. The new kit is handed the run (core-setup.sh's handover): `all`
# stays all - the new kit's list may hold components the old one does not know -
# and named ids hand over the kit and the ids after it. The new run skips the kit
# (EXAKIT_UPDATE_HANDOVER=1), updates the rest, makes its own new-setup check,
# and under --json writes its rows into the same results file, so the one
# object lists what it did - nothing is deferred. Only the updaters are stubbed;
# _exakit_update_run and the handover are the real ones.
_ucs_handoff() { # _ucs_handoff <json 0|1> <target> <targets> -> what ran here, what the new kit was asked, the rows
    _ucs_bin="$(mktemp -d)"
    cat > "$_ucs_bin/exakit" <<'UCS_FAKE'
#!/bin/sh
printf 'new-kit:%s handover=%s\n' "$*" "${EXAKIT_UPDATE_HANDOVER:-0}"
# The new run's own rows, as its _exakit_update_note writes them under --json.
if [ -n "${EXAKIT_UPDATE_RESULTS:-}" ] && [ "${EXAKIT_UPDATE_JSON:-0}" = 1 ]; then
    shift
    for _id in "$@"; do
        [ "$_id" = exakit ] && continue
        [ "$_id" = all ] && _id="exasol-scheduler dbt-exasol"
        for _one in $_id; do printf '%s|updated|1.0|2.0|\n' "$_one" >> "$EXAKIT_UPDATE_RESULTS"; done
    done
fi
exit 0
UCS_FAKE
    chmod +x "$_ucs_bin/exakit"
    EXAKIT_HOME="$_ucs_bin/kit" EXAKIT_BIN_DIR="$_ucs_bin" EXAKIT_UPDATE_JSON="$1" EXAKIT_UPDATE_RESULTS="$_ucs_bin/results" bash -c '
        . "$1/setup/lib/common.sh" >/dev/null 2>&1
        . "$1/setup/lib/core-setup.sh" >/dev/null 2>&1
        EXAKIT_BIN_DIR="$2"; EXAKIT_VERSION_POLICY=pinned
        exakit_print_versions_source_line() { :; }
        exakit_component_min_kit() { :; }
        exakit_component_is_managed() { return 0; }
        exakit_core_update_check() { :; }
        exakit_update_actual_target() { printf "%s\n" "$1"; }
        exakit_component_current() { case "$1" in exakit) cat "$EXAKIT_BIN_DIR/kit" 2>/dev/null || echo 0.2.0 ;; *) echo 1.0 ;; esac; }
        exakit_component_available() { case "$1" in exakit) echo 0.2.3 ;; *) echo 2.0 ;; esac; }
        exakit_update_component() { printf "this-shell:%s\n" "$1"; [ "$1" = exakit ] && echo 0.2.3 > "$EXAKIT_BIN_DIR/kit"; return 0; }
        _exakit_update_run "$3" "$4"
        [ -f "$EXAKIT_UPDATE_RESULTS" ] && cat "$EXAKIT_UPDATE_RESULTS"' _ "$ROOT" "$_ucs_bin" "$2" "$3" 2>&1
    rm -rf "$_ucs_bin"
}
_ucs_all="exakit
exasol-scheduler
dbt-exasol"
_ucs_out="$(_ucs_handoff 0 all "$_ucs_all")"
case "$_ucs_out" in
    *"this-shell:exakit"*"new-kit:update all handover=1"*) pass "after the kit moves, the new kit is handed the run: all stays all" ;;
    *) fail "the run was not handed to the new kit as all: $_ucs_out" ;;
esac
case "$_ucs_out" in
    *"this-shell:exasol-scheduler"*|*"this-shell:dbt-exasol"*) fail "...and this shell still updated an add-on with the old code" ;;
    *) pass "...and the old shell updates nothing after the kit" ;;
esac
_ucs_out="$(_ucs_handoff 1 all "$_ucs_all")"
case "$_ucs_out" in
    *"exasol-scheduler|updated|1.0|2.0|"*"dbt-exasol|updated|1.0|2.0|"*) pass "under --json the handed-over run's rows are the answer" ;;
    *) fail "under --json the new run's rows are missing: $_ucs_out" ;;
esac
case "$_ucs_out" in
    *"|deferred|"*) fail "...and nothing is deferred, yet a row was: $_ucs_out" ;;
    *) pass "...and nothing is deferred" ;;
esac
# Named ids: the ones before the kit are done here, so only the kit and the ids
# after it are handed over - none is listed as both updated and current.
_ucs_out="$(_ucs_handoff 0 "exasol-scheduler exakit dbt-exasol" "exasol-scheduler
exakit
dbt-exasol")"
case "$_ucs_out" in
    *"this-shell:exasol-scheduler"*"this-shell:exakit"*"new-kit:update exakit dbt-exasol handover=1"*) pass "named ids: the kit and the ids after it are handed over" ;;
    *) fail "named ids were not handed over as the kit and the ids after it: $_ucs_out" ;;
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
mkdir -p "$_UCS_HOME/kit" && printf '{"runtime":{"type":"personal","ownership":"kit"},"kit":{"version":"0.2.0"},"components":{"personal":{"ownership":"kit"},"exapump":{"ownership":"kit"},"mcp_server":{"ownership":"kit"},"pyexasol":{"ownership":"kit"}}}\n' > "$_UCS_HOME/kit/manifest.json"
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

printf '\n== a v-prefixed pin is the same version as the bare one it installed ==\n'
# versions.json pins semantic-views v0.6.1 (a git tag) and its probe answers
# 0.6.1. Compared as strings, every `exakit update` "updated" it 0.6.1 ->
# v0.6.1 (retiring and re-registering its module), never said everything was
# current, and the update notice returned after every command. Twin:
# tests/update-targets-ps.ps1.
mkdir -p "$_UCS_HOME/kit" && printf '{"kit":{"version":"0.2.0"},"components":{}}\n' > "$_UCS_HOME/kit/manifest.json"
_ucs_v="$(HOME="$_UCS_HOME" EXAKIT_HOME="$_UCS_HOME/kit" EXAKIT_BIN_DIR="$_UCS_HOME/bin" bash -c '
. "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
exakit_print_versions_source_line() { :; }
exakit_update_targets() { printf "%s\n" semantic-views json-tables exapump; }
exakit_component_supported() { return 0; }
exakit_component_is_managed() { return 0; }
exakit_component_min_kit() { return 1; }
_exakit_addon_needs_update() { return 1; }
exakit_component_current()   { case "$1" in semantic-views) echo 0.6.1;; json-tables) echo v0.4.1;; exapump) echo 0.14.0;; esac; }
exakit_component_available() { case "$1" in semantic-views) echo v0.6.1;; json-tables) echo 0.4.1;; exapump) echo v0.14.0;; esac; }
exakit_update_component() { echo "updater for $1"; return 0; }
exakit_update --json' 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d["status"], [e["component"] for e in d["updated"]], d["current"])' 2>/dev/null)"
check "0.6.1 against v0.6.1 (and v0.4.1 against 0.4.1) is current, nothing is updated" \
    "current [] ['semantic-views', 'json-tables', 'exapump']" "$_ucs_v"
_ucs_v="$(HOME="$_UCS_HOME" EXAKIT_HOME="$_UCS_HOME/kit" EXAKIT_BIN_DIR="$_UCS_HOME/bin" bash -c '
. "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
exakit_component_is_managed() { return 0; }
exakit_component_current() { case "$1" in mcp) echo 2.4.0;; exapump) echo 0.13.0;; esac; }
_exakit_notice_still_behind "mcp:v2.4.0,exapump:v0.14.0"' 2>/dev/null)"
# (The cached notice re-reads only the cheap components, never an add-on's module: mcp stands in here.)
check "the cached update notice drops a v-spelled match and keeps a real one" "exapump" "$_ucs_v"
_ucs_v="$(bash -c '. "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
for p in "0.6.1 v0.6.1" "v0.6.1 0.6.1" "v0.6.1 v0.6.1" "0.6.1 0.6.2" "vNext Next" " 0.6.1"; do
  set -- $p; if exakit_version_same "$1" "${2:-}"; then printf "y"; else printf "n"; fi; done')"
check "exakit_version_same ignores a leading v before a digit, and nothing else" "yyynnn" "$_ucs_v"

printf '\n== a component the kit did not install is updated through its owner, or kept ==\n'
# Product owner, 0.3.0: `exakit update` updates a uv or pyexasol the kit did
# not install THROUGH THE TOOL THAT OWNS IT (brew, pipx, the uv installer,
# that Python's pip), never by writing its files. An owner it cannot name, or
# an owner update that did not work, keeps it with one line naming the command
# (a warning row, exit 0). Equal or newer: nothing runs. Every owner below is a
# stub that records its argv; PATH holds only the stubs and python3, so no
# real brew, pipx, uv or pip is ever reached. Twin: tests/update-targets-ps.ps1.
_UCS_PY3="$(command -v python3)"
_ucs_sandbox() { # _ucs_sandbox -> a fresh $_UCS_S with stub owners
    _UCS_S="$(mktemp -d "${TMPDIR:-/tmp}/exakit-ucs-own.XXXXXX")"
    mkdir -p "$_UCS_S/bin" "$_UCS_S/brew/bin" "$_UCS_S/kit" "$_UCS_S/kitbin" "$_UCS_S/cfg"
    ln -s "$_UCS_PY3" "$_UCS_S/bin/python3"
    printf '{"kit":{"version":"0.3.0"},"components":{}}\n' > "$_UCS_S/kit/manifest.json"
    cat > "$_UCS_S/brew/bin/uv" <<UVSTUB
#!/bin/sh
case "\$1" in
  --version) echo "uv \$(cat "$_UCS_S/uvver")" ;;
  self) echo "uv \$*" >> "$_UCS_S/calls"; [ -f "$_UCS_S/owner-fails" ] && exit 1; echo "\$3" > "$_UCS_S/uvver" ;;
esac
UVSTUB
    cat > "$_UCS_S/bin/brew" <<BREWSTUB
#!/bin/sh
case "\$1" in
  --prefix) echo "$_UCS_S/brew" ;;
  list) [ -f "$_UCS_S/brew-owns" ] ;;
  *) echo "brew \$*" >> "$_UCS_S/calls"; [ -f "$_UCS_S/owner-fails" ] && exit 1; echo 0.13.8 > "$_UCS_S/uvver" ;;
esac
BREWSTUB
    cat > "$_UCS_S/bin/pipx" <<PIPXSTUB
#!/bin/sh
case "\$1" in
  environment) echo "$_UCS_S/pipx" ;;
  *) echo "pipx \$*" >> "$_UCS_S/calls"; echo 0.13.9 > "$_UCS_S/uvver" ;;
esac
PIPXSTUB
    # A user Python with pyexasol: the probe word comes from pymode.
    mkdir -p "$_UCS_S/venv/bin"
    rm -f "$_UCS_S/venv/bin/python"
    cat > "$_UCS_S/venv/bin/python" <<PYSTUB
#!/bin/sh
case "\$*" in
  *"-m pip"*) echo "python \$*" >> "$_UCS_S/calls"; [ -f "$_UCS_S/owner-fails" ] && exit 1; echo 2.5.0 > "$_UCS_S/pyxver" ;;
  *EXTERNALLY-MANAGED*) cat "$_UCS_S/pymode" ;;
  *) cat "$_UCS_S/pyxver" ;;
esac
PYSTUB
    chmod +x "$_UCS_S/brew/bin/uv" "$_UCS_S/bin/brew" "$_UCS_S/bin/pipx" "$_UCS_S/venv/bin/python"
    : > "$_UCS_S/calls"
}
_ucs_own() { # _ucs_own <component> <advertised> [--json] -> output of exakit update
    _ucs_c="$1"; _ucs_a="$2"; shift 2
    env -u EXAKIT_UV_BIN HOME="$_UCS_S" EXAKIT_HOME="$_UCS_S/kit" EXAKIT_BIN_DIR="$_UCS_S/kitbin" \
        XDG_CONFIG_HOME="$_UCS_S/cfg" PATH="$_UCS_S/bin:$_UCS_S/brew/bin:/usr/bin:/bin" \
        UCS_C="$_ucs_c" UCS_A="$_ucs_a" EXAKIT_LOG_FILE="$_UCS_S/log" bash -c '
. "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
exakit_print_versions_source_line() { :; }
exakit_versions_update_cache() { :; }
exakit_update_targets() { printf "%s\n" "$UCS_C"; }
exakit_component_supported() { return 0; }
exakit_component_ownership() { printf unknown; }
exakit_component_min_kit() { return 1; }
exakit_component_available() { echo "$UCS_A"; }
exakit_update_component() { echo "KIT UPDATER RAN for $1"; return 0; }
exakit_update "$@"' _ "$@" 2>&1
}
_ucs_row() { # _ucs_row <output> -> "status|ok|bucket comp from to remedy|hint"
    _json_range='/^{/,$p'      # assigned first: bash 3.2
    printf '%s\n' "$1" | sed -n "$_json_range" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for b in ("updated", "skipped", "ahead"):
    for e in d[b]:
        print("%s|%s|%s %s %s %s %s|%s" % (d["status"], d["ok"], b, e["component"], e["from"], e["to"], e.get("remedy"), e.get("remedy_hint")))
if d["current"]: print("%s|%s|current %s" % (d["status"], d["ok"], " ".join(d["current"])))' 2>&1
}

_ucs_sandbox; echo 0.13.2 > "$_UCS_S/uvver"; : > "$_UCS_S/brew-owns"
_ucs_out="$(_ucs_own uv 0.13.8)"; _ucs_rc=$?
check "a Homebrew uv behind the advertised version is updated with brew upgrade uv" "brew upgrade uv" "$(cat "$_UCS_S/calls")"
check "...the screen says which owner and which command" "1" \
    "$(printf '%s\n' "$_ucs_out" | grep -cF 'uv was installed with Homebrew. Updating it with: brew upgrade uv')"
check "...and the version it reached" "1" "$(printf '%s\n' "$_ucs_out" | grep -cF 'uv updated to 0.13.8 (Homebrew)')"
check "...the kit's own updater never runs on it, and the update exits 0" "0 0" \
    "$(printf '%s\n' "$_ucs_out" | grep -c 'KIT UPDATER RAN') $_ucs_rc"
echo 0.13.2 > "$_UCS_S/uvver"; : > "$_UCS_S/calls"
check "...the --json row is updated, with the owner" \
    "updated|True|updated uv 0.13.2 0.13.8 None|updated through its owner, Homebrew: brew upgrade uv" \
    "$(_ucs_row "$(_ucs_own uv 0.13.8 --json)")"

echo 0.13.8 > "$_UCS_S/uvver"; : > "$_UCS_S/calls"
_ucs_out="$(_ucs_own uv 0.13.8 --json)"
check "an equal uv runs nothing and is current" "|current|True|current uv" "$(cat "$_UCS_S/calls")|$(_ucs_row "$_ucs_out")"
echo 0.14.0 > "$_UCS_S/uvver"
_ucs_out="$(_ucs_own uv 0.13.8 --json)"
check "a newer uv runs nothing and is never moved back" "|current|True|ahead uv 0.14.0 0.13.8 None|None" \
    "$(cat "$_UCS_S/calls")|$(_ucs_row "$_ucs_out")"

echo 0.13.2 > "$_UCS_S/uvver"; : > "$_UCS_S/owner-fails"
_ucs_out="$(_ucs_own uv 0.13.8)"; _ucs_rc=$?
check "an owner update that fails is a warning, and the update still exits 0" "1 0" \
    "$(printf '%s\n' "$_ucs_out" | grep -cF 'Updating uv with Homebrew did not work, so uv 0.13.2 stays as it is. Run it yourself: brew upgrade uv') $_ucs_rc"
check "...its --json row is kept with the command as the remedy, ok stays true" \
    "current|True|skipped uv 0.13.2 0.13.8 brew upgrade uv|kept as it is: updating it with Homebrew did not work. Run the remedy yourself" \
    "$(_ucs_row "$(_ucs_own uv 0.13.8 --json)")"
rm -f "$_UCS_S/owner-fails" "$_UCS_S/brew-owns"; : > "$_UCS_S/calls"

_ucs_out="$(_ucs_own uv 0.13.8)"
check "a uv whose owner cannot be found is kept, and nothing runs" "|1" \
    "$(cat "$_UCS_S/calls")|$(printf '%s\n' "$_ucs_out" | grep -cF 'Leaving uv 0.13.2 as it is. The kit did not install it and could not tell which tool did, so update it with the tool you installed it with.')"
check "...its --json row says why" \
    "current|True|skipped uv 0.13.2 0.13.8 None|kept as it is: installed outside the kit, and the tool that installed it could not be found. Update it with that tool" \
    "$(_ucs_row "$(_ucs_own uv 0.13.8 --json)")"
check "...and the uv files are untouched" "0.13.2" "$(cat "$_UCS_S/uvver")"

# The uv installer's receipt names the folder this uv is in: uv self update,
# to the advertised version.
mkdir -p "$_UCS_S/cfg/uv"
printf '{"binaries":["uv","uvx"],"install_prefix":"%s","version":"0.13.2"}\n' "$_UCS_S/brew/bin" > "$_UCS_S/cfg/uv/uv-receipt.json"
_ucs_out="$(_ucs_own uv 0.13.8)"
check "a uv from the uv installer is updated with uv self update <advertised>" "uv self update 0.13.8|1" \
    "$(cat "$_UCS_S/calls")|$(printf '%s\n' "$_ucs_out" | grep -cF 'uv updated to 0.13.8 (the uv installer)')"
rm -rf "$_UCS_S"

# pipx: the uv on PATH is a link into pipx's own venvs/uv.
_ucs_sandbox; echo 0.13.2 > "$_UCS_S/uvver"
mkdir -p "$_UCS_S/pipx/venvs/uv/bin"; mv "$_UCS_S/brew/bin/uv" "$_UCS_S/pipx/venvs/uv/bin/uv"
ln -s "$_UCS_S/pipx/venvs/uv/bin/uv" "$_UCS_S/bin/uv"
_ucs_out="$(_ucs_own uv 0.13.8)"
check "a pipx uv is updated with pipx upgrade uv" "pipx upgrade uv|1" \
    "$(cat "$_UCS_S/calls")|$(printf '%s\n' "$_ucs_out" | grep -cF 'uv updated to 0.13.9 (pipx)')"
rm -rf "$_UCS_S"

# pyexasol in the user's own Python: that Python's pip, only where it may.
_ucs_sandbox; echo 2.3.0 > "$_UCS_S/pyxver"; echo venv > "$_UCS_S/pymode"
printf '{"kit":{"version":"0.3.0"},"components":{"pyexasol":{"python":"%s"}}}\n' "$_UCS_S/venv/bin/python" > "$_UCS_S/kit/manifest.json"
_ucs_out="$(_ucs_own pyexasol 2.4.1)"
check "a user pyexasol in a venv is updated with that Python's pip" \
    "python -m pip install --upgrade pyexasol|1" \
    "$(cat "$_UCS_S/calls")|$(printf '%s\n' "$_ucs_out" | grep -cF 'pyexasol updated to 2.5.0 (pip)')"
echo 2.3.0 > "$_UCS_S/pyxver"; echo managed > "$_UCS_S/pymode"; : > "$_UCS_S/calls"
_ucs_out="$(_ucs_own pyexasol 2.4.1)"
check "a PEP 668 (externally managed) Python is kept: no pip, no --break-system-packages" "|1" \
    "$(cat "$_UCS_S/calls")|$(printf '%s\n' "$_ucs_out" | grep -c 'Leaving pyexasol 2.3.0 as it is. Its Python (.*) is managed by the operating system or a package manager (PEP 668), so the kit does not install into it. Update it with that package manager.')"
echo readonly > "$_UCS_S/pymode"
_ucs_out="$(_ucs_own pyexasol 2.4.1 --json)"
check "a Python the user cannot write to is kept, and nothing runs" \
    "|current|True|skipped pyexasol 2.3.0 2.4.1 None|kept as it is: the kit cannot update it safely in that Python environment. Update it the way you installed it" \
    "$(cat "$_UCS_S/calls")|$(_ucs_row "$_ucs_out")"
rm -rf "$_UCS_S"

# Everything else the kit did not install keeps the line it always had.
_ucs_sandbox
_ucs_out="$(HOME="$_UCS_S" EXAKIT_HOME="$_UCS_S/kit" EXAKIT_BIN_DIR="$_UCS_S/kitbin" PATH="$_UCS_S/bin:/usr/bin:/bin" bash -c '
. "'"$ROOT"'/setup/lib/common.sh" 2>/dev/null
exakit_print_versions_source_line() { :; }
exakit_update_targets() { printf "%s\n" exapump; }
exakit_component_supported() { return 0; }
exakit_component_ownership() { printf user; }
exakit_component_min_kit() { return 1; }
exakit_component_current()   { echo 0.13.0; }
exakit_component_available() { echo 0.14.0; }
exakit_update_component() { echo "KIT UPDATER RAN for $1"; return 0; }
exakit_update' 2>&1)"
check "a user exapump keeps the line it always had, no owner command runs" "1|0|" \
    "$(printf '%s\n' "$_ucs_out" | grep -cF 'Leaving exapump as it is (the kit did not install it, or has no record that it did).')|$(printf '%s\n' "$_ucs_out" | grep -c 'KIT UPDATER RAN')|$(cat "$_UCS_S/calls")"
rm -rf "$_UCS_S"
rm -rf "$_UCS_HOME"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
