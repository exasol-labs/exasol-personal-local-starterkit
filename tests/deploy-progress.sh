#!/usr/bin/env bash
# deploy-progress.sh — proves the two "something is happening" guarantees:
#
#   1. `exasol install local` is no longer echoed to the screen. Its output is
#      consumed into a progress line, while every raw byte still reaches the
#      logfile, the tail survives for a failed deploy, and the launcher's EULA
#      notice is replayed.
#   2. A long, silent step is animated under a truthful label: fetch_quiet keeps
#      the spinner outside the logfile redirect, and an add-on install names
#      itself instead of borrowing the previous step's title.
#
#   bash tests/deploy-progress.sh
#
# Pure logic against a sandboxed kit home: no network, no launcher, no install.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

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

# Same isolation rule as the other suites: common.sh derives its paths at source
# time, so the kit home and HOME are redirected before it is read.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
HOME="$WORK/fake-home"
export HOME
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR" "$HOME"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/runtime-personal.sh"

EXAKIT_LOG_FILE="$WORK/install.log"
: > "$EXAKIT_LOG_FILE"

# A real `exasol install local` run, warm cache: the nine structured log lines
# and the connection overview that follows them. Trimmed only where the same
# shape repeats.
cat > "$WORK/launcher.txt" <<'LAUNCHEREOF'
{"time":"2026-08-26T05:18:24.887779+05:30","level":"INFO","msg":"validating presets"}
{"time":"2026-08-26T05:18:24.889452+05:30","level":"INFO","msg":"extracting preset files","infrastructure":{"Name":"local","Path":""}}
{"time":"2026-08-26T05:18:24.901145+05:30","level":"INFO","msg":"successfully initialized deployment","infrastructure":"local"}
{"time":"2026-08-26T05:18:25.067073+05:30","level":"INFO","msg":"found resource in cache","id":"exasol-local-runner","path":"/Users/x/Library/Caches/.exasol/personal/runtime-artifacts/artifacts/exasol-local-runner/darwin/arm64/74e3ef/unpack/launcher"}
{"time":"2026-08-26T05:18:33.433226+05:30","level":"INFO","msg":"found resource in cache","id":"exasol-local-runner","path":"/Users/x/Library/Caches/.exasol/personal/runtime-artifacts/artifacts/exasol-local-runner/darwin/arm64/74e3ef/unpack/launcher"}
{"time":"2026-08-26T05:18:49.020956+05:30","level":"INFO","msg":"waiting for database to start","elapsed_seconds":0,"next_retry_in_seconds":2,"remaining_seconds":297}
{"time":"2026-08-26T05:18:53.683701+05:30","level":"INFO","msg":"no installation steps defined; skipping"}
{"time":"2026-08-26T05:18:53.700245+05:30","level":"INFO","msg":"Completed deploying"}
Using default deployment directory: /Users/x/.exasol/personal/deployments/default
For your reference:
By using the Exasol Personal launcher, you accept its End User License Agreement (EULA):
https://www.exasol.com/terms-and-conditions/#h-exasol-personal-end-user-license-agreement

A copy of the EULA is also included as 'eula.txt' in this directory.

Exasol Personal Deployment Overview
Deployment directory: /Users/x/.exasol/personal/deployments/default
Deployment ID: 28e35d75
Deployment State: running
  - Password: <stored in /Users/x/.exasol/personal/deployments/default/secrets.json>
  Alternative: ssh -i local/node_access.pem root@127.0.0.1 -p 56732
=== Exasol Product Documentation ===
  https://docs.exasol.com/
LAUNCHEREOF
LAUNCHER_LINES="$(wc -l < "$WORK/launcher.txt" | tr -d ' ')"

printf '\n== the launcher stream is consumed, not printed ==\n'

STATE="$WORK/state"; TAIL="$WORK/tail"; NOTICE="$WORK/notice"
printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
# EXAKIT_DEPLOY_LIVE=1 is the animated case: the collector must print NOTHING,
# because the animator owns the screen.
EXAKIT_DEPLOY_LIVE=1
SCREEN="$(_personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" < "$WORK/launcher.txt")"
check "animated run prints nothing" "" "$SCREEN"
lacks "no JSON on screen" '"level":"INFO"' "$SCREEN"
lacks "no secrets.json path on screen" "secrets.json" "$SCREEN"
lacks "no ssh line on screen" "node_access.pem" "$SCREEN"

# ...while the logfile still has every raw line, unchanged.
check "every raw line logged" "$LAUNCHER_LINES" "$(wc -l < "$EXAKIT_LOG_FILE" | tr -d ' ')"
has "raw JSON is in the log" '"msg":"Completed deploying"' "$(cat "$EXAKIT_LOG_FILE")"
has "overview is in the log" "Deployment ID: 28e35d75" "$(cat "$EXAKIT_LOG_FILE")"
check "tail file mirrors the stream" "$LAUNCHER_LINES" "$(wc -l < "$TAIL" | tr -d ' ')"

printf '\n== the bar reaches the end, and only ever moves forward ==\n'

# pct|ceiling|seconds|segment-start|phase — the segment's own clock is written
# with it, which is what lets the bar move while the launcher is silent.
check "the bar ends at 100" "100" "$(cut -d'|' -f1 "$STATE")"
check "with the final phase"  "Deployed" "$(cut -d'|' -f5 "$STATE")"

# Out-of-order and repeated milestones must not rewind the bar: a launcher that
# retries a stage would otherwise walk the percentage backwards on screen.
printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
printf '%s\n' \
    '{"msg":"validating presets"}' \
    '{"msg":"found resource in cache"}' \
    '{"msg":"found resource in cache"}' \
    '{"msg":"extracting preset files"}' \
    | _personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" >/dev/null
check "a lower milestone never rewinds" "35" "$(cut -d'|' -f1 "$STATE")"
check "...keeping its phase"          "Getting Exasol ready" "$(cut -d'|' -f5 "$STATE")"

printf '\n== a silent launcher is noticed, not waited on forever ==\n'

# THE HANG THIS PINS: the launcher re-attaches stdin to the terminal so a
# first-run licence confirmation can read the keyboard - but the prompt text
# arrives here without a newline, so it never leaves the pipe. The install sat
# at 5%% forever with the question invisible. The collector's bounded read now
# notices the silence, stops the bar, prints the tail and says how to act; a
# launcher that then speaks again resumes on screen.
printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
STALLED="$( { printf '{"msg":"validating presets"}\n'; sleep 6; printf '{"msg":"Completed deploying"}\n'; } | \
    EXAKIT_PERSONAL_DEPLOY_STALL=3 EXAKIT_DEPLOY_LIVE=1 \
    _personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" 2>&1 )"
has "the stall is announced"            "The launcher has said nothing" "$STALLED"
has "the keyboard hint is given"        "Your keyboard is still connected" "$STALLED"
has "the tail is shown"                 "last lines from the exasol launcher" "$STALLED"
has "the escape hatch is named"         "Ctrl-C is safe" "$STALLED"
has "a late milestone still lands"      "Deployed" "$STALLED"
check "and the bar still completes"     "100" "$(cut -d'|' -f1 "$STATE")"

# A launcher with no gaps must never see any of that.
printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
QUICK="$(printf '{"msg":"validating presets"}\n{"msg":"Completed deploying"}\n' | \
    EXAKIT_PERSONAL_DEPLOY_STALL=3 EXAKIT_DEPLOY_LIVE=1 \
    _personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" 2>&1)"
check "a gapless stream stays silent"   "" "$QUICK"

printf '\n== unknown output is harmless ==\n'

printf '10|20|2|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
NOISE="$(printf '%s\n' 'a line no launcher release ever wrote' '{"msg":"brand new message"}' \
    | _personal_deploy_collect "$STATE" "$TAIL" "$NOTICE")"
check "unknown lines print nothing" "" "$NOISE"
check "unknown lines do not move the bar" "10" "$(cut -d'|' -f1 "$STATE")"

printf '\n== without an animation, each phase gets one plain line ==\n'

printf '0|5|3|0|Preparing to deploy\n' > "$STATE"
: > "$TAIL"; : > "$NOTICE"
EXAKIT_DEPLOY_LIVE=0
PLAIN="$(_personal_deploy_collect "$STATE" "$TAIL" "$NOTICE" < "$WORK/launcher.txt")"
has "phase: preparing"  "Preparing to deploy"          "$PLAIN"
has "phase: getting ready" "Getting Exasol ready" "$PLAIN"
# The label has to hold for BOTH launcher messages this arm matches. It said
# "Fetching the Exasol runtime" for a cache hit too, where nothing is fetched
# and the launcher then goes quiet for the VM boot.
check "the cached path says the same" "Getting Exasol ready" \
    "$(_personal_deploy_milestone 'found resource in cache' | cut -d'|' -f4)"
check "and so does the download path" "Getting Exasol ready" \
    "$(_personal_deploy_milestone 'fetching resource abc' | cut -d'|' -f4)"
lacks "nothing still says 'runtime' at the reader" "Fetching the Exasol runtime" "$PLAIN"
has "phase: waiting"    "Waiting for Exasol" "$PLAIN"
has "phase: finishing"  "Finishing up"                      "$PLAIN"
has "phase: deployed"   "Deployed"                          "$PLAIN"
lacks "still no JSON" '"level":"INFO"' "$PLAIN"
# "Preparing to deploy" is three milestones; it must be said once.
check "a repeated phase is said once" "1" \
    "$(printf '%s\n' "$PLAIN" | grep -c 'Preparing to deploy')"

printf '\n== the EULA notice survives the stream being hidden ==\n'

NOTICE_OUT="$(_personal_deploy_print_notice "$NOTICE")"
has "EULA sentence replayed" "you accept its End User License Agreement" "$NOTICE_OUT"
has "EULA link replayed" "https://www.exasol.com/terms-and-conditions/" "$NOTICE_OUT"

printf '\n== a failed deploy still shows the launcher its own words ==\n'

TAIL_OUT="$(_personal_deploy_print_tail "$TAIL")"
has "tail is announced" "last lines from the exasol launcher" "$TAIL_OUT"
has "tail has the launcher's end" "https://docs.exasol.com/" "$TAIL_OUT"
check "tail is bounded (1 note + 12 lines)" "13" "$(printf '%s\n' "$TAIL_OUT" | wc -l | tr -d ' ')"
check "an empty tail prints nothing" "" "$(_personal_deploy_print_tail "$WORK/absent")"

printf '\n== the bar keeps moving while the launcher says nothing ==\n'

# The launcher is silent for about twenty-five seconds between "found resource
# in cache" and "waiting for database to start", which is the longest stretch of
# the deploy. Milestones stay the truth; the time between them is filled in.
SEG="$(_personal_deploy_milestone '{"msg":"found resource in cache"}')"
check "the segment knows where it ends" "35|65|25" "${SEG%|*}"
check "at the start it is the milestone" "35" "$(ui_progress_creep 35 65 25 0)"
check "a third of the way in"            "44" "$(ui_progress_creep 35 65 25 8)"
check "two thirds"                       "54" "$(ui_progress_creep 35 65 25 16)"
# Capped one point BELOW the next milestone: arriving at it must still be
# something the reader sees happen...
check "just before the next stage"       "64" "$(ui_progress_creep 35 65 25 25)"
# ...and a stage that runs long waits there rather than walking into the next
# one's territory.
check "a stage that overruns waits"      "64" "$(ui_progress_creep 35 65 25 300)"
check "never before its own milestone"   "35" "$(ui_progress_creep 35 65 25 0)"
# A milestone with nowhere to creep to just sits on its number.
check "the final milestone does not creep" "100" "$(ui_progress_creep 100 100 0 9)"
check "nor does a zero-length segment"     "65"  "$(ui_progress_creep 65 65 10 5)"

printf '\n== the progress line carries a bar, a percentage and a clock ==\n'

UI_SPIN_FRAMES=(a b c d e f g h i j)
BAR="$(ui_progress_line 65 "Waiting for Exasol" 42 0 100)"
has "percentage rendered" "65%" "$BAR"
has "phase rendered" "Waiting for Exasol" "$BAR"
has "elapsed rendered" "(42s)" "$BAR"
has "bar is filled" "$UI_BAR_FULL" "$BAR"
has "bar has a remainder" "$UI_BAR_EMPTY" "$BAR"
# 100% must fill the bar exactly, not overflow it.
FULL="$(ui_progress_line 100 Deployed 9 0 100)"
lacks "a full bar has no remainder" "$UI_BAR_EMPTY" "$FULL"

printf '\n== a download animates instead of going silent ==\n'

# fetch_quiet must start the spinner BEFORE redirecting to the log — the whole
# point of it. Proven by what reaches the caller: stdout stays clean, the
# command's chatter lands in the log, and a failure is soft (fetch would die).
fetch() { printf 'curl noise\n'; return 7; }   # stub: no network in this suite
: > "$EXAKIT_LOG_FILE"
FQ_OUT="$(fetch_quiet https://example.invalid/x "$WORK/dl" 2>&1)"
FQ_RC=$?
check "a failed download is soft" "7" "$FQ_RC"
check "its chatter is off screen" "" "$FQ_OUT"
has "its chatter is in the log" "curl noise" "$(cat "$EXAKIT_LOG_FILE")"
fetch() { printf 'curl noise\n'; return 0; }
fetch_quiet https://example.invalid/x "$WORK/dl" >/dev/null 2>&1
check "a good download reports success" "0" "$?"

# The ORDER is the fix. Give the spinner a voice: started before the redirect it
# reaches the caller, started inside it (what every add-on download used to do)
# it would be swallowed by the logfile. The stubs stay for the rest of the run;
# nothing below animates.
ui_spin_begin() { printf 'SPINNER\n'; }
ui_spin_end()   { :; }
: > "$EXAKIT_LOG_FILE"
SPIN_OUT="$(fetch_quiet https://example.invalid/x "$WORK/dl" 2>&1)"
has   "the spinner starts before the redirect" "SPINNER" "$SPIN_OUT"
lacks "the spinner is not swallowed by the log" "SPINNER" "$(cat "$EXAKIT_LOG_FILE")"

printf '\n== the wiring itself stays wired ==\n'

RP="$(cat "$ROOT/setup/lib/runtime-personal.sh")"
lacks "the launcher is not streamed to the screen" \
    "install local 2>&1 | exakit_stream_foreign" "$RP"
has "the launcher is piped into the collector" \
    '_personal_deploy_collect "$_deploy_state" "$_deploy_tail" "$_deploy_notice"' "$RP"
ADDONS="$(cat "$ROOT/setup/lib/exasol-vscode.sh" "$ROOT/setup/lib/dash-server.sh" \
    "$ROOT/setup/lib/json-tables.sh")"
lacks "no add-on redirects a fetch by hand" "( fetch " "$ADDONS"
lacks "the VS Code install is not a bare redirect" \
    '_exasol_vscode_code --install-extension "$(_exasol_vscode_host_path "$_evi_vsix")" --force' "$ADDONS"

printf '\n== an add-on install reports its own stages ==\n'

# The add-on install writes into the shared progress state now, not into the
# spinner's label. tests/install-output-brevity.sh owns the rest of that flow;
# what is asserted here is that the state carries this add-on and this stage.
ADDON_STATE="$WORK/addon-state"
_exakit_addon_progress "$ADDON_STATE" dash-server 0 65 40 "installing"
check "the stage it is at"       "0"  "$(cut -d'|' -f1 "$ADDON_STATE")"
check "and where that stage ends" "65" "$(cut -d'|' -f2 "$ADDON_STATE")"
has "the add-on is named"        "dash-server" "$(cut -d'|' -f5 "$ADDON_STATE")"
has "so is the phase"            "installing"  "$(cut -d'|' -f5 "$ADDON_STATE")"
_exakit_addon_progress "$ADDON_STATE" dash-server 65 90 8 "validating"
check "validating starts at 65"  "65" "$(cut -d'|' -f1 "$ADDON_STATE")"
has "...and says so"             "validating" "$(cut -d'|' -f5 "$ADDON_STATE")"

# Every phase must fit the cell it is drawn in. The phase gets 30% of the
# progress line, which is 21 columns on an 80-column terminal -- the narrowest
# the line supports -- so a longer phase is ellipsed for anyone not running a
# wide window. This has gone wrong twice: once when a phase was reworded to be
# accurate on both the download and cache-hit paths and grew to 33 characters,
# and once before that. Measuring the strings is cheaper than noticing on screen.
echo
echo "== every phase fits the 21-column cell =="
PHASE_SRC="$ROOT/setup/lib/runtime-personal.sh"
LONGEST=0
for _p in $(grep -ohE "printf '[0-9]+\|[0-9]+\|[0-9]+\|[^']+'" "$PHASE_SRC" \
            | sed "s/.*|//;s/'$//" | tr ' ' '_' | sort -u); do
    _phase="$(printf '%s' "$_p" | tr '_' ' ')"
    _len=${#_phase}
    [ "$_len" -gt "$LONGEST" ] && LONGEST=$_len
    if [ "$_len" -le 21 ]; then
        PASS=$((PASS + 1)); printf '  ok   %-28s fits (%d)\n' "$_phase" "$_len"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL %-28s is %d chars; the cell is 21 at 80 columns\n' "$_phase" "$_len"
    fi
done
check "a phase was actually measured" "yes" "$([ "$LONGEST" -gt 0 ] && echo yes || echo NONE-FOUND)"

printf '\n== no function is defined twice ==\n'

# A duplicated definition is invisible to every check the repo already runs: the
# file parses, the encoding guard passes, and the LAST definition silently wins.
# It happened for real - a patch to a PowerShell runtime module computed its end
# offset from an anchor that occurs twice, re-included the region instead of
# replacing it, and left the PRE-FIX body as the effective one. Windows kept the
# old behaviour while every test went green.
for _dup_file in "$ROOT"/setup/lib/*.ps1 "$ROOT"/setup/*.ps1 "$ROOT"/install.ps1; do
    [ -f "$_dup_file" ] || continue
    _dup_names="$(grep -oE '^function [A-Za-z][A-Za-z0-9-]*' "$_dup_file" 2>/dev/null | sort | uniq -d | tr '\n' ' ')"
    check "$(basename "$_dup_file") defines each function once" "" "$(printf '%s' "$_dup_names" | sed 's/ *$//')"
done

# The shell side has the same hazard. ui.sh used to carry one real instance -
# ui_rule defined twice, the UI_BOX_W-sized first definition dead - and it was
# tolerated here as a named exception. It is gone, so no file gets an exception.
for _dup_sh in "$ROOT"/setup/lib/*.sh; do
    [ -f "$_dup_sh" ] || continue
    _dup_shnames="$(grep -oE '^[a-z_][a-z0-9_]*\(\) \{' "$_dup_sh" 2>/dev/null | sort | uniq -d | tr '\n' ' ')"
    _dup_shnames="$(printf '%s' "$_dup_shnames" | sed 's/ *$//')"
    check "$(basename "$_dup_sh") defines each function once" "" "$_dup_shnames"
done

printf '\n== all three platforms install in the same six steps ==\n'

MAC_SH="$(cat "$ROOT/setup/setup-macos.sh")"
WSL_SH="$(cat "$ROOT/setup/setup-linux.sh")"
WIN_PS="$(cat "$ROOT/setup/setup-windows.ps1")"

# The container platforms used to fold "fetch the image" and "deploy the
# database" into one step, so Step 1/5 covered an 18-second network download AND
# the whole deploy - the longest silent stretch of the install and its most
# failure-prone phase, under one heading. macOS had always split them.
for _six_h in "Exasol launcher" "Local database deployment"; do
    has "macOS has: $_six_h"   "$_six_h" "$MAC_SH"
    has "WSL has: $_six_h"     "$_six_h" "$WSL_SH"
    has "Windows has: $_six_h" "$_six_h" "$WIN_PS"
done

# Six on every platform, and the shared tail told the right total.
# Counted as DECLARATIONS, not as label text: the two shell installers declare
# their first two steps and delegate the remaining four to kit_shared_steps, so
# a raw count of 'Step n/6' strings would differ by platform for a reason that
# has nothing to do with the shape being the same.
check "macOS declares two, then delegates" "2" \
    "$(printf '%s\n' "$MAC_SH" | grep -c '^if begin_step ')"
check "WSL declares two, then delegates" "2" \
    "$(printf '%s\n' "$WSL_SH" | grep -c '^if begin_step ')"
check "Windows declares all six itself" "6" \
    "$(printf '%s\n' "$WIN_PS" | grep -c 'Begin-ExakitStep "')"
# The shared tail must be told the right start and total, or the four steps it
# owns would number themselves against the old five.
check "macOS hands over at 3 of 6" "1" \
    "$(printf '%s\n' "$MAC_SH" | grep -c 'kit_shared_steps 3 6')"
check "WSL hands over at 3 of 6"   "1" \
    "$(printf '%s\n' "$WSL_SH" | grep -c 'kit_shared_steps 3 6')"
# And no installer still advertises a five-step run.
lacks "macOS has no stale total"   "/5  " "$MAC_SH"
lacks "WSL has no stale total"     "/5  " "$WSL_SH"
lacks "Windows has no stale total" "/5  " "$WIN_PS"

# --- Linux is a served platform ----------------------------------------------
echo
echo "autostart is honest, and linux has a quickstart:"
COMMON_SH_7="$(cat "$ROOT/setup/lib/common.sh")"
# LNX-01: nothing on Linux restarts the deployment at boot on its own, so
# autostart is a systemd USER unit that runs the launcher's start - and a
# starter that hands off must not be declared as a service that crashed.
has "autostart is a systemd user unit" 'EXAKIT_SYSTEMD_USER_DIR' "$COMMON_SH_7"
has "...as a oneshot where the command hands off" 'Type=oneshot' "$COMMON_SH_7"
# LNX-12: a user unit dies at logout without lingering; the kit enables it or
# says what an admin has to run.
has "lingering is attempted" 'loginctl enable-linger' "$COMMON_SH_7"
has "...and refusal names the admin command" 'loginctl enable-linger $USER' "$COMMON_SH_7"
# LNX-03: Linux users stop being routed to a WSL document.
check "a Linux quickstart exists" "yes" "$([ -f "$ROOT/quickstarts/linux.md" ] && echo yes || echo no)"
has "and the README points at it" "quickstarts/linux.md" "$(cat "$ROOT/README.md")"

printf '\n== every macOS launcher probe is bounded ==\n'

# MAC-02. exakit_run_bounded exists BECAUSE macOS has no timeout(1), and for a
# long time it guarded only the container-engine probes - which run on the
# platforms that do have one. Every `exasol` probe stayed unbounded, so `exakit
# status`, the command AGENTS.md tells agents to poll, could block forever on
# exactly the wedged launcher this module ships a reaper for.
RP_SH="$(cat "$ROOT/setup/lib/runtime-personal.sh")"
has "the pre-download 'install --help' probe is bounded" \
    'exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$_existing" install --help' "$RP_SH"
has "the launcher capability probe is bounded" \
    'exakit_run_bounded "$EXAKIT_PERSONAL_PROBE_TIMEOUT" "$(personal_cli)" --help' "$RP_SH"
lacks "no launcher probe runs the CLI straight into a pipe" \
    '"$(personal_cli)" --help 2>&1 |' "$RP_SH"
# A probe captured with $( ) stays blocked until every process holding the
# pipe's write end exits, so the cutoff has to reach the whole group.
has "the bounded fallback kills the process group first" \
    'kill -TERM -- "-$_rb_pid"' "$(cat "$ROOT/setup/lib/common.sh")"

# And behaviourally: a launcher that never answers must not hold the probe.
mkdir -p "$WORK/hang"
cat > "$WORK/hang/exasol" <<'HANGEOF'
#!/bin/sh
exec sleep 60
HANGEOF
chmod 755 "$WORK/hang/exasol"
_pb_bin_was="$EXAKIT_PERSONAL_BIN"
EXAKIT_PERSONAL_BIN="$WORK/hang/exasol"
EXAKIT_PERSONAL_PROBE_TIMEOUT=2
_pb_t0="$(date +%s)"
personal_launcher_supports start >/dev/null 2>&1
_pb_spent=$(( $(date +%s) - _pb_t0 ))
if [ "$_pb_spent" -le 15 ]; then
    check "a hanging launcher does not hang the capability probe" "bounded" "bounded"
else
    check "a hanging launcher does not hang the capability probe" "bounded" "${_pb_spent}s"
fi
EXAKIT_PERSONAL_BIN="$_pb_bin_was"

printf '\n== the manifest records the real version and the real state ==\n'

# MAC-07. The major-upgrade `--apply` path deliberately did not record
# runtime.version, and nothing else recorded it either - so the next `exakit
# update` saw the same major gap, matched the same backup record, and swapped
# the launcher again. Forever: no command anywhere finished the upgrade.
PU_APPLY="$(sed -n '/^personal_update()/,/^}/p' "$ROOT/setup/lib/runtime-personal.sh")"
has "'update --apply' records the version it just installed" \
    'manifest_set runtime.version "$_latest"' "$PU_APPLY"
has "...and the outstanding data migration gets its own key" \
    'manifest_set runtime.migration_pending' "$PU_APPLY"

# MAC-06. personal_record_manifest ended every call with runtime.status
# "healthy" - including from `exakit update`, which reaches it after a launcher
# swap with no health probe of any kind in between. Updating a STOPPED database
# recorded it as healthy. Stubs from here to the end of the file.
_rec_log="$WORK/manifest-writes"
: > "$_rec_log"
manifest_set() { printf '%s=%s\n' "$1" "$2" >> "$_rec_log"; }
personal_status() { printf 'stopped\n'; }
EXAKIT_PERSONAL_DEPLOY_DIR="$WORK/no-such-deployment"
personal_record_manifest >/dev/null 2>&1
check "a caller that did not probe gets the probed state, not 'healthy'" "stopped" \
    "$(sed -n 's/^runtime\.status=//p' "$_rec_log" | tail -1)"
: > "$_rec_log"
personal_record_manifest "healthy" >/dev/null 2>&1
check "...and a caller that just watched it answer records healthy" "healthy" \
    "$(sed -n 's/^runtime\.status=//p' "$_rec_log" | tail -1)"

# CPY-10. THE LICENCE, SAID BEFORE THE SOFTWARE ARRIVES.
#
# The launcher's own notice IS replayed verbatim, but only after `install
# local` has succeeded - i.e. once the deployment already exists. Both halves
# now say which licence covers what while the reader can still stop, and the
# ORDER is the point: an assertion that the sentence merely exists would pass
# with it printed at the end.
echo
echo "the licence is named before the software arrives:"
_lic_before() { # _lic_before <file> <function-opener> <marker-after>
    _lb_body="$(awk -v o="$2" 'index($0,o)==1{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/$1")"
    _lb_lic="$(printf '%s\n' "$_lb_body" | grep -n "own licence terms" | head -1 | cut -d: -f1)"
    _lb_mark="$(printf '%s\n' "$_lb_body" | grep -n "$3" | head -1 | cut -d: -f1)"
    if [ -z "$_lb_lic" ]; then printf 'missing\n'; return; fi
    if [ -z "$_lb_mark" ]; then printf 'no-marker\n'; return; fi
    if [ "$_lb_lic" -lt "$_lb_mark" ]; then printf 'before\n'; else printf 'after\n'; fi
}
check "the deploy says it before it deploys" "before" \
    "$(_lic_before setup/lib/runtime-personal.sh 'personal_deploy_local() {' 'Deploying Exasol Personal locally')"
# The PowerShell twin is not run here; its ordering is read the same way.
_ps_dep="$(awk '/^function Install-PersonalDeployment/{f=1} f{print} f&&/^}$/{if(f)exit}' "$ROOT/setup/lib/runtime-personal.ps1")"
_ps_lic="$(printf '%s\n' "$_ps_dep" | grep -n "own licence terms" | head -1 | cut -d: -f1)"
_ps_mark="$(printf '%s\n' "$_ps_dep" | grep -n 'Deploying Exasol Personal locally' | head -1 | cut -d: -f1)"
if [ -n "$_ps_lic" ] && [ -n "$_ps_mark" ] && [ "$_ps_lic" -lt "$_ps_mark" ]; then
    check "the twin says it before its deploy too" "before" "before"
else
    check "the twin says it before its deploy too" "before" "lic=${_ps_lic:-none} deploy=${_ps_mark:-none}"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
