#!/usr/bin/env bash
# windows-rootful-podman.sh — the rootful Podman machine on Windows is a
# remedy, not a check; and the exit that did not exit.
#
# Podman Desktop creates the default machine ROOTFUL. A rootful container
# publishes its port as an iptables rule inside the machine - no listener - so
# nothing forwards it to Windows and the database answers only inside the
# machine. Kit 0.2.4: new Windows users deploy on Docker and Podman is the
# fallback, so the compatibility gate no longer probes, offers to switch or
# warns about the machine. The manual fix is named only where a Podman
# deployment failed or never answered, and never on Docker.
#
# Source checks, not behaviour: the machine and the podman that owns it are
# Windows-only, and this suite runs where neither exists. The hint's engine
# gate is exercised for real in tests/personal-engine-ps.ps1.
#
#   bash tests/windows-rootful-podman.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 = $3"
          else FAIL=$((FAIL+1)); echo "  FAIL $1: expected $2, got $3"; fi; }
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }
# The sed range is assigned first: bash 3.2 mangles a braced range passed
# straight as an argument (tests/bash32-guard.sh).
fn()    { _fn_range="/^function $1 {/,/^}\$/p"; printf '%s\n' "$RTP" | sed -n "$_fn_range"; }

RTP="$(cat "$ROOT/setup/lib/runtime-personal.ps1")"
WIN="$(cat "$ROOT/setup/setup-windows.ps1")"
GATE="$(fn Test-PersonalRequirements)"
HINT="$(fn Show-PersonalPodmanRootfulHint)"
READY="$(fn Wait-PersonalReady)"
ORDEPLOY="$(fn Wait-PersonalReadyOrDeploy)"
DEPLOY="$(fn Install-PersonalDeployment)"
START="$(fn Start-Personal)"
HINT_TEXT="If Podman's default machine is rootful, the database port is not reachable from Windows. Make it rootless: podman machine stop; podman machine set --rootful=false; podman machine start"

echo "the gate has no rootful-machine check:"
lacks "no repair function"                "Repair-PersonalRootfulPodmanMachine" "$RTP"
lacks "the gate reads no machine setting"  "{{.Rootful}}" "$GATE"
lacks "...runs no podman machine command"  '"machine"' "$GATE"
lacks "...and warns about no machine"      "Warn2 " "$GATE"
# The WSL check that shared the gate with it stays.
has "the WSL check is still there"        "Test-PersonalWslPodmanNetworkOk -Quiet" "$GATE"
lacks "the Windows side no longer reads the self-heal opt-in" "EXAKIT_PODMAN_SELFHEAL" "$RTP"
# Its Linux/WSL meaning (the subuid/uidmap fix) is untouched.
has "...the Linux side still does"        "EXAKIT_PODMAN_SELFHEAL" \
    "$(cat "$ROOT/setup/lib/runtime-personal.sh")"

echo
echo "the manual fix is a remedy, on Podman only:"
has "one hint, the three commands"        "$HINT_TEXT" "$HINT"
has "...only on the Podman engine"        'if ($engine -ne "podman") { return }' "$HINT"
lacks "...and it probes nothing"          "podman machine inspect" "$HINT"
lacks "...nor changes anything"           "Invoke-Exakit" "$HINT"
_hits=$(printf '%s\n' "$RTP" | grep -c "podman machine set --rootful=false")
check "the commands are written once"     1 "$_hits"
has "a deploy that failed names it"       "Show-PersonalPodmanRootfulHint" "$DEPLOY"
has "a database that never answered after the deploy retry" "Show-PersonalPodmanRootfulHint" "$ORDEPLOY"
_n=$(printf '%s\n' "$ORDEPLOY" | grep -c "Show-PersonalPodmanRootfulHint")
check "...on both of its failure returns" 2 "$_n"
has "a wait that ran out names it"        "Show-PersonalPodmanRootfulHint" "$READY"
_n=$(printf '%s\n' "$START" | grep -c "Show-PersonalPodmanRootfulHint")
check "a start that failed names it, both generic arms" 2 "$_n"
# Docker never sees it: a Docker start that fails because Docker is down ends
# before any hint, and the hint itself returns for any engine but podman.
_dk=$(printf '%s\n' "$START" | grep -n 'Start Docker Desktop, then: exakit start' | cut -d: -f1 | head -1)
_h1=$(printf '%s\n' "$START" | grep -n 'Show-PersonalPodmanRootfulHint' | cut -d: -f1 | head -1)
check "the Docker-down arm comes first" yes "$([ -n "$_dk" ] && [ -n "$_h1" ] && [ "$_dk" -lt "$_h1" ] && echo yes || echo no)"
# The Podman-missing deploy failure is about installing Podman, not its machine.
_pm=$(printf '%s\n' "$DEPLOY" | sed -n '/Podman is still not installed/,/return/p')
lacks "a Podman-missing failure does not name the machine" "Show-PersonalPodmanRootfulHint" "$_pm"

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
