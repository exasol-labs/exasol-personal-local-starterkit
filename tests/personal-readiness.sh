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
#     "continuing with the database it can reach". When the launcher already
#     records its database as ready there is nothing to reconcile, and no
#     deploy is run over the running VM.
#   - personal_start on a deployment the launcher records as failed retries the
#     launcher's deploy, because in that state its start exits 0 doing nothing.
#     When the kit's own runner (executed from the launcher's cache, listening
#     on the port) still runs the VM, the launcher refuses that deploy with "VM
#     is already running": the runner is stopped first, then deploy runs once.
#     A listener that is not certainly ours is never signalled.
#   - personal_tls_answers is decided by openssl's OUTPUT, never its exit
#     status, under the `set -o pipefail` every entry point runs with. macOS
#     ships LibreSSL as /usr/bin/openssl, and its s_client exits 1 after a
#     completed handshake when stdin hits EOF; piped into `grep -q` under
#     pipefail that made the probe fail against a database that was up, so a
#     slow first boot was never recovered and status called the database's own
#     port "held by another process". The harness runs with pipefail for that
#     reason, and the probe is also run through the real exakit_run_bounded
#     and the real /usr/bin/openssl.
#
# Uses spare ports (186xx) and a stub launcher; never touches a real deployment.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TMP="$(mktemp -d)"
CHILDREN=""
# Listeners started inside $(...) (start_listener) run in a subshell, where an
# append to CHILDREN is lost - they leaked past the run. Every listener pid
# also goes into this file, which the EXIT trap reads and kills.
CHILD_PIDS="$TMP/child-pids"
: > "$CHILD_PIDS"
cleanup() {
    for _p in $CHILDREN $(cat "$CHILD_PIDS" 2>/dev/null); do kill -9 "$_p" 2>/dev/null || true; done
    rm -rf "$TMP"
}
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
# Every entry point (setup/exakit, setup-macos.sh, setup-linux.sh) runs with it.
set -o pipefail
info(){ printf 'INFO %s\n' "\$*"; }; ok(){ printf 'OK %s\n' "\$*"; }; warn(){ printf 'WARN %s\n' "\$*"; }
die(){ printf 'DIE %s\n' "\$*"; exit 1; }
ui_spin_begin(){ :; }; ui_spin_end(){ :; }
manifest_set(){ :; }
manifest_get(){ printf '%s' "\${STUB_PROFILE:-}"; }
exakit_run_bounded(){ shift; "\$@"; }
port_in_use(){ (exec 3<>"/dev/tcp/127.0.0.1/\$1") 2>/dev/null && { exec 3>&- 3<&-; return 0; }; return 1; }
run_logged(){
    printf 'RUN %s\n' "\$*" >> "$TMP/calls"
    # The launcher over a VM its runner still runs: deploy refuses.
    case " \$* " in *" deploy "*)
        if [ -n "\${STUB_VM_PID:-}" ] && command kill -0 "\$STUB_VM_PID" 2>/dev/null; then
            printf 'Error: VM is already running\n'; return 1
        fi;;
    esac
    for _fv in \$(printf '%s' "\${STUB_FAIL_VERB:-never}" | tr , ' '); do case " \$* " in *" \$_fv "*) return 1;; esac; done; return 0; }
detect_wsl_version(){ [ "\${STUB_WSL:-0}" = 1 ]; }
EXAKIT_PERSONAL_DEPLOY_DIR="\${STUB_DEPLOY_DIR:-$TMP/no-deployment}"
# The deployment these cases recover is the kit's own (OWN-06: only that one
# is ever deployed again).
exakit_component_is_managed(){ return 0; }
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
# The real lsof-backed listener lookup only for the runner scenarios, which
# start a real process on a spare port; every other probe sees no listener.
if [ "\${STUB_REAL_PIDS:-0}" = 1 ]; then
    kill(){ printf 'KILL %s\n' "\$*" >> "$TMP/calls"; command kill "\$@"; }
else
    personal_db_port_pids(){ :; }
fi
personal_launcher_state(){ printf '%s' "\${STUB_STATE:-}"; }
# The real bound, for the probes that must prove a hung client is cut off.
if [ "\${STUB_REAL_BOUNDED:-0}" = 1 ]; then
    eval "\$(sed -n '/^exakit_run_bounded()/,/^}/p' "$ROOT/setup/lib/common.sh")"
fi
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
# Never adopted by its port (D3): the kit's database is starter-kit-local, on
# its own port. Even a database the kit's profile can log into is not it.
check "no deployment of ours, profile's SELECT works -> still NOT adopted" 1 "$(rc_of "$(probe STUB_EXISTS=0 STUB_PROFILE=starter-kit STUB_SQL_OK=1 STUB_PORT="$TLS_PORT" -- 'personal_deployment_running')")"

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

# A launcher that already records its database as up is not deployed over:
# a deploy over a running VM is answered with "VM is already running" and a
# record that then refuses every command, stop included.
_out="$(probe STUB_TLS=1 STUB_STATE=database_ready -- 'personal_recover_slow_first_boot')"
check "database answers, launcher already says database_ready -> success" 0 "$(rc_of "$_out")"
case "$(cat "$TMP/calls")" in *deploy*) check "  ...and no deploy over the running database" "no deploy" "deploy";; *) check "  ...and no deploy over the running database" "no deploy" "no deploy";; esac
_out="$(probe STUB_TLS=1 STUB_STATE=deployment_failed -- 'personal_recover_slow_first_boot')"
check "database answers, launcher still says deployment_failed -> reconciled" 0 "$(rc_of "$_out")"
contains "  ...by the launcher's deploy" "RUN exasol-stub deploy" "$(cat "$TMP/calls")"

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

echo "personal_container_error asks the engine the deployment runs on"
# A stub docker on a PATH with nothing else on it: answers --version / info
# from DOCKER_VERSION_TEXT and DOCKER_INFO, ps and inspect from DOCKER_PS / DOCKER_ERR.
mkdir -p "$TMP/eng-dock"
cat > "$TMP/eng-dock/docker" <<'DOCK'
#!/bin/sh
case "$1" in
    --version) printf '%s\n' "${DOCKER_VERSION_TEXT:-Docker version 29.0.1, build abc}" ;;
    info) [ -n "${DOCKER_INFO:-}" ] || exit 1; printf '%s\n' "$DOCKER_INFO" ;;
    ps) printf '%s\n' "${DOCKER_PS:-}" ;;
    inspect) printf '%s\n' "${DOCKER_ERR:-}" ;;
    *) exit 1 ;;
esac
DOCK
chmod +x "$TMP/eng-dock/docker"
export DOCKER_INFO="linux 29.0.1" DOCKER_PS="exasol-db-abc created" DOCKER_ERR="docker: Error response from daemon: port is already allocated"
_out="$(probe PATH="$TMP/eng-dock:/usr/bin:/bin" -- \
    ". '$ROOT/setup/lib/detect.sh'; detect_os(){ printf linux; }; EXAKIT_PERSONAL_ENGINE=docker; personal_container_error" | sed '$d')"
check "a Docker deployment (this run's engine) is asked of Docker" "$DOCKER_ERR" "$_out"
_out="$(probe PATH="$TMP/eng-dock:/usr/bin:/bin" -- \
    ". '$ROOT/setup/lib/detect.sh'; detect_os(){ printf linux; }; manifest_get(){ [ \"\$1\" = runtime.engine ] && printf docker; }; personal_container_error" | sed '$d')"
check "...and so is one the record names as Docker" "$DOCKER_ERR" "$_out"
unset DOCKER_INFO DOCKER_PS DOCKER_ERR

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
# The kit's own database is started without a question (the one-question
# design): the old "keep its data?" question is gone.
contains "a deployment that ever answered keeps the old ladder" "INFO An Exasol deployment was found, not running." "$_out"
case "$_out" in *"keep its data"*) check "  ...without the keep-its-data question" no yes ;; *) check "  ...without the keep-its-data question" no no ;; esac
contains "  ...whose DELETE still defaults to no" "ASK DELETE the stopped deployment and its data, and deploy a fresh one? This cannot be undone. [n]" "$_out"
case "$(cat "$TMP/calls")" in *destroy*) check "  ...and deletes nothing unasked" none destroy ;; *) check "  ...and deletes nothing unasked" none none ;; esac
_out="$(_dl STUB_PENDING=1 EXAKIT_REUSE_DB=1)"
case "$_out" in *"never started"*) check "EXAKIT_REUSE_DB=1 keeps the old ladder" ladder never ;; *) check "EXAKIT_REUSE_DB=1 keeps the old ladder" ladder ladder ;; esac

echo "exakit status: a deployment the launcher records as failed says why, beside the unchanged word"
# Up to the next function, not the first column-0 brace: the embedded Python closes a dict with one.
_st_sh="$(awk '/^cmd_status\(\)/ {on=1; print; next} on && /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ {exit} on' "$ROOT/setup/exakit")"
contains "sh asks the launcher only for a stopped personal deployment" '[ "$_type" = "personal" ] && [ "$_cs_db" = "stopped" ]' "$_st_sh"
contains "  ...names the container's error" 'personal_container_error' "$_st_sh"
contains "  ...in the JSON hint, keeping exakit start as the remedy" "failed_detail + \" - exakit start retries the launcher's deploy\"" "$_st_sh"
contains "  ...and on the screen" 'not reachable — %s' "$(cat "$ROOT/setup/exakit")"
_st_ps="$(sed -n '/^function Invoke-CmdStatus/,/^}/p' "$ROOT/setup/exakit.ps1")"
contains "the Windows twin does the same" 'if ($type -eq "personal" -and "$status" -eq "stopped")' "$_st_ps"
contains "  ...with the container's error" 'Get-PersonalContainerError' "$_st_ps"
echo "_personal_runner_of_this_deployment: a deploy dir that proves everything proves nothing"
# lsof stubbed: the "runner" has its cwd and files in $LSOF_PATHS.
PRD_HOME="$TMP/prdhome"; PRD_DEPLOY="$TMP/prddeploy/default"; mkdir -p "$PRD_HOME" "$PRD_DEPLOY" "$TMP/prddeploy/default2"
prd() { # prd <deploy-dir> <path the process has open>
    rc_of "$(probe STUB_DEPLOY_DIR="$1" HOME="$PRD_HOME" LSOF_PATHS="$2" -- 'lsof(){ printf "n%s\n" "$LSOF_PATHS"; }; _personal_runner_of_this_deployment 4242')"
}
check "the deploy dir itself -> proven" 0 "$(prd "$PRD_DEPLOY" "$PRD_DEPLOY")"
check "a file below it -> proven" 0 "$(prd "$PRD_DEPLOY/" "$PRD_DEPLOY/disk.img")"
check "a sibling sharing the prefix -> not proven" 1 "$(prd "$PRD_DEPLOY" "${PRD_DEPLOY}2/disk.img")"
check "deploy dir / -> refused" 1 "$(prd "/" "/usr/lib/x")"
check "deploy dir // -> refused" 1 "$(prd "//" "/usr/lib/x")"
check "deploy dir = HOME -> refused" 1 "$(prd "$PRD_HOME" "$PRD_HOME/.zshrc")"
check "deploy dir = HOME/ -> refused" 1 "$(prd "$PRD_HOME/" "$PRD_HOME/.zshrc")"
# A deploy dir that is a symlink: the "/" and HOME refusals are reached only
# after pwd -P resolves it (a plain "/" is refused earlier, as empty).
ln -s / "$TMP/rootlink"; ln -s "$PRD_HOME" "$TMP/homelink"
check "deploy dir = a symlink to / -> refused" 1 "$(prd "$TMP/rootlink" "/usr/lib/x")"
check "deploy dir = a symlink to /, process cwd / -> refused" 1 "$(prd "$TMP/rootlink" "/")"
check "deploy dir = a symlink to HOME -> refused" 1 "$(prd "$TMP/homelink" "$PRD_HOME/.zshrc")"
check "deploy dir = an ancestor of HOME -> refused" 1 "$(prd "$TMP" "$PRD_HOME/.zshrc")"
check "deploy dir = an ancestor of HOME/ -> refused" 1 "$(prd "$TMP/" "$PRD_HOME/.zshrc")"
# A mixed-case HOME on a case-insensitive APFS volume: bash 3.2's pwd -P keeps
# the case as typed, so a case-variant of HOME must still be refused.
MIX_HOME="$TMP/MixHome"; mkdir -p "$MIX_HOME"
if [ "$(uname -s)" = "Darwin" ] && [ -d "$TMP/mixhome" ]; then
    check "deploy dir = HOME in other case (macOS) -> refused" 1 \
        "$(rc_of "$(probe STUB_DEPLOY_DIR="$TMP/mixhome" HOME="$MIX_HOME" LSOF_PATHS="$TMP/mixhome/.zshrc" -- 'lsof(){ printf "n%s\n" "$LSOF_PATHS"; }; _personal_runner_of_this_deployment 4242')")"
    check "deploy dir = an ancestor of HOME in other case (macOS) -> refused" 1 \
        "$(rc_of "$(probe STUB_DEPLOY_DIR="$(printf '%s' "$TMP" | tr '[:lower:]' '[:upper:]')" HOME="$MIX_HOME" LSOF_PATHS="$(printf '%s' "$TMP" | tr '[:lower:]' '[:upper:]')/MixHome/.zshrc" -- 'lsof(){ printf "n%s\n" "$LSOF_PATHS"; }; _personal_runner_of_this_deployment 4242')")"
else
    echo "  skip mixed-case HOME: not a case-insensitive macOS volume"
fi
check "deploy dir empty -> refused" 1 "$(rc_of "$(probe STUB_DEPLOY_DIR= HOME="$PRD_HOME" -- 'EXAKIT_PERSONAL_DEPLOY_DIR=; lsof(){ printf "n/x\n"; }; _personal_runner_of_this_deployment 4242')")"

echo "personal_stop_runner_of_failed_deployment: no KILL for a pid that is no longer proven"
# A process that ignores TERM. It was proven when the stop began; by the KILL
# it no longer is (another start's runner, or a reused pid). It is not forced.
( trap '' TERM; exec sleep 30 ) & _tpid=$!; echo "$_tpid" >> "$CHILD_PIDS"
_out="$(probe TPID="$_tpid" EXAKIT_PERSONAL_RUNNER_STOP_WAIT=1 -- '_personal_port_held_by_own_runner() { _ppo_pids="$TPID"; }; _personal_is_own_runner_pid() { return 1; }; personal_launcher_cache_dir() { echo /nonexistent-cache; }; personal_db_port_pids() { echo "$TPID"; }; personal_stop_runner_of_failed_deployment')"
contains "a pid no longer proven is named, not forced" "is no longer proven to be this deployment's runner - it was not forced" "$_out"
check    "  ...and it is still alive" 0 "$(kill -0 "$_tpid" 2>/dev/null; echo $?)"
# No launcher cache to prove against: refused, even if the identity check would pass.
_out="$(probe TPID="$_tpid" EXAKIT_PERSONAL_RUNNER_STOP_WAIT=1 -- '_personal_port_held_by_own_runner() { _ppo_pids="$TPID"; }; _personal_is_own_runner_pid() { return 0; }; personal_launcher_cache_dir() { :; }; personal_db_port_pids() { :; }; personal_stop_runner_of_failed_deployment')"
contains "an empty launcher cache is not forced" "it was not forced" "$_out"
check    "  ...and it is still alive" 0 "$(kill -0 "$_tpid" 2>/dev/null; echo $?)"
# A proven runner that already let go of the port but ignores TERM: forced, so
# the deploy that follows does not meet its VM.
( trap '' TERM; exec sleep 30 ) & _tpid2=$!; echo "$_tpid2" >> "$CHILD_PIDS"
_out="$(probe TPID="$_tpid2" EXAKIT_PERSONAL_RUNNER_STOP_WAIT=1 -- '_personal_port_held_by_own_runner() { _ppo_pids="$TPID"; }; _personal_is_own_runner_pid() { return 0; }; personal_launcher_cache_dir() { echo /nonexistent-cache; }; personal_db_port_pids() { :; }; personal_stop_runner_of_failed_deployment')"
contains "a proven runner off the port is forced" "did not exit within 1s - forcing it" "$_out"
_w=0; while kill -0 "$_tpid2" 2>/dev/null && [ "$_w" -lt 20 ]; do sleep 0.1; _w=$((_w + 1)); done
check    "  ...and it is gone" 1 "$(kill -0 "$_tpid2" 2>/dev/null; echo $?)"
# The same process still proven (and on the port): forced, as before.
_out="$(probe TPID="$_tpid" EXAKIT_PERSONAL_RUNNER_STOP_WAIT=1 -- '_personal_port_held_by_own_runner() { _ppo_pids="$TPID"; }; _personal_is_own_runner_pid() { return 0; }; personal_launcher_cache_dir() { echo /nonexistent-cache; }; personal_db_port_pids() { kill -0 "$TPID" 2>/dev/null && echo "$TPID"; }; personal_stop_runner_of_failed_deployment')"
contains "a pid still proven is forced" "did not exit within 1s - forcing it" "$_out"
_w=0; while kill -0 "$_tpid" 2>/dev/null && [ "$_w" -lt 20 ]; do sleep 0.1; _w=$((_w + 1)); done
check    "  ...and it is gone" 1 "$(kill -0 "$_tpid" 2>/dev/null; echo $?)"

echo "personal_start: deployment_failed while the kit's own runner still runs the VM"
# What an older kit left behind on a user's Mac: the launcher records
# deployment_failed, its runner (executed from the launcher's cache) still
# runs the VM and listens on the port, and the launcher answers every command
# with "VM is already running". The runner is stopped, then deploy runs once.
RHOME="$TMP/home"
case "$(uname -s)" in
    Darwin) RCACHE="$RHOME/Library/Caches/.exasol" ;;
    *)      RCACHE="$RHOME/.cache/.exasol" ;;
esac
RDIR="$RCACHE/personal/runtime-artifacts/exasol-local-runner/darwin/arm64/abc123/unpack"
# The runner works in its deployment's directory: that is how the kit proves
# a runner is THIS deployment's, not another deployment's from the same cache.
RDEPLOY="$TMP/deployments/default"
ODEPLOY="$TMP/deployments/other"
mkdir -p "$RDIR" "$TMP/elsewhere" "$RDEPLOY" "$ODEPLOY"
cp "$TMP/tls_server.py" "$RDIR/launcher"
cp "$TMP/tls_server.py" "$TMP/elsewhere/exasol-local-runner-copy"
start_listener() { # start_listener <script> <port> [cwd] -> pid, once the port is held
    (cd "${3:-$TMP}" && exec python3 "$1" "$2" "$TMP/cert.pem" "$TMP/key.pem") >/dev/null 2>&1 &
    _lp=$!; echo "$_lp" >> "$CHILD_PIDS"
    _w=0; until (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null; do _w=$((_w + 1)); [ "$_w" -ge 40 ] && break; sleep 0.25; done
    echo "$_lp"
}
alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }
if command -v lsof >/dev/null 2>&1; then
    RUN_PORT="$(pick_port $((CLOSED_PORT + 20)))"
    _rpid="$(start_listener "$RDIR/launcher" "$RUN_PORT" "$RDEPLOY")"
    _hint_own="$(probe STUB_REAL_PIDS=1 STUB_DEPLOY_DIR="$RDEPLOY" HOME="$RHOME" XDG_CACHE_HOME= STUB_PORT="$RUN_PORT" -- 'personal_foreign_db_hint')"
    contains "the kit's own runner on the port is named as ours" "own Exasol database process (pid $_rpid)" "$_hint_own"
    case "$_hint_own" in *"did not deploy"*) check "  ...not as a foreign database" "not foreign" "foreign" ;; *) check "  ...not as a foreign database" "not foreign" "not foreign" ;; esac
    _out="$(probe STUB_REAL_PIDS=1 STUB_DEPLOY_DIR="$RDEPLOY" HOME="$RHOME" XDG_CACHE_HOME= STUB_VM_PID="$_rpid" STUB_STATE=deployment_failed STUB_PORT="$RUN_PORT" EXAKIT_PERSONAL_RUNNER_STOP_WAIT=10 -- 'personal_start')"
    check "own runner + deployment_failed -> exit 0" 0 "$(rc_of "$_out")"
    contains "  ...says why it stops the VM" "but it is still running. Restarting it cleanly" "$_out"
    contains "  ...the runner was signalled" "KILL -TERM $_rpid" "$(cat "$TMP/calls")"
    check "  ...the runner is gone" no "$(alive "$_rpid")"
    check "  ...deploy ran exactly once" 1 "$(grep -c 'RUN exasol-stub deploy' "$TMP/calls")"
    _kl="$(sed -n '/KILL -TERM/=' "$TMP/calls" | head -1)"; _dl="$(sed -n '/RUN exasol-stub deploy/=' "$TMP/calls" | head -1)"
    check "  ...stop before deploy" yes "$([ -n "$_kl" ] && [ -n "$_dl" ] && [ "$_kl" -lt "$_dl" ] && echo yes || echo "no ($(tr '\n' ';' < "$TMP/calls"))")"

    # NEGATIVE: the launcher's own runner, from the launcher's own cache, but
    # working for ANOTHER deployment (its cwd is that deployment's directory).
    # Not provably this deployment's runner - never signalled.
    RUN_PORT4="$(pick_port $((RUN_PORT + 1)))"
    _opid="$(start_listener "$RDIR/launcher" "$RUN_PORT4" "$ODEPLOY")"
    _out="$(probe STUB_REAL_PIDS=1 STUB_DEPLOY_DIR="$RDEPLOY" HOME="$RHOME" XDG_CACHE_HOME= STUB_VM_PID="$_opid" STUB_STATE=deployment_failed STUB_PORT="$RUN_PORT4" -- 'personal_start')"
    check "own-cache runner of another deployment -> old behaviour (dies)" 1 "$(rc_of "$_out")"
    check "  ...it was not killed" yes "$(alive "$_opid")"
    case "$(cat "$TMP/calls")" in *KILL*) check "  ...no signal sent" none sent ;; *) check "  ...no signal sent" none none ;; esac
    check "  ...not named as this kit's runner" 1 "$(rc_of "$(probe STUB_REAL_PIDS=1 STUB_DEPLOY_DIR="$RDEPLOY" HOME="$RHOME" XDG_CACHE_HOME= STUB_PORT="$RUN_PORT4" -- '_personal_port_held_by_own_runner')")"
    kill -9 "$_opid" 2>/dev/null || true

    # NEGATIVE: the same name outside the launcher's cache is not certainly
    # ours - untouched, and the old behaviour (deploy, which fails) stands.
    RUN_PORT2="$(pick_port $((RUN_PORT4 + 1)))"
    _fpid="$(start_listener "$TMP/elsewhere/exasol-local-runner-copy" "$RUN_PORT2" "$RDEPLOY")"
    _out="$(probe STUB_REAL_PIDS=1 STUB_DEPLOY_DIR="$RDEPLOY" HOME="$RHOME" XDG_CACHE_HOME= STUB_VM_PID="$_fpid" STUB_STATE=deployment_failed STUB_PORT="$RUN_PORT2" -- 'personal_start')"
    check "runner name outside the cache -> old behaviour (dies)" 1 "$(rc_of "$_out")"
    check "  ...it was not killed" yes "$(alive "$_fpid")"
    case "$(cat "$TMP/calls")" in *KILL*) check "  ...no signal sent" none sent ;; *) check "  ...no signal sent" none none ;; esac
    contains "  ...deploy still tried" "RUN exasol-stub deploy" "$(cat "$TMP/calls")"
    # NEGATIVE: a plain foreign listener is never touched.
    RUN_PORT3="$(pick_port $((RUN_PORT2 + 1)))"
    _xpid="$(start_listener "$TMP/tls_server.py" "$RUN_PORT3")"
    _out="$(probe STUB_REAL_PIDS=1 HOME="$RHOME" XDG_CACHE_HOME= STUB_VM_PID="$_xpid" STUB_STATE=deployment_failed STUB_PORT="$RUN_PORT3" -- 'personal_start')"
    check "foreign listener -> old behaviour (dies)" 1 "$(rc_of "$_out")"
    check "  ...it was not killed" yes "$(alive "$_xpid")"
    contains "  ...and it is still called foreign" "did not deploy" "$_out"
else
    echo "  (no lsof: runner checks skipped)"
fi

echo "personal_tls_answers: openssl's output decides, not its exit status (pipefail)"
# Stub clients, one per directory so each can be put first on PATH.
_pem='-----BEGIN CERTIFICATE-----\nMIIBstub\n-----END CERTIFICATE-----\n'
_stub() { # _stub <name> <body>
    mkdir -p "$TMP/ssl-$1"
    printf '#!/bin/sh\n%s\n' "$2" > "$TMP/ssl-$1/openssl"
    chmod +x "$TMP/ssl-$1/openssl"
}
_stub cert-exit1  "printf '%b' '$_pem'; exit 1"
_stub empty-exit1 "exit 1"
_stub cert-exit0  "printf '%b' '$_pem'; exit 0"
_stub hang        "exec sleep 30"
# A client that keeps writing after the certificate: `grep -q` stops reading at
# the match and the writer dies of SIGPIPE (141), which pipefail reported as
# a failed probe.
_stub cert-more   "printf '%b' '$_pem'; exec head -c 1000000 /dev/zero"
# The system directories only: probe() word-splits its assignments, so a PATH
# with a space in it (macOS app bundles) cannot pass through, and a Homebrew
# openssl ahead of the stub would answer instead of it.
SYS_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
_tls_stub() { # _tls_stub <stub> -> rc of personal_tls_answers with that openssl first on PATH
    rc_of "$(probe PATH="$TMP/ssl-$1:$SYS_PATH" STUB_REAL_BOUNDED=1 EXAKIT_PERSONAL_PROBE_TIMEOUT=3 STUB_PORT="$CLOSED_PORT" -- 'personal_tls_answers')"
}
check "certificate printed, client exits 1 (LibreSSL) -> answers" 0 "$(_tls_stub cert-exit1)"
check "nothing printed, client exits 1 -> does not"               1 "$(_tls_stub empty-exit1)"
check "certificate printed, client exits 0 -> answers"            0 "$(_tls_stub cert-exit0)"
check "certificate, then more output (SIGPIPE under grep -q) -> answers" 0 "$(_tls_stub cert-more)"
_t0="$(date +%s)"
check "client hangs, prints nothing -> does not"                  1 "$(_tls_stub hang)"
_t1="$(date +%s)"
check "  ...and the bound cut it off (under 15s)" yes "$([ $((_t1 - _t0)) -lt 15 ] && echo yes || echo "no ($((_t1 - _t0))s)")"

# The real thing: macOS's own /usr/bin/openssl against a real s_server. -www
# answers and closes the way a database does, and it is the shape that makes
# LibreSSL's s_client exit 1 after a good handshake.
if [ -x /usr/bin/openssl ]; then
    mkdir -p "$TMP/ssl-system"
    ln -sf /usr/bin/openssl "$TMP/ssl-system/openssl"
    _sys_ver="$(/usr/bin/openssl version 2>/dev/null)"
    SSERVER_PORT="$(pick_port $((CLOSED_PORT + 1)))"
    /usr/bin/openssl s_server -accept "$SSERVER_PORT" -cert "$TMP/cert.pem" -key "$TMP/key.pem" -www \
        </dev/null >/dev/null 2>&1 &
    CHILDREN="$CHILDREN $!"
    _w=0
    until (exec 3<>"/dev/tcp/127.0.0.1/$SSERVER_PORT") 2>/dev/null; do
        _w=$((_w + 1)); [ "$_w" -ge 20 ] && break; sleep 0.25
    done
    _sys_raw="$(/usr/bin/openssl s_client -connect "127.0.0.1:$SSERVER_PORT" </dev/null >/dev/null 2>&1; echo $?)"
    echo "  (system client: $_sys_ver; its own s_client exit against s_server -www: $_sys_raw)"
    check "system openssl, s_server answers -> answers" 0 \
        "$(rc_of "$(probe PATH="$TMP/ssl-system:$SYS_PATH" STUB_REAL_BOUNDED=1 EXAKIT_PERSONAL_PROBE_TIMEOUT=5 STUB_PORT="$SSERVER_PORT" -- 'personal_tls_answers')")"
    check "system openssl, closed port -> does not" 1 \
        "$(rc_of "$(probe PATH="$TMP/ssl-system:$SYS_PATH" STUB_REAL_BOUNDED=1 EXAKIT_PERSONAL_PROBE_TIMEOUT=5 STUB_PORT="$CLOSED_PORT" -- 'personal_tls_answers')")"
else
    echo "  (no /usr/bin/openssl: system-client checks skipped)"
fi

echo ""
echo "personal-readiness.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
