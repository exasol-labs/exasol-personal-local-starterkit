#!/usr/bin/env bash
# windows-rootful-podman.sh — the check that stopped every new Windows install,
# and the exit that did not exit.
#
# Podman Desktop creates the default machine ROOTFUL. A rootful container
# publishes its port as an iptables rule inside the machine - no listener - so
# nothing forwards it to Windows, the database answers only inside the machine,
# and every start waits 150 s for a port that will never open. The check that
# catches this was right to exist and wrong to stop there: it printed three
# commands and gave up, which is the entire experience of this product for
# anyone whose machine Podman Desktop had already made.
#
# Source checks, not behaviour: the machine and the podman that owns it are
# Windows-only, and this suite runs where neither exists.
#
#   bash tests/windows-rootful-podman.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 = $3"
          else FAIL=$((FAIL+1)); echo "  FAIL $1: expected $2, got $3"; fi; }
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }

RTP="$(cat "$ROOT/setup/lib/runtime-personal.ps1")"
WIN="$(cat "$ROOT/setup/setup-windows.ps1")"
HEAL="$(printf '%s\n' "$RTP" | sed -n '/^function Repair-PersonalRootfulPodmanMachine/,/^}$/p')"
GATE="$(printf '%s\n' "$RTP" | sed -n '/\$podmanCmd = Get-Command podman/,/Compatibility check passed (windows/p')"

echo "the rootful machine is offered a fix, not three commands:"
has "there is a repair at all"            "function Repair-PersonalRootfulPodmanMachine" "$RTP"
has "the gate calls it"                   "if (Repair-PersonalRootfulPodmanMachine)" "$GATE"
# The order that matters: repair, ASK AGAIN, and only then refuse. A repair that
# reported success but did not take must not be trusted into the install.
has "...then re-reads the machine"        '"machine", "inspect", "--format", "{{.Rootful}}"' "$GATE"
has "...and still refuses if it is rootful" "Fail " "$GATE"
# The manual commands stay for the run where the fix is declined or fails.
has "the manual escape is still printed"  "podman machine set --rootful=false" "$GATE"
has "...and so is the force flag"         "EXAKIT_FORCE=1" "$GATE"

echo
echo "it is not ours to change quietly:"
has "a terminal is asked"                 "Confirm-ExakitPrompt" "$HEAL"
has "...and an unattended run must opt in" "EXAKIT_PODMAN_SELFHEAL" "$HEAL"
# The same opt-in as the Linux rootless fix: one variable for "you may change
# system state to make Podman work", not one per platform.
has "the opt-in matches the Linux one"    "EXAKIT_PODMAN_SELFHEAL" \
    "$(cat "$ROOT/setup/lib/runtime-personal.sh")"
# The consequence a reader has to hear BEFORE, not discover after: the machine
# is shared host-wide and rootful containers go out of view.
has "the prompt names the restart"        "stops and restarts the machine" "$HEAL"
has "...and the containers that vanish"   "will not be visible afterwards" "$HEAL"
lacks "nothing is deleted to achieve it"  "machine rm" "$HEAL"

echo
echo "the three commands are run in the only order that works:"
# set refuses on a running machine, so stop must come first; start last or the
# install talks to a machine that is down.
_stop=$(printf '%s\n' "$HEAL" | grep -n '"machine", "stop"' | cut -d: -f1 | head -1)
_set=$(printf '%s\n'  "$HEAL" | grep -n '"machine" "set" "--rootful=false"' | cut -d: -f1 | head -1)
_start=$(printf '%s\n' "$HEAL" | grep -n '"machine" "start"' | cut -d: -f1 | head -1)
check "stop comes before set"  "yes" "$([ -n "$_stop" ] && [ -n "$_set" ] && [ "$_stop" -lt "$_set" ] && echo yes || echo no)"
check "set comes before start" "yes" "$([ -n "$_set" ] && [ -n "$_start" ] && [ "$_set" -lt "$_start" ] && echo yes || echo no)"
has "a set that fails is reported"   "podman machine set exited" "$HEAL"
has "a start that fails says which half took" "set to rootless but would not start" "$HEAL"

echo
echo "and the run actually ends:"
# The spinner runs in its own runspace, and a live runspace keeps Windows
# PowerShell 5.1 from terminating - so a run that ended while one was spinning
# printed its last line and sat there, which reads as a hang, not a finish.
_finally="$(printf '%s\n' "$WIN" | sed -n '/^} finally {/,/^}$/p')"
has "the animation is stopped on every way out" "Stop-ExakitAnimation" "$_finally"
has "...before the lock is released"            "Exit-ExakitInstallLock" "$_finally"

echo
echo "windows-rootful-podman.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
