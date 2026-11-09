#!/usr/bin/env bash
# personal-agent-contract.sh — the agent-facing contract around the update loop,
# start and status. Runs the real functions against stubs; nothing is installed,
# no launcher, podman or docker runs, and HOME is a throwaway directory.
#
#   bash tests/personal-agent-contract.sh
#
# What it pins:
#   - a kit self-update stops `exakit update`: the rest is deferred to the new kit
#   - an update whose restart after the launcher swap meets a WSL kernel
#     without nftables names the remedy that clears it (wsl --update), says the
#     launcher WAS updated and that exakit start follows, with an `error`
#     sentence, on every row shape
#   - a refused install step keeps its reason for `exakit status --json`
#   - `exakit start` on a Docker deployment with Docker down, or on a WSL kernel
#     without nftables, never points at repair-runtime
#   - the "keeps its database password" result on macOS, and "unknown" when
#     secrets.json cannot be read
#   - the PowerShell twins carry the same decisions

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" EXAKIT_HOME="$TMP/home/.exasol-starter-kit" EXAKIT_BIN_DIR="$TMP/home/bin"
mkdir -p "$EXAKIT_HOME"
unset XDG_CONFIG_HOME EXAKIT_UPDATE_JSON EXAKIT_UPDATE_RESULTS EXAKIT_LOG_FILE

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
contains() { # contains <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s contains "%s"\n' "$1" "$2" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: must not contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s lacks "%s"\n' "$1" "$2" ;;
    esac
}
jq_py() { # jq_py <json> <python expression over d>
    printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))' "$2" 2>&1
}

# shellcheck disable=SC1091
. "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
# shellcheck disable=SC1091
. "$ROOT/setup/lib/detect.sh" >/dev/null 2>&1
# shellcheck disable=SC1091
. "$ROOT/setup/lib/runtime-personal.sh" >/dev/null 2>&1
EXAKIT_FAILURE_NOTE="$TMP/last-failure"; export EXAKIT_FAILURE_NOTE
UI_FANCY=0

# ---------------------------------------------------------------------------
# The update loop, with every component stubbed.
# ---------------------------------------------------------------------------
STATE="$TMP/state"; mkdir -p "$STATE"
exakit_versions_update_cache() { :; }
exakit_versions_resolve_doc() { :; }
exakit_print_versions_source_line() { :; }
exakit_update_actual_target() { printf '%s\n' "$1"; }
exakit_component_current() { cat "$STATE/cur.$1" 2>/dev/null || true; }
exakit_component_available() { cat "$STATE/avail.$1" 2>/dev/null || true; }
exakit_component_supported() { return 0; }
exakit_component_is_ahead() { return 1; }
exakit_component_is_heavy() { return 1; }
exakit_component_min_kit() { :; }
_exakit_addon_registered() { return 1; }
# Every component here is the kit's own (ownership receipts).
exakit_component_is_managed() { return 0; }
exakit_update_component() {
    printf '%s\n' "$1" >> "$STATE/calls"
    case "$1" in
        exakit)  cat "$STATE/avail.exakit" > "$STATE/cur.exakit" ;;
        # The launcher is swapped, then the restart of a database that was
        # running meets the WSL kernel: the REAL start die, as
        # exakit_apply_runtime_update -> exakit_runtime_start raises it.
        runtime) [ -f "$STATE/refuse" ] && { : > "$STATE/swapped"; _personal_start_network_die; } ;;
        exapump) [ -f "$STATE/break" ] && die "exapump download failed: HTTP 503" ;;
    esac
    return 0
}
reset_state() {
    rm -f "$STATE"/* "$EXAKIT_FAILURE_NOTE"
    printf '0.2.4\n' > "$STATE/cur.exakit";  printf '0.2.4\n' > "$STATE/avail.exakit"
    printf '2.3.0\n' > "$STATE/cur.runtime"; printf '2.4.0\n' > "$STATE/avail.runtime"
    printf '1.0\n'   > "$STATE/cur.exapump"; printf '1.1\n'   > "$STATE/avail.exapump"
}
run_json() { # run_json <targets> - one --json object, as exakit_update prints it
    EXAKIT_UPDATE_RESULTS="$TMP/results"; : > "$EXAKIT_UPDATE_RESULTS"
    ( EXAKIT_UPDATE_JSON=1; export EXAKIT_UPDATE_RESULTS EXAKIT_UPDATE_JSON
      _exakit_update_run all "$1" ) >/dev/null 2>&1
    _rj_rc=$?
    _exakit_update_json_report "$EXAKIT_UPDATE_RESULTS" "$_rj_rc" 2>/dev/null
    unset EXAKIT_UPDATE_RESULTS
}

echo "a kit self-update stops the run; the new kit does the rest:"
reset_state
printf '0.2.3\n' > "$STATE/cur.exakit"
_out="$(_exakit_update_run all "exakit runtime exapump" 2>&1)"
check "only the kit was updated in this process" "exakit" "$(tr '\n' ' ' < "$STATE/calls" | sed 's/ $//')"
contains "and it says to run the update again" "The starter kit itself was updated; run 'exakit update' again" "$_out"
reset_state
printf '0.2.3\n' > "$STATE/cur.exakit"
_j="$(run_json "exakit runtime exapump")"
check "--json: still one object" "yes" "$(printf '%s' "$_j" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
check "--json: status deferred" "deferred" "$(jq_py "$_j" 'd["status"]')"
check "--json: the kit row is updated" "exakit" "$(jq_py "$_j" '",".join(r["component"] for r in d["updated"])')"
check "--json: the rest are deferred rows" "runtime,exapump" "$(jq_py "$_j" '",".join(r["component"] for r in d["deferred"])')"
check "--json: each with remedy exakit update" "exakit update" "$(jq_py "$_j" '",".join(sorted(set(r["remedy"] for r in d["deferred"])))')"
check "--json: remedy exakit update" "exakit update" "$(jq_py "$_j" 'd["remedy"]')"
contains "--json: the hint says why" "starter kit itself was updated" "$(jq_py "$_j" 'd["remedy_hint"]')"
reset_state
printf '0.2.3\n' > "$STATE/cur.exakit"
_out="$(_exakit_update_run all "exakit" 2>&1)"
lacks "a kit-only run has nothing to defer" "run 'exakit update' again" "$_out"
reset_state
_out="$(_exakit_update_run all "exakit runtime exapump" 2>&1)"
check "a current kit leaves the run alone" "runtime exapump" "$(tr '\n' ' ' < "$STATE/calls" | sed 's/ $//')"

echo "an update whose restart meets the WSL kernel names the remedy that clears it (AGK4-01):"
_NETDIE="$( (_personal_start_network_die) 2>&1 | grep -o 'This WSL kernel.*the same kernel\.' | head -1)"
contains "the stub raises the real start die" "cannot create the deployment network: run wsl --update" "$_NETDIE"
UFR_HINT="The launcher was updated, but the database could not start: this WSL kernel cannot create the deployment network. Run wsl --update, then wsl --shutdown, reopen this distro, then exakit start."
_exakit_update_failure_remedy personal "$_NETDIE"
check "_exakit_update_failure_remedy: remedy wsl --update" "wsl --update" "$_ufr_remedy"
check "  the hint says the launcher was updated, then exakit start" "$UFR_HINT" "$_ufr_hint"
reset_state
: > "$STATE/refuse"
_j="$(run_json "runtime exapump")"
check "the launcher was swapped before the start died" "yes" "$([ -f "$STATE/swapped" ] && echo yes || echo no)"
check "status failed" "failed" "$(jq_py "$_j" 'd["status"]')"
check "the row's remedy is wsl --update" "wsl --update" "$(jq_py "$_j" 'd["failed"][0]["remedy"]')"
check "  and so is the top-level remedy" "wsl --update" "$(jq_py "$_j" 'd["remedy"]')"
contains "the row carries the reason" "cannot create the deployment network" "$(jq_py "$_j" 'd["failed"][0]["error"]')"
check "the hint is the start's, not the old update refusal" "$UFR_HINT" "$(jq_py "$_j" 'd["remedy_hint"]')"
lacks "  never 'nothing was updated'" "nothing was updated" "$(jq_py "$_j" 'd["remedy_hint"]')"
lacks "  never a re-run of exakit update personal" "exakit update personal" "$(jq_py "$_j" 'd["remedy_hint"]')"
check "the other components still ran" "exapump" "$(jq_py "$_j" '",".join(r["component"] for r in d["updated"])')"
reset_state
: > "$STATE/break"
_j="$(run_json "exapump")"
check "any other failure: re-run that component" "exakit update exapump" "$(jq_py "$_j" 'd["failed"][0]["remedy"]')"
check "  with its reason as error" "exapump download failed: HTTP 503" "$(jq_py "$_j" 'd["failed"][0]["error"]')"
: > "$TMP/empty-results"
_j="$(_exakit_update_json_report "$TMP/empty-results" 1 "$_NETDIE" "wsl --update" "$UFR_HINT" 2>/dev/null)"
check "a run that died outside a row keeps the remedy" "wsl --update" "$(jq_py "$_j" 'd["failed"][0]["remedy"]')"
check "  and its reason" "yes" "$(jq_py "$_j" '"yes" if "cannot create the deployment network" in d["failed"][0]["error"] else "no"')"
_exakit_update_failure_remedy "" "something else broke"
check "the default remedy is still exakit update" "exakit update" "$_ufr_remedy"

echo "a refused install step keeps its reason for status --json:"
SH="$TMP/status-home"; mkdir -p "$SH"
printf '{"kit_level": 1, "steps_completed": ["launcher"], "runtime": {}}\n' > "$SH/manifest.json"
(
    EXAKIT_HOME="$SH"; EXAKIT_MANIFEST="$SH/manifest.json"; export EXAKIT_HOME EXAKIT_MANIFEST
    exakit_record_soft_failure runtime "curl -fsSL https://example.invalid/install.sh | sh" \
        "WSL 2.6.1.0 is older than 2.7, so Podman cannot create the deployment network (run: wsl --update)" "the local database"
)
check "the reason is on disk" "yes" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("yes" if "wsl --update" in d["install"]["soft_failures"]["runtime"]["reason"] else "no")' "$SH/manifest.json" 2>&1)"
_sj="$(EXAKIT_HOME="$SH" EXAKIT_FAILURE_NOTE="$SH/.last-failure" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
check "status --json is one object" "yes" "$(printf '%s' "$_sj" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
contains "last_failure names the reason" "older than 2.7" "$(jq_py "$_sj" 'd["last_failure"]')"
check "remedies.runtime is wsl --update" "wsl --update" "$(jq_py "$_sj" 'd["remedies"].get("runtime")')"
check "the top-level remedy is not the installer loop" "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
contains "the hint names wsl --shutdown" "wsl --shutdown" "$(jq_py "$_sj" 'd["remedy_hint"]')"
check "runtime.engine is null with no runtime" "None" "$(jq_py "$_sj" 'd["runtime"]["engine"]')"
printf '{"kit_level": 1, "steps_completed": ["launcher", "runtime"], "install": {"soft_failures": {"runtime": {"reason": "old (run: wsl --update)", "repair": "x"}}}, "runtime": {}}\n' > "$SH/manifest.json"
_sj="$(EXAKIT_HOME="$SH" EXAKIT_FAILURE_NOTE="$SH/.last-failure" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
check "a step a later run finished never speaks" "None" "$(jq_py "$_sj" 'd["last_failure"]')"

echo "exakit start on a Docker deployment with Docker down:"
personal_engine_platform() { return 0; }
personal_engine_recorded() { printf 'docker'; }
personal_docker_usable() { _pdu_said="Docker is installed but not running ('docker info' did not answer)"; return 1; }
personal_launcher_supports() { printf 'LAUNCHER CALLED\n' >> "$TMP/start-calls"; return 0; }
_out="$( (personal_start) 2>&1)"
contains "says Docker is the problem" "runs on Docker, and Docker is installed but not running" "$_out"
contains "names starting Docker" "Start Docker" "$_out"
lacks "never repair-runtime" "repair-runtime" "$_out"
check "the launcher was never asked" "no" "$([ -f "$TMP/start-calls" ] && echo yes || echo no)"
check "exakit_runtime_engine reports it" "docker" "$(exakit_installation_runtime_type() { printf personal; }; exakit_runtime_engine)"
check "  and nothing off an engine platform" "" "$(exakit_installation_runtime_type() { printf personal; }; personal_engine_platform() { return 1; }; exakit_runtime_engine)"

echo "exakit start on a WSL kernel without nftables:"
personal_docker_usable() { return 0; }
personal_engine_recorded() { printf 'podman'; }
personal_launcher_state() { printf 'running'; }
personal_note_guest_rebuild() { :; }
port_in_use() { return 1; }
personal_cli() { printf 'exasol'; }
personal_auto_approve_flag() { :; }
personal_deployment_wedged() { return 1; }
personal_status() { printf 'stopped'; }
personal_repair_command() { printf 'exakit repair-runtime'; }
detect_podman_iptables_driver() { return 1; }
EXAKIT_LOG_FILE="$TMP/start.log"; printf 'earlier line mentioning nothing\n' > "$EXAKIT_LOG_FILE"
run_logged() { printf 'Error: netavark: nftables error: "nft" did not return successfully while applying ruleset\n' >> "$EXAKIT_LOG_FILE"; return 1; }
detect_os() { printf 'wsl'; }
detect_wsl_release() { printf '2.6.1.0\n'; }
_out="$( (personal_start) 2>&1)"
contains "the nft error in this start's output is named" "cannot create the deployment network" "$_out"
contains "  with wsl --update" "wsl --update" "$_out"
contains "  then wsl --shutdown" "wsl --shutdown" "$_out"
lacks "  never 'repair with'" "repair with:" "$_out"
printf 'Error: nftables error from an OLD run\n' > "$EXAKIT_LOG_FILE"
run_logged() { printf 'some other failure\n' >> "$EXAKIT_LOG_FILE"; return 1; }
_out="$( (personal_start) 2>&1)"
contains "an old run's nft line is not this start's" "repair with: exakit repair-runtime" "$_out"
_out="$( (personal_start) 2>&1)"
contains "WSL 2.6 + Podman, no nft line: the normal failure" "Failed to start the database" "$_out"
lacks "  never blamed on the WSL kernel" "cannot create the deployment network" "$_out"
detect_wsl_release() { return 1; }
_out="$( (personal_start) 2>&1)"
contains "an unreadable WSL release claims nothing" "Failed to start the database" "$_out"
detect_wsl_release() { printf '2.7.0.0\n'; }
_out="$( (personal_start) 2>&1)"
contains "WSL 2.7 fails for its own reason" "Failed to start the database" "$_out"
unset EXAKIT_LOG_FILE

echo "personal_update says the password result on macOS too:"
UPD="$TMP/upd"; mkdir -p "$UPD/deploy"
MF="$UPD/manifest"; : > "$MF"
manifest_get() { grep "^$1=" "$MF" 2>/dev/null | tail -1 | cut -d= -f2-; }
manifest_set() { { grep -v "^$1=" "$MF" 2>/dev/null || true; } > "$MF.n"; mv "$MF.n" "$MF"; printf '%s=%s\n' "$1" "$2" >> "$MF"; }
manifest_set runtime.version 2.3.0
exakit_component_available() { printf '2.4.0'; }
EXAKIT_PERSONAL_DEPLOY_DIR="$UPD/deploy"
EXAKIT_PERSONAL_BIN="$UPD/exasol"
personal_install_launcher() { :; }
personal_record_manifest() { :; }
personal_deployment_exists() { return 0; }
read_credential() { printf 'same-password-16c'; }
exapump_create_profile() { :; }
printf '{"dbPassword": "same-password-16c"}\n' > "$UPD/deploy/secrets.json"
personal_engine_platform() { return 1; }
# The launcher is the kit's own here (ownership receipt).
exakit_component_is_managed() { return 0; }
_out="$(personal_update 2>&1)"
contains "macOS: the password result is said" "keeps its database password: the launcher did not change it" "$_out"
lacks "  without an engine word" "keeps its engine" "$_out"
rm -f "$UPD/deploy/secrets.json"
_out="$(personal_update 2>&1; printf 'state=%s' "$EXAKIT_PERSONAL_PASSWORD_CHANGE")"
contains "an unreadable secrets.json is unknown" "state=unknown" "$_out"
lacks "  and nothing is claimed about the password" "database password" "$_out"
personal_engine_platform() { return 0; }
detect_os() { printf 'linux'; }
_out="$(personal_update 2>&1)"
contains "linux, unreadable: the engine line alone" "keeps its engine (podman)." "$_out"
lacks "  never 'changed neither'" "changed neither" "$_out"
printf '{"dbPassword": "same-password-16c"}\n' > "$UPD/deploy/secrets.json"
_out="$(personal_update 2>&1)"
contains "linux, same: both said" "keeps its engine (podman) and its database password" "$_out"

echo "the PowerShell twins carry the same decisions:"
PS1F="$ROOT/setup/exakit.ps1"
PSC="$ROOT/setup/lib/exakit-common.ps1"
RPS="$ROOT/setup/lib/runtime-personal.ps1"
check "Get-ExakitUpdateFailureRemedy defined" 1 "$(grep -c '^function Get-ExakitUpdateFailureRemedy' "$PS1F")"
check "  it maps the WSL reason to wsl --update" 1 "$(grep -c '\$remedy = "wsl --update"' "$PS1F")"
check "the failed row carries an error" 1 "$(grep -cF -- '-ErrorText $componentError' "$PS1F")"
check "the offer's Fail is a row under --json" 1 "$(grep -cF -- '-ErrorText $offerError' "$PS1F")"
check "the loop defers after a kit swap" 1 "$(grep -cF 'if ($script:ExakitKitSwapped) {' "$PS1F")"
# Each function body is assigned first: bash 3.2 mangles a braced sed range
# passed straight into an argument (tests/bash32-guard.sh).
_ps_self="$(sed -n '/^function Update-ExakitSelf {/,/^}/p' "$PSC")"
_ps_start="$(sed -n '/^function Start-Personal {/,/^}/p' "$RPS")"
_ps_netfail="$(sed -n '/^function Stop-PersonalStartNetworkBlocked {/,/^}/p' "$RPS")"
_ps_nettext="$(sed -n '/^function Get-PersonalStartNetworkText {/,/^}/p' "$RPS")"
check "Update-ExakitSelf flags both swap arms" 2 "$(printf '%s\n' "$_ps_self" | grep -cF '$script:ExakitKitSwapped = $true')"
check "status JSON carries runtime.engine" 1 "$(grep -cF 'engine         = $(if ($runtimeEngine)' "$PS1F")"
check "version JSON carries runtime.engine" 1 "$(grep -cF 'engine = $(if (Get-ExakitRuntimeEngine)' "$PS1F")"
check "Start-Personal checks Docker first" 1 "$(printf '%s\n' "$_ps_start" | grep -cF 'if ((Get-PersonalEngineRecorded) -eq "docker" -and -not (Test-PersonalDockerUsable))')"
check "  and the network before the repair arms" 2 "$(printf '%s\n' "$_ps_start" | grep -cF 'Stop-PersonalStartNetworkBlocked }')"
check "the network Fail takes the one wording" 1 "$(printf '%s\n' "$_ps_netfail" | grep -cF '$msg = Get-PersonalStartNetworkText')"
check "the network text never names repair as a fix" 1 "$(printf '%s\n' "$_ps_nettext" | grep -cF 'do not repair-runtime')"

# ---------------------------------------------------------------------------
# Package C (round 2): the failure note read by update --json, Docker down
# beside a missing step, soft records that outlive their step, and the
# PowerShell refusal hint.
# ---------------------------------------------------------------------------
# The sections above stubbed the manifest and the machine; start clean.
# shellcheck disable=SC1091
. "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
EXAKIT_FAILURE_NOTE="$TMP/last-failure"; export EXAKIT_FAILURE_NOTE
UI_FANCY=0
exakit_versions_update_cache() { :; }
exakit_versions_resolve_doc() { :; }
exakit_print_versions_source_line() { :; }
exakit_update_actual_target() { printf '%s\n' "$1"; }
exakit_component_current() { cat "$STATE/cur.$1" 2>/dev/null || true; }
exakit_component_available() { cat "$STATE/avail.$1" 2>/dev/null || true; }
exakit_component_supported() { return 0; }
exakit_component_is_ahead() { return 1; }
exakit_component_is_heavy() { return 1; }
exakit_component_min_kit() { :; }
_exakit_addon_registered() { return 1; }
exakit_component_is_managed() { return 0; }
exakit_update_component() {
    case "$1" in
        runtime) [ -f "$STATE/refuse" ] && _personal_start_network_die ;;
        exapump) [ -f "$STATE/quiet" ] && exit 1 ;;
    esac
    return 0
}

echo "update --json retried within the same second keeps the WSL reason:"
# A frozen clock: every note is byte-identical, which is what a retry in the
# same second produced, and what the old "text changed" test read as no reason.
_exakit_ts() { printf '2026-11-09 00:00:00'; }
reset_state
: > "$STATE/refuse"
_j1="$(run_json "runtime")"
_j2="$(run_json "runtime")"
_j3="$(run_json "runtime exapump")"
check "first run: remedy wsl --update" "wsl --update" "$(jq_py "$_j1" 'd["remedy"]')"
check "same-second retry: remedy wsl --update" "wsl --update" "$(jq_py "$_j2" 'd["remedy"]')"
contains "  and the row still carries the reason" "cannot create the deployment network" "$(jq_py "$_j2" 'd["failed"][0]["error"]')"
check "  and the hint" "$UFR_HINT" "$(jq_py "$_j2" 'd["remedy_hint"]')"
check "a third, wider retry: the runtime row too" "wsl --update" "$(jq_py "$_j3" '[r for r in d["failed"] if r["component"] == "runtime"][0]["remedy"]')"
reset_state
printf 'an older install failure\n2026-01-01 00:00:00\n' > "$EXAKIT_FAILURE_NOTE"
: > "$STATE/quiet"
_j="$(run_json "exapump")"
check "a failure with no note of its own is not given the old one" "the update did not finish (see exakit logs)" "$(jq_py "$_j" 'd["failed"][0]["error"]')"
check "  and the older note is put back for status" "an older install failure" "$(head -n 1 "$EXAKIT_FAILURE_NOTE" 2>/dev/null)"
rm -f "$STATE/quiet"
_j="$(run_json "exapump")"
check "a clean run leaves the older note in place" "an older install failure" "$(head -n 1 "$EXAKIT_FAILURE_NOTE" 2>/dev/null)"
unset -f _exakit_ts
# shellcheck disable=SC1091
. "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
EXAKIT_FAILURE_NOTE="$TMP/last-failure"; export EXAKIT_FAILURE_NOTE

echo "a soft record goes when its step finishes, and never comes back:"
SF="$TMP/soft-home"; mkdir -p "$SF"
sf_read() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(sorted(((d.get("install") or {}).get("soft_failures") or {}).keys())))' "$SF/manifest.json" 2>&1; }
sf_read_at() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(",".join(sorted(((d.get("install") or {}).get("soft_failures") or {}).keys())))' "$1" 2>&1; }
(
    EXAKIT_HOME="$SF"; EXAKIT_MANIFEST="$SF/manifest.json"; export EXAKIT_HOME EXAKIT_MANIFEST
    printf '{"kit_level": 1, "steps_completed": ["launcher"], "runtime": {}}\n' > "$EXAKIT_MANIFEST"
    exakit_record_soft_failure runtime "x" "WSL 2.6.1.0 is older than 2.7 (run: wsl --update)" "the local database"
    exakit_record_soft_failure sample_data "exakit data-load" "load failed" "sample data"
    printf 'recorded=%s\n' "$(sf_read)"
    mark_step runtime
    printf 'marked=%s\n' "$(sf_read)"
    EXAKIT_SOFT_FAILED=""; exakit_record_soft_failure runtime "exakit start" "the start was refused" "the local database"
    exakit_unmark_step runtime
    printf 'unmarked=%s\n' "$(sf_read)"
    EXAKIT_SOFT_FAILED=""; exakit_record_soft_failure exapump "exakit update" "download failed" "exapump"
    exakit_soft_step exapump "exakit update" "exapump" true >/dev/null 2>&1
    printf 'softstep=%s failed=[%s]\n' "$(sf_read)" "${EXAKIT_SOFT_FAILED:-}"
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["install"]["soft_failures"]["launcher"]={"reason":"old","repair":"x"}; json.dump(d,open(p,"w"))' "$EXAKIT_MANIFEST"
    exakit_prune_soft_failures
    printf 'pruned=%s\n' "$(sf_read)"
) > "$TMP/soft.out" 2>&1
contains "both records are on disk" "recorded=runtime,sample_data" "$(cat "$TMP/soft.out")"
contains "mark_step clears the step's record only" "marked=sample_data" "$(cat "$TMP/soft.out")"
contains "exakit_unmark_step clears a record written after the mark" "unmarked=sample_data" "$(cat "$TMP/soft.out")"
contains "a soft step that finishes clears its record and its summary row" "softstep=sample_data failed=[]" "$(cat "$TMP/soft.out")"
contains "the closing prune drops a completed step's record, keeps the rest" "pruned=sample_data" "$(cat "$TMP/soft.out")"

echo "status --json: Docker down beside a missing step, refusals, dates:"
# The real cmd_status (and the helpers above it in setup/exakit), in its own
# process, with the machine stubbed. Line numbers are read first: bash 3.2
# mangles a braced sed range passed straight into an argument.
_cs_from="$(grep -n '^_runtime_type() {' "$ROOT/setup/exakit" | head -n 1 | cut -d: -f1)"
_cs_to="$(grep -n '^case "${1:-}" in' "$ROOT/setup/exakit" | head -n 1 | cut -d: -f1)"
sed -n "${_cs_from},$((_cs_to - 1))p" "$ROOT/setup/exakit" > "$TMP/cs-body.sh"
cat > "$TMP/cs-run.sh" <<'EXAKIT_CS_RUN'
. "$1/setup/lib/common.sh" >/dev/null 2>&1
. "$1/setup/lib/detect.sh" >/dev/null 2>&1
. "$1/setup/lib/runtime-personal.sh" >/dev/null 2>&1
. "$2" >/dev/null 2>&1
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"; export EXAKIT_MANIFEST
EXAKIT_FAILURE_NOTE="$EXAKIT_HOME/.last-failure"; export EXAKIT_FAILURE_NOTE
detect_os() { printf 'wsl'; }
detect_wsl_version() { printf 2; }
personal_engine_platform() { return 0; }
personal_status() { printf '%s' "${DB_STUB:-stopped}"; }
personal_docker_usable() { [ "${DOCKER_UP:-0}" = 1 ] && return 0; _pdu_said="Docker is installed but not running ('docker info' did not answer)"; return 1; }
exakit_install_command() { printf 'curl -fsSL https://x/install.sh | sh'; }
if [ -n "${RECORD_REASON:-}" ]; then
    exakit_record_soft_failure runtime "curl -fsSL https://x/install.sh | sh" "$RECORD_REASON" "the local database" >/dev/null 2>&1
fi
cmd_status --json 2>/dev/null
EXAKIT_CS_RUN
CSH="$TMP/cs-home"; mkdir -p "$CSH"
cs_json() { # cs_json <manifest json> [VAR=value ...] - one cmd_status --json answer
    printf '%s\n' "$1" > "$CSH/manifest.json"; rm -f "$CSH/.last-failure"; shift
    env EXAKIT_HOME="$CSH" "$@" bash "$TMP/cs-run.sh" "$ROOT" "$TMP/cs-body.sh"
}
_no_mcp='["launcher","runtime","exapump","pyexasol","exakit_helper"]'
_sj="$(cs_json '{"kit_level":1,"steps_completed":'"$_no_mcp"',"runtime":{"type":"personal","engine":"docker"}}')"
check "Docker down + mcp missing: remedy null" "None" "$(jq_py "$_sj" 'd["remedy"]')"
contains "  remedy_hint says to start Docker" "start Docker" "$(jq_py "$_sj" 'd["remedy_hint"]')"
check "  the step's remedy is still listed" "exakit mcp-setup" "$(jq_py "$_sj" 'd["remedies"].get("mcp")')"
check "  engine_running false" "False" "$(jq_py "$_sj" 'd["runtime"]["engine_running"]')"
_sj="$(cs_json '{"kit_level":1,"steps_completed":'"$_no_mcp"',"runtime":{"type":"personal","engine":"docker"}}' DOCKER_UP=1)"
check "Docker up, stopped, mcp missing: start first" "exakit start" "$(jq_py "$_sj" 'd["remedy"]')"
check "  and the hint is the database's (none), not Docker's" "None" "$(jq_py "$_sj" 'd["remedy_hint"]')"
_sj="$(cs_json '{"kit_level":1,"steps_completed":'"$_no_mcp"',"runtime":{"type":"personal","engine":"docker"}}' DB_STUB=running)"
check "running, mcp missing: the step's remedy" "exakit mcp-setup" "$(jq_py "$_sj" 'd["remedy"]')"
check "  remedy_hint is present and null" "True None" "$(jq_py "$_sj" '"%s %s" % ("remedy_hint" in d, d["remedy_hint"])')"
_sj="$(cs_json '{"kit_level":1,"steps_completed":["launcher"],"runtime":{}}' DB_STUB="not installed" RECORD_REASON="EXAKIT_CONTAINER_ENGINE=docker, but Docker is installed but not running")"
contains "a non-WSL refusal names the reason in remedy_hints.runtime" "this step was refused: EXAKIT_CONTAINER_ENGINE=docker" "$(jq_py "$_sj" 'd["remedy_hints"].get("runtime")')"
check "  and remedy_hint is that sentence" "yes" "$(jq_py "$_sj" '"yes" if d["remedy_hint"] == d["remedy_hints"].get("runtime") else "no"')"
check "  last_failure_at is the record's date" "yes" "$(jq_py "$_sj" '"yes" if (d["last_failure_at"] or "")[:2] == "20" else "no"')"
_sj="$(cs_json '{"kit_level":1,"steps_completed":["launcher","exapump","mcp","pyexasol","exakit_helper"],"runtime":{"type":"personal","engine":"podman"}}' DB_STUB="not installed")"
check "an unmarked step with no record: the installer, not wsl --update" "curl -fsSL https://x/install.sh | sh" "$(jq_py "$_sj" 'd["remedy"]')"
check "  and no last_failure" "None" "$(jq_py "$_sj" 'd["last_failure"]')"

echo "the PowerShell status twin, run for real:"
if command -v pwsh >/dev/null 2>&1; then
    cat > "$TMP/ps-status.ps1" <<'EXAKIT_PS_STATUS'
param([string]$Repo, [string]$Work, [string]$Scenario)
$ErrorActionPreference = "Continue"
$env:HOME = "$Work/home"; $env:USERPROFILE = "$Work/home"; $env:EXAKIT_HOME = "$Work/kit"; $env:EXAKIT_BIN_DIR = "$Work/bin"; $env:EXAKIT_PERSONAL_DEPLOY_DIR = "$Work/deploy"
New-Item -ItemType Directory -Force -Path $env:HOME, $env:EXAKIT_HOME | Out-Null
switch ($Scenario) {
    "dockerdown" { $m = '{"kit_level":1,"steps_completed":["launcher","runtime","exapump","pyexasol","exakit_helper"],"runtime":{"type":"personal","engine":"docker"}}' }
    { $_ -eq "startnote" -or $_ -eq "interrupted" } { $m = '{"kit_level":1,"steps_completed":["launcher","runtime","exapump","mcp","pyexasol","exakit_helper"],"runtime":{"type":"personal","engine":"podman"}}' }
    default     { $m = '{"kit_level":1,"steps_completed":["launcher"],"runtime":{}}' }
}
Set-Content -Path "$env:EXAKIT_HOME/manifest.json" -Value $m -Encoding Ascii
if ($Scenario -eq "startnote" -or $Scenario -eq "interrupted") { $env:EXAKIT_FAILURE_NOTE = "$env:EXAKIT_HOME/.last-failure" }
. "$Repo/setup/lib/exakit-common.ps1"
. "$Repo/setup/lib/runtime-personal.ps1"
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$Repo/setup/exakit.ps1", [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Parent.Parent -eq $ast }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$script:ManifestPath = "$env:EXAKIT_HOME/manifest.json"
function Get-PersonalStatus {
    if ($Scenario -eq "dockerdown" -or $Scenario -eq "startnote") { "stopped" }
    elseif ($Scenario -eq "interrupted") { "interrupted" }
    else { "not installed" }
}
if ($Scenario -eq "startnote" -or $Scenario -eq "interrupted") {
    # `exakit start` refused for the WSL kernel, as Invoke-CmdStart runs it:
    # no installer, so Fail itself does not note (WIN3-03).
    $script:ExakitRecordFailureNotes = $false
    try { Stop-PersonalStartNetworkBlocked *> $null } catch { }
    if (-not (Test-Path $script:FailureNotePath)) { Write-Output "NO-NOTE"; return }
}
function Test-PersonalDockerUsable { $script:PersonalDockerSaid = "Docker Desktop is installed but not running"; return $false }
function Get-ExakitInstallCommand { "irm https://x/install.ps1 | iex" }
if ($Scenario -eq "refused") {
    Register-ExakitSoftFailure -Component "runtime" -Repair "irm https://x/install.ps1 | iex" -Reason "EXAKIT_CONTAINER_ENGINE=docker, but Docker Desktop is installed but not running" -Label "the local database"
}
if ($Scenario -eq "steps") {
    Register-ExakitSoftFailure -Component "runtime" -Repair "x" -Reason "old (run: wsl --update)" -Label "the local database"
    Set-ExakitStepDone "runtime"
    $a = @((Get-ExakitManifestValue "install.soft_failures").PSObject.Properties | ForEach-Object { $_.Name }) -join ","
    Set-ExakitManifestValue "install.soft_failures.runtime.reason" "later"
    Remove-ExakitStepDone "runtime"
    $b = @((Get-ExakitManifestValue "install.soft_failures").PSObject.Properties | ForEach-Object { $_.Name }) -join ","
    Set-ExakitManifestValue "install.soft_failures.launcher.reason" "old"
    Set-ExakitManifestValue "install.soft_failures.sample_data.reason" "kept"
    Clear-ExakitFinishedSoftFailures
    $c = @((Get-ExakitManifestValue "install.soft_failures").PSObject.Properties | ForEach-Object { $_.Name }) -join ","
    Write-Output "marked=[$a] unmarked=[$b] pruned=[$c]"
    return
}
Invoke-CmdStatus -Json
EXAKIT_PS_STATUS
    ps_run() { pwsh -NoProfile -NonInteractive -File "$TMP/ps-status.ps1" -Repo "$ROOT" -Work "$TMP/ps-$1" -Scenario "$1" 2>/dev/null; }
    _pj="$(ps_run refused)"
    contains "PS: a non-WSL refusal names the reason in remedy_hints.runtime" "this step was refused: EXAKIT_CONTAINER_ENGINE=docker" "$(jq_py "$_pj" 'd["remedy_hints"].get("runtime")')"
    check "PS:   and remedy_hint is that sentence" "yes" "$(jq_py "$_pj" '"yes" if d["remedy_hint"] == d["remedy_hints"].get("runtime") else "no"')"
    _pj="$(ps_run dockerdown)"
    check "PS: Docker down + mcp missing: remedy null" "None" "$(jq_py "$_pj" 'd["remedy"]')"
    contains "PS:   remedy_hint says to start Docker" "start Docker" "$(jq_py "$_pj" 'd["remedy_hint"]')"
    check "PS:   the step's remedy is still listed" "exakit mcp-setup" "$(jq_py "$_pj" 'd["remedies"].get("mcp")')"
    _pj="$(ps_run steps)"
    check "PS: Set-ExakitStepDone / Remove-ExakitStepDone / the prune clear records" "marked=[] unmarked=[] pruned=[sample_data]" "$_pj"
    _pj="$(ps_run startnote)"
    lacks "PS: exakit start's WSL refusal writes the note (WIN3-03)" "NO-NOTE" "$_pj"
    check "PS:   status then answers wsl --update" "wsl --update" "$(jq_py "$_pj" 'd["remedy"]')"
    contains "PS:   last_failure is the refusal" "cannot create the deployment network" "$(jq_py "$_pj" 'd["last_failure"]')"
    _pj="$(ps_run interrupted)"
    check "PS: interrupted + the WSL note -> wsl --update (WSL3-01)" "wsl --update" "$(jq_py "$_pj" 'd["remedy"]')"
    check "PS:   remedies.database too" "wsl --update" "$(jq_py "$_pj" 'd["remedies"]["database"]')"
else
    check "PS: the refusal arm gives every reason a hint (no pwsh: source check)" 1 "$(grep -cF 'this step was refused: $($softReason.TrimEnd' "$ROOT/setup/exakit.ps1")"
fi

echo "exakit start names the WSL kernel only on its evidence (MACR-01, WSLR-04, WSLR-08, WINR-03):"
# Every stub this section leans on is set here: earlier sections re-stub some.
personal_engine_platform() { return 0; }
personal_engine_recorded() { printf 'podman'; }
personal_docker_usable() { return 0; }
personal_launcher_supports() { return 0; }
personal_launcher_state() { printf 'running'; }
personal_note_guest_rebuild() { :; }
port_in_use() { return 1; }
personal_cli() { printf 'exasol'; }
personal_auto_approve_flag() { :; }
personal_deployment_wedged() { return 1; }
personal_status() { printf 'stopped'; }
personal_repair_command() { printf 'exakit repair-runtime'; }
personal_port_holder_hint() { printf ' (pid 4242 nginx)'; }
detect_podman_iptables_driver() { return 1; }
detect_wsl_release() { printf '2.6.1.0\n'; }
EXAKIT_LOG_FILE="$TMP/start2.log"; : > "$EXAKIT_LOG_FILE"
NFT='Error: netavark: nftables error: "nft" did not return successfully while applying ruleset'
start_with() { # start_with <os> <launcher output line>
    detect_os() { printf '%s' "$_sw_os"; }
    _sw_os="$1"; _sw_line="$2"
    run_logged() { printf '%s\n' "$_sw_line" >> "$EXAKIT_LOG_FILE"; return 1; }
    (personal_start) 2>&1
}
_out="$(start_with macos "$NFT")"
lacks    "macOS + nft line -> no WSL instruction" "wsl --update" "$_out"
contains "  the normal failure"                  "Failed to start the database" "$_out"
_out="$(start_with linux "$NFT")"
lacks    "native Linux + nft line -> no WSL instruction" "wsl --update" "$_out"
_out="$(start_with wsl 'level=warn msg="nftables not available, falling back"')"
lacks    "WSL + a benign nftables line -> not the kernel" "cannot create the deployment network" "$_out"
_out="$(start_with wsl "$NFT")"
contains "WSL + Podman + netavark's error -> the kernel" "cannot create the deployment network" "$_out"
lacks    "  never repair-runtime as the fix"     "repair with:" "$_out"
personal_status() { printf 'conflict'; }
_out="$(start_with wsl 'Error: rootlessport listen tcp 0.0.0.0:8563: bind: address already in use')"
contains "WSL 2.6, port held -> the port is named" "Port 8563 is held by another process (pid 4242 nginx)" "$_out"
lacks    "  not the WSL kernel"                  "cannot create the deployment network" "$_out"
personal_status() { printf 'stopped'; }
personal_deployment_wedged() { return 0; }
_out="$(start_with wsl 'Error: podman machine not running')"
contains "WSL 2.6, interrupted -> the repair is named" "The database is interrupted" "$_out"
personal_deployment_wedged() { return 1; }
personal_engine_recorded() { printf 'docker'; }
_out="$(start_with wsl "$NFT")"
lacks    "a Docker deployment + nft line -> not the kernel" "cannot create the deployment network" "$_out"
personal_engine_recorded() { printf 'podman'; }
unset EXAKIT_LOG_FILE

echo "status --json after a start refused for the WSL kernel (AGKR-03):"
_sj_py="$TMP/status-json.py"
sed -n "/<<'EXAKIT_SJ_PY'\$/,/^EXAKIT_SJ_PY\$/p" "$ROOT/setup/exakit" | sed '1d;$d' > "$_sj_py"
SJH="$TMP/sj-home"; mkdir -p "$SJH"
printf '{"kit_level": 1, "steps_completed": ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"], "runtime": {"type": "personal"}}\n' > "$SJH/manifest.json"
sj_run() { # sj_run <db status> <failure note>
    python3 "$_sj_py" 1 personal "$1" false "" 0.1 "$SJH/manifest.json" \
        '["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"]' "" "$2" "2026-11-09T00:00:00Z" \
        0 "" "" "bash install.sh" "" "" "" "" "" wsl 2 "ok|/x/uv|0.13.7|0.13.4" podman "" 2>&1
}
_die_text="$( (_personal_start_network_die) 2>&1 | grep -o 'This WSL kernel.*the same kernel\.' | head -1)"
contains "the die text is what the note records" "cannot create the deployment network: run wsl --update" "$_die_text"
_sj="$(sj_run stopped "$_die_text")"
check "remedy is wsl --update, not exakit start" "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
check "  remedies.database too"                  "wsl --update" "$(jq_py "$_sj" 'd["remedies"]["database"]')"
contains "  the hint names wsl --shutdown"       "wsl --shutdown" "$(jq_py "$_sj" 'd["remedy_hint"]')"
contains "  then exakit start"                   "re-run: exakit start" "$(jq_py "$_sj" 'd["remedy_hint"]')"
_sj="$(sj_run stopped "Failed to start the database. Check the log above")"
check "any other start failure -> exakit start"  "exakit start" "$(jq_py "$_sj" 'd["remedy"]')"
_sj="$(sj_run running "$_die_text")"
check "a running database -> no remedy"          "None" "$(jq_py "$_sj" 'd["remedy"]')"
check "PS status maps the same note" 1 "$(grep -cF '$startNote.Contains("cannot create the deployment network") -and $startNote.Contains("wsl --update")' "$ROOT/setup/exakit.ps1")"
check "  to wsl --update" 1 "$(grep -cF 'exakit start was refused: this WSL kernel cannot create the deployment network' "$ROOT/setup/exakit.ps1")"

echo "status --json on an INTERRUPTED deployment after a WSL refusal (WSL3-01):"
_sj="$(sj_run interrupted "$_die_text")"
check "the start die -> wsl --update, not repair-runtime" "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
check "  remedies.database too"                  "wsl --update" "$(jq_py "$_sj" 'd["remedies"]["database"]')"
contains "  the hint says a rebuild cannot work" "neither a start nor a rebuild" "$(jq_py "$_sj" 'd["remedy_hint"]')"
_sj="$(sj_run interrupted "WSL 2.6.1.0 is older than 2.7, so Podman cannot create the deployment network (run: wsl --update)")"
check "the replace check's 2.6 note -> wsl --update" "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
_sj="$(sj_run interrupted "The WSL release could not be read, so replacing the Podman deployment was refused ('wsl --version' must show 2.7 or newer)")"
check "an unreadable release -> wsl --version (AGK4-04)" "wsl --version" "$(jq_py "$_sj" 'd["remedy"]')"
contains "  with EXAKIT_WSL_CHECKED=1 in the hint" "If it shows 2.7 or newer, re-run with EXAKIT_WSL_CHECKED=1; otherwise run wsl --update first." "$(jq_py "$_sj" 'd["remedy_hint"]')"
contains "  naming the destructive re-run" "exakit repair-runtime, which DESTROYS" "$(jq_py "$_sj" 'd["remedy_hint"]')"
_sj="$(sj_run interrupted "Failed to start the database. Check the log above")"
check "any other note on interrupted -> repair-runtime" "exakit repair-runtime" "$(jq_py "$_sj" 'd["remedy"]')"

echo "repair-runtime --json refused by the WSL check before the destroy (WSL3-02):"
RRH="$TMP/rr-home"; RRK="$TMP/rr-kit"; mkdir -p "$RRH" "$RRK/setup"
# The rebuild the command re-runs: refused by the replace check, which records
# the runtime step's reason as setup-linux.sh does, and exits non-zero.
cat > "$RRK/setup/setup-linux.sh" <<'EXAKIT_RR_SETUP'
. "$RR_REPO/setup/lib/common.sh" >/dev/null 2>&1
if [ "${RR_FLOW:-}" = real ]; then
    # THE REAL FLOW (AGK4-05): the real replace check notes its refusal, and
    # setup-linux.sh's own runtime-step arm - run as written, not copied -
    # takes that note into the step's soft record, deleting the note.
    . "$RR_REPO/setup/lib/detect.sh" >/dev/null 2>&1
    . "$RR_REPO/setup/lib/runtime-personal.sh" >/dev/null 2>&1
    detect_os() { printf 'wsl'; }
    detect_podman_iptables_driver() { return 1; }
    detect_podman_backend_not_netavark() { return 1; }
    detect_wsl_release() { [ -n "${RR_WSL:-}" ] || return 1; printf '%s\n' "$RR_WSL"; }
    exakit_install_command() { printf 'bash install.sh'; }
    begin_step() { return 0; }
    mark_step() { :; }
    personal_deploy_local() { personal_wsl_podman_network_ok --replace "exakit start"; }
    _rr_arm="$(sed -n '/^if begin_step runtime/,/^else$/p' "$RR_REPO/setup/setup-linux.sh")"
    eval "$(printf '%s\n' "$_rr_arm" | sed '$d'; printf 'fi\n')"
    exit 1
fi
[ -n "${RR_REASON:-}" ] && exakit_record_soft_failure runtime "bash install.sh" "$RR_REASON" "the local database" >/dev/null 2>&1
exit 1
EXAKIT_RR_SETUP
cat > "$TMP/rr-run.sh" <<'EXAKIT_RR_RUN'
. "$1/setup/lib/common.sh" >/dev/null 2>&1
. "$1/setup/lib/detect.sh" >/dev/null 2>&1
. "$1/setup/lib/runtime-personal.sh" >/dev/null 2>&1
. "$2" >/dev/null 2>&1
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"; export EXAKIT_MANIFEST
EXAKIT_FAILURE_NOTE="$EXAKIT_HOME/.last-failure"; export EXAKIT_FAILURE_NOTE
detect_os() { printf 'wsl'; }
exakit_repo_root() { printf '%s' "$RRK"; }
exakit_install_command() { printf 'bash install.sh'; }
exakit_init_logging() { :; }
exakit_reset_dataset_flags() { :; }
cmd_repair_runtime --yes --json 2>/dev/null
EXAKIT_RR_RUN
rr_json() { # rr_json [RR_REASON=...] - one repair-runtime --json answer
    printf '{"kit_level":1,"steps_completed":["launcher","runtime"],"runtime":{"type":"personal","engine":"podman"}}\n' > "$RRH/manifest.json"
    env EXAKIT_HOME="$RRH" RRK="$RRK" RR_REPO="$ROOT" "$@" bash "$TMP/rr-run.sh" "$ROOT" "$TMP/cs-body.sh"
}
_rj="$(rr_json RR_REASON="WSL 2.6.1.0 is older than 2.7, so Podman cannot create the deployment network (run: wsl --update)")"
check "WSL 2.6 refusal: changed false"           "False" "$(jq_py "$_rj" 'd["changed"]')"
check "  status refused"                         "refused" "$(jq_py "$_rj" 'd["status"]')"
check "  remedy wsl --update"                    "wsl --update" "$(jq_py "$_rj" 'd["remedy"]')"
contains "  the reason is the check's"           "older than 2.7" "$(jq_py "$_rj" 'd["reason"]')"
contains "  remedy_hint names wsl --shutdown"    "then 'wsl --shutdown'" "$(jq_py "$_rj" 'd["remedy_hint"]')"
check "  under remedy_hint, no 'hint' key (AGK4-04)" "False" "$(jq_py "$_rj" '"hint" in d')"
_rj="$(rr_json RR_REASON="The WSL release could not be read, so replacing the Podman deployment was refused ('wsl --version' must show 2.7 or newer)")"
check "unreadable release: changed false"        "False" "$(jq_py "$_rj" 'd["changed"]')"
check "  remedy wsl --version (it reads the release; wsl --update cannot clear this)" "wsl --version" "$(jq_py "$_rj" 'd["remedy"]')"
check "  remedy_hint: EXAKIT_WSL_CHECKED=1, else wsl --update" "If it shows 2.7 or newer, re-run with EXAKIT_WSL_CHECKED=1; otherwise run wsl --update first." "$(jq_py "$_rj" 'd["remedy_hint"]')"
_rj="$(rr_json RR_REASON="Port 8563 is held by something that is not an Exasol Personal deployment")"
check "any other failure: changed true, as before" "True" "$(jq_py "$_rj" 'd["changed"]')"
check "  and the installer remedy"               "bash install.sh" "$(jq_py "$_rj" 'd["remedy"]')"
check "PS twin answers changed false on the same refusal" 1 "$(grep -cF 'ok = $false; status = "refused"; changed = $false' "$ROOT/setup/exakit.ps1")"

echo "a refused repair-runtime, then status --json on the same home - the real note handling (AGK4-05):"
_arm="$(sed -n '/^if begin_step runtime/,/^else$/p' "$ROOT/setup/setup-linux.sh")"
contains "setup-linux.sh's runtime arm takes the note into the soft record" '"$(exakit_take_failure_note)" "the local database"' "$_arm"
_rj="$(rr_json RR_FLOW=real RR_WSL=2.6.1.0)"
check "WSL 2.6, real check: repair-runtime refused" "refused" "$(jq_py "$_rj" 'd["status"]')"
check "  remedy wsl --update"                    "wsl --update" "$(jq_py "$_rj" 'd["remedy"]')"
check "  the note was taken (deleted) by setup-linux.sh" "no" "$([ -f "$RRH/.last-failure" ] && echo yes || echo no)"
_sj="$(env EXAKIT_HOME="$RRH" DB_STUB=interrupted bash "$TMP/cs-run.sh" "$ROOT" "$TMP/cs-body.sh")"
check "  status --json, interrupted: remedy wsl --update, not the refused repair" "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
check "  remedies.database too"                  "wsl --update" "$(jq_py "$_sj" 'd["remedies"]["database"]')"
contains "  remedy_hint names wsl --shutdown"    "wsl --shutdown" "$(jq_py "$_sj" 'd["remedy_hint"]')"
_sj="$(env EXAKIT_HOME="$RRH" DB_STUB=stopped bash "$TMP/cs-run.sh" "$ROOT" "$TMP/cs-body.sh")"
check "  status --json, stopped: remedy wsl --update" "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
_rj="$(rr_json RR_FLOW=real RR_WSL=)"
check "release unreadable, real check: refused"  "refused" "$(jq_py "$_rj" 'd["status"]')"
check "  remedy wsl --version"                   "wsl --version" "$(jq_py "$_rj" 'd["remedy"]')"
_sj="$(env EXAKIT_HOME="$RRH" DB_STUB=interrupted bash "$TMP/cs-run.sh" "$ROOT" "$TMP/cs-body.sh")"
check "  status --json answers the same remedy"  "wsl --version" "$(jq_py "$_sj" 'd["remedy"]')"
contains "  with EXAKIT_WSL_CHECKED=1 in the hint" "EXAKIT_WSL_CHECKED=1" "$(jq_py "$_sj" 'd["remedy_hint"]')"
check "  remedies.runtime agrees"                "wsl --version" "$(jq_py "$_sj" 'd["remedies"].get("runtime")')"
_rj="$(rr_json RR_FLOW=real RR_WSL=2.7.0.0)"
check "WSL 2.7, real check: not refused"         "failed" "$(jq_py "$_rj" 'd["status"]')"

echo "an installer re-run whose start meets the WSL kernel keeps wsl --update until a start succeeds (WSL4-05, AGK3-02):"
# The resume arm books the failed start against the runtime step it never
# unmarks, and takes the note: the record is the only trace left.
_all_steps='["launcher","runtime","exapump","mcp","pyexasol","exakit_helper"]'
_sj="$(cs_json '{"kit_level":1,"steps_completed":'"$_all_steps"',"runtime":{"type":"personal","engine":"podman"}}' DB_STUB=stopped RECORD_REASON="$_NETDIE")"
check "step complete, database stopped: remedy wsl --update, not exakit start" "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
contains "  remedy_hint names wsl --shutdown"    "wsl --shutdown" "$(jq_py "$_sj" 'd["remedy_hint"]')"
contains "  last_failure uses the installer's label, not the step id" "the local database did not finish - This WSL kernel" "$(jq_py "$_sj" 'd["last_failure"]')"
_sj="$(cs_json '{"kit_level":1,"steps_completed":'"$_all_steps"',"runtime":{"type":"personal","engine":"podman"}}' DB_STUB=running RECORD_REASON="$_NETDIE")"
check "  once the database runs, the record is silent" "None" "$(jq_py "$_sj" 'd["last_failure"]')"
lacks "  and no wsl --update"                    "wsl --update" "$(jq_py "$_sj" 'str(d["remedy"]) + str(d["remedies"])')"
_sj="$(cs_json '{"kit_level":1,"steps_completed":'"$_all_steps"',"runtime":{"type":"personal","engine":"podman"}}' DB_STUB=stopped RECORD_REASON="Failed to start the database. Check the log above")"
check "  any other start failure on a complete step: still silent" "None" "$(jq_py "$_sj" 'd["last_failure"]')"
KH="$TMP/keep-home"; mkdir -p "$KH"
(
    EXAKIT_HOME="$KH"; EXAKIT_MANIFEST="$KH/manifest.json"; export EXAKIT_HOME EXAKIT_MANIFEST
    printf '{"kit_level": 1, "steps_completed": ["launcher", "runtime", "exapump"], "runtime": {}}\n' > "$EXAKIT_MANIFEST"
    exakit_record_soft_failure runtime "exakit start" "$_NETDIE" "the local database" >/dev/null 2>&1
    EXAKIT_SOFT_FAILED=""; exakit_record_soft_failure exapump "exakit update" "download failed" "exapump" >/dev/null 2>&1
    printf 'label=%s\n' "$(manifest_get install.soft_failures.runtime.label 2>/dev/null)"
    exakit_prune_soft_failures
    printf 'pruned=%s\n' "$(sf_read_at "$EXAKIT_MANIFEST")"
    exakit_retire_start_soft_failure
    printf 'retired=%s\n' "$(sf_read_at "$EXAKIT_MANIFEST")"
) > "$TMP/keep.out" 2>&1
contains "the label is on disk" "label=the local database" "$(cat "$TMP/keep.out")"
contains "the closing prune keeps the WSL start record, drops the rest" "pruned=runtime" "$(cat "$TMP/keep.out")"
check "a successful start retires it, leaving nothing" "retired=" "$(grep '^retired=' "$TMP/keep.out")"
contains "exakit start retires it once the database runs" "exakit_retire_start_soft_failure" "$(grep -A4 'exakit_runtime_is_running 2>/dev/null; then' "$ROOT/setup/exakit")"
contains "  and so does the installer's resume arm" "exakit_retire_start_soft_failure" "$(grep -A1 'if ( personal_start && personal_wait_ready_or_deploy ); then' "$ROOT/setup/setup-linux.sh")"

echo "a start the launcher took without acting, then a deploy that meets the WSL kernel (WSL4-01):"
# personal_start's network check never runs when the launcher's start exits
# 0; the deploy in personal_wait_ready_or_deploy then fails on netavark's
# error, and that used to be told "repair with: exakit repair-runtime".
wsl401() { # wsl401 <deploy output line> <entry: heal|start>
    (
        _w_line="$1"
        EXAKIT_LOG_FILE="$TMP/wsl401.log"; : > "$EXAKIT_LOG_FILE"
        rm -f "$EXAKIT_FAILURE_NOTE"
        detect_os() { printf 'wsl'; }
        manifest_get() { [ "$1" = runtime.type ] && printf 'personal'; }
        exakit_installation_runtime_type() { printf 'personal'; }
        personal_engine_platform() { return 0; }
        personal_engine_recorded() { printf 'podman'; }
        personal_docker_usable() { return 0; }
        personal_launcher_supports() { return 0; }
        personal_launcher_state() { printf 'running'; }
        personal_note_guest_rebuild() { :; }
        port_in_use() { return 1; }
        personal_cli() { printf 'exasol'; }
        personal_auto_approve_flag() { :; }
        personal_deployment_running() { return 1; }
        personal_deployment_exists() { return 0; }
        personal_repair_command() { printf 'exakit repair-runtime'; }
        _personal_wait_ready_probe() { return 1; }
        run_logged() {
            case "$2" in
                deploy) printf '%s\n' "$_w_line" >> "$EXAKIT_LOG_FILE"; return 1 ;;
            esac
            return 0
        }
        if [ "$2" = start ]; then exakit_runtime_start; else exakit_ensure_runtime_running; fi
    ) 2>&1
}
NFT4='Error: netavark: nftables error: "nft" did not return successfully while applying ruleset'
_out="$(wsl401 "$NFT4" heal)"
contains "self-heal: the launcher's start was taken"   "Database started" "$_out"
contains "  then the deploy's nft error names the kernel" "cannot create the deployment network" "$_out"
contains "  with wsl --update"                         "run wsl --update" "$_out"
lacks    "  never 'repair with'"                       "repair with:" "$_out"
lacks    "  never 'did not come up'"                   "did not come up" "$_out"
_note="$(head -n 1 "$EXAKIT_FAILURE_NOTE" 2>/dev/null)"
contains "  the note is the network sentence"          "cannot create the deployment network: run wsl --update" "$_note"
_sj="$(sj_run stopped "$_note")"
check "  status --json then answers wsl --update"      "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
_sj="$(sj_run interrupted "$_note")"
check "  also for an interrupted deployment"           "wsl --update" "$(jq_py "$_sj" 'd["remedy"]')"
_out="$(wsl401 "$NFT4" start)"
contains "exakit_runtime_start (the post-update restart) names the kernel too" "cannot create the deployment network" "$_out"
lacks    "  never 'repair with'"                       "repair with:" "$_out"
_out="$(wsl401 "Error: some other deploy failure" heal)"
contains "any other deploy failure: the old message"   "did not come up" "$_out"
lacks    "  never blamed on the WSL kernel"            "cannot create the deployment network" "$_out"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
