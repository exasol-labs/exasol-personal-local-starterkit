#!/bin/sh
# legacy-fault-engine.sh — a container engine that misbehaves on request.
#
# Installed into a sandbox as `fakeengine` (the name the fixture manifest
# records as runtime.engine) by tests/legacy-crossing-resilience.sh. It answers
# the four verbs the crossing may use — version, inspect, start, stop — and
# takes its behaviour from plain files in $EXAKIT_FAULT_DIR, so a scenario can
# make it hang, refuse, or lose the container between two calls without a
# second stub. Every call is appended to engine.calls, argv verbatim: that log
# is what the suite reads to prove which verbs were ever issued.
#
#   engine.state         running | stopped | absent | down | unknown | hang | noformat   (running)
#                        (noformat: `inspect -f` fails, plain `inspect` works -
#                        an engine too old for the template flag)
#   engine.start_rc      exit code of `start`                          (0)
#   engine.stop_rc       exit code of `stop`                           (0)
#   engine.hang_seconds  how long `hang` sleeps                        (30)
#
# A successful start or stop UPDATES engine.state, the way a real engine's
# container would change state - so a scenario that starts a stopped
# container sees it running on the next inspect.

_dir="${EXAKIT_FAULT_DIR:?EXAKIT_FAULT_DIR must point at the scenario control directory}"
_read() { # _read <file> <default>
    if [ -f "$_dir/$1" ]; then cat "$_dir/$1"; else printf '%s' "$2"; fi
}
printf '%s\n' "$*" >> "$_dir/engine.calls"

_state="$(_read engine.state running)"
case "$1 $2" in
    # down: the CLI is there, the daemon or machine is not (Docker Desktop stopped).
    "version --format")
        [ "$_state" = down ] && exit 1
        printf '1.0\n'; exit 0 ;;
    "container inspect")
        case "$_state" in
            # exec, so the hang IS this process - the shape of a wedged engine
            # CLI, and the one the kit's bounded runner can end. A child sleep
            # would outlive the stub and hold the caller's pipe open for the
            # whole hang; see the note on grandchildren in the resilience suite.
            hang)    exec sleep "$(_read engine.hang_seconds 30)" ;;
            absent|down)  exit 1 ;;
            noformat) case "$*" in *"-f "*) exit 1 ;; esac; exit 0 ;;
        esac
        # `inspect -f {{.State.Running}} NAME` wants a boolean; a bare
        # `inspect NAME` only wants to know the container exists.
        case "$*" in
            *"-f "*)
                case "$_state" in
                    running) printf 'true\n' ;;
                    stopped) printf 'false\n' ;;
                    *)       printf 'weird\n' ;;
                esac ;;
        esac
        exit 0 ;;
    "start "*)
        _rc="$(_read engine.start_rc 0)"
        [ "$_rc" = 0 ] && printf 'running' > "$_dir/engine.state"
        exit "$_rc" ;;
    "stop "*)
        _rc="$(_read engine.stop_rc 0)"
        [ "$_rc" = 0 ] && printf 'stopped' > "$_dir/engine.state"
        exit "$_rc" ;;
esac
# Anything else - rm, volume, destroy - is logged above and answered politely.
# The suite's invariants fail the run if such a line ever appears.
exit 0
