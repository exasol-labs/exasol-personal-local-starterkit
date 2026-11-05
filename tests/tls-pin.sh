#!/usr/bin/env bash
# tls-pin.sh — the database's TLS certificate pin (audit SEC-14), shell half.
#
#   bash tests/tls-pin.sh
#
# What it pins:
#   - trust on first use: exakit_tls_record reads what the port serves and
#     records it ONLY when nothing is recorded (or with --replace, for a
#     deployment the kit just made); a recorded pin is never silently replaced,
#     and exakit_tls_ensure_pinned records only while the kit's own database is
#     reported running
#   - the clients that carry it, pinned and unpinned: the exapump profile
#     (certificate_fingerprint, lowercase), the temporary admin/read-only
#     profiles the MCP step uses, and the pyexasol/MCP DSN host/<fp>:port
#   - a re-pin rewrites the clients that hold the pin (exapump profile, MCP
#     entries), --profile-only only the profile, sidecar entries never
#   - `exakit status` (prose and --json `tls: {pinned, matches}`) says when the
#     live certificate is not the pinned one, with a remedy that changes nothing
#   - `exakit tls-pin`: shows recorded vs live (exit 0 / 6 / 3), --accept asks
#     and refuses without a terminal (exit 5), --accept --yes re-pins and
#     rewrites, --yes alone is bad input, --json is one object
#   - the command is in the help catalog, its group, both CLIs' dispatch and
#     the read-only allowlist only in its non-mutating form
#
# A sandboxed kit home; no database: the "database port" is a local TLS server
# (tests/lib/tls_server.py) with a certificate generated here. No password is
# ever printed - the sandbox's password file holds a dummy value.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
PIDS=""
cleanup() { for _p in $PIDS; do kill "$_p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"
    fi
}
has() { # has <label> <needle> <haystack>
    case "$3" in
        *"$2"*) PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
        *)      FAIL=$((FAIL + 1)); printf '  FAIL %s: expected to contain "%s", got [%s]\n' "$1" "$2" "$3" ;;
    esac
}
lacks() { # lacks <label> <needle> <haystack>
    case "$3" in
        *"$2"*) FAIL=$((FAIL + 1)); printf '  FAIL %s: did not expect "%s" in [%s]\n' "$1" "$2" "$3" ;;
        *)      PASS=$((PASS + 1)); printf '  ok   %s\n' "$1" ;;
    esac
}
jget() { # jget <json> <python expression over d>
    printf '%s' "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(json.dumps(v) if not isinstance(v, str) else v)' "$2" 2>/dev/null
}

command -v openssl >/dev/null 2>&1 || { echo "SKIP tls-pin.sh: needs openssl to make a self-signed certificate"; exit 0; }
SRV="$ROOT/tests/lib/tls_server.py"
FP1="$(python3 "$SRV" cert "$WORK/certs" one)" || { echo "FAIL could not make a certificate"; exit 1; }
FP2="$(python3 "$SRV" cert "$WORK/certs" two)" || { echo "FAIL could not make a certificate"; exit 1; }
serve() { # serve <name> -> sets PORT
    rm -f "$WORK/port.$1"
    python3 "$SRV" serve "$WORK/certs/$1.pem" "$WORK/certs/$1.key" "$WORK/port.$1" &
    PIDS="$PIDS $!"
    disown "$!" 2>/dev/null || true   # no "Terminated" job notice at cleanup
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -s "$WORK/port.$1" ] && break
        sleep 0.2
    done
    PORT="$(cat "$WORK/port.$1")"
}
serve one; PORT1="$PORT"
serve two; PORT2="$PORT"
CLOSED="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

export HOME="$WORK/home" EXAKIT_HOME="$WORK/kit" EXAKIT_BIN_DIR="$WORK/bin"
export EXAPUMP_CONFIG="$WORK/kit/exapump/config.toml"
unset EXAKIT_REFUSAL_JSON EXAKIT_READONLY_QUERY
mkdir -p "$HOME" "$EXAKIT_HOME/credentials" "$EXAKIT_BIN_DIR"
printf 'dummy-test-value\n' > "$EXAKIT_HOME/credentials/personal_sys_password"
chmod 600 "$EXAKIT_HOME/credentials/personal_sys_password"

echo "the library (setup/lib/common.sh, exapump.sh):"
(
    # shellcheck disable=SC1091
    . "$ROOT/setup/lib/ui.sh"; . "$ROOT/setup/lib/common.sh"; . "$ROOT/setup/lib/exapump.sh"
    run_python_any() { python3 "$@"; }
    run_python() { python3 "$@"; }
    require_python3() { :; }
    EXAKIT_LOG_FILE="$WORK/log"; : > "$EXAKIT_LOG_FILE"
    manifest_init >/dev/null 2>&1
    manifest_set runtime.dsn "127.0.0.1:$PORT1"
    manifest_set runtime.user sys
    manifest_set runtime.password_file "$EXAKIT_HOME/credentials/personal_sys_password"

    check "unpinned: the DSN is unchanged" "127.0.0.1:$PORT1" "$(exakit_tls_pinned_dsn)"
    check "unpinned: nothing is recorded" "1" "$(exakit_tls_recorded_fingerprint >/dev/null 2>&1; echo $?)"
    check "the live fingerprint is the certificate's" "$FP1" "$(exakit_tls_live_fingerprint 127.0.0.1 "$PORT1" 5)"
    check "a port that does not answer TLS gives nothing, exit 1" "|1" "$(exakit_tls_live_fingerprint 127.0.0.1 "$CLOSED" 2; echo "|$?")"

    exapump_write_profile starter-kit 127.0.0.1 "$PORT1" sys "dummy-test-value" >/dev/null 2>&1
    lacks "an unpinned exapump profile has no certificate_fingerprint" "certificate_fingerprint" "$(cat "$EXAPUMP_CONFIG")"
    has "...and keeps the old TLS posture" "validate_certificate = false" "$(cat "$EXAPUMP_CONFIG")"

    exakit_tls_record >/dev/null 2>&1
    check "first use records the live certificate" "$FP1" "$(manifest_get runtime.tls_fingerprint)"
    check "...says the pin changed" "1" "$EXAKIT_TLS_PIN_CHANGED"
    has "...and when" "T" "$(manifest_get runtime.tls_fingerprint_at)"
    check "pinned: the DSN carries the pin (pyexasol form)" "127.0.0.1/$FP1:$PORT1" "$(exakit_tls_pinned_dsn)"
    check "...for any DSN handed in" "127.0.0.1/$FP1:9" "$(exakit_tls_pinned_dsn 127.0.0.1:9)"
    check "the state is recorded|live" "$FP1|$FP1" "$(exakit_tls_state 5)"

    # The port now serves ANOTHER certificate: a redeploy outside the kit, or a squatter.
    manifest_set runtime.dsn "127.0.0.1:$PORT2"
    exakit_tls_record >/dev/null 2>&1
    check "a recorded pin is never silently replaced" "$FP1" "$(manifest_get runtime.tls_fingerprint)"
    check "...and nothing is said to have changed" "0" "$EXAKIT_TLS_PIN_CHANGED"
    check "the state shows the mismatch" "$FP1|$FP2" "$(exakit_tls_state 5)"
    exakit_runtime_is_running() { return 0; }
    exakit_tls_ensure_pinned >/dev/null 2>&1
    check "the lazy record leaves a recorded pin alone" "$FP1" "$(manifest_get runtime.tls_fingerprint)"
    exakit_tls_record --replace >/dev/null 2>&1
    check "--replace (a deployment the kit just made) records the new one" "$FP2" "$(manifest_get runtime.tls_fingerprint)"
    check "...and says so" "1" "$EXAKIT_TLS_PIN_CHANGED"

    manifest_set runtime.tls_fingerprint "$(printf '%s' "$FP2" | tr 'a-f' 'A-F')"
    check "an uppercase record is not a pin (exapump compares lowercase)" "127.0.0.1:9" "$(exakit_tls_pinned_dsn 127.0.0.1:9)"
    manifest_set runtime.tls_fingerprint "not-a-fingerprint"
    check "a malformed record is not a pin" "127.0.0.1:9" "$(exakit_tls_pinned_dsn 127.0.0.1:9)"

    manifest_del runtime.tls_fingerprint
    exakit_runtime_is_running() { return 1; }
    exakit_tls_ensure_pinned >/dev/null 2>&1
    check "the lazy record waits for the kit's own database to be running" "" "$(manifest_get runtime.tls_fingerprint 2>/dev/null)"
    exakit_runtime_is_running() { return 0; }
    manifest_set runtime.dsn "127.0.0.1:$PORT1"
    _rw_log="$WORK/rewrites"; : > "$_rw_log"
    exapump_create_profile_real() { :; }
    eval "exapump_create_profile_real() $(declare -f exapump_create_profile | tail -n +2)"
    exapump_create_profile() { echo profile >> "$_rw_log"; exapump_create_profile_real "$@"; }
    mcp_refresh_client_pins() { echo mcp >> "$_rw_log"; }
    manifest_set components.exapump.profile starter-kit
    manifest_set components.mcp_server.validated true
    exakit_tls_ensure_pinned >/dev/null 2>&1
    check "the lazy record pins an install that predates the pin" "$FP1" "$(manifest_get runtime.tls_fingerprint)"
    check "...and rewrites the exapump profile and the MCP entries" "profile mcp" "$(tr '\n' ' ' < "$_rw_log" | sed 's/ $//')"
    has "the rewritten exapump profile carries the pin, lowercase" "certificate_fingerprint = \"$FP1\"" "$(cat "$EXAPUMP_CONFIG")"
    check "...once, in the kit's section" "1" "$(grep -c certificate_fingerprint "$EXAPUMP_CONFIG")"
    : > "$_rw_log"; exakit_tls_rewrite_clients --profile-only >/dev/null 2>&1
    check "--profile-only rewrites the profile alone" "profile" "$(tr '\n' ' ' < "$_rw_log" | sed 's/ $//')"
    : > "$_rw_log"; manifest_set components.mcp_server.backend sidecar; exakit_tls_rewrite_clients >/dev/null 2>&1
    check "the launcher's sidecar entries hold no DSN and are left alone" "profile" "$(tr '\n' ' ' < "$_rw_log" | sed 's/ $//')"

    _exakit_write_exapump_config "$WORK/temp.toml" 127.0.0.1 "$PORT1" sys "dummy-a" mcp_readonly "dummy-b" STARTER_KIT
    check "the MCP step's admin and read-only profiles are both pinned" "2" "$(grep -c "certificate_fingerprint = \"$FP1\"" "$WORK/temp.toml")"
    manifest_del runtime.tls_fingerprint
    _exakit_write_exapump_config "$WORK/temp2.toml" 127.0.0.1 "$PORT1" sys "dummy-a" mcp_readonly "dummy-b" STARTER_KIT
    check "...and unpinned without a record" "0" "$(grep -c certificate_fingerprint "$WORK/temp2.toml")"
    exapump_write_profile legacy 127.0.0.1 8564 sys "dummy-c" >/dev/null 2>&1
    lacks "a profile for another database (the legacy crossing's) gets no pin" "certificate_fingerprint" "$(sed -n '/^\[legacy\]/,/^$/p' "$EXAPUMP_CONFIG")"
    lacks "no password reaches the log" "dummy" "$(cat "$EXAKIT_LOG_FILE")"
    printf 'RESULT %s %s\n' "$PASS" "$FAIL"
) > "$WORK/lib.out" 2>&1
sed '/^RESULT /d' "$WORK/lib.out"
_lib="$(sed -n 's/^RESULT //p' "$WORK/lib.out")"
[ -n "$_lib" ] || { echo "  FAIL the library checks did not finish"; FAIL=$((FAIL + 1)); }
PASS=$((PASS + ${_lib%% *})); FAIL=$((FAIL + ${_lib##* }))

echo
echo "the CLI (setup/exakit, with the database's probes stubbed):"
STUB="$WORK/cli/exakit"
mkdir -p "$WORK/cli"
ln -s "$ROOT/setup/lib" "$WORK/cli/lib"
LAST_LIB="$(grep -n '^\(\[ -f "\$_lib_dir/[^"]*" \] && \)\?\. "\$_lib_dir/' "$ROOT/setup/exakit" | tail -1 | cut -d: -f1)"
{
    sed -n "1,${LAST_LIB}p" "$ROOT/setup/exakit"
    cat <<'STUB_EOF'
# tls-pin.sh: the database's probes, and the client writers, stubbed.
personal_status() { printf '%s\n' "${EXAKIT_TEST_DB:-running}"; }
personal_launcher_state() { printf 'running\n'; }
exakit_runtime_is_running() { [ "${EXAKIT_TEST_DB:-running}" = running ]; }
exakit_service_ids() { :; }
exakit_loaded_datasets() { :; }
exapump_create_profile() { echo profile >> "$EXAKIT_TEST_REWRITES"; }
mcp_refresh_client_pins() { echo mcp >> "$EXAKIT_TEST_REWRITES"; }
STUB_EOF
    sed -n "$((LAST_LIB + 1)),\$p" "$ROOT/setup/exakit"
} > "$STUB"
bash -n "$STUB" || { echo "  FAIL the CLI stub does not parse"; exit 1; }
export EXAKIT_TEST_REWRITES="$WORK/cli-rewrites"
M="$EXAKIT_HOME/manifest.json"
write_manifest() { # write_manifest <port> [fingerprint]
    python3 - "$M" "$1" "${2:-}" "$EXAKIT_HOME/credentials/personal_sys_password" <<'PY'
import json, sys
path, port, fp, pw = sys.argv[1:5]
runtime = {"type": "personal", "dsn": "127.0.0.1:" + port, "user": "sys", "password_file": pw}
if fp:
    runtime["tls_fingerprint"] = fp
    runtime["tls_fingerprint_at"] = "2026-01-01T00:00:00Z"
doc = {"kit_level": 1, "runtime": runtime,
       "steps_completed": ["launcher", "runtime", "exapump", "mcp", "pyexasol", "exakit_helper"],
       "components": {"exapump": {"profile": "starter-kit"}, "mcp_server": {"validated": True}}}
json.dump(doc, open(path, "w"))
PY
}
cli() { OUT="$(bash "$STUB" "$@" 2>&1 </dev/null)"; CODE=$?; }
cli_out() { OUT="$(bash "$STUB" "$@" 2>/dev/null </dev/null)"; CODE=$?; }

write_manifest "$PORT1" "$FP1"
cli_out status --json
check "status --json: pinned and matching" '{"pinned": true, "matches": true}' "$(jget "$OUT" 'd["tls"]')"
lacks "...and no tls remedy" '"tls"' "$(jget "$OUT" 'd["remedies"]')"
cli status
has "status: the TLS row says the certificate matches" "certificate matches" "$OUT"

write_manifest "$PORT2" "$FP1"
cli_out status --json
check "status --json: a changed certificate is matches: false" '{"pinned": true, "matches": false}' "$(jget "$OUT" 'd["tls"]')"
check "...its remedy SHOWS the two values (changes nothing)" "exakit tls-pin" "$(jget "$OUT" 'd["remedies"]["tls"]')"
has "...and the hint names both causes" "outside the kit" "$(jget "$OUT" 'd["remedy_hints"]["tls"]')"
cli status
has "status: the TLS row says the certificate changed" "certificate CHANGED" "$OUT"
has "...and names the command that compares" "exakit tls-pin" "$OUT"

write_manifest "$CLOSED" "$FP1"
cli_out status --json
check "status --json: nothing answering TLS is matches: null" '{"pinned": true, "matches": null}' "$(jget "$OUT" 'd["tls"]')"
write_manifest "$PORT1"
cli_out status --json
check "status --json: nothing recorded is pinned: false" '{"pinned": false, "matches": null}' "$(jget "$OUT" 'd["tls"]')"
cli status
has "status: a running, unpinned database names the pin command" "exakit tls-pin --accept" "$OUT"

echo
write_manifest "$PORT1" "$FP1"
cli tls-pin
check "tls-pin: pinned and matching exits 0" "0" "$CODE"
has "...showing the recorded fingerprint" "$FP1" "$OUT"
has "...and saying it matches" "serves the pinned certificate" "$OUT"
cli_out tls-pin --json
check "tls-pin --json is one object: status" "pinned" "$(jget "$OUT" 'd["status"]')"
check "...matches" "true" "$(jget "$OUT" 'd["matches"]')"
check "...the recorded and the live fingerprint" "$FP1 $FP1" "$(jget "$OUT" 'd["fingerprint"]') $(jget "$OUT" 'd["live"]')"
check "...when it was recorded" "2026-01-01T00:00:00Z" "$(jget "$OUT" 'd["recorded_at"]')"
check "...and nothing changed" "false" "$(jget "$OUT" 'd["changed"]')"

write_manifest "$PORT2" "$FP1"
cli tls-pin
check "tls-pin: a changed certificate exits 6" "6" "$CODE"
has "...shows the live one" "$FP2" "$OUT"
has "...and says it is not the pinned one" "NOT the pinned one" "$OUT"
check "...and changes nothing" "$FP1" "$(jget "$(cat "$M")" 'd["runtime"]["tls_fingerprint"]')"
cli_out tls-pin --json
check "tls-pin --json: mismatch" "mismatch false 6" "$(jget "$OUT" 'd["status"]') $(jget "$OUT" 'd["matches"]') $CODE"

: > "$EXAKIT_TEST_REWRITES"
cli tls-pin --accept
check "tls-pin --accept without a terminal is not confirmed: exit 5" "5" "$CODE"
check "...and nothing changed" "$FP1" "$(jget "$(cat "$M")" 'd["runtime"]["tls_fingerprint"]')"
has "...naming the scripted form, for after the user said yes" "exakit tls-pin --accept --yes" "$OUT"
cli_out tls-pin --accept --json
check "tls-pin --accept --json never prompts: declined, exit 5" "declined 5" "$(jget "$OUT" 'd["status"]') $CODE"
cli tls-pin --yes
check "tls-pin --yes alone is bad input: exit 2" "2" "$CODE"
cli tls-pin --bogus
check "an unknown option is bad input: exit 2" "2" "$CODE"
check "nothing was rewritten by any of that" "" "$(cat "$EXAKIT_TEST_REWRITES")"

cli_out tls-pin --accept --yes --json
check "tls-pin --accept --yes re-pins: exit 0" "0" "$CODE"
check "...records the live certificate" "$FP2" "$(jget "$(cat "$M")" 'd["runtime"]["tls_fingerprint"]')"
check "...answers changed: true, matching" "true true pinned" "$(jget "$OUT" 'd["changed"]') $(jget "$OUT" 'd["matches"]') $(jget "$OUT" 'd["status"]')"
check "...and rewrote the exapump profile and the MCP entries" "profile mcp" "$(tr '\n' ' ' < "$EXAKIT_TEST_REWRITES" | sed 's/ $//')"
cli tls-pin --accept --yes
check "re-pinning to the same certificate is a no-op: exit 0" "0" "$CODE"
has "...said so" "nothing changed" "$OUT"

write_manifest "$CLOSED" "$FP1"
cli tls-pin
check "tls-pin with nothing answering TLS exits 3" "3" "$CODE"
has "...and names exakit start" "exakit start" "$OUT"
write_manifest "$PORT1"
cli tls-pin
check "tls-pin with nothing recorded exits 0" "0" "$CODE"
has "...and names the command that pins" "exakit tls-pin --accept" "$OUT"
rm -f "$M"
cli_out tls-pin --json
check "tls-pin with no install exits 4" "4" "$CODE"

echo
echo "the command surface:"
_cmd="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=[x for x in d["commands"] if x["command"]=="tls-pin"]; print(len(c), sorted(c[0]["exit_codes"]) if c else "", [g["title"] for g in d["groups"] if "tls-pin" in g["commands"]])' "$ROOT/setup/help/exakit.json")"
check "the help catalog has tls-pin, its exit codes and its group" "1 ['0', '2', '3', '4', '5', '6'] ['Repair and removal']" "$_cmd"
has "the shell CLI dispatches it" 'tls-pin)  shift; cmd_tls_pin' "$(cat "$ROOT/setup/exakit")"
has "the Windows CLI dispatches it" '"tls-pin" {' "$(cat "$ROOT/setup/exakit.ps1")"
has "showing it is a read-only query" 'tls-pin)
        case " $* " in *" --accept "*) ;; *) export EXAKIT_READONLY_QUERY=1 ;; esac ;;' "$(cat "$ROOT/setup/exakit")"
_allow="$(sed -n '/^READONLY = \[/,/^DENY = /p' "$ROOT/setup/lib/common.sh")"
has "the allowlist names the exact read-only form" 'tls-pin)" % prefix' "$_allow"
lacks "...and never a prefix that would allow --accept" 'tls-pin:*' "$_allow"
has "the Windows allowlist the same" 'Bash($prefix tls-pin --json)' "$(cat "$ROOT/setup/lib/exakit-common.ps1")"
_help="$(bash "$STUB" tls-pin --help 2>&1)"
has "tls-pin --help renders its page" "--accept" "$_help"

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
