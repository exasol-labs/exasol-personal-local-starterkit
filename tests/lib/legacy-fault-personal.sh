# legacy-fault-personal.sh — the Exasol Personal runtime, as `exakit migrate
# docker-nano` sees it, with faults on request.
#
# Sourced (not executed) into a scenario by tests/legacy-crossing-resilience.sh,
# in place of setup/lib/runtime-personal.sh: the migrate road stops and starts
# the deployment around the copy, and these five functions are everything it
# calls. Knobs are files in $EXAKIT_FAULT_DIR, like the other two stubs; every
# stop, start and wait is appended to personal.calls, in order.
#
#   personal.port      the deployment's SQL port                       (8563)
#   personal.state     running | stopped                               (running)
#   personal.stop_rc   exit code of personal_stop                      (0)
#   personal.start_rc  exit code of personal_start                     (0)
#   personal.port_busy 1: the port stays held after a stop             (0)
#   personal.reap_frees 1: the orphan reaper frees it                  (0)
#
# A successful stop or start UPDATES personal.state, the way the real
# deployment's state would change. port_in_use is redefined here too, so the
# port question is answered by the knob and never by the developer's machine.
personal_db_port() {
    if [ -f "$EXAKIT_FAULT_DIR/personal.port" ]; then cat "$EXAKIT_FAULT_DIR/personal.port"; else printf '8563'; fi
}
personal_deployment_running() {
    _pfs="running"
    [ -f "$EXAKIT_FAULT_DIR/personal.state" ] && _pfs="$(cat "$EXAKIT_FAULT_DIR/personal.state")"
    [ "$_pfs" = "running" ]
}
personal_stop() {
    printf 'stop\n' >> "$EXAKIT_FAULT_DIR/personal.calls"
    _pfr=0; [ -f "$EXAKIT_FAULT_DIR/personal.stop_rc" ] && _pfr="$(cat "$EXAKIT_FAULT_DIR/personal.stop_rc")"
    [ "$_pfr" = 0 ] || return 1
    printf 'stopped' > "$EXAKIT_FAULT_DIR/personal.state"
}
personal_start() {
    printf 'start\n' >> "$EXAKIT_FAULT_DIR/personal.calls"
    _pfr=0; [ -f "$EXAKIT_FAULT_DIR/personal.start_rc" ] && _pfr="$(cat "$EXAKIT_FAULT_DIR/personal.start_rc")"
    [ "$_pfr" = 0 ] || return 1
    printf 'running' > "$EXAKIT_FAULT_DIR/personal.state"
}
personal_wait_ready() {
    printf 'wait\n' >> "$EXAKIT_FAULT_DIR/personal.calls"
    return 0
}
port_in_use() {
    [ -f "$EXAKIT_FAULT_DIR/personal.port_busy" ] && [ "$(cat "$EXAKIT_FAULT_DIR/personal.port_busy")" = 1 ]
}
personal_reap_orphan_daemon() {
    printf 'reap\n' >> "$EXAKIT_FAULT_DIR/personal.calls"
    if [ -f "$EXAKIT_FAULT_DIR/personal.reap_frees" ] && [ "$(cat "$EXAKIT_FAULT_DIR/personal.reap_frees")" = 1 ]; then
        printf '0' > "$EXAKIT_FAULT_DIR/personal.port_busy"
    fi
    return 0
}
personal_port_holder_hint() { printf ' (pid 4242: something-else)'; }
