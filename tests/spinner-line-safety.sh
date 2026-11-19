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

# 5. A SUBSHELL's outcome line must not end the parent's spinner. Bash gives a
#    subshell its parent's $$, so an owner check on $$ alone let the subshell
#    that set up the read-only MCP user stop Step 4's spinner at (3s) and leave
#    it frozen there while the MCP server took half a minute to start.
cat > "$WORK/subshell.sh" <<EOF
cd "$ROOT"
. setup/lib/ui.sh
. setup/lib/common.sh 2>/dev/null
ui_detect >/dev/null 2>&1
UI_FANCY=1
EXAKIT_QUIET_DETAIL=1
ui_spin_begin "Starting the MCP server and checking it answers"
_outer="\$_UI_SPIN_PID"
( ui_spin_begin inner; ui_spin_end; ok_step "read-only user ready" ) >/dev/null 2>&1
sleep 0.5
if kill -0 "\$_outer" 2>/dev/null; then echo; echo SPINNER-ALIVE; else echo; echo SPINNER-KILLED; fi
ui_spin_end
EOF
case "$(python3 "$WORK/ptyrun.py" "$WORK/subshell.sh" 2>&1 | tr '\r' '\n')" in
    *SPINNER-ALIVE*)  pass "a subshell's ok_step leaves the parent's spinner running" ;;
    *SPINNER-KILLED*) fail "a subshell's ok_step stopped the parent's spinner (frozen step line)" ;;
    *)                fail "the subshell scenario did not report" ;;
esac

# A MENU STOPS THE SPINNER. The install's add-on offer starts a spinner until
# its table is up; on a re-run with nothing to auto-install nothing stopped it,
# so its frames prefixed the menu's rows, kept going while it waited for a key,
# and ran on into the closing box. The menu must take the line, as
# ui_table_begin does.
cat > "$WORK/menu.sh" <<EOF
cd "$ROOT"
export HOME="$WORK/home"; mkdir -p "\$HOME"
. setup/lib/ui.sh
. setup/lib/common.sh 2>/dev/null
ui_detect >/dev/null 2>&1
UI_FANCY=1
printf 'alpha|Alpha||\nskip|Skip||\n' > "$WORK/menu-table"
UI_TABLE_TITLE="Marketplace add-ons"
ui_spin_begin ""
sleep 0.6
printf '\nMENU-START\n'
ui_table_menu "$WORK/menu-table"
echo "AFTER-MENU pid=[\${_UI_SPIN_PID}]"
sleep 0.6
EOF
# The driver for the two scenarios below: keys typed at 2s (Space, Enter),
# and a hard deadline, so a spinner that never stops cannot hang the test.
cat > "$WORK/ptykeys.py" <<'PY'
import os, pty, sys, select, time, signal
env = dict(os.environ); env['TERM'] = 'xterm-256color'; env['LC_ALL'] = 'en_US.UTF-8'
env.pop('NO_COLOR', None); env.pop('EXAKIT_NO_FANCY', None)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe('/bin/bash', ['/bin/bash', sys.argv[1]], env); os._exit(1)
buf = b''; t0 = time.time(); sent = False; deadline = float(sys.argv[2])
while time.time() - t0 < deadline:
    if not sent and time.time() - t0 > 2.0:
        os.write(fd, b' '); time.sleep(0.3); os.write(fd, b'\r'); sent = True
    try:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            d = os.read(fd, 65536)
            if not d: break
            buf += d
    except OSError:
        break
try: os.kill(pid, signal.SIGKILL)
except Exception: pass
sys.stdout.buffer.write(buf)
PY
cat > "$WORK/frames.py" <<'PY'
import sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
start = raw.find(sys.argv[2]); stop = raw.find(sys.argv[3]) if len(sys.argv) > 3 else -1
seg = raw[start:stop if stop > 0 else None] if start >= 0 else ''
print('found' if start >= 0 else 'missing', sum(seg.count(c) for c in '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'))
PY
python3 "$WORK/ptykeys.py" "$WORK/menu.sh" 7 > "$WORK/menu.raw" 2>&1
case "$(python3 "$WORK/frames.py" "$WORK/menu.raw" MENU-START AFTER-MENU)" in
    "found 0") pass "no spinner frame while the menu is on screen" ;;
    *)         fail "the spinner kept drawing over the menu: $(python3 "$WORK/frames.py" "$WORK/menu.raw" MENU-START AFTER-MENU)" ;;
esac
case "$(python3 "$WORK/frames.py" "$WORK/menu.raw" AFTER-MENU)" in
    "found 0") pass "no spinner frame after the menu returns" ;;
    *)         fail "the spinner outlived the menu: $(python3 "$WORK/frames.py" "$WORK/menu.raw" AFTER-MENU)" ;;
esac
grep -q 'AFTER-MENU pid=\[\]' "$WORK/menu.raw" && pass "the menu released the spinner slot" \
    || fail "the spinner slot still holds a pid after the menu"

# CTRL-C NEVER LEAVES AN ANIMATOR. The animator is disowned, so when the
# installer died at a menu nothing reaped it, and it wrote frames over the shell
# prompt until the terminal closed. The terminal stays open here (the driver
# lives on) while the installer it started is interrupted.
cat > "$WORK/inner.sh" <<EOF
cd "$ROOT"; export HOME="$WORK/home"
. setup/lib/ui.sh; . setup/lib/common.sh 2>/dev/null; ui_detect >/dev/null 2>&1; UI_FANCY=1
ui_spin_begin "working"
sleep 30
EOF
cat > "$WORK/driver.sh" <<EOF
bash "$WORK/inner.sh" &
p=\$!
sleep 0.8
kill -INT \$p; kill -9 \$p 2>/dev/null
sleep 0.5
echo; echo DEAD-MARK
sleep 1.5
echo; echo "LEFT=\$(pgrep -f "$WORK/inner.sh" | wc -l | tr -d ' ')"
EOF
python3 "$WORK/ptykeys.py" "$WORK/driver.sh" 5 > "$WORK/driver.raw" 2>&1
pkill -f "$WORK/inner.sh" 2>/dev/null
case "$(python3 "$WORK/frames.py" "$WORK/driver.raw" DEAD-MARK)" in
    "found 0") pass "no spinner frame after the installer is interrupted" ;;
    *)         fail "an orphaned spinner kept drawing after the installer died" ;;
esac
grep -q 'LEFT=0' "$WORK/driver.raw" && pass "no animator process outlives the installer" \
    || fail "an animator process outlived the installer"

# THE OFFER'S SPINNER, handed to a table someone else draws. A nested
# ui_spin_begin that never gave its reference back left ui_spin_end only
# counting down, so the owner's last frame stayed frozen above the add-ons
# table. ui_spin_end_all is the real stop the hand-over uses now.
cat > "$WORK/nested.sh" <<EOF
cd "$ROOT"; export HOME="$WORK/home"
. setup/lib/ui.sh; . setup/lib/common.sh 2>/dev/null; ui_detect >/dev/null 2>&1; UI_FANCY=1
ui_spin_begin ""
ui_spin_begin "Opening the add-ons"
sleep 0.6
ui_spin_end
echo "COUNTDOWN pid=[\${_UI_SPIN_PID:+set}]"
ui_spin_end_all
printf '\nTABLE-START\n'
sleep 0.8
echo "TABLE-END pid=[\${_UI_SPIN_PID}] nested=[\${_UI_SPIN_NESTED}]"
EOF
python3 "$WORK/ptykeys.py" "$WORK/nested.sh" 4 > "$WORK/nested.raw" 2>&1
grep -q 'COUNTDOWN pid=\[set\]' "$WORK/nested.raw" && pass "a leaked nested reference keeps ui_spin_end from stopping the owner (the cause)" \
    || fail "expected ui_spin_end to only count down with a nested reference out"
case "$(python3 "$WORK/frames.py" "$WORK/nested.raw" TABLE-START TABLE-END)" in
    "found 0") pass "ui_spin_end_all: no spinner frame once the table owns the line" ;;
    *)         fail "a frame was drawn after ui_spin_end_all: $(python3 "$WORK/frames.py" "$WORK/nested.raw" TABLE-START TABLE-END)" ;;
esac
grep -q 'TABLE-END pid=\[\] nested=\[0\]' "$WORK/nested.raw" && pass "ui_spin_end_all released the slot and every reference" \
    || fail "ui_spin_end_all left a pid or a reference"

# A spinner that is stopped says nothing on stderr. The stop is a SIGTERM to
# the animator; one that landed while the frame's `date` ran in a $( ) left the
# `|| echo 0` writing into a dead pipe, and bash printed
# "ui.sh: line 463: echo: write error: Broken pipe" on the status screen (4 of
# 7 pty runs of `exakit status`). A race, so many short start/stop cycles: the
# unfixed animator printed it 5 times in 60 cycles, 26 in 200. python3 ignores
# SIGPIPE and its pty child inherits that, as an agent's terminal does.
cat > "$WORK/stopstorm.sh" <<EOF
cd "$ROOT"
. setup/lib/ui.sh
. setup/lib/common.sh 2>/dev/null
ui_detect >/dev/null 2>&1
UI_FANCY=1
_ss=0
while [ \$_ss -lt 60 ]; do
    ui_spin_begin "Checking the database"
    sleep 0.0\$(( _ss % 9 ))
    ui_spin_end
    _ss=\$(( _ss + 1 ))
done
echo STORM-DONE
EOF
python3 "$WORK/ptyrun.py" "$WORK/stopstorm.sh" > "$WORK/storm.raw" 2>&1
grep -q 'STORM-DONE' "$WORK/storm.raw" && pass "60 spinner start/stop cycles ran under a pty" \
    || fail "the start/stop scenario did not finish"
if grep -aq 'write error\|Broken pipe' "$WORK/storm.raw"; then
    fail "a stopped spinner printed a bash error: $(grep -ao 'line [0-9]*: [a-z]*: write error' "$WORK/storm.raw" | head -1)"
else
    pass "a stopped spinner never prints a write error on the user's screen"
fi

# Windows: every exakit command sat on a blank console for seconds while the
# libraries loaded (ui.ps1's Add-Type compiles C#), before anything could draw.
# exakit.ps1 now puts its own spinner up first and erases it before the
# command's first line; redirected output and --json get nothing.
if command -v pwsh >/dev/null 2>&1; then
    sed 's/\[\], 20)/[], 180)/' "$WORK/ptyrun.py" > "$WORK/ptyrun-slow.py"
    _bs_env="EXAKIT_HOME='$WORK/bs-home' EXAKIT_BIN_DIR='$WORK/bs-bin'"
    printf 'cd "%s"\n%s exec pwsh -NoProfile -File setup/exakit.ps1 help\n' "$ROOT" "$_bs_env" > "$WORK/boot.sh"
    printf 'cd "%s"\n%s exec pwsh -NoProfile -File setup/exakit.ps1 help --json\n' "$ROOT" "$_bs_env" > "$WORK/boot-json.sh"
    python3 "$WORK/ptyrun-slow.py" "$WORK/boot.sh" > "$WORK/boot.raw" 2>&1
    if grep -aq 'Starting exakit' "$WORK/boot.raw"; then
        pass "exakit.ps1 draws a spinner while its libraries load"
    else
        fail "exakit.ps1 showed nothing while its libraries loaded"
    fi
    _bs_screen="$(python3 "$WORK/replay.py" "$WORK/boot.raw")"
    case "$_bs_screen" in
        *"Starting exakit"*) fail "the start-up spinner was left on the screen" ;;
        *) pass "the start-up spinner is gone from the screen" ;;
    esac
    case "$_bs_screen" in
        *"exakit"*) pass "the command's own output follows" ;;
        *) fail "no help output after the start-up spinner" ;;
    esac
    python3 "$WORK/ptyrun-slow.py" "$WORK/boot-json.sh" > "$WORK/boot-json.raw" 2>&1
    if grep -aq 'Starting exakit' "$WORK/boot-json.raw"; then
        fail "--json drew the start-up spinner"
    else
        pass "--json draws no start-up spinner"
    fi
    (cd "$ROOT" && EXAKIT_HOME="$WORK/bs-home" EXAKIT_BIN_DIR="$WORK/bs-bin" \
        pwsh -NoProfile -File setup/exakit.ps1 help > "$WORK/boot-piped.out" 2>&1)
    if grep -aq 'Starting exakit' "$WORK/boot-piped.out"; then
        fail "redirected output got the start-up spinner"
    else
        pass "redirected output gets no start-up spinner"
    fi
else
    printf '  skip pwsh not available: start-up spinner checks\n'
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
