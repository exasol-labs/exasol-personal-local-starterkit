#!/usr/bin/env bash
# podman-rootless-selfheal.sh — the one place the kit asks to run sudo.
#
# Everything else it installs lives under ~/.local and ~/.exasol-starter-kit,
# which is why it needs no privilege at all. A rootless Podman gap is the
# exception: the sub-id ranges are in /etc/subuid and /etc/subgid and the uidmap
# helper is a system package, so there is no unprivileged fix. Before this, the
# kit printed the command in red and deployed anyway - and the deploy failed
# minutes later inside a container start, naming neither Podman nor the range.
#
# What these checks are really guarding is the CONSENT, not the plumbing: that a
# run with nobody watching never edits /etc on its own, that a declined offer
# changes nothing, and that a fix which did not take is reported as such rather
# than announced as success.
#
#   bash tests/podman-rootless-selfheal.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 = $3"
          else FAIL=$((FAIL+1)); echo "  FAIL $1: expected $2, got $3"; fi; }
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-rootless.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"

# A sudo that records what it was asked to do and never does it.
cat > "$BIN/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SUDO_LOG"
exit "${SUDO_RC:-0}"
STUB
chmod +x "$BIN/sudo"
printf '#!/bin/sh\nexit 0\n' > "$BIN/podman"; chmod +x "$BIN/podman"
printf '#!/bin/sh\nexit 0\n' > "$BIN/apt-get"; chmod +x "$BIN/apt-get"

# heal <gap-kind> <gap-kind-after-fix> [env...] — run the healer with the gap
# stubbed, no terminal attached, and print what reached the screen.
heal() {
    _h_kind="$1"; _h_after="$2"; shift 2
    : > "$WORK/sudo.log"
    env SUDO_LOG="$WORK/sudo.log" PATH="$BIN:$PATH" ROOT="$ROOT" \
        GAP_FIRST="$_h_kind" GAP_AFTER="$_h_after" SEEN_FILE="$WORK/seen" "$@" \
        bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        . "$ROOT/setup/lib/detect.sh" 2>/dev/null
        . "$ROOT/setup/lib/exapump.sh" 2>/dev/null
        . "$ROOT/setup/lib/runtime-personal.sh" 2>/dev/null
        # A FILE, not a variable: every call below happens inside $( ), which
        # is a subshell, so an assignment would never be seen by the next one.
        : > "$SEEN_FILE"
        detect_rootless_podman_gap_kind() {
            if [ ! -s "$SEEN_FILE" ]; then
                printf x > "$SEEN_FILE"
                [ -n "$GAP_FIRST" ] || return 1
                printf "%s\n" "$GAP_FIRST"; return 0
            fi
            [ -n "$GAP_AFTER" ] || return 1
            printf "%s\n" "$GAP_AFTER"
        }
        detect_rootless_podman_gap() { printf "a stubbed reason\n"; }
        personal_heal_rootless_podman' </dev/null 2>&1 | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'
}
sudo_log() { cat "$WORK/sudo.log" 2>/dev/null; }

echo "nothing is changed on a machine nobody is watching:"
# No terminal, no opt-in: the fix is offered, never taken. This is the whole
# point - a scripted install that silently edits /etc is not a self-heal.
OUT="$(heal subid "")"
has   "the gap is named"                  "Rootless Podman is not ready" "$OUT"
has   "...and the opt-in is spelled out"  "EXAKIT_PODMAN_SELFHEAL=1" "$OUT"
has   "...alongside the manual command"   "usermod --add-subuids" "$OUT"
check "sudo was never called"             "" "$(sudo_log)"

echo
echo "an unattended run that opted in is healed:"
OUT="$(heal subid "" EXAKIT_PODMAN_SELFHEAL=1)"
has   "the command is shown before it runs" "Running: sudo usermod" "$OUT"
has   "...and names this user"              "--add-subgids 100000-165535" "$(sudo_log)"
has   "...and reports the machine ready"    "Rootless Podman is ready" "$OUT"

echo
echo "a fix that did not take is not announced as success:"
# usermod can exit 0 and leave the gap - a distribution may manage its ranges
# somewhere else entirely. The verify is the whole reason this is not fire-and-forget.
OUT="$(heal subid subid EXAKIT_PODMAN_SELFHEAL=1)"
has   "the run is honest about it"        "still looks incomplete" "$OUT"
lacks "...and never claims it is ready"   "Rootless Podman is ready" "$OUT"

echo
echo "what cannot be fixed is not attempted:"
# cgroups v2 needs a reboot or a boot flag. No process can grant it, so the
# healer must not reach for sudo to look busy.
OUT="$(heal cgroups cgroups EXAKIT_PODMAN_SELFHEAL=1)"
has   "the reason is still given"         "a stubbed reason" "$OUT"
check "sudo was never called"             "" "$(sudo_log)"

echo
echo "a missing pids controller is named, never 'fixed' with sudo:"
# The container runs with a pids limit; with no pids controller delegated to
# the user (a systemd that delegates none, or WSL 2.9+, which puts the distro
# under a non-systemd cgroup subtree) crun refuses it and it sits in
# "created". No command here can grant the controller, so it is advice only.
OUT="$(heal pids pids EXAKIT_PODMAN_SELFHEAL=1)"
has   "the reason is given"               "a stubbed reason" "$OUT"
check "sudo was never called"             "" "$(sudo_log)"
lacks "...and nothing claims it is ready" "Rootless Podman is ready" "$OUT"

echo
echo "the pids gap is read off podman itself, and only a real list counts:"
PIDBIN="$WORK/pidbin"; mkdir -p "$PIDBIN"
cat > "$PIDBIN/podman" <<'STUB'
#!/bin/sh
[ "$1 $2" = "info --format" ] || exit 0
[ -n "${PODMAN_FAIL:-}" ] && exit 125
printf '%s\n' "$PODMAN_CTL"
STUB
chmod +x "$PIDBIN/podman"
pids_missing() {
    env PATH="$PIDBIN:$PATH" ROOT="$ROOT" "$@" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        . "$ROOT/setup/lib/detect.sh" 2>/dev/null
        _detect_podman_pids_missing && echo missing || echo fine'
}
check "no pids in the list -> missing"      "missing" "$(pids_missing PODMAN_CTL='[cpu io memory]')"
check "an empty list -> missing"            "missing" "$(pids_missing PODMAN_CTL='[]')"
check "pids in the list -> fine"            "fine"    "$(pids_missing PODMAN_CTL='[cpuset cpu io memory pids]')"
check "podman cannot answer -> not evidence" "fine"   "$(pids_missing PODMAN_FAIL=1)"
check "an unknown field -> not evidence"    "fine"    "$(pids_missing PODMAN_CTL='<no value>')"
DETECT="$(cat "$ROOT/setup/lib/detect.sh")"
has "the gap kind can be pids"              "printf 'pids\\n'" "$(sed -n '/^detect_rootless_podman_gap_kind()/,/^}/p' "$ROOT/setup/lib/detect.sh")"
_gap="$(sed -n '/^detect_rootless_podman_gap()/,/^}/p' "$ROOT/setup/lib/detect.sh")"
has "...its sentence names the WSL issue"   "podman-container-tools/podman#29909" "$_gap"
has "...and the Linux delegation"           "Delegate=cpu cpuset io memory pids" "$_gap"

echo
echo "a missing package is the distribution's own command:"
OUT="$(heal uidmap "" EXAKIT_PODMAN_SELFHEAL=1)"
has   "apt-get is used where apt-get is"  "apt-get install -y uidmap" "$(sudo_log)"

echo
echo "no sudo means guidance, not a crash:"
NOSUDO="$WORK/nosudo"; mkdir -p "$NOSUDO"
# Symlinks to exactly what the modules reach for, and NO sudo - a PATH that
# still contains /usr/bin would find the real one and never take this branch.
for _t in bash sh sed grep tr head cat cut awk id uname mktemp date rm mkdir printf ls sort wc dirname basename command; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$NOSUDO/$_t" 2>/dev/null
done
cp "$BIN/podman" "$BIN/apt-get" "$NOSUDO/" 2>/dev/null
OUT="$(: > "$WORK/sudo.log"; env SUDO_LOG="$WORK/sudo.log" PATH="$NOSUDO" ROOT="$ROOT" \
        SEEN_FILE="$WORK/seen2" EXAKIT_PODMAN_SELFHEAL=1 "$NOSUDO/bash" -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        . "$ROOT/setup/lib/detect.sh" 2>/dev/null
        . "$ROOT/setup/lib/exapump.sh" 2>/dev/null
        . "$ROOT/setup/lib/runtime-personal.sh" 2>/dev/null
        : > "$SEEN_FILE"
        detect_rootless_podman_gap_kind() {
            [ -s "$SEEN_FILE" ] && return 1
            printf x > "$SEEN_FILE"; printf "subid\n"
        }
        detect_rootless_podman_gap() { printf "a stubbed reason\n"; }
        personal_heal_rootless_podman' </dev/null 2>&1 | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g')"
has   "it says sudo is missing"           "'sudo' is not on PATH" "$OUT"
has   "...and gives the root command"     "usermod --add-subuids" "$OUT"

echo
echo "the install path actually calls it:"
has "the requirements gate heals before downloading" "personal_heal_rootless_podman" \
    "$(sed -n '/linux|wsl)/,/^        \*)/p' "$ROOT/setup/lib/runtime-personal.sh")"

echo
echo "podman-rootless-selfheal.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
