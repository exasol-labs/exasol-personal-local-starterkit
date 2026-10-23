#!/usr/bin/env bash
# personal-readiness.sh — behavioural tests for the Exasol Personal readiness
# and adoption probes in setup/lib/runtime-personal.sh.
#
#   bash tests/personal-readiness.sh
#
# What it pins, and why each one exists:
#   - personal_tls_answers tells a database that completes a TLS handshake apart
#     from a port that is merely open. Under rootless Podman the published port
#     belongs to pasta from the moment the container starts, a minute or more
#     before the database inside accepts a connection; pasta accepts the TCP
#     connection and resets it, which every client reports as "tls handshake
#     eof". A port-open wait returned instantly and declared a booting database
#     reachable; the next step's SELECT 1 then failed six times in a row.
#   - personal_deployment_running never adopts a database the launcher does not
#     own: the launcher's "stopped" and "deployment_failed" outrank an answering
#     port, and with no deployment of ours only a SELECT through the kit's own
#     profile counts. Windows and WSL share one network stack, so the other
#     side's database holds 8563 here too — adopting it handed the rest of the
#     install a password that could never work.
#   - personal_recover_slow_first_boot treats the launcher's reconcile as the
#     ownership proof: when its deploy fails, the recovery fails, instead of
#     "continuing with the database it can reach".
#   - personal_start on a deployment the launcher records as failed retries the
#     launcher's deploy, because in that state its start exits 0 doing nothing.
#
# Uses spare ports (186xx) and a stub launcher; never touches a real deployment.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
CHILDREN=""
cleanup() { for _p in $CHILDREN; do kill -9 "$_p" 2>/dev/null || true; done; rm -rf "$TMP"; }
trap cleanup EXIT

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

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 required for this test"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl required for this test"; exit 0; }

# pick_port <start> — first port at or above <start> that nothing answers on.
pick_port() {
    _p="$1"
    while (exec 3<>"/dev/tcp/127.0.0.1/$_p") 2>/dev/null; do exec 3>&- 3<&-; _p=$((_p + 1)); done
    echo "$_p"
}

# --- fixtures: three kinds of port -----------------------------------------
# 1. A TLS server with a self-signed certificate: what the database is.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=localhost" -days 1 >/dev/null 2>&1 || { echo "SKIP: openssl could not make a certificate"; exit 0; }
cat > "$TMP/tls_server.py" <<'PY'
import socket, ssl, sys
port, cert, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(16)
while True:
    try:
        c, _ = s.accept()
        try:
            t = ctx.wrap_socket(c, server_side=True)
            t.close()
        except Exception:
            c.close()
    except Exception:
        pass
PY
# 2. A listener that accepts and immediately closes: pasta (or the launcher's
#    runner) with nothing behind it - the "tls handshake eof" port.
cat > "$TMP/reset_server.py" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen(16)
while True:
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
PY
# 3. A closed port: nothing at all.
TLS_PORT="$(pick_port 18600)"
python3 "$TMP/tls_server.py" "$TLS_PORT" "$TMP/cert.pem" "$TMP/key.pem" >/dev/null 2>&1 &
CHILDREN="$CHILDREN $!"
RESET_PORT="$(pick_port $((TLS_PORT + 1)))"
python3 "$TMP/reset_server.py" "$RESET_PORT" >/dev/null 2>&1 &
CHILDREN="$CHILDREN $!"
CLOSED_PORT="$(pick_port $((RESET_PORT + 1)))"
sleep 1

# --- harness -----------------------------------------------------------------
# Source the real module with the loggers and the common-layer helpers stubbed,
# then run one probe. Everything after HARNESS-time is the module's own code.
cat > "$TMP/harness.sh" <<HARNESS
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
ui_spin_begin(){ :; }; ui_spin_end(){ :; }
manifest_set(){ :; }
manifest_get(){ printf '%s' "\${STUB_PROFILE:-}"; }
exakit_run_bounded(){ shift; "\$@"; }
port_in_use(){ (exec 3<>"/dev/tcp/127.0.0.1/\$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }; return 1; }
run_logged(){ printf 'RUN %s\n' "\$*" >> "$TMP/calls"; for _fv in \$(printf '%s' "\${STUB_FAIL_VERB:-never}" | tr , ' '); do case " \$* " in *" \$_fv "*) return 1;; esac; done; return 0; }
detect_wsl_version(){ [ "\${STUB_WSL:-0}" = 1 ]; }
EXAKIT_PERSONAL_DEPLOY_DIR="$TMP/no-deployment"
source "$ROOT/setup/lib/runtime-personal.sh"
personal_cli(){ printf 'exasol-stub'; }
personal_auto_approve_flag(){ printf -- '--auto-approve'; }
personal_launcher_supports(){ return 0; }
personal_launcher_version(){ printf '2.3.0'; }
personal_guest_rebuild_expected(){ return 1; }
personal_note_guest_rebuild(){ :; }
personal_repair_command(){ printf 'exakit repair-runtime'; }
personal_deployment_wedged(){ return 1; }
personal_reap_orphan_daemon(){ return 1; }
personal_port_holder_hint(){ :; }
personal_db_port_pids(){ :; }
personal_launcher_state(){ printf '%s' "\${STUB_STATE:-}"; }
# The crossing's accessors exist only on a machine with a legacy record, and
# the hint guards on that with command -v, so they are defined only when the
# scenario asks for them.
if [ "\${STUB_LEGACY:-0}" = 1 ]; then
    legacy_db_recorded(){ return 0; }
    legacy_container_state(){ printf '%s' "\${STUB_LEGACY_STATE:-running}"; }
    legacy_container(){ printf 'exasol-nano'; }
    legacy_engine_name(){ printf 'docker'; }
fi
personal_deployment_exists(){ [ "\${STUB_EXISTS:-0}" = 1 ]; }
exakit_db_reachable(){ [ "\${STUB_SQL_OK:-0}" = 1 ]; }
[ -n "\${STUB_TLS:-}" ] && eval "personal_tls_answers(){ [ \"\$STUB_TLS\" = 1 ]; }"
EXAKIT_PERSONAL_PORT="\${STUB_PORT:-$CLOSED_PORT}"
# The deploy ladder's collaborators, for the never-booted and container-error
# scenarios. confirm_env answers from the variable like the real one and, with
# none set, prints the question and takes its default (no terminal here).
exakit_note_failure(){ printf 'NOTE %s\n' "\$*"; }
exakit_install_command(){ printf 'install-cmd'; }
confirm_env(){ eval "_cev=\\\${\$1:-}"; case "\$_cev" in 1|y|Y|yes|YES|Yes) return 0;; 0|n|N|no|NO|No) return 1;; esac; printf 'ASK %s [%s]\n' "\$2" "\$3"; [ "\$3" = y ]; }
personal_install_podman(){ return 0; }
personal_podman_running(){ return 0; }
push_rollback(){ printf 'FRESH-DEPLOY\n'; exit 0; }
[ -n "\${STUB_CERR+x}" ] && eval 'personal_container_error(){ [ -n "\$STUB_CERR" ] && printf "%s\\n" "\$STUB_CERR"; return 0; }'
[ -n "\${STUB_PENDING:-}" ] && eval 'personal_first_boot_pending(){ [ "\$STUB_PENDING" = 1 ]; }'
[ "\${STUB_FAST_SLEEP:-0}" = 1 ] && eval 'sleep(){ :; }'
[ "\${STUB_SLOW_FAIL:-0}" = 1 ] && eval 'personal_recover_slow_first_boot(){ return 1; }'
eval "\$@"
HARNESS
probe() { # probe <ENV=val ...> -- <shell to eval>; echoes stdout then "rc=N"
    _envs=""
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do _envs="$_envs $1"; shift; done
    shift
    : > "$TMP/calls"
    _out="$(env $_envs bash "$TMP/harness.sh" "$@" 2>&1)"; _rc=$?
    printf '%s\nrc=%s' "$_out" "$_rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }

echo "personal_tls_answers: a handshake, not an open port"
check "TLS server answers"        0 "$(rc_of "$(probe STUB_PORT="$TLS_PORT" -- 'personal_tls_answers')")"
check "accept-and-close does not" 1 "$(rc_of "$(probe STUB_PORT="$RESET_PORT" -- 'personal_tls_answers')")"
check "closed port does not"      1 "$(rc_of "$(probe STUB_PORT="$CLOSED_PORT" -- 'personal_tls_answers')")"
# ...and without openssl the python3 road gives the same three answers.
mkdir -p "$TMP/bin"
for _tool in python3 grep sed head tail tr cat awk sleep date env bash sh ps timeout; do
    _path="$(command -v "$_tool" 2>/dev/null)" && ln -s "$_path" "$TMP/bin/$_tool" 2>/dev/null
done
check "python3 road: TLS server answers"        0 "$(rc_of "$(probe PATH="$TMP/bin" STUB_PORT="$TLS_PORT" -- 'personal_tls_answers')")"
check "python3 road: accept-and-close does not" 1 "$(rc_of "$(probe PATH="$TMP/bin" STUB_PORT="$RESET_PORT" -- 'personal_tls_answers')")"
check "python3 road: closed port does not"      1 "$(rc_of "$(probe PATH="$TMP/bin" STUB_PORT="$CLOSED_PORT" -- 'personal_tls_answers')")"

echo "personal_db_answers: the handshake alone, so a broken exapump cannot report the database down"
check "handshake completes -> answers"                 0 "$(rc_of "$(probe STUB_PORT="$TLS_PORT" -- 'personal_db_answers')")"
check "accept-and-close -> does not"                   1 "$(rc_of "$(probe STUB_PORT="$RESET_PORT" -- 'personal_db_answers')")"
# A virus scanner holding the freshly installed exapump made every SELECT fail;
# with the liveness probe asking exapump, a healthy database read as "not
# running" and the installer went on to "self-heal" it.
check "a failing SELECT does not make a live database dead" 0 "$(rc_of "$(probe STUB_PROFILE=starter-kit STUB_SQL_OK=0 STUB_PORT="$TLS_PORT" -- 'personal_db_answers')")"

echo "personal_deployment_running: the launcher's word outranks the port, ownership is proven"
check "port silent -> not running"                                        1 "$(rc_of "$(probe STUB_EXISTS=1 STUB_STATE=database_ready STUB_PORT="$CLOSED_PORT" -- 'personal_deployment_running')")"
check "ours, launcher says stopped, port answers TLS -> not running"      1 "$(rc_of "$(probe STUB_EXISTS=1 STUB_STATE=stopped STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"
check "ours, launcher says deployment_failed, TLS answers -> not running" 1 "$(rc_of "$(probe STUB_EXISTS=1 STUB_STATE=deployment_failed STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"
check "ours, launcher says database_ready, TLS answers -> running"        0 "$(rc_of "$(probe STUB_EXISTS=1 STUB_STATE=database_ready STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"
check "ours, launcher cannot say, TLS answers -> running"                 0 "$(rc_of "$(probe STUB_EXISTS=1 STUB_STATE= STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"
check "ours, launcher says database_ready, accept-and-close -> not running" 1 "$(rc_of "$(probe STUB_EXISTS=1 STUB_STATE=database_ready STUB_PORT="$RESET_PORT" -- 'personal_deployment_running')")"
check "ours, database answers, exapump broken -> still running"            0 "$(rc_of "$(probe STUB_EXISTS=1 STUB_STATE=database_ready STUB_PROFILE=starter-kit STUB_SQL_OK=0 STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"
check "no deployment of ours, TLS answers, no profile -> NOT adopted"     1 "$(rc_of "$(probe STUB_EXISTS=0 STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"
check "no deployment of ours, profile's SELECT fails -> NOT adopted"      1 "$(rc_of "$(probe STUB_EXISTS=0 STUB_PROFILE=starter-kit STUB_SQL_OK=0 STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"
check "no deployment of ours, profile's SELECT works -> running"          0 "$(rc_of "$(probe STUB_EXISTS=0 STUB_PROFILE=starter-kit STUB_SQL_OK=1 STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"

echo "personal_foreign_db_hint: names the other side only when something answers like Exasol"
check "nothing answers -> empty"                    "" "$(probe STUB_PORT="$CLOSED_PORT" -- 'personal_foreign_db_hint' | sed '$d')"
check "accept-and-close -> empty (not a database)"  "" "$(probe STUB_PORT="$RESET_PORT" -- 'personal_foreign_db_hint' | sed '$d')"
_hint="$(probe STUB_PORT="$TLS_PORT" -- 'personal_foreign_db_hint')"
contains "TLS answers, not WSL" "did not deploy" "$_hint"
_hint_wsl="$(probe STUB_WSL=1 STUB_PORT="$TLS_PORT" -- 'personal_foreign_db_hint')"
contains "TLS answers, under WSL, names the Windows side" "Windows side" "$_hint_wsl"
contains "TLS answers, under WSL, names the remedy"       "exakit stop" "$_hint_wsl"
# THE COMMONEST HOLDER OF THIS PORT IS THIS MACHINE'S OWN PREVIOUS KIT. Naming
# WSL whatever is really there sent a Windows user with a local container
# looking for a database in a distro that did not have one.
_hint_legacy="$(probe STUB_LEGACY=1 STUB_PORT="$TLS_PORT" -- 'personal_foreign_db_hint')"
contains "a recorded container on the port is named"  "exasol-nano" "$_hint_legacy"
contains "...with the command that stops it"          "docker stop exasol-nano" "$_hint_legacy"
contains "...and the road out"                        "copy its data across" "$_hint_legacy"
case "$_hint_legacy" in
    *WSL*) check "...and no WSL red herring" "no WSL" "WSL" ;;
    *)     check "...and no WSL red herring" "no WSL" "no WSL" ;;
esac
# A recorded container that is NOT the thing on the port falls back to the
# general sentence: it is not evidence about whatever is answering.
_hint_stopped="$(probe STUB_LEGACY=1 STUB_LEGACY_STATE=stopped STUB_PORT="$TLS_PORT" -- 'personal_foreign_db_hint')"
contains "a stopped container is not blamed for the port" "did not deploy" "$_hint_stopped"

echo "personal_recover_slow_first_boot: waits for the handshake, and the reconcile is the proof"
_out="$(probe STUB_TLS=1 -- 'personal_recover_slow_first_boot')"
check "database answers, deploy reconciles -> success" 0 "$(rc_of "$_out")"
contains "  ...and says so" "record agrees" "$_out"
_out="$(probe STUB_TLS=1 STUB_FAIL_VERB=deploy -- 'personal_recover_slow_first_boot')"
check "database answers, deploy fails -> FAILURE, not 'continue with what answers'" 1 "$(rc_of "$_out")"
contains "  ...and the warning names the port" "answers on port" "$_out"
_out="$(probe STUB_TLS=0 EXAKIT_PERSONAL_READY_TIMEOUT=1 -- 'personal_recover_slow_first_boot')"
check "database never answers within the budget -> failure" 1 "$(rc_of "$_out")"
case "$(cat "$TMP/calls")" in *deploy*) check "  ...and deploy was not attempted" "no deploy" "deploy";; *) check "  ...and deploy was not attempted" "no deploy" "no deploy";; esac

echo "personal_wait_ready: reachable means a handshake completed"
_out="$(probe STUB_TLS=1 -- 'personal_wait_ready')"
check "handshake completes -> reachable" 0 "$(rc_of "$_out")"
contains "  ...reported" "Deployment is reachable" "$_out"
_out="$(probe STUB_TLS=0 EXAKIT_PERSONAL_READY_TIMEOUT=1 -- 'personal_wait_ready')"
check "no handshake within the budget -> dies" 1 "$(rc_of "$_out")"
contains "  ...naming the ceiling" "did not answer within" "$_out"

echo "personal_start: a deployment the launcher records as failed is deployed again, not 'started'"
_out="$(probe STUB_STATE=deployment_failed -- 'personal_start')"
check "deployment_failed -> exit 0" 0 "$(rc_of "$_out")"
contains "  ...deploy was run"     "RUN exasol-stub deploy" "$(cat "$TMP/calls")"
case "$(cat "$TMP/calls")" in *" start"*) check "  ...start was not" "no start" "start";; *) check "  ...start was not" "no start" "no start";; esac
_out="$(probe STUB_STATE=deployment_failed STUB_FAIL_VERB=deploy -- 'personal_start')"
check "deployment_failed, deploy fails -> dies" 1 "$(rc_of "$_out")"
contains "  ...naming the repair" "exakit repair-runtime" "$_out"
_out="$(probe STUB_STATE=stopped -- 'personal_start')"
check "stopped -> the ordinary start" 0 "$(rc_of "$_out")"
contains "  ...start was run" "RUN exasol-stub start" "$(cat "$TMP/calls")"

echo "personal_container_error: the container's own error, never a running one's"
mkdir -p "$TMP/podbin"
cat > "$TMP/podbin/podman" <<'POD'
#!/bin/sh
case "$1" in
    ps) printf '%s\n' "$PODMAN_PS" ;;
    inspect) printf '%s\n' "$PODMAN_ERR" ;;
    *) exit 1 ;;
esac
POD
chmod +x "$TMP/podbin/podman"
_pids_err="crun: controller \`pids\` is not available under /sys/fs/cgroup/non-systemd/x/cgroup.controllers: OCI runtime error"
# probe word-splits its NAME=value list, so values with spaces travel in the
# environment instead.
export PODMAN_ERR="$_pids_err" PODMAN_PS="exasol-db-abc created"
_out="$(probe PATH="$TMP/podbin:$PATH" -- 'detect_os(){ printf linux; }; personal_container_error' | sed '$d')"
check "a created container's State.Error is returned" "$_pids_err" "$_out"
PODMAN_PS="exasol-db-abc running"
_out="$(probe PATH="$TMP/podbin:$PATH" -- 'detect_os(){ printf linux; }; personal_container_error' | sed '$d')"
check "a running container is never blamed" "" "$_out"
PODMAN_PS="exasol-db-abc created"
_out="$(probe PATH="$TMP/podbin:$PATH" -- 'detect_os(){ printf macos; }; personal_container_error' | sed '$d')"
check "macOS's podman is not the launcher's" "" "$_out"

echo "personal_known_cause: the errors the kit can name, in this platform's words"
_out="$(probe -- "detect_os(){ printf wsl; }; personal_known_cause '$_pids_err'")"
contains "pids is named with the issue" "podman-container-tools/podman#29909" "$_out"
contains "...and under WSL as a WSL problem" "WSL 2.9+" "$_out"
_out="$(probe -- "detect_os(){ printf linux; }; personal_known_cause '$_pids_err'")"
contains "...and on Linux with the systemd delegation" "Delegate=cpu cpuset io memory pids" "$_out"
_out="$(probe -- "detect_os(){ printf wsl; }; personal_known_cause 'dial tcp: lookup registry-1.docker.io: Temporary failure in name resolution'")"
contains "DNS under WSL names the Windows-side setting" 'dnsTunneling=true' "$_out"
contains "...in the right file" '%USERPROFILE%\.wslconfig' "$_out"
check "anything else is not guessed at" 1 "$(rc_of "$(probe -- "personal_known_cause 'exit status 125'")")"

echo "a container that refused to start ends the wait, and is the reason"
export STUB_CERR="$_pids_err"
_out="$(probe STUB_TLS=0 STUB_FAST_SLEEP=1 EXAKIT_PERSONAL_READY_TIMEOUT=600 -- 'personal_wait_ready_or_deploy')"
check "the wait gives up" 1 "$(rc_of "$_out")"
contains "  ...saying the container's error" "The database container could not start: crun: controller" "$_out"
contains "  ...recording it as the reason" "NOTE The database never answered: the database container could not start (crun" "$_out"
contains "  ...with the fix" "Fix: " "$_out"
case "$(cat "$TMP/calls")" in *deploy*) check "  ...and no deploy into the same error" "no deploy" "deploy";; *) check "  ...and no deploy into the same error" "no deploy" "no deploy";; esac
_tries="$(printf '%s\n' "$_out" | grep -c 'could not start: crun')"
check "  ...said once, not every poll" 1 "$_tries"
_out="$(probe STUB_TLS=0 STUB_FAST_SLEEP=1 -- 'personal_wait_ready')"
check "personal_wait_ready dies on it" 1 "$(rc_of "$_out")"
contains "  ...naming the container, not a timeout" "The database could not start: the database container could not start" "$_out"
unset STUB_CERR PODMAN_ERR PODMAN_PS

echo "personal_deploy_local: a deployment that never started is offered for replacement, default yes"
_dl() { probe STUB_EXISTS=1 STUB_STATE=deployment_failed STUB_FAIL_VERB=deploy STUB_SLOW_FAIL=1 STUB_TLS=0 STUB_CERR= "$@" -- 'personal_deploy_local'; }
_out="$(_dl STUB_PENDING=1)"
contains "the never-started question is asked" "ASK This deployment never started, so it holds no data. Remove it and deploy a fresh one? [y]" "$_out"
case "$_out" in *"keep its data"*) check "  ...not the keep-its-data one" no yes ;; *) check "  ...not the keep-its-data one" no no ;; esac
contains "  ...unattended, the default replaces it" "RUN exasol-stub destroy --remove --auto-approve" "$(cat "$TMP/calls")"
contains "  ...and a fresh deploy follows" "FRESH-DEPLOY" "$_out"
_out="$(_dl STUB_PENDING=1 EXAKIT_REPLACE_DB=0)"
check "EXAKIT_REPLACE_DB=0 declines it" 1 "$(rc_of "$_out")"
case "$(cat "$TMP/calls")" in *destroy*) check "  ...deleting nothing" none destroy ;; *) check "  ...deleting nothing" none none ;; esac
contains "  ...with a reason" "NOTE A deployment that never started could not be brought up, and replacing it was declined" "$_out"
_out="$(_dl STUB_PENDING=0 STUB_FAIL_VERB=deploy,start)"
contains "a deployment that ever answered keeps the old ladder" "ASK Start the existing database and keep its data? [y]" "$_out"
contains "  ...whose DELETE still defaults to no" "ASK DELETE the stopped deployment and its data, and deploy a fresh one? This cannot be undone. [n]" "$_out"
case "$(cat "$TMP/calls")" in *destroy*) check "  ...and deletes nothing unasked" none destroy ;; *) check "  ...and deletes nothing unasked" none none ;; esac
_out="$(_dl STUB_PENDING=1 EXAKIT_REUSE_DB=1)"
case "$_out" in *"never started"*) check "EXAKIT_REUSE_DB=1 keeps the old ladder" ladder never ;; *) check "EXAKIT_REUSE_DB=1 keeps the old ladder" ladder ladder ;; esac

echo ""
echo "personal-readiness.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
