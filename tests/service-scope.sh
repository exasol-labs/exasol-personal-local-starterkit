#!/usr/bin/env bash
# service-scope.sh — `exakit start|stop <service>` acts on ONE service, and a
# bad id changes nothing.
#
#   bash tests/service-scope.sh
#
# `exakit stop exasol-scheduler` used to stop the database. The dash-only
# option guard let the word through, the dispatch arm dropped it, and the bare
# form ran: every add-on, then the database. It only LOOKED scoped because one
# add-on was installed (exasol-labs/exasol-personal-local-starterkit#28). The
# per-service helpers (exakit_service_start/stop <id>) had existed all along;
# nothing called them one at a time.
#
# Two halves. Static guards pin the wiring on both platforms. The functional
# half drives the real cmd_start/cmd_stop with the database and an add-on
# STUBBED - no deployment is ever touched, because a sandboxed kit home with
# the developer's real launcher on PATH is exactly how a test stops someone's
# database by accident.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/tests/lib/utf8-locale.sh"
PASS=0; FAIL=0
check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}
has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CLI="$ROOT/setup/exakit"
SH="$(cat "$CLI")"
PS="$(cat "$ROOT/setup/exakit.ps1")"

# The developer's own add-on launchers must not be visible: an add-on that
# PROBES as installed would turn "not installed, nothing to stop" into a real
# stop hook. Same scrub as tests/marketplace.sh.
_clean_path=""
_old_ifs="$IFS"; IFS=:
for _dir in $PATH; do
    _keep=1
    for _launcher in dash-server exasol-json-tables dbt-exasol exasol-scheduler; do
        [ -x "$_dir/$_launcher" ] && { _keep=0; break; }
    done
    [ "$_keep" = 1 ] && _clean_path="${_clean_path:+$_clean_path:}$_dir"
done
IFS="$_old_ifs"
PATH="$_clean_path"
export PATH

printf '\n== the arguments reach the command on both platforms ==\n'
has "the shell start arm passes its arguments on" '_with_notice cmd_start "$@"' "$SH"
has "...and the stop arm"                          '_with_notice cmd_stop "$@"'  "$SH"
has "the Windows start arm passes its arguments on" 'Invoke-CmdStart -Scope @($RestArgs)' "$PS"
has "...and the stop arm"                            'Invoke-CmdStop -Scope @($RestArgs)'  "$PS"

printf '\n== the scope is settled before anything runs, in the main shell ==\n'
_cmd_stop="$(sed -n '/^cmd_stop()/,/^}/p' "$CLI")"
_cmd_start="$(sed -n '/^cmd_start()/,/^}/p' "$CLI")"
has "cmd_stop validates first"  '_service_scope stop "$@"'  "$_cmd_stop"
has "cmd_start validates first" '_service_scope start "$@"' "$_cmd_start"
# reject() exits; inside $(...) that ends only the subshell and the caller runs
# the bare form on the refused input. So the validator is never substituted.
lacks "...never through a command substitution" '$(_service_scope' "$SH"
has "a scoped stop reaches the per-service helper"  'exakit_service_stop "$EXAKIT_SERVICE_SCOPE"'  "$_cmd_stop"
has "a scoped start reaches the per-service helper" 'exakit_service_start "$EXAKIT_SERVICE_SCOPE"' "$_cmd_start"
has "the bare stop still stops the database" 'personal) personal_stop ;;' "$_cmd_stop"
has "the Windows bare stop still stops the database" '"personal" { Stop-Personal }' \
    "$(awk '/^function Invoke-CmdStop/{p=1} p{print; if(/^}/){exit}}' "$ROOT/setup/exakit.ps1")"
has "the Windows scope resolver refuses through Deny-ExakitInput (exit 2)" 'Deny-ExakitInput "Unknown service' "$PS"
has "autostart is untouched (it still takes no arguments)" 'autostart takes no arguments' "$SH"

printf '\n== bad input exits 2 and changes nothing (through the CLI) ==\n'
# A kit that is installed as far as the manifest is concerned, in a sandbox:
# EXAKIT_BIN_DIR sandboxed too, so no add-on probes as installed.
KIT="$WORK/kit"; mkdir -p "$KIT" "$WORK/bin"
printf '{\n  "runtime": {\n    "type": "personal"\n  }\n}\n' > "$KIT/manifest.json"
_cli() { EXAKIT_HOME="$KIT" EXAKIT_BIN_DIR="$WORK/bin" bash "$CLI" "$@"; }
_rc() { _cli "$@" >/dev/null 2>&1; echo $?; }
_err() { _cli "$@" 2>&1 >/dev/null; }

check "stop with two ids exits 2"               "2" "$(_rc stop a b)"
has   "...and says so"                          "at most one service id" "$(_err stop a b)"
check "start with two ids exits 2"              "2" "$(_rc start a b)"
# Shape before the install check: the same bad input on a bare machine is
# still bad input, not "not installed".
check "two ids with no kit at all still exits 2" "2" "$(EXAKIT_HOME="$WORK/none" bash "$CLI" stop a b >/dev/null 2>&1; echo $?)"
check "an unknown service exits 2"              "2" "$(_rc stop nosuch)"
has   "...names it"                             "Unknown service 'nosuch'" "$(_err stop nosuch)"
has   "...and lists what this machine has"      "services on this machine: database" "$(_err stop nosuch)"
check "start of an unknown service exits 2"     "2" "$(_rc start nosuch)"
check "a known add-on that is not installed exits 2" "2" "$(_rc stop exasol-scheduler)"
has   "...and names the marketplace"            "exakit marketplace exasol-scheduler" "$(_err stop exasol-scheduler)"
has   "...for start too"                        "exakit marketplace dash-server" "$(_err start dash-server)"
check "an unknown option is still refused"      "2" "$(_rc stop --bogus)"
check "...with --json answered as one object"   "True" \
    "$(_cli stop --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["rejected"])' 2>/dev/null)"
check "an unknown id with no kit exits 4 (the registry needs an install)" "4" \
    "$(EXAKIT_HOME="$WORK/none" bash "$CLI" stop nosuch >/dev/null 2>&1; echo $?)"
lacks "no refusal recorded a failure note" ".last-failure" "$(ls -A "$KIT" 2>/dev/null)"

printf '\n== one service, and only that one (database and add-on stubbed) ==\n'
# The real cmd_start/cmd_stop/_service_scope, lifted out of the CLI, over the
# real registry helpers from common.sh - with the two things that would touch
# a machine replaced by echoes: the database (personal_stop, _start_database)
# and an add-on's hooks (zzfake_*, found by the same name convention the
# registry uses). exakit_service_ids is stubbed to list that add-on, since a
# fake cannot be registered.
HARNESS="$WORK/harness.sh"
{
    printf 'set -u\nEXAKIT_HOME=%s\nEXAKIT_BIN_DIR=%s\n' "$KIT" "$WORK/bin"
    printf '. "%s/setup/lib/common.sh"\n' "$ROOT"
    printf '. "%s/setup/lib/dash-server.sh"\n' "$ROOT"
    printf '. "%s/setup/lib/exasol-scheduler.sh"\n' "$ROOT"
    sed -n '/^_service_scope()/,/^}/p' "$CLI"
    sed -n '/^cmd_start()/,/^}/p' "$CLI"
    sed -n '/^cmd_stop()/,/^}/p' "$CLI"
    sed -n '/^_stop_database_scoped()/,/^}/p' "$CLI"
    cat <<'STUBS'
_require_install()        { echo "require-install"; }
_runtime_type()           { echo personal; }
exakit_init_logging()     { :; }
_exakit_log_file()        { :; }
reject()                  { echo "REJECT $*"; exit 2; }
warn()                    { echo "WARN $*"; }
personal_stop()           { echo "STOP database"; }
_start_database()         { echo "START database"; }
exakit_service_ids()      { printf 'database\nzzfake\n'; }
zzfake_status()           { echo "${ZZ_STATUS:-running}"; }
zzfake_start()            { echo "START zzfake"; }
zzfake_stop()             { echo "STOP zzfake"; }
exakit_runtime_is_running() { [ "${DB_UP:-1}" = 1 ]; }
_exakit_prompt_tty()      { :; }
STUBS
    printf '"$@"\n'
} > "$HARNESS"
_run() { bash "$HARNESS" "$@" 2>&1; }

_bare="$(_run cmd_stop)"
has   "bare stop stops the add-on"            "STOP zzfake"    "$_bare"
has   "...and then the database"              "STOP database"  "$_bare"
check "...add-ons first"                      "yes" "$(printf '%s\n' "$_bare" | awk '/STOP zzfake/{a=NR} /STOP database/{d=NR} END{print (a && d && a<d) ? "yes" : "no"}')"

_one="$(_run cmd_stop zzfake)"
has   "stop <addon> stops that add-on"        "STOP zzfake"    "$_one"
lacks "...and leaves the database alone"      "STOP database"  "$_one"

# `exakit stop database` under a running add-on asks first. The harness has no
# terminal (_exakit_prompt_tty stubbed), so EXAKIT_STOP_ADDONS carries the
# answer, and no answer at all takes the safe side: the add-on goes down too.
unset EXAKIT_STOP_ADDONS
_db="$(EXAKIT_STOP_ADDONS=0 bash "$HARNESS" cmd_stop database 2>&1)"
has   "stop database, answered no, stops the database" "STOP database" "$_db"
lacks "...and leaves the running add-on alone" "STOP zzfake"   "$_db"
has   "...naming what still runs without it"  "Still running without it: zzfake" "$_db"
has   "...and the start it will need afterwards" "you must also start it: exakit start zzfake" "$_db"

_dby="$(EXAKIT_STOP_ADDONS=1 bash "$HARNESS" cmd_stop database 2>&1)"
has   "stop database, answered yes, stops the add-on too" "STOP zzfake" "$_dby"
has   "...and the database"                   "STOP database"  "$_dby"
check "...add-ons first"                      "yes" "$(printf '%s\n' "$_dby" | awk '/STOP zzfake/{a=NR} /STOP database/{d=NR} END{print (a && d && a<d) ? "yes" : "no"}')"
lacks "...with no reminder to give"           "you must also start" "$_dby"

_dbq="$(_run cmd_stop database)"
has   "no answer and no terminal stops the add-on too" "STOP zzfake" "$_dbq"
has   "...after naming it"                    "Running add-on services need the database: zzfake" "$_dbq"

_dbs="$(ZZ_STATUS=stopped bash "$HARNESS" cmd_stop database 2>&1)"
has   "a stopped add-on raises no question"   "STOP database"  "$_dbs"
lacks "...and is not stopped again"           "STOP zzfake"    "$_dbs"
lacks "...nor named"                          "need the database" "$_dbs"

_bad="$(_run cmd_stop nosuch)"
has   "stop nosuch is refused"                "REJECT Unknown service 'nosuch'" "$_bad"
has   "...listing the services"               "database, zzfake" "$_bad"
lacks "...and nothing was stopped"            "STOP"           "$_bad"
check "...with exit 2"                        "2" "$(bash "$HARNESS" cmd_stop nosuch >/dev/null 2>&1; echo $?)"
_gone="$(_run cmd_stop exasol-scheduler)"
has   "a registered add-on that is not installed is refused" "not installed" "$_gone"
has   "...naming the marketplace"             "exakit marketplace exasol-scheduler" "$_gone"
lacks "...and nothing was stopped"            "STOP"           "$_gone"

_bs="$(_run cmd_start)"
has   "bare start starts the database"        "START database" "$_bs"
has   "...and the add-on"                     "START zzfake"   "$_bs"

_sa="$(_run cmd_start zzfake)"
has   "start <addon> starts that add-on"      "START zzfake"   "$_sa"
lacks "...and does not start the database"    "START database" "$_sa"

_sd="$(_run cmd_start database)"
has   "start database starts the database"    "START database" "$_sd"
lacks "...and not the add-on"                 "START zzfake"   "$_sd"

_down="$(DB_UP=0 bash "$HARNESS" cmd_start zzfake 2>&1)"
has   "start <addon> with the database down refuses" "REJECT The database is not running" "$_down"
has   "...and names the bare command"         "exakit start"   "$_down"
lacks "...starting nothing"                   "START"          "$_down"
check "...with the refusal code, like every other refusal here" "2" "$(DB_UP=0 bash "$HARNESS" cmd_start zzfake >/dev/null 2>&1; echo $?)"
has   "...and the help says which code"       "refuses (exit 2)" "$(cat "$ROOT/setup/help/exakit.json")"
has   "the Windows twin refuses the same way" 'Deny-ExakitInput "The database is not running, and $id needs it' "$PS"

printf '\n== the help and the agent contract say so ==\n'
_help="$(python3 - "$ROOT/setup/help/exakit.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for c in doc["commands"]:
    if c["command"] in ("start", "stop"):
        print(c["command"], c["options"], " ".join(c["examples"]))
PY
)"
has "start takes an optional service in the help" "start [<service>]" "$_help"
has "stop takes an optional service in the help"  "stop [<service>]"  "$_help"
has "...with a scoped example"                    "exakit stop exasol-scheduler" "$_help"
has "AGENTS.md documents the scoped form"         'exakit stop <service>' "$(cat "$ROOT/AGENTS.md")"
has "stop database asks before taking the database from running add-ons" 'confirm_env EXAKIT_STOP_ADDONS' "$SH"
has "...and the Windows twin asks the same question" 'Confirm-ExakitEnvPrompt -EnvName "EXAKIT_STOP_ADDONS"' "$PS"
has "...the help says so"                         "EXAKIT_STOP_ADDONS" "$(cat "$ROOT/setup/help/exakit.json")"
has "...and so does AGENTS.md"                    "EXAKIT_STOP_ADDONS" "$(cat "$ROOT/AGENTS.md")"

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
