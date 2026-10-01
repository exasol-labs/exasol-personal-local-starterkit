#!/usr/bin/env bash
# Guard: a line printed while a SPINNER is running must stand on its own row.
#
# A spinner owns its line and rewrites it every 80ms with a leading \r. Anything
# printed without giving that line back lands inside it, which is what `exakit
# uninstall -y` did on macOS:
#
#   ⠇ Removing the kit (3s)      ✓ dash-server removed — reinstall any time...
#   ⠏ Removing the kit (4s)      ✓ Exasol for VS Code removed — reinstall...
#
# The outcomes are MEANT to print there -- ok_step exists precisely so a line
# survives the quieting a one-line step turns on -- so the fix is not to silence
# them but to pause the spinner around the print. This test replays a real pty
# and asserts the two never share a row.
#
#   bash tests/spinner-line-safety.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# python3 with a pty is the only way to see this at all: ui_spin_begin re-checks
# `-t 1` at call time, so a spinner never starts in a captured pipeline and the
# collision it causes cannot be reproduced by running the command normally.
if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 not available - skipping\n'; exit 0
fi

cat > "$WORK/scenario.sh" <<EOF
cd "$ROOT"
. setup/lib/ui.sh
. setup/lib/common.sh 2>/dev/null
ui_detect >/dev/null 2>&1
# Forced, because ui_detect looks at the environment and a CI runner is not a
# fancy terminal -- without this the spinner never draws and the test passes
# while proving nothing.
UI_FANCY=1
UI_ACCENT=\$'\033[38;5;35m'; UI_RESET=\$'\033[0m'; UI_DIM=\$'\033[2m'
UI_OK=\$'\033[1;32m'; UI_TICK='+'
EXAKIT_QUIET_DETAIL=1
ui_spin_begin "Removing the kit"
sleep 1
ok_step "ADDON-ONE removed"
sleep 1
info_step "ADDON-TWO removed"
sleep 1
ui_spin_end
EOF

cat > "$WORK/ptyrun.py" <<'EOF'
import os, pty, sys, select
env = dict(os.environ)
env['TERM'] = 'xterm-256color'
env['LC_ALL'] = 'en_US.UTF-8'
env.pop('NO_COLOR', None)
env.pop('EXAKIT_NO_FANCY', None)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe('/bin/bash', ['/bin/bash', sys.argv[1]], env)
    os._exit(1)
buf = b''
while True:
    try:
        r, _, _ = select.select([fd], [], [], 20)
        if not r:
            break
        d = os.read(fd, 65536)
        if not d:
            break
        buf += d
    except OSError:
        break
os.waitpid(pid, 0)
sys.stdout.buffer.write(buf)
EOF

# Replay the byte stream the way a terminal would: \r moves to column 0, ESC[K
# erases to end of line. Without that replay the check is meaningless -- the raw
# stream contains every spinner frame, so a naive grep finds the label on a
# "line" that no human ever saw.
cat > "$WORK/replay.py" <<'EOF'
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
raw = raw.replace('\x1b[?25l', '').replace('\x1b[?25h', '')
lines = ['']
col = 0
i = 0
while i < len(raw):
    if raw.startswith('\x1b[K', i):
        lines[-1] = lines[-1][:col]
        i += 3
        continue
    ch = raw[i]
    i += 1
    if ch == '\r':
        col = 0
    elif ch == '\n':
        lines.append('')
        col = 0
    else:
        cur = lines[-1]
        if col < len(cur):
            lines[-1] = cur[:col] + ch + cur[col + 1:]
        else:
            lines[-1] = cur + ' ' * (col - len(cur)) + ch
        col += 1
for line in lines:
    if line.strip():
        print(line.rstrip())
EOF

python3 "$WORK/ptyrun.py" "$WORK/scenario.sh" > "$WORK/raw.bin" 2>&1
SCREEN="$(python3 "$WORK/replay.py" "$WORK/raw.bin")"
# The RAW stream, colours gone and every \r turned into a newline: this is where
# the spinner's own frames live. The replayed SCREEN cannot answer "did it draw"
# because ui_spin_end clears that line on the way out, so by the end the label is
# gone from the screen even though it animated for seconds.
RAWTXT="$(python3 -c "
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
print(re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', raw).replace('\r', '\n'))
" "$WORK/raw.bin")"

# 0. The scenario has to have actually animated, or everything below is vacuous.
case "$RAWTXT" in
    *"Removing the kit"*) pass "the spinner ran (the test is not vacuous)" ;;
    *)
        # No spinner means no collision is possible; say so rather than passing
        # silently, because a green run here would be meaningless.
        printf '  SKIP no spinner drew on this host - nothing to guard\n'
        printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
        exit 0
        ;;
esac

# 1. THE BUG: no row carries the spinner label AND an outcome.
COLLIDED="$(printf '%s\n' "$SCREEN" | grep -c 'Removing the kit.*ADDON' || true)"
if [ "$COLLIDED" = "0" ]; then
    pass "no outcome shares a row with the spinner"
else
    fail "$COLLIDED outcome(s) printed into the spinner's line"
    printf '%s\n' "$SCREEN" | grep 'Removing the kit.*ADDON' | sed 's/^/       /'
fi

# 2. Both outcomes still reached the screen. Pausing the spinner must not become
#    a way of losing the line -- silencing them would pass check 1 too.
for want in ADDON-ONE ADDON-TWO; do
    case "$SCREEN" in
        *"$want"*) pass "$want still printed" ;;
        *)         fail "$want never reached the screen" ;;
    esac
done

# 3. The elapsed counter carries on across a pause. Resuming with a fresh start
#    time would send it back to (0s) every time a line printed, which reads as
#    the step having started over. Checked as a SEQUENCE rather than a final
#    value: a reset shows up as the count going backwards, which is the only
#    shape that distinguishes it from a step that was simply quick.
ELAPSED="$(python3 -c "
import re, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
raw = re.sub(r'\x1b\[[0-9;?]*[A-Za-z]', '', raw)
vals = [int(v) for v in re.findall(r'Removing the kit \((\d+)s\)', raw)]
if len(vals) < 2:
    print('TOO-FEW')
elif any(b < a for a, b in zip(vals, vals[1:])):
    print('RESET')
else:
    print('OK ' + str(max(vals)) + 's')
" "$WORK/raw.bin")"
case "$ELAPSED" in
    OK*)      pass "the elapsed counter never went backwards (${ELAPSED#OK })" ;;
    RESET)    fail "the elapsed counter restarted after a pause" ;;
    *)        fail "could not read the elapsed counter ($ELAPSED)" ;;
esac

# 4. The PowerShell twin does the same, asserted as text: there is no pwsh on the
#    machine this kit is developed on, and Windows is where the uninstall this
#    fixes actually runs.
PS_UI="$ROOT/setup/lib/ui.ps1"
PS_COMMON="$ROOT/setup/lib/exakit-common.ps1"
if grep -q 'function Suspend-ExakitSpinner' "$PS_UI" && grep -q 'function Resume-ExakitSpinner' "$PS_UI"; then
    pass "the PowerShell twin has a pause/resume pair"
else
    fail "the PowerShell twin has no pause/resume - Windows keeps the collision"
fi
if grep -q 'Suspend-ExakitSpinner' "$PS_COMMON" && grep -q 'Resume-ExakitSpinner' "$PS_COMMON"; then
    pass "...and OkStep/InfoStep use it"
else
    fail "the PowerShell OkStep/InfoStep still print across the spinner"
fi
# Restoring T0 is what keeps the counter honest on that side too.
if grep -q 'UiSpinFlag.T0 = \$script:UiSpinPausedT0' "$PS_UI"; then
    pass "...and puts the original start time back"
else
    fail "the PowerShell resume restarts the elapsed counter"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
