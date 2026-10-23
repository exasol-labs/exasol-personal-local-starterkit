#!/usr/bin/env bash
# windows-rootful-podman.sh — rootful and rootless Podman machines are BOTH
# supported on Windows, and the machine is changed only on evidence, with
# consent.
#
# The kit used to refuse a rootful default machine at the requirements gate and
# offer to make it rootless, on the theory that a rootful machine never forwards
# its ports to Windows. That holds only for Podman 6.0.0 to 6.1.0 (a regression
# fixed in 6.1.1); on 5.x a rootful port is a real listener that WSL's relay
# forwards. And where WSL 2.9+ gives rootless Podman no pids controller, rootful
# is the one mode in which the database starts at all - so the refusal blocked
# the very machine that worked. `exakit preflight` ran the same gate, so a
# check-only command could restart the machine.
#
# What this pins:
#   - the requirements gate (and so preflight) REPORTS the mode and never
#     refuses, switches, stops or starts the machine, and EXAKIT_FORCE is about
#     RAM and disk only;
#   - the rootless switch exists only in the unreachable-database diagnosis,
#     after evidence (a running container) and behind the consent helper;
#   - the switch helper runs stop, set, start in the only order that works;
#   - the run still ends (the spinner runspace is stopped on every way out).
#
# Source checks: the machine and the podman that owns it are Windows-only. The
# behaviour is exercised against a stubbed podman in tests/runtime-personal-ps.ps1.
#
#   bash tests/windows-rootful-podman.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 = $3"
          else FAIL=$((FAIL+1)); echo "  FAIL $1: expected $2, got $3"; fi; }
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }
fn()    { _fn_range="/^function $1 {/,/^}\$/p"; printf '%s\n' "$RTP" | sed -n "$_fn_range"; }

RTP="$(cat "$ROOT/setup/lib/runtime-personal.ps1")"
WIN="$(cat "$ROOT/setup/setup-windows.ps1")"
XK="$(cat "$ROOT/setup/exakit.ps1")"
GATE="$(fn Test-PersonalRequirements)"
SWITCH="$(fn Set-PersonalPodmanRootful)"
CONSENT="$(fn Confirm-PersonalPodmanSelfHeal)"
UNREACH="$(fn Resolve-PersonalUnreachableDatabase)"

echo "the requirements gate reports the mode and refuses neither:"
has   "the gate asks which mode the machine is in"   "Get-PersonalPodmanMode" "$GATE"
has   "...and says it"                               'Podman machine $mode' "$GATE"
lacks "it no longer fails on a rootful machine"      "rootful, and a database published" "$GATE"
lacks "...nor offers to switch it"                   "Set-PersonalPodmanRootful" "$GATE"
lacks "...nor asks for consent to change anything"   "EXAKIT_PODMAN_SELFHEAL" "$GATE"
lacks "...nor stops, sets or starts the machine"     '"machine", "stop"' "$GATE"
lacks "...nor runs anything logged"                  "Invoke-ExakitLogged" "$GATE"
check "EXAKIT_FORCE is about RAM and disk only"      "1" "$(printf '%s\n' "$GATE" | grep -c 'EXAKIT_FORCE -ne "1"')"
lacks "the old repair is gone"                       "Repair-PersonalRootfulPodmanMachine" "$RTP"
lacks "nothing claims rootful cannot be reached"     "is not reachable from Windows (the port is an iptables rule" "$RTP"

echo
echo "preflight is read-only:"
_pre="$(printf '%s\n' "$XK" | sed -n '/^        "preflight"    {/,/^        }/p')"
has   "preflight runs the gate"                      "Test-PersonalRequirements" "$_pre"
lacks "...and nothing else that could change the machine" "Podman" "$_pre"

echo
echo "the rootless switch is offered only on evidence, with consent:"
check "one caller switches a machine to rootless"   "1" "$(printf '%s\n' "$RTP" | grep -c 'Set-PersonalPodmanRootful $false')"
has   "...the unreachable-database diagnosis"        'Set-PersonalPodmanRootful $false' "$UNREACH"
_ev=$(printf '%s\n' "$UNREACH" | grep -n 'State -eq "running"' | head -1 | cut -d: -f1)
_ask=$(printf '%s\n' "$UNREACH" | grep -n 'Confirm-PersonalPodmanSelfHeal' | head -1 | cut -d: -f1)
_do=$(printf '%s\n' "$UNREACH" | grep -n 'Set-PersonalPodmanRootful $false' | head -1 | cut -d: -f1)
check "a running container is the evidence, asked first" "yes" "$([ -n "$_ev" ] && [ -n "$_ask" ] && [ "$_ev" -lt "$_ask" ] && echo yes || echo no)"
check "...then consent, then the switch"             "yes" "$([ -n "$_ask" ] && [ -n "$_do" ] && [ "$_ask" -lt "$_do" ] && echo yes || echo no)"
has   "the known regression is named by version"     "Test-PersonalPodmanForwardingRegression" "$UNREACH"
has   "...with the fix that works"                   "podman machine rm; podman machine init" "$UNREACH"
has   "a rootless switch that meets no pids goes back" 'Set-PersonalPodmanRootful $true' "$UNREACH"

echo
echo "it is not ours to change quietly:"
has   "a terminal is asked"                          'Confirm-ExakitEnvPrompt "EXAKIT_PODMAN_SELFHEAL"' "$CONSENT"
has   "...and an unattended run must opt in"         'EXAKIT_PODMAN_SELFHEAL=1' "$CONSENT"
has   "the opt-in matches the Linux one"             "EXAKIT_PODMAN_SELFHEAL" "$(cat "$ROOT/setup/lib/runtime-personal.sh")"
# The switch helper asks nothing itself, so every function that calls it must
# ask first: the two that switch on evidence, each before its first switch.
_callers="$(printf '%s\n' "$RTP" | grep -v '^function Set-PersonalPodmanRootful' | grep -v '^ *#' | awk '/^function /{f=$2} /Set-PersonalPodmanRootful/{print f}' | sort -u | tr '\n' ' ')"
check "only the two evidence-driven checks switch"   "Resolve-PersonalUnreachableDatabase Test-PersonalPodmanPids " "$_callers"
for _f in Resolve-PersonalUnreachableDatabase Test-PersonalPodmanPids; do
    _b="$(fn "$_f")"
    _a=$(printf '%s\n' "$_b" | grep -n 'Confirm-PersonalPodmanSelfHeal' | head -1 | cut -d: -f1)
    _s=$(printf '%s\n' "$_b" | grep -n 'Set-PersonalPodmanRootful' | head -1 | cut -d: -f1)
    check "$_f asks before it switches" "yes" "$([ -n "$_a" ] && [ -n "$_s" ] && [ "$_a" -lt "$_s" ] && echo yes || echo no)"
done
has   "the rootful question names the restart"       "stops and restarts the machine" "$(fn Test-PersonalPodmanPids)"
has   "...and the storage that goes out of view"     "not visible in rootful mode" "$(fn Test-PersonalPodmanPids)"
lacks "nothing is deleted to achieve it"             "machine rm" "$SWITCH"

echo
echo "the three commands are run in the only order that works:"
# set refuses on a running machine, so stop must come first; start last or the
# install talks to a machine that is down.
_stop=$(printf '%s\n' "$SWITCH" | grep -n '"machine", "stop"' | cut -d: -f1 | head -1)
_set=$(printf '%s\n'  "$SWITCH" | grep -n '"machine" "set" $flag' | cut -d: -f1 | head -1)
_start=$(printf '%s\n' "$SWITCH" | grep -n '"machine" "start"' | cut -d: -f1 | head -1)
check "stop comes before set"  "yes" "$([ -n "$_stop" ] && [ -n "$_set" ] && [ "$_stop" -lt "$_set" ] && echo yes || echo no)"
check "set comes before start" "yes" "$([ -n "$_set" ] && [ -n "$_start" ] && [ "$_set" -lt "$_start" ] && echo yes || echo no)"
has "a set that fails is reported"   "podman machine set exited" "$SWITCH"
has "a start that fails says which half took" 'is set to $mode but would not start' "$SWITCH"

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
